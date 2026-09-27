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

pub const PartInfo = struct {
    num: u32, // GPT entry number
    path: []const u8, // "/dev/sda3"
    /// blkid TYPE (ntfs/ext4/btrfs/vfat/swap/BitLocker/crypto_LUKS/…); "" when unknown.
    fs: []const u8 = "",
    /// PART_ENTRY_UUID (the PARTUUID kernel/fstab resolve by).
    partuuid: []const u8 = "",
    esp: bool = false, // PART_ENTRY_TYPE is the EFI System Partition GUID
    start_sector: u64 = 0,
    size_bytes: u64 = 0,
    /// Filesystem probe results — 0 means "couldn't determine" (tool
    /// absent, fs dirty, unreadable). Shrink validation refuses
    /// unprobed filesystems rather than guessing.
    fs_size_bytes: u64 = 0,
    fs_free_bytes: u64 = 0,
};

/// An unallocated gap between partitions, sector-exact (end inclusive).
/// Both bounds are already clamped to the GPT usable range and MiB
/// alignment, so sgdisk can take them verbatim.
pub const FreeRegion = struct {
    start_sector: u64,
    end_sector: u64,
};

pub const DiskInfo = struct {
    name: []const u8, // "sda"
    path: []const u8, // "/dev/sda"
    size_bytes: u64,
    removable: bool,
    /// Partition-table label — "gpt", "dos", … ("" when unknown).
    label: []const u8 = "",
    parts: []const PartInfo = &.{},
    free_regions: []const FreeRegion = &.{},
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
    /// Installed-OS hint for the wizard's `alongside` visibility:
    /// "windows" when ntfs/BitLocker shows up, "linux" when an ESP or
    /// foreign linux fs exists, "" on empty disks.
    os_hint: []const u8 = "",
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
    // Installed-OS heuristic for `alongside` visibility: Windows when
    // ntfs/BitLocker partitions exist, generic linux when a foreign
    // linux fs or an ESP does, nothing on a blank disk.
    var saw_ntfs = false;
    var saw_linux = false;
    var saw_esp = false;
    for (env.disks) |d| {
        for (d.parts) |p| {
            if (std.mem.eql(u8, p.fs, "ntfs") or std.mem.eql(u8, p.fs, "BitLocker"))
                saw_ntfs = true
            else if (p.esp)
                saw_esp = true
            else if (std.mem.startsWith(u8, p.fs, "ext") or std.mem.eql(u8, p.fs, "btrfs") or
                std.mem.eql(u8, p.fs, "xfs") or std.mem.eql(u8, p.fs, "f2fs"))
                saw_linux = true;
        }
    }
    env.os_hint = if (saw_ntfs) "windows" else if (saw_linux or saw_esp) "linux" else "";
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

/// Run a probe tool and capture stdout (bounded). Best-effort: any
/// spawn/exit failure returns null — callers treat it as "unprobed".
fn capture(alloc: Allocator, io: std.Io, argv: []const []const u8) ?[]const u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    var buf: std.ArrayList(u8) = .empty;
    const cs = child.stdout.?;
    var rbuf: [8192]u8 = undefined;
    var r = cs.reader(io, &rbuf);
    while (true) {
        const chunk = r.interface.peekGreedy(1) catch break;
        if (chunk.len == 0) break;
        if (buf.items.len < (256 << 10)) {
            const room = (256 << 10) - buf.items.len;
            buf.appendSlice(alloc, chunk[0..@min(room, chunk.len)]) catch break;
        }
        r.interface.toss(chunk.len);
    }
    cs.close(io);
    child.stdout = null;
    const term = child.wait(io) catch return null;
    switch (term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return buf.items;
}

/// Parse "KEY=value" export output (blkid -o export / parted-free style
/// probes we don't need a shell for). Returns the value for `key`.
fn exportField(out: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, trim(line[0..eq]), key)) return trim(line[eq + 1 ..]);
    }
    return null;
}

/// Numeric field out of a tool's report (dumpe2fs -h, ntfsresize -i):
/// first digit-run on the line containing `key` after the colon.
fn reportNum(out: []const u8, key: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const idx = std.mem.indexOf(u8, line, key) orelse continue;
        var rest = line[idx + key.len ..];
        // skip past ':' and any non-digits
        var i: usize = 0;
        while (i < rest.len and !std.ascii.isDigit(rest[i])) i += 1;
        var j = i;
        while (j < rest.len and std.ascii.isDigit(rest[j])) j += 1;
        if (j > i) return std.fmt.parseInt(u64, rest[i..j], 10) catch null;
        _ = &rest;
    }
    return null;
}

/// Filesystem size + free bytes for a shrinkable candidate, via
/// read-only probes. ntfs needs ntfs3g's ntfsresize; btrfs needs a
/// read-only mount (nologreplay never writes) for `filesystem usage`.
fn probeFs(alloc: Allocator, io: std.Io, p: *PartInfo) void {
    if (std.mem.startsWith(u8, p.fs, "ext")) {
        const out = capture(alloc, io, &.{ "dumpe2fs", "-h", p.path }) orelse return;
        const blocks = reportNum(out, "Block count") orelse return;
        const free_blocks = reportNum(out, "Free blocks") orelse return;
        const bsz = reportNum(out, "Block size") orelse return;
        p.fs_size_bytes = blocks * bsz;
        p.fs_free_bytes = free_blocks * bsz;
    } else if (std.mem.eql(u8, p.fs, "ntfs")) {
        const out = capture(alloc, io, &.{ "ntfsresize", "--info", "--force", p.path }) orelse return;
        const cur = reportNum(out, "Current volume size") orelse return;
        const min = reportNum(out, "You might resize at") orelse cur;
        p.fs_size_bytes = cur;
        p.fs_free_bytes = if (cur > min) cur - min else 0;
    } else if (std.mem.eql(u8, p.fs, "btrfs")) {
        // btrfs resizes only while mounted; nologreplay keeps it RO-safe.
        const out = capture(alloc, io, &.{ "sh", "-c", std.fmt.allocPrint(alloc, "mkdir -p /run/gi-probe && mount -o ro,nologreplay {s} /run/gi-probe && btrfs filesystem usage -b /run/gi-probe; rc=$?; umount /run/gi-probe 2>/dev/null; exit $rc", .{p.path}) catch return }) orelse return;
        const sz = reportNum(out, "Device size") orelse p.size_bytes;
        const free = reportNum(out, "Free (estimated)") orelse return;
        p.fs_size_bytes = sz;
        p.fs_free_bytes = free;
    }
}

/// Enumerate GPT/MBR partitions of one disk via sysfs + blkid.
fn detectParts(alloc: Allocator, io: std.Io, name: []const u8) ![]const PartInfo {
    var out: std.ArrayList(PartInfo) = .empty;
    const disk_dir = try std.fmt.allocPrint(alloc, "/sys/block/{s}", .{name});
    var dir = std.Io.Dir.cwd().openDir(io, disk_dir, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const pnum_path = try std.fmt.allocPrint(alloc, "{s}/{s}/partition", .{ disk_dir, entry.name });
        const num_raw = readSmall(alloc, io, pnum_path) orelse continue;
        const num = std.fmt.parseInt(u32, trim(num_raw), 10) catch continue;
        const start_raw = readSmall(alloc, io, try std.fmt.allocPrint(alloc, "{s}/{s}/start", .{ disk_dir, entry.name }));
        const size_raw = readSmall(alloc, io, try std.fmt.allocPrint(alloc, "{s}/{s}/size", .{ disk_dir, entry.name }));
        const start = if (start_raw) |r| std.fmt.parseInt(u64, trim(r), 10) catch 0 else 0;
        const secs = if (size_raw) |r| std.fmt.parseInt(u64, trim(r), 10) catch 0 else 0;

        var p: PartInfo = .{
            .num = num,
            .path = try std.fmt.allocPrint(alloc, "/dev/{s}", .{entry.name}),
            .start_sector = start,
            .size_bytes = secs * 512,
        };
        // blkid low-level probe: fs TYPE + PART_ENTRY_* GPT metadata.
        if (capture(alloc, io, &.{ "blkid", "-p", "-o", "export", p.path })) |b| {
            if (exportField(b, "TYPE")) |t| p.fs = try alloc.dupe(u8, t);
            if (exportField(b, "PART_ENTRY_UUID")) |u| p.partuuid = try alloc.dupe(u8, u);
            if (exportField(b, "PART_ENTRY_TYPE")) |t| {
                // blkid prints the bare GUID (sometimes 0x-prefixed).
                const tv = if (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X")) t[2..] else t;
                p.esp = std.ascii.eqlIgnoreCase(tv, "c12a7328-f81f-11d2-ba4b-00a0c93ec93b");
            }
        }
        probeFs(alloc, io, &p);
        try out.append(alloc, p);
    }
    std.mem.sort(PartInfo, out.items, {}, struct {
        fn lt(_: void, a: PartInfo, b: PartInfo) bool {
            return a.num < b.num;
        }
    }.lt);
    return out.items;
}

/// Unallocated regions of a GPT disk, computed from the partition map
/// (no parted needed). Bounds are the standard usable range [34,
/// sectors-34), each clamped to MiB alignment so sgdisk accepts them.
fn freeRegions(alloc: Allocator, disk: *const DiskInfo) ![]const FreeRegion {
    var gaps: std.ArrayList(FreeRegion) = .empty;
    if (!std.mem.eql(u8, disk.label, "gpt")) return gaps.items;
    const total_sectors = disk.size_bytes / 512;
    if (total_sectors < 4096) return gaps.items;
    const usable_end = total_sectors - 34;
    var by_start: std.ArrayList(PartInfo) = .empty;
    try by_start.appendSlice(alloc, disk.parts);
    std.mem.sort(PartInfo, by_start.items, {}, struct {
        fn lt(_: void, a: PartInfo, b: PartInfo) bool {
            return a.start_sector < b.start_sector;
        }
    }.lt);
    var cursor: u64 = 34;
    for (by_start.items) |p| {
        if (p.start_sector > cursor and p.start_sector > 0)
            try gaps.append(alloc, .{ .start_sector = cursor, .end_sector = p.start_sector - 1 });
        const end = p.start_sector + p.size_bytes / 512;
        if (end > cursor) cursor = end;
    }
    if (usable_end > cursor) try gaps.append(alloc, .{ .start_sector = cursor, .end_sector = usable_end - 1 });
    // MiB-align each gap.
    var out: std.ArrayList(FreeRegion) = .empty;
    for (gaps.items) |g| {
        const s_aligned = (g.start_sector + 2047) / 2048 * 2048;
        const e_aligned = (g.end_sector + 1) / 2048 * 2048;
        if (e_aligned > s_aligned + 1)
            try out.append(alloc, .{ .start_sector = s_aligned, .end_sector = e_aligned - 1 });
    }
    return out.items;
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

        var di: DiskInfo = .{
            .name = try alloc.dupe(u8, name),
            .path = try std.fmt.allocPrint(alloc, "/dev/{s}", .{name}),
            .size_bytes = sectors * 512,
            .removable = removable,
        };
        // Table label (gpt/dos) + partition map: alongside needs both.
        if (capture(alloc, io, &.{ "blkid", "-p", "-o", "export", di.path })) |b| {
            if (exportField(b, "PTTYPE")) |t|
                di.label = try alloc.dupe(u8, t);
        }
        di.parts = try detectParts(alloc, io, name);
        di.free_regions = try freeRegions(alloc, &di);
        try out.append(alloc, di);
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
        try w.print("{{\"name\":\"{s}\",\"path\":\"{s}\",\"size_gib\":{},\"removable\":{},\"label\":\"{s}\",\"parts\":[", .{ d.name, d.path, d.size_bytes / (1 << 30), d.removable, d.label });
        for (d.parts, 0..) |p, j| {
            if (j > 0) try w.writeAll(",");
            try w.print("{{\"num\":{},\"path\":\"{s}\",\"fs\":\"{s}\",\"partuuid\":\"{s}\",\"esp\":{},\"start_sector\":{},\"size_mib\":{},\"fs_size_mib\":{},\"fs_free_mib\":{}}}", .{ p.num, p.path, p.fs, p.partuuid, p.esp, p.start_sector, p.size_bytes >> 20, p.fs_size_bytes >> 20, p.fs_free_bytes >> 20 });
        }
        try w.writeAll("],\"free\":[");
        for (d.free_regions, 0..) |g, j| {
            if (j > 0) try w.writeAll(",");
            try w.print("{{\"start\":{},\"end\":{}}}", .{ g.start_sector, g.end_sector });
        }
        try w.writeAll("]}");
    }
    try w.print("],\"os_hint\":\"{s}\",\"cpu_flags\":[", .{env.os_hint});
    for (env.cpu_flags, 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{f});
    }
    try w.writeAll("]");
    _ = alloc;
}
