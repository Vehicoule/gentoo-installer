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
    } = .{},

    stage3: struct {
        libc: Libc = .glibc,
        toolchain: Toolchain = .gcc,
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
        if (field(t, "scheme")) |x| cfg.disk.scheme = try enumOr(Scheme, x, "disk.scheme");
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
    }

    if (doc.root.get("stage3")) |v| {
        const t = try tableOf(v, "stage3");
        if (field(t, "libc")) |x| cfg.stage3.libc = try enumOr(Libc, x, "stage3.libc");
        if (field(t, "toolchain")) |x| cfg.stage3.toolchain = try enumOr(Toolchain, x, "stage3.toolchain");
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

/// Resolve the stage3 stem from the axes (libc × toolchain × hardening ×
/// init) unless `stage3.variant` pins one explicitly.
pub fn stage3Stem(alloc: Allocator, cfg: *const Config) ![]const u8 {
    if (!std.mem.eql(u8, cfg.stage3.variant, "auto")) return cfg.stage3.variant;
    // Stem word order matches Gentoo's published names:
    // stage3-<arch>[-musl][-hardened[-selinux]][-llvm]-<init>
    var parts: std.ArrayList([]const u8) = .empty;
    if (cfg.stage3.libc == .musl) try parts.append(alloc, "musl");
    switch (cfg.security.hardening) {
        .standard => {},
        .hardened => try parts.append(alloc, "hardened"),
        .@"hardened-selinux" => try parts.append(alloc, "hardened-selinux"),
    }
    if (cfg.stage3.toolchain == .llvm) try parts.append(alloc, "llvm");
    try parts.append(alloc, switch (cfg.system.init) {
        .systemd => "systemd",
        else => "openrc", // non-systemd stage3s ship openrc; alt inits swap later
    });
    return std.mem.join(alloc, "-", parts.items);
}

/// VALIDATE: returns a list of violations (empty = valid). `env` may be
/// null when hardware detection hasn't run (unattended dry-run still
/// checks what it can).
pub fn validate(alloc: Allocator, cfg: *const Config, has_nvidia: ?bool) ![][]const u8 {
    var errs: std.ArrayList([]const u8) = .empty;

    if (cfg.disk.device.len == 0)
        try errs.append(alloc, "disk.device is required (e.g. /dev/vda)");
    if (cfg.disk.luks and cfg.disk.luks_passphrase == null)
        try errs.append(alloc, "disk.luks requires disk.luks_passphrase in exec mode (wizard collects it interactively)");

    // Control chars / newlines in values interpolated into generated
    // files or argv would inject extra directives — reject them all.
    const injectable = [_]?[]const u8{
        cfg.disk.device,
        cfg.disk.shrink_part,
        cfg.stage3.mirror,
        cfg.system.hostname,
        cfg.system.timezone,
        cfg.system.locale,
        cfg.system.keymap,
        cfg.makeconf.mirrors,
        cfg.makeconf.accept_license,
        cfg.makeconf.video_cards,
        cfg.root.password_hash,
        cfg.disk.luks_passphrase,
    };
    for (injectable) |ms| {
        const v = ms orelse continue;
        if (hasCtl(v)) try errs.append(alloc, fmt(alloc, "value contains control characters: '{s}'", .{v}));
    }
    if (cfg.makeconf.cflags == .custom) {
        const v = cfg.makeconf.cflags.custom;
        if (hasCtl(v) or hasShellMeta(v))
            try errs.append(alloc, "makeconf.cflags contains shell metacharacters — portage sources make.conf");
    }
    // URLs interpolated into sh -c strings must be plain URL charset.
    if (!urlSafe(cfg.stage3.mirror))
        try errs.append(alloc, "stage3.mirror contains characters outside URL charset");
    if (!urlSafe(cfg.makeconf.mirrors))
        try errs.append(alloc, "makeconf.mirrors contains characters outside URL charset");
    // Erase-disk schemes always format — wipe=false preserves nothing.
    if (!cfg.disk.wipe and cfg.disk.scheme != .alongside and cfg.disk.scheme != .manual)
        try errs.append(alloc, "disk.wipe=false has no effect on erase schemes — use alongside/manual to preserve data");
    // Erase scheme must match the firmware boot mode (partition layout
    // and bootloader paths are mode-specific).
    if (cfg.disk.scheme == .@"efi-swap-root" and cfg.boot_mode == .bios)
        try errs.append(alloc, "disk.scheme=efi-swap-root requires boot_mode=uefi — use bios-boot-swap-root");
    if (cfg.disk.scheme == .@"bios-boot-swap-root" and cfg.boot_mode == .uefi)
        try errs.append(alloc, "disk.scheme=bios-boot-swap-root requires boot_mode=bios — use efi-swap-root");
    // BIOS limine reads only ext-family filesystems and cannot unlock
    // LUKS — a separate /boot is required unless the root is plain ext4.
    if (cfg.boot_mode == .bios and resolveBootloader(cfg) == .limine) {
        if (cfg.disk.luks and !cfg.disk.boot_part)
            try errs.append(alloc, "BIOS + LUKS requires disk.boot_part=true — limine cannot read encrypted roots");
        if (cfg.disk.root_fs != .ext4 and !cfg.disk.boot_part)
            try errs.append(alloc, fmt(alloc, "BIOS limine cannot read {s} roots — set disk.boot_part=true (ext4 /boot)", .{@tagName(cfg.disk.root_fs)}));
    }
    // Network managers must match init capabilities.
    if (cfg.network.manager == .netifrc and cfg.system.init != .openrc)
        try errs.append(alloc, "network.manager=netifrc requires init=openrc");
    if (cfg.network.manager == .@"systemd-networkd" and cfg.system.init != .systemd)
        try errs.append(alloc, "network.manager=systemd-networkd requires init=systemd");
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
        for (u.groups) |g|
            if (hasCtl(g)) try errs.append(alloc, fmt(alloc, "group '{s}' has control characters", .{g}));
        for (u.ssh_authorized_keys) |k|
            if (hasCtl(k)) try errs.append(alloc, fmt(alloc, "ssh key for '{s}' has control characters", .{u.name}));
    }
    var uit = cfg.use.global.iterator();
    while (uit.next()) |kv| {
        if (hasCtl(kv.key_ptr.*)) try errs.append(alloc, "USE flag name has control characters");
    }

    if (cfg.disk.scheme == .alongside) {
        if (cfg.disk.wipe) try errs.append(alloc, "disk.scheme=alongside requires wipe=false");
        if (cfg.disk.space_src == .shrink and cfg.disk.shrink_part.len == 0)
            try errs.append(alloc, "alongside+shrink requires disk.shrink_part");
        if (cfg.disk.space_src == .shrink and cfg.disk.shrink_mib == 0)
            try errs.append(alloc, "alongside+shrink requires disk.shrink_mib");
    }

    if (cfg.boot_mode == .bios) {
        switch (resolveBootloader(cfg)) {
            .@"systemd-boot", .efistub, .refind =>
                try errs.append(alloc, "bootloader requires UEFI on a BIOS boot"),
            else => {},
        }
        if (cfg.system.uki) try errs.append(alloc, "uki requires UEFI");
        if (cfg.security.secure_boot != .off)
            try errs.append(alloc, "secure_boot requires UEFI; forced off on BIOS");
    }

    if ((cfg.disk.luks or cfg.disk.lvm) and cfg.system.initramfs == .none)
        try errs.append(alloc, "luks/lvm root requires an initramfs (dracut|ugrd)");

    if (cfg.stage3.libc == .musl and cfg.system.init == .systemd)
        try errs.append(alloc, "systemd requires glibc — musl supports openrc/runit/s6/dinit");

    if (cfg.security.secure_boot == .shim and resolveBootloader(cfg) != .grub)
        try errs.append(alloc, "secure_boot=shim is only supported with grub");

    if (cfg.system.privilege == .none and cfg.root.lock_root)
        try errs.append(alloc, "privilege=none with lock_root leaves no admin path");

    if (cfg.stage3.toolchain == .llvm and cfg.security.hardening == .@"hardened-selinux" and cfg.stage3.libc == .glibc)
        try errs.append(alloc, "glibc+llvm+hardened-selinux has no stage3 stem; use hardened-llvm or gcc");

    // Login-path proof: some credential must survive to the finished
    // system, or sshd must be reachable with keys.
    var login_path = false;
    if (cfg.root.password_hash != null and !cfg.root.lock_root) login_path = true;
    for (cfg.users) |u| {
        if (u.password_hash != null) login_path = true;
        if (cfg.services.sshd and u.ssh_authorized_keys.len > 0) login_path = true;
    }
    if (!login_path)
        try errs.append(alloc, "no surviving login path: set a password_hash, or sshd=true plus ssh_authorized_keys");

    if (cfg.gpu.driver == .@"nvidia-open") {
        if (has_nvidia) |nv| {
            if (!nv) try errs.append(alloc, "gpu.driver=nvidia-open but no NVIDIA GPU detected");
        }
    }

    // locale must be a member of locales
    var found = false;
    for (cfg.system.locales) |l| {
        if (std.mem.eql(u8, l, cfg.system.locale)) found = true;
    }
    if (!found) try errs.append(alloc, "system.locale must be one of system.locales");

    return errs.items;
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
    const errs = try validate(doc.arena.allocator(), &cfg, null);
    try std.testing.expect(errs.len > 0);
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
    const errs = try validate(doc.arena.allocator(), &cfg, null);
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
        \\[system]
        \\init = "dinit"
    , null);
    defer doc.deinit();
    const cfg = try decode(doc.arena.allocator(), doc);
    const stem = try stage3Stem(doc.arena.allocator(), &cfg);
    try std.testing.expectEqualStrings("musl-hardened-selinux-openrc", stem);
}
