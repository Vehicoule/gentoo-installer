//! Typed InstallConfig decoded from a parsed TOML document, plus
//! VALIDATE — the rule set from docs/DESIGN.md ("VALIDATE must prove
//! ..." comments). Field names mirror the TOML schema exactly.

const std = @import("std");
const toml = @import("toml.zig");
const Allocator = std.mem.Allocator;

pub const Arch = enum { detect, amd64, arm64, riscv64 };
pub const BootMode = enum { uefi, bios };
pub const Scheme = enum { @"efi-swap-root", @"bios-boot-swap-root", alongside, manual };
pub const RootFs = enum { btrfs, xfs, ext4, f2fs, bcachefs };
pub const Swap = enum { zram, partition, none };
pub const SpaceSrc = enum { shrink, @"free-space" };
pub const Libc = enum { glibc, musl };
pub const Toolchain = enum { gcc, llvm };
pub const Init = enum { openrc, systemd, runit, s6, dinit };
pub const Kernel = enum { @"dist-bin", dist, manual };
pub const Bootloader = enum { auto, grub, @"systemd-boot", efistub, limine, refind };
pub const Initramfs = enum { dracut, ugrd, none };
pub const Privilege = enum { doas, sudo, none };
pub const Snapshots = enum { auto, off };
pub const Cflags = union(enum) { safe, native, custom: []const u8 };
pub const GpuDriver = enum { auto, nouveau, @"nvidia-open", @"nvidia-drivers" };

/// What detection knows about NVIDIA hardware: absent, present but
/// pre-Turing (open modules unsupported), or open-module capable.
pub const NvidiaTier = enum { absent, legacy, open_capable };
pub const NetManager = enum { networkmanager, dhcpcd, netifrc, @"systemd-networkd" };
pub const SecureBoot = enum { off, sbctl, shim };
pub const Hardening = enum { standard, hardened, @"hardened-selinux" };

pub const User = struct {
    name: []const u8 = "",
    groups: []const []const u8 = &.{},
    shell: []const u8 = "/bin/bash",
    password_hash: ?[]const u8 = null,
    ssh_authorized_keys: []const []const u8 = &.{},
};

/// One [[disk.partitions]] row — the free-form layout scheme=manual
/// builds. Sizes are "<n>MiB"/"<n>GiB" or "rest" (last entry only);
/// ptype is a GPT type code (EF00 ESP, EF02 BIOS boot, 8200 swap,
/// 8300/8304 Linux); fs is vfat|ext4|xfs|btrfs|f2fs|bcachefs|swap|none
/// ("none" = leave unformatted); mount is absolute or "" (unmounted).
pub const Partition = struct {
    size: []const u8 = "",
    ptype: []const u8 = "8300",
    name: []const u8 = "",
    fs: []const u8 = "",
    mount: []const u8 = "",
};

pub const Config = struct {
    arch: Arch = .detect,
    boot_mode: BootMode = .uefi,
    /// set by decode() when the config doc names boot_mode — detection
    /// fills it only when not explicitly set.
    boot_mode_explicit: bool = false,

    disk: struct {
        device: []const u8 = "",
        wipe: bool = true,
        scheme: Scheme = .@"efi-swap-root",
        root_fs: RootFs = .btrfs,
        swap: Swap = .zram,
        swap_mib: u32 = 4096,
        boot_part: bool = false,
        /// whether `scheme` appeared in the document (detection may pick
        /// the matching default scheme)
        scheme_explicit: bool = false,
        luks: bool = false,
        lvm: bool = false,
        /// Exec-mode LUKS passphrase (fed to cryptsetup on stdin; never
        /// argv, never journaled). Wizard collects it interactively;
        /// mass-install configs must set it for luks=true.
        luks_passphrase: ?[]const u8 = null,
        space_src: SpaceSrc = .shrink,
        shrink_part: []const u8 = "",
        shrink_mib: u32 = 0,
        esp_mib: u32 = 512,
        home_part: bool = false,
        /// scheme=manual only: the free-form partition table.
        partitions: []const Partition = &.{},
    } = .{},

    stage3: struct {
        libc: Libc = .glibc,
        toolchain: Toolchain = .gcc,
        /// amd64-only stem token; musl is already single-ABI so this is
        /// a no-op there, and non-amd64 arches ship one ABI only.
        nomultilib: bool = false,
        variant: []const u8 = "auto",
        mirror: []const u8 = "https://distfiles.gentoo.org",
    } = .{},

    system: struct {
        init: Init = .systemd,
        hostname: []const u8 = "gentoo",
        timezone: []const u8 = "UTC",
        locales: []const []const u8 = &.{"en_US.UTF-8"},
        locale: []const u8 = "en_US.UTF-8",
        keymap: []const u8 = "us",
        kernel: Kernel = .@"dist-bin",
        bootloader: Bootloader = .auto,
        initramfs: Initramfs = .dracut,
        uki: bool = false,
        binhost: bool = true,
        privilege: Privilege = .doas,
        keep_kernels: u32 = 3,
        snapshots: Snapshots = .auto,
        /// `system.kernel_config` — kernel=manual only: path to a
        /// .config on the live env fs, copied into the target and
        /// built with olddefconfig. Required for a manual kernel to
        /// be executable.
        kernel_config: []const u8 = "",
    } = .{},

    makeconf: struct {
        cflags: Cflags = .native,
        jobs: u32 = 0,
        mem_cap_gib: u32 = 0,
        video_cards: []const u8 = "auto",
        accept_license: []const u8 = "@FREE",
        mirrors: []const u8 = "auto",
    } = .{},

    gpu: struct {
        driver: GpuDriver = .auto,
    } = .{},

    network: struct {
        manager: NetManager = .networkmanager,
        wifi: bool = true,
    } = .{},

    services: struct {
        sshd: bool = false,
        logger: bool = true,
        cron: bool = true,
        ntp: bool = true,
    } = .{},

    users: []const User = &.{},

    root: struct {
        password_hash: ?[]const u8 = null,
        lock_root: bool = false,
    } = .{},

    security: struct {
        secure_boot: SecureBoot = .off,
        hardening: Hardening = .@"hardened-selinux",
        selinux: bool = true,
    } = .{},

    packages: struct {
        sets: []const []const u8 = &.{"minimal"},
        /// whether `sets` appeared in the document — an explicit `[]`
        /// means "no sets", not "defaults"
        sets_explicit: bool = false,
        atoms: []const []const u8 = &.{},
    } = .{},

    use: struct {
        global: toml.Value.Table = .empty,
        pkg: toml.Value.Table = .empty,
    } = .{},

    extra: struct {
        update_world: bool = true,
    } = .{},
};

pub const DecodeError = error{ BadConfig, OutOfMemory };

fn enumOr(comptime T: type, v: toml.Value, path: []const u8) DecodeError!T {
    const s = switch (v) {
        .string => |s| s,
        else => return decodeFail(path, "expected string"),
    };
    return std.meta.stringToEnum(T, s) orelse decodeFail(path, "bad enum value");
}

fn decodeFail(path: []const u8, what: []const u8) DecodeError {
    std.log.err("config: {s}: {s}", .{ path, what });
    return error.BadConfig;
}

fn strOr(v: toml.Value, path: []const u8) DecodeError![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => decodeFail(path, "expected string"),
    };
}

fn boolOr(v: toml.Value, path: []const u8) DecodeError!bool {
    return switch (v) {
        .boolean => |b| b,
        else => decodeFail(path, "expected bool"),
    };
}

fn intOr(v: toml.Value, path: []const u8) DecodeError!u32 {
    return switch (v) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else decodeFail(path, "expected non-negative u32"),
        else => decodeFail(path, "expected int"),
    };
}

fn strList(alloc: Allocator, v: toml.Value, path: []const u8) DecodeError![]const []const u8 {
    const arr = switch (v) {
        .array => |a| a,
        else => return decodeFail(path, "expected array"),
    };
    const out = try alloc.alloc([]const u8, arr.len);
    for (arr, 0..) |item, i| {
        out[i] = switch (item) {
            .string => |s| s,
            else => return decodeFail(path, "expected array of strings"),
        };
    }
    return out;
}

fn field(table: toml.Value.Table, name: []const u8) ?toml.Value {
    return table.get(name);
}

fn tableOf(v: toml.Value, path: []const u8) DecodeError!toml.Value.Table {
    return switch (v) {
        .table => |t| t,
        else => decodeFail(path, "expected table"),
    };
}

/// Decode a parsed TOML document into a typed Config. `alloc` is the
/// document arena — decoded slices borrow from it.
pub fn decode(alloc: Allocator, doc: toml.Document) DecodeError!Config {
    var cfg: Config = .{};

    if (doc.root.get("arch")) |v| cfg.arch = try enumOr(Arch, v, "arch");
    if (doc.root.get("boot_mode")) |v| {
        cfg.boot_mode = try enumOr(BootMode, v, "boot_mode");
        cfg.boot_mode_explicit = true;
    }

    if (doc.root.get("disk")) |v| {
        const t = try tableOf(v, "disk");
        if (field(t, "device")) |x| cfg.disk.device = try strOr(x, "disk.device");
        if (field(t, "wipe")) |x| cfg.disk.wipe = try boolOr(x, "disk.wipe");
        if (field(t, "scheme")) |x| {
            cfg.disk.scheme = try enumOr(Scheme, x, "disk.scheme");
            cfg.disk.scheme_explicit = true;
        }
        if (field(t, "root_fs")) |x| cfg.disk.root_fs = try enumOr(RootFs, x, "disk.root_fs");
        if (field(t, "swap")) |x| cfg.disk.swap = try enumOr(Swap, x, "disk.swap");
        if (field(t, "swap_mib")) |x| cfg.disk.swap_mib = try intOr(x, "disk.swap_mib");
        if (field(t, "boot_part")) |x| cfg.disk.boot_part = try boolOr(x, "disk.boot_part");
        if (field(t, "luks")) |x| cfg.disk.luks = try boolOr(x, "disk.luks");
        if (field(t, "luks_passphrase")) |x| cfg.disk.luks_passphrase = try strOr(x, "disk.luks_passphrase");
        if (field(t, "lvm")) |x| cfg.disk.lvm = try boolOr(x, "disk.lvm");
        if (field(t, "space_src")) |x| cfg.disk.space_src = try enumOr(SpaceSrc, x, "disk.space_src");
        if (field(t, "shrink_part")) |x| cfg.disk.shrink_part = try strOr(x, "disk.shrink_part");
        if (field(t, "shrink_mib")) |x| cfg.disk.shrink_mib = try intOr(x, "disk.shrink_mib");
        if (field(t, "esp_mib")) |x| cfg.disk.esp_mib = try intOr(x, "disk.esp_mib");
        if (field(t, "home_part")) |x| cfg.disk.home_part = try boolOr(x, "disk.home_part");
        if (field(t, "partitions")) |x| {
            const arr = switch (x) {
                .array => |a| a,
                else => return decodeFail("disk.partitions", "expected [[disk.partitions]] array"),
            };
            const parts = try alloc.alloc(Partition, arr.len);
            for (arr, 0..) |item, i| {
                const pt = try tableOf(item, "disk.partitions[]");
                var p: Partition = .{};
                if (field(pt, "size")) |y| p.size = try strOr(y, "disk.partitions[].size");
                if (field(pt, "type")) |y| p.ptype = try strOr(y, "disk.partitions[].type");
                if (field(pt, "name")) |y| p.name = try strOr(y, "disk.partitions[].name");
                if (field(pt, "fs")) |y| p.fs = try strOr(y, "disk.partitions[].fs");
                if (field(pt, "mount")) |y| p.mount = try strOr(y, "disk.partitions[].mount");
                parts[i] = p;
            }
            cfg.disk.partitions = parts;
        }
    }

    if (doc.root.get("stage3")) |v| {
        const t = try tableOf(v, "stage3");
        if (field(t, "libc")) |x| cfg.stage3.libc = try enumOr(Libc, x, "stage3.libc");
        if (field(t, "toolchain")) |x| cfg.stage3.toolchain = try enumOr(Toolchain, x, "stage3.toolchain");
        if (field(t, "nomultilib")) |x| cfg.stage3.nomultilib = try boolOr(x, "stage3.nomultilib");
        if (field(t, "variant")) |x| cfg.stage3.variant = try strOr(x, "stage3.variant");
        if (field(t, "mirror")) |x| cfg.stage3.mirror = try strOr(x, "stage3.mirror");
    }

    if (doc.root.get("system")) |v| {
        const t = try tableOf(v, "system");
        if (field(t, "init")) |x| cfg.system.init = try enumOr(Init, x, "system.init");
        if (field(t, "hostname")) |x| cfg.system.hostname = try strOr(x, "system.hostname");
        if (field(t, "timezone")) |x| cfg.system.timezone = try strOr(x, "system.timezone");
        if (field(t, "locales")) |x| cfg.system.locales = try strList(alloc, x, "system.locales");
        if (field(t, "locale")) |x| cfg.system.locale = try strOr(x, "system.locale");
        if (field(t, "keymap")) |x| cfg.system.keymap = try strOr(x, "system.keymap");
        if (field(t, "kernel")) |x| cfg.system.kernel = try enumOr(Kernel, x, "system.kernel");
        if (field(t, "bootloader")) |x| cfg.system.bootloader = try enumOr(Bootloader, x, "system.bootloader");
        if (field(t, "initramfs")) |x| cfg.system.initramfs = try enumOr(Initramfs, x, "system.initramfs");
        if (field(t, "uki")) |x| cfg.system.uki = try boolOr(x, "system.uki");
        if (field(t, "binhost")) |x| cfg.system.binhost = try boolOr(x, "system.binhost");
        if (field(t, "privilege")) |x| cfg.system.privilege = try enumOr(Privilege, x, "system.privilege");
        if (field(t, "keep_kernels")) |x| cfg.system.keep_kernels = try intOr(x, "system.keep_kernels");
        if (field(t, "snapshots")) |x| cfg.system.snapshots = try enumOr(Snapshots, x, "system.snapshots");
        if (field(t, "kernel_config")) |x| cfg.system.kernel_config = try strOr(x, "system.kernel_config");
    }

    if (doc.root.get("makeconf")) |v| {
        const t = try tableOf(v, "makeconf");
        if (field(t, "cflags")) |x| {
            cfg.makeconf.cflags = switch (x) {
                .string => |s| blk: {
                    if (std.mem.eql(u8, s, "safe")) break :blk .safe;
                    if (std.mem.eql(u8, s, "native")) break :blk .native;
                    if (std.mem.startsWith(u8, s, "custom"))
                        break :blk .{ .custom = std.mem.trim(u8, s["custom".len..], " \"") };
                    break :blk .{ .custom = s };
                },
                else => return decodeFail("makeconf.cflags", "expected string"),
            };
        }
        if (field(t, "jobs")) |x| cfg.makeconf.jobs = try intOr(x, "makeconf.jobs");
        if (field(t, "mem_cap_gib")) |x| cfg.makeconf.mem_cap_gib = try intOr(x, "makeconf.mem_cap_gib");
        if (field(t, "video_cards")) |x| cfg.makeconf.video_cards = try strOr(x, "makeconf.video_cards");
        if (field(t, "accept_license")) |x| cfg.makeconf.accept_license = try strOr(x, "makeconf.accept_license");
        if (field(t, "mirrors")) |x| cfg.makeconf.mirrors = try strOr(x, "makeconf.mirrors");
    }

    if (doc.root.get("gpu")) |v| {
        const t = try tableOf(v, "gpu");
        if (field(t, "driver")) |x| cfg.gpu.driver = try enumOr(GpuDriver, x, "gpu.driver");
    }

    if (doc.root.get("network")) |v| {
        const t = try tableOf(v, "network");
        if (field(t, "manager")) |x| cfg.network.manager = try enumOr(NetManager, x, "network.manager");
        if (field(t, "wifi")) |x| cfg.network.wifi = try boolOr(x, "network.wifi");
    }

    if (doc.root.get("services")) |v| {
        const t = try tableOf(v, "services");
        if (field(t, "sshd")) |x| cfg.services.sshd = try boolOr(x, "services.sshd");
        if (field(t, "logger")) |x| cfg.services.logger = try boolOr(x, "services.logger");
        if (field(t, "cron")) |x| cfg.services.cron = try boolOr(x, "services.cron");
        if (field(t, "ntp")) |x| cfg.services.ntp = try boolOr(x, "services.ntp");
    }

    if (doc.root.get("users")) |v| {
        const arr = switch (v) {
            .array => |a| a,
            else => return decodeFail("users", "expected [[users]] array"),
        };
        const users = try alloc.alloc(User, arr.len);
        for (arr, 0..) |item, i| {
            const t = try tableOf(item, "users[]");
            var u: User = .{};
            if (field(t, "name")) |x| u.name = try strOr(x, "users[].name");
            if (field(t, "groups")) |x| u.groups = try strList(alloc, x, "users[].groups");
            if (field(t, "shell")) |x| u.shell = try strOr(x, "users[].shell");
            if (field(t, "password_hash")) |x| u.password_hash = try strOr(x, "users[].password_hash");
            if (field(t, "ssh_authorized_keys")) |x| u.ssh_authorized_keys = try strList(alloc, x, "users[].ssh_authorized_keys");
            users[i] = u;
        }
        cfg.users = users;
    }

    if (doc.root.get("root")) |v| {
        const t = try tableOf(v, "root");
        if (field(t, "password_hash")) |x| cfg.root.password_hash = try strOr(x, "root.password_hash");
        if (field(t, "lock_root")) |x| cfg.root.lock_root = try boolOr(x, "root.lock_root");
    }

    if (doc.root.get("security")) |v| {
        const t = try tableOf(v, "security");
        if (field(t, "secure_boot")) |x| cfg.security.secure_boot = try enumOr(SecureBoot, x, "security.secure_boot");
        if (field(t, "hardening")) |x| cfg.security.hardening = try enumOr(Hardening, x, "security.hardening");
        if (field(t, "selinux")) |x| cfg.security.selinux = try boolOr(x, "security.selinux");
    }

    if (doc.root.get("packages")) |v| {
        const t = try tableOf(v, "packages");
        if (field(t, "sets")) |x| {
            cfg.packages.sets = try strList(alloc, x, "packages.sets");
            cfg.packages.sets_explicit = true;
        }
        if (field(t, "atoms")) |x| cfg.packages.atoms = try strList(alloc, x, "packages.atoms");
    }

    if (doc.root.get("use")) |v| {
        const t = try tableOf(v, "use");
        if (field(t, "global")) |x| cfg.use.global = try tableOf(x, "use.global");
        if (field(t, "pkg")) |x| cfg.use.pkg = try tableOf(x, "use.pkg");
    }

    if (doc.root.get("extra")) |v| {
        const t = try tableOf(v, "extra");
        if (field(t, "update_world")) |x| cfg.extra.update_world = try boolOr(x, "extra.update_world");
    }

    return cfg;
}

/// Whether a filesystem can be shrunk in alongside mode.
pub fn shrinkable(fs: RootFs) bool {
    return switch (fs) {
        .btrfs, .ext4 => true,
        .xfs, .f2fs, .bcachefs => false,
    };
}

/// Resolve `bootloader = "auto"`: limine on every boot mode/flow
/// (docs/DESIGN.md §Decisions).
pub fn resolveBootloader(cfg: *const Config) Bootloader {
    if (cfg.system.bootloader != .auto) return cfg.system.bootloader;
    return .limine;
}

/// Resolve the stage3 stem (the pointer-file suffix after the arch
/// token) from the axes unless `stage3.variant` pins one explicitly.
/// Gentoo names differ per arch: on amd64/arm64 variants are dash
/// segments in the filename — stage3-amd64-musl-llvm-systemd-* — but on
/// riscv musl is part of the ABI token (stage3-rv64_lp64d_musl-*) so
/// the stem carries init only; archTokens() handles that side.
pub fn stage3Stem(alloc: Allocator, cfg: *const Config) ![]const u8 {
    if (!std.mem.eql(u8, cfg.stage3.variant, "auto")) return cfg.stage3.variant;
    if (cfg.arch == .riscv64)
        return stage3Init(cfg);
    // amd64/arm64 word order matches the published names:
    // <arch>[-musl][-hardened[-selinux]][-llvm][-nomultilib]-<init>
    var parts: std.ArrayList([]const u8) = .empty;
    if (cfg.stage3.libc == .musl) try parts.append(alloc, "musl");
    switch (cfg.security.hardening) {
        .standard => {},
        .hardened => try parts.append(alloc, "hardened"),
        .@"hardened-selinux" => try parts.append(alloc, "hardened-selinux"),
    }
    if (cfg.stage3.toolchain == .llvm) try parts.append(alloc, "llvm");
    if (cfg.stage3.nomultilib and cfg.arch == .amd64 and cfg.stage3.libc == .glibc)
        try parts.append(alloc, "nomultilib");
    try parts.append(alloc, stage3Init(cfg));
    return std.mem.join(alloc, "-", parts.items);
}

/// Alt inits have no stage3 of their own — the openrc tarball is the
/// base and the init is swapped into the target later.
fn stage3Init(cfg: *const Config) []const u8 {
    return switch (cfg.system.init) {
        .systemd => "systemd",
        else => "openrc",
    };
}

const detect = @import("detect.zig");

/// VALIDATE: returns a list of violations (empty = valid). `env` may be
/// null when hardware detection hasn't run (unattended dry-run still
/// checks what it can); alongside's disk-level rules only fire with env.
pub fn validate(alloc: Allocator, cfg: *const Config, nvidia: ?NvidiaTier, env: ?*const detect.Env) ![][]const u8 {
    var errs: std.ArrayList([]const u8) = .empty;

    if (cfg.disk.device.len == 0)
        try errs.append(alloc, "disk.device is required (e.g. /dev/vda)");
    if (cfg.disk.luks) {
        // Presence is an exec gate (execPrechecks) — plan/preview and
        // answer files never carry the passphrase. A weak-but-set one
        // is still flagged here.
        if (cfg.disk.luks_passphrase != null and cfg.disk.luks_passphrase.?.len < 8)
            try errs.append(alloc, "disk.luks_passphrase needs ≥8 characters");
    }

    // Control chars / newlines in values interpolated into generated
    // files or argv would inject extra directives — reject them all.
    // Errors name the FIELD, never the value: luks_passphrase and other
    // secrets must not leak into stderr.
    const injectable = [_]struct { name: []const u8, v: ?[]const u8 }{
        .{ .name = "disk.device", .v = cfg.disk.device },
        .{ .name = "disk.shrink_part", .v = cfg.disk.shrink_part },
        .{ .name = "stage3.mirror", .v = cfg.stage3.mirror },
        .{ .name = "system.hostname", .v = cfg.system.hostname },
        .{ .name = "system.timezone", .v = cfg.system.timezone },
        .{ .name = "system.locale", .v = cfg.system.locale },
        .{ .name = "system.keymap", .v = cfg.system.keymap },
        .{ .name = "makeconf.mirrors", .v = cfg.makeconf.mirrors },
        .{ .name = "makeconf.accept_license", .v = cfg.makeconf.accept_license },
        .{ .name = "makeconf.video_cards", .v = cfg.makeconf.video_cards },
        .{ .name = "root.password_hash", .v = cfg.root.password_hash },
        .{ .name = "disk.luks_passphrase", .v = cfg.disk.luks_passphrase },
    };
    for (injectable) |e| {
        const v = e.v orelse continue;
        if (hasCtl(v)) try errs.append(alloc, fmt(alloc, "{s} contains control characters", .{e.name}));
    }
    // Device paths are also embedded inside single-quoted sh -c scripts
    // (efistub/efibootmgr) — lock them to a charset with no quotes or
    // metacharacters at all.
    if (cfg.disk.device.len > 0 and !devPathOk(cfg.disk.device))
        try errs.append(alloc, "disk.device must look like /dev/<path> (letters/digits /._+:- only) — it is interpolated into shell commands");
    if (cfg.disk.shrink_part.len > 0 and !devPathOk(cfg.disk.shrink_part))
        try errs.append(alloc, "disk.shrink_part must look like /dev/<path> (letters/digits /._+:- only)");
    if (cfg.makeconf.cflags == .custom) {
        const v = cfg.makeconf.cflags.custom;
        if (hasCtl(v) or hasShellMeta(v))
            try errs.append(alloc, "makeconf.cflags contains shell metacharacters — portage sources make.conf");
    }
    // make.conf is SOURCED by portage — every interpolated string needs a
    // shell-metacharacter deny-set, not just control chars.
    for ([_][]const u8{ cfg.makeconf.video_cards, cfg.makeconf.accept_license }) |v| {
        if (hasShellMeta(v)) try errs.append(alloc, fmt(alloc, "'{s}' contains shell metacharacters — portage sources make.conf", .{v}));
    }
    // URLs interpolated into sh -c strings must be plain URL charset.
    if (!urlSafe(cfg.stage3.mirror))
        try errs.append(alloc, "stage3.mirror contains characters outside URL charset");
    if (!urlSafe(cfg.makeconf.mirrors))
        try errs.append(alloc, "makeconf.mirrors contains characters outside URL charset");
    if (!std.mem.eql(u8, cfg.stage3.variant, "auto") and !stage3StemOk(cfg.stage3.variant))
        try errs.append(alloc, "stage3.variant is not a stage3 stem (lowercase [a-z0-9-] segments, e.g. hardened-selinux-systemd)");
    // Erase-disk schemes always format — wipe=false preserves nothing.
    if (!cfg.disk.wipe and cfg.disk.scheme != .alongside and cfg.disk.scheme != .manual)
        try errs.append(alloc, "disk.wipe=false has no effect on erase schemes — use alongside to preserve data");
    // Erase scheme must match the firmware boot mode (partition layout
    // and bootloader paths are mode-specific).
    if (cfg.disk.scheme == .@"efi-swap-root" and cfg.boot_mode == .bios)
        try errs.append(alloc, "disk.scheme=efi-swap-root requires boot_mode=uefi — use bios-boot-swap-root");
    if (cfg.disk.scheme == .@"bios-boot-swap-root" and cfg.boot_mode == .uefi)
        try errs.append(alloc, "disk.scheme=bios-boot-swap-root requires boot_mode=bios — use efi-swap-root");
    // Limine ≥12 dropped ext support — its BIOS stage reads only
    // FAT/ISO9660. Kernel, initramfs, limine-bios.sys and limine.conf
    // must all live on a FAT /boot, so BIOS+limine always needs a
    // separate boot partition (also covers the LUKS case — the FAT /boot
    // is unencrypted either way).
    if (cfg.boot_mode == .bios and resolveBootloader(cfg) == .limine and
        cfg.disk.scheme == .@"bios-boot-swap-root" and !cfg.disk.boot_part)
        try errs.append(alloc, "BIOS + limine requires disk.boot_part=true — limine reads only FAT filesystems");
    // GRUB reads kernels before the initramfs can unlock LUKS, and we
    // emit no cryptodisk setup — it needs an unencrypted /boot.
    if (resolveBootloader(cfg) == .grub and cfg.disk.luks) {
        if (cfg.disk.scheme == .manual) {
            if (manualMountPart(cfg, "/boot") == null)
                try errs.append(alloc, "disk.partitions: GRUB + LUKS under scheme=manual needs a mount=\"/boot\" row — grub cannot read kernels inside the encrypted root");
        } else if (!cfg.disk.boot_part)
            try errs.append(alloc, "GRUB + LUKS requires disk.boot_part=true — grub cannot read kernels inside the encrypted root");
    }
    // Zero-sized partitions produce sgdisk failures AFTER --zap-all has
    // already wiped the table — catch them in validation.
    if (cfg.boot_mode == .uefi and cfg.disk.esp_mib == 0)
        try errs.append(alloc, "disk.esp_mib must be > 0 on UEFI — the ESP is required");
    if (cfg.disk.swap == .partition and cfg.disk.swap_mib == 0)
        try errs.append(alloc, "disk.swap_mib must be > 0 when disk.swap=\"partition\"");
    // scheme=manual: the [[disk.partitions]] table IS the layout — the
    // guided knobs (esp_mib/boot_part/home_part/shrink_*/space_src) are
    // inert there. The spec itself is checked here so sgdisk can't hit
    // a malformed row after --zap-all has already wiped the table.
    if (cfg.disk.scheme != .manual and cfg.disk.partitions.len > 0)
        try errs.append(alloc, "disk.partitions only applies to scheme=manual");
    if (cfg.disk.scheme == .manual) {
        if (cfg.disk.partitions.len == 0)
            try errs.append(alloc, "disk.partitions: scheme=manual needs at least one entry");
        if (cfg.disk.partitions.len > 128)
            try errs.append(alloc, "disk.partitions exceeds GPT's 128-entry limit");
        if (cfg.disk.lvm)
            try errs.append(alloc, "disk.lvm is a guided-layout feature — express volumes as partitions under scheme=manual");
        if (!cfg.disk.wipe)
            try errs.append(alloc, "disk.wipe=false is unsupported under scheme=manual — rows are always created at fixed indices and formatted; use scheme=alongside to preserve an existing install");
        if (cfg.disk.swap == .partition)
            try errs.append(alloc, "disk.swap=partition is guided-only — under manual, list a fs=\"swap\" partition");
        var root_count: u32 = 0;
        var rest_count: u32 = 0;
        var esp_count: u32 = 0;
        var biosboot_count: u32 = 0;
        for (cfg.disk.partitions, 0..) |p, i| {
            const row = i + 1;
            if (std.mem.eql(u8, p.size, "rest")) {
                rest_count += 1;
                if (i != cfg.disk.partitions.len - 1)
                    try errs.append(alloc, "disk.partitions: \"rest\" must be the last entry — it consumes all remaining space");
            } else if (parseSizeMiB(p.size) == null)
                try errs.append(alloc, fmt(alloc, "disk.partitions[{}].size must be <n>MiB, <n>GiB, or \"rest\"", .{row}));
            if (!partTypeOk(p.ptype))
                try errs.append(alloc, fmt(alloc, "disk.partitions[{}].type '{s}' is not a GPT type code (hex/short code like EF00, 8304)", .{ row, p.ptype }));
            if (hasCtl(p.name) or std.mem.indexOfScalar(u8, p.name, '"') != null)
                try errs.append(alloc, fmt(alloc, "disk.partitions[{}].name has characters sgdisk -c can't carry", .{row}));
            if (p.name.len > 0 and p.name[0] == '-')
                try errs.append(alloc, fmt(alloc, "disk.partitions[{}].name can't start with '-' — it lands after -n/-L in mkfs calls", .{row}));
            if (!manualFsOk(p.fs))
                try errs.append(alloc, fmt(alloc, "disk.partitions[{}].fs '{s}' — expected vfat|ext4|xfs|btrfs|f2fs|bcachefs|swap|none", .{ row, p.fs }));
            if (std.mem.eql(u8, p.fs, "swap") and p.mount.len > 0)
                try errs.append(alloc, fmt(alloc, "disk.partitions[{}]: fs=swap takes no mount point", .{row}));
            if (p.mount.len > 0) {
                if (!mountOk(p.mount))
                    try errs.append(alloc, fmt(alloc, "disk.partitions[{}].mount '{s}' must be an absolute path in [A-Za-z0-9._/-]", .{ row, p.mount }));
                if (std.mem.eql(u8, p.mount, "/")) {
                    root_count += 1;
                    if (manualRootFs(cfg) == null)
                        try errs.append(alloc, fmt(alloc, "disk.partitions[{}]: mount=\"/\" needs a root filesystem (btrfs|xfs|ext4|f2fs|bcachefs)", .{row}));
                    if (parseSizeMiB(p.size)) |sz| {
                        if (sz < 8192)
                            try errs.append(alloc, fmt(alloc, "disk.partitions[{}]: root needs ≥8192 MiB (stage3 + toolchain + world) — or size=\"rest\"", .{row}));
                    }
                }
            }
            // Dedup on the EFFECTIVE mount — an EF00 row with a blank
            // mount still lands at /efi (manualEspMount default).
            const eff_mount: []const u8 = if (p.mount.len > 0) p.mount else if (std.ascii.eqlIgnoreCase(p.ptype, "EF00")) "/efi" else "";
            for (cfg.disk.partitions[0..i]) |q| {
                const q_eff: []const u8 = if (q.mount.len > 0) q.mount else if (std.ascii.eqlIgnoreCase(q.ptype, "EF00")) "/efi" else "";
                if (q_eff.len > 0 and std.mem.eql(u8, q_eff, eff_mount))
                    try errs.append(alloc, fmt(alloc, "disk.partitions[{}].mount '{s}' duplicates an earlier entry", .{ row, eff_mount }));
            }
            // fs="none" means unformatted — a mount would fail mid-install.
            if (std.mem.eql(u8, p.fs, "none") and eff_mount.len > 0)
                try errs.append(alloc, fmt(alloc, "disk.partitions[{}]: fs=\"none\" takes no mount point", .{row}));
            // EF02 is a bootloader embed target — never a filesystem,
            // and "rest" here would swallow the remainder of the disk.
            if (std.ascii.eqlIgnoreCase(p.ptype, "EF02")) {
                if (!std.mem.eql(u8, p.fs, "none") or p.mount.len > 0)
                    try errs.append(alloc, fmt(alloc, "disk.partitions[{}]: EF02 biosboot must be fs=\"none\" mount=\"\" — bios-install embeds stage2 there, corrupting any filesystem", .{row}));
                const sz = parseSizeMiB(p.size);
                if (sz == null or sz.? > 8192)
                    try errs.append(alloc, fmt(alloc, "disk.partitions[{}]: EF02 needs an explicit small size (1–8192 MiB), not \"{s}\"", .{ row, p.size }));
            }
            if (std.ascii.eqlIgnoreCase(p.ptype, "EF00")) esp_count += 1;
            if (std.ascii.eqlIgnoreCase(p.ptype, "EF02")) biosboot_count += 1;
        }
        if (root_count != 1)
            try errs.append(alloc, "disk.partitions needs exactly one mount=\"/\" entry");
        if (rest_count > 1)
            try errs.append(alloc, "disk.partitions: at most one size=\"rest\" entry");
        if (cfg.boot_mode == .uefi) {
            // Exactly one ESP — the planner (espPartIdx/manualEspMount)
            // picks the first EF00 row, so multiples would bootload the
            // wrong partition.
            if (esp_count != 1)
                try errs.append(alloc, "disk.partitions: scheme=manual on UEFI needs exactly one type=\"EF00\" partition (the ESP)");
            var esp_ok = false;
            for (cfg.disk.partitions) |p| {
                if (std.ascii.eqlIgnoreCase(p.ptype, "EF00") and std.mem.eql(u8, p.fs, "vfat")) esp_ok = true;
            }
            if (esp_count == 1 and !esp_ok)
                try errs.append(alloc, "disk.partitions: the EF00 ESP row needs fs=\"vfat\"");
        } else {
            if (esp_count > 0)
                try errs.append(alloc, "disk.partitions lists an EF00 ESP under BIOS boot — ESPs are UEFI-only");
            if (biosboot_count == 0)
                try errs.append(alloc, "disk.partitions: BIOS boot needs a type=\"EF02\" biosboot partition (grub and limine both embed stage2 there — GPT has no post-MBR gap)");
            if (resolveBootloader(cfg) == .limine) {
                const bf = manualBootFs(cfg);
                if (bf == null or !std.mem.eql(u8, bf.?, "vfat"))
                    try errs.append(alloc, "disk.partitions: BIOS limine reads only FAT — add a mount=\"/boot\" fs=\"vfat\" partition for kernels + limine-bios.sys");
            }
        }
    }
    // kernel=manual builds gentoo-sources from a caller-supplied .config
    // — the path must exist on the live env for the copy to succeed.
    if (cfg.system.kernel == .manual and cfg.system.kernel_config.len == 0)
        try errs.append(alloc, "kernel=manual needs system.kernel_config=<path to .config>");
    if (cfg.system.kernel != .manual and cfg.system.kernel_config.len > 0)
        try errs.append(alloc, "system.kernel_config only applies to kernel=manual");
    if (hasCtl(cfg.system.kernel_config))
        try errs.append(alloc, "system.kernel_config contains control characters");
    if (cfg.system.kernel_config.len > 0 and cfg.system.kernel_config[0] != '/')
        try errs.append(alloc, "system.kernel_config must be an absolute path on the live env");
    // Keymaps land in shell-sourced conf.d files under OpenRC — pin to
    // the keymap-name charset.
    if (!keymapOk(cfg.system.keymap))
        try errs.append(alloc, fmt(alloc, "keymap '{s}' has characters outside the keymap charset", .{cfg.system.keymap}));
    // zram works on every init — systemd via zram-generator; all others
    // run `openrc boot` in stage-1 which executes the generated
    // init.d/zram runscript.
    // No official Gentoo binhost exists for riscv64.
    if (cfg.system.binhost and cfg.arch == .riscv64)
        try errs.append(alloc, "system.binhost has no upstream binpackages for riscv64");
    // Network managers must match init capabilities.
    if (cfg.network.manager == .netifrc and cfg.system.init != .openrc)
        try errs.append(alloc, "network.manager=netifrc requires init=openrc");
    if (cfg.network.manager == .@"systemd-networkd" and cfg.system.init != .systemd)
        try errs.append(alloc, "network.manager=systemd-networkd requires init=systemd");
    // A standalone /home partition is not provisioned — separate home is
    // an LVM LV or the btrfs @home subvol.
    if (cfg.disk.home_part and !cfg.disk.lvm and cfg.disk.root_fs != .btrfs)
        try errs.append(alloc, "disk.home_part requires lvm=true (thin home LV) — btrfs roots already get @home");
    // usernames become filesystem paths (/home/<name>) and useradd args.
    for (cfg.users) |u| {
        if (!posixName(u.name))
            try errs.append(alloc, fmt(alloc, "users[].name '{s}' is not a POSIX account name", .{u.name}));
        for (u.groups) |g|
            if (!posixName(g))
                try errs.append(alloc, fmt(alloc, "group '{s}' is not a POSIX group name", .{g}));
    }
    if (!hostnameOk(cfg.system.hostname))
        try errs.append(alloc, fmt(alloc, "hostname '{s}' is not a valid hostname", .{cfg.system.hostname}));
    for (cfg.system.locales) |l|
        if (hasCtl(l)) try errs.append(alloc, fmt(alloc, "locale contains control characters: '{s}'", .{l}));
    for (cfg.users) |u| {
        if (hasCtl(u.name) or hasCtl(u.shell))
            try errs.append(alloc, fmt(alloc, "user '{s}' has control chars in name/shell", .{u.name}));
        // The shell is argv to useradd -s and lands in /etc/passwd —
        // restrict to an absolute-path charset (no spaces/metachars).
        if (u.shell.len > 0 and !shellOk(u.shell))
            try errs.append(alloc, fmt(alloc, "shell '{s}' is not a valid absolute shell path", .{u.shell}));
        // chpasswd -e lines are `name:hash` — a ':' or newline in the
        // hash would forge extra account lines.
        if (u.password_hash) |h|
            if (!pwHashOk(h)) try errs.append(alloc, fmt(alloc, "password_hash for '{s}' must be a $id$ crypt hash (sha512/yescrypt/...)", .{u.name}));
        for (u.groups) |g|
            if (hasCtl(g)) try errs.append(alloc, fmt(alloc, "group '{s}' has control characters", .{g}));
        for (u.ssh_authorized_keys) |k|
            if (hasCtl(k)) try errs.append(alloc, fmt(alloc, "ssh key for '{s}' has control characters", .{u.name}));
    }
    if (cfg.root.password_hash) |h|
        if (!pwHashOk(h)) try errs.append(alloc, "root.password_hash must be a $id$ crypt hash (sha512/yescrypt/...)");
    // Timezone lands verbatim in /etc/timezone — zone names only.
    if (!tzOk(cfg.system.timezone))
        try errs.append(alloc, fmt(alloc, "timezone '{s}' is not a valid zone name", .{cfg.system.timezone}));
    // Package atoms become emerge argv — a leading '-' would be a
    // portage flag, whitespace splits into extra args.
    for (cfg.packages.atoms) |a|
        if (!atomOk(a)) try errs.append(alloc, fmt(alloc, "packages.atoms entry '{s}' is not a valid atom", .{a}));
    var pit = cfg.use.pkg.iterator();
    while (pit.next()) |kv| {
        if (!atomOk(kv.key_ptr.*))
            try errs.append(alloc, fmt(alloc, "use.pkg key '{s}' is not a valid atom", .{kv.key_ptr.*}));
        // a use.pkg value must be a flags string — anything else is
        // silently dropped by packageUse(), so reject it here.
        const flags_str = switch (kv.value_ptr.*) {
            .string => |fl| fl,
            else => {
                try errs.append(alloc, fmt(alloc, "use.pkg['{s}'] must be a string of USE flags", .{kv.key_ptr.*}));
                continue;
            },
        };
        var ft = std.mem.tokenizeScalar(u8, flags_str, ' ');
        while (ft.next()) |f| {
            const flag = if (f.len > 0 and f[0] == '-') f[1..] else f;
            if (!useFlagOk(flag))
                try errs.append(alloc, fmt(alloc, "use.pkg flag '{s}' for '{s}' is not a USE flag", .{ f, kv.key_ptr.* }));
        }
    }
    var uit = cfg.use.global.iterator();
    while (uit.next()) |kv| {
        if (!useFlagOk(kv.key_ptr.*)) try errs.append(alloc, fmt(alloc, "USE flag '{s}' has characters outside the USE charset", .{kv.key_ptr.*}));
        // use.global values must be booleans — other types are silently
        // dropped by makeConf(), so reject them here.
        switch (kv.value_ptr.*) {
            .boolean => {},
            else => try errs.append(alloc, fmt(alloc, "use.global['{s}'] must be true or false", .{kv.key_ptr.*})),
        }
    }

    if (cfg.disk.scheme == .alongside) {
        if (cfg.disk.wipe) try errs.append(alloc, "disk.scheme=alongside requires wipe=false");
        if (cfg.disk.space_src == .shrink and cfg.disk.shrink_part.len == 0)
            try errs.append(alloc, "alongside+shrink requires disk.shrink_part");
        if (cfg.disk.space_src == .shrink and cfg.disk.shrink_mib == 0)
            try errs.append(alloc, "alongside+shrink requires disk.shrink_mib");
        if (cfg.boot_mode == .bios)
            try errs.append(alloc, "disk.scheme=alongside requires UEFI — BIOS chainloading of foreign OSes isn't supported; use a spare disk");
        if (cfg.disk.boot_part)
            try errs.append(alloc, "disk.boot_part is meaningless under alongside — the existing ESP is reused");
        // bootctl unconditionally writes EFI/BOOT/BOOTX64.EFI — on a
        // shared ESP that hijacks the firmware's fallback loader.
        if (cfg.system.bootloader == .@"systemd-boot")
            try errs.append(alloc, "scheme=alongside + systemd-boot is refused: bootctl always claims EFI/BOOT/BOOTX64.EFI on the shared ESP — pick limine/grub/efistub/rEFInd");
        if (env) |e| blk: {
            const disk = for (e.disks) |*di| {
                if (std.mem.eql(u8, di.path, cfg.disk.device)) break di;
            } else null;
            const d = disk orelse {
                try errs.append(alloc, fmt(alloc, "disk.device {s} not among detected disks", .{cfg.disk.device}));
                break :blk;
            };
            if (!std.mem.eql(u8, d.label, "gpt"))
                try errs.append(alloc, fmt(alloc, "disk.scheme=alongside requires a GPT disk (detected label: '{s}')", .{d.label}));
            var esp: ?*const detect.PartInfo = null;
            var shrink_p: ?*const detect.PartInfo = null;
            for (d.parts) |*p| {
                if (p.esp) esp = p;
                if (std.mem.eql(u8, p.path, cfg.disk.shrink_part)) shrink_p = p;
            }
            if (esp == null)
                try errs.append(alloc, fmt(alloc, "disk.scheme=alongside needs an existing ESP on {s} — none detected", .{cfg.disk.device}));
            switch (cfg.disk.space_src) {
                .shrink => {
                    const p = shrink_p orelse {
                        if (cfg.disk.shrink_part.len > 0)
                            try errs.append(alloc, fmt(alloc, "disk.shrink_part {s} isn't a partition on {s}", .{ cfg.disk.shrink_part, cfg.disk.device }));
                        break :blk;
                    };
                    if (std.mem.eql(u8, p.fs, "BitLocker"))
                        try errs.append(alloc, fmt(alloc, "{s} is BitLocker — decrypt it in Windows first", .{p.path}))
                    else if (std.mem.eql(u8, p.fs, "ntfs") or std.mem.startsWith(u8, p.fs, "ext") or std.mem.eql(u8, p.fs, "btrfs")) {
                        if (p.fs_size_bytes == 0) {
                            try errs.append(alloc, fmt(alloc, "couldn't probe free space on {s} ({s}) — the fs may be dirty; fsck/chkdsk it first", .{ p.path, p.fs }));
                        } else {
                            // fs must keep 512 MiB reserve past the shrink.
                            const need = (@as(u64, cfg.disk.shrink_mib) + 512) << 20;
                            if (p.fs_free_bytes < need)
                                try errs.append(alloc, fmt(alloc, "{s} has only {} MiB free — shrink_mib {} + reserve won't fit", .{ p.path, p.fs_free_bytes >> 20, cfg.disk.shrink_mib }));
                            if (cfg.disk.shrink_mib < 8192 + (if (cfg.disk.swap == .partition) cfg.disk.swap_mib else 0))
                                try errs.append(alloc, fmt(alloc, "disk.shrink_mib must cover the install (≥8192 MiB{s})", .{if (cfg.disk.swap == .partition) " + swap_mib" else ""}));
                        }
                    } else
                        try errs.append(alloc, fmt(alloc, "{s} is '{s}' — only ntfs/ext/btrfs shrink (xfs/f2fs/luks/lvm can't)", .{ p.path, p.fs }));
                },
                .@"free-space" => {
                    const need: u64 = (8192 + @as(u64, if (cfg.disk.swap == .partition) cfg.disk.swap_mib else 0)) << 20;
                    var ok = false;
                    for (d.free_regions) |g| {
                        if ((g.end_sector - g.start_sector + 1) * 512 >= need) ok = true;
                    }
                    if (!ok) try errs.append(alloc, fmt(alloc, "no contiguous free region ≥{} MiB on {s} — shrink a partition or pick another disk", .{ need >> 20, cfg.disk.device }));
                },
            }
        }
    }

    if (cfg.boot_mode == .bios) {
        switch (resolveBootloader(cfg)) {
            .@"systemd-boot", .efistub, .refind => try errs.append(alloc, "bootloader requires UEFI on a BIOS boot"),
            else => {},
        }
        if (cfg.system.uki) try errs.append(alloc, "uki requires UEFI");
        if (cfg.security.secure_boot != .off)
            try errs.append(alloc, "secure_boot requires UEFI; forced off on BIOS");
    }

    if ((cfg.disk.luks or cfg.disk.lvm) and cfg.system.initramfs == .none)
        try errs.append(alloc, "luks/lvm root requires an initramfs (dracut|ugrd)");

    // Stage3 availability matrix — every axes combination must name a
    // tarball Gentoo actually autobuilds (releases/<arch>/autobuilds).
    // amd64: glibc{,hardened,hardened-selinux,llvm,nomultilib} ×
    // {openrc,systemd} plus musl{,-hardened,-llvm}; arm64 drops
    // hardened/selinux/nomultilib; riscv64 ships rv64_lp64d[_musl]
    // only. musl+systemd stage3s exist on all three arches.
    // `stage3.variant` pins an explicit stem past this matrix.
    {
        const musl = cfg.stage3.libc == .musl;
        const llvm = cfg.stage3.toolchain == .llvm;
        const h = cfg.security.hardening;
        if (llvm and h != .standard)
            try errs.append(alloc, "no hardened-llvm stage3 — hardened toolchains ship gcc only");
        if (musl and h == .@"hardened-selinux")
            try errs.append(alloc, "no musl-selinux stage3 — musl-hardened is the ceiling");
        if (musl and llvm and h == .hardened)
            try errs.append(alloc, "no musl-hardened-llvm stage3 — musl variants are hardened or llvm, not both");
        switch (cfg.arch) {
            .amd64 => {
                if (cfg.stage3.nomultilib and (llvm or h != .standard))
                    try errs.append(alloc, "nomultilib stage3s exist only for the plain glibc+gcc toolchain — hardened+nomultilib is reachable via profile + world rebuild, not stage3");
            },
            .arm64 => {
                if (!musl and h != .standard)
                    try errs.append(alloc, "no arm64 glibc hardened stage3 — hardened on arm64 is musl-only");
            },
            .riscv64 => {
                if (h != .standard)
                    try errs.append(alloc, "no riscv64 hardened/selinux stage3");
                if (llvm)
                    try errs.append(alloc, "no riscv64 llvm stage3");
            },
            .detect => {}, // resolved post-detection; matrix re-checked then
        }
        // nomultilib is a no-op wherever the ABI is already single
        // (musl, arm64, riscv64) — only amd64 glibc emits the token.
    }

    if (cfg.security.secure_boot == .shim and resolveBootloader(cfg) != .grub)
        try errs.append(alloc, "secure_boot=shim is only supported with grub");
    if (cfg.security.secure_boot == .shim and cfg.arch == .riscv64)
        try errs.append(alloc, "secure_boot=shim needs a shim-signed arch — riscv64 has none; use secure_boot=sbctl");
    // mokutil --root-pw enrolls with the root password — shim needs
    // root to have one (a locked/hashless root has no enrollment cred).
    if (cfg.security.secure_boot == .shim and (cfg.root.password_hash == null or cfg.root.lock_root))
        try errs.append(alloc, "secure_boot=shim requires root.password — mokutil --root-pw uses it as the MOK enrollment password");

    if (cfg.system.privilege == .none and cfg.root.lock_root)
        try errs.append(alloc, "privilege=none with lock_root leaves no admin path");


    // Login-path proof: some credential must survive to the finished
    // system, or sshd must be reachable with keys.
    var login_path = false;
    // A wheel member with credentials is also the admin path once root
    // is locked — doas/sudo policies grant only wheel.
    var wheel_login = false;
    if (cfg.root.password_hash != null and !cfg.root.lock_root) login_path = true;
    for (cfg.users) |u| {
        const has_cred = u.password_hash != null or (cfg.services.sshd and u.ssh_authorized_keys.len > 0);
        if (u.password_hash != null) login_path = true;
        if (cfg.services.sshd and u.ssh_authorized_keys.len > 0) login_path = true;
        var in_wheel = false;
        for (u.groups) |g| {
            if (std.mem.eql(u8, g, "wheel")) in_wheel = true;
        }
        if (in_wheel and has_cred) wheel_login = true;
    }
    if (!login_path)
        try errs.append(alloc, "no surviving login path: set a password_hash, or sshd=true plus ssh_authorized_keys");
    if (cfg.root.lock_root and cfg.system.privilege != .none and !wheel_login)
        try errs.append(alloc, "root.lock_root leaves no admin path: give a wheel member a password or SSH key (doas/sudo grant wheel only)");

    if (cfg.boot_mode == .bios and (cfg.arch == .arm64 or cfg.arch == .riscv64))
        try errs.append(alloc, "boot_mode=bios exists on amd64 only — arm64/riscv64 are UEFI");

    const nvidia_prop = cfg.gpu.driver == .@"nvidia-open" or cfg.gpu.driver == .@"nvidia-drivers";
    if (nvidia_prop) {
        if (cfg.stage3.libc == .musl)
            try errs.append(alloc, "proprietary NVIDIA drivers are glibc-only — musl gets nouveau");
        if (cfg.arch == .riscv64)
            try errs.append(alloc, "proprietary NVIDIA drivers are keyworded amd64/arm64 only");
    }
    if (cfg.gpu.driver == .@"nvidia-open") {
        if (nvidia) |t| switch (t) {
            .absent => try errs.append(alloc, "gpu.driver=nvidia-open but no NVIDIA GPU detected"),
            .legacy => try errs.append(alloc, "gpu.driver=nvidia-open requires a Turing-or-newer NVIDIA GPU — use nvidia-drivers or nouveau on this card"),
            .open_capable => {},
        };
    }
    // security.selinux and hardening are one decision: the SELinux
    // toolchain/policy ships in the hardened-selinux stage3, so the two
    // fields must agree or the tarball contradicts the setting.
    if (cfg.security.selinux and cfg.security.hardening != .@"hardened-selinux")
        try errs.append(alloc, "security.selinux=true requires hardening=hardened-selinux (policy + toolchain live in that stage3)");
    if (!cfg.security.selinux and cfg.security.hardening == .@"hardened-selinux")
        try errs.append(alloc, "security.selinux=false contradicts hardening=hardened-selinux — use hardening=hardened");

    // dinit comes from the GURU overlay, keyworded ~amd64 only — nothing
    // to emerge on other arches until a keyworded ebuild/overlay exists.
    if (cfg.system.init == .dinit and cfg.arch != .amd64)
        try errs.append(alloc, "init=dinit is amd64-only for now (GURU sys-apps/dinit is ~amd64)");

    // locale must be a member of locales
    var found = false;
    for (cfg.system.locales) |l| {
        if (std.mem.eql(u8, l, cfg.system.locale)) found = true;
    }
    if (!found) try errs.append(alloc, "system.locale must be one of system.locales");

    return errs.items;
}

// Device paths the config may legitimately name: /dev/<node> or
// /dev/disk/by-* — the charset excludes quotes/metacharacters so the
// value is safe inside single-quoted shell fragments.
fn devPathOk(v: []const u8) bool {
    if (!std.mem.startsWith(u8, v, "/dev/") or v.len > 96) return false;
    for (v[5..]) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '/' or ch == '.' or ch == '_' or
            ch == '+' or ch == '-' or ch == ':';
        if (!ok) return false;
    }
    return true;
}

fn hasCtl(v: []const u8) bool {
    for (v) |ch| if (ch < 0x20 or ch == 0x7f) return true;
    return false;
}

// Characters that would break out of quoting or inject commands into
// make.conf (a shell-sourced file) or sh -c strings.
fn hasShellMeta(v: []const u8) bool {
    for (v) |ch| {
        switch (ch) {
            '\'', '"', '\\', '$', '`', ';', '|', '&', '<', '>', '(', ')', '{', '}', '[', ']' => return true,
            else => {},
        }
    }
    return false;
}

// URL allowlist: scheme://host/path chars only.
// OpenRC conf.d keymaps are shell-sourced: lowercase names + - _ only.
fn keymapOk(v: []const u8) bool {
    if (v.len == 0 or v.len > 32) return false;
    for (v) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_';
        if (!ok) return false;
    }
    return true;
}

// USE flag names: letters, digits, _ - + @ (e.g. wayland, l10n_de)
fn useFlagOk(v: []const u8) bool {
    if (v.len == 0) return false;
    for (v) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '_' or ch == '-' or ch == '+' or ch == '@';
        if (!ok) return false;
    }
    return true;
}

fn urlSafe(v: []const u8) bool {
    if (v.len == 0) return false;
    for (v) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', ':', '/', '?', '&', '=', '.', '_', '~', '%', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// Stage3 stems are dash-joined lowercase words — the value lands in a
/// pointer-file URL path, so anything with separators or traversal is
/// refused rather than sanitized.
fn stage3StemOk(v: []const u8) bool {
    if (v.len == 0 or v.len > 96) return false;
    if (v[0] == '-' or v[v.len - 1] == '-') return false;
    for (v) |ch| {
        switch (ch) {
            'a'...'z', '0'...'9', '-', '_' => {},
            else => return false,
        }
    }
    return std.mem.indexOf(u8, v, "--") == null;
}

// ---- scheme=manual partition-spec helpers ----

/// "<n>MiB" / "<n>GiB" / "rest" → MiB; null on any other shape.
pub fn parseSizeMiB(s: []const u8) ?u64 {
    if (std.mem.eql(u8, s, "rest")) return null; // caller handles rest
    for ([_]struct { suf: []const u8, mul: u64 }{ .{ .suf = "MiB", .mul = 1 }, .{ .suf = "GiB", .mul = 1024 } }) |u| {
        if (std.mem.endsWith(u8, s, u.suf)) {
            const n = std.fmt.parseInt(u64, s[0 .. s.len - u.suf.len], 10) catch return null;
            if (n == 0) return null;
            return std.math.mul(u64, n, u.mul) catch null;
        }
    }
    return null;
}

/// GPT type codes we accept for manual rows: the short hex forms
/// (EF00, 8200, 8300…) or a full GUID. Hex/dash only, sane length.
fn partTypeOk(v: []const u8) bool {
    if (v.len == 0 or v.len > 36) return false;
    for (v) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or
            (ch >= 'A' and ch <= 'F') or ch == '-';
        if (!ok) return false;
    }
    return true;
}

fn manualFsOk(v: []const u8) bool {
    const known = [_][]const u8{ "vfat", "ext4", "xfs", "btrfs", "f2fs", "bcachefs", "swap", "none" };
    for (known) |k| if (std.mem.eql(u8, v, k)) return true;
    return false;
}

// Mount points become fstab fields + mkdir targets under /mnt/gentoo
// — a strict charset, not a denylist, so shell meta / fstab
// comment-syntax / whitespace can't reinterpret the field.
fn mountOk(v: []const u8) bool {
    if (v.len == 0 or v.len > 64 or v[0] != '/') return false;
    if (v.len > 1 and v[v.len - 1] == '/') return false;
    for (v) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '/' or ch == '-' or ch == '_' or ch == '.';
        if (!ok) return false;
    }
    // no empty (//) or traversal segments
    if (std.mem.indexOf(u8, v, "//") != null) return false;
    var it = std.mem.splitScalar(u8, v, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return false;
    }
    return true;
}

/// 1-based partition number carrying mount="/" under scheme=manual.
pub fn manualRootPart(cfg: *const Config) ?u32 {
    for (cfg.disk.partitions, 0..) |p, i|
        if (std.mem.eql(u8, p.mount, "/")) return @intCast(i + 1);
    return null;
}

/// The manual row mounted at `path` (e.g. "/boot"), if listed.
pub fn manualMountPart(cfg: *const Config, path: []const u8) ?u32 {
    for (cfg.disk.partitions, 0..) |p, i|
        if (std.mem.eql(u8, p.mount, path)) return @intCast(i + 1);
    return null;
}

/// Root filesystem under scheme=manual comes from the "/" row's fs —
/// disk.root_fs is a guided-layout knob. null = no/invalid root fs.
pub fn manualRootFs(cfg: *const Config) ?RootFs {
    const n = manualRootPart(cfg) orelse return null;
    const fs = cfg.disk.partitions[n - 1].fs;
    return std.meta.stringToEnum(RootFs, fs);
}

/// Where the manual ESP mounts inside the target — the EF00 row's own
/// mount, defaulting to /efi when left blank.
pub fn manualEspMount(cfg: *const Config) []const u8 {
    for (cfg.disk.partitions) |p|
        if (std.ascii.eqlIgnoreCase(p.ptype, "EF00"))
            return if (p.mount.len > 0) p.mount else "/efi";
    return "/efi";
}

/// The fs type on the manual /boot row, if one exists.
fn manualBootFs(cfg: *const Config) ?[]const u8 {
    const n = manualMountPart(cfg, "/boot") orelse return null;
    const fs = cfg.disk.partitions[n - 1].fs;
    return if (fs.len > 0 and !std.mem.eql(u8, fs, "none")) fs else null;
}

// POSIX account/group names: [a-z_][a-z0-9_-]*, ≤32 chars. This also
// rules out '/', '\\', '..' — user names build filesystem paths.
fn posixName(v: []const u8) bool {
    if (v.len == 0 or v.len > 32) return false;
    for (v, 0..) |ch, i| {
        const ok = switch (ch) {
            'a'...'z', '_', '-' => true,
            '0'...'9' => i > 0,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

// RFC1123 hostname: labels of alnum + '-', not starting/ending with '-'.
fn hostnameOk(v: []const u8) bool {
    if (v.len == 0 or v.len > 253) return false;
    var it = std.mem.splitScalar(u8, v, '.');
    while (it.next()) |label| {
        if (label.len == 0) return false;
        if (label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |ch| {
            switch (ch) {
                'a'...'z', 'A'...'Z', '0'...'9', '-' => {},
                else => return false,
            }
        }
    }
    return true;
}

// tzdata zone names: Area/City, letters + _ - + /, no '..' or ctl.
fn tzOk(v: []const u8) bool {
    if (v.len == 0 or v.len > 64) return false;
    for (v) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '_' or ch == '-' or ch == '+' or ch == '/';
        if (!ok) return false;
    }
    return true;
}

// A portage atom passed as emerge argv and written into package.use:
// the atom grammar charset only (cat/pkg[-ver][:slot][use] + repo), no
// leading '-', no whitespace. Anything else can't be a valid atom.
fn atomOk(v: []const u8) bool {
    if (v.len == 0 or v.len > 128 or v[0] == '-') return false;
    for (v) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '_' or ch == '+' or ch == '.' or
            ch == '/' or ch == '-' or ch == ':' or ch == '@' or ch == '~' or
            ch == '<' or ch == '>' or ch == '=' or ch == '!' or ch == '*' or
            ch == '[' or ch == ']' or ch == '?';
        if (!ok) return false;
    }
    return true;
}

// crypt(3) hashes: $id$salt$digest over a restricted charset — the
// string is joined into `name:hash` lines for chpasswd -e, so ':' and
// whitespace are forbidden. Contract is $id$ hashes only: '!'/'*' are
// locked-account markers (no login), and 13-char DES hashes are
// unsupported — musl has no DES crypt, so accepting one would install
// an account nobody can log into on musl targets.
fn pwHashOk(v: []const u8) bool {
    if (v.len == 0 or v.len > 256 or v[0] != '$') return false;
    for (v) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '$' or ch == '.' or ch == '/' or
            ch == '=' or ch == ',' or ch == '_' or ch == '-';
        if (!ok) return false;
    }
    return true;
}

// Login shell: absolute path, no whitespace/metachars (useradd -s arg
// and /etc/passwd field).
fn shellOk(v: []const u8) bool {
    if (v.len < 2 or v.len > 64 or v[0] != '/') return false;
    for (v) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '/' or ch == '.' or ch == '_' or ch == '-' or ch == '+';
        if (!ok) return false;
    }
    return true;
}

fn fmt(alloc: Allocator, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, f, args) catch @panic("oom");
}

test "decode defaults" {
    var doc = try toml.parse(std.testing.allocator, "", null);
    defer doc.deinit();
    const cfg = try decode(doc.arena.allocator(), doc);
    try std.testing.expectEqual(RootFs.btrfs, cfg.disk.root_fs);
    try std.testing.expectEqual(Init.systemd, cfg.system.init);
    try std.testing.expectEqualStrings("hardened-selinux", @tagName(cfg.security.hardening));
}

test "validate rejects bios+systemd-boot" {
    var doc = try toml.parse(std.testing.allocator,
        \\boot_mode = "bios"
        \\[system]
        \\bootloader = "systemd-boot"
        \\[[users]]
        \\name = "a"
        \\password_hash = "x"
    , null);
    defer doc.deinit();
    const cfg = try decode(doc.arena.allocator(), doc);
    const errs = try validate(doc.arena.allocator(), &cfg, null, null);
    try std.testing.expect(errs.len > 0);
}

test "validate rejects a short luks passphrase from a file" {
    var doc = try toml.parse(std.testing.allocator,
        \\[disk]
        \\device = "/dev/sda"
        \\luks = true
        \\luks_passphrase = "short"
    , null);
    defer doc.deinit();
    const cfg = try decode(doc.arena.allocator(), doc);
    const errs = try validate(doc.arena.allocator(), &cfg, null, null);
    var seen = false;
    for (errs) |e| {
        if (std.mem.indexOf(u8, e, "luks_passphrase") != null) seen = true;
    }
    try std.testing.expect(seen);
}

/// Exec-only requirements — plan/preview and answer files legitimately
/// lack secrets, a real install cannot proceed without them.
pub fn execPrechecks(cfg: *const Config) ?[]const u8 {
    if (cfg.disk.luks and cfg.disk.luks_passphrase == null)
        return "disk.luks requires disk.luks_passphrase before exec";
    return null;
}

test "validate login-path proof" {
    var doc = try toml.parse(std.testing.allocator,
        \\[disk]
        \\device = "/dev/sda"
        \\[root]
        \\lock_root = true
    , null);
    defer doc.deinit();
    const cfg = try decode(doc.arena.allocator(), doc);
    const errs = try validate(doc.arena.allocator(), &cfg, null, null);
    var has_login_err = false;
    for (errs) |e| {
        if (std.mem.indexOf(u8, e, "login path") != null) has_login_err = true;
    }
    try std.testing.expect(has_login_err);
}

test "stage3 stem resolution" {
    var doc = try toml.parse(std.testing.allocator,
        \\[stage3]
        \\libc = "musl"
        \\[security]
        \\hardening = "standard"
        \\selinux = false
        \\[system]
        \\init = "dinit"
    , null);
    defer doc.deinit();
    const cfg = try decode(doc.arena.allocator(), doc);
    const stem = try stage3Stem(doc.arena.allocator(), &cfg);
    try std.testing.expectEqualStrings("musl-openrc", stem);
}

// Stem word order and per-arch coverage must match Gentoo's real
// autobuild names (see releases/<arch>/autobuilds/latest-stage3-*).
test "stage3 stem matrix matches autobuilds" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { src: []const u8, stem: []const u8 }{
        .{ .src = \\arch = "amd64"
                 \\[security]
                 \\hardening = "standard"
                 \\selinux = false
                 , .stem = "systemd" },
        .{ .src = \\arch = "amd64"
                 \\[system]
                 \\init = "openrc"
                 , .stem = "hardened-selinux-openrc" },
        .{ .src = \\arch = "amd64"
                 \\[system]
                 \\init = "openrc"
                 \\[security]
                 \\hardening = "hardened"
                 \\selinux = false
                 , .stem = "hardened-openrc" },
        .{ .src = \\arch = "amd64"
                 \\[stage3]
                 \\toolchain = "llvm"
                 \\[security]
                 \\hardening = "standard"
                 \\selinux = false
                 , .stem = "llvm-systemd" },
        .{ .src = \\arch = "amd64"
                 \\[stage3]
                 \\nomultilib = true
                 \\[system]
                 \\init = "openrc"
                 \\[security]
                 \\hardening = "standard"
                 \\selinux = false
                 , .stem = "nomultilib-openrc" },
        .{ .src = \\arch = "amd64"
                 \\[stage3]
                 \\libc = "musl"
                 \\[security]
                 \\hardening = "hardened"
                 \\selinux = false
                 , .stem = "musl-hardened-systemd" },
        .{ .src = \\arch = "arm64"
                 \\[stage3]
                 \\libc = "musl"
                 \\toolchain = "llvm"
                 \\[security]
                 \\hardening = "standard"
                 \\selinux = false
                 \\[system]
                 \\init = "openrc"
                 , .stem = "musl-llvm-openrc" },
        // riscv carries musl in the ABI token — stem is init only
        .{ .src = \\arch = "riscv64"
                 \\[stage3]
                 \\libc = "musl"
                 \\[security]
                 \\hardening = "standard"
                 \\selinux = false
                 , .stem = "systemd" },
        // nomultilib is a no-op where the ABI is already single
        .{ .src = \\arch = "arm64"
                 \\[stage3]
                 \\nomultilib = true
                 \\[security]
                 \\hardening = "standard"
                 \\selinux = false
                 \\[system]
                 \\init = "openrc"
                 , .stem = "openrc" },
    };
    for (cases) |tc| {
        var doc = try toml.parse(alloc, tc.src, null);
        defer doc.deinit();
        const cfg = try decode(doc.arena.allocator(), doc);
        const stem = try stage3Stem(doc.arena.allocator(), &cfg);
        try std.testing.expectEqualStrings(tc.stem, stem);
    }
}

// Build a minimal-but-valid config with the given stage3 axes for
// matrix tests (disk + login path are fillers). The caller owns doc —
// errs and cfg borrow from its arena.
fn validCfg(alloc: Allocator, src: []const u8) !struct { doc: toml.Document, cfg: Config, errs: [][]const u8 } {
    var doc = try toml.parse(alloc, src, null);
    errdefer doc.deinit();
    const cfg = try decode(doc.arena.allocator(), doc);
    const errs = try validate(doc.arena.allocator(), &cfg, null, null);
    return .{ .doc = doc, .cfg = cfg, .errs = errs };
}

const matrix_base =
    \\arch = "{s}"
    \\[disk]
    \\device = "/dev/sda"
    \\[stage3]
    \\{s}
    \\[system]
    \\init = "{s}"
    \\[security]
    \\hardening = "{s}"
    \\selinux = {}
    \\[[users]]
    \\name = "a"
    \\password_hash = "$6$x$y"
;

test "validate stage3 variant matrix" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { arch: []const u8, s3: []const u8, init: []const u8, h: []const u8, se: bool, ok: bool }{
        .{ .arch = "amd64", .s3 = "", .init = "systemd", .h = "hardened-selinux", .se = true, .ok = true },
        .{ .arch = "amd64", .s3 = "libc = \"musl\"", .init = "systemd", .h = "standard", .se = false, .ok = true },
        .{ .arch = "amd64", .s3 = "libc = \"musl\"\ntoolchain = \"llvm\"", .init = "openrc", .h = "standard", .se = false, .ok = true },
        .{ .arch = "amd64", .s3 = "libc = \"musl\"", .init = "openrc", .h = "hardened", .se = false, .ok = true },
        .{ .arch = "amd64", .s3 = "nomultilib = true", .init = "openrc", .h = "standard", .se = false, .ok = true },
        .{ .arch = "amd64", .s3 = "libc = \"musl\"", .init = "openrc", .h = "hardened-selinux", .se = true, .ok = false }, // no musl-selinux
        .{ .arch = "amd64", .s3 = "toolchain = \"llvm\"", .init = "systemd", .h = "hardened", .se = false, .ok = false }, // no glibc hardened-llvm
        .{ .arch = "amd64", .s3 = "libc = \"musl\"\ntoolchain = \"llvm\"", .init = "openrc", .h = "hardened", .se = false, .ok = false }, // no musl-hardened-llvm
        .{ .arch = "amd64", .s3 = "nomultilib = true", .init = "openrc", .h = "hardened", .se = false, .ok = false }, // no hardened-nomultilib
        .{ .arch = "arm64", .s3 = "", .init = "systemd", .h = "standard", .se = false, .ok = true },
        .{ .arch = "arm64", .s3 = "libc = \"musl\"", .init = "openrc", .h = "hardened", .se = false, .ok = true }, // musl-hardened exists on arm64
        .{ .arch = "arm64", .s3 = "", .init = "systemd", .h = "hardened", .se = false, .ok = false }, // no arm64 glibc hardened
        .{ .arch = "arm64", .s3 = "", .init = "systemd", .h = "hardened-selinux", .se = true, .ok = false }, // no arm64 selinux
        .{ .arch = "riscv64", .s3 = "", .init = "systemd", .h = "standard", .se = false, .ok = true },
        .{ .arch = "riscv64", .s3 = "libc = \"musl\"", .init = "openrc", .h = "standard", .se = false, .ok = true },
        .{ .arch = "riscv64", .s3 = "", .init = "openrc", .h = "hardened", .se = false, .ok = false },
        .{ .arch = "riscv64", .s3 = "toolchain = \"llvm\"", .init = "systemd", .h = "standard", .se = false, .ok = false },
    };
    for (cases) |tc| {
        const src = try std.fmt.allocPrint(alloc, matrix_base, .{ tc.arch, tc.s3, tc.init, tc.h, tc.se });
        defer alloc.free(src);
        var r = try validCfg(alloc, src);
        defer r.doc.deinit();
        var stage3_err = false;
        for (r.errs) |e| {
            if (std.mem.indexOf(u8, e, "stage3") != null) stage3_err = true;
        }
        if (tc.ok) {
            if (stage3_err) std.debug.print("unexpected stage3 err: {s}\n", .{r.errs[0]});
            try std.testing.expect(!stage3_err);
        } else {
            if (!stage3_err) std.debug.print("expected stage3 err for {s}/{s}\n", .{ tc.arch, tc.s3 });
            try std.testing.expect(stage3_err);
        }
    }
}

test "validate rejects proprietary nvidia on musl/riscv64" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { arch: []const u8, libc: []const u8, ok: bool }{
        .{ .arch = "amd64", .libc = "glibc", .ok = true },
        .{ .arch = "amd64", .libc = "musl", .ok = false },
        .{ .arch = "riscv64", .libc = "glibc", .ok = false },
        .{ .arch = "arm64", .libc = "glibc", .ok = true },
    };
    for (cases) |tc| {
        const src = try std.fmt.allocPrint(alloc,
            \\arch = "{s}"
            \\[disk]
            \\device = "/dev/sda"
            \\[stage3]
            \\libc = "{s}"
            \\[gpu]
            \\driver = "nvidia-drivers"
            \\[security]
            \\hardening = "standard"
            \\selinux = false
            \\[[users]]
            \\name = "a"
            \\password_hash = "$6$x$y"
        , .{ tc.arch, tc.libc });
        defer alloc.free(src);
        var r = try validCfg(alloc, src);
        defer r.doc.deinit();
        var nv_err = false;
        for (r.errs) |e| {
            if (std.mem.indexOf(u8, e, "NVIDIA") != null) nv_err = true;
        }
        try std.testing.expect(nv_err != tc.ok);
    }
}

test "validate rejects bad stage3.variant charset" {
    var doc = try toml.parse(std.testing.allocator,
        \\[stage3]
        \\variant = "../evil"
    , null);
    defer doc.deinit();
    const cfg = try decode(doc.arena.allocator(), doc);
    const errs = try validate(doc.arena.allocator(), &cfg, null, null);
    var seen = false;
    for (errs) |e| {
        if (std.mem.indexOf(u8, e, "variant") != null) seen = true;
    }
    try std.testing.expect(seen);
}

fn alongsideTestEnv(alloc: std.mem.Allocator) !detect.Env {
    const parts = try alloc.dupe(detect.PartInfo, &.{
        .{ .num = 1, .path = "/dev/sda1", .fs = "vfat", .partuuid = "ESP-UUID", .esp = true, .start_sector = 2048, .size_bytes = 512 << 20 },
        .{ .num = 2, .path = "/dev/sda2", .fs = "ntfs", .partuuid = "P2", .start_sector = 1050624, .size_bytes = 100 << 30, .fs_size_bytes = 100 << 30, .fs_free_bytes = 60 << 30 },
        .{ .num = 3, .path = "/dev/sda3", .fs = "xfs", .partuuid = "P3", .start_sector = 210766848, .size_bytes = 20 << 30, .fs_size_bytes = 20 << 30, .fs_free_bytes = 15 << 30 },
    });
    const disks = try alloc.dupe(detect.DiskInfo, &.{.{
        .name = "sda",
        .path = "/dev/sda",
        .size_bytes = 256 << 30,
        .removable = false,
        .label = "gpt",
        .parts = parts,
        .free_regions = &.{.{ .start_sector = 260000768, .end_sector = 500000000 }},
    }});
    return .{
        .boot_mode = .uefi,
        .arch = .amd64,
        .ram_mib = 8192,
        .cpu_count = 2,
        .cpu_vendor = "x",
        .cpu_flags = &.{},
        .nics = &.{},
        .gpus = &.{},
        .disks = disks,
        .net_reachable = true,
        .os_hint = "windows",
    };
}

test "validate alongside: UEFI/GPT/ESP/shrinkable-fs rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const env = try alongsideTestEnv(alloc);

    // happy path: shrink the ntfs part
    var doc = try toml.parse(alloc,
        \\boot_mode = "uefi"
        \\arch = "amd64"
        \\[disk]
        \\device = "/dev/sda"
        \\scheme = "alongside"
        \\wipe = false
        \\space_src = "shrink"
        \\shrink_part = "/dev/sda2"
        \\shrink_mib = 20000
        \\swap = "zram"
        \\[[users]]
        \\name = "a"
        \\password_hash = "$6$xyz"
    , null);
    defer doc.deinit();
    const cfg = try decode(alloc, doc);
    const ok = try validate(alloc, &cfg, null, &env);
    for (ok) |e| std.debug.print("err: {s}\n", .{e});
    try std.testing.expectEqual(@as(usize, 0), ok.len);

    // BIOS refuses
    var cfg2 = cfg;
    cfg2.boot_mode = .bios;
    const errs2 = try validate(alloc, &cfg2, null, &env);
    var saw_bios = false;
    for (errs2) |e| if (std.mem.indexOf(u8, e, "UEFI") != null) {
        saw_bios = true;
    };
    try std.testing.expect(saw_bios);

    // wipe=true refused
    var cfg3 = cfg;
    cfg3.disk.wipe = true;
    const errs3 = try validate(alloc, &cfg3, null, &env);
    var saw_wipe = false;
    for (errs3) |e| if (std.mem.indexOf(u8, e, "wipe") != null) {
        saw_wipe = true;
    };
    try std.testing.expect(saw_wipe);

    // unshrinkable fs refused
    var cfg4 = cfg;
    cfg4.disk.shrink_part = "/dev/sda3"; // xfs
    const errs4 = try validate(alloc, &cfg4, null, &env);
    var saw_fs = false;
    for (errs4) |e| if (std.mem.indexOf(u8, e, "xfs") != null or std.mem.indexOf(u8, e, "shrink") != null) {
        saw_fs = true;
    };
    try std.testing.expect(saw_fs);

    // free-space src uses the detected region
    var cfg5 = cfg;
    cfg5.disk.space_src = .@"free-space";
    cfg5.disk.shrink_part = "";
    const ok5 = try validate(alloc, &cfg5, null, &env);
    try std.testing.expectEqual(@as(usize, 0), ok5.len);

    // env=null → preview mode skips the env-gated checks
    const ok6 = try validate(alloc, &cfg, null, null);
    try std.testing.expectEqual(@as(usize, 0), ok6.len);
}
