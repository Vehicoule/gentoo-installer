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
pub const Sets = struct {
    atoms: []const []const u8 = &.{},
    repos: []const []const u8 = &.{},
};

pub fn build(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env, pkg_sets: Sets) !Plan {
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
    try steps.append(alloc, try planKernel(alloc, cfg, env));
    try steps.append(alloc, try planFstab(alloc, cfg));
    try steps.append(alloc, try planSystemConfig(alloc, cfg));
    try steps.append(alloc, try planServices(alloc, cfg, env));
    try steps.append(alloc, try planPackages(alloc, cfg, pkg_sets));
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
    var boot_part: ?[]const u8 = null;
    if (d.boot_part) {
        n += 1;
        boot_part = partPath(alloc, dev, n);
        try c.append(alloc, argv(alloc, &.{ "sgdisk", s(alloc, "-n{}:0:+1024MiB", .{n}), s(alloc, "-t{}:8300", .{n}), s(alloc, "-c{}:boot", .{n}), dev }, s(alloc, "boot partition 1GiB at partition {}", .{n})));
    }
    n += 1;
    const root_part = partPath(alloc, dev, n);
    // 8304 = Linux root DPS GUID (auto-discovery on systemd)
    try c.append(alloc, argv(alloc, &.{ "sgdisk", s(alloc, "-n{}:0:0", .{n}), s(alloc, "-t{}:8304", .{n}), s(alloc, "-c{}:root", .{n}), dev }, s(alloc, "root partition {} (rest of disk)", .{n})));
    // Separate /home is an LVM thin LV (or a btrfs @home subvol), never a
    // standalone partition — validation enforces that pairing.
    _ = d.home_part;

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
            // Thin LVs take -V (virtual size); for a thin LV, %FREE means
            // a share of the thin POOL's free space — give root 70% when
            // a home LV follows, else the whole pool (overcommit is
            // intended: caps are soft, the pool is 95% of the VG).
            const root_pct = if (d.home_part and d.root_fs != .btrfs) "70%FREE" else "100%FREE";
            try c.append(alloc, argv(alloc, &.{ "lvcreate", "-V", root_pct, "-T", "vg0/tank", "-n", "root" }, "thin root LV"));
            if (d.home_part and d.root_fs != .btrfs) {
                try c.append(alloc, argv(alloc, &.{ "lvcreate", "-V", "100%FREE", "-T", "vg0/tank", "-n", "home" }, "thin home LV (remaining pool)"));
                try c.append(alloc, argv(alloc, &.{ s(alloc, "mkfs.{s}", .{@tagName(d.root_fs)}), "/dev/vg0/home" }, "format home LV"));
            }
        } else {
            try c.append(alloc, argv(alloc, &.{ "lvcreate", "-l", "70%VG", "-n", "root", "vg0" }, "linear root LV (70% VG)"));
            if (d.home_part and d.root_fs != .btrfs) {
                try c.append(alloc, argv(alloc, &.{ "lvcreate", "-l", "100%FREE", "-n", "home", "vg0" }, "linear home LV (rest of VG)"));
                try c.append(alloc, argv(alloc, &.{ s(alloc, "mkfs.{s}", .{@tagName(d.root_fs)}), "/dev/vg0/home" }, "format home LV"));
            }
        }
        fs_dev = "/dev/vg0/root";
    }

    const mk = mkfsTool(d.root_fs);
    var mkfs_argv: std.ArrayList([]const u8) = .empty;
    try mkfs_argv.append(alloc, mk.mkfs);
    try mkfs_argv.append(alloc, fs_dev);
    try c.append(alloc, fmtArgv(alloc, s(alloc, "format root as {s}", .{@tagName(d.root_fs)}), mkfs_argv.items));

    if (boot_part) |bp|
        try c.append(alloc, argv(alloc, &.{ "mkfs.ext4", "-L", "boot", bp }, "format /boot as ext4"));

    if (swap_part) |sp|
        try c.append(alloc, argv(alloc, &.{ "mkswap", "-L", "swap", sp }, "format swap"));

    if (d.root_fs == .btrfs) {
        // Mount then create the subvol layout + @snapshots dir.
        try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo" }, "target mountpoint"));
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
/// Kernel command line shared by every bootloader backend.
///
/// Shell fragment staging the newest initramfs onto the boot volume —
/// empty when initramfs=none so a validated no-initramfs config doesn't
/// fail the step.
fn initrdStage(alloc: Allocator, cfg: *const Config, dir: []const u8) []const u8 {
    if (cfg.system.initramfs == .none) return "";
    return s(alloc,
        "i=$(ls -t /boot/initramfs-*.img /boot/initrd-*.img 2>/dev/null | head -n1); " ++
        "[ -n \"$i\" ] || {{ echo 'no initramfs to stage' >&2; exit 1; }}; " ++
        "cp -f \"$i\" {s}/initramfs.img", .{dir});
}
fn kernelArgs(alloc: Allocator, cfg: *const Config) []const u8 {
    var r = s(alloc, "root={s}", .{fsDevice(alloc, cfg)});
    // btrfs: install mounted subvol=@root — boot must select it too.
    if (cfg.disk.root_fs == .btrfs)
        r = s(alloc, "{s} rootflags=subvol=@root", .{r});
    // LUKS: dracut unlocks via crypttab/rd.luks at initramfs time.
    if (cfg.disk.luks)
        r = s(alloc, "{s} rd.luks=1", .{r});
    return s(alloc, "{s} rootfstype={s}", .{ r, @tagName(cfg.disk.root_fs) });
}

pub fn fsDevice(alloc: Allocator, cfg: *const Config) []const u8 {
    if (cfg.disk.lvm) return "/dev/vg0/root";
    if (cfg.disk.luks) return "/dev/mapper/cryptroot";
    // root partition is the last numbered one created
    var n: u32 = 1; // esp (uefi) or biosboot (bios)
    if (cfg.disk.swap == .partition) n += 1;
    if (cfg.disk.boot_part) n += 1;
    n += 1;
    return partPath(alloc, cfg.disk.device, n);
}

/// Partition index of the separate /boot partition, if configured.
fn bootPartIdx(cfg: *const Config) u32 {
    var n: u32 = 1; // esp/biosboot
    if (cfg.disk.swap == .partition) n += 1;
    return n + 1;
}

fn planMount(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    const root = rootMountArgs(alloc, cfg);
    try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo" }, "target mountpoint"));
    if (root.opts.len > 0)
        try c.append(alloc, argv(alloc, &.{ "mount", "-o", root.opts, root.dev, "/mnt/gentoo" }, "mount root"))
    else
        try c.append(alloc, argv(alloc, &.{ "mount", root.dev, "/mnt/gentoo" }, "mount root"));

    if (cfg.disk.boot_part) {
        try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo/boot" }, "/boot mountpoint"));
        try c.append(alloc, argv(alloc, &.{ "mount", partPath(alloc, cfg.disk.device, bootPartIdx(cfg)), "/mnt/gentoo/boot" }, "mount /boot"));
    }

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
    // LVM thin home LV (non-btrfs roots only).
    if (cfg.disk.lvm and cfg.disk.home_part and cfg.disk.root_fs != .btrfs) {
        try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo/home" }, "/home mountpoint"));
        try c.append(alloc, argv(alloc, &.{ "mount", "/dev/vg0/home", "/mnt/gentoo/home" }, "mount home LV"));
    }
    // btrfs: mount the home + snapshots subvolumes created earlier.
    if (cfg.disk.root_fs == .btrfs) {
        const dev = root.dev;
        try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo/home", "/mnt/gentoo/.snapshots" }, "subvol mountpoints"));
        try c.append(alloc, argv(alloc, &.{ "mount", "-o", "subvol=@home,compress=zstd:1,noatime", dev, "/mnt/gentoo/home" }, "mount @home"));
        try c.append(alloc, argv(alloc, &.{ "mount", "-o", "subvol=@snapshots,compress=zstd:1,noatime", dev, "/mnt/gentoo/.snapshots" }, "mount @snapshots"));
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
    // Resolve filename from the pointer, fetch tarball+signature+digests.
    // latest.txt entries may carry a dated subdir (2026…/stage3-….tar.xz):
    // use the full path in the URL but save locally under the basename.
    try c.append(alloc, .{ .exec = .{
        .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc,
            "f=$(grep -oE '[^ ]*stage3-[^ ]*\\.tar\\.xz' /tmp/latest.txt | head -n1); " ++
            "test -n \"$f\" || exit 1; b=${{f##*/}}; " ++
            "curl -fsSL -o \"/tmp/$b\" '{s}/'$f && " ++
            "curl -fsSL -o \"/tmp/$b.asc\" '{s}/'$f.asc && " ++
            "curl -fsSL -o /tmp/stage3.DIGESTS '{s}/'$f.DIGESTS && " ++
            "ln -sf \"$b\" /tmp/stage3.tar.xz && ln -sf \"$b.asc\" /tmp/stage3.tar.xz.asc",
            .{ base, base, base }) }),
        .desc = "download stage3 tarball + .asc + .DIGESTS (resolved from latest.txt)",
    } });
    // --verify needs the Gentoo release key in the keyring — live media
    // ship it under openpgp-keys; fall back to keyserver fetch of the
    // pinned Release Engineering fingerprint.
    try c.append(alloc, .{ .exec = .{
        .argv = try alloc.dupe([]const u8, &.{ "sh", "-c",
            "gpg --import /usr/share/openpgp-keys/gentoo-release.asc 2>/dev/null || " ++
            "gpg --keyserver hkps://keys.gentoo.org --recv-keys 13EBBDBEDE7A12775DFDB1BABB572E0E2D182910" }),
        .desc = "import Gentoo release signing key (pinned fingerprint fallback)",
    } });
    try c.append(alloc, argv(alloc, &.{ "gpg", "--verify", "/tmp/stage3.tar.xz.asc", "/tmp/stage3.tar.xz" }, "GPG-verify stage3"));
    // DIGESTS mixes SHA256/SHA512/WHIRLPOOL lines — extract our tarball's
    // SHA256 entry and refuse vacuous success when it is absent.
    try c.append(alloc, .{ .exec = .{
        .argv = try alloc.dupe([]const u8, &.{ "sh", "-c",
            "b=$(basename \"$(readlink -f /tmp/stage3.tar.xz)\"); " ++
            "awk -v f=\"$b\" '$2 == f && length($1) == 64' /tmp/stage3.DIGESTS > /tmp/stage3.sha256; " ++
            "test -s /tmp/stage3.sha256 || { echo 'no SHA256 digest entry for stage3' >&2; exit 1; }; " ++
            "(cd /tmp && sha256sum -c /tmp/stage3.sha256)" }),
        .desc = "digest-verify stage3 (SHA256 entry for the tarball)",
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
        jobs = 4; // conservative fallback without detection
        if (env) |e| {
            // ~2 GiB per emerge job, bounded by core count and mem_cap.
            const by_ram: u32 = @intCast(@max(e.ram_mib / 2048, 1));
            jobs = @max(1, @min(e.cpu_count, by_ram));
            if (cfg.makeconf.mem_cap_gib > 0)
                jobs = @max(1, @min(jobs, cfg.makeconf.mem_cap_gib / 2));
        }
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
    const drv = resolveGpuDriver(cfg, env);
    const wants_nvidia = drv == .@"nvidia-open" or drv == .@"nvidia-drivers";
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
    if (cfg.system.binhost) {
        // Gentoo ships binhosts per arch+ABI dir; riscv64 has none.
        // arch==detect is unreachable in real flows (main resolves it
        // from detection) but reachable from tests with env=null.
        if (cfg.arch == .detect) {
            try c.append(alloc, .{ .note = "binhost sync-uri resolved after hardware detection" });
        } else {
        const abi_dir = switch (cfg.arch) {
            .amd64 => "x86-64",
            .arm64 => "arm64",
            .riscv64, .detect => unreachable, // validate() rejects binhost on riscv64
        };
        try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/portage/binrepos.conf/gentoobinhost.conf", s(alloc, "[gentoobinhost]\npriority = 9999\nsync-uri = https://distfiles.gentoo.org/releases/{s}/binpackages/23.0/{s}/\n", .{ @tagName(cfg.arch), abi_dir })));
        }
    }
    // LUKS root: crypttab names the GPT partlabel (-cN:root). Written here
    // — before the kernel emerge — so installkernel's initramfs generation
    // (dracut --hostonly) picks it up.
    if (cfg.disk.luks)
        try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/crypttab", "cryptroot /dev/disk/by-partlabel/root none luks\n"));
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

fn planKernel(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    // firmware + microcode
    var fw_atoms: std.ArrayList([]const u8) = .empty;
    try fw_atoms.append(alloc, "sys-kernel/linux-firmware");
    try fw_atoms.append(alloc, "media-sound/sof-firmware");
    if (ucodeAtom(cfg, env)) |atom| try fw_atoms.append(alloc, atom);
    try c.append(alloc, .{ .exec = .{
        .argv = try prepend(alloc, "emerge", fw_atoms.items),
        .chroot = true,
        .desc = "firmware + CPU microcode",
    } });
    // The initramfs generator must exist before the kernel emerges —
    // the kernel package's installkernel hooks call it.
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
    // GPU driver packages — resolve `auto` the same way make.conf's
    // VIDEO_CARDS / ACCEPT_LICENSE do (Turing+ → nvidia-open).
    switch (resolveGpuDriver(cfg, env)) {
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

/// gpu.driver=auto resolves once against detected hardware: a
/// Turing-or-newer NVIDIA GPU gets the open kernel modules, anything
/// else falls back to nouveau (in-kernel; nothing to emerge).
pub fn resolveGpuDriver(cfg: *const Config, env: ?*const detect.Env) config.GpuDriver {
    if (cfg.gpu.driver != .auto) return cfg.gpu.driver;
    if (env) |e| if (hasTuringNvidia(e)) return .@"nvidia-open";
    return .nouveau;
}

// Microcode emerges only on amd64 — arm64/riscv64 get it via
// linux-firmware; on AMD hosts linux-firmware already carries amd-ucode,
// so a separate package is needed only for Intel.
fn ucodeAtom(cfg: *const Config, env: ?*const detect.Env) ?[]const u8 {
    if (cfg.arch != .amd64) return null;
    if (env) |e| {
        if (std.mem.eql(u8, e.cpu_vendor, "AuthenticAMD")) return null;
    }
    return "sys-firmware/intel-microcode";
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
    if (cfg.disk.boot_part)
        try w.print("{s}\t/boot\text4\tdefaults\t0 2\n", .{partPath(alloc, cfg.disk.device, bootPartIdx(cfg))});
    if (cfg.disk.lvm and cfg.disk.home_part and cfg.disk.root_fs != .btrfs)
        try w.print("/dev/vg0/home\t/home\t{s}\tdefaults\t0 2\n", .{@tagName(cfg.disk.root_fs)});
    if (cfg.disk.root_fs == .btrfs) {
        try w.print("{s}\t/home\tbtrfs\tsubvol=@home,compress=zstd:1,noatime\t0 2\n", .{root.dev});
        try w.print("{s}\t/.snapshots\tbtrfs\tsubvol=@snapshots,compress=zstd:1,noatime\t0 2\n", .{root.dev});
    }
    if (cfg.disk.swap == .zram)
        try w.writeAll("# zram swap configured via /etc/systemd/zram-generator.conf or OpenRC zram service\n");
    try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/fstab", aw.written()));
    // crypttab is written in planPortage — the kernel emerge's
    // installkernel hook bakes it into the initramfs; writing it in this
    // step would be too late.
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

    // zram swap: install the backend the config file needs.
    if (cfg.disk.swap == .zram) {
        switch (cfg.system.init) {
            .systemd => {
                try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-apps/zram-generator" }), .chroot = true, .desc = "zram-generator" } });
                try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/systemd/zram-generator.conf", "[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = zstd\n"));
            },
            .openrc => {
                try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-apps/zram-init" }), .chroot = true, .desc = "zram-init" } });
                // zram-init sizes use its `lram` expression var (RAM in MiB),
                // not the zram-generator `ram` spelling.
                try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/conf.d/zram-init", "num_devices=1\ntype0=swap\nsize0=min(lram / 2, 8192)\ncompr0=zstd\n"));
                try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "rc-update", "add", "zram-init", "boot" }), .chroot = true, .desc = "enable zram-init" } });
            },
            else => try c.append(alloc, .{ .note = "zram on this init lands with its backend in M6" }),
        }
    }
    return step(alloc, "system-config", "System config", c);
}

fn planServices(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    const init = cfg.system.init;

    var svc_atoms: std.ArrayList([]const u8) = .empty;
    if (cfg.network.manager == .networkmanager) try svc_atoms.append(alloc, "net-misc/networkmanager");
    if (cfg.network.manager == .dhcpcd) try svc_atoms.append(alloc, "net-misc/dhcpcd");
    if (cfg.services.cron) try svc_atoms.append(alloc, "sys-process/cronie");
    if (cfg.services.ntp) try svc_atoms.append(alloc, "net-misc/chrony");
    if (cfg.services.sshd) try svc_atoms.append(alloc, "net-misc/openssh");
    if (cfg.services.logger and init != .systemd) try svc_atoms.append(alloc, "app-admin/sysklogd");
    // wifi needs a supplicant — iwd is the lean default backend.
    if (cfg.network.wifi) try svc_atoms.append(alloc, "net-wireless/iwd");
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
        // netifrc: emerge the package, then link + enable a net.<nic>
        // unit per detected interface (predictable names like enp1s0).
        .netifrc => {
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "emerge", "net-misc/netifrc" }),
                .chroot = true,
                .desc = "netifrc",
            } });
            if (env != null and env.?.nics.len > 0) {
                var netconf: std.Io.Writer.Allocating = .init(alloc);
                for (env.?.nics) |nic| {
                    try netconf.writer.print("config_{s}=\"dhcp\"\n", .{nic});
                    try c.append(alloc, .{ .exec = .{
                        .argv = try alloc.dupe([]const u8, &.{ "ln", "-sf", "net.lo", s(alloc, "/etc/init.d/net.{s}", .{nic}) }),
                        .chroot = true,
                        .desc = s(alloc, "netifrc net.{s} unit link", .{nic}),
                    } });
                    try enables.append(alloc, .{ .name = s(alloc, "net.{s}", .{nic}), .runlevel = "default" });
                }
                try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/conf.d/net", netconf.written()));
            } else {
                try c.append(alloc, .{ .note = "netifrc: no NICs detected — enable net.<iface> for each interface" });
            }
        },
        // systemd-networkd: enable the daemons + resolved stub resolv.conf.
        .@"systemd-networkd" => {
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "systemctl", "enable", "systemd-networkd.service", "systemd-resolved.service" }),
                .chroot = true,
                .desc = "enable networkd + resolved",
            } });
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "ln", "-sf", "../run/systemd/resolve/stub-resolv.conf", "/etc/resolv.conf" }),
                .chroot = true,
                .desc = "resolved stub resolv.conf",
            } });
            // A .network unit — the daemons alone configure nothing.
            var netw: std.Io.Writer.Allocating = .init(alloc);
            try netw.writer.writeAll("[Match]\nName=");
            if (env != null and env.?.nics.len > 0) {
                for (env.?.nics) |nic| try netw.writer.print("{s} ", .{nic});
            } else {
                try netw.writer.writeAll("*");
            }
            try netw.writer.writeAll("\n[Network]\nDHCP=yes\n");
            try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/systemd/network/20-installer.network", netw.written()));
        },
    }
    if (cfg.services.ntp) try enables.append(alloc, .{ .name = if (init == .systemd) "systemd-timesyncd" else "chronyd", .runlevel = "default" });
    if (cfg.services.cron) try enables.append(alloc, .{ .name = "cronie", .runlevel = "default" });
    if (cfg.services.sshd) try enables.append(alloc, .{ .name = "sshd", .runlevel = "default" });
    if (cfg.services.logger and init != .systemd) try enables.append(alloc, .{ .name = "sysklogd", .runlevel = "default" });

    // Alt-init packages: the stage3 is OpenRC-flavoured, so the chosen
    // init is installed on top. Service-level migration (sv dirs, dinit
    // links) lands with the init backends in M6.
    switch (init) {
        .dinit => try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-process/dinit" }), .chroot = true, .desc = "dinit package (service migration is M6)" } }),
        .runit => try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-process/runit" }), .chroot = true, .desc = "runit package (service migration is M6)" } }),
        .s6 => try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-apps/s6", "sys-apps/s6-rc" }), .chroot = true, .desc = "s6 + s6-rc packages (service migration is M6)" } }),
        else => {},
    }

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

/// packages step: preset-resolved sets + config atoms actually emerge.
fn planPackages(alloc: Allocator, cfg: *const Config, sets: Sets) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    // overlay repos a set asked for (e.g. cosmic) — enable + sync first.
    for (sets.repos) |repo| {
        try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "eselect", "repository", "enable", repo }),
            .chroot = true,
            .desc = s(alloc, "enable {s} overlay", .{repo}),
        } });
        try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "emerge", "--sync", repo }),
            .chroot = true,
            .desc = s(alloc, "sync {s} overlay", .{repo}),
        } });
    }
    var atoms: std.ArrayList([]const u8) = .empty;
    try atoms.appendSlice(alloc, sets.atoms);
    try atoms.appendSlice(alloc, cfg.packages.atoms);
    if (atoms.items.len > 0)
        try c.append(alloc, .{ .exec = .{
            .argv = try prepend(alloc, "emerge", try alloc.dupe([]const u8, atoms.items)),
            .chroot = true,
            .desc = "package sets + extra atoms",
        } });
    if (c.items.len == 0)
        try c.append(alloc, .{ .note = "no extra packages" });
    return step(alloc, "packages", "Install packages", c);
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
                    .argv = try alloc.dupe([]const u8, &.{ "cp", s(alloc, "/usr/share/limine/{s}", .{efiBootFile(cfg)}), "/efi/EFI/BOOT/" }),
                    .chroot = true,
                    .desc = s(alloc, "limine EFI binary ({s})", .{efiBootFile(cfg)}),
                } });
            } else {
                try c.append(alloc, argv(alloc, &.{ "limine", "bios-install", cfg.disk.device }, "limine BIOS stages"));
            }
            // Limine's boot volume: the ESP under UEFI, /boot under BIOS
            // (a separate ext4 partition when disk.boot_part, else the
            // root fs — validation restricts bare-root BIOS to ext4).
            const stage_dir = if (cfg.boot_mode == .uefi) "/efi" else "/boot";
            try c.append(alloc, wf(alloc, s(alloc, "/mnt/gentoo{s}/limine.conf", .{stage_dir}), limineConf(alloc, cfg)));
            // kernel-install hook: stage kernel+initramfs at the fixed
            // paths limine.conf references. installkernel invokes this on
            // every kernel add/remove — upgrades stay seamless.
            try c.append(alloc, .{ .write_file = .{
                .path = "/mnt/gentoo/etc/kernel/install.d/91-limine.install",
                .content = s(alloc,
                    \\#!/bin/sh
                    \\# gentoo-installer limine hook (kernel-install): stage
                    \\# kernel + initramfs at the fixed boot paths limine.conf uses.
                    \\# args: $1=command $2=kver $3=entry_dir_abs $4=kernel_image
                    \\[ "$1" = add ] || exit 0
                    \\esp={s}
                    \\cp -f "$4" "$esp/vmlinuz" || exit 1
                    \\initrd=$(ls -t /boot/initramfs-*.img /boot/initrd-*.img /boot/initrd-* 2>/dev/null | head -n1)
                    \\[ -n "$initrd" ] && cp -f "$initrd" "$esp/initramfs.img"
                    \\exit 0
                    , .{stage_dir}),
                .mode = 0o755,
            } });
            // The hook only fires for FUTURE kernel installs — the kernel
            // emerged earlier this install was never staged. Stage it now.
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc,
                    "k=$(ls -t /boot/vmlinuz-* 2>/dev/null | head -n1); " ++
                    "[ -n \"$k\" ] || {{ echo 'no kernel to stage' >&2; exit 1; }}; " ++
                    "cp -f \"$k\" {s}/vmlinuz || exit 1; {s}; true", .{ stage_dir, initrdStage(alloc, cfg, stage_dir) }) }),
                .chroot = true,
                .desc = "stage current kernel + initramfs for limine",
            } });
        }, 
        .grub => {
            var grub_args: std.ArrayList([]const u8) = .empty;
            try grub_args.appendSlice(alloc, &.{ "emerge", "sys-boot/grub" });
            try c.append(alloc, .{ .exec = .{ .argv = grub_args.items, .chroot = true, .desc = "grub" } });
            const target = if (cfg.boot_mode == .uefi) grubEfiTarget(cfg) else "i386-pc";
            if (cfg.boot_mode == .uefi)
                try c.append(alloc, .{ .exec = .{
                    .argv = try alloc.dupe([]const u8, &.{ "grub-install", s(alloc, "--target={s}", .{grubEfiTarget(cfg)}), "--efi-directory=/efi" }),
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
        .@"systemd-boot" => {
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "bootctl", "install" }),
                .chroot = true,
                .desc = "systemd-boot (UEFI only)",
            } });
            // bootctl only installs the manager — a Type-1 entry needs the
            // kernel + initramfs staged on the ESP and a loader entry.
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc,
                    "k=$(ls -t /boot/vmlinuz-* 2>/dev/null | head -n1); " ++
                    "[ -n \"$k\" ] || {{ echo 'no kernel to stage' >&2; exit 1; }}; " ++
                    "mkdir -p /efi/loader/entries && cp -f \"$k\" /efi/vmlinuz || exit 1; " ++
                    "{s}; true", .{initrdStage(alloc, cfg, "/efi")}) }),
                .chroot = true,
                .desc = "stage kernel + initramfs on the ESP",
            } });
            try c.append(alloc, wf(alloc, "/mnt/gentoo/efi/loader/loader.conf", "default gentoo.conf\ntimeout 4\n"));
            try c.append(alloc, wf(alloc, "/mnt/gentoo/efi/loader/entries/gentoo.conf",
                s(alloc, "title   Gentoo Linux\nlinux   /vmlinuz\n{s}options {s}\n", .{ if (cfg.system.initramfs == .none) "" else "initrd  /initramfs.img\n", kernelArgs(alloc, cfg) })));
            // kernel-install hook keeps the entry current on upgrades.
            try c.append(alloc, .{ .write_file = .{
                .path = "/mnt/gentoo/etc/kernel/install.d/91-sd-boot.install",
                .content =
                \\#!/bin/sh
                \\# gentoo-installer systemd-boot hook: restage kernel+initramfs
                \\# onto the ESP at the fixed paths the loader entry uses.
                \\[ "$1" = add ] || exit 0
                \\cp -f "$4" /efi/vmlinuz || exit 1
                \\initrd=$(ls -t /boot/initramfs-*.img /boot/initrd-*.img 2>/dev/null | head -n1)
                \\[ -n "$initrd" ] && cp -f "$initrd" /efi/initramfs.img
                \\exit 0
                ,
                .mode = 0o755,
            } });
        },
        // efistub: stage kernel+initramfs on the ESP and register a
        // firmware NVRAM entry. The ESP's disk/partition are resolved at
        // runtime via the /efi mount so alongside/reuse layouts work.
        .efistub => {
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-boot/efibootmgr" }),
                .chroot = true,
                .desc = "efibootmgr",
            } });
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc,
                    "k=$(ls -t /boot/vmlinuz-* 2>/dev/null | head -n1); " ++
                    "[ -n \"$k\" ] || {{ echo 'no kernel to stage' >&2; exit 1; }}; " ++
                    "cp -f \"$k\" /efi/vmlinuz || exit 1; {s}; true", .{initrdStage(alloc, cfg, "/efi")}) }),
                .chroot = true,
                .desc = "stage kernel + initramfs on the ESP",
            } });
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc,
                    "esp=$(findmnt -no SOURCE /efi) || exit 1; " ++
                    "d=$(lsblk -no PKNAME \"$esp\"); p=$(lsblk -no PARTN \"$esp\"); " ++
                    "[ -n \"$d\" ] && [ -n \"$p\" ] || exit 1; " ++
                    "efibootmgr -c -d /dev/$d -p $p -L Gentoo -l '\\vmlinuz' " ++
                    "-u '{s}{s}'", .{ kernelArgs(alloc, cfg), if (cfg.system.initramfs == .none) "" else " initrd=\\initramfs.img" }) }),
                .chroot = true,
                .desc = "efibootmgr: create Gentoo NVRAM entry",
            } });
        },
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
                .argv = try alloc.dupe([]const u8, &.{ "sbctl", "enroll-keys" }),
                .chroot = true,
                .desc = "enroll keys into firmware (requires Setup Mode)",
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

/// Fallback-loader EFI filename for the target arch (matches what
/// sys-boot/limine ships and what firmware looks for on EFI/BOOT).
fn efiBootFile(cfg: *const Config) []const u8 {
    return switch (cfg.arch) {
        .amd64 => "BOOTX64.EFI",
        .arm64 => "BOOTAA64.EFI",
        .riscv64 => "BOOTRISCV64.EFI",
        else => "BOOTX64.EFI",
    };
}

fn grubEfiTarget(cfg: *const Config) []const u8 {
    return switch (cfg.arch) {
        .amd64 => "x86_64-efi",
        .arm64 => "arm64-efi",
        .riscv64 => "riscv64-efi",
        else => "x86_64-efi",
    };
}

fn limineConf(alloc: Allocator, cfg: *const Config) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    w.writeAll("# generated by gentoo-installer\n") catch {};
    w.writeAll("timeout: 5\n\n") catch {};
    const root_args = kernelArgs(alloc, cfg);
    // boot:// resolves on the volume holding limine.conf: ESP root under
    // UEFI or a dedicated /boot partition; the root fs otherwise, where
    // staged files live under /boot/.
    const boot_vol = cfg.boot_mode == .uefi or cfg.disk.boot_part;
    const kpath = if (boot_vol) "vmlinuz" else "boot/vmlinuz";
    const ipath = if (boot_vol) "initramfs.img" else "boot/initramfs.img";
    w.print("/Gentoo\n", .{}) catch {};
    w.writeAll("    protocol: linux\n") catch {};
    w.print("    kernel_path: boot:///{s}\n", .{kpath}) catch {};
    // no initramfs → no module line (and nothing for the hook to stage)
    if (cfg.system.initramfs != .none)
        w.print("    module_path: boot:///{s}\n", .{ipath}) catch {};
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
    const plan = try build(alloc, &cfg, null, .{});

    const expected_ids = [_][]const u8{
        "detect",       "partition",      "mount",          "stage3",
        "portage-config", "enter-chroot", "repo-sync",      "profile",
        "world-update", "base-config",    "firmware-kernel", "fstab",
        "system-config", "services",      "packages",       "bootloader",
        "finish",
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
    for (plan.steps) |st| {
        if (!std.mem.eql(u8, st.id, "bootloader")) continue;
        for (st.cmds) |cmd| {
            if (cmd == .write_file and std.mem.endsWith(u8, cmd.write_file.path, "limine.conf"))
                saw_limine = true;
        }
    }
    try std.testing.expect(saw_limine);
}
