//! The planner: Config + Env → ordered Steps → Cmd lists. Pure —
//! no side effects, no process spawns; the runner executes or prints.
//! The wizard's "after" preview renders exactly this plan.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const detect = @import("detect.zig");
const preset = @import("preset.zig");
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
    /// Preset [[extra_steps]] skippable=true: a failed command logs a
    /// warning and the run continues instead of aborting.
    skippable: bool = false,
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
    repos: []const preset.Repo = &.{},
};

/// `disk_seed` namespaces the partition GUIDs this plan assigns — pass a
/// fixed value in tests; null draws a random per-install seed so two
/// installer-produced disks never collide on PARTUUID.
///
/// `pre` contributes [[extra_steps]] (inserted after their `after`
/// anchor; earliest allowed is enter-chroot) and [hooks].post_install
/// (last chroot step before finish/unmount).
pub fn build(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env, pkg_sets: Sets, pre: ?*const preset.Preset, disk_seed: ?u128) !Plan {
    const seed = disk_seed orelse blk: {
        var buf: [16]u8 = undefined;
        const rc = std.os.linux.getrandom(&buf, buf.len, 0);
        break :blk if (std.os.linux.errno(rc) == .SUCCESS)
            std.mem.readInt(u128, &buf, .little)
        else
            @as(u128, @intCast(std.os.linux.getpid())) *% 0x9e3779b97f4a7c15c39d7f1b08b5e9;
    };
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

    try steps.append(alloc, try planPartition(alloc, cfg, env, seed));
    try steps.append(alloc, try planMount(alloc, cfg, env));
    try steps.append(alloc, try planStage3(alloc, cfg));
    try steps.append(alloc, try planPortage(alloc, cfg, env, seed));
    try steps.append(alloc, try planChroot(alloc));
    try steps.append(alloc, try planRepoSync(alloc, cfg));
    try steps.append(alloc, try planProfile(alloc, cfg));
    if (cfg.extra.update_world)
        try steps.append(alloc, try planWorldUpdate(alloc, cfg));
    try steps.append(alloc, try planBaseConfig(alloc, cfg));
    try steps.append(alloc, try planKernel(alloc, cfg, env));
    try steps.append(alloc, try planFstab(alloc, cfg, env, seed));
    try steps.append(alloc, try planSystemConfig(alloc, cfg));
    try steps.append(alloc, try planServices(alloc, cfg, env));
    try steps.append(alloc, try planPackages(alloc, cfg, pkg_sets));
    try steps.append(alloc, try planBootloader(alloc, cfg, env, seed));
    // [hooks].post_install: last thing inside the chroot, before
    // finish's unmount. The script ships inside the preset; the plan
    // stages it into the target and runs it there.
    if (pre) |p| {
        if (p.post_install) |script| {
            var c: std.ArrayList(Cmd) = .empty;
            try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/root/gi-post-install.sh", .content = script, .mode = 0o700 } });
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "/bin/sh", "/root/gi-post-install.sh" }), .chroot = true, .desc = "preset post-install hook" } });
            try c.append(alloc, argv(alloc, &.{ "rm", "-f", "/mnt/gentoo/root/gi-post-install.sh" }, "cleanup hook script"));
            try steps.append(alloc, .{ .id = "post-install", .title = "Preset post-install hook", .cmds = c.items });
        }
    }
    try steps.append(alloc, try planFinish(alloc, cfg));

    // Preset [[extra_steps]]: each inserts right after its `after`
    // anchor. The anchor must be a pipeline step at or after
    // enter-chroot (earlier steps have no target userland yet).
    if (pre) |p| {
        for (p.extra_steps) |ex| {
            if (!stepNameOk(ex.name)) return error.BadExtraStep;
            const anchor = findStepIndex(steps.items, ex.after) orelse {
                if (!builtin.is_test)
                    std.log.err("preset extra_step '{s}': unknown anchor '{s}'", .{ ex.name, ex.after });
                return error.BadExtraStep;
            };
            const floor = findStepIndex(steps.items, "enter-chroot") orelse 0;
            // Ceiling: the terminal steps are not valid anchors — finish
            // unmounts the target and post-install is the last chroot hook.
            const anchor_id = steps.items[anchor].id;
            const past_end = std.mem.eql(u8, anchor_id, "finish") or
                std.mem.eql(u8, anchor_id, "post-install") or
                std.mem.startsWith(u8, anchor_id, "preset-");
            if (anchor < floor or past_end) {
                if (!builtin.is_test)
                    std.log.err("preset extra_step '{s}': anchor '{s}' is outside the chroot pipeline", .{ ex.name, ex.after });
                return error.BadExtraStep;
            }
            var c: std.ArrayList(Cmd) = .empty;
            const spath = s(alloc, "/mnt/gentoo/root/gi-extra-{s}.sh", .{ex.name});
            try c.append(alloc, .{ .write_file = .{ .path = spath, .content = ex.script, .mode = 0o700 } });
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "/bin/sh", s(alloc, "/root/gi-extra-{s}.sh", .{ex.name}) }),
                .chroot = true,
                .desc = if (ex.description.len > 0) ex.description else ex.name,
            } });
            try c.append(alloc, argv(alloc, &.{ "rm", "-f", spath }, "cleanup extra-step script"));
            // Keep declaration order when several steps share an anchor.
            var pos = anchor + 1;
            while (pos < steps.items.len and std.mem.startsWith(u8, steps.items[pos].id, "preset-")) pos += 1;
            try steps.insert(alloc, pos, .{
                .id = s(alloc, "preset-{s}", .{ex.name}),
                .title = if (ex.description.len > 0) ex.description else s(alloc, "Preset step: {s}", .{ex.name}),
                .cmds = c.items,
                .skippable = ex.skippable,
            });
        }
    }

    return .{ .steps = steps.items };
}

fn findStepIndex(steps: []const Step, id: []const u8) ?usize {
    for (steps, 0..) |st, i| if (std.mem.eql(u8, st.id, id)) return i;
    return null;
}

/// Extra-step names become a tmp path + journal id — keep them tame.
fn stepNameOk(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    }
    return true;
}

// ------------------------------------------------------------------ //

fn planPartition(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env, seed: u128) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    const dev = cfg.disk.device;
    const d = cfg.disk;

    switch (d.scheme) {
        .manual => {
            // Free-form: every row of disk.partitions becomes a GPT
            // entry + filesystem in listed order. Validation has already
            // enforced one "/", ≥1 EF00 on UEFI, rest-last, etc.
            if (d.wipe)
                try c.append(alloc, argv(alloc, &.{ "sgdisk", "--zap-all", dev }, s(alloc, "wipe partition table on {s}", .{dev})));
            for (d.partitions, 0..) |p, i| {
                const n: u32 = @intCast(i + 1);
                // sgdisk takes +<n>M for MiB — our MiB/GiB spec units
                // aren't literals it accepts, so convert via MiB.
                const size_arg = if (config.parseSizeMiB(p.size)) |mib|
                    s(alloc, "-n{}:0:+{}M", .{ n, mib })
                else // "rest" — take all remaining space
                    s(alloc, "-n{}:0:0", .{n});
                const name_arg = if (p.name.len > 0) s(alloc, "-c{}:{s}", .{ n, p.name }) else s(alloc, "-c{}:part{}", .{ n, n });
                try c.append(alloc, argv(alloc, &.{ "sgdisk", size_arg, s(alloc, "-t{}:{s}", .{ n, p.ptype }), name_arg, s(alloc, "-u{}:{s}", .{ n, partGuid(alloc, seed, n) }), dev }, s(alloc, "partition {} ({s}, {s})", .{ n, p.size, p.ptype })));
            }
            // filesystems — LUKS wraps the "/" partition when enabled.
            var root_dev: []const u8 = "";
            for (d.partitions, 0..) |p, i| {
                const n: u32 = @intCast(i + 1);
                const pp = partPath(alloc, dev, n);
                const is_root = std.mem.eql(u8, p.mount, "/");
                var dev_node = pp;
                // mkfs/luksFormat refuse leftover signatures — a rerun after
                // a failed install still has them. Wipe before any format.
                if ((is_root and d.luks) or (p.fs.len > 0 and !std.mem.eql(u8, p.fs, "none")))
                    try c.append(alloc, argv(alloc, &.{ "wipefs", "-a", pp }, s(alloc, "wipe signatures on {s}", .{pp})));
                if (is_root and d.luks) {
                    try c.append(alloc, .{ .exec = .{
                        .argv = try alloc.dupe([]const u8, &.{ "cryptsetup", "luksFormat", "--type", "luks2", "--pbkdf", "argon2id", "--batch-mode", "--key-file", "-", pp }),
                        .stdin = cfg.disk.luks_passphrase,
                        .stdin_label = "<luks passphrase>",
                        .desc = s(alloc, "LUKS2+argon2id on {s} (passphrase on stdin)", .{pp}),
                    } });
                    try c.append(alloc, .{ .exec = .{
                        .argv = try alloc.dupe([]const u8, &.{ "cryptsetup", "open", "--key-file", "-", pp, "cryptroot" }),
                        .stdin = cfg.disk.luks_passphrase,
                        .stdin_label = "<luks passphrase>",
                        .desc = "open LUKS container",
                    } });
                    dev_node = "/dev/mapper/cryptroot";
                    root_dev = dev_node;
                } else if (is_root) root_dev = pp;
                if (std.mem.eql(u8, p.fs, "vfat"))
                    try c.append(alloc, argv(alloc, &.{ "mkfs.vfat", "-F32", "-n", if (p.name.len > 0) p.name else "ESP", pp }, s(alloc, "format {s} as FAT32", .{pp})))
                else if (std.mem.eql(u8, p.fs, "swap"))
                    try c.append(alloc, argv(alloc, &.{ "mkswap", "-L", if (p.name.len > 0) p.name else "swap", pp }, s(alloc, "format {s} as swap", .{pp})))
                else if (p.fs.len > 0 and !std.mem.eql(u8, p.fs, "none"))
                    try c.append(alloc, argv(alloc, &.{ s(alloc, "mkfs.{s}", .{p.fs}), dev_node }, s(alloc, "format {s} as {s}", .{ dev_node, p.fs })));
            }
            // btrfs root gets the standard subvol layout (rollback is a
            // distro invariant — manual partitions don't opt out).
            if (rootFsOf(cfg) == .btrfs) {
                try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo" }, "target mountpoint"));
                try c.append(alloc, argv(alloc, &.{ "mount", root_dev, "/mnt/gentoo" }, "mount btrfs top-level"));
                for ([_][]const u8{ "@root", "@home", "@snapshots" }) |sv|
                    try c.append(alloc, argv(alloc, &.{ "btrfs", "subvolume", "create", s(alloc, "/mnt/gentoo/{s}", .{sv}) }, s(alloc, "subvol {s}", .{sv})));
                try c.append(alloc, argv(alloc, &.{ "umount", "/mnt/gentoo" }, "unmount after subvol creation"));
            }
            return step(alloc, "partition", "Partition disks (manual)", c);
        },
        .alongside => {
            try c.append(alloc, .{ .note = "alongside mode: existing OS partitions + ESP preserved untouched" });
            const di = diskOf(env, dev) orelse {
                try c.append(alloc, .{ .note = "no detection data for the target disk — validation reports the error" });
                return step(alloc, "partition", "Partition disks (alongside)", c);
            };
            if (alongsideEsp(di) == null)
                try c.append(alloc, .{ .note = "no ESP detected — validation blocks the run" });
            const base = maxPartNum(di);
            // Region [rs..re] (sectors) the new partitions occupy.
            var rs: u64 = 0;
            var re: u64 = 0;
            if (d.space_src == .shrink) {
                const p = for (di.parts) |*pp| {
                    if (std.mem.eql(u8, pp.path, d.shrink_part)) break pp;
                } else null;
                if (p) |pp| {
                    // fs shrinks first so the fs stays consistent if the
                    // partition resize fails midway; the partition then
                    // keeps a small margin over the shrunk fs.
                    const fs_size_mib = pp.fs_size_bytes >> 20;
                    const new_fs_mib = fs_size_mib - d.shrink_mib;
                    if (std.mem.eql(u8, pp.fs, "ntfs")) {
                        // No --force: a dirty NTFS must refuse loudly —
                        // docs say chkdsk + full shutdown first.
                        try c.append(alloc, argv(alloc, &.{ "ntfsresize", "--no-percentage", s(alloc, "-s{}M", .{new_fs_mib}), pp.path }, s(alloc, "ntfsresize {s} → {} MiB", .{ pp.path, new_fs_mib })));
                    } else if (std.mem.startsWith(u8, pp.fs, "ext")) {
                        try c.append(alloc, argv(alloc, &.{ "e2fsck", "-f", "-y", pp.path }, s(alloc, "e2fsck {s} (resize2fs needs a clean fs)", .{pp.path})));
                        try c.append(alloc, argv(alloc, &.{ "resize2fs", pp.path, s(alloc, "{}M", .{new_fs_mib}) }, s(alloc, "resize2fs {s} → {} MiB", .{ pp.path, new_fs_mib })));
                    } else if (std.mem.eql(u8, pp.fs, "btrfs")) {
                        // btrfs resizes only while mounted.
                        try c.append(alloc, argv(alloc, &.{ "sh", "-c", s(alloc, "mkdir -p /tmp/gi-shrink && mount {s} /tmp/gi-shrink && btrfs filesystem resize -{}M /tmp/gi-shrink; rc=$?; umount /tmp/gi-shrink 2>/dev/null; exit $rc", .{ pp.path, d.shrink_mib }) }, s(alloc, "btrfs resize -{} MiB on {s}", .{ d.shrink_mib, pp.path })));
                    }
                    // Partition keeps a 16 MiB margin over the shrunk fs.
                    const margin_sectors: u64 = 16 * 2048;
                    const new_end = pp.start_sector + (new_fs_mib << 11) + margin_sectors - 1;
                    const old_end = pp.start_sector + (pp.size_bytes >> 9) - 1;
                    // sgdisk -d/-n recreates the GPT entry — capture the
                    // existing partition's identity (type GUID, unique
                    // GUID, name, attribute bits) first and re-apply it,
                    // or the foreign OS's boot/mount references keyed to
                    // PARTUUID or type silently break.
                    try c.append(alloc, argv(alloc, &.{ "sh", "-c", s(alloc, "i=$(sgdisk -i{} {s}) && " ++
                        "t=$(echo \"$i\" | sed -n 's|Partition GUID code: *\\([^ ]*\\).*|\\1|p') && " ++
                        "u=$(echo \"$i\" | sed -n 's|Partition unique GUID: *||p') && " ++
                        "m=$(echo \"$i\" | sed -n \"s|Partition name: *'\\(.*\\)'|\\1|p\") && " ++
                        "a=$(echo \"$i\" | sed -n 's|Attribute flags: *||p') && " ++
                        "sgdisk -d{} -n{}:{}:{} -t{}:$t -u{}:$u -c{}:\"$m\" -A{}:=:$a {s}", .{ pp.num, dev, pp.num, pp.num, pp.start_sector, new_end, pp.num, pp.num, pp.num, pp.num, dev }) }, s(alloc, "shrink partition {} to end at sector {} (type/GUID/name/attrs preserved)", .{ pp.num, new_end })));
                    rs = new_end + 1;
                    // The freed gap ends where the partition used to.
                    re = old_end;
                    // MiB-align the gap start the same way detection does.
                    rs = (rs + 2047) / 2048 * 2048;
                } else {
                    try c.append(alloc, .{ .note = "shrink_part not detected on the target disk — validation reports the error" });
                }
            } else {
                // Largest free region big enough; bounds already MiB-aligned.
                const need: u64 = (8192 + @as(u64, if (d.swap == .partition) d.swap_mib else 0)) << 20;
                var best: ?detect.FreeRegion = null;
                for (di.free_regions) |g| {
                    const size_b = (g.end_sector - g.start_sector + 1) * 512;
                    if (size_b >= need and (best == null or size_b > (best.?.end_sector - best.?.start_sector + 1) * 512)) best = g;
                }
                if (best) |g| {
                    rs = g.start_sector;
                    re = g.end_sector;
                } else try c.append(alloc, .{ .note = "no free region ≥ the install floor — validation reports the error" });
            }
            if (re > rs) {
                var n: u32 = base + 1;
                if (d.swap == .partition) {
                    try c.append(alloc, argv(alloc, &.{ "sgdisk", s(alloc, "-n{}:{}:+{}M", .{ n, rs, d.swap_mib }), s(alloc, "-t{}:8200", .{n}), s(alloc, "-c{}:swap", .{n}), s(alloc, "-u{}:{s}", .{ n, partGuid(alloc, seed, n) }), dev }, s(alloc, "swap {}MiB at partition {} (in freed space)", .{ d.swap_mib, n })));
                    rs += @as(u64, d.swap_mib) * 2048;
                    n += 1;
                }
                try c.append(alloc, argv(alloc, &.{ "sgdisk", s(alloc, "-n{}:{}:{}", .{ n, rs, re }), s(alloc, "-t{}:8304", .{n}), s(alloc, "-c{}:root", .{n}), s(alloc, "-u{}:{s}", .{ n, partGuid(alloc, seed, n) }), dev }, s(alloc, "root partition {} in freed space [{}-{}]", .{ n, rs, re })));
                try c.append(alloc, argv(alloc, &.{ "partprobe", dev }, "re-read partition table"));
                const root_part = partPath(alloc, dev, n);
                const swap_p: ?[]const u8 = if (d.swap == .partition) partPath(alloc, dev, n - 1) else null;
                try appendFsChain(alloc, &c, cfg, root_part, swap_p);
            }
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
        try c.append(alloc, argv(alloc, &.{ "sgdisk", s(alloc, "-n{}:0:+{}MiB", .{ n, d.esp_mib }), s(alloc, "-t{}:EF00", .{n}), s(alloc, "-c{}:ESP", .{n}), s(alloc, "-u{}:{s}", .{ n, partGuid(alloc, seed, n) }), dev }, s(alloc, "ESP {}MiB at partition {}", .{ d.esp_mib, n })));
    } else {
        n += 1;
        try c.append(alloc, argv(alloc, &.{ "sgdisk", s(alloc, "-n{}:0:+2MiB", .{n}), s(alloc, "-t{}:EF02", .{n}), s(alloc, "-c{}:biosboot", .{n}), s(alloc, "-u{}:{s}", .{ n, partGuid(alloc, seed, n) }), dev }, "BIOS boot partition (2MiB, EF02)"));
    }
    if (d.swap == .partition) {
        n += 1;
        swap_part = partPath(alloc, dev, n);
        try c.append(alloc, argv(alloc, &.{ "sgdisk", s(alloc, "-n{}:0:+{}MiB", .{ n, d.swap_mib }), s(alloc, "-t{}:8200", .{n}), s(alloc, "-c{}:swap", .{n}), s(alloc, "-u{}:{s}", .{ n, partGuid(alloc, seed, n) }), dev }, s(alloc, "swap {}MiB at partition {}", .{ d.swap_mib, n })));
    }
    var boot_part: ?[]const u8 = null;
    if (d.boot_part) {
        n += 1;
        boot_part = partPath(alloc, dev, n);
        try c.append(alloc, argv(alloc, &.{ "sgdisk", s(alloc, "-n{}:0:+1024MiB", .{n}), s(alloc, "-t{}:8300", .{n}), s(alloc, "-c{}:boot", .{n}), s(alloc, "-u{}:{s}", .{ n, partGuid(alloc, seed, n) }), dev }, s(alloc, "boot partition 1GiB at partition {}", .{n})));
    }
    n += 1;
    const root_part = partPath(alloc, dev, n);
    // 8304 = Linux root DPS GUID (auto-discovery on systemd)
    try c.append(alloc, argv(alloc, &.{ "sgdisk", s(alloc, "-n{}:0:0", .{n}), s(alloc, "-t{}:8304", .{n}), s(alloc, "-c{}:root", .{n}), s(alloc, "-u{}:{s}", .{ n, partGuid(alloc, seed, n) }), dev }, s(alloc, "root partition {} (rest of disk)", .{n})));

    // ESP filesystem (never reformatted in alongside mode — not reached here).
    // wipefs before every format: a rerun after a failed install still
    // carries signatures mkfs tools refuse to overwrite.
    if (esp_part) |esp| {
        try c.append(alloc, argv(alloc, &.{ "wipefs", "-a", esp }, s(alloc, "wipe signatures on {s}", .{esp})));
        try c.append(alloc, argv(alloc, &.{ "mkfs.vfat", "-F32", "-n", "ESP", esp }, "format ESP as FAT32"));
    }
    if (boot_part) |bp| {
        try c.append(alloc, argv(alloc, &.{ "wipefs", "-a", bp }, s(alloc, "wipe signatures on {s}", .{bp})));
        // Limine ≥12 reads only FAT/ISO9660 — ext4 /boot is unreadable
        // to its BIOS stage. grub keeps ext4.
        if (std.mem.eql(u8, bootPartFs(cfg), "vfat")) {
            try c.append(alloc, argv(alloc, &.{ "mkfs.vfat", "-F32", "-n", "boot", bp }, "format /boot as FAT32 (limine BIOS)"));
        } else {
            try c.append(alloc, argv(alloc, &.{ "mkfs.ext4", "-L", "boot", bp }, "format /boot as ext4"));
        }
    }

    try appendFsChain(alloc, &c, cfg, root_part, swap_part);
    return step(alloc, "partition", "Partition disks", c);
}

/// The shared post-partitioning chain for guided + alongside layouts:
/// LUKS wrap → LVM → mkfs root → mkswap → btrfs subvols.
fn appendFsChain(alloc: Allocator, c: *std.ArrayList(Cmd), cfg: *const Config, root_part: []const u8, swap_part: ?[]const u8) !void {
    const d = cfg.disk;
    // Separate /home is an LVM thin LV (or a btrfs @home subvol), never a
    // standalone partition — validation enforces that pairing.
    _ = d.home_part;

    // LUKS on root (container lives on the raw partition). Wipe stale
    // signatures first — luksFormat/pvcreate/mkfs all refuse leftovers.
    var root_dev = root_part;
    try c.append(alloc, argv(alloc, &.{ "wipefs", "-a", root_part }, s(alloc, "wipe signatures on {s}", .{root_part})));
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
        try c.append(alloc, argv(alloc, &.{ "wipefs", "-a", root_dev }, s(alloc, "wipe signatures on {s}", .{root_dev})));
        try c.append(alloc, argv(alloc, &.{ "pvcreate", "--norestorefile", root_dev }, s(alloc, "PV on {s}", .{root_dev})));
        try c.append(alloc, argv(alloc, &.{ "vgcreate", "vg0", root_dev }, "volume group vg0"));
        if (cfg.system.snapshots == .auto) {
            // -l %VG is valid on the POOL (a normal LV underneath).
            try c.append(alloc, argv(alloc, &.{ "lvcreate", "-l", "95%VG", "-T", "vg0/tank" }, "thin pool tank (95% VG)"));
            // Thin LVs take -V <absolute size>; %FREE is a -l/-L suffix,
            // not a -V one. The pool size isn't known at plan time, so
            // measure it and give each thin LV the full pool as virtual
            // size (intentional overcommit; pool autoextend guards it).
            // lvs reports decimal MiB ('10240.00') — strip spaces,
            // truncate at the decimal point. Never delete the dot.
            const measure = "pm=$(lvs --noheadings --units m --nosuffix -o lv_size vg0/tank | tr -d ' '); " ++
                "pm=${pm%.*}; [ -n \"$pm\" ] || exit 1; ";
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc, "{s}lvcreate -T vg0/tank -n root -V \"${{pm}}M\"", .{measure}) }),
                .desc = "thin root LV (virtual size = pool)",
            } });
            if (d.home_part and d.root_fs != .btrfs) {
                try c.append(alloc, .{ .exec = .{
                    .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc, "{s}lvcreate -T vg0/tank -n home -V \"${{pm}}M\"", .{measure}) }),
                    .desc = "thin home LV (virtual size = pool, overcommit)",
                } });
                try c.append(alloc, argv(alloc, &.{ "wipefs", "-a", "/dev/vg0/home" }, "wipe signatures on home LV"));
                try c.append(alloc, argv(alloc, &.{ s(alloc, "mkfs.{s}", .{@tagName(d.root_fs)}), "/dev/vg0/home" }, "format home LV"));
            }
        } else {
            try c.append(alloc, argv(alloc, &.{ "lvcreate", "-l", "70%VG", "-n", "root", "vg0" }, "linear root LV (70% VG)"));
            if (d.home_part and d.root_fs != .btrfs) {
                try c.append(alloc, argv(alloc, &.{ "lvcreate", "-l", "100%FREE", "-n", "home", "vg0" }, "linear home LV (rest of VG)"));
                try c.append(alloc, argv(alloc, &.{ "wipefs", "-a", "/dev/vg0/home" }, "wipe signatures on home LV"));
                try c.append(alloc, argv(alloc, &.{ s(alloc, "mkfs.{s}", .{@tagName(d.root_fs)}), "/dev/vg0/home" }, "format home LV"));
            }
        }
        fs_dev = "/dev/vg0/root";
    }

    try c.append(alloc, argv(alloc, &.{ "wipefs", "-a", fs_dev }, s(alloc, "wipe signatures on {s}", .{fs_dev})));
    const mk = mkfsTool(d.root_fs);
    var mkfs_argv: std.ArrayList([]const u8) = .empty;
    try mkfs_argv.append(alloc, mk.mkfs);
    try mkfs_argv.append(alloc, fs_dev);
    try c.append(alloc, fmtArgv(alloc, s(alloc, "format root as {s}", .{@tagName(d.root_fs)}), mkfs_argv.items));

    if (swap_part) |sp| {
        try c.append(alloc, argv(alloc, &.{ "wipefs", "-a", sp }, s(alloc, "wipe signatures on {s}", .{sp})));
        try c.append(alloc, argv(alloc, &.{ "mkswap", "-L", "swap", sp }, "format swap"));
    }

    if (d.root_fs == .btrfs) {
        // Mount then create the subvol layout + @snapshots dir.
        try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo" }, "target mountpoint"));
        try c.append(alloc, argv(alloc, &.{ "mount", fs_dev, "/mnt/gentoo" }, "mount btrfs top-level"));
        for ([_][]const u8{ "@root", "@home", "@snapshots" }) |sv|
            try c.append(alloc, argv(alloc, &.{ "btrfs", "subvolume", "create", s(alloc, "/mnt/gentoo/{s}", .{sv}) }, s(alloc, "subvol {s}", .{sv})));
        try c.append(alloc, argv(alloc, &.{ "umount", "/mnt/gentoo" }, "unmount after subvol creation"));
    }
}

/// The mount point where the root filesystem lands — subvol-aware.
fn rootMountArgs(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env) struct { dev: []const u8, opts: []const u8 } {
    const dev = fsDevice(alloc, cfg, env);
    if (rootFsOf(cfg) == .btrfs)
        return .{ .dev = dev, .opts = "subvol=@root,compress=zstd:1,noatime" };
    return .{ .dev = dev, .opts = "" };
}

/// The device node that carries the root filesystem (through LUKS/LVM).
/// Kernel command line shared by every bootloader backend.
///
/// kernel-install hook body resolving the initramfs for the kernel version
/// in $2 — flat and BLS layouts, -t so a regenerated initrd beats a stale
/// sibling of the same version. Empty when initramfs=none (the hook then
/// stages the kernel only). Fails the add when a match is required but
/// absent: copying an unmatched initrd would pair it with the wrong kernel.
fn hookInitrd(alloc: Allocator, cfg: *const Config, dest: []const u8) []const u8 {
    if (cfg.system.initramfs == .none) return "";
    return s(alloc, "initrd=$(ls -t /boot/initramfs-\"$2\".img /boot/initrd-\"$2\".img /boot/initrd-\"$2\" /boot/*/\"$2\"/initrd* 2>/dev/null | head -n1); " ++
        "[ -n \"$initrd\" ] || {{ echo \"no initramfs for kernel $2\" >&2; exit 1; }}; " ++
        "cp -f \"$initrd\" {s} || exit 1", .{dest});
}

/// Shell fragment staging the newest initramfs onto the boot volume,
/// INCLUDING the leading ';' — empty when initramfs=none. The copy
/// fails the step (`|| exit 1`); nothing after it may mask the status.
fn initrdStage(alloc: Allocator, cfg: *const Config, dir: []const u8) []const u8 {
    if (cfg.system.initramfs == .none) return "";
    // kernel-install places artifacts flat (/boot/initramfs-*.img) under
    // 'flat'/'compat' layouts but /boot/<token>/<kver>/ under 'bls' — glob both.
    return s(alloc, "; i=$(ls -t /boot/initramfs-*.img /boot/initrd-*.img /boot/*/*/initrd* 2>/dev/null | head -n1); " ++
        "[ -n \"$i\" ] || {{ echo 'no initramfs to stage' >&2; exit 1; }}; " ++
        "cp -f \"$i\" {s}/initramfs.img || exit 1", .{dir});
}
// Partition GUIDs we assign at sgdisk time — derived from the plan's
// random disk seed XOR the index, so every install's PARTUUIDs are
// globally unique and the plan can persist them in fstab/root= (kernel
// names like /dev/sda3 are NOT stable across renumbering). RFC 4122
// version/variant bits are set so the values are well-formed UUIDs.
fn partGuid(alloc: Allocator, seed: u128, n: u32) []const u8 {
    const mix = seed ^ (@as(u128, n) *% 0x9e3779b97f4a7c15c39d7f1b08b5e9);
    const a: u32 = @truncate(mix >> 96);
    const b: u16 = @truncate(mix >> 80);
    const c: u16 = (@as(u16, @truncate(mix >> 64)) & 0x0fff) | 0x4000;
    const d: u16 = (@as(u16, @truncate(mix >> 48)) & 0x3fff) | 0x8000;
    const e: u48 = @truncate(mix);
    return s(alloc, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{ a, b, c, d, e });
}

/// Persistent identifier for a partition — PARTUUID, resolved by mount
/// and the kernel alike. Exec-time ops (sgdisk/mkfs/mount) keep using
/// the canonical /dev path from partPath.
fn partIdent(alloc: Allocator, seed: u128, n: u32) []const u8 {
    return s(alloc, "PARTUUID={s}", .{partGuid(alloc, seed, n)});
}

/// The partition index the root filesystem lands on (plain layouts;
/// scheme=manual resolves it from the "/" row of disk.partitions;
/// alongside appends after the disk's highest existing GPT number).
fn rootPartIdx(cfg: *const Config, env: ?*const detect.Env) u32 {
    if (cfg.disk.scheme == .manual)
        return config.manualRootPart(cfg) orelse 1;
    if (cfg.disk.scheme == .alongside) {
        const base = if (env) |e| blk: {
            const di = diskOf(e, cfg.disk.device) orelse break :blk 0;
            break :blk maxPartNum(di);
        } else 0;
        var n = base + 1;
        if (cfg.disk.swap == .partition) n += 1;
        return n;
    }
    var n: u32 = 1; // esp (uefi) or biosboot (bios)
    if (cfg.disk.swap == .partition) n += 1;
    if (cfg.disk.boot_part) n += 1;
    return n + 1;
}

/// Detected disk matching the configured device path.
fn diskOf(env: ?*const detect.Env, dev: []const u8) ?*const detect.DiskInfo {
    const e = env orelse return null;
    for (e.disks) |*d| if (std.mem.eql(u8, d.path, dev)) return d;
    return null;
}

/// The detected ESP partition on a populated disk.
fn alongsideEsp(di: *const detect.DiskInfo) ?*const detect.PartInfo {
    for (di.parts) |*p| if (p.esp) return p;
    return null;
}

/// Highest GPT partition number currently on the disk (0 = empty).
fn maxPartNum(di: *const detect.DiskInfo) u32 {
    var m: u32 = 0;
    for (di.parts) |p| {
        if (p.num > m) m = p.num;
    }
    return m;
}

/// Root filesystem for mkfs/fstab/rootfstype — under scheme=manual it
/// is the "/" row's fs; everywhere else it is disk.root_fs.
fn rootFsOf(cfg: *const Config) config.RootFs {
    if (cfg.disk.scheme == .manual)
        return config.manualRootFs(cfg) orelse cfg.disk.root_fs;
    return cfg.disk.root_fs;
}

/// Partition number of the ESP — index 1 on guided UEFI layouts; under
/// scheme=manual the row whose type is EF00 (any position); under
/// alongside, the detected existing ESP's GPT number.
fn espPartIdx(cfg: *const Config, env: ?*const detect.Env) ?u32 {
    if (cfg.disk.scheme == .manual) {
        for (cfg.disk.partitions, 0..) |p, i|
            if (std.ascii.eqlIgnoreCase(p.ptype, "EF00")) return @intCast(i + 1);
        return null;
    }
    if (cfg.disk.scheme == .alongside) {
        const di = diskOf(env, cfg.disk.device) orelse return null;
        const esp = alongsideEsp(di) orelse return null;
        return esp.num;
    }
    return if (cfg.boot_mode == .uefi) 1 else null;
}

/// Device path of the ESP — detected partition for alongside (which
/// reuses it), sgdisk-created index otherwise.
fn espPath(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env) ?[]const u8 {
    if (cfg.disk.scheme == .alongside) {
        const di = diskOf(env, cfg.disk.device) orelse return null;
        const esp = alongsideEsp(di) orelse return null;
        return esp.path;
    }
    const n = espPartIdx(cfg, env) orelse return null;
    return partPath(alloc, cfg.disk.device, n);
}

/// Persistent fstab identifier for the ESP — the detected PARTUUID
/// under alongside (we didn't create it), our assigned one otherwise.
fn espIdent(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env, seed: u128) ?[]const u8 {
    if (cfg.disk.scheme == .alongside) {
        const di = diskOf(env, cfg.disk.device) orelse return null;
        const esp = alongsideEsp(di) orelse return null;
        if (esp.partuuid.len == 0) return null;
        return s(alloc, "PARTUUID={s}", .{esp.partuuid});
    }
    const n = espPartIdx(cfg, env) orelse return null;
    return partIdent(alloc, seed, n);
}

/// 1-based partition number of the EF02 BIOS-boot partition — index 1
/// on guided BIOS layouts; under scheme=manual the EF02 row, if any.
fn biosBootIdx(cfg: *const Config) ?u32 {
    if (cfg.disk.scheme == .manual) {
        for (cfg.disk.partitions, 0..) |p, i|
            if (std.ascii.eqlIgnoreCase(p.ptype, "EF02")) return @intCast(i + 1);
        return null;
    }
    return if (cfg.boot_mode == .bios) 1 else null;
}

/// Filesystem of the guided /boot partition — limine's BIOS stage reads
/// only FAT/ISO9660 (ext support dropped in limine 12), so BIOS+limine
/// gets FAT32; everything else keeps ext4.
fn bootPartFs(cfg: *const Config) []const u8 {
    if (cfg.boot_mode == .bios and config.resolveBootloader(cfg) == .limine)
        return "vfat";
    return "ext4";
}

/// Mount point of the ESP inside the target.
fn espMountPoint(alloc: Allocator, cfg: *const Config) []const u8 {
    if (cfg.disk.scheme == .manual)
        return s(alloc, "/mnt/gentoo{s}", .{config.manualEspMount(cfg)});
    return "/mnt/gentoo/efi";
}

/// The ESP's path from inside the chroot (bootloader/signing steps).
fn espInTarget(cfg: *const Config) []const u8 {
    if (cfg.disk.scheme == .manual) return config.manualEspMount(cfg);
    return "/efi";
}

/// Persistent root identifier for root= and fstab: mapper/LV names are
/// already stable; plain partitions use their assigned PARTUUID.
pub fn rootIdent(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env, seed: u128) []const u8 {
    if (cfg.disk.lvm) return "/dev/vg0/root";
    if (cfg.disk.luks) return "/dev/mapper/cryptroot";
    return partIdent(alloc, seed, rootPartIdx(cfg, env));
}

fn kernelArgs(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env, seed: u128) []const u8 {
    var r = s(alloc, "root={s}", .{rootIdent(alloc, cfg, env, seed)});
    // btrfs: install mounted subvol=@root — boot must select it too.
    if (rootFsOf(cfg) == .btrfs)
        r = s(alloc, "{s} rootflags=subvol=@root", .{r});
    // LUKS: dracut unlocks via crypttab/rd.luks at initramfs time.
    if (cfg.disk.luks)
        r = s(alloc, "{s} rd.luks=1", .{r});
    // Proprietary NVIDIA: kernel modesetting is required for Wayland
    // compositors and gives a working fb console before X starts.
    switch (resolveGpuDriver(cfg, env)) {
        .@"nvidia-open", .@"nvidia-drivers" => r = s(alloc, "{s} nvidia-drm.modeset=1", .{r}),
        else => {},
    }
    // Alt inits need their supervisor binary as PID1 — the stage3 ships
    // sysvinit+openrc, so init= swaps the chain at kernel time.
    switch (cfg.system.init) {
        .runit => r = s(alloc, "{s} init=/sbin/runit-init", .{r}),
        .dinit => r = s(alloc, "{s} init=/sbin/dinit", .{r}),
        // the maker's bin/init lands at /sbin/init (sysvinit unmerged),
        // but spell it out so the cmdline documents the PID1 choice.
        .s6 => r = s(alloc, "{s} init=/sbin/init", .{r}),
        else => {},
    }
    return s(alloc, "{s} rootfstype={s}", .{ r, @tagName(rootFsOf(cfg)) });
}

pub fn fsDevice(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env) []const u8 {
    if (cfg.disk.lvm) return "/dev/vg0/root";
    if (cfg.disk.luks) return "/dev/mapper/cryptroot";
    return partPath(alloc, cfg.disk.device, rootPartIdx(cfg, env));
}

/// Partition index of the separate /boot partition, if configured.
fn bootPartIdx(cfg: *const Config) u32 {
    var n: u32 = 1; // esp/biosboot
    if (cfg.disk.swap == .partition) n += 1;
    return n + 1;
}

/// Count of '/' in a mount path — the mount ordering key (parents
/// before nested children like /boot then /boot/efi).
fn mountDepth(path: []const u8) usize {
    return std.mem.count(u8, path, "/");
}

/// A manual row's effective mount inside the target: its own mount,
/// or the /efi default for an EF00 ESP row that left mount blank
/// (mirrors config.manualEspMount).
fn rowMount(p: config.Partition) []const u8 {
    if (p.mount.len > 0) return p.mount;
    if (std.ascii.eqlIgnoreCase(p.ptype, "EF00")) return "/efi";
    return "";
}

fn planMount(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    const root = rootMountArgs(alloc, cfg, env);
    try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo" }, "target mountpoint"));
    if (root.opts.len > 0)
        try c.append(alloc, argv(alloc, &.{ "mount", "-o", root.opts, root.dev, "/mnt/gentoo" }, "mount root"))
    else
        try c.append(alloc, argv(alloc, &.{ "mount", root.dev, "/mnt/gentoo" }, "mount root"));

    if (cfg.disk.scheme == .manual) {
        // Non-root mounts in path-depth order so parents mount first
        // (/boot before /boot/efi).
        const parts = cfg.disk.partitions;
        var idxs: std.ArrayList(u32) = .empty;
        for (parts, 0..) |p, i| {
            const m = rowMount(p);
            if (m.len > 0 and !std.mem.eql(u8, m, "/"))
                try idxs.append(alloc, @intCast(i));
        }
        std.mem.sort(u32, idxs.items, parts, struct {
            fn lt(ps: []const config.Partition, a: u32, b: u32) bool {
                return mountDepth(rowMount(ps[a])) < mountDepth(rowMount(ps[b]));
            }
        }.lt);
        for (idxs.items) |i| {
            const p = parts[i];
            const m = rowMount(p);
            const target = s(alloc, "/mnt/gentoo{s}", .{m});
            try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", target }, s(alloc, "{s} mountpoint", .{m})));
            try c.append(alloc, argv(alloc, &.{ "mount", partPath(alloc, cfg.disk.device, i + 1), target }, s(alloc, "mount {s}", .{m})));
        }
        for (parts, 0..) |p, i|
            if (std.mem.eql(u8, p.fs, "swap"))
                try c.append(alloc, argv(alloc, &.{ "swapon", partPath(alloc, cfg.disk.device, @intCast(i + 1)) }, "enable swap"));
        // btrfs root: the standard subvol mounts are part of the
        // invariant layout — skipped only when a row claims the
        // mountpoint itself (fstab below mirrors this).
        if (rootFsOf(cfg) == .btrfs) {
            if (config.manualMountPart(cfg, "/home") == null) {
                try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo/home" }, "/home mountpoint"));
                try c.append(alloc, argv(alloc, &.{ "mount", "-o", "subvol=@home,compress=zstd:1,noatime", root.dev, "/mnt/gentoo/home" }, "mount @home"));
            }
            if (config.manualMountPart(cfg, "/.snapshots") == null) {
                try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo/.snapshots" }, "/.snapshots mountpoint"));
                try c.append(alloc, argv(alloc, &.{ "mount", "-o", "subvol=@snapshots,compress=zstd:1,noatime", root.dev, "/mnt/gentoo/.snapshots" }, "mount @snapshots"));
            }
        }
        try c.append(alloc, .{ .note = "bind mounts (/proc /sys /dev /run) happen at enter-chroot" });
        return step(alloc, "mount", "Mount target", c);
    }

    if (cfg.disk.boot_part) {
        try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo/boot" }, "/boot mountpoint"));
        try c.append(alloc, argv(alloc, &.{ "mount", partPath(alloc, cfg.disk.device, bootPartIdx(cfg)), "/mnt/gentoo/boot" }, "mount /boot"));
    }

    if (espPath(alloc, cfg, env)) |esp| {
        const esp_target = espMountPoint(alloc, cfg);
        try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", esp_target }, "ESP mountpoint"));
        try c.append(alloc, argv(alloc, &.{ "mount", esp, esp_target }, if (cfg.disk.scheme == .alongside) "mount existing ESP (read-write, not reformatted)" else "mount ESP"));
    }
    if (cfg.disk.swap == .partition) {
        const swap_n: u32 = if (cfg.disk.scheme == .alongside) blk: {
            // alongside: swap is the first appended partition (base+1).
            const base = if (env) |e| blk2: {
                const di = diskOf(e, cfg.disk.device) orelse break :blk2 0;
                break :blk2 maxPartNum(di);
            } else 0;
            break :blk base + 1;
        } else 2; // erase layouts: index 2 after esp/biosboot
        try c.append(alloc, argv(alloc, &.{ "swapon", partPath(alloc, cfg.disk.device, swap_n) }, "enable swap"));
    }
    // LVM thin home LV (non-btrfs roots only).
    if (cfg.disk.lvm and cfg.disk.home_part and rootFsOf(cfg) != .btrfs) {
        try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo/home" }, "/home mountpoint"));
        try c.append(alloc, argv(alloc, &.{ "mount", "/dev/vg0/home", "/mnt/gentoo/home" }, "mount home LV"));
    }
    // btrfs: mount the home + snapshots subvolumes created earlier.
    if (rootFsOf(cfg) == .btrfs) {
        const dev = root.dev;
        try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo/home", "/mnt/gentoo/.snapshots" }, "subvol mountpoints"));
        try c.append(alloc, argv(alloc, &.{ "mount", "-o", "subvol=@home,compress=zstd:1,noatime", dev, "/mnt/gentoo/home" }, "mount @home"));
        try c.append(alloc, argv(alloc, &.{ "mount", "-o", "subvol=@snapshots,compress=zstd:1,noatime", dev, "/mnt/gentoo/.snapshots" }, "mount @snapshots"));
    }
    try c.append(alloc, .{ .note = "bind mounts (/proc /sys /dev /run) happen at enter-chroot" });
    return step(alloc, "mount", "Mount target", c);
}

/// Gentoo naming differs per arch: the releases dir token vs the stage3
/// filename token (riscv: releases/riscv/… but stage3-rv64_lp64d-*).
/// Returns null for arch=detect — resolved once detection runs.
fn archTokens(cfg: *const Config) ?struct { dir: []const u8, file: []const u8 } {
    return switch (cfg.arch) {
        .amd64 => .{ .dir = "amd64", .file = "amd64" },
        .arm64 => .{ .dir = "arm64", .file = "arm64" },
        // riscv folds musl into the ABI token: stage3-rv64_lp64d_musl-*.
        .riscv64 => .{ .dir = "riscv", .file = if (cfg.stage3.libc == .musl) "rv64_lp64d_musl" else "rv64_lp64d" },
        .detect => null,
    };
}

fn planStage3(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    const stem = try config.stage3Stem(alloc, cfg);
    const toks = archTokens(cfg) orelse {
        try c.append(alloc, .{ .note = "stage3 URL resolved after hardware detection (arch=detect)" });
        return step(alloc, "stage3", "Stage3 download + extract", c);
    };
    const base = s(alloc, "{s}/releases/{s}/autobuilds", .{ cfg.stage3.mirror, toks.dir });
    // pointer files are latest-stage3-<arch-token>-<stem>.txt
    try c.append(alloc, argv(alloc, &.{ "curl", "-fsSL", "-o", "/tmp/latest.txt", s(alloc, "{s}/latest-stage3-{s}-{s}.txt", .{ base, toks.file, stem }) }, "resolve stage3 pointer"));
    // Resolve filename from the pointer, fetch tarball+signature+digests.
    // latest.txt entries may carry a dated subdir (2026…/stage3-….tar.xz):
    // use the full path in the URL but save locally under the basename.
    try c.append(alloc, .{ .exec = .{
        .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc, "f=$(grep -oE '[^ ]*stage3-[^ ]*\\.tar\\.xz' /tmp/latest.txt | head -n1); " ++
            "test -n \"$f\" || exit 1; b=${{f##*/}}; " ++
            "curl -fsSL -o \"/tmp/$b\" '{s}/'$f && " ++
            "curl -fsSL -o \"/tmp/$b.asc\" '{s}/'$f.asc && " ++
            "curl -fsSL -o /tmp/stage3.DIGESTS '{s}/'$f.DIGESTS && " ++
            "ln -sf \"$b\" /tmp/stage3.tar.xz && ln -sf \"$b.asc\" /tmp/stage3.tar.xz.asc", .{ base, base, base }) }),
        .desc = "download stage3 tarball + .asc + .DIGESTS (resolved from latest.txt)",
    } });
    // --verify needs the Gentoo release key in the keyring — live media
    // ship it under openpgp-keys; fall back to keyserver fetch of the
    // pinned Release Engineering fingerprint.
    try c.append(alloc, .{ .exec = .{
        .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", "gpg --import /usr/share/openpgp-keys/gentoo-release.asc 2>/dev/null || " ++
            "gpg --keyserver hkps://keys.gentoo.org --recv-keys 13EBBDBEDE7A12775DFDB1BABB572E0E2D182910" }),
        .desc = "import Gentoo release signing key (pinned fingerprint fallback)",
    } });
    try c.append(alloc, argv(alloc, &.{ "gpg", "--verify", "/tmp/stage3.tar.xz.asc", "/tmp/stage3.tar.xz" }, "GPG-verify stage3"));
    // DIGESTS carries per-section entries (# BLAKE2B HASH / # SHA512 HASH
    // — SHA256 was dropped) — extract our tarball's SHA512 entry (both
    // hashes are 128-hex, so the section header must scope the match) and
    // refuse vacuous success when it is absent.
    try c.append(alloc, .{ .exec = .{
        .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", "b=$(basename \"$(readlink -f /tmp/stage3.tar.xz)\"); " ++
            "awk -v f=\"$b\" '/^# SHA512 HASH/{h=1; next} /^#/{h=0} h && $2 == f' /tmp/stage3.DIGESTS > /tmp/stage3.sha512; " ++
            "test -s /tmp/stage3.sha512 || { echo 'no SHA512 digest entry for stage3' >&2; exit 1; }; " ++
            "(cd /tmp && sha512sum -c /tmp/stage3.sha512)" }),
        .desc = "digest-verify stage3 (SHA512 entry for the tarball)",
    } });
    try c.append(alloc, argv(alloc, &.{ "tar", "--xattrs-include=*.*", "--numeric-owner", "-xpf", "/tmp/stage3.tar.xz", "-C", "/mnt/gentoo" }, "extract stage3"));
    return step(alloc, "stage3", "Stage3 download + extract", c);
}

fn makeConf(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;

    const cflags = switch (cfg.makeconf.cflags) {
        .safe => "-O2 -pipe",
        // -march=native is broken on riscv64: gcc's ISA-string detection
        // frequently produces an arch string it then rejects (even on real
        // hardware); rv64gc is the lp64d baseline Gentoo recommends.
        .native => if (cfg.arch == .riscv64) "-O2 -pipe -march=rv64gc" else "-O2 -pipe -march=native",
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

    // riscv is effectively a ~arch-only arch: nearly all packages past
    // the stage3 base (service/fs tooling included) carry ~riscv only.
    // ~${ARCH} is the usable default; amd64/arm64 keep the stage3's
    // stable ACCEPT_KEYWORDS="${ARCH}".
    if (cfg.arch == .riscv64)
        try w.writeAll("ACCEPT_KEYWORDS=\"~${ARCH}\"\n");

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
    // Secure boot + out-of-tree modules: linux-mod-r1 signs at merge
    // time when modules-sign is on and the db (sbctl) or MOK (shim)
    // key is wired up.
    const sign_mods = cfg.security.secure_boot != .off and switch (resolveGpuDriver(cfg, env)) {
        .@"nvidia-open", .@"nvidia-drivers" => true,
        else => false,
    };
    if (sign_mods) try w.writeAll(" modules-sign");
    try w.writeAll("\"\n");
    if (sign_mods) {
        const key_path: []const u8 = switch (cfg.security.secure_boot) {
            .shim => "/etc/shim/mok",
            else => "/var/lib/sbctl/keys/db/db",
        };
        try w.print("MODULES_SIGN_KEY=\"{s}.key\"\nMODULES_SIGN_CERT=\"{s}.pem\"\nMODULES_SIGN_HASH=\"sha512\"\n", .{ key_path, key_path });
    }
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
    // engine-managed entries (bootloader/kernel wiring). The initramfs
    // generator USE must accompany every pick — kernels with
    // USE=initramfs depend on installkernel[dracut|ugrd], which is only
    // on by default in systemd profiles (openrc/musl leave it off and
    // emerge aborts on the USE-change request).
    // The unselected generator is explicitly disabled too — profiles
    // default one of them on, and initramfs=none must suppress the
    // kernel's initramfs USE entirely or emerge hits a USE-change abort.
    const gen_flag: []const u8 = switch (cfg.system.initramfs) {
        .dracut => " dracut -ugrd",
        .ugrd => " ugrd -dracut",
        .none => " -dracut -ugrd",
    };
    switch (config.resolveBootloader(cfg)) {
        .limine => try w.print("sys-kernel/installkernel -systemd-boot -refind{s}\n", .{gen_flag}),
        .grub => try w.print("sys-kernel/installkernel grub{s}\n", .{gen_flag}),
        .@"systemd-boot" => try w.print("sys-kernel/installkernel systemd-boot{s}\n", .{gen_flag}),
        .efistub => try w.print("sys-kernel/installkernel -systemd-boot{s}\n", .{gen_flag}),
        else => if (gen_flag.len > 0) try w.print("sys-kernel/installkernel{s}\n", .{gen_flag}),
    }
    if (cfg.system.initramfs == .none)
        try w.writeAll("sys-kernel/gentoo-kernel-bin -initramfs\nsys-kernel/gentoo-kernel -initramfs\n");
    if (cfg.system.uki) try w.writeAll("sys-kernel/installkernel uki\n");
    // shim chain loads a signed standalone grub — the ebuild only ships
    // grub-<arch>.efi.signed under USE=secureboot.
    if (cfg.security.secure_boot == .shim)
        try w.writeAll("sys-boot/grub secureboot\n");
    // LUKS unlock in a systemd initramfs runs through systemd-cryptsetup,
    // which Gentoo only builds under USE=cryptsetup — stage3s ship without
    // it, so the flag must be set and systemd rebuilt before dracut runs.
    if (cfg.disk.luks and cfg.system.init == .systemd)
        try w.writeAll("sys-apps/systemd cryptsetup\n");
    // networkmanager[wifi,-iwd] (the ebuild default) links its supplicant
    // control over D-Bus — without the flag emerge aborts on a USE change.
    if (cfg.network.manager == .networkmanager)
        try w.writeAll("net-wireless/wpa_supplicant dbus\n");
    return aw.written();
}

fn planPortage(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env, seed: u128) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/portage/make.conf", try makeConf(alloc, cfg, env)));
    try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/portage/package.use/installer", try packageUse(alloc, cfg)));
    // Firmware + microcode carry non-free licenses that @FREE masks —
    // grant per-package instead of loosening ACCEPT_LICENSE globally.
    // (AMD microcode ships inside linux-firmware, so one grant covers it.)
    var lic: std.Io.Writer.Allocating = .init(alloc);
    try lic.writer.writeAll("sys-kernel/linux-firmware linux-fw-redistributable\n");
    if (ucodeAtom(cfg, env)) |atom| {
        if (std.mem.eql(u8, atom, "sys-firmware/intel-microcode"))
            try lic.writer.writeAll("sys-firmware/intel-microcode intel-ucode\n");
    }
    try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/portage/package.license/installer", lic.written()));
    // limine is ~arch-masked in ::gentoo — accept-keyword it when chosen.
    if (config.resolveBootloader(cfg) == .limine) {
        const kw = switch (cfg.arch) {
            .amd64 => "~amd64",
            .arm64 => "~arm64",
            .riscv64 => "~riscv",
            .detect => "~amd64",
        };
        try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/portage/package.accept_keywords/installer", s(alloc, "sys-boot/limine {s}\n", .{kw})));
    }
    // Packages that are stable on amd64 but ~arch-only elsewhere. Keywords
    // for other arches are inert on the current one, so emit the union.
    if (cfg.disk.swap == .zram and cfg.system.init == .systemd)
        try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/portage/package.accept_keywords/zram", "sys-apps/zram-generator ~arm64 ~riscv\n"));
    if (cfg.system.privilege == .doas)
        try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/portage/package.accept_keywords/doas", "app-admin/doas ~riscv\n"));
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
    // LUKS root: crypttab names the partition by the PARTUUID we assign
    // at sgdisk time (manual-layout rows carry user-chosen partlabels,
    // so -cN:root can't be relied on). Written here — before the kernel
    // emerge — so installkernel's initramfs generation (dracut
    // --hostonly) picks it up.
    if (cfg.disk.luks)
        try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/crypttab", s(alloc, "cryptroot /dev/disk/by-partuuid/{s} none luks\n", .{partGuid(alloc, seed, rootPartIdx(cfg, env))})));
    return step(alloc, "portage-config", "Generate portage config", c);
}

fn planChroot(alloc: Allocator) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    for ([_][]const u8{ "/proc", "/sys", "/dev", "/run" }) |p|
        try c.append(alloc, argv(alloc, &.{ "mount", "--rbind", p, s(alloc, "/mnt/gentoo{s}", .{p}) }, s(alloc, "bind {s}", .{p})));
    // Keep the bound /dev out of the live env's propagation group: an rbind
    // stays shared, so a tmpfs we mount at dev/pts or dev/shm would otherwise
    // propagate back and shadow whatever the live env has there. Slave it
    // first (--make-rslave on util-linux, -o rslave on busybox).
    try c.append(alloc, argv(alloc, &.{
        "sh",                                                                                                  "-c",
        "mount --make-rslave /mnt/gentoo/dev 2>/dev/null || mount -o rslave /mnt/gentoo/dev 2>/dev/null || :",
    }, "slave the bound /dev before chroot submounts"));
    // Minimal/hand-rolled live envs can expose /dev/null & friends at 0600/0660
    // root:root or lack devpts, which breaks portage's userpriv/userfetch
    // children (they reopen os.devnull and allocate ptys). Normalize; no-op on
    // regular live media. /dev/shm gets a tmpfs because POSIX sem_open (python
    // multiprocessing, e.g. pybind11 parallel compiles) resolves under it and
    // an empty bound dir fails ENOENT.
    try c.append(alloc, argv(alloc, &.{
        "sh", "-c",
        "chmod a+rw /mnt/gentoo/dev/null /mnt/gentoo/dev/zero /mnt/gentoo/dev/full" ++
            " /mnt/gentoo/dev/random /mnt/gentoo/dev/urandom /mnt/gentoo/dev/tty 2>/dev/null; " ++
            "mkdir -p /mnt/gentoo/dev/pts /mnt/gentoo/dev/shm; " ++
            "mountpoint -q /mnt/gentoo/dev/pts 2>/dev/null || mount -t devpts devpts /mnt/gentoo/dev/pts 2>/dev/null; " ++
            "mountpoint -q /mnt/gentoo/dev/shm 2>/dev/null || mount -t tmpfs shm /mnt/gentoo/dev/shm 2>/dev/null; :",
    }, "normalize device nodes + devpts/devshm inside chroot"));
    try c.append(alloc, argv(alloc, &.{ "cp", "--dereference", "/etc/resolv.conf", "/mnt/gentoo/etc/" }, "dns into target"));
    try c.append(alloc, .{ .note = "subsequent chroot cmds run as: chroot /mnt/gentoo <cmd>" });
    return step(alloc, "enter-chroot", "Enter chroot", c);
}

fn planRepoSync(alloc: Allocator, cfg: *const Config) !Step {
    _ = cfg;
    var c: std.ArrayList(Cmd) = .empty;
    // Portage drops a repo whose `location` isn't a directory (seen on
    // bare live envs: "Invalid Repository Location" → "Repository
    // 'gentoo' not found"). Create it rather than relying on webrsync.
    try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo/var/db/repos/gentoo" }, "repo location dir"));
    try c.append(alloc, .{ .exec = .{
        .argv = try alloc.dupe([]const u8, &.{"emerge-webrsync"}),
        .chroot = true,
        .desc = "sync gentoo repo (webrsync; firewall-friendly)",
    } });
    // binrepos.conf entries are binary-package sources, not ebuild
    // repos — there is no `emerge --sync gentoobinhost`; getbinpkg
    // fetches the Packages index on demand.
    return step(alloc, "repo-sync", "Sync portage tree", c);
}

fn planProfile(alloc: Allocator, cfg: *const Config) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    try c.append(alloc, .{ .exec = .{
        .argv = try alloc.dupe([]const u8, &.{ "eselect", "profile", "list" }),
        .chroot = true,
        .desc = "list profiles (resolve stem → profile name)",
    } });
    const prof = try profilePath(alloc, cfg) orelse {
        try c.append(alloc, .{ .note = "profile path resolved after hardware detection (arch=detect)" });
        return step(alloc, "profile", "Select portage profile", c);
    };
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
    if (cfg.stage3.libc == .musl) {
        // musl has no locale-gen/SUPPORTED database — C.UTF-8 is builtin
        // and extra locales come from musl-locales via MUSL_LOCPATH. Set
        // the default through env.d directly (what eselect would write).
        try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/env.d/02locale", s(alloc, "LANG=\"{s}\"\nMUSL_LOCPATH=\"/usr/share/i18n/locales\"\n", .{cfg.system.locale})));
        try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "--oneshot", "sys-apps/musl-locales" }), .chroot = true, .desc = "musl locale data" } });
    } else {
        var gen: std.Io.Writer.Allocating = .init(alloc);
        const gw = &gen.writer;
        for (cfg.system.locales) |l|
            try gw.print("{s} UTF-8\n", .{l});
        try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/locale.gen", gen.written()));
        try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{"locale-gen"}), .chroot = true, .desc = "generate locales" } });
        try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "eselect", "locale", "set", cfg.system.locale }), .chroot = true, .desc = "default locale" } });
    }
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
    // SOF is Intel audio-DSP firmware — the package is amd64/x86-only in
    // ::gentoo, so emerging it elsewhere fails dep resolution outright.
    if (cfg.arch == .amd64)
        try fw_atoms.append(alloc, "sys-firmware/sof-firmware");
    if (ucodeAtom(cfg, env)) |atom| try fw_atoms.append(alloc, atom);
    try c.append(alloc, .{ .exec = .{
        .argv = try prepend(alloc, "emerge", fw_atoms.items),
        .chroot = true,
        .desc = "firmware + CPU microcode",
    } });
    // Block-stack userspace must exist in the TARGET before the kernel
    // emerge — installkernel's dracut hook runs in-chroot and the
    // crypt/lvm dracut modules need their tools there.
    if (cfg.disk.luks or cfg.disk.lvm) {
        var stack: std.ArrayList([]const u8) = .empty;
        try stack.append(alloc, "emerge");
        try stack.appendSlice(alloc, &.{ "--oneshot", "--newuse" });
        if (cfg.disk.luks) try stack.append(alloc, "sys-fs/cryptsetup");
        if (cfg.disk.lvm) try stack.append(alloc, "sys-fs/lvm2");
        // USE=cryptsetup (package.use/installer) only takes effect on a
        // rebuilt systemd — the stage3's binpkg predates it.
        if (cfg.disk.luks and cfg.system.init == .systemd)
            try stack.append(alloc, "sys-apps/systemd");
        try c.append(alloc, .{ .exec = .{ .argv = stack.items, .chroot = true, .desc = "cryptsetup/lvm2 for initramfs" } });
    }
    // The initramfs generator must exist before the kernel emerges —
    // the kernel package's installkernel hooks call it.
    switch (cfg.system.initramfs) {
        .dracut => {
            // dracut's crypt/lvm modules are hostonly-conditional — a
            // chrooted generic build omits them unless asked, which
            // leaves a LUKS/LVM root unattachable at boot.
            var mods: std.ArrayList(u8) = .empty;
            if (cfg.disk.luks or cfg.disk.lvm) {
                try mods.appendSlice(alloc, "add_dracutmodules+=\" ");
                if (cfg.disk.luks) try mods.appendSlice(alloc, "crypt ");
                if (cfg.disk.lvm) try mods.appendSlice(alloc, "lvm ");
                try mods.appendSlice(alloc, "\"\n");
                if (cfg.disk.luks)
                    // the crypt module only ships /etc/crypttab in
                    // hostonly mode — pull it explicitly.
                    try mods.appendSlice(alloc, "install_items+=\" /etc/crypttab \"\n");
                try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/dracut.conf.d/installer.conf", mods.items));
            }
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-kernel/dracut" }),
                .chroot = true,
                .desc = "dracut initramfs (early microcode on)",
            } });
        },
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
        .manual => {
            // gentoo-sources + the user's .config — the install at the
            // end runs installkernel, whose dracut hook generates the
            // initramfs and whose staging hook lands it on the boot
            // volume like any other kernel.
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-kernel/gentoo-sources", "sys-devel/bc", "sys-devel/bison", "sys-devel/flex", "dev-libs/elfutils", "dev-libs/openssl" }),
                .chroot = true,
                .desc = "gentoo-sources + kernel build deps",
            } });
            // The path is arbitrary live-env input — confirm it smells
            // like a .config before copying so a bad answer file can't
            // exfiltrate an unrelated host file into the target. Real
            // configs are a few hundred KiB; an 8 MiB cap both bounds
            // the grep and defines the max supported config size.
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", "[ -f \"$1\" ] && [ \"$(wc -c < \"$1\")\" -le 8388608 ] && grep -q CONFIG_ \"$1\"", "kcfg", cfg.system.kernel_config }),
                .desc = "verify kernel_config is a regular file ≤8MiB containing CONFIG_",
            } });
            try c.append(alloc, argv(alloc, &.{ "cp", cfg.system.kernel_config, "/mnt/gentoo/tmp/kernel.config" }, "stage .config into target"));
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", "eselect kernel set 1 && cp /tmp/kernel.config \"$(readlink -f /usr/src/linux)/.config\" && make -C /usr/src/linux olddefconfig && make -C /usr/src/linux -j\"$(nproc)\" && make -C /usr/src/linux modules_install && make -C /usr/src/linux install" }),
                .chroot = true,
                .desc = "build + install kernel from kernel_config (olddefconfig → make → install)",
            } });
        },
    }
    // GPU driver packages — resolve `auto` the same way make.conf's
    // VIDEO_CARDS / ACCEPT_LICENSE do (Turing+ → nvidia-open).
    const nvidia_prop = switch (resolveGpuDriver(cfg, env)) {
        .@"nvidia-open", .@"nvidia-drivers" => true,
        else => false,
    };
    // Secure boot: out-of-tree modules are signed at emerge time by
    // linux-mod-r1 (USE=modules-sign + MODULES_SIGN_* in make.conf), so
    // the sbctl key pair must exist before nvidia-drivers builds.
    if (cfg.security.secure_boot == .sbctl and nvidia_prop) {
        try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "emerge", "app-crypt/sbctl" }),
            .chroot = true,
            .desc = "sbctl (secure boot key mgmt)",
        } });
        try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "sbctl", "create-keys" }),
            .chroot = true,
            .desc = "generate secure boot keys (before module builds)",
        } });
    }
    if (cfg.security.secure_boot == .shim) {
        // make.conf points MODULES_SIGN_KEY at /etc/shim/mok.key — the
        // pair must exist before any module build (nvidia emerge below)
        // or linux-mod-r1 signs with a nonexistent key.
        try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", "umask 077 && mkdir -p /etc/shim && " ++
                "openssl req -new -x509 -newkey rsa:2048 -keyout /etc/shim/mok.key " ++
                "-out /etc/shim/mok.pem -days 3650 -nodes -subj '/CN=gentoo-installer-mok/' && " ++
                "openssl x509 -in /etc/shim/mok.pem -outform der -out /etc/shim/mok.der" }),
            .chroot = true,
            .desc = "generate the MOK key pair (before module builds)",
        } });
    }
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
    // proprietary NVIDIA is glibc + amd64/arm64 only — auto must not
    // pick it on musl or riscv64 targets.
    if (cfg.stage3.libc == .musl or cfg.arch == .riscv64) return .nouveau;
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

fn planFstab(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env, seed: u128) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    const root = rootMountArgs(alloc, cfg, env);
    // Persistent identifiers only: PARTUUID for partitions (assigned by
    // our own sgdisk -u flags), mapper/LV names where already stable —
    // kernel /dev/sdX names can shift across renumbering.
    const root_ident = rootIdent(alloc, cfg, env, seed);
    try w.writeAll("# generated by gentoo-installer (persistent ids)\n");
    if (cfg.disk.scheme == .manual) {
        // Every listed row maps to its assigned PARTUUID; root uses the
        // mapper name under LUKS.
        for (cfg.disk.partitions, 0..) |p, i| {
            const n: u32 = @intCast(i + 1);
            if (std.mem.eql(u8, p.fs, "swap"))
                try w.print("{s}\tnone\tswap\tsw\t0 0\n", .{partIdent(alloc, seed, n)});
            const m = rowMount(p);
            if (m.len == 0) continue;
            const ident = if (std.mem.eql(u8, m, "/")) root_ident else partIdent(alloc, seed, n);
            const opts = if (std.mem.eql(u8, m, "/") and root.opts.len > 0)
                s(alloc, "{s},defaults", .{root.opts})
            else
                "defaults";
            try w.print("{s}\t{s}\t{s}\t{s}\t0 {s}\n", .{ ident, m, p.fs, opts, if (std.mem.eql(u8, m, "/")) "1" else "2" });
        }
        // btrfs root: subvol mounts are part of the invariant layout
        // unless a row claims the mountpoint itself (mounted above).
        if (rootFsOf(cfg) == .btrfs) {
            if (config.manualMountPart(cfg, "/home") == null)
                try w.print("{s}\t/home\tbtrfs\tsubvol=@home,compress=zstd:1,noatime\t0 2\n", .{root_ident});
            if (config.manualMountPart(cfg, "/.snapshots") == null)
                try w.print("{s}\t/.snapshots\tbtrfs\tsubvol=@snapshots,compress=zstd:1,noatime\t0 2\n", .{root_ident});
        }
        if (cfg.disk.swap == .zram)
            try w.writeAll("# zram swap configured via zram-generator.conf (systemd) or /etc/init.d/zram (openrc)\n");
        try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/fstab", aw.written()));
        return step(alloc, "fstab", "Generate fstab", c);
    }
    try w.print("{s}\t/\t{s}\t{s}defaults\t0 1\n", .{ root_ident, @tagName(cfg.disk.root_fs), if (root.opts.len > 0) s(alloc, "{s},", .{root.opts}) else "" });
    if (cfg.boot_mode == .uefi) {
        // alongside reuses the existing ESP — fstab carries ITS partuuid.
        if (espIdent(alloc, cfg, env, seed)) |e|
            try w.print("{s}\t/efi\tvfat\tdefaults\t0 2\n", .{e});
    }
    if (cfg.disk.swap == .partition) {
        // erase layouts: swap is index 2 (after esp/biosboot); alongside
        // appends it as the first new partition (root_idx - 1).
        const swap_n = if (cfg.disk.scheme == .alongside) rootPartIdx(cfg, env) - 1 else 2;
        try w.print("{s}\tnone\tswap\tsw\t0 0\n", .{partIdent(alloc, seed, swap_n)});
    }
    if (cfg.disk.boot_part)
        try w.print("{s}\t/boot\t{s}\tdefaults\t0 2\n", .{ partIdent(alloc, seed, bootPartIdx(cfg)), bootPartFs(cfg) });
    if (cfg.disk.lvm and cfg.disk.home_part and cfg.disk.root_fs != .btrfs)
        try w.print("/dev/vg0/home\t/home\t{s}\tdefaults\t0 2\n", .{@tagName(cfg.disk.root_fs)});
    if (cfg.disk.root_fs == .btrfs) {
        try w.print("{s}\t/home\tbtrfs\tsubvol=@home,compress=zstd:1,noatime\t0 2\n", .{root_ident});
        try w.print("{s}\t/.snapshots\tbtrfs\tsubvol=@snapshots,compress=zstd:1,noatime\t0 2\n", .{root_ident});
    }
    if (cfg.disk.swap == .zram)
        try w.writeAll("# zram swap configured via zram-generator.conf (systemd) or /etc/init.d/zram (openrc)\n");
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
        try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/sysctl.d/60-zram.conf", "vm.swappiness = 180\n"));
        switch (cfg.system.init) {
            .systemd => {
                try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-apps/zram-generator" }), .chroot = true, .desc = "zram-generator" } });
                try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/systemd/zram-generator.conf", "[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = zstd\n"));
            },
            .openrc, .runit, .s6, .dinit => {
                // ::gentoo ships no openrc zram service (zram-init was
                // tree-cleaned; zram-generator is systemd-only), so the plan
                // installs a small runscript driving util-linux zramctl.
                // Alt inits all run `openrc sysinit`+`openrc boot` in their
                // stage-1, which is what executes this boot-runlevel unit.
                try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/etc/init.d/zram", .mode = 0o755, .content =
                    \\#!/sbin/openrc-run
                    \\description="zram compressed swap device"
                    \\
                    \\depend() {
                    \\    after localmount
                    \\    before swap
                    \\}
                    \\
                    \\start() {
                    \\    ebegin "Creating zram swap"
                    \\    modprobe zram 2>/dev/null || true
                    \\    mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
                    \\    size=$((mem_kb * 512))
                    \\    cap=$((8 * 1024 * 1024 * 1024))
                    \\    if [ "$size" -gt "$cap" ]; then size=$cap; fi
                    \\    dev=$(zramctl --find --size "$size" --algorithm zstd)
                    \\    [ -n "$dev" ] || { eend 1; return 1; }
                    \\    echo "$dev" > /run/zram-swap.dev || { zramctl --reset "$dev" 2>/dev/null; eend 1; return 1; }
                    \\    if mkswap "$dev" >/dev/null 2>&1 && swapon -p 100 "$dev"; then
                    \\        eend 0
                    \\    else
                    \\        zramctl --reset "$dev" 2>/dev/null
                    \\        rm -f /run/zram-swap.dev
                    \\        eend 1
                    \\    fi
                    \\}
                    \\
                    \\stop() {
                    \\    ebegin "Removing zram swap"
                    \\    dev=$(cat /run/zram-swap.dev 2>/dev/null)
                    \\    if [ -n "$dev" ]; then
                    \\        swapoff "$dev" 2>/dev/null
                    \\        zramctl --reset "$dev" 2>/dev/null
                    \\        rm -f /run/zram-swap.dev
                    \\    fi
                    \\    eend 0
                    \\}
                    \\
                } });
                try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "rc-update", "add", "zram", "boot" }), .chroot = true, .desc = "enable zram" } });
            },
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
    // init is installed on top and takes over as PID1 via init= on the
    // kernel cmdline (kernelArgs). All of them keep openrc for the
    // sysinit+boot runlevels — udev, fsck, mounts, sysctl, our zram unit —
    // and only the longrun supervision is init-native.
    switch (init) {
        .dinit => {
            // dinit lives in GURU as sys-apps/dinit (~amd64 only) —
            // enable the repo, unmask, and drop sysvinit FIRST: the
            // ebuild's `dosym dinit /sbin/init` collides with sysvinit's
            // /sbin/init, and its !sys-apps/sysvinit block wants it gone.
            try c.append(alloc, .{ .write_file = .{
                .path = "/mnt/gentoo/etc/portage/package.accept_keywords/dinit",
                .mode = 0o644,
                .content = "sys-apps/dinit ~amd64\n",
            } });
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "app-eselect/eselect-repository", "dev-vcs/git" }), .chroot = true, .desc = "eselect-repository + git (for GURU)" } });
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "eselect", "repository", "enable", "guru" }), .chroot = true, .desc = "enable GURU overlay" } });
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emaint", "sync", "-r", "guru" }), .chroot = true, .desc = "sync GURU" } });
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "--unmerge", "sys-apps/sysvinit" }), .chroot = true, .desc = "unmerge sysvinit (dinit takes PID1)" } });
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-apps/dinit" }), .chroot = true, .desc = "dinit (PID1 + service manager)" } });
        },
        .runit => {
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-process/runit" }), .chroot = true, .desc = "runit (PID1 + runsvdir)" } });
            // sysvinit's /sbin/{poweroff,halt,shutdown,reboot} talk to an
            // initctl fifo nobody serves under runit PID1 — drop the
            // package so the runit wrappers installed below stand alone.
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "--unmerge", "sys-apps/sysvinit" }), .chroot = true, .desc = "unmerge sysvinit (runit takes PID1)" } });
        },
        .s6 => {
            // s6 stack is ~arch-keyworded in ::gentoo on some arches.
            try c.append(alloc, .{ .write_file = .{
                .path = "/mnt/gentoo/etc/portage/package.accept_keywords/s6",
                .mode = 0o644,
                .content = "dev-lang/execline ~amd64 ~arm64 ~riscv\nsys-apps/s6 ~amd64 ~arm64 ~riscv\nsys-apps/s6-rc ~amd64 ~arm64 ~riscv\nsys-apps/s6-linux-init ~amd64 ~arm64 ~riscv\nsys-apps/s6-linux-utils ~amd64 ~arm64 ~riscv\nsys-apps/s6-portable-utils ~amd64 ~arm64 ~riscv\nsys-libs/skalibs ~amd64 ~arm64 ~riscv\n",
            } });
            // sysvinit goes FIRST: s6-linux-init RDEPENDs !sys-apps/sysvinit
            // (its bin/init takes the /sbin/init slot) and the initctl tools
            // hang under a foreign PID1 anyway.
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "--unmerge", "sys-apps/sysvinit" }), .chroot = true, .desc = "unmerge sysvinit (s6 takes PID1)" } });
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-apps/s6", "sys-apps/s6-rc", "sys-apps/s6-linux-init", "sys-apps/s6-linux-utils", "sys-apps/s6-portable-utils" }), .chroot = true, .desc = "s6 + s6-rc + s6-linux-init" } });
        },
        else => {},
    }
    // Boot scaffolding per init — a shared stage-1 script every
    // supervisor execs before taking over service supervision.
    if (init != .openrc and init != .systemd) {
        try c.append(alloc, .{ .write_file = .{
            .path = "/mnt/gentoo/usr/libexec/gi-sysinit",
            .mode = 0o755,
            .content = "#!/bin/sh\n# early boot stays with openrc — its sysinit/boot runlevels cover\n# udev, fsck, mounts, sysctl and the generated init.d units.\n/sbin/openrc sysinit\n/sbin/openrc boot\n",
        } });
    }
    switch (init) {
        .dinit => {
            // The boot target is a real service: `waits-for.d` makes every
            // link in boot.d/ a unit dinit starts before `boot` completes.
            try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo/etc/dinit.d/boot.d" }, "dinit.d dirs"));
            try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/dinit.d/boot", "type = internal\nwaits-for.d: boot.d\n"));
            try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/dinit.d/sysinit", "type = scripted\ncommand = /usr/libexec/gi-sysinit\n"));
            // gettys on the vt consoles (serial getty is added by tests/
            // installs that need it — console= decides what's live).
            for ([_]u8{ '1', '2', '3', '4' }) |n| {
                const name = s(alloc, "tty{c}", .{n});
                try c.append(alloc, wf(alloc, s(alloc, "/mnt/gentoo/etc/dinit.d/{s}", .{name}), s(alloc, "type = process\ncommand = /sbin/agetty {s} 38400 linux\nrestart = true\ndepends-on = sysinit\n", .{name})));
                try c.append(alloc, argv(alloc, &.{ "ln", "-sf", s(alloc, "../{s}", .{name}), s(alloc, "/mnt/gentoo/etc/dinit.d/boot.d/{s}", .{name}) }, s(alloc, "boot.d {s}", .{name})));
            }
            try c.append(alloc, argv(alloc, &.{ "ln", "-sf", "../sysinit", "/mnt/gentoo/etc/dinit.d/boot.d/sysinit" }, "boot.d sysinit"));
            // Gentoo's dinit ebuild ships no shutdown utility, but PID1
            // execs `/usr/sbin/shutdown --system <-h|-r|-p>` once services
            // stop (and immediately on SIGQUIT). That process IS init —
            // it must reboot(2) itself and never exit, so a compiled
            // binary is required (a shell script's exit panics the
            // kernel, and sysrq 'o' needs a live usermode-helper).
            // dinitctl can only request HALT, so -h maps to power off.
            try c.append(alloc, .{ .write_file = .{
                .path = "/mnt/gentoo/usr/src/gi-shutdown.c",
                .mode = 0o644,
                .content =
                \\/* gentoo-installer dinit shutdown — dual role:
                \\ * `shutdown --system -X` (exec'd by dinit PID1 after
                \\ *   services stop): sync + reboot(2), never return.
                \\ * `shutdown [-r]` (user): reboot asks PID1 directly
                \\ *   (SIGINT) — dinitctl can only request HALT. */
                \\#include <signal.h>
                \\#include <string.h>
                \\#include <sys/reboot.h>
                \\#include <unistd.h>
                \\int main(int argc, char **argv)
                \\{
                \\    int sys = 0, cmd = RB_POWER_OFF;
                \\    for (int i = 1; i < argc; i++) {
                \\        if (!strcmp(argv[i], "--system")) sys = 1;
                \\        if (!strcmp(argv[i], "-r") || !strcmp(argv[i], "-k") ||
                \\            !strcmp(argv[i], "-s")) cmd = RB_AUTOBOOT;
                \\    }
                \\    if (!sys) {
                \\        if (cmd == RB_AUTOBOOT) {
                \\            if (kill(1, SIGINT)) {
                \\                write(2, "shutdown: cannot signal init\n", 28);
                \\                _exit(1);
                \\            }
                \\            _exit(0);
                \\        }
                \\        execl("/sbin/dinitctl", "dinitctl", "shutdown", (char *)0);
                \\        _exit(1);
                \\    }
                \\    sync();
                \\    reboot(cmd);
                \\    for (;;) pause();
                \\}
                ,
            } });
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", "cc -O2 -o /usr/sbin/shutdown /usr/src/gi-shutdown.c || " ++
                    "gcc -O2 -o /usr/sbin/shutdown /usr/src/gi-shutdown.c || " ++
                    "clang -O2 -o /usr/sbin/shutdown /usr/src/gi-shutdown.c" }),
                .chroot = true,
                .desc = "build the dinit shutdown binary",
            } });
            for ([_][]const u8{ "poweroff", "halt" }) |name|
                try c.append(alloc, .{ .write_file = .{ .path = s(alloc, "/mnt/gentoo/sbin/{s}", .{name}), .mode = 0o755, .content = "#!/bin/sh\nexec /usr/sbin/shutdown\n" } });
            try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/sbin/reboot", .mode = 0o755, .content = "#!/bin/sh\nkill -INT 1\n" } });
        },
        .runit => {
            // runit-init runs /etc/runit/{1,2,3}: sysinit via openrc,
            // then runsvdir on the default sv dir, openrc shutdown last.
            try c.append(alloc, argv(alloc, &.{ "mkdir", "-p", "/mnt/gentoo/etc/runit/runsvdir/default", "/mnt/gentoo/etc/sv" }, "runit dirs"));
            try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/etc/runit/1", .mode = 0o755, .content = "#!/bin/sh\nexec /usr/libexec/gi-sysinit\n" } });
            try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/etc/runit/2", .mode = 0o755, .content = "#!/bin/sh\nexec /usr/bin/runsvdir -P /etc/runit/runsvdir/default\n" } });
            try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/etc/runit/3", .mode = 0o755, .content = "#!/bin/sh\nexec /sbin/openrc shutdown\n" } });
            // Shutdown commands: `runit-init 0` signals PID1 to end
            // stage2, run stage3, then power off; `6` reboots.
            // `shutdown -r` must reboot, so shutdown parses its args.
            for ([_][]const u8{ "poweroff", "halt" }) |name|
                try c.append(alloc, .{ .write_file = .{ .path = s(alloc, "/mnt/gentoo/sbin/{s}", .{name}), .mode = 0o755, .content = "#!/bin/sh\nexec /sbin/runit-init 0\n" } });
            try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/sbin/shutdown", .mode = 0o755, .content = "#!/bin/sh\ncase \" $*\" in\n  *\" -r\"*) exec /sbin/runit-init 6 ;;\n  *) exec /sbin/runit-init 0 ;;\nesac\n" } });
            try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/sbin/reboot", .mode = 0o755, .content = "#!/bin/sh\nexec /sbin/runit-init 6\n" } });
        },
        .s6 => {
            // s6-linux-init-maker emits a staging dir: bin/ holds init +
            // sysvinit-compat tools, run-image/ env/ scripts/ form the
            // runtime layout the init binary expects at /etc/s6-linux-init.
            // Generate in chroot, install with s6-hiercopy (mode-preserving).
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "s6-linux-init-maker", "/root/gi-mk" }), .chroot = true, .desc = "s6-linux-init skeldir" } });
            // The default basedir (-c) is /etc/s6-linux-init/current —
            // bin/init embeds it, so the copy must land exactly there.
            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "s6-hiercopy", "/root/gi-mk", "/etc/s6-linux-init/current" }), .chroot = true, .desc = "install s6 runtime dirs" } });
            for ([_][]const u8{ "init", "halt", "poweroff", "reboot", "shutdown", "telinit" }) |b|
                try c.append(alloc, argv(alloc, &.{ "cp", "-a", s(alloc, "/mnt/gentoo/root/gi-mk/bin/{s}", .{b}), s(alloc, "/mnt/gentoo/sbin/{s}", .{b}) }, s(alloc, "install s6 {s}", .{b})));
            try c.append(alloc, argv(alloc, &.{ "rm", "-rf", "/mnt/gentoo/root/gi-mk" }, "drop maker staging"));
            // Upstream requirement (s6-linux-init skel rc.shutdown): under
            // s6 PID1, openrc's shutdown runlevel must not run killprocs
            // or mount-ro — they kill the s6 supervision tree mid-teardown
            // and stage 3 never finishes.
            try c.append(alloc, argv(alloc, &.{ "rm", "-f", "/mnt/gentoo/etc/runlevels/shutdown/killprocs", "/mnt/gentoo/etc/runlevels/shutdown/mount-ro" }, "strip killprocs/mount-ro from shutdown runlevel"));
            // rc.init is stage 2: openrc owns sysinit/boot (gi-sysinit),
            // then s6-rc-init opens the compiled db on the live scandir
            // and brings up the default bundle ($1 is the boot runlevel).
            try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/etc/s6-linux-init/current/scripts/rc.init", .mode = 0o755, .content = "#!/bin/sh\n/usr/libexec/gi-sysinit\ns6-rc-init -c /etc/s6-rc/compiled /run/service || exit 1\nexec s6-rc -u change \"${1:-default}\"\n" } });
            // Bundle down first, then openrc's shutdown runlevel — the
            // sysinit oneshot has no down action, so zram/mounts/sysctl
            // state needs openrc's own teardown (same as runit's /3).
            try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/etc/s6-linux-init/current/scripts/rc.shutdown", .mode = 0o755, .content = "#!/bin/sh\ns6-rc -da change default || true\nopenrc shutdown || true\nexit 0\n" } });
            // s6-rc source db: sysinit is a oneshot every unit depends on,
            // tty1-4 are supervised agettys, `default` bundles them all.
            // The bundle's contents file is appended per enabled unit in
            // the services loop below, then s6-rc-compile bakes the db.
            try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/etc/s6-rc/source/sysinit/type", .mode = 0o644, .content = "oneshot\n" } });
            try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/etc/s6-rc/source/sysinit/up", .mode = 0o644, .content = "/usr/libexec/gi-sysinit\n" } });
            try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/etc/s6-rc/source/default/type", .mode = 0o644, .content = "bundle\n" } });
            try c.append(alloc, .{ .write_file = .{ .path = "/mnt/gentoo/etc/s6-rc/source/default/contents", .mode = 0o644, .content = "sysinit\ntty1\ntty2\ntty3\ntty4\n" } });
            for ([_]u8{ '1', '2', '3', '4' }) |n| {
                const name = s(alloc, "tty{c}", .{n});
                try c.append(alloc, .{ .write_file = .{ .path = s(alloc, "/mnt/gentoo/etc/s6-rc/source/{s}/type", .{name}), .mode = 0o644, .content = "longrun\n" } });
                try c.append(alloc, .{ .write_file = .{ .path = s(alloc, "/mnt/gentoo/etc/s6-rc/source/{s}/run", .{name}), .mode = 0o755, .content = s(alloc, "#!/bin/sh\nexec /sbin/agetty {s} 38400 linux\n", .{name}) } });
                try c.append(alloc, .{ .write_file = .{ .path = s(alloc, "/mnt/gentoo/etc/s6-rc/source/{s}/dependencies", .{name}), .mode = 0o644, .content = "sysinit\n" } });
            }
        },
        else => {},
    }

    for (enables.items) |e| {
        switch (init) {
            .systemd => try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "systemctl", "enable", e.name }), .chroot = true, .desc = s(alloc, "enable {s}", .{e.name}) } }),
            .openrc => try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "rc-update", "add", e.name, e.runlevel }), .chroot = true, .desc = s(alloc, "rc-update {s}", .{e.name}) } }),
            .runit, .dinit, .s6 => {
                // sysklogd is two daemons — one supervised unit each.
                const units: []const []const u8 = if (std.mem.eql(u8, e.name, "sysklogd"))
                    &.{ "syslogd", "klogd" }
                else
                    &.{e.name};
                for (units) |u| {
                    const cmd = altSvcCmd(u) orelse {
                        try c.append(alloc, .{ .note = s(alloc, "no {s} unit for {s} — enable it manually", .{ @tagName(init), u }) });
                        continue;
                    };
                    switch (init) {
                        .runit => {
                            try c.append(alloc, .{ .write_file = .{
                                .path = s(alloc, "/mnt/gentoo/etc/sv/{s}/run", .{u}),
                                .mode = 0o755,
                                .content = s(alloc, "#!/bin/sh\nexec {s} 2>&1\n", .{cmd}),
                            } });
                            try c.append(alloc, argv(alloc, &.{ "ln", "-sf", s(alloc, "/etc/sv/{s}", .{u}), s(alloc, "/mnt/gentoo/etc/runit/runsvdir/default/{s}", .{u}) }, s(alloc, "runit enable {s}", .{u})));
                        },
                        .dinit => {
                            try c.append(alloc, wf(alloc, s(alloc, "/mnt/gentoo/etc/dinit.d/{s}", .{u}), s(alloc, "type = process\ncommand = {s}\nrestart = true\ndepends-on = sysinit\n", .{cmd})));
                            try c.append(alloc, argv(alloc, &.{ "ln", "-sf", s(alloc, "../{s}", .{u}), s(alloc, "/mnt/gentoo/etc/dinit.d/boot.d/{s}", .{u}) }, s(alloc, "dinit enable {s}", .{u})));
                        },
                        .s6 => {
                            try c.append(alloc, .{ .write_file = .{ .path = s(alloc, "/mnt/gentoo/etc/s6-rc/source/{s}/type", .{u}), .mode = 0o644, .content = "longrun\n" } });
                            try c.append(alloc, .{ .write_file = .{ .path = s(alloc, "/mnt/gentoo/etc/s6-rc/source/{s}/run", .{u}), .mode = 0o755, .content = s(alloc, "#!/bin/sh\nexec {s}\n", .{cmd}) } });
                            try c.append(alloc, .{ .write_file = .{ .path = s(alloc, "/mnt/gentoo/etc/s6-rc/source/{s}/dependencies", .{u}), .mode = 0o644, .content = "sysinit\n" } });
                            try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc, "echo {s} >> /etc/s6-rc/source/default/contents", .{u}) }), .chroot = true, .desc = s(alloc, "s6-rc bundle {s}", .{u}) } });
                        },
                        else => unreachable,
                    }
                }
            },
        }
    }
    if (init == .s6)
        try c.append(alloc, .{ .exec = .{ .argv = try alloc.dupe([]const u8, &.{ "s6-rc-compile", "/etc/s6-rc/compiled", "/etc/s6-rc/source" }), .chroot = true, .desc = "compile s6-rc database" } });
    return step(alloc, "services", "Enable services", c);
}

/// Foreground invocation for a supervised service — the command a
/// runit run script or dinit service file execs. null for units with
/// no alt-init equivalent (openrc init.d scripts like net.*).
fn altSvcCmd(name: []const u8) ?[]const u8 {
    const map = .{
        .{ "dhcpcd", "/sbin/dhcpcd -B -q" },
        .{ "NetworkManager", "/usr/sbin/NetworkManager -n" },
        .{ "sshd", "/usr/sbin/sshd -D" },
        .{ "cronie", "/usr/sbin/crond -n" },
        .{ "chronyd", "/usr/sbin/chronyd -n" },
        .{ "syslogd", "/usr/sbin/syslogd -n" },
        .{ "klogd", "/usr/sbin/klogd -n" },
        .{ "iwd", "/usr/libexec/iwd" },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, name, m[0])) return m[1];
    }
    return null;
}

/// packages step: preset-resolved sets + config atoms actually emerge.
fn planPackages(alloc: Allocator, cfg: *const Config, sets: Sets) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    // overlay repos a set asked for (e.g. cosmic) — enable + sync first.
    // A preset [[repos]] entry with sync_uri is unknown to eselect: write
    // the repos.conf file and sync it directly instead. Git sync needs
    // dev-vcs/git in the target — stage3s don't guarantee it.
    var needs_git = false;
    for (sets.repos) |repo| if (repo.sync_uri != null) {
        needs_git = true;
        break;
    };
    if (needs_git)
        try c.append(alloc, .{ .exec = .{
            .argv = try alloc.dupe([]const u8, &.{ "emerge", "--noreplace", "dev-vcs/git" }),
            .chroot = true,
            .desc = "git for overlay sync",
        } });
    for (sets.repos) |repo| {
        // repo names land in a repos.conf path + [section] — no traversal.
        if (!stepNameOk(repo.name)) return error.BadRepo;
        if (repo.sync_uri) |uri| {
            try c.append(alloc, wf(alloc, s(alloc, "/mnt/gentoo/etc/portage/repos.conf/{s}.conf", .{repo.name}), s(alloc, "[{s}]\nlocation = /var/db/repos/{s}\nsync-type = git\nsync-uri = {s}\nauto-sync = yes\n", .{ repo.name, repo.name, uri })));
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "emaint", "sync", "-r", repo.name }),
                .chroot = true,
                .desc = s(alloc, "sync {s} overlay (sync_uri)", .{repo.name}),
            } });
        } else {
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "eselect", "repository", "enable", repo.name }),
                .chroot = true,
                .desc = s(alloc, "enable {s} overlay", .{repo.name}),
            } });
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "emaint", "sync", "-r", repo.name }),
                .chroot = true,
                .desc = s(alloc, "sync {s} overlay", .{repo.name}),
            } });
        }
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

fn planBootloader(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env, seed: u128) !Step {
    var c: std.ArrayList(Cmd) = .empty;
    const bl = config.resolveBootloader(cfg);
    const nvidia_prop_sbctl = cfg.security.secure_boot == .sbctl and switch (resolveGpuDriver(cfg, env)) {
        .@"nvidia-open", .@"nvidia-drivers" => true,
        else => false,
    };
    switch (bl) {
        .limine => {
            const limine_atoms: []const []const u8 =
                if (cfg.boot_mode == .bios)
                    &.{ "sys-boot/limine", "sys-fs/dosfstools" } // fsck.vfat for the FAT /boot
                else
                    &.{"sys-boot/limine"};
            try c.append(alloc, .{ .exec = .{
                .argv = try prepend(alloc, "emerge", limine_atoms),
                .chroot = true,
                .desc = "limine",
            } });
            if (cfg.boot_mode == .uefi) {
                if (cfg.disk.scheme == .alongside) {
                    // Shared ESP: install under a scoped dir and register
                    // a NVRAM entry — never overwrite EFI/BOOT (the
                    // firmware fallback could belong to another loader).
                    try c.append(alloc, .{ .exec = .{
                        .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-boot/efibootmgr" }),
                        .chroot = true,
                        .desc = "efibootmgr (NVRAM entry on shared ESP)",
                    } });
                    try c.append(alloc, .{ .exec = .{
                        .argv = try alloc.dupe([]const u8, &.{ "mkdir", "-p", s(alloc, "{s}/EFI/gentoo", .{espInTarget(cfg)}) }),
                        .chroot = true,
                        .desc = "scoped ESP dir",
                    } });
                    try c.append(alloc, .{ .exec = .{
                        .argv = try alloc.dupe([]const u8, &.{ "cp", s(alloc, "/usr/share/limine/{s}", .{efiBootFile(cfg)}), s(alloc, "{s}/EFI/gentoo/", .{espInTarget(cfg)}) }),
                        .chroot = true,
                        .desc = s(alloc, "limine EFI binary ({s})", .{efiBootFile(cfg)}),
                    } });
                    try c.append(alloc, .{ .exec = .{
                        .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc, "esp=$(findmnt -no SOURCE {s}) || exit 1; " ++
                            "d=$(lsblk -no PKNAME \"$esp\"); p=$(lsblk -no PARTN \"$esp\"); " ++
                            "[ -n \"$d\" ] && [ -n \"$p\" ] || exit 1; " ++
                            "efibootmgr -c -d /dev/$d -p $p -L 'Gentoo (limine)' " ++
                            "-l '\\EFI\\gentoo\\{s}'", .{ espInTarget(cfg), efiBootFile(cfg) }) }),
                        .chroot = true,
                        .desc = "efibootmgr: limine NVRAM entry (coexists with other loaders)",
                    } });
                } else {
                    try c.append(alloc, .{ .exec = .{
                        .argv = try alloc.dupe([]const u8, &.{ "mkdir", "-p", s(alloc, "{s}/EFI/BOOT", .{espInTarget(cfg)}) }),
                        .chroot = true,
                        .desc = "ESP layout",
                    } });
                    try c.append(alloc, .{ .exec = .{
                        .argv = try alloc.dupe([]const u8, &.{ "cp", s(alloc, "/usr/share/limine/{s}", .{efiBootFile(cfg)}), s(alloc, "{s}/EFI/BOOT/", .{espInTarget(cfg)}) }),
                        .chroot = true,
                        .desc = s(alloc, "limine EFI binary ({s})", .{efiBootFile(cfg)}),
                    } });
                }
            } else {
                // limine-bios.sys must exist on a partition BEFORE
                // bios-install — it embeds a hint to the stage3's
                // location into the BIOS-boot partition's stages.
                try c.append(alloc, .{ .exec = .{
                    .argv = try alloc.dupe([]const u8, &.{ "cp", "/usr/share/limine/limine-bios.sys", "/boot/limine-bios.sys" }),
                    .chroot = true,
                    .desc = "limine BIOS stage3 payload",
                } });
                // GPT has no post-MBR gap — stage2 lives in the EF02
                // partition, passed by 1-based index (validation
                // guarantees one exists on BIOS configs).
                const bbp = biosBootIdx(cfg).?;
                try c.append(alloc, .{ .exec = .{
                    .argv = try alloc.dupe([]const u8, &.{ "limine", "bios-install", cfg.disk.device, s(alloc, "{}", .{bbp}) }),
                    .chroot = true,
                    .desc = "limine BIOS stages",
                } });
            }
            // Limine's boot volume: the ESP under UEFI, /boot under BIOS
            // (a separate ext4 partition when disk.boot_part, else the
            // root fs — validation restricts bare-root BIOS to ext4).
            const stage_dir = if (cfg.boot_mode == .uefi) espInTarget(cfg) else "/boot";
            try c.append(alloc, wf(alloc, s(alloc, "/mnt/gentoo{s}/limine.conf", .{stage_dir}), limineConf(alloc, cfg, env, seed)));
            if (cfg.disk.scheme == .alongside) {
                // Menu merge: chainload the firmware's other loaders when
                // they exist on the shared ESP. Guarded — absence is fine.
                try c.append(alloc, .{ .exec = .{
                    .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc, "esp={s}; " ++
                        "if [ -f \"$esp/EFI/Microsoft/Boot/bootmgfw.efi\" ]; then " ++
                        "printf '\\n/Windows\\n    protocol: efi_chainload\\n    image_path: boot():/EFI/Microsoft/Boot/bootmgfw.efi\\n' >> \"$esp/limine.conf\"; " ++
                        "fi; if [ -f \"$esp/EFI/BOOT/BOOTX64.EFI\" ]; then " ++
                        "printf '\\n/Other loader (fallback)\\n    protocol: efi_chainload\\n    image_path: boot():/EFI/BOOT/BOOTX64.EFI\\n' >> \"$esp/limine.conf\"; " ++
                        "fi; true", .{espInTarget(cfg)}) }),
                    .chroot = true,
                    .desc = "limine.conf: chainload entries for existing ESP loaders",
                } });
            }
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
                    \\{s}
                    \\exit 0
                , .{ stage_dir, hookInitrd(alloc, cfg, "$esp/initramfs.img") }),
                .mode = 0o755,
            } });
            // The hook only fires for FUTURE kernel installs — the kernel
            // emerged earlier this install was never staged. Stage it now.
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc, "k=$(ls -t /boot/vmlinuz-* /boot/kernel-* /boot/*/*/vmlinuz /boot/*/*/linux 2>/dev/null | head -n1); " ++
                    "[ -n \"$k\" ] || {{ echo 'no kernel to stage' >&2; exit 1; }}; " ++
                    "cp -f \"$k\" {s}/vmlinuz || exit 1{s}", .{ stage_dir, initrdStage(alloc, cfg, stage_dir) }) }),
                .chroot = true,
                .desc = "stage current kernel + initramfs for limine",
            } });
        },
        .grub => {
            var grub_args: std.ArrayList([]const u8) = .empty;
            try grub_args.appendSlice(alloc, &.{ "emerge", "sys-boot/grub" });
            try c.append(alloc, .{ .exec = .{ .argv = grub_args.items, .chroot = true, .desc = "grub" } });
            // grub-mkconfig composes root= itself; extra args go through
            // GRUB_CMDLINE_LINUX_DEFAULT — proprietary NVIDIA needs KMS.
            const nvidia_prop = switch (resolveGpuDriver(cfg, env)) {
                .@"nvidia-open", .@"nvidia-drivers" => true,
                else => false,
            };
            if (nvidia_prop or cfg.disk.scheme == .alongside) {
                const grub_default = s(alloc, "# generated by gentoo-installer\n{s}{s}", .{
                    if (nvidia_prop) "GRUB_CMDLINE_LINUX_DEFAULT=\"nvidia-drm.modeset=1\"\n" else "",
                    if (cfg.disk.scheme == .alongside) "GRUB_DISABLE_OS_PROBER=false\n" else "",
                });
                try c.append(alloc, wf(alloc, "/mnt/gentoo/etc/default/grub", grub_default));
            }
            if (cfg.disk.scheme == .alongside)
                try c.append(alloc, .{ .exec = .{
                    .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-boot/os-prober" }),
                    .chroot = true,
                    .desc = "os-prober (dual-boot detection for grub.cfg)",
                } });
            const target = if (cfg.boot_mode == .uefi) grubEfiTarget(cfg) else "i386-pc";
            // grub's ebuild does not RDEPEND on efibootmgr, and without it
            // grub-install fails outright on an EFI-booted live env —
            // merge it whenever the NVRAM-registering path can be taken.
            if (cfg.boot_mode == .uefi)
                try c.append(alloc, .{ .exec = .{
                    .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-boot/efibootmgr" }),
                    .chroot = true,
                    .desc = "efibootmgr (grub-install NVRAM registration)",
                } });
            if (cfg.boot_mode == .uefi)
                try c.append(alloc, .{
                    .exec = .{
                        // shim owns the NVRAM entry — under --no-nvram
                        // grub-install only lays modules + boot files. When the
                        // live env wasn't EFI-booted (riscv64 OpenSBI direct-kernel
                        // bring-up) efibootmgr can't register an entry — install
                        // --removable instead, which also writes the
                        // EFI/BOOT/BOOT<arch>.EFI fallback U-Boot/EDK2 scan for.
                        .argv = if (cfg.security.secure_boot == .shim)
                            try alloc.dupe([]const u8, &.{ "grub-install", s(alloc, "--target={s}", .{grubEfiTarget(cfg)}), s(alloc, "--efi-directory={s}", .{espInTarget(cfg)}), "--no-nvram" })
                        else
                            // --removable overwrites EFI/BOOT/BOOT<arch>.EFI
                            // — on a shared (alongside) ESP preserve whatever
                            // loader sits there. $f.gentoo is a reference copy of
                            // the fallback WE last wrote (refreshed after each
                            // successful install): a live fallback matching it is
                            // ours; anything else (first-run foreign loader, or
                            // one an OS update swapped in later) goes to the next
                            // free .bak/.bakN before grub-install writes ours.
                            try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc, "if [ -d /sys/firmware/efi/efivars ]; then exec grub-install --target={s} --efi-directory={s}; else f={s}/EFI/BOOT/{s}; r=$f.gentoo; if [ -f $f ] && ! cmp -s $f $r 2>/dev/null; then b=$f.bak; n=1; while [ -f $b ]; do b=$f.bak$n; n=$((n+1)); done; cp -f $f $b || exit 1; fi; grub-install --target={s} --efi-directory={s} --removable && cp -f $f $r; fi", .{ grubEfiTarget(cfg), espInTarget(cfg), espInTarget(cfg), efiBootFile(cfg), grubEfiTarget(cfg), espInTarget(cfg) }) }),
                        .chroot = true,
                        .desc = "grub-install UEFI",
                    },
                })
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
            // bootctl unconditionally writes EFI/BOOT/BOOTX64.EFI — on a
            // shared ESP that hijacks the firmware fallback. VALIDATE
            // refuses alongside+systemd-boot, so this is only reached on
            // our own ESP.
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "bootctl", "install" }),
                .chroot = true,
                .desc = "systemd-boot (UEFI only)",
            } });
            // bootctl only installs the manager — a Type-1 entry needs the
            // kernel + initramfs staged on the ESP and a loader entry.
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc, "k=$(ls -t /boot/vmlinuz-* /boot/kernel-* /boot/*/*/vmlinuz /boot/*/*/linux 2>/dev/null | head -n1); " ++
                    "[ -n \"$k\" ] || {{ echo 'no kernel to stage' >&2; exit 1; }}; " ++
                    "mkdir -p {s}/loader/entries && cp -f \"$k\" {s}/vmlinuz || exit 1{s}", .{ espInTarget(cfg), espInTarget(cfg), initrdStage(alloc, cfg, espInTarget(cfg)) }) }),
                .chroot = true,
                .desc = "stage kernel + initramfs on the ESP",
            } });
            try c.append(alloc, wf(alloc, s(alloc, "/mnt/gentoo{s}/loader/loader.conf", .{espInTarget(cfg)}), "default gentoo.conf\ntimeout 4\n"));
            try c.append(alloc, wf(alloc, s(alloc, "/mnt/gentoo{s}/loader/entries/gentoo.conf", .{espInTarget(cfg)}), s(alloc, "title   Gentoo Linux\nlinux   /vmlinuz\n{s}options {s}\n", .{ if (cfg.system.initramfs == .none) "" else "initrd  /initramfs.img\n", kernelArgs(alloc, cfg, env, seed) })));
            // kernel-install hook keeps the entry current on upgrades.
            try c.append(alloc, .{ .write_file = .{
                .path = "/mnt/gentoo/etc/kernel/install.d/91-sd-boot.install",
                .content = s(alloc,
                    \\#!/bin/sh
                    \\# gentoo-installer systemd-boot hook: restage kernel+initramfs
                    \\# onto the ESP at the fixed paths the loader entry uses.
                    \\# args: $1=command $2=kver $3=entry_dir_abs $4=kernel_image
                    \\[ "$1" = add ] || exit 0
                    \\cp -f "$4" {s}/vmlinuz || exit 1
                    \\{s}
                    \\exit 0
                , .{ espInTarget(cfg), hookInitrd(alloc, cfg, s(alloc, "{s}/initramfs.img", .{espInTarget(cfg)})) }),
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
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc, "k=$(ls -t /boot/vmlinuz-* /boot/kernel-* /boot/*/*/vmlinuz /boot/*/*/linux 2>/dev/null | head -n1); " ++
                    "[ -n \"$k\" ] || {{ echo 'no kernel to stage' >&2; exit 1; }}; " ++
                    "cp -f \"$k\" {s}/vmlinuz || exit 1{s}", .{ espInTarget(cfg), initrdStage(alloc, cfg, espInTarget(cfg)) }) }),
                .chroot = true,
                .desc = "stage kernel + initramfs on the ESP",
            } });
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc, "esp=$(findmnt -no SOURCE {s}) || exit 1; " ++
                    "d=$(lsblk -no PKNAME \"$esp\"); p=$(lsblk -no PARTN \"$esp\"); " ++
                    "[ -n \"$d\" ] && [ -n \"$p\" ] || exit 1; " ++
                    "efibootmgr -c -d /dev/$d -p $p -L Gentoo -l '\\vmlinuz' " ++
                    "-u '{s}{s}'", .{ espInTarget(cfg), kernelArgs(alloc, cfg, env, seed), if (cfg.system.initramfs == .none) "" else " initrd=\\initramfs.img" }) }),
                .chroot = true,
                .desc = "efibootmgr: create Gentoo NVRAM entry",
            } });
        },
        .refind => {
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-boot/refind" }),
                .chroot = true,
                .desc = "rEFInd package",
            } });
            // refind-install copies the manager + filesystem drivers onto
            // the mounted ESP and creates the NVRAM entry; --alldrivers
            // lets it read kernels off /boot (btrfs/ext4/xfs). On a shared
            // (alongside) ESP we must NOT pass --usedefault — that would
            // install rEFInd as EFI/BOOT/BOOTX64.EFI, hijacking whatever
            // fallback loader already lives there.
            try c.append(alloc, .{
                .exec = .{
                    .argv = if (cfg.disk.scheme == .alongside)
                        // no positional device — that operand only pairs with
                        // --usedefault; without it refind-install discovers
                        // the already-mounted ESP itself.
                        try alloc.dupe([]const u8, &.{ "refind-install", "--alldrivers" })
                    else
                        try alloc.dupe([]const u8, &.{ "refind-install", "--alldrivers", "--usedefault", espPath(alloc, cfg, env) orelse partPath(alloc, cfg.disk.device, 1) }),
                    .chroot = true,
                    .desc = "install rEFInd to ESP + NVRAM entry",
                },
            });
            try c.append(alloc, .{ .note = "rEFInd auto-discovers kernels+initramfs on /boot via its fs drivers — no staging needed" });
        },
        .auto => unreachable,
    }

    // Secure boot: sign every boot binary with the locally-generated key.
    switch (cfg.security.secure_boot) {
        .sbctl => {
            if (!nvidia_prop_sbctl) {
                // nvidia+sbctl already emerged sbctl and created keys
                // back at the firmware-kernel step.
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
            }
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sbctl", "enroll-keys" }),
                .chroot = true,
                .desc = "enroll keys into firmware (requires Setup Mode)",
            } });
            try c.append(alloc, .{
                .exec = .{
                    // missing globs skip silently; a FAILED sign propagates.
                    .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc, "rc=0; for f in {s}/EFI/BOOT/*.EFI {s}/vmlinuz {s}/EFI/Linux/*.efi; do [ -f \"$f\" ] || continue; sbctl sign -s \"$f\" || rc=1; done; exit $rc", .{ espInTarget(cfg), espInTarget(cfg), espInTarget(cfg) }) }),
                    .chroot = true,
                    .desc = "sign bootloader + kernels (sbctl)",
                },
            });
        },
        // shim+MOK (grub only — validation gates it): the MS-signed
        // shim + MokManager stage on the ESP; grub[secureboot]'s signed
        // standalone lands as grubx64.efi (shim's hardcoded second stage);
        // a generated MOK key signs it and every staged kernel; mokutil
        // queues the cert so MokManager can enroll it at first boot.
        .shim => {
            const dir = s(alloc, "{s}/EFI/gentoo", .{espInTarget(cfg)});
            const arm64 = cfg.arch == .arm64;
            const shim_src: []const u8 = if (arm64) "BOOTAA64.EFI" else "BOOTX64.EFI";
            const mm_src: []const u8 = if (arm64) "mmaa64.efi" else "mmx64.efi";
            const shim_dst: []const u8 = if (arm64) "shimaa64.efi" else "shimx64.efi";
            const grub_src: []const u8 = if (arm64) "grub-arm64.efi.signed" else "grub-x86_64.efi.signed";
            const grub_dst: []const u8 = if (arm64) "grubaa64.efi" else "grubx64.efi";
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "emerge", "sys-boot/shim", "sys-boot/mokutil", "app-crypt/sbsigntools", "sys-boot/efibootmgr" }),
                .chroot = true,
                .desc = "shim + mokutil + sbsigntools",
            } });
            try c.append(alloc, .{
                .exec = .{
                    .argv = try alloc.dupe([]const u8, &.{
                        "sh", "-c",
                        s(alloc,
                            // Gentoo's prebuilt grub carries its own signature
                            // that nothing trusts yet — sbsign adds ours (MOK)
                            // on top; shim accepts any verifiable signature.
                            "mkdir -p {s} && cp /usr/share/shim/{s} {s}/{s} && cp /usr/share/shim/{s} {s}/{s} && " ++
                                "sbsign --key /etc/shim/mok.key --cert /etc/shim/mok.pem --output {s}/{s} /usr/lib/grub/{s}", .{ dir, shim_src, dir, shim_dst, mm_src, dir, mm_src, dir, grub_dst, grub_src }),
                    }),
                    .chroot = true,
                    .desc = "stage shim + MokManager + signed grub on the ESP",
                },
            });
            try c.append(alloc, .{
                .exec = .{
                    .argv = try alloc.dupe([]const u8, &.{
                        "sh", "-c",
                        s(alloc,
                            // grub's linux loader verifies the PE signature via
                            // shim — sign every staged kernel copy in place.
                            "rc=0; for f in {s}/vmlinuz /boot/vmlinuz-* /boot/kernel-* /boot/*/*/vmlinuz /boot/*/*/linux; do " ++
                                "[ -f \"$f\" ] || continue; sbsign --key /etc/shim/mok.key --cert /etc/shim/mok.pem " ++
                                "--output \"$f.signed\" \"$f\" && mv -f \"$f.signed\" \"$f\" || rc=1; done; exit $rc", .{espInTarget(cfg)}),
                    }),
                    .chroot = true,
                    .desc = "sign kernels with the MOK key",
                },
            });
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", s(alloc, "esp=$(findmnt -no SOURCE {s}) || exit 1; " ++
                    "d=$(lsblk -no PKNAME \"$esp\"); p=$(lsblk -no PARTN \"$esp\"); " ++
                    "[ -n \"$d\" ] && [ -n \"$p\" ] || exit 1; " ++
                    "efibootmgr -c -d /dev/$d -p $p -L 'Gentoo (shim)' -l '\\EFI\\gentoo\\{s}'", .{ espInTarget(cfg), shim_dst }) }),
                .chroot = true,
                .desc = "efibootmgr: shim NVRAM entry",
            } });
            try c.append(alloc, .{
                .exec = .{
                    // --root-pw uses the root password as the one-time
                    // enrollment credential — headless-safe (mokutil has no
                    // --password-file) and the user already knows it.
                    // The queued request MUST be visible afterwards —
                    // without it MokManager never enrolls the cert and the
                    // signed grub is refused under real secure boot.
                    .argv = try alloc.dupe([]const u8, &.{ "sh", "-c", "mokutil --import /etc/shim/mok.der --root-pw && " ++
                        "mokutil --list-new 2>/dev/null | grep -q ." }),
                    .chroot = true,
                    .desc = "mokutil: queue MOK enrollment for first boot",
                },
            });
            // The prebuilt standalone grub resolves $prefix to the dir
            // it loaded from — it needs grub.cfg next to grubx64.efi.
            try c.append(alloc, .{ .exec = .{
                .argv = try alloc.dupe([]const u8, &.{ "cp", "-f", "/boot/grub/grub.cfg", s(alloc, "{s}/grub.cfg", .{dir}) }),
                .chroot = true,
                .desc = "grub.cfg onto the ESP (shim grub reads $prefix/grub.cfg)",
            } });
            // kernel-install hook: future kernels must carry a MOK
            // signature or shim's grub refuses them.
            try c.append(alloc, .{ .write_file = .{
                .path = "/mnt/gentoo/etc/kernel/install.d/90-mok-sign.install",
                .content =
                \\#!/bin/sh
                \\# gentoo-installer shim hook: sign new kernels with the
                \\# MOK key so the shim-chain grub verifies them.
                \\# args: $1=command $2=kver $3=entry_dir_abs $4=kernel_image
                \\[ "$1" = add ] || exit 0
                \\[ -f /etc/shim/mok.key ] || exit 0
                \\sbsign --key /etc/shim/mok.key --cert /etc/shim/mok.pem --output "$4.signed" "$4" && mv -f "$4.signed" "$4" || exit 1
                \\exit 0
                ,
                .mode = 0o755,
            } });
            // grub.cfg lives at /boot/grub but the standalone shim grub
            // reads $prefix/grub.cfg on the ESP — keep them in sync on
            // every kernel add/remove (the file may change then).
            try c.append(alloc, .{ .write_file = .{
                .path = "/mnt/gentoo/etc/kernel/install.d/91-shim-grubcfg.install",
                .content = s(alloc,
                    \\#!/bin/sh
                    \\# gentoo-installer shim hook: grub.cfg updates (new
                    \\# kernel entries) must reach the ESP copy the
                    \\# standalone grub actually reads.
                    \\[ "$1" = add ] || [ "$1" = remove ] || exit 0
                    \\cp -f /boot/grub/grub.cfg {s}/grub.cfg 2>/dev/null || true
                    \\exit 0
                , .{dir}),
                .mode = 0o755,
            } });
            try c.append(alloc, .{ .note = "secure_boot=shim: at the first boot MokManager runs — Enroll MOK → Continue → Yes → enter the ROOT password — then the signed chain boots" });
        },
        .off => {},
    }
    return step(alloc, "bootloader", "Install bootloader", c);
}

/// stem → eselect profile path under `default/linux/{arch}/23.0/`.
/// The openrc base profile carries no init suffix — only systemd is a
/// segment. amd64/arm64 paths mirror the stage3 word order with
/// `-selinux` and `nomultilib` mapped to real directory names
/// (hardened/selinux, no-multilib); riscv64 is fixed rv64/lp64d with
/// musl nested under it. A pinned `stage3.variant` is split the same
/// way so e.g. "desktop-systemd" still resolves to a real profile.
fn profilePath(alloc: Allocator, cfg: *const Config) !?[]const u8 {
    const toks = archTokens(cfg) orelse return null;
    var out: std.ArrayList([]const u8) = .empty;
    if (cfg.arch == .riscv64) {
        // A pinned stage3.variant is authoritative — the profile must
        // follow its tokens (rv64_lp64d_musl-systemd etc.), matching
        // how the amd64/arm64 branches treat it; otherwise derive from
        // the libc/init axes.
        try out.appendSlice(alloc, &.{ "rv64", "lp64d" });
        if (std.mem.eql(u8, cfg.stage3.variant, "auto")) {
            if (cfg.stage3.libc == .musl) try out.append(alloc, "musl");
            if (cfg.system.init == .systemd) try out.append(alloc, "systemd");
        } else {
            var rit = std.mem.tokenizeAny(u8, cfg.stage3.variant, "-_");
            while (rit.next()) |seg| {
                if (std.mem.eql(u8, seg, "musl") or std.mem.eql(u8, seg, "systemd"))
                    try out.append(alloc, seg);
            }
        }
    } else {
        const stem = try config.stage3Stem(alloc, cfg);
        var it = std.mem.splitScalar(u8, stem, '-');
        while (it.next()) |seg| {
            if (std.mem.eql(u8, seg, "openrc")) {
                // openrc is the base profile — no suffix segment
            } else if (std.mem.eql(u8, seg, "nomultilib")) {
                try out.append(alloc, "no-multilib");
            } else if (std.mem.eql(u8, seg, "usr") and out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1], "split")) {
                out.items[out.items.len - 1] = "split-usr";
            } else {
                try out.append(alloc, seg);
            }
        }
    }
    if (out.items.len == 0)
        return s(alloc, "default/linux/{s}/23.0", .{toks.dir});
    const joined = try std.mem.join(alloc, "/", out.items);
    return s(alloc, "default/linux/{s}/23.0/{s}", .{ toks.dir, joined });
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

fn limineConf(alloc: Allocator, cfg: *const Config, env: ?*const detect.Env, seed: u128) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    w.writeAll("# generated by gentoo-installer\n") catch {};
    w.writeAll("timeout: 5\n\n") catch {};
    const root_args = kernelArgs(alloc, cfg, env, seed);
    // boot() resolves on the volume holding limine.conf: ESP root under
    // UEFI or a dedicated /boot partition; the root fs otherwise, where
    // staged files live under /boot/. Modern limine path grammar is
    // `resource(arg):/path` — boot():/... (boot:/// is the pre-v9 form).
    // boot_part covers guided schemes; a manual /boot row is the same
    // separate volume from limine's perspective.
    const boot_vol = cfg.boot_mode == .uefi or cfg.disk.boot_part or
        config.manualMountPart(cfg, "/boot") != null;
    const kpath = if (boot_vol) "vmlinuz" else "boot/vmlinuz";
    const ipath = if (boot_vol) "initramfs.img" else "boot/initramfs.img";
    w.print("/Gentoo\n", .{}) catch {};
    w.writeAll("    protocol: linux\n") catch {};
    w.print("    kernel_path: boot():/{s}\n", .{kpath}) catch {};
    // no initramfs → no module line (and nothing for the hook to stage)
    if (cfg.system.initramfs != .none)
        w.print("    module_path: boot():/{s}\n", .{ipath}) catch {};
    w.print("    cmdline: {s}\n", .{root_args}) catch {};
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
        try c.append(alloc, .{ .note = "btrfs @snapshots subvol provisioned — snapshot+entry creation is the distro pre-emerge hook's job (M5+)" });
    if (cfg.system.snapshots == .auto and cfg.disk.lvm)
        try c.append(alloc, .{ .note = "LVM thin pool 'tank' provisioned — snapshot+entry creation is the distro pre-emerge hook's job (M5+)" });
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
    const plan = try build(alloc, &cfg, null, .{}, null, 0x0123456789abcdef0123456789abcdef);

    const expected_ids = [_][]const u8{
        "detect",         "partition",    "mount",           "stage3",
        "portage-config", "enter-chroot", "repo-sync",       "profile",
        "world-update",   "base-config",  "firmware-kernel", "fstab",
        "system-config",  "services",     "packages",        "bootloader",
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

test "persistent ids: fstab + kernel args use PARTUUID, exec paths use /dev" {
    const toml_mod = @import("toml.zig");
    const doc_src =
        \\[disk]
        \\device="/dev/vdb"
        \\swap="partition"
        \\[[users]]
        \\name="u"
        \\password_hash="x"
        \\
    ;
    var doc = try toml_mod.parse(std.testing.allocator, doc_src, null);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try config.decode(alloc, doc);
    cfg.boot_mode = .uefi;
    const seed: u128 = 0xdeadbeefcafebabe0123456789abcdef;
    const plan = try build(alloc, &cfg, null, .{}, null, seed);

    // UEFI + swap-partition: esp=1, swap=2, root=3. Assert each fstab
    // entry carries ITS partition's GUID, not just any PARTUUID.
    const guid_root = partGuid(alloc, seed, 3);
    const guid_esp = partGuid(alloc, seed, 1);
    const guid_swap = partGuid(alloc, seed, 2);
    const root_ref = s(alloc, "PARTUUID={s}", .{guid_root});
    var saw_root = false;
    var saw_esp = false;
    var saw_swap = false;
    var saw_rootarg = false;
    var saw_dev_root = false;
    var sgdisk_u = false;
    for (plan.steps) |st| for (st.cmds) |cmd| {
        switch (cmd) {
            .write_file => |w| {
                if (std.mem.eql(u8, w.path, "/mnt/gentoo/etc/fstab")) {
                    var it = std.mem.splitScalar(u8, w.content, '\n');
                    while (it.next()) |line| {
                        if (std.mem.indexOf(u8, line, "\t/\t") != null and std.mem.indexOf(u8, line, root_ref) != null)
                            saw_root = true;
                        if (std.mem.indexOf(u8, line, "/efi") != null and std.mem.indexOf(u8, line, s(alloc, "PARTUUID={s}", .{guid_esp})) != null)
                            saw_esp = true;
                        if (std.mem.indexOf(u8, line, "swap") != null and std.mem.indexOf(u8, line, s(alloc, "PARTUUID={s}", .{guid_swap})) != null)
                            saw_swap = true;
                    }
                    if (std.mem.indexOf(u8, w.content, "/dev/vdb") != null)
                        saw_dev_root = true;
                }
                if (std.mem.indexOf(u8, w.content, s(alloc, "root=PARTUUID={s}", .{guid_root})) != null)
                    saw_rootarg = true;
            },
            .exec => |e| {
                if (std.mem.eql(u8, e.argv[0], "sgdisk"))
                    for (e.argv) |a| {
                        if (std.mem.startsWith(u8, a, "-u") and std.mem.endsWith(u8, a, guid_root))
                            sgdisk_u = true;
                    };
            },
            else => {},
        }
    };
    try std.testing.expect(sgdisk_u); // sgdisk assigned root's PARTUUID
    try std.testing.expect(saw_root); // fstab / line uses root PARTUUID
    try std.testing.expect(saw_esp); // fstab /efi line uses esp PARTUUID
    try std.testing.expect(saw_swap); // fstab swap line uses swap PARTUUID
    try std.testing.expect(saw_rootarg); // a written file carries root=PARTUUID
    try std.testing.expect(!saw_dev_root); // no /dev/vdb persisted
}

fn profileFor(alloc: std.mem.Allocator, src: []const u8) !?[]const u8 {
    var doc = try @import("toml.zig").parse(alloc, src, null);
    defer doc.deinit();
    var cfg = try config.decode(doc.arena.allocator(), doc);
    return profilePath(alloc, &cfg);
}

// Every expected path must exist in ::gentoo profiles.desc — these were
// verified against the live tree (openrc is the base profile: no suffix).
test "profilePath matrix matches profiles.desc" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src =
        \\arch = "amd64"
        \\[security]
        \\hardening = "standard"
        \\selinux = false
        , .want = "default/linux/amd64/23.0/systemd" },
        .{ .src =
        \\arch = "amd64"
        \\[system]
        \\init = "openrc"
        , .want = "default/linux/amd64/23.0/hardened/selinux" },
        .{ .src =
        \\arch = "amd64"
        \\[system]
        \\init = "openrc"
        \\[security]
        \\hardening = "standard"
        \\selinux = false
        , .want = "default/linux/amd64/23.0" },
        .{ .src =
        \\arch = "amd64"
        \\[stage3]
        \\nomultilib = true
        \\[security]
        \\hardening = "standard"
        \\selinux = false
        , .want = "default/linux/amd64/23.0/no-multilib/systemd" },
        .{ .src =
        \\arch = "amd64"
        \\[stage3]
        \\libc = "musl"
        \\toolchain = "llvm"
        \\[system]
        \\init = "openrc"
        \\[security]
        \\hardening = "standard"
        \\selinux = false
        , .want = "default/linux/amd64/23.0/musl/llvm" },
        .{ .src =
        \\arch = "amd64"
        \\[stage3]
        \\libc = "musl"
        \\[security]
        \\hardening = "hardened"
        \\selinux = false
        , .want = "default/linux/amd64/23.0/musl/hardened/systemd" },
        .{ .src =
        \\arch = "arm64"
        \\[stage3]
        \\libc = "musl"
        \\[system]
        \\init = "openrc"
        \\[security]
        \\hardening = "standard"
        \\selinux = false
        , .want = "default/linux/arm64/23.0/musl" },
        .{ .src =
        \\arch = "riscv64"
        \\[security]
        \\hardening = "standard"
        \\selinux = false
        , .want = "default/linux/riscv/23.0/rv64/lp64d/systemd" },
        .{ .src =
        \\arch = "riscv64"
        \\[stage3]
        \\libc = "musl"
        \\[system]
        \\init = "openrc"
        \\[security]
        \\hardening = "standard"
        \\selinux = false
        , .want = "default/linux/riscv/23.0/rv64/lp64d/musl" },
    };
    for (cases) |tc| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const got = try profileFor(arena.allocator(), tc.src);
        try std.testing.expectEqualStrings(tc.want, got.?);
    }
}

test "proprietary nvidia: modeset arg, signed modules, sbctl before emerge" {
    var doc = try @import("toml.zig").parse(std.testing.allocator,
        \\arch = "amd64"
        \\boot_mode = "uefi"
        \\[disk]
        \\device = "/dev/vda"
        \\[gpu]
        \\driver = "nvidia-drivers"
        \\[security]
        \\hardening = "standard"
        \\selinux = false
        \\secure_boot = "sbctl"
        \\[[users]]
        \\name = "u"
        \\password_hash = "$6$x$y"
    , null);
    defer doc.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cfg = try config.decode(alloc, doc);
    const plan = try build(alloc, &cfg, null, .{}, null, null);

    var saw_modeset = false;
    var saw_sign_key = false;
    var create_keys_idx: ?usize = null;
    var nvidia_emerge_idx: ?usize = null;
    var bootloader_create_keys = false;
    for (plan.steps) |st| {
        for (st.cmds, 0..) |cmd, i| {
            switch (cmd) {
                .write_file => |w| {
                    if (std.mem.indexOf(u8, w.content, "nvidia-drm.modeset=1") != null)
                        saw_modeset = true;
                    if (std.mem.endsWith(u8, w.path, "make.conf") and
                        std.mem.indexOf(u8, w.content, "MODULES_SIGN_KEY") != null and
                        std.mem.indexOf(u8, w.content, "modules-sign") != null)
                        saw_sign_key = true;
                },
                .exec => |e| {
                    const joins_create = e.argv.len >= 2 and std.mem.eql(u8, e.argv[0], "sbctl") and std.mem.eql(u8, e.argv[1], "create-keys");
                    if (std.mem.eql(u8, st.id, "firmware-kernel")) {
                        if (joins_create) create_keys_idx = i;
                        if (e.argv.len == 2 and std.mem.eql(u8, e.argv[0], "emerge") and
                            std.mem.indexOf(u8, e.argv[1], "nvidia-drivers") != null)
                            nvidia_emerge_idx = i;
                    }
                    if (std.mem.eql(u8, st.id, "bootloader") and joins_create)
                        bootloader_create_keys = true;
                },
                else => {},
            }
        }
    }
    try std.testing.expect(saw_modeset); // limine.conf/loader entry carries it
    try std.testing.expect(saw_sign_key); // linux-mod-r1 signs at merge time
    try std.testing.expect(create_keys_idx != null and nvidia_emerge_idx != null);
    try std.testing.expect(create_keys_idx.? < nvidia_emerge_idx.?);
    try std.testing.expect(!bootloader_create_keys); // no duplicate key gen
}

test "installkernel package.use always carries the initramfs generator" {
    const toml_mod = @import("toml.zig");
    // openrc/musl profiles default installkernel to -dracut — kernels with
    // USE=initramfs then fail dep resolution. Every bootloader pick must
    // emit the generator flag (dracut for the default initramfs).
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src =
        \\arch = "amd64"
        \\[disk]
        \\device = "/dev/vda"
        \\[stage3]
        \\libc = "musl"
        \\[system]
        \\init = "openrc"
        \\bootloader = "efistub"
        \\[security]
        \\hardening = "standard"
        \\selinux = false
        , .want = "sys-kernel/installkernel -systemd-boot dracut -ugrd\n" },
        .{ .src =
        \\arch = "amd64"
        \\[disk]
        \\device = "/dev/vda"
        \\[system]
        \\init = "openrc"
        \\bootloader = "grub"
        \\initramfs = "ugrd"
        \\[security]
        \\hardening = "standard"
        \\selinux = false
        , .want = "sys-kernel/installkernel grub ugrd -dracut\n" },
        .{ .src =
        \\arch = "amd64"
        \\[disk]
        \\device = "/dev/vda"
        \\[system]
        \\bootloader = "limine"
        \\initramfs = "none"
        \\[security]
        \\hardening = "standard"
        \\selinux = false
        , .want = "sys-kernel/installkernel -systemd-boot -refind -dracut -ugrd\n" },
    };
    for (cases) |tc| {
        var doc = try toml_mod.parse(std.testing.allocator, tc.src, null);
        defer doc.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const cfg = try config.decode(alloc, doc);
        const use = try packageUse(alloc, &cfg);
        try std.testing.expect(std.mem.indexOf(u8, use, tc.want) != null);
    }
}

test "riscv64 make.conf accepts ~arch keywords" {
    const toml_mod = @import("toml.zig");
    // Beyond the stage3 base, most riscv packages (service + fs tooling
    // included) are ~riscv-only — stable keywords leave the arch nearly
    // uninstallable.
    const cases = [_]struct { arch: []const u8, tilde: bool }{
        .{ .arch = "amd64", .tilde = false },
        .{ .arch = "arm64", .tilde = false },
        .{ .arch = "riscv64", .tilde = true },
    };
    for (cases) |tc| {
        const src = try std.fmt.allocPrint(std.testing.allocator, "arch = \"{s}\"\n[disk]\ndevice = \"/dev/vda\"\n", .{tc.arch});
        defer std.testing.allocator.free(src);
        var doc = try toml_mod.parse(std.testing.allocator, src, null);
        defer doc.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const cfg = try config.decode(alloc, doc);
        const mc = try makeConf(alloc, &cfg, null);
        const has = std.mem.indexOf(u8, mc, "ACCEPT_KEYWORDS=\"~${ARCH}\"") != null;
        try std.testing.expectEqual(tc.tilde, has);
    }
}

test "alt inits: init= cmdline + supervisor scaffolding" {
    const cases = [_]struct { init: []const u8, arg: []const u8, want: []const u8 }{
        .{ .init = "dinit", .arg = "init=/sbin/dinit", .want = "/mnt/gentoo/etc/dinit.d/sysinit" },
        .{ .init = "runit", .arg = "init=/sbin/runit-init", .want = "/mnt/gentoo/etc/runit/2" },
        .{ .init = "s6", .arg = "init=/sbin/init", .want = "/mnt/gentoo/etc/s6-rc/source/sysinit/type" },
    };
    for (cases) |tc| {
        var doc = try @import("toml.zig").parse(std.testing.allocator,
            \\arch = "amd64"
            \\boot_mode = "uefi"
            \\[disk]
            \\device = "/dev/vda"
            \\swap = "zram"
            \\[system]
            \\init = "dinit"
            \\[security]
            \\hardening = "standard"
            \\selinux = false
            \\[[users]]
            \\name = "u"
            \\password_hash = "$6$x$y"
        , null);
        defer doc.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var cfg = try config.decode(alloc, doc);
        if (std.mem.eql(u8, tc.init, "runit")) cfg.system.init = .runit;
        if (std.mem.eql(u8, tc.init, "s6")) cfg.system.init = .s6;
        const plan = try build(alloc, &cfg, null, .{}, null, null);
        var saw_arg = false;
        var saw_scaffold = false;
        var saw_sysinit = false;
        var saw_zram = false;
        var saw_boot = !std.mem.eql(u8, tc.init, "dinit"); // only dinit needs the boot svc
        for (plan.steps) |st| {
            for (st.cmds) |cmd| {
                switch (cmd) {
                    .write_file => |w| {
                        if (std.mem.indexOf(u8, w.content, tc.arg) != null) saw_arg = true;
                        if (std.mem.eql(u8, w.path, tc.want)) saw_scaffold = true;
                        if (std.mem.eql(u8, w.path, "/mnt/gentoo/usr/libexec/gi-sysinit")) saw_sysinit = true;
                        if (std.mem.eql(u8, w.path, "/mnt/gentoo/etc/init.d/zram")) saw_zram = true;
                        if (std.mem.eql(u8, w.path, "/mnt/gentoo/etc/dinit.d/boot") and
                            std.mem.indexOf(u8, w.content, "waits-for.d") != null) saw_boot = true;
                    },
                    else => {},
                }
            }
        }
        try std.testing.expect(saw_arg);
        try std.testing.expect(saw_scaffold);
        try std.testing.expect(saw_sysinit);
        try std.testing.expect(saw_zram); // init.d unit runs via openrc boot
        try std.testing.expect(saw_boot);
    }
}

test "alongside: preserve table, shrink ext4, reuse ESP, menu merge" {
    const toml_mod = @import("toml.zig");
    const doc_src =
        \\arch = "amd64"
        \\boot_mode = "uefi"
        \\[disk]
        \\device = "/dev/sda"
        \\scheme = "alongside"
        \\wipe = false
        \\root_fs = "ext4"
        \\swap = "zram"
        \\space_src = "shrink"
        \\shrink_part = "/dev/sda2"
        \\shrink_mib = 20000
        \\[stage3]
        \\libc = "glibc"
        \\toolchain = "gcc"
        \\[system]
        \\init = "openrc"
        \\hostname = "dualboot"
        \\kernel = "dist-bin"
        \\bootloader = "limine"
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

    const sda1_esp_uuid = "AAAA-1111-2222-3333";
    const sda2_uuid = "BBBB-4444-5555-6666";
    var parts = [_]detect.PartInfo{
        .{ .num = 1, .path = "/dev/sda1", .fs = "vfat", .partuuid = sda1_esp_uuid, .esp = true, .start_sector = 2048, .size_bytes = 512 << 20 },
        .{ .num = 2, .path = "/dev/sda2", .fs = "ext4", .partuuid = sda2_uuid, .start_sector = 1050624, .size_bytes = 200 << 30, .fs_size_bytes = 200 << 30, .fs_free_bytes = 120 << 30 },
    };
    const sda2_end = @as(u64, 1050624) + (@as(u64, 200 << 30) / 512) - 1;
    var disks = [_]detect.DiskInfo{.{
        .name = "sda",
        .path = "/dev/sda",
        .size_bytes = 256 << 30,
        .removable = false,
        .label = "gpt",
        .parts = &parts,
    }};
    const env = detect.Env{
        .boot_mode = .uefi,
        .arch = .amd64,
        .ram_mib = 16384,
        .cpu_count = 4,
        .cpu_vendor = "GenuineIntel",
        .cpu_flags = &.{},
        .nics = &.{},
        .gpus = &.{},
        .disks = &disks,
        .net_reachable = true,
        .os_hint = "linux",
    };

    const plan = try build(alloc, &cfg, &env, .{}, null, 0x0123456789abcdef0123456789abcdef);

    var saw_zap = false;
    var saw_resize = false;
    var saw_shrink_sgdisk = false;
    var saw_new_root = false;
    var saw_esp_mkfs = false;
    var saw_efibootmgr = false;
    var saw_efi_gentoo = false;
    var saw_chainload_note = false;
    var fstab_esp_ok = false;
    var mount_esp_ok = false;
    var saw_limine_conf = false;
    for (plan.steps) |st| {
        for (st.cmds) |cmd| {
            switch (cmd) {
                .exec => |e| {
                    for (e.argv) |a| {
                        if (std.mem.eql(u8, a, "--zap-all")) saw_zap = true;
                        if (std.mem.indexOf(u8, a, "efibootmgr") != null) saw_efibootmgr = true;
                        if (std.mem.indexOf(u8, a, "EFI/gentoo") != null) saw_efi_gentoo = true;
                        if (std.mem.indexOf(u8, a, "bootmgfw.efi") != null) saw_chainload_note = true;
                        if (std.mem.indexOf(u8, a, "mkfs.vfat") != null) saw_esp_mkfs = true;
                    }
                    if (std.mem.eql(u8, e.argv[0], "resize2fs") and std.mem.eql(u8, e.argv[1], "/dev/sda2"))
                        saw_resize = true;
                    // the shrink is a sh -c script: sgdisk -i capture +
                    // -d/-n recreate + -t/-u/-c/-A re-apply of the identity
                    if (std.mem.eql(u8, e.argv[0], "sh") and e.argv.len > 2 and
                        std.mem.indexOf(u8, e.argv[2], "sgdisk -d2") != null and
                        std.mem.indexOf(u8, e.argv[2], "sgdisk -i2") != null and
                        std.mem.indexOf(u8, e.argv[2], "-u2:$u") != null)
                        saw_shrink_sgdisk = true;
                    if (std.mem.eql(u8, e.argv[0], "sgdisk")) {
                        for (e.argv) |a| {
                            if (std.mem.startsWith(u8, a, "-n3:")) saw_new_root = true;
                        }
                    }
                },
                .write_file => |w| {
                    if (std.mem.eql(u8, w.path, "/mnt/gentoo/etc/fstab"))
                        fstab_esp_ok = std.mem.indexOf(u8, w.content, "PARTUUID=" ++ sda1_esp_uuid) != null;
                    if (std.mem.eql(u8, w.path, "/mnt/gentoo/efi/limine.conf") and
                        std.mem.indexOf(u8, w.content, "root=") != null) saw_limine_conf = true;
                },
                else => {},
            }
            // mount step: existing ESP path under /mnt/gentoo/efi.
            if (std.mem.eql(u8, st.id, "mount")) {
                for (st.cmds) |mc| {
                    if (mc == .exec) {
                        const me = mc.exec;
                        if (me.argv.len >= 3 and std.mem.eql(u8, me.argv[0], "mount") and
                            std.mem.eql(u8, me.argv[me.argv.len - 1], "/mnt/gentoo/efi") and
                            std.mem.eql(u8, me.argv[me.argv.len - 2], "/dev/sda1"))
                            mount_esp_ok = true;
                    }
                }
            }
        }
    }
    _ = sda2_end;
    try std.testing.expect(saw_limine_conf);
    try std.testing.expect(!saw_zap);
    try std.testing.expect(saw_resize);
    try std.testing.expect(saw_shrink_sgdisk);
    try std.testing.expect(saw_new_root);
    try std.testing.expect(!saw_esp_mkfs); // existing ESP is never reformatted
    try std.testing.expect(fstab_esp_ok);
    try std.testing.expect(mount_esp_ok);
    try std.testing.expect(saw_efibootmgr);
    try std.testing.expect(saw_efi_gentoo);
    try std.testing.expect(saw_chainload_note);
}

test "preset extra_steps insert after anchor; post_install before finish" {
    const toml_mod = @import("toml.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const doc = try toml_mod.parse(alloc,
        \\arch = "amd64"
        \\boot_mode = "uefi"
        \\[disk]
        \\device = "/dev/vda"
        \\scheme = "efi-swap-root"
    , null);
    const cfg = try config.decode(alloc, doc);

    var p: preset.Preset = .{ .doc = doc };
    const extra: []const preset.ExtraStep = &.{
        .{ .name = "motd", .after = "system-config", .script = "echo hi > /etc/motd\n", .skippable = true, .description = "seed motd" },
        .{ .name = "second", .after = "system-config", .script = "true\n" },
    };
    p.extra_steps = extra;
    p.post_install = "echo done\n";

    const pl = try build(alloc, &cfg, null, .{}, &p, null);
    const idxOf = struct {
        fn f(steps: []const Step, id: []const u8) usize {
            for (steps, 0..) |st, i| if (std.mem.eql(u8, st.id, id)) return i;
            unreachable;
        }
    }.f;
    const sc = idxOf(pl.steps, "system-config");
    try std.testing.expectEqualStrings("preset-motd", pl.steps[sc + 1].id);
    try std.testing.expectEqualStrings("preset-second", pl.steps[sc + 2].id);
    try std.testing.expect(pl.steps[sc + 1].skippable);
    try std.testing.expect(!pl.steps[sc + 2].skippable);
    // script staged into the target then run in the chroot
    const cmds = pl.steps[sc + 1].cmds;
    try std.testing.expectEqualStrings("/mnt/gentoo/root/gi-extra-motd.sh", cmds[0].write_file.path);
    try std.testing.expectEqual(0o700, cmds[0].write_file.mode);
    try std.testing.expect(cmds[1].exec.chroot);
    // post-install sits between bootloader and finish
    const fin = idxOf(pl.steps, "finish");
    try std.testing.expectEqualStrings("post-install", pl.steps[fin - 1].id);

    // Refusals: unknown anchor + anchor before enter-chroot.
    var bad: preset.Preset = .{ .doc = doc };
    bad.extra_steps = &.{.{ .name = "x", .after = "no-such-step", .script = "true\n" }};
    try std.testing.expectError(error.BadExtraStep, build(alloc, &cfg, null, .{}, &bad, null));
    var early: preset.Preset = .{ .doc = doc };
    early.extra_steps = &.{.{ .name = "x", .after = "stage3", .script = "true\n" }};
    try std.testing.expectError(error.BadExtraStep, build(alloc, &cfg, null, .{}, &early, null));

    // terminal steps are not valid anchors
    var late: preset.Preset = .{ .doc = doc };
    late.extra_steps = &.{.{ .name = "late", .after = "finish", .script = "true\n" }};
    try std.testing.expectError(error.BadExtraStep, build(alloc, &cfg, null, .{}, &late, null));
    var last: preset.Preset = .{ .doc = doc };
    last.extra_steps = &.{.{ .name = "last", .after = "post-install", .script = "true\n" }};
    last.post_install = "true\n";
    try std.testing.expectError(error.BadExtraStep, build(alloc, &cfg, null, .{}, &last, null));
}
