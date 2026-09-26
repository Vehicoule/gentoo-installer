//! Live-environment probing: boot mode, arch, RAM, CPU flags, GPUs,
//! block devices, network reachability. Fills the `env` object the
//! headless protocol emits and the planner consults.

const std = @import("std");
const config = @import("config.zig");
const Allocator = std.mem.Allocator;

pub const Gpu = struct {
    /// PCI address, e.g. "0000:01:00.0".
    pci: []const u8,
    vendor: []const u8, // "nvidia" | "amd" | "intel" | "other" | hex
    device_id: u32,
};

pub const DiskInfo = struct {
    name: []const u8, // "sda"
    path: []const u8, // "/dev/sda"
    size_bytes: u64,
    removable: bool,
};

pub const Env = struct {
    boot_mode: config.BootMode,
    arch: config.Arch,
    ram_mib: u64,
    cpu_count: u32,
    cpu_vendor: []const u8,
    cpu_flags: []const []const u8,
    /// non-loopback network interface names (/sys/class/net)
    nics: []const []const u8,
    gpus: []const Gpu,
    disks: []const DiskInfo,
    net_reachable: bool,
};

fn readSmall(alloc: Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    // readFileAlloc stat-sizes reads; procfs/sysfs report size 0 and
    // would come back empty — fill a stack buffer then dupe.
    var buf: [4096]u8 = undefined;
    const data = std.Io.Dir.cwd().readFile(io, path, &buf) catch return null;
    return alloc.dupe(u8, data) catch null;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

// readFile with a 1 MiB heap buffer — for procfs files too big for
// readSmall's stack buffer (cpuinfo on multicore hosts).
fn readBig(alloc: Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    const buf = alloc.alloc(u8, 1 << 20) catch return null;
    const data = std.Io.Dir.cwd().readFile(io, path, buf) catch return null;
    return data;
}

pub fn detect(alloc: Allocator, io: std.Io) !Env {
    var env: Env = .{
        .boot_mode = .bios,
        .arch = switch (@import("builtin").cpu.arch) {
            .x86_64 => .amd64,
            .aarch64 => .arm64,
            .riscv64 => .riscv64,
            else => .amd64,
        },
        .ram_mib = 0,
        .cpu_count = 1,
        .cpu_vendor = "",
        .cpu_flags = &.{},
        .nics = &.{},
        .gpus = &.{},
        .disks = &.{},
        .net_reachable = false,
    };

    // Boot mode: presence of the EFI sysfs interface.
    if (std.Io.Dir.cwd().openDir(io, "/sys/firmware/efi", .{}) catch null) |dir| {
        dir.close(io);
        env.boot_mode = .uefi;
    }

    // RAM: /proc/meminfo MemTotal is in KiB.
    if (readSmall(alloc, io, "/proc/meminfo")) |meminfo| {
        var it = std.mem.tokenizeAny(u8, meminfo, " \t:\n");
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "MemTotal")) {
                const kb = it.next() orelse break;
                const kib = std.fmt.parseInt(u64, kb, 10) catch 0;
                env.ram_mib = kib / 1024;
                break;
            }
        }
    }

    // CPU flags: the `flags` line of /proc/cpuinfo (x86); other arches
    // expose different names — we just record whatever is there.
    // cpuinfo grows ~1-2 KiB per core — read it into a large heap
    // buffer, not the 4 KiB readSmall one (truncated counts → -j1).
    if (readBig(alloc, io, "/proc/cpuinfo")) |cpuinfo| {
        var lines = std.mem.splitScalar(u8, cpuinfo, '\n');
        var ncpu: u32 = 0;
        var got_flags = false;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "processor")) ncpu += 1;
            if (std.mem.startsWith(u8, line, "vendor_id")) {
                if (std.mem.indexOfScalar(u8, line, ':')) |colon|
                    env.cpu_vendor = trim(line[colon + 1 ..]);
            }
            // flags/Features repeats per-processor — take the first only,
            // but keep scanning so cpu_count sees every processor stanza.
            if (!got_flags and (std.mem.startsWith(u8, line, "flags") or std.mem.startsWith(u8, line, "Features"))) {
                if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                    var flags: std.ArrayList([]const u8) = .empty;
                    var it = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
                    while (it.next()) |f| try flags.append(alloc, f);
                    env.cpu_flags = flags.items;
                }
                got_flags = true;
            }
        }
        if (ncpu > 0) env.cpu_count = ncpu;
    }
    env.nics = detectNics(alloc, io);

    env.gpus = try detectGpus(alloc, io);
    env.disks = try detectDisks(alloc, io);
    env.net_reachable = detectNet(alloc, io);
    return env;
}

fn detectNics(alloc: Allocator, io: std.Io) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, "/sys/class/net", .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (std.mem.eql(u8, entry.name, "lo")) continue;
        // virtual links (docker0, veth*, br-*) have no device symlink
        const dev_path = std.fmt.allocPrint(alloc, "/sys/class/net/{s}/device", .{entry.name}) catch continue;
        std.Io.Dir.cwd().access(io, dev_path, .{}) catch continue;
        out.append(alloc, alloc.dupe(u8, entry.name) catch continue) catch {};
    }
    return out.items;
}

fn detectNet(alloc: Allocator, io: std.Io) bool {
    // Cheap probe: a non-loopback interface that is "up". True
    // reachability (distfiles mirror) is checked by the fetch step.
    var dir = std.Io.Dir.cwd().openDir(io, "/sys/class/net", .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (std.mem.eql(u8, entry.name, "lo")) continue;
        const path = std.fmt.allocPrint(alloc, "/sys/class/net/{s}/operstate", .{entry.name}) catch return false;
        if (readSmall(alloc, io, path)) |state| {
            if (std.mem.eql(u8, trim(state), "up")) return true;
        }
    }
    return false;
}

fn detectGpus(alloc: Allocator, io: std.Io) ![]const Gpu {
    var out: std.ArrayList(Gpu) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, "/sys/bus/pci/devices", .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const class_path = try std.fmt.allocPrint(alloc, "/sys/bus/pci/devices/{s}/class", .{entry.name});
        const class_raw = readSmall(alloc, io, class_path) orelse continue;
        const class = std.fmt.parseInt(u32, std.mem.trimStart(u8, trim(class_raw), "0x"), 16) catch continue;
        // VGA / 3D / display controllers: PCI class 0x03xxxx
        if (class >> 16 != 0x03) continue;

        const vendor_path = try std.fmt.allocPrint(alloc, "/sys/bus/pci/devices/{s}/vendor", .{entry.name});
        const device_path = try std.fmt.allocPrint(alloc, "/sys/bus/pci/devices/{s}/device", .{entry.name});
        const vendor_id = if (readSmall(alloc, io, vendor_path)) |v|
            std.fmt.parseInt(u32, std.mem.trimStart(u8, trim(v), "0x"), 16) catch 0
        else
            0;
        const device_id = if (readSmall(alloc, io, device_path)) |v|
            std.fmt.parseInt(u32, std.mem.trimStart(u8, trim(v), "0x"), 16) catch 0
        else
            0;

        const vendor: []const u8 = switch (vendor_id) {
            0x10de => "nvidia",
            0x1002, 0x1022 => "amd",
            0x8086 => "intel",
            else => "other",
        };
        try out.append(alloc, .{
            .pci = try alloc.dupe(u8, entry.name),
            .vendor = vendor,
            .device_id = device_id,
        });
    }
    return out.items;
}

/// NVIDIA GPU generation gate: Turing+ only for the open kernel
/// modules (nvidia-open). PCI device IDs are assigned roughly
/// monotonically per architecture: Turing (TU10x/TU11x) starts at
/// 0x1e02; Pascal and older sit below ~0x1e00. Good enough for
/// detection — an explicit `nvidia-open` pick on unknown IDs still
/// prompts a confirmation, and VALIDATE errs on the side of allowing
/// borderline devices.
pub fn nvidiaIsTuringPlus(gpu: Gpu) bool {
    if (!std.mem.eql(u8, gpu.vendor, "nvidia")) return false;
    return gpu.device_id >= 0x1e00;
}

fn detectDisks(alloc: Allocator, io: std.Io) ![]const DiskInfo {
    var out: std.ArrayList(DiskInfo) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, "/sys/block", .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        // Skip virtual/no-media devices we never install to.
        const name = entry.name;
        if (std.mem.startsWith(u8, name, "loop") or
            std.mem.startsWith(u8, name, "ram") or
            std.mem.startsWith(u8, name, "sr") or
            std.mem.startsWith(u8, name, "dm-") or
            std.mem.startsWith(u8, name, "zram") or
            std.mem.startsWith(u8, name, "md")) continue;

        const size_path = try std.fmt.allocPrint(alloc, "/sys/block/{s}/size", .{name});
        const sectors = if (readSmall(alloc, io, size_path)) |s|
            std.fmt.parseInt(u64, trim(s), 10) catch 0
        else
            0;

        const rem_path = try std.fmt.allocPrint(alloc, "/sys/block/{s}/removable", .{name});
        const removable = if (readSmall(alloc, io, rem_path)) |r|
            std.mem.eql(u8, trim(r), "1")
        else
            false;

        try out.append(alloc, .{
            .name = try alloc.dupe(u8, name),
            .path = try std.fmt.allocPrint(alloc, "/dev/{s}", .{name}),
            .size_bytes = sectors * 512,
            .removable = removable,
        });
    }
    return out.items;
}

/// Emit env as a JSON object — the standalone `detect` CLI output.
pub fn envToJson(alloc: Allocator, env: *const Env, w: *std.Io.Writer) !void {
    try w.writeAll("{");
    try envFieldsJson(alloc, env, w);
    try w.writeAll("}");
}

/// The env event payload fields (no braces) — flat, per
/// docs/protocol.md's env event contract.
pub fn envFieldsJson(alloc: Allocator, env: *const Env, w: *std.Io.Writer) !void {
    try w.writeAll("\"boot\":\"");
    try w.writeAll(@tagName(env.boot_mode));
    try w.print("\",\"arch\":\"{s}\",\"ram_mib\":{},\"cpus\":{},\"cpu_vendor\":\"{s}\",\"net\":{},", .{ @tagName(env.arch), env.ram_mib, env.cpu_count, env.cpu_vendor, env.net_reachable });
    try w.writeAll("\"nics\":[");
    for (env.nics, 0..) |nic, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{nic});
    }
    try w.writeAll("],");
    try w.writeAll("\"gpus\":[");
    for (env.gpus, 0..) |g, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"pci\":\"{s}\",\"vendor\":\"{s}\",\"device\":\"0x{x:0>4}\",\"nvidia_turing_plus\":{}}}", .{ g.pci, g.vendor, g.device_id, nvidiaIsTuringPlus(g) });
    }
    try w.writeAll("],\"disks\":[");
    for (env.disks, 0..) |d, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"name\":\"{s}\",\"path\":\"{s}\",\"size_gib\":{},\"removable\":{}}}", .{ d.name, d.path, d.size_bytes / (1 << 30), d.removable });
    }
    try w.writeAll("],\"cpu_flags\":[");
    for (env.cpu_flags, 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{f});
    }
    try w.writeAll("]");
    _ = alloc;
}
