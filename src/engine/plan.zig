//! The planner: Config + Env → ordered Steps → Cmd lists. Pure —
//! no side effects, no process spawns; the runner executes or prints.
//! The wizard's "after" preview renders exactly this plan.

const std = @import("std");
const config = @import("config.zig");
const detect = @import("detect.zig");
const Allocator = std.mem.Allocator;
const Config = config.Config;

pub const Exec = struct {
    argv: []const []const u8,
    /// Real bytes fed to the child's stdin (LUKS passphrase, password
    /// hash line, …). Never printed — dry-run shows `stdin_label`.
    stdin: ?[]const u8 = null,
    /// Redacted description shown in place of stdin data
    /// (e.g. "<luks passphrase>").
    stdin_label: ?[]const u8 = null,
    /// Runs inside /mnt/gentoo.
    chroot: bool = false,
    desc: []const u8 = "",
};

pub const WriteFile = struct {
    /// Absolute path inside the target (prefix /mnt/gentoo applied by
    /// the runner).
    path: []const u8,
    content: []const u8,
    mode: u32 = 0o644,
};

pub const Cmd = union(enum) {
    exec: Exec,
    write_file: WriteFile,
    note: []const u8,
};

pub const Step = struct {
    id: []const u8, // stable id for the journal/protocol
    title: []const u8,
    cmds: []const Cmd,
};

pub const Plan = struct {
    steps: []const Step,
};

fn argv(alloc: Allocator, parts: []const []const u8, desc: []const u8) Cmd {
    const dup = alloc.alloc([]const u8, parts.len) catch @panic("oom");
    for (parts, 0..) |part, i| dup[i] = part;
    return .{ .exec = .{ .argv = dup, .desc = desc } };
}

fn fmtArgv(alloc: Allocator, desc: []const u8, parts: []const []const u8) Cmd {
    const dup = alloc.alloc([]const u8, parts.len) catch @panic("oom");
    @memcpy(dup, parts);
    return .{ .exec = .{ .argv = dup, .desc = desc } };
}

fn wf(alloc: Allocator, path: []const u8, content: []const u8) Cmd {
    _ = alloc;
    return .{ .write_file = .{ .path = path, .content = content } };
}

fn s(alloc: Allocator, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, f, args) catch @panic("oom");
}

/// Partition device node for partition N of a device, handling nvme/
/// mmcblk "p" separators.
pub fn partPath(alloc: Allocator, dev: []const u8, n: u32) []const u8 {
    const needs_p = std.mem.endsWith(u8, dev, "0") or
        (dev.len > 0 and std.ascii.isDigit(dev[dev.len - 1]));
    return s(alloc, "{s}{s}{}", .{ dev, if (needs_p) "p" else "", n });
}

const mkfs_cmd = struct {
    fs: config.RootFs,
    mkfs: []const u8,
    tool_pkg: []const u8, // gentoo atom providing it
};

fn mkfsTool(fs: config.RootFs) mkfs_cmd {
    return switch (fs) {
        .btrfs => .{ .fs = fs, .mkfs = "mkfs.btrfs", .tool_pkg = "sys-fs/btrfs-progs" },
        .xfs => .{ .fs = fs, .mkfs = "mkfs.xfs", .tool_pkg = "sys-fs/xfsprogs" },
        .ext4 => .{ .fs = fs, .mkfs = "mkfs.ext4", .tool_pkg = "sys-fs/e2fsprogs" },
        .f2fs => .{ .fs = fs, .mkfs = "mkfs.f2fs", .tool_pkg = "sys-fs/f2fs-tools" },
        .bcachefs => .{ .fs = fs, .mkfs = "mkfs.bcachefs", .tool_pkg = "sys-fs/bcachefs-tools" },
    };
}

fn step(alloc: Allocator, id: []const u8, title: []const u8, cmds: std.ArrayList(Cmd)) Step {
    _ = alloc;
    return .{ .id = id, .title = title, .cmds = cmds.items };
}

/// Build the full install plan. `env` comes from detect; when null
/// (e.g. `--dry-run` off a bare config on a non-live host), detection-
/// dependent commands are still emitted with placeholders.
pub fn build(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env) !Plan {
    var steps: std.ArrayList(Step) = .empty;

    try steps.append(alloc, step(alloc, "detect", "Detect environment", blk: {
        var c: std.ArrayList(Cmd) = .empty;
        if (env) |e| {
            try c.append(alloc, .{ .note = s(alloc, "boot_mode={s} arch={s} ram={}MiB gpus={} disks={}", .{ @tagName(e.boot_mode), @tagName(e.arch), e.ram_mib, e.gpus.len, e.disks.len }) });
        } else {
            try c.append(alloc, .{ .note = "detection runs in the live env; not performed for this plan" });
        }
        break :blk c;
    }));

    try steps.append(alloc, try planPartition(alloc, cfg, env));
    try steps.append(alloc, try planMount(alloc, cfg));
    try steps.append(alloc, try planStage3(alloc, cfg));
    try steps.append(alloc, try planPortage(alloc, cfg, env));
    try steps.append(alloc, try planChroot(alloc));
    try steps.append(alloc, try planRepoSync(alloc, cfg));
    try steps.append(alloc, try planProfile(alloc, cfg));
    if (cfg.extra.update_world)
        try steps.append(alloc, try planWorldUpdate(alloc, cfg));
    try steps.append(alloc, try planBaseConfig(alloc, cfg));
    try steps.append(alloc, try planKernel(alloc, cfg));
    try steps.append(alloc, try planFstab(alloc, cfg));
    try steps.append(alloc, try planSystemConfig(alloc, cfg));
    try steps.append(alloc, try planServices(alloc, cfg));
    try steps.append(alloc, try planBootloader(alloc, cfg));
    try steps.append(alloc, try planFinish(alloc, cfg));

    return .{ .steps = steps.items };
}

// ------------------------------------------------------------------ //

fn planPartition(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    const dev = cfg.disk.device;
    const d = cfg.disk;

    switch (d.scheme) {
        .manual => {
            try c.append(alloc, .{ .note = "manual: use the partition table as found; mount targets must be supplied" });
            return step(alloc, "partition", "Partition disks", c);
        },
        .alongside => {
            try c.append(alloc, .{ .note = "alongside mode: preserve existing OS partitions; reuse existing ESP" });
            if (d.space_src == .shrink) {
                const tool = switch (d.root_fs) {
                    // shrink tool is chosen by the EXISTING fs, not ours —
                    // refine when detection reports the partition's fs
                    else => "ntfsresize/resize2fs (per detected fs)",
                };
                try c.append(alloc, argv(alloc, &.{ "shrink", d.shrink_part, s(alloc, "{}MiB", .{d.shrink_mib}) }, s(alloc, "shrink {s} by {} MiB ({s})", .{ d.shrink_part, d.shrink_mib, tool })));
            } else {
                try c.append(alloc, .{ .note = "free-space: use largest contiguous unallocated region" });
            }
            if (env) |e| _ = e;
            return step(alloc, "partition", "Partition disks (alongside)", c);
        },
        else => {},
    }

    if (d.wipe)
        try c.append(alloc, argv(alloc, &.{ "sgdisk", "--zap-all", dev }, s(alloc, "wipe partition table on {s}", .{dev})));

    // Layout: [ESP] [swap] [root]  (BIOS: [BIOSBOOT] [swap] [root])
    var n: u32 = 0;
    var esp_part: ?[]const u8 = null;
    var swap_part: ?[]const u8 = null;
    if (cfg.boot_mode == .uefi) {
        n += 1;
        esp_part = partPath(alloc, dev, n);
        try c.append(alloc, argv(alloc, &.{ "sgdisk", s(alloc, "-n{}:0:+{}MiB", .{ n, d.esp_mib }), s(alloc, "-t{}:EF00", .{n}), s(alloc, "-c{}:ESP", .{n}), dev }, s(alloc, "ESP {}MiB at partition {}", .{ d.esp_mib, n })));
    } else {
        n += 1;
        try c.append(alloc, argv(alloc, &.{ "sgdisk", s(alloc, "-n{}:0:+2MiB", .{n}), s(alloc, "-t{}:EF02", .{n}), s(alloc, "-c{}:biosboot", .{n}), dev }, "BIOS boot partition (2MiB, EF02)"));
    }
    if (d.swap == .partition) {
        n += 1;
        swap_part = partPath(alloc, dev, n);
        try c.append(alloc, argv(alloc, &.{ "sgdisk", s(alloc, "-n{}:0:+{}MiB", .{ n, d.swap_mib }), s(alloc, "-t{}:8200", .{n}), s(alloc, "-c{}:swap", .{n}), dev }, s(alloc, "swap {}MiB at partition {}", .{ d.swap_mib, n })));
    }
    n += 1;
    const root_part = partPath(alloc, dev, n);
    // 8304 = Linux root DPS GUID (auto-discovery on systemd)
    try c.append(alloc, argv(alloc, &.{ "sgdisk", s(alloc, "-n{}:0:0", .{n}), s(alloc, "-t{}:8304", .{n}), s(alloc, "-c{}:root", .{n}), dev }, s(alloc, "root partition {} (rest of disk)", .{n})));
    if (d.home_part) {
        n += 1;
        try c.append(alloc, .{ .note = "separate /home part requires an explicit size — TUI asks" });
    }

    // ESP filesystem (never reformatted in alongside mode — not reached here).
    if (esp_part) |esp|
        try c.append(alloc, argv(alloc, &.{ "mkfs.vfat", "-F32", "-n", "ESP", esp }, "format ESP as FAT32"));

    // LUKS on root (container lives on the raw partition).
    var root_dev = root_part;
    if (d.luks) {
        try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "cryptsetup", "luksFormat", "--type", "luks2", "--pbkdf", "argon2id", "--batch-mode", "--key-file", "-", root_part }),
            .stdin = cfg.disk.luks_passphrase,
            .stdin_label = "<luks passphrase>",
            .desc = s(alloc, "LUKS2+argon2id on {s} (passphrase on stdin)", .{root_part}),
        } });
        try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "cryptsetup", "open", "--key-file", "-", root_part, "cryptroot" }),
            .stdin = cfg.disk.luks_passphrase,
            .stdin_label = "<luks passphrase>",
            .desc = "open LUKS container",
        } });
        root_dev = "/dev/mapper/cryptroot";
    }

    // LVM inside the (possibly encrypted) root container.
    var fs_dev = root_dev;
    if (d.lvm) {
        try c.append(alloc, argv(alloc, &.{ "pvcreate", "--norestorefile", root_dev }, s(alloc, "PV on {s}", .{root_dev})));
        try c.append(alloc, argv(alloc, &.{ "vgcreate", "vg0", root_dev }, "volume group vg0"));
        if (cfg.system.snapshots == .auto) {
            try c.append(alloc, argv(alloc, &.{ "lvcreate", "-l", "95%VG", "-T", "vg0/tank" }, "thin pool tank (95% VG)"));
            try c.append(alloc, argv(alloc, &.{ "lvcreate", "-V", "100%FREE", "-T", "vg0/tank", "-n", "root" }, "thin root LV"));
            if (d.home_part)
                try c.append(alloc, argv(alloc, &.{ "lvcreate", "-V", "50%FREE", "-T", "vg0/tank", "-n", "home" }, "thin home LV"));
        } else {
            try c.append(alloc, argv(alloc, &.{ "lvcreate", "-l", "100%FREE", "-n", "root", "vg0" }, "linear root LV"));
        }
        fs_dev = "/dev/vg0/root";
    }

    const mk = mkfsTool(d.root_fs);
    var mkfs_argv: std.ArrayList([]const u8) = .empty;
    try mkfs_argv.append(alloc, mk.mkfs);
    try mkfs_argv.append(alloc, fs_dev);
    try c.append(alloc, fmtArgv(alloc, s(alloc, "format root as {s}", .{@tagName(d.root_fs)}), mkfs_argv.items));

    if (swap_part) |sp|
        try c.append(alloc, argv(alloc, &.{ "mkswap", "-L", "swap", sp }, "format swap"));

    if (d.root_fs == .btrfs) {
        // Mount then create the subvol layout + @snapshots dir.
        try c.append(alloc, argv(alloc, &.{ "mount", fs_dev, "/mnt/gentoo" }, "mount btrfs top-level"));
        for ([_][]const u8{ "@root", "@home", "@snapshots" }) |sv|
            try c.append(alloc, argv(alloc, &.{ "btrfs", "subvolume", "create", s(alloc, "/mnt/gentoo/{s}", .{sv}) }, s(alloc, "subvol {s}", .{sv})));
        try c.append(alloc, argv(alloc, &.{ "umount", "/mnt/gentoo" }, "unmount after subvol creation"));
    }
    return step(alloc, "partition", "Partition disks", c);
}

/// The mount point where the root filesystem lands — subvol-aware.
fn rootMountArgs(alloc: Allocator, cfg: *const Config) struct { dev: []const u8, opts: []const u8 } {
    const dev = fsDevice(alloc, cfg);
    if (cfg.disk.root_fs == .btrfs)
        return .{ .dev = dev, .opts = "subvol=@root,compress=zstd:1,noatime" };
    return .{ .dev = dev, .opts = "" };
}

/// The device node that carries the root filesystem (through LUKS/LVM).
pub fn fsDevice(alloc: Allocator, cfg: *const Config) []const u8 {
    if (cfg.disk.lvm) return "/dev/vg0/root";
    if (cfg.disk.luks) return "/dev/mapper/cryptroot";
    // root partition is the last numbered one created
    var n: u32 = 1; // esp (uefi) or biosboot (bios)
    if (cfg.disk.swap == .partition) n += 1;
    n += 1;
    return partPath(alloc, cfg.disk.device, n);
}

fn planMount(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    const root = rootMountArgs(alloc, cfg);
    if (root.opts.len > 0)
        try c.append(alloc, argv(alloc, &.{ "mount", "-o", root.opts, root.dev, "/mnt/gentoo" }, "mount root"))
    else
        try c.append(alloc, argv(alloc, &.{ "mount", root.dev, "/mnt/gentoo" }, "mount root"));

    if (cfg.boot_mode == .uefi) {
        const esp = partPath(alloc, cfg.disk.device, 1);
        const esp_target = if (cfg.system.uki or config.resolveBootloader(cfg) == .@"systemd-boot") "/mnt/gentoo/efi" else "/mnt/gentoo/efi";
        try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", esp_target }, "ESP mountpoint"));
        try c.append(alloc, argv(alloc, &.{ "mount", esp, esp_target }, "mount ESP"));
    }
    if (cfg.disk.swap == .partition) {
        const swap_n: u32 = if (cfg.boot_mode == .uefi) 2 else 2;
        try c.append(alloc, argv(alloc, &.{ "swapon", partPath(alloc, cfg.disk.device, swap_n) }, "enable swap"));
    }
    try c.append(alloc, .{ .note = "bind mounts (/proc /sys /dev /run) happen at enter-chroot" });
    return step(alloc, "mount", "Mount target", c);
}

fn planStage3(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    const stem = try config.stage3Stem(alloc, cfg);
    const arch = @tagName(cfg.arch);
    const base = s(alloc, "{s}/releases/{s}/autobuilds", .{ cfg.stage3.mirror, arch });
    try c.append(alloc, argv(alloc, &.{ "curl", "-fsSL", "-o", "/tmp/latest.txt", s(alloc, "{s}/latest-stage3-{s}.txt", .{ base, stem }) }, "resolve stage3 pointer"));
    // Resolve filename from the pointer, fetch tarball+signature+digests,
    // and link them under canonical names for the verify/extract cmds.
    try c.append(alloc, .{ .exec = .{
        .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc,
            "f=$(grep -oE '[^ ]*stage3-[^ ]*\\.tar\\.xz' /tmp/latest.txt | head -n1); " ++
            "test -n \"$f\" || exit 1; " ++
            "curl -fsSL -o \"/tmp/$f\" '{s}/'$f && " ++
            "curl -fsSL -o \"/tmp/$f.asc\" '{s}/'$f.asc && " ++
            "curl -fsSL -o /tmp/stage3.DIGESTS '{s}/'$f.DIGESTS && " ++
            "ln -sf \"$f\" /tmp/stage3.tar.xz && ln -sf \"$f.asc\" /tmp/stage3.tar.xz.asc",
            .{ base, base, base }) }),
        .desc = "download stage3 tarball + .asc + .DIGESTS (resolved from latest.txt)",
    } });
    try c.append(alloc, argv(alloc, &.{ "gpg", "--keyserver", "hkps://keys.gentoo.org", "--verify", "/tmp/stage3.tar.xz.asc", "/tmp/stage3.tar.xz" }, "GPG-verify stage3"));
    // DIGESTS mixes SHA256/SHA512/WHIRLPOOL lines — feed sha256sum only the 64-hex lines.
    try c.append(alloc, .{ .exec = .{
        .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", "grep -E '^[0-9a-f]{64}  ' /tmp/stage3.DIGESTS | (cd /tmp && sha256sum -c --ignore-missing -)" }),
        .desc = "digest-verify stage3 (SHA256 lines only)",
    } });
    try c.append(alloc, argv(alloc, &.{ "tar", "--xattrs-include=*.*", "--numeric-owner", "-xpf", "/tmp/stage3.tar.xz", "-C", "/mnt/gentoo" }, "extract stage3"));
    return step(alloc, "stage3", "Stage3 download + extract", c);
}

fn makeConf(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;

    const cflags = switch (cfg.makeconf.cflags) {
        .safe => "-O2 -pipe",
        .native => "-O2 -pipe -march=native",
        .custom => |f| f,
    };
    try w.print("COMMON_FLAGS=\"{s}\"\nCFLAGS=\"${{COMMON_FLAGS}}\"\nCXXFLAGS=\"${{COMMON_FLAGS}}\"\n", .{cflags});

    var jobs = cfg.makeconf.jobs;
    if (jobs == 0) {
        // runtime: nproc, capped by ~2GiB/job when mem known; the dry-run
        // plan fixes a conservative value and notes the rule
        jobs = 4;
    }
    try w.print("MAKEOPTS=\"-j{}\"\n", .{jobs});
    if (cfg.makeconf.mem_cap_gib > 0)
        try w.print("# mem cap {} GiB enforced at emerge job calc\n", .{cfg.makeconf.mem_cap_gib});

    if (!std.mem.eql(u8, cfg.makeconf.video_cards, "auto"))
        try w.print("VIDEO_CARDS=\"{s}\"\n", .{cfg.makeconf.video_cards})
    else if (env) |e| {
        try w.writeAll("VIDEO_CARDS=\"");
        for (e.gpus) |g| {
            if (std.mem.eql(u8, g.vendor, "amd")) try w.writeAll("amdgpu radeonsi ");
            if (std.mem.eql(u8, g.vendor, "intel")) try w.writeAll("intel ");
            if (std.mem.eql(u8, g.vendor, "nvidia")) try w.writeAll("nvidia ");
        }
        try w.writeAll("\"\n");
    } else {
        try w.writeAll("VIDEO_CARDS=\"\" # auto: filled by detection\n");
    }

    var accept = cfg.makeconf.accept_license;
    var nv_buf: [64]u8 = undefined;
    const wants_nvidia = cfg.gpu.driver == .@"nvidia-open" or cfg.gpu.driver == .@"nvidia-drivers" or
        (cfg.gpu.driver == .auto and env != null and hasTuringNvidia(env.?));
    if (wants_nvidia) {
        accept = std.fmt.bufPrint(&nv_buf, "{s} NVIDIA", .{cfg.makeconf.accept_license}) catch cfg.makeconf.accept_license;
    }
    try w.print("ACCEPT_LICENSE=\"{s}\"\n", .{accept});

    if (!std.mem.eql(u8, cfg.makeconf.mirrors, "auto"))
        try w.print("GENTOO_MIRRORS=\"{s}\"\n", .{cfg.makeconf.mirrors})
    else
        try w.writeAll("# GENTOO_MIRRORS: auto (geoip pick at install time)\n");

    if (cfg.system.binhost)
        try w.writeAll("FEATURES=\"${FEATURES} getbinpkg\"\n");

    try w.writeAll("USE=\"${USE}");
    var it = cfg.use.global.iterator();
    while (it.next()) |kv| {
        const flag = kv.key_ptr.*;
        const on = switch (kv.value_ptr.*) {
            .boolean => |flag_on| flag_on,
            else => continue,
        };
        if (on) try w.print(" {s}", .{flag}) else try w.print(" -{s}", .{flag});
    }
    try w.writeAll("\"\n");
    return aw.written();
}

fn hasTuringNvidia(env: *const detect.Env) bool {
    for (env.gpus) |g| {
        if (std.mem.eql(u8, g.vendor, "nvidia") and detect.nvidiaIsTuringPlus(g)) return true;
    }
    return false;
}

fn packageUse(alloc: Allocator, cfg: *const Config) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    var it = cfg.use.pkg.iterator();
    while (it.next()) |kv| {
        const atom = kv.key_ptr.*;
        const flags = switch (kv.value_ptr.*) {
            .string => |fl| fl,
            else => continue,
        };
        try w.print("{s} {s}\n", .{ atom, flags });
    }
    // engine-managed entries (bootloader/kernel wiring)
    switch (config.resolveBootloader(cfg)) {
        .limine => try w.writeAll("sys-kernel/installkernel -systemd-boot -refind dracut\n"),
        .grub => try w.writeAll("sys-kernel/installkernel grub\n"),
        .@"systemd-boot" => try w.writeAll("sys-kernel/installkernel systemd-boot\n"),
        .efistub => try w.writeAll("sys-kernel/installkernel -systemd-boot\n"),
        else => {},
    }
    if (cfg.system.uki) try w.writeAll("sys-kernel/installkernel uki\n");
    return aw.written();
}

fn planPortage(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/portage/make.conf", try makeConf(alloc, cfg, env)));
    try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/portage/package.use/installer", try packageUse(alloc, cfg)));
    try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/portage/repos.conf/gentoo.conf", "[gentoo]\nlocation = /var/db/repos/gentoo\nsync-type = webrsync\n"));
    if (cfg.system.binhost)
        try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/portage/binrepos.conf/gentoobinhost.conf", s(alloc, "[gentoobinhost]\npriority = 9999\nsync-uri = https://distfiles.gentoo.org/releases/{s}/binpackages/23.0/x86-64/\n", .{@tagName(cfg.arch)})));
    return step(alloc, "portage-config", "Generate portage config", c);
}

fn planChroot(alloc: Allocator) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    for ([_][]const u8{ "/proc", "/sys", "/dev", "/run" }) |p|
        try c.append(alloc, argv(alloc, &.{ "mount", "--rbind", p, s(alloc, "/mnt/gentoo{s}", .{p}) }, s(alloc, "bind {s}", .{p})));
    try c.append(alloc, argv(alloc, &.{ "cp", "--dereference", "/etc/resolv.conf", "/mnt/gentoo/etc/" }, "dns into target"));
    try c.append(alloc, .{ .note = "subsequent chroot cmds run as: chroot /mnt/gentoo <cmd>" });
    return step(alloc, "enter-chroot", "Enter chroot", c);
}

fn planRepoSync(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    try c.append(alloc, .{ .exec = .{
        .argv = try alloc.dupe([]const u8, &.{ "emerge-webrsync" }),
        .chroot = true,
        .desc = "sync gentoo repo (webrsync; firewall-friendly)",
    } });
    if (cfg.system.binhost)
        try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "emerge", "--sync", "gentoobinhost" }),
            .chroot = true,
            .desc = "sync binhost index",
        } });
    return step(alloc, "repo-sync", "Sync portage tree", c);
}

fn planProfile(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    try c.append(alloc, .{ .exec = .{
        .argv = try alloc.dupe([]const u8, &.{ "eselect", "profile", "list" }),
        .chroot = true,
        .desc = "list profiles (resolve stem → profile name)",
    } });
    const prof = try profilePath(alloc, cfg);
    try c.append(alloc, .{ .exec = .{
        .argv = try alloc.dupe([]const u8, &.{ "eselect", "profile", "set", prof }),
        .chroot = true,
        .desc = s(alloc, "set profile {s}", .{prof}),
    } });
    return step(alloc, "profile", "Select portage profile", c);
}

fn planWorldUpdate(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(alloc, &.{ "emerge", "--verbose", "--update", "--deep", "--newuse", "@world" });
    if (cfg.system.binhost) try args.appendSlice(alloc, &.{ "--getbinpkg", "--binpkg-respect-use=n" });
    try c.append(alloc, .{ .exec = .{ .argv = args.items, .chroot = true, .desc = "world update" } });
    return step(alloc, "world-update", "Update @world", c);
}

fn planBaseConfig(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/timezone", cfg.system.timezone));
    // locale.gen
    var gen: std.Io.Writer.Allocating = .init(alloc);
    const gw = &gen.writer;
    for (cfg.system.locales) |l|
        try gw.print("{s} UTF-8\n", .{l});
    try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/locale.gen", gen.written()));
    try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "locale-gen" }), .chroot = true, .desc = "generate locales" } });
    try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "eselect", "locale", "set", cfg.system.locale }), .chroot = true, .desc = "default locale" } });
    // localectl needs a running systemd — write the config files directly.
    if (cfg.system.init == .systemd)
        try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/vconsole.conf", s(alloc, "KEYMAP={s}\n", .{cfg.system.keymap})))
    else
        try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/conf.d/keymaps", s(alloc, "keymap=\"{s}\"\n", .{cfg.system.keymap})));
    return step(alloc, "base-config", "Base system config", c);
}

fn planKernel(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    // firmware + microcode
    var fw_atoms: std.ArrayList([]const u8) = .empty;
    try fw_atoms.append(alloc, "sys-kernel/linux-firmware");
    try fw_atoms.append(alloc, "media-sound/sof-firmware");
    if (envNeedsIntelUcode(cfg)) try fw_atoms.append(alloc, "sys-firmware/intel-microcode");
    try c.append(alloc, .{ .exec = .{
        .argv = try prepend(alloc, "emerge", fw_atoms.items),
        .chroot = true,
        .desc = "firmware + CPU microcode",
    } });
    switch (cfg.system.kernel) {
        .@"dist-bin" => try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-kernel/gentoo-kernel-bin" }),
            .chroot = true,
            .desc = "prebuilt dist kernel",
        } }),
        .dist => try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-kernel/gentoo-kernel" }),
            .chroot = true,
            .desc = "dist kernel (compiled)",
        } }),
        .manual => try c.append(alloc, .{ .note = "manual kernel: emerge gentoo-sources + user config (expert flow)" }),
    }
    switch (cfg.system.initramfs) {
        .dracut => try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-kernel/dracut" }),
            .chroot = true,
            .desc = "dracut initramfs (early microcode on)",
        } }),
        .ugrd => try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-kernel/ugrd" }),
            .chroot = true,
            .desc = "ugrd initramfs",
        } }),
        .none => {},
    }
    // GPU driver packages
    switch (cfg.gpu.driver) {
        .@"nvidia-open" => try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "emerge", "x11-drivers/nvidia-drivers[kernel-open]" }),
            .chroot = true,
            .desc = "NVIDIA open kernel modules (Turing+)",
        } }),
        .@"nvidia-drivers" => try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "emerge", "x11-drivers/nvidia-drivers" }),
            .chroot = true,
            .desc = "NVIDIA proprietary drivers",
        } }),
        else => {},
    }
    return step(alloc, "firmware-kernel", "Firmware + kernel", c);
}

fn envNeedsIntelUcode(cfg: *const Config) bool {
    _ = cfg;
    return true; // detection refines at runtime; x86 hosts overwhelmingly intel/amd
}

fn prepend(alloc: Allocator, head: []const u8, tail: []const []const u8) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, tail.len + 1);
    out[0] = head;
    @memcpy(out[1..], tail);
    return out;
}

fn planFstab(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    const root = rootMountArgs(alloc, cfg);
    try w.writeAll("# generated by gentoo-installer (device paths; PARTUUID in M3)\n");
    try w.print("{s}\t/\t{s}\t{s}defaults\t0 1\n", .{ root.dev, @tagName(cfg.disk.root_fs), if (root.opts.len > 0) s(alloc, "{s},", .{root.opts}) else "" });
    if (cfg.boot_mode == .uefi)
        try w.print("{s}\t/efi\tvfat\tdefaults\t0 2\n", .{partPath(alloc, cfg.disk.device, 1)});
    if (cfg.disk.swap == .partition)
        try w.print("{s}\tnone\tswap\tsw\t0 0\n", .{partPath(alloc, cfg.disk.device, 2)});
    if (cfg.disk.swap == .zram)
        try w.writeAll("# zram swap configured via /etc/systemd/zram-generator.conf or OpenRC zram service\n");
    try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/fstab", aw.written()));
    return step(alloc, "fstab", "Generate fstab", c);
}

fn planSystemConfig(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/hostname", cfg.system.hostname));
    try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/hosts", s(alloc, "127.0.0.1 localhost\n::1 localhost\n127.0.1.1 {s}.local {s}\n", .{ cfg.system.hostname, cfg.system.hostname })));

    // root credential — the hash travels on stdin via chpasswd -e so it
    // never lands on argv (journal/ps-safe).
    if (cfg.root.password_hash) |h| {
        try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "chpasswd", "-e" }),
            .stdin = s(alloc, "root:{s}\n", .{h}),
            .stdin_label = "<root password hash>",
            .chroot = true,
            .desc = "set root password hash",
        } });
    }
    for (cfg.users) |u| {
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(alloc, &.{ "useradd", "-m", "-s", u.shell });
        if (u.groups.len > 0) {
            try args.append(alloc, "-G");
            try args.append(alloc, try std.mem.join(alloc, ",", u.groups));
        }
        try args.append(alloc, u.name);
        try c.append(alloc, .{ .exec = .{ .argv = args.items, .chroot = true, .desc = s(alloc, "create user {s}", .{u.name}) } });
        if (u.password_hash) |h|
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "chpasswd", "-e" }),
                .stdin = s(alloc, "{s}:{s}\n", .{ u.name, h }),
                .stdin_label = s(alloc, "<{s} password hash>", .{u.name}),
                .chroot = true,
                .desc = s(alloc, "set password for {s}", .{u.name}),
            } });
        if (u.ssh_authorized_keys.len > 0) {
            const home = s(alloc, "/home/{s}", .{u.name});
            const ssh_dir = s(alloc, "/mnt/gentoo{s}/.ssh", .{home});
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "install", "-d", "-m", "0700", "-o", u.name, "-g", u.name, s(alloc, "{s}/.ssh", .{home}) }),
                .chroot = true,
                .desc = s(alloc, "~{s}/.ssh", .{u.name}),
            } });
            try c.append(alloc, .{ .write_file = .{
                .path = s(alloc, "{s}/authorized_keys", .{ssh_dir}),
                .content = try std.mem.join(alloc, "\n", u.ssh_authorized_keys),
                .mode = 0o600,
            } });
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "chown", "-R", s(alloc, "{s}:{s}", .{ u.name, u.name }), s(alloc, "{s}/.ssh", .{home}) }),
                .chroot = true,
                .desc = s(alloc, "~{s}/.ssh ownership", .{u.name}),
            } });
        }
    }

    switch (cfg.system.privilege) {
        .doas => {
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "app-admin/doas" }), .chroot = true, .desc = "doas" } });
            try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/doas.conf", "permit persist :wheel\n"));
        },
        .sudo => {
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "app-admin/sudo" }), .chroot = true, .desc = "sudo" } });
            try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/sudoers.d/wheel", "%wheel ALL=(ALL:ALL) ALL\n"));
        },
        .none => {},
    }

    // zram swap config
    if (cfg.disk.swap == .zram) {
        if (cfg.system.init == .systemd)
            try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/systemd/zram-generator.conf", "[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = zstd\n"))
        else
            try c.append(alloc, .{ .note = "zram via sys-apps/zram-service or init script (per init backend)" });
    }
    return step(alloc, "system-config", "System config", c);
}

fn planServices(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    const init = cfg.system.init;

    var svc_atoms: std.ArrayList([]const u8) = .empty;
    if (cfg.network.manager == .networkmanager) try svc_atoms.append(alloc, "net-misc/networkmanager");
    if (cfg.network.manager == .dhcpcd) try svc_atoms.append(alloc, "net-misc/dhcpcd");
    if (cfg.services.cron) try svc_atoms.append(alloc, "sys-process/cronie");
    if (cfg.services.ntp) try svc_atoms.append(alloc, "net-misc/chrony");
    if (cfg.services.sshd) try svc_atoms.append(alloc, "net-misc/openssh");
    if (cfg.services.logger and init != .systemd) try svc_atoms.append(alloc, "app-admin/sysklogd");
    if (svc_atoms.items.len > 0)
        try c.append(alloc, .{ .exec = .{
            .argv = try prepend(alloc, "emerge", svc_atoms.items),
            .chroot = true,
            .desc = "service packages",
        } });

    const Enable = struct { name: []const u8, runlevel: []const u8 };
    var enables: std.ArrayList(Enable) = .empty;
    switch (cfg.network.manager) {
        .networkmanager => try enables.append(alloc, .{ .name = "NetworkManager", .runlevel = "default" }),
        .dhcpcd => try enables.append(alloc, .{ .name = "dhcpcd", .runlevel = "default" }),
        else => {},
    }
    if (cfg.services.ntp) try enables.append(alloc, .{ .name = if (init == .systemd) "systemd-timesyncd" else "chronyd", .runlevel = "default" });
    if (cfg.services.cron) try enables.append(alloc, .{ .name = "cronie", .runlevel = "default" });
    if (cfg.services.sshd) try enables.append(alloc, .{ .name = "sshd", .runlevel = "default" });
    if (cfg.services.logger and init != .systemd) try enables.append(alloc, .{ .name = "sysklogd", .runlevel = "default" });

    for (enables.items) |e| {
        switch (init) {
            .systemd => try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "systemctl", "enable", e.name }), .chroot = true, .desc = s(alloc, "enable {s}", .{e.name}) } }),
            .openrc => try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "rc-update", "add", e.name, e.runlevel }), .chroot = true, .desc = s(alloc, "rc-update {s}", .{e.name}) } }),
            .runit => try c.append(alloc, .{ .note = s(alloc, "runit: ln -s /etc/sv/{s} /run/runit/service/", .{e.name}) }),
            .s6 => try c.append(alloc, .{ .note = s(alloc, "s6-rc: add {s} to default bundle", .{e.name}) }),
            .dinit => try c.append(alloc, .{ .note = s(alloc, "dinit: enable {s}.d service link", .{e.name}) }),
        }
    }
    return step(alloc, "services", "Enable services", c);
}

fn planBootloader(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    const bl = config.resolveBootloader(cfg);
    switch (bl) {
        .limine => {
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-boot/limine" }),
                .chroot = true,
                .desc = "limine",
            } });
            if (cfg.boot_mode == .uefi) {
                try c.append(alloc, .{ .exec = .{
                    .argv = try alloc.dupe([]const u8, &.{ "mkdir", "-p", "/efi/EFI/BOOT" }),
                    .chroot = true,
                    .desc = "ESP layout",
                } });
                try c.append(alloc, .{ .exec = .{
                    .argv = try alloc.dupe([]const u8, &.{ "cp", "/usr/share/limine/BOOTX64.EFI", "/efi/EFI/BOOT/" }),
                    .chroot = true,
                    .desc = "limine EFI binary (amd64)",
                } });
            } else {
                try c.append(alloc, argv(alloc, &.{ "limine", "bios-install", cfg.disk.device }, "limine BIOS stages"));
            }
            try c.append(alloc, wf(alloc, "/mnt/gentoo/efi/limine.conf", limineConf(alloc, cfg)));
            // kernel-install hook: stage kernel+initramfs at the fixed ESP
            // paths limine.conf references. installkernel invokes this on
            // every kernel add/remove — upgrades stay seamless.
            try c.append(alloc, .{ .write_file = .{
                .path = "/mnt/gentoo/etc/kernel/install.d/91-limine.install",
                .content =
                \\#!/bin/sh
                \\# gentoo-installer limine hook (kernel-install): stage
                \\# kernel + initramfs at the fixed ESP paths limine.conf uses.
                \\# args: $1=command $2=kver $3=entry_dir_abs $4=kernel_image
                \\[ "$1" = add ] || exit 0
                \\esp=/efi
                \\cp -f "$4" "$esp/vmlinuz" || exit 1
                \\initrd=$(ls -t /boot/initramfs-*.img /boot/initrd-*.img /boot/initrd-* 2>/dev/null | head -n1)
                \\[ -n "$initrd" ] && cp -f "$initrd" "$esp/initramfs.img"
                \\exit 0
                ,
                .mode = 0o755,
            } });
        }, 
        .grub => {
            var grub_args: std.ArrayList([]const u8) = .empty;
            try grub_args.appendSlice(alloc, &.{ "emerge", "sys-boot/grub" });
            try c.append(alloc, .{ .exec = .{ .argv = grub_args.items, .chroot = true, .desc = "grub" } });
            const target = if (cfg.boot_mode == .uefi) "efi" else "i386-pc";
            if (cfg.boot_mode == .uefi)
                try c.append(alloc, .{ .exec = .{
                    .argv = try alloc.dupe([]const u8, &.{ "grub-install", "--target=x86_64-efi", "--efi-directory=/efi" }),
                    .chroot = true,
                    .desc = "grub-install UEFI",
                } })
            else
                try c.append(alloc, .{ .exec = .{
                    .argv = try alloc.dupe([]const u8, &.{ "grub-install", s(alloc, "--target={s}", .{target}), cfg.disk.device }),
                    .chroot = true,
                    .desc = "grub-install BIOS",
                } });
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "grub-mkconfig", "-o", "/boot/grub/grub.cfg" }),
                .chroot = true,
                .desc = "grub.cfg (os-prober merges other OSes)",
            } });
        },
        .@"systemd-boot" => try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "bootctl", "install" }),
            .chroot = true,
            .desc = "systemd-boot (UEFI only)",
        } }),
        .efistub => try c.append(alloc, .{ .note = "efistub: kernels boot via firmware NVRAM entries (efibootmgr)" }),
        .refind => try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-boot/refind" }),
            .chroot = true,
            .desc = "rEFInd (UEFI)",
        } }),
        .auto => unreachable,
    }

    // Secure boot: sign every boot binary with the locally-generated key.
    switch (cfg.security.secure_boot) {
        .sbctl => {
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "emerge", "app-crypt/sbctl" }),
                .chroot = true,
                .desc = "sbctl (secure boot key mgmt)",
            } });
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sbctl", "create-keys" }),
                .chroot = true,
                .desc = "generate secure boot keys",
            } });
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", "for f in /efi/EFI/BOOT/*.EFI /efi/vmlinuz /efi/initramfs.img /efi/EFI/Linux/*.efi; do [ -f \"$f\" ] && sbctl sign -s \"$f\"; done; true" }),
                .chroot = true,
                .desc = "sign bootloader + kernels (sbctl)",
            } });
        },
        .shim => try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-boot/shim", "app-crypt/sbsigntools" }),
            .chroot = true,
            .desc = "shim + sbsigntools (secure boot)",
        } }),
        .off => {},
    }
    return step(alloc, "bootloader", "Install bootloader", c);
}

/// stem → eselect profile path: `default/linux/{arch}/23.0/` + stem
/// segments joined with `/` (nomultilib → no-multilib).
fn profilePath(alloc: Allocator, cfg: *const Config) ![]const u8 {
    const stem = try config.stage3Stem(alloc, cfg);
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, stem, '-');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "nomultilib")) {
            try out.append(alloc, "no-multilib");
        } else if (std.mem.eql(u8, seg, "usr") and out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1], "split")) {
            out.items[out.items.len - 1] = "split-usr";
        } else {
            try out.append(alloc, seg);
        }
    }
    const joined = try std.mem.join(alloc, "/", out.items);
    return s(alloc, "default/linux/{s}/23.0/{s}", .{ @tagName(cfg.arch), joined });
}

fn limineConf(alloc: Allocator, cfg: *const Config) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    w.writeAll("# generated by gentoo-installer\n") catch {};
    w.writeAll("timeout: 5\n\n") catch {};
    const root_args = s(alloc, "root={s}", .{fsDevice(alloc, cfg)});
    w.print("/Gentoo\n", .{}) catch {};
    w.writeAll("    protocol: linux\n") catch {};
    w.writeAll("    kernel_path: boot:///vmlinuz\n") catch {};
    w.writeAll("    module_path: boot:///initramfs.img\n") catch {};
    w.print("    cmdline: {s} rootfstype={s}\n", .{ root_args, @tagName(cfg.disk.root_fs) }) catch {};
    w.writeAll("\n# snapshot entries are appended by the kernel-install hook\n") catch {};
    return aw.written();
}

fn planFinish(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    if (cfg.root.lock_root)
        try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "passwd", "-l", "root" }),
            .chroot = true,
            .desc = "lock root password login",
        } });
    if (cfg.system.snapshots == .auto and cfg.disk.root_fs == .btrfs)
        try c.append(alloc, .{ .note = "btrfs @snapshots subvol is ready for pre-emerge hooks" });
    if (cfg.system.snapshots == .auto and cfg.disk.lvm)
        try c.append(alloc, .{ .note = "LVM thin pool 'tank' provisioned for snapshots" });
    try c.append(alloc, argv(alloc, &.{ "rm", "-f", "/mnt/gentoo/stage3-*.tar.xz" }, "cleanup stage3 artifacts"));
    try c.append(alloc, .{ .note = "unmount + reboot prompt" });
    return step(alloc, "finish", "Finish", c);
}

test "golden plan: uefi + luks + lvm + btrfs + limine" {
    const toml_mod = @import("toml.zig");
    const doc_src =
        \\arch = "amd64"
        \\boot_mode = "uefi"
        \\[disk]
        \\device = "/dev/vda"
        \\scheme = "efi-swap-root"
        \\root_fs = "btrfs"
        \\swap = "zram"
        \\luks = true
        \\lvm = true
        \\[stage3]
        \\libc = "glibc"
        \\toolchain = "gcc"
        \\[system]
        \\init = "systemd"
        \\hostname = "goldbox"
        \\kernel = "dist-bin"
        \\[[users]]
        \\name = "larry"
        \\groups = ["wheel"]
        \\password_hash = "$6$xyz"
    ;
    var doc = try toml_mod.parse(std.testing.allocator, doc_src, null);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cfg = try config.decode(alloc, doc);
    const plan = try build(alloc, &cfg, null);

    const expected_ids = [_][]const u8{
        "detect",       "partition",      "mount",          "stage3",
        "portage-config", "enter-chroot", "repo-sync",      "profile",
        "world-update", "base-config",    "firmware-kernel", "fstab",
        "system-config", "services",      "bootloader",     "finish",
    };
    try std.testing.expectEqual(expected_ids.len, plan.steps.len);
    for (expected_ids, plan.steps) |id, st| try std.testing.expectEqualStrings(id, st.id);

    const part_cmds = plan.steps[1].cmds;
    try std.testing.expectEqualStrings("sgdisk", part_cmds[0].exec.argv[0]);
    try std.testing.expectEqualStrings("--zap-all", part_cmds[0].exec.argv[1]);
    // LUKS passphrase travels on stdin, never argv.
    var saw_keyfile_stdin = false;
    for (part_cmds) |cmd| {
        if (cmd == .exec and std.mem.eql(u8, cmd.exec.argv[0], "cryptsetup"))
            saw_keyfile_stdin = saw_keyfile_stdin or (cmd.exec.stdin_label != null);
    }
    try std.testing.expect(saw_keyfile_stdin);

    // ESP is raw (never LUKS/LVM): mkfs.vfat targets the partition, not a mapper.
    var saw_esp = false;
    for (part_cmds) |cmd| {
        if (cmd == .exec and std.mem.startsWith(u8, cmd.exec.argv[0], "mkfs.vfat")) {
            saw_esp = true;
            try std.testing.expectEqualStrings("/dev/vda1", cmd.exec.argv[cmd.exec.argv.len - 1]);
        }
    }
    try std.testing.expect(saw_esp);

    // bootloader step emits a limine.conf write_file.
    var saw_limine = false;
    for (plan.steps[14].cmds) |cmd| {
        if (cmd == .write_file and std.mem.endsWith(u8, cmd.write_file.path, "limine.conf"))
            saw_limine = true;
    }
    try std.testing.expect(saw_limine);
}
