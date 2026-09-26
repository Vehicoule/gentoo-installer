//! Wizard state machine — the engine-owned page surface every frontend
//! (TUI today, libcosmic GUI at M4) renders. Pages are data: field
//! schemas with types, defaults, options, and visibility predicates
//! evaluated HERE — frontends only draw what the page event carries.
//! See docs/pages.md (field spec) and docs/protocol.md (wire format).

const std = @import("std");
const config = @import("config.zig");
const detect = @import("detect.zig");
const plan = @import("plan.zig");
const preset_mod = @import("preset.zig");
const toml = @import("toml.zig");
const Allocator = std.mem.Allocator;
const Config = config.Config;
const Env = detect.Env;

pub const Flow = enum { express, advanced };
pub const FType = enum { @"enum", bool, int, string, secret, list, record, table, path };

pub const WizardError = error{
    UnknownField,
    BadType,
    BadValue,
    OutOfMemory,
    HashFailed,
    ReadFailed,
    InvalidToml,
    BadConfig,
    WriteFailed,
    PathEscape,
    Locked,
};

const Opt = struct {
    v: []const u8,
    label: []const u8,
    help: ?[]const u8 = null,
    visible: ?*const fn (*const Wizard) bool = null,
};

const Field = struct {
    name: []const u8, // dotted config path, or a pseudo-field (see setField)
    ftype: FType,
    label: []const u8,
    help: ?[]const u8 = null,
    options: []const Opt = &.{},
    expert: bool = false, // Advanced flow only
    confirm: bool = false, // secret fields: frontend asks twice
    min_len: ?usize = null,
    visible: ?*const fn (*const Wizard) bool = null,
};

const Page = struct {
    id: []const u8,
    title: []const u8,
    essential: bool, // visited in Express flow
    fields: []const Field = &.{},
    /// validation error field-prefixes owned by this page
    prefixes: []const []const u8 = &.{},
};

// ---------- visibility predicates ----------

fn isUefi(w: *const Wizard) bool {
    return w.cfg.boot_mode == .uefi;
}
fn isBios(w: *const Wizard) bool {
    return w.cfg.boot_mode == .bios;
}
fn luksOn(w: *const Wizard) bool {
    return w.cfg.disk.luks;
}
fn swapIsPart(w: *const Wizard) bool {
    return w.cfg.disk.swap == .partition;
}
fn btrfsRoot(w: *const Wizard) bool {
    return w.cfg.disk.root_fs == .btrfs;
}
fn isAlongside(w: *const Wizard) bool {
    return w.cfg.disk.scheme == .alongside;
}
fn shrinkSrc(w: *const Wizard) bool {
    return w.cfg.disk.scheme == .alongside and cfg_space(w) == .shrink;
}
fn cfg_space(w: *const Wizard) config.SpaceSrc {
    return w.cfg.disk.space_src;
}
fn hasOtherOs(w: *const Wizard) bool {
    _ = w;
    // OS probing lands with dual-boot (M6) — until then `alongside`
    // stays hidden and unexecutable.
    return false;
}
fn rootByPassword(w: *const Wizard) bool {
    return !w.cfg.root.lock_root;
}
fn hasNvidia(w: *const Wizard) bool {
    const e = w.env orelse return false;
    for (e.gpus) |g| if (std.mem.eql(u8, g.vendor, "nvidia")) return true;
    return false;
}
fn systemdInit(w: *const Wizard) bool {
    return w.cfg.system.init == .systemd;
}
fn notSystemd(w: *const Wizard) bool {
    return w.cfg.system.init != .systemd;
}
fn isExpress(w: *const Wizard) bool {
    return w.flow == .express;
}
fn isAdvanced(w: *const Wizard) bool {
    return w.flow == .advanced;
}

// ---------- field tables ----------

const keymap_opts = [_]Opt{
    .{ .v = "us", .label = "US English" },
    .{ .v = "uk", .label = "UK English" },
    .{ .v = "de", .label = "German" },
    .{ .v = "fr", .label = "French" },
    .{ .v = "es", .label = "Spanish" },
    .{ .v = "it", .label = "Italian" },
    .{ .v = "pt", .label = "Portuguese" },
    .{ .v = "br", .label = "Brazilian" },
    .{ .v = "ru", .label = "Russian" },
    .{ .v = "jp", .label = "Japanese" },
    .{ .v = "dvorak", .label = "Dvorak" },
};

const welcome_fields = [_]Field{
    .{ .name = "system.keymap", .ftype = .@"enum", .label = "Keyboard layout", .help = "applies to this live session immediately", .options = &keymap_opts },
    .{ .name = "flow.mode", .ftype = .@"enum", .label = "Install mode", .options = &.{
        .{ .v = "express", .label = "Express", .help = "opinionated defaults — pick a disk and accounts only" },
        .{ .v = "advanced", .label = "Advanced", .help = "every option exposed" },
    } },
    .{ .name = "answer_file", .ftype = .path, .label = "Load answer file", .help = "a saved --config TOML; jumps straight to Review", .expert = false },
};

const disk_fields = [_]Field{
    .{ .name = "disk.device", .ftype = .@"enum", .label = "Target disk", .help = "the disk to install onto" },
    .{ .name = "boot_mode", .ftype = .@"enum", .label = "Boot mode", .help = "auto = firmware-detected", .visible = isAdvanced, .options = &.{
        .{ .v = "auto", .label = "auto (detected)" },
        .{ .v = "bios", .label = "BIOS (legacy)" },
        .{ .v = "uefi", .label = "UEFI" },
    } },
    .{ .name = "disk.scheme", .ftype = .@"enum", .label = "Partitioning", .options = &.{
        .{ .v = "efi-swap-root", .label = "Normal — erase disk (UEFI layout)", .visible = isUefi },
        .{ .v = "bios-boot-swap-root", .label = "Normal — erase disk (BIOS layout)", .visible = isBios },
        .{ .v = "alongside", .label = "Install alongside existing OS", .visible = hasOtherOs },
        .{ .v = "manual", .label = "Manual partition table", .help = "expert", .visible = null },
    } },
    .{ .name = "disk.root_fs", .ftype = .@"enum", .label = "Root filesystem", .options = &.{
        .{ .v = "btrfs", .label = "btrfs", .help = "recommended — CoW snapshots/rollback" },
        .{ .v = "xfs", .label = "xfs" },
        .{ .v = "ext4", .label = "ext4" },
        .{ .v = "f2fs", .label = "f2fs" },
        .{ .v = "bcachefs", .label = "bcachefs", .help = "expert — needs a recent kernel" },
    } },
    .{ .name = "disk.swap", .ftype = .@"enum", .label = "Swap", .options = &.{
        .{ .v = "zram", .label = "zram (in-RAM compressed)", .help = "recommended — no disk swap" },
        .{ .v = "partition", .label = "swap partition" },
        .{ .v = "none", .label = "none" },
    } },
    .{ .name = "disk.swap_mib", .ftype = .int, .label = "Swap size (MiB)", .visible = swapIsPart },
    .{ .name = "disk.esp_mib", .ftype = .int, .label = "ESP size (MiB)", .help = "≥128; ≥512 for UKI/systemd-boot", .expert = true, .visible = isUefi },
    .{ .name = "disk.boot_part", .ftype = .bool, .label = "Separate /boot partition", .expert = true },
    .{ .name = "disk.luks", .ftype = .bool, .label = "Encrypt root (LUKS2)", .help = "argon2id, passphrase on stdin" },
    .{ .name = "disk.luks_passphrase", .ftype = .secret, .label = "Encryption passphrase", .min_len = 8, .confirm = true, .visible = luksOn },
    .{ .name = "disk.lvm", .ftype = .bool, .label = "LVM volume group", .help = "thin pool when snapshots are on" },
    .{ .name = "disk.home_part", .ftype = .bool, .label = "Separate /home (LVM LV)", .expert = true },
    .{ .name = "disk.space_src", .ftype = .@"enum", .label = "Space source", .options = &.{
        .{ .v = "free-space", .label = "Use free space" },
        .{ .v = "shrink", .label = "Shrink a partition" },
    }, .visible = isAlongside },
    .{ .name = "disk.shrink_part", .ftype = .string, .label = "Partition to shrink", .visible = shrinkSrc },
    .{ .name = "disk.shrink_mib", .ftype = .int, .label = "Shrink by (MiB)", .visible = shrinkSrc },
};

const variant_fields = [_]Field{
    .{ .name = "system.init", .ftype = .@"enum", .label = "Init system", .options = &.{
        .{ .v = "systemd", .label = "systemd", .help = "upstream default for desktops" },
        .{ .v = "openrc", .label = "openrc", .help = "Gentoo's classic init" },
        .{ .v = "runit", .label = "runit", .help = "early support" },
        .{ .v = "s6", .label = "s6", .help = "early support" },
        .{ .v = "dinit", .label = "dinit", .help = "early support" },
    } },
    .{ .name = "stage3.libc", .ftype = .@"enum", .label = "C library", .options = &.{
        .{ .v = "glibc", .label = "glibc" },
        .{ .v = "musl", .label = "musl", .help = "leaner; removes systemd" },
    } },
    .{ .name = "stage3.toolchain", .ftype = .@"enum", .label = "Toolchain", .options = &.{
        .{ .v = "gcc", .label = "gcc" },
        .{ .v = "llvm", .label = "llvm/clang" },
    } },
    .{ .name = "security.hardening", .ftype = .@"enum", .label = "Hardening", .help = "lives in the stage3 toolchain — picks a different tarball", .options = &.{
        .{ .v = "hardened-selinux", .label = "hardened + SELinux", .help = "default" },
        .{ .v = "hardened", .label = "hardened" },
        .{ .v = "standard", .label = "standard" },
    } },
    .{ .name = "stage3.variant", .ftype = .string, .label = "Stage3 stem override", .help = "e.g. hardened-selinux-systemd", .expert = true },
    .{ .name = "system.binhost", .ftype = .bool, .label = "Use official binary packages", .help = "signature-verified binhost" },
};

const region_fields = [_]Field{
    .{ .name = "system.timezone", .ftype = .string, .label = "Timezone", .help = "zoneinfo name, e.g. Europe/Lisbon" },
    .{ .name = "system.locales", .ftype = .list, .label = "Locales to generate", .help = "locale.gen entries" },
    .{ .name = "system.locale", .ftype = .string, .label = "Default locale" },
    .{ .name = "system.keymap", .ftype = .@"enum", .label = "Console keymap", .options = &keymap_opts },
    .{ .name = "services.ntp", .ftype = .bool, .label = "Network time sync", .help = "chrony / systemd-timesyncd" },
};

const accounts_fields = [_]Field{
    .{ .name = "root.mode", .ftype = .@"enum", .label = "Root account", .options = &.{
        .{ .v = "password", .label = "Set a root password" },
        .{ .v = "locked", .label = "Locked", .help = "needs a wheel user or ssh key" },
    } },
    .{ .name = "root.password", .ftype = .secret, .label = "Root password", .min_len = 8, .confirm = true, .visible = rootByPassword },
    .{ .name = "user.name", .ftype = .string, .label = "User name", .help = "your login — added to wheel", .visible = isExpress },
    .{ .name = "user.password", .ftype = .secret, .label = "User password", .min_len = 8, .confirm = true, .visible = isExpress },
    .{ .name = "users", .ftype = .table, .label = "User accounts", .help = "name, password, groups, shell, ssh keys", .visible = isAdvanced },
    .{ .name = "system.privilege", .ftype = .@"enum", .label = "Privilege escalation", .options = &.{
        .{ .v = "doas", .label = "doas", .help = "minimal-footprint default" },
        .{ .v = "sudo", .label = "sudo" },
        .{ .v = "none", .label = "none" },
    } },
};

const system_fields = [_]Field{
    .{ .name = "system.hostname", .ftype = .string, .label = "Hostname" },
    .{ .name = "system.kernel", .ftype = .@"enum", .label = "Kernel", .options = &.{
        .{ .v = "dist-bin", .label = "Prebuilt official kernel", .help = "fastest, recommended" },
        .{ .v = "dist", .label = "Compiled with Gentoo defaults", .help = "tunable" },
        .{ .v = "manual", .label = "gentoo-sources — configure it yourself", .help = "expert" },
    } },
    .{ .name = "system.initramfs", .ftype = .@"enum", .label = "Initramfs", .options = &.{
        .{ .v = "dracut", .label = "dracut" },
        .{ .v = "ugrd", .label = "ugrd" },
        .{ .v = "none", .label = "none", .help = "unsafe with LUKS/LVM" },
    } },
    .{ .name = "system.uki", .ftype = .bool, .label = "Unified kernel image (UKI)", .visible = isUefi },
    .{ .name = "system.bootloader", .ftype = .@"enum", .label = "Bootloader", .options = &.{
        .{ .v = "auto", .label = "Automatic (limine)", .help = "recommended — works on BIOS and UEFI" },
        .{ .v = "limine", .label = "Limine" },
        .{ .v = "grub", .label = "GRUB" },
        .{ .v = "systemd-boot", .label = "systemd-boot", .visible = systemdInit },
        .{ .v = "efistub", .label = "efistub (firmware entry)", .visible = isUefi },
        .{ .v = "refind", .label = "rEFInd", .visible = isUefi },
    } },
    .{ .name = "security.selinux", .ftype = .bool, .label = "SELinux", .help = "policy + toolchain ship in the hardened-selinux stage3 — toggling moves Hardening with it" },
    .{ .name = "security.secure_boot", .ftype = .@"enum", .label = "Secure boot", .options = &.{
        .{ .v = "off", .label = "off" },
        .{ .v = "sbctl", .label = "sbctl (self-signed keys)" },
        .{ .v = "shim", .label = "shim + MOK (grub only)" },
    }, .visible = isUefi },
    .{ .name = "system.snapshots", .ftype = .@"enum", .label = "System snapshots", .options = &.{
        .{ .v = "auto", .label = "auto (btrfs/LVM when available)" },
        .{ .v = "off", .label = "off" },
    } },
    .{ .name = "system.keep_kernels", .ftype = .int, .label = "Kernels kept (rollback)", .help = "0 = never prune" },
    .{ .name = "network.manager", .ftype = .@"enum", .label = "Network manager", .options = &.{
        .{ .v = "networkmanager", .label = "NetworkManager" },
        .{ .v = "dhcpcd", .label = "dhcpcd" },
        .{ .v = "netifrc", .label = "netifrc", .visible = notSystemd },
        .{ .v = "systemd-networkd", .label = "systemd-networkd", .visible = systemdInit },
    } },
    .{ .name = "network.wifi", .ftype = .bool, .label = "Wi-Fi support", .help = "linux-firmware + iwd" },
    .{ .name = "gpu.driver", .ftype = .@"enum", .label = "NVIDIA driver", .options = &.{
        .{ .v = "auto", .label = "auto", .help = "open modules on Turing+; nouveau otherwise" },
        .{ .v = "nvidia-open", .label = "nvidia-open", .help = "proprietary, Turing and newer" },
        .{ .v = "nvidia-drivers", .label = "nvidia-drivers", .help = "proprietary, legacy GPUs" },
        .{ .v = "nouveau", .label = "nouveau", .help = "open source" },
    }, .visible = hasNvidia },
    .{ .name = "services.sshd", .ftype = .bool, .label = "SSH server" },
    .{ .name = "services.logger", .ftype = .bool, .label = "System logger" },
    .{ .name = "services.cron", .ftype = .bool, .label = "Cron daemon" },
};

const packages_fields = [_]Field{
    .{ .name = "packages.sets", .ftype = .list, .label = "Package sets", .help = "from the active preset (minimal/cosmic/cosmic-full)" },
    .{ .name = "packages.atoms", .ftype = .list, .label = "Extra packages", .help = "portage atoms, e.g. app-editors/vim" },
    .{ .name = "use.global", .ftype = .record, .label = "Global USE flags", .help = "tri-state: true/false/absent" },
    .{ .name = "use.pkg", .ftype = .record, .label = "Per-package USE", .help = "atom → \"flag -flag\"", .expert = true },
    .{ .name = "makeconf.accept_license", .ftype = .string, .label = "ACCEPT_LICENSE" },
    .{ .name = "makeconf.cflags", .ftype = .@"enum", .label = "CFLAGS", .options = &.{
        .{ .v = "native", .label = "native (-march=native)" },
        .{ .v = "safe", .label = "safe (-O2 -pipe)" },
        .{ .v = "custom", .label = "custom…", .help = "expert" },
    } },
    .{ .name = "makeconf.cflags_custom", .ftype = .string, .label = "Custom CFLAGS", .expert = true },
    .{ .name = "makeconf.jobs", .ftype = .int, .label = "Parallel jobs", .help = "0 = auto (nproc, ~2 GiB/job)" },
    .{ .name = "makeconf.mem_cap_gib", .ftype = .int, .label = "Memory cap (GiB)", .help = "0 = auto" },
    .{ .name = "makeconf.video_cards", .ftype = .string, .label = "VIDEO_CARDS", .help = "auto-detected" },
};

pub const pages = [_]Page{
    .{ .id = "welcome", .title = "Welcome", .essential = true, .fields = &welcome_fields, .prefixes = &.{"system.keymap"} },
    .{ .id = "disk", .title = "Disk & partitioning", .essential = true, .fields = &disk_fields, .prefixes = &.{ "disk.", "boot_mode" } },
    .{ .id = "variant", .title = "Variant", .essential = false, .fields = &variant_fields, .prefixes = &.{ "stage3.", "system.init", "system.binhost", "security.hardening" } },
    .{ .id = "region", .title = "Region & input", .essential = false, .fields = &region_fields, .prefixes = &.{ "system.timezone", "system.locale", "system.locales", "services.ntp" } },
    .{ .id = "accounts", .title = "Accounts", .essential = true, .fields = &accounts_fields, .prefixes = &.{ "root.", "users", "system.privilege", "login", "privilege" } },
    .{ .id = "system", .title = "System", .essential = false, .fields = &system_fields, .prefixes = &.{ "system.", "network.", "gpu.", "services.", "security.", "bootloader", "uki" } },
    .{ .id = "packages", .title = "Packages & USE", .essential = false, .fields = &packages_fields, .prefixes = &.{ "packages.", "use.", "makeconf." } },
    .{ .id = "review", .title = "Review & install", .essential = true, .prefixes = &.{} },
};

// ---------- the wizard ----------

pub const Wizard = struct {
    alloc: Allocator,
    io: std.Io,
    cfg: Config,
    env: ?Env = null,
    /// Attached distro preset — package-set resolution for plan/install
    /// runs through it exactly like the CLI path does.
    preset: ?*const preset_mod.Preset = null,
    flow: Flow = .express,
    /// index into `pages` (not the filtered flow order — order is
    /// computed by nextInFlow())
    page_idx: usize = 0,
    detected_boot: ?config.BootMode = null,

    pub fn init(alloc: Allocator, io: std.Io, cfg: Config) Wizard {
        var w = Wizard{ .alloc = alloc, .io = io, .cfg = cfg };
        w.applyExpressDefaults();
        return w;
    }

    /// Express flow picks the opinionated set the distro preset locks:
    /// btrfs, zram, limine, dist-bin, doas, hardened+selinux.
    fn applyExpressDefaults(w: *Wizard) void {
        if (w.flow != .express) return;
        w.cfg.disk.root_fs = .btrfs;
        w.cfg.disk.swap = .zram;
        w.cfg.system.bootloader = .limine;
        w.cfg.system.kernel = .@"dist-bin";
        w.cfg.system.privilege = .doas;
        w.cfg.security.hardening = .@"hardened-selinux";
    }

    /// Pages visible under the current flow, in order.
    fn flowOrder(w: *const Wizard, buf: *[pages.len]usize) []const usize {
        var n: usize = 0;
        for (pages, 0..) |pg, i| {
            if (w.flow == .express and !pg.essential) continue;
            buf[n] = i;
            n += 1;
        }
        return buf[0..n];
    }

    pub fn currentPage(w: *const Wizard) *const Page {
        return &pages[w.page_idx];
    }

    /// Emit the `page` event for the current (or named) page.
    pub fn emitPage(w: *Wizard, out: *std.Io.Writer, req: ?u64, name: ?[]const u8) !void {
        if (name) |nm| {
            var found = false;
            for (pages, 0..) |pg, i| {
                if (std.mem.eql(u8, pg.id, nm)) {
                    w.page_idx = i;
                    found = true;
                    break;
                }
            }
            if (!found) return error.BadValue;
        }
        const pg = w.currentPage();
        try out.writeAll("{\"ev\":\"page\",");
        if (req) |r| try out.print("\"req\":{},", .{r});
        try out.print("\"page\":\"{s}\",\"index\":{},\"of\":{},\"title\":\"", .{ pg.id, w.flowIndex() + 1, w.flowLen() });
        jesc(out, pg.title);
        try out.writeAll("\",\"fields\":[");
        var first = true;
        for (pg.fields) |f| {
            if (f.expert and w.flow == .express) continue;
            if (f.visible) |vis| if (!vis(w)) continue;
            if (!first) try out.writeAll(",");
            first = false;
            try w.emitField(out, f);
        }
        if (std.mem.eql(u8, pg.id, "review")) {
            try out.writeAll("],\"summary\":[");
            try w.emitSummary(out);
        } else {
            try out.writeAll("]");
        }
        try out.writeAll(",\"actions\":[");
        try w.emitActions(out);
        try out.writeAll("]}\n");
    }

    /// Grouped "label: value" summary of the whole config for the
    /// review page — secrets render as set/unset, never values.
    fn emitSummary(w: *Wizard, out: *std.Io.Writer) !void {
        var buf: [pages.len]usize = undefined;
        const order = w.flowOrder(&buf);
        var first_g = true;
        for (order) |pi| {
            const pg = pages[pi];
            if (std.mem.eql(u8, pg.id, "review")) continue;
            if (!first_g) try out.writeAll(",");
            first_g = false;
            try out.writeAll("{\"title\":\"");
            jesc(out, pg.title);
            try out.writeAll("\",\"lines\":[");
            var first_l = true;
            for (pg.fields) |f| {
                if (f.expert and w.flow == .express) continue;
                if (f.visible) |vis| if (!vis(w)) continue;
                if (!first_l) try out.writeAll(",");
                first_l = false;
                var aw: std.Io.Writer.Allocating = .init(w.alloc);
                defer aw.deinit();
                try aw.writer.writeAll(f.label);
                try aw.writer.writeAll(": ");
                try w.fmtField(&aw.writer, f);
                try jstr(out, aw.written());
            }
            try out.writeAll("]}");
        }
        try out.writeAll("]");
    }

    /// Human-readable field value — same policy as emitValue but text.
    fn fmtField(w: *Wizard, out: *std.Io.Writer, f: Field) !void {
        if (f.ftype == .secret or std.mem.eql(u8, f.name, "user.password")) {
            const set = if (std.mem.eql(u8, f.name, "user.password"))
                w.cfg.users.len > 0 and w.cfg.users[0].password_hash != null
            else
                w.secretIsSet(f.name);
            try out.writeAll(if (set) "●●●●●●" else "(unset)");
            return;
        }
        // reuse the JSON emitter, then unwrap strings
        var aw: std.Io.Writer.Allocating = .init(w.alloc);
        defer aw.deinit();
        try w.emitValue(&aw.writer, f);
        const s = aw.written();
        const unquoted = if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s[1 .. s.len - 1] else s;
        if (unquoted.len == 0 or std.mem.eql(u8, unquoted, "null")) {
            try out.writeAll("(unset)");
        } else {
            try out.writeAll(unquoted);
        }
    }

    fn flowLen(w: *const Wizard) usize {
        var buf: [pages.len]usize = undefined;
        return w.flowOrder(&buf).len;
    }
    fn flowIndex(w: *const Wizard) usize {
        var buf: [pages.len]usize = undefined;
        const order = w.flowOrder(&buf);
        for (order, 0..) |pi, i| if (pi == w.page_idx) return i;
        return 0;
    }

    fn emitActions(w: *const Wizard, out: *std.Io.Writer) !void {
        const last = w.flowIndex() == w.flowLen() - 1;
        try out.writeAll("\"back\"");
        if (w.page_idx == 0) try out.writeAll(",\"quit\"");
        if (!last) {
            try out.writeAll(",\"next\"");
        } else {
            // review page
            try out.writeAll(",\"install\",\"export_answer\",\"plan\"");
        }
    }

    fn emitField(w: *Wizard, out: *std.Io.Writer, f: Field) !void {
        try out.writeAll("{\"name\":\"");
        jesc(out, f.name);
        try out.writeAll("\",\"type\":\"");
        jesc(out, @tagName(f.ftype));
        try out.writeAll("\",\"label\":\"");
        jesc(out, f.label);
        try out.writeAll("\"");
        if (f.help) |h| {
            try out.writeAll(",\"help\":\"");
            jesc(out, h);
            try out.writeAll("\"");
        }
        if (f.min_len) |m| try out.print(",\"min\":{}", .{m});
        if (f.confirm) try out.writeAll(",\"confirm\":true");
        // disk.device options are the detected disks — dynamic.
        const dev_opts = std.mem.eql(u8, f.name, "disk.device");
        if (f.options.len > 0 or dev_opts) {
            try out.writeAll(",\"options\":[");
            var first = true;
            if (dev_opts and w.env != null) {
                for (w.env.?.disks) |d| {
                    if (!first) try out.writeAll(",");
                    first = false;
                    try out.writeAll("{\"v\":\"");
                    jesc(out, d.path);
                    try out.writeAll("\",\"label\":\"");
                    jesc(out, d.name);
                    try out.print(" · {} GiB\"}}", .{d.size_bytes / (1 << 30)});
                }
            }
            for (f.options) |o| {
                if (o.visible) |vis| if (!vis(w)) continue;
                if (!first) try out.writeAll(",");
                first = false;
                try out.writeAll("{\"v\":\"");
                jesc(out, o.v);
                try out.writeAll("\",\"label\":\"");
                jesc(out, o.label);
                try out.writeAll("\"");
                if (o.help) |h| {
                    try out.writeAll(",\"help\":\"");
                    jesc(out, h);
                    try out.writeAll("\"");
                }
                try out.writeAll("}");
            }
            try out.writeAll("]");
        }
        try out.writeAll(",\"value\":");
        try w.emitValue(out, f);
        try out.writeAll(",\"default\":");
        try w.emitDefault(out, f);
        try out.writeAll("}");
    }

    fn emitValue(w: *Wizard, out: *std.Io.Writer, f: Field) !void {
        // secrets never leave the engine — masked per protocol.md
        if (f.ftype == .secret) {
            const set = w.secretIsSet(f.name);
            try out.print("{{\"secret\":true,\"is_set\":{}}}", .{set});
            return;
        }
        if (std.mem.eql(u8, f.name, "flow.mode")) {
            try jstr(out, @tagName(w.flow));
            return;
        }
        if (std.mem.eql(u8, f.name, "root.mode")) {
            try jstr(out, if (w.cfg.root.lock_root) "locked" else "password");
            return;
        }
        if (std.mem.eql(u8, f.name, "user.name")) {
            try jstr(out, if (w.cfg.users.len > 0) w.cfg.users[0].name else "");
            return;
        }
        if (std.mem.eql(u8, f.name, "user.password")) {
            try out.print("{{\"secret\":true,\"is_set\":{}}}", .{w.cfg.users.len > 0 and w.cfg.users[0].password_hash != null});
            return;
        }
        if (std.mem.eql(u8, f.name, "answer_file")) {
            try out.writeAll("null");
            return;
        }
        if (std.mem.eql(u8, f.name, "boot_mode")) {
            try jstr(out, if (w.cfg.boot_mode_explicit) @tagName(w.cfg.boot_mode) else "auto");
            return;
        }
        try emitCfgValue(w, out, f.name, f.ftype);
    }

    fn emitDefault(w: *Wizard, out: *std.Io.Writer, f: Field) !void {
        _ = w;
        _ = f;
        try out.writeAll("null");
    }

    /// Fold a detected env into wizard state — the same defaults the
    /// CLI fills on run/plan (arch, boot_mode, BIOS scheme flip).
    pub fn applyEnv(w: *Wizard, env: Env) void {
        w.env = env;
        w.detected_boot = env.boot_mode;
        if (w.cfg.arch == .detect) w.cfg.arch = env.arch;
        if (!w.cfg.boot_mode_explicit)
            w.cfg.boot_mode = env.boot_mode;
        // an unpinned scheme tracks the EFFECTIVE firmware either way —
        // an explicit boot_mode pick must flip an implicit scheme too,
        // and a bios→uefi re-detect must un-apply the bios scheme.
        if (!w.cfg.disk.scheme_explicit)
            w.cfg.disk.scheme = switch (w.cfg.boot_mode) {
                .bios => .@"bios-boot-swap-root",
                .uefi => .@"efi-swap-root",
            };
        // BIOS Express pins btrfs+limine, and limine can't read btrfs —
        // the /boot partition toggle is expert-only, so Express must set
        // it itself or the disk page can never validate on BIOS.
        if (w.flow == .express and w.cfg.boot_mode == .bios)
            w.cfg.disk.boot_part = true;
    }

    /// Merge the attached preset's `[defaults]` under cfg and pin any
    /// `[locks]` paths to their defaults. Call after `preset` is set.
    pub fn applyPresetDefaults(w: *Wizard) !void {
        const p = w.preset orelse return;
        var doc = toml.parse(w.alloc, "", null) catch return error.OutOfMemory;
        try preset_mod.mergeDefaults(p, &doc);
        const fresh = config.decode(w.alloc, doc) catch return error.BadConfig;
        w.cfg = fresh;
        w.applyExpressDefaults();
        // locks fix their preset default — over express choices too.
        const defs = presetDefaults(p) orelse return;
        for (p.locks) |path| {
            if (preset_mod.lookup(defs, path)) |tv| {
                if (tomlToJson(w.alloc, tv)) |jv| setPath(w, path, jv) catch {};
            }
        }
    }

    /// Does the preset lock this field? A locked field only accepts the
    /// preset's own default — mirrors checkLocks' doc-level semantics.
    fn presetLocks(w: *Wizard, name: []const u8, v: std.json.Value) WizardError!void {
        const p = w.preset orelse return;
        for (p.locks) |lp| {
            if (!std.mem.eql(u8, lp, name)) continue;
            const defs = presetDefaults(p) orelse return;
            const want = preset_mod.lookup(defs, name) orelse return; // no default → can't pin
            const jv = jsonToToml(w.alloc, v) orelse return error.Locked;
            if (!preset_mod.valueEq(jv, want)) return error.Locked;
            return;
        }
    }

    fn secretIsSet(w: *Wizard, name: []const u8) bool {
        if (std.mem.eql(u8, name, "disk.luks_passphrase")) return w.cfg.disk.luks_passphrase != null;
        if (std.mem.eql(u8, name, "root.password")) return w.cfg.root.password_hash != null;
        if (std.mem.eql(u8, name, "user.password")) return w.cfg.users.len > 0 and w.cfg.users[0].password_hash != null;
        return false;
    }

    /// `set` op: apply a JSON value to the field. Secrets hash on input
    /// — plaintext never survives in cfg beyond the luks passphrase,
    /// which is protocol-defined as in-memory only.
    pub fn setField(w: *Wizard, name: []const u8, v: std.json.Value) WizardError!void {
        try w.presetLocks(name, v);
        if (std.mem.eql(u8, name, "flow.mode")) {
            const s = try strOf(v);
            w.flow = std.meta.stringToEnum(Flow, s) orelse return error.BadValue;
            w.applyExpressDefaults();
            return;
        }
        if (std.mem.eql(u8, name, "answer_file")) {
            const s = try strOf(v);
            return w.loadAnswerFile(s);
        }
        if (std.mem.eql(u8, name, "disk.luks_passphrase")) {
            const s = try dstr(w, v);
            if (s.len > 0 and s.len < 8) return error.BadValue;
            w.cfg.disk.luks_passphrase = if (s.len == 0) null else s;
            return;
        }
        if (std.mem.eql(u8, name, "root.password")) {
            const s = try strOf(v);
            if (s.len < 8) return error.BadValue;
            w.cfg.root.password_hash = try w.hashPassword(s);
            w.cfg.root.lock_root = false;
            return;
        }
        if (std.mem.eql(u8, name, "user.name")) {
            const s = try dstr(w, v);
            if (s.len == 0) return error.BadValue;
            // Rename users[0] in place — a fresh 1-element slice would
            // drop extra users and the first user's keys/shell/groups.
            if (w.cfg.users.len == 0) {
                const items = try w.alloc.alloc(config.User, 1);
                items[0] = .{ .name = s, .groups = @constCast(&.{"wheel"}), .shell = "/bin/bash" };
                w.cfg.users = items;
            } else {
                const items = try w.alloc.alloc(config.User, w.cfg.users.len);
                @memcpy(items, w.cfg.users);
                items[0].name = s;
                w.cfg.users = items;
            }
            return;
        }
        if (std.mem.eql(u8, name, "user.password")) {
            const s = try strOf(v);
            if (s.len < 8) return error.BadValue;
            const h = try w.hashPassword(s);
            if (w.cfg.users.len == 0) {
                const items = try w.alloc.alloc(config.User, 1);
                items[0] = .{ .name = "user", .groups = @constCast(&.{"wheel"}), .shell = "/bin/bash", .password_hash = h };
                w.cfg.users = items;
            } else {
                const items = try w.alloc.alloc(config.User, w.cfg.users.len);
                @memcpy(items, w.cfg.users);
                items[0].password_hash = h;
                w.cfg.users = items;
            }
            return;
        }
        if (std.mem.eql(u8, name, "root.mode")) {
            const s = try strOf(v);
            if (std.mem.eql(u8, s, "locked")) {
                w.cfg.root.lock_root = true;
            } else if (std.mem.eql(u8, s, "password")) {
                w.cfg.root.lock_root = false;
            } else return error.BadValue;
            return;
        }
        if (std.mem.eql(u8, name, "boot_mode")) {
            // "auto" clears the explicit pick and re-tracks detection.
            const s = try strOf(v);
            if (std.mem.eql(u8, s, "auto")) {
                w.cfg.boot_mode_explicit = false;
                w.cfg.boot_mode = if (w.env) |env| env.boot_mode else (w.detected_boot orelse .uefi);
            } else {
                w.cfg.boot_mode = std.meta.stringToEnum(config.BootMode, s) orelse return error.BadValue;
                w.cfg.boot_mode_explicit = true;
            }
            // the effective mode drives an implicit scheme (and the
            // express /boot partition) — same rules as applyEnv.
            if (!w.cfg.disk.scheme_explicit)
                w.cfg.disk.scheme = switch (w.cfg.boot_mode) {
                    .bios => .@"bios-boot-swap-root",
                    .uefi => .@"efi-swap-root",
                };
            if (w.flow == .express and w.cfg.boot_mode == .bios)
                w.cfg.disk.boot_part = true;
            return;
        }
        if (std.mem.eql(u8, name, "users")) {
            return w.setUsers(v);
        }
        if (std.mem.eql(u8, name, "use.global")) {
            const t = switch (v) {
                .object => |o| tableFromObj(w.alloc, o) catch return error.OutOfMemory,
                else => return error.BadType,
            };
            w.cfg.use.global = t;
            return;
        }
        if (std.mem.eql(u8, name, "use.pkg")) {
            const t = switch (v) {
                .object => |o| tableFromObj(w.alloc, o) catch return error.OutOfMemory,
                else => return error.BadType,
            };
            w.cfg.use.pkg = t;
            return;
        }
        if (std.mem.eql(u8, name, "packages.sets")) {
            // decode-equivalent semantics: an explicit list — even an
            // empty one — overrides the preset's default sets.
            const arr = switch (v) {
                .array => |a| a,
                else => return error.BadType,
            };
            var items: std.ArrayList([]const u8) = .empty;
            for (arr.items) |it| try items.append(w.alloc, try dstr(w, it));
            w.cfg.packages.sets = items.items;
            w.cfg.packages.sets_explicit = true;
            return;
        }
        if (std.mem.eql(u8, name, "makeconf.cflags_custom")) {
            // dupe onto w.alloc — the request arena dies after the reply
            w.cfg.makeconf.cflags = .{ .custom = try dstr(w, v) };
            return;
        }
        return setPath(w, name, v);
    }

    /// Hash a plaintext password via openssl — stdin only, never argv.
    fn hashPassword(w: *Wizard, pw: []const u8) WizardError![]const u8 {
        var child = std.process.spawn(w.io, .{
            .argv = &.{ "openssl", "passwd", "-6", "-stdin" },
            .stdin = .pipe,
            .stdout = .pipe,
        }) catch return error.HashFailed;
        // Every post-spawn failure must reap: a headless session hashes
        // per attempt, and leaked children/fds accumulate.
        errdefer {
            if (child.stdin) |f| f.close(w.io);
            if (child.stdout) |f| f.close(w.io);
            _ = child.wait(w.io) catch {};
        }
        var wbuf: [4096]u8 = undefined;
        var fw = child.stdin.?.writer(w.io, &wbuf);
        fw.interface.writeAll(pw) catch return error.HashFailed;
        fw.interface.writeAll("\n") catch return error.HashFailed;
        fw.interface.flush() catch return error.HashFailed;
        child.stdin.?.close(w.io);
        child.stdin = null;
        var rbuf: [4096]u8 = undefined;
        var fr = child.stdout.?.reader(w.io, &rbuf);
        var out: std.Io.Writer.Allocating = .init(w.alloc);
        const n = fr.interface.streamRemaining(&out.writer) catch return error.HashFailed;
        _ = n;
        child.stdout.?.close(w.io);
        child.stdout = null;
        const term = child.wait(w.io) catch return error.HashFailed;
        switch (term) {
            .exited => |code| if (code != 0) return error.HashFailed,
            else => return error.HashFailed,
        }
        return std.mem.trim(u8, out.written(), " \t\r\n");
    }

    fn setUsers(w: *Wizard, v: std.json.Value) WizardError!void {
        const arr = switch (v) {
            .array => |a| a,
            else => return error.BadType,
        };
        var users: std.ArrayList(config.User) = .empty;
        for (arr.items) |item| {
            const o = switch (item) {
                .object => |o| o,
                else => return error.BadType,
            };
            var u = config.User{};
            if (o.get("name")) |nv| u.name = try dstr(w, nv);
            if (o.get("shell")) |sv| u.shell = try dstr(w, sv);
            if (o.get("groups")) |gv| {
                const ga = switch (gv) {
                    .array => |a| a,
                    else => return error.BadType,
                };
                var groups: std.ArrayList([]const u8) = .empty;
                for (ga.items) |g| try groups.append(w.alloc, try dstr(w, g));
                u.groups = groups.items;
            }
            if (o.get("password")) |pv| {
                const pw = try strOf(pv);
                if (pw.len > 0) u.password_hash = try w.hashPassword(pw);
            }
            if (o.get("password_hash")) |hv| u.password_hash = try dstr(w, hv);
            if (o.get("ssh_authorized_keys")) |kv| {
                const ka = switch (kv) {
                    .array => |a| a,
                    else => return error.BadType,
                };
                var keys: std.ArrayList([]const u8) = .empty;
                for (ka.items) |k| try keys.append(w.alloc, try dstr(w, k));
                u.ssh_authorized_keys = keys.items;
            }
            // An edit naming an existing account without credentials
            // must not erase them — the wire/text form can't always
            // carry the hash or keys.
            for (w.cfg.users) |old| {
                if (u.name.len > 0 and std.mem.eql(u8, old.name, u.name)) {
                    if (u.password_hash == null) u.password_hash = old.password_hash;
                    if (u.ssh_authorized_keys.len == 0) u.ssh_authorized_keys = old.ssh_authorized_keys;
                    break;
                }
            }
            try users.append(w.alloc, u);
        }
        w.cfg.users = users.items;
    }

    /// Load an answer file: parse TOML, decode into cfg, jump to review.
    fn loadAnswerFile(w: *Wizard, path: []const u8) WizardError!void {
        const real = try confinedRead(w, path);
        const text = std.Io.Dir.cwd().readFileAlloc(w.io, real, w.alloc, .limited(4 << 20)) catch
            return error.ReadFailed;
        var doc = toml.parse(w.alloc, text, null) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidToml,
        };
        // Preset locks gate the file exactly like a user document — a
        // locked path may only carry the preset's default value.
        if (w.preset) |p| {
            const lerrs = preset_mod.checkLocks(w.alloc, p, &doc) catch return error.OutOfMemory;
            if (lerrs.len > 0) return error.Locked;
        }
        // The file replaces the config wholesale — including secrets.
        // Keeping a previous session's passphrase/hash across a load
        // would silently stamp it onto an unrelated install.
        w.cfg = config.decode(w.alloc, doc) catch return error.BadConfig;
        // decode() already set boot_mode_explicit when the doc carries a
        // root-level boot_mode. Scheme pins the same way, plus the CLI's
        // preserve-scheme promotion (main.zig): an answer file that asks
        // for alongside/manual must keep it when detection re-syncs.
        w.cfg.disk.scheme_explicit = docHas(&doc, "disk", "scheme") or
            w.cfg.disk.scheme == .alongside or w.cfg.disk.scheme == .manual;
        // Re-apply the probed env: implicit boot_mode/scheme follow the
        // live firmware exactly like they did before the file loaded.
        if (w.env) |e| w.applyEnv(e);
        // jump to review
        for (pages, 0..) |pg, i| {
            if (std.mem.eql(u8, pg.id, "review")) {
                w.page_idx = i;
                break;
            }
        }
    }

    /// `next` — validate the current page, advance within the flow.
    /// Returns error.BadValue when the page has errors (caller emits
    /// the validate delta).
    pub fn next(w: *Wizard, alloc: Allocator, nvidia: ?config.NvidiaTier) !bool {
        const errs = try w.pageErrors(alloc, nvidia, w.currentPage());
        if (errs.len > 0) return false;
        var buf: [pages.len]usize = undefined;
        const order = w.flowOrder(&buf);
        const i = w.flowIndex();
        if (i + 1 < order.len) {
            w.page_idx = order[i + 1];
            return true;
        }
        return true; // already at review
    }

    pub fn back(w: *Wizard) void {
        var buf: [pages.len]usize = undefined;
        const order = w.flowOrder(&buf);
        const i = w.flowIndex();
        if (i > 0) w.page_idx = order[i - 1];
    }

    /// Errors whose field prefix belongs to `pg` — the whole-config
    /// validator stays the single source of truth.
    pub fn pageErrors(w: *Wizard, alloc: Allocator, nvidia: ?config.NvidiaTier, pg: *const Page) ![][]const u8 {
        const all = try config.validate(alloc, &w.cfg, nvidia);
        var out: std.ArrayList([]const u8) = .empty;
        for (all) |e| {
            for (pg.prefixes) |p| {
                if (std.mem.indexOf(u8, e, p) != null) {
                    try out.append(alloc, e);
                    break;
                }
            }
        }
        // wizard-side requirements the config can't express
        if (std.mem.eql(u8, pg.id, "disk")) {
            // length/presence rules live in config.validate — imported
            // answer files get the same check at plan/install.
        }
        if (std.mem.eql(u8, pg.id, "accounts")) {
            var login = false;
            if (w.cfg.root.password_hash != null and !w.cfg.root.lock_root) login = true;
            for (w.cfg.users) |u| {
                if (u.password_hash != null) login = true;
                if (w.cfg.services.sshd and u.ssh_authorized_keys.len > 0) login = true;
            }
            if (!login) try out.append(alloc, "no usable login path — set a password or an ssh key");
        }
        return out.items;
    }

    /// Serialise cfg to JSON for `get_config` — secrets masked.
    pub fn emitConfigJson(w: *Wizard, out: *std.Io.Writer, req: ?u64) !void {
        try out.writeAll("{\"ev\":\"config\",");
        if (req) |r| try out.print("\"req\":{},", .{r});
        try out.writeAll("\"config\":{");
        try out.writeAll("\"arch\":\"");
        try out.writeAll(@tagName(w.cfg.arch));
        try out.writeAll("\",\"boot_mode\":\"");
        try out.writeAll(@tagName(w.cfg.boot_mode));
        try out.writeAll("\",\"disk\":{");
        try fieldStr(out, "device", w.cfg.disk.device);
        try out.writeAll(",");
        try fieldBool(out, "wipe", w.cfg.disk.wipe);
        try out.writeAll(",");
        try fieldStr(out, "scheme", @tagName(w.cfg.disk.scheme));
        try out.writeAll(",");
        try fieldStr(out, "root_fs", @tagName(w.cfg.disk.root_fs));
        try out.writeAll(",");
        try fieldStr(out, "swap", @tagName(w.cfg.disk.swap));
        try out.writeAll(",");
        try fieldInt(out, "swap_mib", w.cfg.disk.swap_mib);
        try out.writeAll(",");
        try fieldInt(out, "esp_mib", w.cfg.disk.esp_mib);
        try out.writeAll(",");
        try fieldBool(out, "boot_part", w.cfg.disk.boot_part);
        try out.writeAll(",");
        try fieldBool(out, "luks", w.cfg.disk.luks);
        try out.writeAll(",\"luks_passphrase\":{\"secret\":true,\"is_set\":");
        try out.writeAll(if (w.cfg.disk.luks_passphrase != null) "true" else "false");
        try out.writeAll("},");
        try fieldBool(out, "lvm", w.cfg.disk.lvm);
        try out.writeAll(",");
        try fieldBool(out, "home_part", w.cfg.disk.home_part);
        try out.writeAll(",");
        try fieldStr(out, "space_src", @tagName(w.cfg.disk.space_src));
        try out.writeAll(",");
        try fieldStr(out, "shrink_part", w.cfg.disk.shrink_part);
        try out.writeAll(",");
        try fieldInt(out, "shrink_mib", w.cfg.disk.shrink_mib);
        try out.writeAll("},\"stage3\":{");
        try fieldStr(out, "libc", @tagName(w.cfg.stage3.libc));
        try out.writeAll(",");
        try fieldStr(out, "toolchain", @tagName(w.cfg.stage3.toolchain));
        try out.writeAll(",");
        try fieldStr(out, "variant", w.cfg.stage3.variant);
        try out.writeAll(",");
        try fieldStr(out, "mirror", w.cfg.stage3.mirror);
        try out.writeAll("},\"system\":{");
        try fieldStr(out, "init", @tagName(w.cfg.system.init));
        try out.writeAll(",");
        try fieldStr(out, "hostname", w.cfg.system.hostname);
        try out.writeAll(",");
        try fieldStr(out, "kernel", @tagName(w.cfg.system.kernel));
        try out.writeAll(",");
        try fieldStr(out, "bootloader", @tagName(w.cfg.system.bootloader));
        try out.writeAll(",");
        try fieldStr(out, "initramfs", @tagName(w.cfg.system.initramfs));
        try out.writeAll(",");
        try fieldBool(out, "uki", w.cfg.system.uki);
        try out.writeAll(",");
        try fieldBool(out, "binhost", w.cfg.system.binhost);
        try out.writeAll(",");
        try fieldStr(out, "privilege", @tagName(w.cfg.system.privilege));
        try out.writeAll(",");
        try fieldStr(out, "timezone", w.cfg.system.timezone);
        try out.writeAll(",");
        try fieldStr(out, "locale", w.cfg.system.locale);
        try out.writeAll(",");
        try fieldStr(out, "keymap", w.cfg.system.keymap);
        try out.writeAll(",");
        try fieldInt(out, "keep_kernels", w.cfg.system.keep_kernels);
        try out.writeAll(",");
        try fieldStr(out, "snapshots", @tagName(w.cfg.system.snapshots));
        try out.writeAll(",\"locales\":[");
        for (w.cfg.system.locales, 0..) |l, i| {
            if (i > 0) try out.writeAll(",");
            try jstr(out, l);
        }
        try out.writeAll("]},\"network\":{");
        try fieldStr(out, "manager", @tagName(w.cfg.network.manager));
        try out.writeAll(",");
        try fieldBool(out, "wifi", w.cfg.network.wifi);
        try out.writeAll("},\"security\":{");
        try fieldStr(out, "secure_boot", @tagName(w.cfg.security.secure_boot));
        try out.writeAll(",");
        try fieldStr(out, "hardening", @tagName(w.cfg.security.hardening));
        try out.writeAll(",");
        try fieldBool(out, "selinux", w.cfg.security.selinux);
        try out.writeAll("},\"users\":[");
        for (w.cfg.users, 0..) |u, i| {
            if (i > 0) try out.writeAll(",");
            try out.writeAll("{\"name\":\"");
            jesc(out, u.name);
            try out.writeAll("\",\"shell\":\"");
            jesc(out, u.shell);
            try out.writeAll("\",\"groups\":[");
            for (u.groups, 0..) |g, gi| {
                if (gi > 0) try out.writeAll(",");
                try out.writeAll("\"");
                jesc(out, g);
                try out.writeAll("\"");
            }
            try out.writeAll("],\"ssh_authorized_keys\":[");
            for (u.ssh_authorized_keys, 0..) |k, ki| {
                if (ki > 0) try out.writeAll(",");
                try out.writeAll("\"");
                jesc(out, k);
                try out.writeAll("\"");
            }
            try out.writeAll("],\"password_hash\":{\"secret\":true,\"is_set\":");
            try out.writeAll(if (u.password_hash != null) "true" else "false");
            try out.writeAll("}}");
        }
        try out.writeAll("],\"gpu\":{");
        try fieldStr(out, "driver", @tagName(w.cfg.gpu.driver));
        try out.writeAll("},\"makeconf\":{");
        switch (w.cfg.makeconf.cflags) {
            .safe => try out.writeAll("\"cflags\":\"safe\""),
            .native => try out.writeAll("\"cflags\":\"native\""),
            .custom => |c| {
                try out.writeAll("\"cflags\":\"custom\",\"cflags_custom\":");
                try jstr(out, c);
            },
        }
        try out.writeAll(",");
        try fieldInt(out, "jobs", w.cfg.makeconf.jobs);
        try out.writeAll(",");
        try fieldInt(out, "mem_cap_gib", w.cfg.makeconf.mem_cap_gib);
        try out.writeAll(",");
        try fieldStr(out, "video_cards", w.cfg.makeconf.video_cards);
        try out.writeAll(",");
        try fieldStr(out, "accept_license", w.cfg.makeconf.accept_license);
        try out.writeAll(",");
        try fieldStr(out, "mirrors", w.cfg.makeconf.mirrors);
        try out.writeAll("},\"extra\":{");
        try fieldBool(out, "update_world", w.cfg.extra.update_world);
        try out.writeAll("},\"services\":{");
        try fieldBool(out, "sshd", w.cfg.services.sshd);
        try out.writeAll(",");
        try fieldBool(out, "logger", w.cfg.services.logger);
        try out.writeAll(",");
        try fieldBool(out, "cron", w.cfg.services.cron);
        try out.writeAll(",");
        try fieldBool(out, "ntp", w.cfg.services.ntp);
        try out.writeAll("},\"packages\":{");
        try fieldBool(out, "sets_explicit", w.cfg.packages.sets_explicit);
        try out.writeAll(",\"sets\":[");
        for (w.cfg.packages.sets, 0..) |s, i| {
            if (i > 0) try out.writeAll(",");
            try out.writeAll("\"");
            jesc(out, s);
            try out.writeAll("\"");
        }
        try out.writeAll("],\"atoms\":[");
        for (w.cfg.packages.atoms, 0..) |a, i| {
            if (i > 0) try out.writeAll(",");
            try out.writeAll("\"");
            jesc(out, a);
            try out.writeAll("\"");
        }
        try out.writeAll("]},\"use\":{\"global\":{");
        var first = true;
        var git = w.cfg.use.global.iterator();
        while (git.next()) |kv| {
            if (!first) try out.writeAll(",");
            first = false;
            try out.writeAll("\"");
            jesc(out, kv.key_ptr.*);
            try out.writeAll("\":");
            try out.writeAll(if (kv.value_ptr.* == .boolean and kv.value_ptr.boolean) "true" else "false");
        }
        try out.writeAll("},\"pkg\":{");
        first = true;
        var pit = w.cfg.use.pkg.iterator();
        while (pit.next()) |kv| {
            if (kv.value_ptr.* != .string) continue;
            if (!first) try out.writeAll(",");
            first = false;
            try out.writeAll("\"");
            jesc(out, kv.key_ptr.*);
            try out.writeAll("\":\"");
            jesc(out, kv.value_ptr.string);
            try out.writeAll("\"");
        }
        try out.writeAll("}},\"root\":{");
        try out.writeAll("\"password_hash\":{\"secret\":true,\"is_set\":");
        try out.writeAll(if (w.cfg.root.password_hash != null) "true" else "false");
        try out.writeAll("},");
        try fieldBool(out, "lock_root", w.cfg.root.lock_root);
        try out.writeAll("}}}\n");
    }

    /// `export_answer` — write the current config as a reusable TOML
    /// answer file (0600; hashes only — plaintext is never written).
    pub fn exportAnswer(w: *Wizard, path: []const u8) !void {
        var aw: std.Io.Writer.Allocating = .init(w.alloc);
        defer aw.deinit();
        const o = &aw.writer;
        try o.writeAll("# gentoo-installer answer file\n");
        try o.print("arch = \"{s}\"\nboot_mode = \"{s}\"\n", .{ @tagName(w.cfg.arch), @tagName(w.cfg.boot_mode) });
        try o.print("[disk]\nscheme = \"{s}\"\nroot_fs = \"{s}\"\nswap = \"{s}\"\nswap_mib = {}\nesp_mib = {}\nboot_part = {}\nluks = {}\nlvm = {}\nwipe = {}\nhome_part = {}\nspace_src = \"{s}\"\nshrink_mib = {}\ndevice = ", .{
            @tagName(w.cfg.disk.scheme), @tagName(w.cfg.disk.root_fs),   @tagName(w.cfg.disk.swap),
            w.cfg.disk.swap_mib,         w.cfg.disk.esp_mib,             w.cfg.disk.boot_part,
            w.cfg.disk.luks,             w.cfg.disk.lvm,                 w.cfg.disk.wipe,
            w.cfg.disk.home_part,        @tagName(w.cfg.disk.space_src), w.cfg.disk.shrink_mib,
        });
        try tomlStr(o, w.cfg.disk.device);
        try o.writeAll("\nshrink_part = ");
        try tomlStr(o, w.cfg.disk.shrink_part);
        try o.writeAll("\n");
        if (w.cfg.disk.luks)
            try o.writeAll("# luks_passphrase = \"…\"  # plaintext is never exported — set before exec\n");
        try o.print("[stage3]\nlibc = \"{s}\"\ntoolchain = \"{s}\"\nvariant = ", .{ @tagName(w.cfg.stage3.libc), @tagName(w.cfg.stage3.toolchain) });
        try tomlStr(o, w.cfg.stage3.variant);
        try o.writeAll("\nmirror = ");
        try tomlStr(o, w.cfg.stage3.mirror);
        try o.writeAll("\n");
        try o.print("[system]\ninit = \"{s}\"\nkernel = \"{s}\"\nbootloader = \"{s}\"\ninitramfs = \"{s}\"\nuki = {}\nbinhost = {}\nprivilege = \"{s}\"\nkeep_kernels = {}\nsnapshots = \"{s}\"\n", .{
            @tagName(w.cfg.system.init),      @tagName(w.cfg.system.kernel), @tagName(w.cfg.system.bootloader),
            @tagName(w.cfg.system.initramfs), w.cfg.system.uki,              w.cfg.system.binhost,
            @tagName(w.cfg.system.privilege), w.cfg.system.keep_kernels,     @tagName(w.cfg.system.snapshots),
        });
        try o.writeAll("hostname = ");
        try tomlStr(o, w.cfg.system.hostname);
        try o.writeAll("\ntimezone = ");
        try tomlStr(o, w.cfg.system.timezone);
        try o.writeAll("\nlocale = ");
        try tomlStr(o, w.cfg.system.locale);
        try o.writeAll("\nkeymap = ");
        try tomlStr(o, w.cfg.system.keymap);
        try o.writeAll("\nlocales = [");
        for (w.cfg.system.locales, 0..) |l, i| {
            if (i > 0) try o.writeAll(", ");
            try tomlStr(o, l);
        }
        try o.writeAll("]\n");
        try o.print("[network]\nmanager = \"{s}\"\nwifi = {}\n", .{ @tagName(w.cfg.network.manager), w.cfg.network.wifi });
        try o.print("[services]\nsshd = {}\nlogger = {}\ncron = {}\nntp = {}\n", .{ w.cfg.services.sshd, w.cfg.services.logger, w.cfg.services.cron, w.cfg.services.ntp });
        try o.print("[security]\nsecure_boot = \"{s}\"\nhardening = \"{s}\"\nselinux = {}\n", .{ @tagName(w.cfg.security.secure_boot), @tagName(w.cfg.security.hardening), w.cfg.security.selinux });
        try o.print("[gpu]\ndriver = \"{s}\"\n", .{@tagName(w.cfg.gpu.driver)});
        try o.writeAll("[makeconf]\ncflags = ");
        switch (w.cfg.makeconf.cflags) {
            .safe => try o.writeAll("\"safe\""),
            .native => try o.writeAll("\"native\""),
            .custom => |c| try tomlStr(o, c),
        }
        try o.print("\njobs = {}\nmem_cap_gib = {}\n", .{ w.cfg.makeconf.jobs, w.cfg.makeconf.mem_cap_gib });
        try o.writeAll("video_cards = ");
        try tomlStr(o, w.cfg.makeconf.video_cards);
        try o.writeAll("\naccept_license = ");
        try tomlStr(o, w.cfg.makeconf.accept_license);
        try o.writeAll("\nmirrors = ");
        try tomlStr(o, w.cfg.makeconf.mirrors);
        try o.writeAll("\n[packages]\n");
        if (w.cfg.packages.sets_explicit) {
            try o.writeAll("sets = [");
            for (w.cfg.packages.sets, 0..) |s, i| {
                if (i > 0) try o.writeAll(", ");
                try tomlStr(o, s);
            }
            try o.writeAll("]\n");
        } else {
            // omitted = the preset's default sets — serializing the
            // placeholder list would pin it on reload.
            try o.writeAll("# sets = […]  # unset → preset default applies\n");
        }
        try o.writeAll("atoms = [");
        for (w.cfg.packages.atoms, 0..) |a, i| {
            if (i > 0) try o.writeAll(", ");
            try tomlStr(o, a);
        }
        try o.writeAll("]\n");
        var it = w.cfg.use.global.iterator();
        if (w.cfg.use.global.count() > 0) {
            try o.writeAll("[use.global]\n");
            while (it.next()) |kv| {
                try o.writeAll("\"");
                try tomlStrInner(o, kv.key_ptr.*);
                try o.print("\" = {}\n", .{kv.value_ptr.* == .boolean and kv.value_ptr.boolean});
            }
        }
        if (w.cfg.use.pkg.count() > 0) {
            var pit = w.cfg.use.pkg.iterator();
            try o.writeAll("[use.pkg]\n");
            while (pit.next()) |kv| {
                if (kv.value_ptr.* != .string) continue;
                try o.writeAll("\"");
                try tomlStrInner(o, kv.key_ptr.*);
                try o.writeAll("\" = ");
                try tomlStr(o, kv.value_ptr.string);
                try o.writeAll("\n");
            }
        }
        for (w.cfg.users) |u| {
            try o.writeAll("[[users]]\nname = ");
            try tomlStr(o, u.name);
            try o.writeAll("\nshell = ");
            try tomlStr(o, u.shell);
            try o.writeAll("\n");
            if (u.password_hash) |h| {
                try o.writeAll("password_hash = ");
                try tomlStr(o, h);
                try o.writeAll("\n");
            }
            if (u.groups.len > 0) {
                try o.writeAll("groups = [");
                for (u.groups, 0..) |g, i| {
                    if (i > 0) try o.writeAll(", ");
                    try tomlStr(o, g);
                }
                try o.writeAll("]\n");
            }
            if (u.ssh_authorized_keys.len > 0) {
                try o.writeAll("ssh_authorized_keys = [");
                for (u.ssh_authorized_keys, 0..) |k, i| {
                    if (i > 0) try o.writeAll(", ");
                    try tomlStr(o, k);
                }
                try o.writeAll("]\n");
            }
        }
        try o.writeAll("[root]\nlock_root = ");
        try o.print("{}\n", .{w.cfg.root.lock_root});
        if (w.cfg.root.password_hash) |h| {
            try o.writeAll("password_hash = ");
            try tomlStr(o, h);
            try o.writeAll("\n");
        }
        try o.print("[extra]\nupdate_world = {}\n", .{w.cfg.extra.update_world});
        const real = try confinedWrite(w, path);
        std.Io.Dir.cwd().writeFile(w.io, .{
            .sub_path = real,
            .data = aw.written(),
            .flags = .{ .truncate = true, .permissions = .fromMode(0o600) },
        }) catch return error.WriteFailed;
    }

    /// Resolve cfg.packages.sets through the attached preset (or the
    /// stock gentoo table when none) — same source `run`/`plan` use.
    /// errs are surfaced verbatim; empty errs means resolution succeeded.
    pub fn pkgSets(w: *Wizard, alloc: Allocator) !struct { sets: plan.Sets, errs: [][]const u8 } {
        const rs = try preset_mod.resolveSets(alloc, w.preset, if (w.cfg.packages.sets_explicit) w.cfg.packages.sets else null);
        return .{ .sets = .{ .atoms = rs.resolved.atoms, .repos = rs.resolved.repos }, .errs = rs.errs };
    }
};

// ---------- path get/set ----------

fn strOf(v: std.json.Value) WizardError![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.BadType,
    };
}

/// Stored strings must outlive the request arena — dupe onto w.alloc.
fn dstr(w: *Wizard, v: std.json.Value) WizardError![]const u8 {
    const s = try strOf(v);
    return w.alloc.dupe(u8, s) catch return error.OutOfMemory;
}

fn tableFromObj(alloc: Allocator, o: std.json.ObjectMap) !toml.Value.Table {
    var t: toml.Value.Table = .empty;
    var it = o.iterator();
    while (it.next()) |kv| {
        const tv: toml.Value = switch (kv.value_ptr.*) {
            .string => |s| .{ .string = try alloc.dupe(u8, s) },
            .integer => |i| .{ .integer = i },
            .bool => |b| .{ .boolean = b },
            else => continue,
        };
        try t.put(alloc, try alloc.dupe(u8, kv.key_ptr.*), tv);
    }
    return t;
}

fn docHas(doc: *toml.Document, sec: []const u8, key: []const u8) bool {
    const t = doc.root.get(sec) orelse return false;
    if (t != .table) return false;
    return t.table.get(key) != null;
}

/// Headless clients may only touch files inside the process working
/// directory — arbitrary absolute/relative escape paths are refused.
/// Both helpers return the resolved absolute path (cwd-owned).
fn underCwd(real_dir: []const u8, cwd: []const u8) bool {
    if (cwd.len <= 1) return true; // process rooted at / — nothing to escape
    return std.mem.eql(u8, real_dir, cwd) or
        (std.mem.startsWith(u8, real_dir, cwd) and real_dir.len > cwd.len and real_dir[cwd.len] == '/');
}

fn cwdReal(w: *Wizard) WizardError![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(w.io, ".", &buf) catch return error.BadValue;
    return w.alloc.dupe(u8, buf[0..n]) catch return error.OutOfMemory;
}

/// The `defaults` table of the attached preset.
fn presetDefaults(p: *const preset_mod.Preset) ?toml.Value.Table {
    const v = p.doc.root.get("defaults") orelse return null;
    return switch (v) {
        .table => |t| t,
        else => null,
    };
}

fn jsonToToml(alloc: Allocator, v: std.json.Value) ?toml.Value {
    return switch (v) {
        .string => |s| .{ .string = alloc.dupe(u8, s) catch return null },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .bool => |b| .{ .boolean = b },
        .array => |a| blk: {
            const items = alloc.alloc(toml.Value, a.items.len) catch return null;
            for (a.items, 0..) |it, i| items[i] = jsonToToml(alloc, it) orelse return null;
            break :blk .{ .array = items };
        },
        else => null,
    };
}

fn tomlToJson(alloc: Allocator, v: toml.Value) ?std.json.Value {
    return switch (v) {
        .string => |s| .{ .string = alloc.dupe(u8, s) catch return null },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .boolean => |b| .{ .bool = b },
        .array => |a| blk: {
            var arr = std.json.Array.init(alloc);
            for (a) |it| arr.append(tomlToJson(alloc, it) orelse return null) catch return null;
            break :blk .{ .array = arr };
        },
        else => null,
    };
}

/// TOML basic-string escape — every interpolated cfg string goes through
/// this so a stray quote/backslash/newline can't inject directives into
/// an exported answer file.
fn tomlStrInner(o: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"', '\\' => try o.print("\\{c}", .{ch}),
            '\n' => try o.writeAll("\\n"),
            '\r' => try o.writeAll("\\r"),
            '\t' => try o.writeAll("\\t"),
            else => if (ch < 0x20) try o.print("\\u{x:0>4}", .{ch}) else try o.writeByte(ch),
        }
    }
}
fn tomlStr(o: *std.Io.Writer, s: []const u8) !void {
    try o.writeAll("\"");
    try tomlStrInner(o, s);
    try o.writeAll("\"");
}

fn lexicalOk(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |c| if (std.mem.eql(u8, c, "..")) return false;
    return true;
}

/// For reading (answer files): the FILE's canonical path must sit
/// under cwd — refuses absolute paths, `..`, and symlinks pointing out.
fn confinedRead(w: *Wizard, path: []const u8) WizardError![]const u8 {
    if (!lexicalOk(path)) return error.PathEscape;
    const cwd = try cwdReal(w);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(w.io, path, &buf) catch return error.ReadFailed;
    const real = buf[0..n];
    if (!underCwd(real, cwd)) return error.PathEscape;
    return w.alloc.dupe(u8, real) catch return error.OutOfMemory;
}

/// For writing (export): the parent directory's canonical path must sit
/// under cwd; the file itself may not exist yet.
fn confinedWrite(w: *Wizard, path: []const u8) WizardError![]const u8 {
    if (!lexicalOk(path)) return error.PathEscape;
    const cwd = try cwdReal(w);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_part = std.fs.path.dirname(path) orelse ".";
    const n = std.Io.Dir.cwd().realPathFile(w.io, dir_part, &buf) catch return error.PathEscape;
    const real_dir = buf[0..n];
    if (!underCwd(real_dir, cwd)) return error.PathEscape;
    const base = std.fs.path.basename(path);
    if (base.len == 0) return error.BadValue;
    const real = std.fmt.allocPrint(w.alloc, "{s}/{s}", .{ real_dir, base }) catch return error.OutOfMemory;
    // The parent is safe, but the leaf itself may be an existing symlink
    // pointing outside — resolve it and refuse if it doesn't match.
    var fbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.cwd().realPathFile(w.io, real, &fbuf)) |flen| {
        if (!std.mem.eql(u8, fbuf[0..flen], real)) return error.PathEscape;
    } else |_| {}
    return real;
}

fn setPath(w: *Wizard, name: []const u8, v: std.json.Value) WizardError!void {
    const cfg = &w.cfg;
    // enum fields
    inline for (enum_fields) |ef| {
        if (std.mem.eql(u8, name, ef.name)) {
            const s = try strOf(v);
            try setEnum(cfg, ef, s);
            return;
        }
    }
    inline for (bool_fields) |bf| {
        if (std.mem.eql(u8, name, bf)) {
            cfg_bool.set(cfg, bf, switch (v) {
                .bool => |b| b,
                else => return error.BadType,
            });
            return;
        }
    }
    inline for (int_fields) |inf| {
        if (std.mem.eql(u8, name, inf)) {
            switch (v) {
                .integer => |i| {
                    if (i < 0 or i > std.math.maxInt(u32)) return error.BadValue;
                    cfg_int.set(cfg, inf, @intCast(i));
                },
                else => return error.BadType,
            }
            return;
        }
    }
    inline for (str_fields) |sf| {
        if (std.mem.eql(u8, name, sf)) {
            try cfg_str.set(cfg, w.alloc, sf, try strOf(v));
            return;
        }
    }
    inline for (list_fields) |lf| {
        if (std.mem.eql(u8, name, lf)) {
            const arr = switch (v) {
                .array => |a| a,
                else => return error.BadType,
            };
            var items: std.ArrayList([]const u8) = .empty;
            for (arr.items) |it| try items.append(w.alloc, try dstr(w, it));
            cfg_list.set(cfg, lf, items.items);
            return;
        }
    }
    return error.UnknownField;
}

const EField = struct { name: []const u8, tag: ETag };
const ETag = enum { scheme, root_fs, swap, libc, toolchain, init, kernel, bootloader, initramfs, privilege, snapshots, hardening, secure_boot, netmanager, space_src, gpu_driver, cflags };
const enum_fields = [_]EField{
    .{ .name = "disk.scheme", .tag = .scheme },
    .{ .name = "disk.root_fs", .tag = .root_fs },
    .{ .name = "disk.swap", .tag = .swap },
    .{ .name = "disk.space_src", .tag = .space_src },
    .{ .name = "stage3.libc", .tag = .libc },
    .{ .name = "stage3.toolchain", .tag = .toolchain },
    .{ .name = "system.init", .tag = .init },
    .{ .name = "system.kernel", .tag = .kernel },
    .{ .name = "system.bootloader", .tag = .bootloader },
    .{ .name = "system.initramfs", .tag = .initramfs },
    .{ .name = "system.privilege", .tag = .privilege },
    .{ .name = "system.snapshots", .tag = .snapshots },
    .{ .name = "security.hardening", .tag = .hardening },
    .{ .name = "security.secure_boot", .tag = .secure_boot },
    .{ .name = "network.manager", .tag = .netmanager },
    .{ .name = "gpu.driver", .tag = .gpu_driver },
    .{ .name = "makeconf.cflags", .tag = .cflags },
};
fn setEnum(cfg: *Config, ef: EField, s: []const u8) WizardError!void {
    switch (ef.tag) {
        .scheme => cfg.disk.scheme = std.meta.stringToEnum(config.Scheme, s) orelse return error.BadValue,
        .root_fs => cfg.disk.root_fs = std.meta.stringToEnum(config.RootFs, s) orelse return error.BadValue,
        .swap => cfg.disk.swap = std.meta.stringToEnum(config.Swap, s) orelse return error.BadValue,
        .space_src => cfg.disk.space_src = std.meta.stringToEnum(config.SpaceSrc, s) orelse return error.BadValue,
        .libc => cfg.stage3.libc = std.meta.stringToEnum(config.Libc, s) orelse return error.BadValue,
        .toolchain => cfg.stage3.toolchain = std.meta.stringToEnum(config.Toolchain, s) orelse return error.BadValue,
        .init => cfg.system.init = std.meta.stringToEnum(config.Init, s) orelse return error.BadValue,
        .kernel => cfg.system.kernel = std.meta.stringToEnum(config.Kernel, s) orelse return error.BadValue,
        .bootloader => cfg.system.bootloader = std.meta.stringToEnum(config.Bootloader, s) orelse return error.BadValue,
        .initramfs => cfg.system.initramfs = std.meta.stringToEnum(config.Initramfs, s) orelse return error.BadValue,
        .privilege => cfg.system.privilege = std.meta.stringToEnum(config.Privilege, s) orelse return error.BadValue,
        .snapshots => cfg.system.snapshots = std.meta.stringToEnum(config.Snapshots, s) orelse return error.BadValue,
        .hardening => cfg.security.hardening = std.meta.stringToEnum(config.Hardening, s) orelse return error.BadValue,
        .secure_boot => cfg.security.secure_boot = std.meta.stringToEnum(config.SecureBoot, s) orelse return error.BadValue,
        .netmanager => cfg.network.manager = std.meta.stringToEnum(config.NetManager, s) orelse return error.BadValue,
        .gpu_driver => cfg.gpu.driver = std.meta.stringToEnum(config.GpuDriver, s) orelse return error.BadValue,
        .cflags => {
            if (std.mem.eql(u8, s, "safe")) cfg.makeconf.cflags = .safe else if (std.mem.eql(u8, s, "native")) cfg.makeconf.cflags = .native else if (std.mem.eql(u8, s, "custom")) {
                // keep any custom string already typed via
                // makeconf.cflags_custom — cycling to custom re-selects it.
                if (cfg.makeconf.cflags != .custom) cfg.makeconf.cflags = .{ .custom = "" };
            } else return error.BadValue;
        },
    }
    // keep derived flags consistent
    if (ef.tag == .scheme) cfg.disk.scheme_explicit = true;
    if (ef.tag == .init) {
        // musl ⇒ no systemd; systemd-networkd follows init
        if (cfg.system.init == .systemd and cfg.stage3.libc == .musl) cfg.stage3.libc = .glibc;
        // leaving systemd while networkd is selected leaves an invalid
        // pair — move the manager to the default rather than stranding
        // the user on a validation error from another page.
        if (cfg.system.init != .systemd and cfg.network.manager == .@"systemd-networkd")
            cfg.network.manager = .networkmanager;
    }
    if (ef.tag == .libc) {
        if (cfg.stage3.libc == .musl and cfg.system.init == .systemd) cfg.system.init = .openrc;
        if (cfg.stage3.libc == .musl and cfg.network.manager == .@"systemd-networkd") cfg.network.manager = .networkmanager;
    }
    // selinux+ hardening is one decision (the policy/toolchain ships in
    // the hardened-selinux stage3) — keep the bool in lock-step so the
    // wizard can't land in a combination config.validate rejects.
    if (ef.tag == .hardening)
        cfg.security.selinux = (cfg.security.hardening == .@"hardened-selinux");
    if (ef.tag == .toolchain and cfg.stage3.toolchain == .llvm and
        cfg.security.hardening == .@"hardened-selinux" and cfg.stage3.libc == .glibc)
    {
        // no glibc+llvm+hardened-selinux stage3 — drop to plain hardened
        cfg.security.hardening = .hardened;
        cfg.security.selinux = false;
    }
}

const cfg_bool = struct {
    fn set(cfg: *Config, name: []const u8, b: bool) void {
        // selinux is tied to the hardening axis — toggling it moves
        // hardening to keep the pair consistent (see setEnum.hardening).
        if (std.mem.eql(u8, name, "security.selinux")) {
            cfg.security.selinux = b;
            cfg.security.hardening = if (b) .@"hardened-selinux" else .hardened;
            return;
        }
        const map = .{
            .{ "disk.wipe", &cfg.disk.wipe },
            .{ "disk.boot_part", &cfg.disk.boot_part },
            .{ "disk.luks", &cfg.disk.luks },
            .{ "disk.lvm", &cfg.disk.lvm },
            .{ "disk.home_part", &cfg.disk.home_part },
            .{ "system.uki", &cfg.system.uki },
            .{ "system.binhost", &cfg.system.binhost },
            .{ "network.wifi", &cfg.network.wifi },
            .{ "services.sshd", &cfg.services.sshd },
            .{ "services.logger", &cfg.services.logger },
            .{ "services.cron", &cfg.services.cron },
            .{ "services.ntp", &cfg.services.ntp },
        };
        inline for (map) |m| {
            if (std.mem.eql(u8, name, m[0])) {
                m[1].* = b;
                return;
            }
        }
    }
};
const bool_fields = [_][]const u8{ "disk.wipe", "disk.boot_part", "disk.luks", "disk.lvm", "disk.home_part", "system.uki", "system.binhost", "network.wifi", "services.sshd", "services.logger", "services.cron", "services.ntp", "security.selinux" };

const cfg_int = struct {
    fn set(cfg: *Config, name: []const u8, n: u32) void {
        const map = .{
            .{ "disk.swap_mib", &cfg.disk.swap_mib },
            .{ "disk.shrink_mib", &cfg.disk.shrink_mib },
            .{ "disk.esp_mib", &cfg.disk.esp_mib },
            .{ "system.keep_kernels", &cfg.system.keep_kernels },
            .{ "makeconf.jobs", &cfg.makeconf.jobs },
            .{ "makeconf.mem_cap_gib", &cfg.makeconf.mem_cap_gib },
        };
        inline for (map) |m| {
            if (std.mem.eql(u8, name, m[0])) {
                m[1].* = n;
                return;
            }
        }
    }
};
const int_fields = [_][]const u8{ "disk.swap_mib", "disk.shrink_mib", "disk.esp_mib", "system.keep_kernels", "makeconf.jobs", "makeconf.mem_cap_gib" };

const cfg_str = struct {
    fn set(cfg: *Config, alloc: Allocator, name: []const u8, s: []const u8) !void {
        const map = .{
            .{ "disk.device", &cfg.disk.device },
            .{ "disk.shrink_part", &cfg.disk.shrink_part },
            .{ "system.hostname", &cfg.system.hostname },
            .{ "system.timezone", &cfg.system.timezone },
            .{ "system.locale", &cfg.system.locale },
            .{ "system.keymap", &cfg.system.keymap },
            .{ "stage3.variant", &cfg.stage3.variant },
            .{ "stage3.mirror", &cfg.stage3.mirror },
            .{ "makeconf.accept_license", &cfg.makeconf.accept_license },
            .{ "makeconf.video_cards", &cfg.makeconf.video_cards },
            .{ "makeconf.mirrors", &cfg.makeconf.mirrors },
        };
        inline for (map) |m| {
            if (std.mem.eql(u8, name, m[0])) {
                m[1].* = try alloc.dupe(u8, s);
                return;
            }
        }
    }
};
const str_fields = [_][]const u8{ "disk.device", "disk.shrink_part", "system.hostname", "system.timezone", "system.locale", "system.keymap", "stage3.variant", "stage3.mirror", "makeconf.accept_license", "makeconf.video_cards", "makeconf.mirrors" };

const cfg_list = struct {
    fn set(cfg: *Config, name: []const u8, items: []const []const u8) void {
        const map = .{
            .{ "system.locales", &cfg.system.locales },
            .{ "packages.sets", &cfg.packages.sets },
            .{ "packages.atoms", &cfg.packages.atoms },
        };
        inline for (map) |m| {
            if (std.mem.eql(u8, name, m[0])) {
                m[1].* = items;
                return;
            }
        }
    }
};
const list_fields = [_][]const u8{ "system.locales", "packages.sets", "packages.atoms" };

// ---------- JSON emit helpers ----------

pub fn jesc(out: *std.Io.Writer, s: []const u8) void {
    for (s) |ch| {
        switch (ch) {
            '"', '\\' => out.print("\\{c}", .{ch}) catch return,
            '\n' => out.writeAll("\\n") catch return,
            '\r' => out.writeAll("\\r") catch return,
            '\t' => out.writeAll("\\t") catch return,
            else => if (ch < 0x20) out.print("\\u{x:0>4}", .{ch}) catch return else out.writeByte(ch) catch return,
        }
    }
}

fn jstr(out: *std.Io.Writer, s: []const u8) !void {
    try out.writeAll("\"");
    jesc(out, s);
    try out.writeAll("\"");
}

fn fieldStr(out: *std.Io.Writer, k: []const u8, v: []const u8) !void {
    try out.writeAll("\"");
    jesc(out, k);
    try out.writeAll("\":");
    try jstr(out, v);
}
fn fieldBool(out: *std.Io.Writer, k: []const u8, v: bool) !void {
    try out.writeAll("\"");
    jesc(out, k);
    try out.writeAll("\":");
    try out.writeAll(if (v) "true" else "false");
}
fn fieldInt(out: *std.Io.Writer, k: []const u8, v: u32) !void {
    try out.writeAll("\"");
    jesc(out, k);
    try out.print("\":{}", .{v});
}

/// Emit a field's current value straight from cfg (non-secret types).
fn emitCfgValue(w: *Wizard, out: *std.Io.Writer, name: []const u8, ftype: FType) !void {
    const cfg = &w.cfg;
    switch (ftype) {
        .@"enum" => {
            // enum fields are mostly enum-typed in cfg; string-backed
            // ones (disk.device, system.keymap, …) fall through to strVal
            if (enumVal(cfg, name)) |val| {
                try jstr(out, val);
            } else if (strVal(cfg, name)) |s| {
                try jstr(out, s);
            } else {
                try out.writeAll("null");
            }
        },
        .bool => {
            const v = boolVal(cfg, name) orelse false;
            try out.writeAll(if (v) "true" else "false");
        },
        .int => {
            const v = intVal(cfg, name) orelse 0;
            try out.print("{}", .{v});
        },
        .string, .path => {
            const v = strVal(cfg, name) orelse "";
            try jstr(out, v);
        },
        .list => {
            const items = listVal(cfg, name) orelse &.{};
            try out.writeAll("[");
            for (items, 0..) |s, i| {
                if (i > 0) try out.writeAll(",");
                try jstr(out, s);
            }
            try out.writeAll("]");
        },
        .record => {
            const t = if (std.mem.eql(u8, name, "use.global")) &cfg.use.global else &cfg.use.pkg;
            try out.writeAll("{");
            var it = t.iterator();
            var first = true;
            while (it.next()) |kv| {
                if (!first) try out.writeAll(",");
                first = false;
                try jstr(out, kv.key_ptr.*);
                try out.writeAll(":");
                switch (kv.value_ptr.*) {
                    .boolean => |b| try out.writeAll(if (b) "true" else "false"),
                    .integer => |i| try out.print("{}", .{i}),
                    .string => |s| try jstr(out, s),
                    else => try out.writeAll("null"),
                }
            }
            try out.writeAll("}");
        },
        .table => {
            // users[]
            try out.writeAll("[");
            for (cfg.users, 0..) |u, i| {
                if (i > 0) try out.writeAll(",");
                try out.writeAll("{\"name\":");
                try jstr(out, u.name);
                try out.writeAll(",\"shell\":");
                try jstr(out, u.shell);
                try out.writeAll(",\"groups\":[");
                for (u.groups, 0..) |g, gi| {
                    if (gi > 0) try out.writeAll(",");
                    try jstr(out, g);
                }
                try out.writeAll("],\"ssh_authorized_keys\":[");
                for (u.ssh_authorized_keys, 0..) |k, ki| {
                    if (ki > 0) try out.writeAll(",");
                    try jstr(out, k);
                }
                try out.print("],\"password\":{{\"secret\":true,\"is_set\":{}}}}}", .{u.password_hash != null});
            }
            try out.writeAll("]");
        },
        .secret => unreachable, // handled in emitValue
    }
}

fn enumVal(cfg: *Config, name: []const u8) ?[]const u8 {
    inline for (enum_fields) |ef| {
        if (std.mem.eql(u8, name, ef.name)) {
            return switch (ef.tag) {
                .scheme => @tagName(cfg.disk.scheme),
                .root_fs => @tagName(cfg.disk.root_fs),
                .swap => @tagName(cfg.disk.swap),
                .space_src => @tagName(cfg.disk.space_src),
                .libc => @tagName(cfg.stage3.libc),
                .toolchain => @tagName(cfg.stage3.toolchain),
                .init => @tagName(cfg.system.init),
                .kernel => @tagName(cfg.system.kernel),
                .bootloader => @tagName(cfg.system.bootloader),
                .initramfs => @tagName(cfg.system.initramfs),
                .privilege => @tagName(cfg.system.privilege),
                .snapshots => @tagName(cfg.system.snapshots),
                .hardening => @tagName(cfg.security.hardening),
                .secure_boot => @tagName(cfg.security.secure_boot),
                .netmanager => @tagName(cfg.network.manager),
                .gpu_driver => @tagName(cfg.gpu.driver),
                .cflags => switch (cfg.makeconf.cflags) {
                    .safe => "safe",
                    .native => "native",
                    .custom => "custom",
                },
            };
        }
    }
    return null;
}

fn boolVal(cfg: *Config, name: []const u8) ?bool {
    const map = .{
        .{ "disk.wipe", cfg.disk.wipe },
        .{ "disk.boot_part", cfg.disk.boot_part },
        .{ "disk.luks", cfg.disk.luks },
        .{ "disk.lvm", cfg.disk.lvm },
        .{ "disk.home_part", cfg.disk.home_part },
        .{ "system.uki", cfg.system.uki },
        .{ "system.binhost", cfg.system.binhost },
        .{ "network.wifi", cfg.network.wifi },
        .{ "services.sshd", cfg.services.sshd },
        .{ "services.logger", cfg.services.logger },
        .{ "services.cron", cfg.services.cron },
        .{ "services.ntp", cfg.services.ntp },
        .{ "security.selinux", cfg.security.selinux },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, name, m[0])) return m[1];
    }
    return null;
}

fn intVal(cfg: *Config, name: []const u8) ?u32 {
    const map = .{
        .{ "disk.swap_mib", cfg.disk.swap_mib },
        .{ "disk.shrink_mib", cfg.disk.shrink_mib },
        .{ "disk.esp_mib", cfg.disk.esp_mib },
        .{ "system.keep_kernels", cfg.system.keep_kernels },
        .{ "makeconf.jobs", cfg.makeconf.jobs },
        .{ "makeconf.mem_cap_gib", cfg.makeconf.mem_cap_gib },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, name, m[0])) return m[1];
    }
    return null;
}

fn strVal(cfg: *Config, name: []const u8) ?[]const u8 {
    const map = .{
        .{ "disk.device", cfg.disk.device },
        .{ "disk.shrink_part", cfg.disk.shrink_part },
        .{ "system.hostname", cfg.system.hostname },
        .{ "system.timezone", cfg.system.timezone },
        .{ "system.locale", cfg.system.locale },
        .{ "system.keymap", cfg.system.keymap },
        .{ "stage3.variant", cfg.stage3.variant },
        .{ "stage3.mirror", cfg.stage3.mirror },
        .{ "makeconf.accept_license", cfg.makeconf.accept_license },
        .{ "makeconf.video_cards", cfg.makeconf.video_cards },
        .{ "makeconf.mirrors", cfg.makeconf.mirrors },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, name, m[0])) return m[1];
    }
    return null;
}

fn listVal(cfg: *Config, name: []const u8) ?[]const []const u8 {
    const map = .{
        .{ "system.locales", cfg.system.locales },
        .{ "packages.sets", cfg.packages.sets },
        .{ "packages.atoms", cfg.packages.atoms },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, name, m[0])) return m[1];
    }
    return null;
}

// ---------- tests ----------

const testing = std.testing;

fn testWizard() Wizard {
    return Wizard.init(testing.allocator, testing.io, .{});
}

fn pageJsonHas(w: *Wizard, alloc: Allocator, page_id: []const u8, needle: []const u8) !bool {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try w.emitPage(&aw.writer, null, page_id);
    return std.mem.indexOf(u8, aw.written(), needle) != null;
}

test "express flow visits only essential pages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var w = testWizard();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try w.emitPage(&aw.writer, null, null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"of\":4") != null);
    // welcome → disk → accounts → review
    try testing.expect(try w.next(alloc, null));
    try testing.expectEqualStrings("disk", w.currentPage().id);
}

test "advanced flow visits all pages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var w = testWizard();
    try w.setField("flow.mode", .{ .string = "advanced" });
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try w.emitPage(&aw.writer, null, null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"of\":8") != null);
}

test "every page emits valid JSON in both flows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    inline for (.{ Flow.express, Flow.advanced }) |fl| {
        var w = testWizard();
        w.flow = fl;
        w.cfg.disk.luks = true; // widen visible field set
        w.cfg.disk.luks_passphrase = "sup3rsecret";
        w.cfg.disk.device = "/dev/vda";
        for (pages) |pg| {
            var aw: std.Io.Writer.Allocating = .init(alloc);
            try w.emitPage(&aw.writer, null, pg.id);
            _ = std.json.parseFromSlice(std.json.Value, alloc, aw.written(), .{}) catch |e| {
                std.debug.print("invalid page JSON ({s}, page {s}): {s}\n", .{ @tagName(fl), pg.id, aw.written() });
                return e;
            };
        }
    }
}

test "back wraps at page zero" {
    var w = testWizard();
    w.back();
    try testing.expectEqual(@as(usize, 0), w.page_idx);
}

test "secrets are masked in page emission and config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var w = testWizard();
    w.cfg.disk.luks = true;
    w.cfg.disk.luks_passphrase = "sup3rsecret";
    try testing.expect(try pageJsonHas(&w, alloc, "disk", "\"is_set\":true"));
    try testing.expect(!(try pageJsonHas(&w, alloc, "disk", "sup3rsecret")));
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try w.emitConfigJson(&aw.writer, null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "sup3rsecret") == null);
}

test "luks passphrase field only visible when luks on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var w = testWizard();
    w.flow = .advanced;
    try testing.expect(!(try pageJsonHas(&w, alloc, "disk", "disk.luks_passphrase")));
    try w.setField("disk.luks", .{ .bool = true });
    try testing.expect(try pageJsonHas(&w, alloc, "disk", "disk.luks_passphrase"));
}

test "root.password set hashes via openssl" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var w = testWizard();
    w.alloc = arena.allocator();
    try w.setField("root.password", .{ .string = "correct horse battery" });
    const h = w.cfg.root.password_hash orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.startsWith(u8, h, "$6$"));
    try testing.expect(!std.mem.eql(u8, h, "correct horse battery"));
}

test "next blocks on invalid page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var w = testWizard();
    try testing.expect(try w.next(alloc, null)); // welcome ok
    // disk: no device → stays
    try testing.expect(!(try w.next(alloc, null)));
    try testing.expectEqualStrings("disk", w.currentPage().id);
}

test "set enum coercion keeps derived state consistent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var w = testWizard();
    try w.setField("stage3.libc", .{ .string = "musl" });
    // musl can't host systemd → init falls back to openrc
    try testing.expect(w.cfg.system.init == .openrc);
}

test "users table set masks password as hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var w = testWizard();
    w.alloc = alloc;
    const arr = [_]std.json.Value{.{
        .object = blk: {
            var o: std.json.ObjectMap = try .init(alloc, &.{}, &.{});
            try o.put(alloc, "name", .{ .string = "m" });
            try o.put(alloc, "password", .{ .string = "hunter2xyz" });
            break :blk o;
        },
    }};
    var al = std.json.Array.init(alloc);
    try al.appendSlice(&arr);
    const v = std.json.Value{ .array = al };
    try w.setField("users", v);
    try testing.expectEqual(@as(usize, 1), w.cfg.users.len);
    try testing.expectEqualStrings("m", w.cfg.users[0].name);
    const h = w.cfg.users[0].password_hash orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.startsWith(u8, h, "$6$"));
}

test "user.name renames users[0] without dropping the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var w = testWizard();
    w.alloc = arena.allocator();
    var arr = std.json.Array.init(arena.allocator());
    const o1 = try std.json.ObjectMap.init(arena.allocator(), &.{}, &.{});
    var jb = std.json.Value{ .object = o1 };
    try jb.object.put(arena.allocator(), "name", .{ .string = "bob" });
    try jb.object.put(arena.allocator(), "shell", .{ .string = "/bin/zsh" });
    const o2 = try std.json.ObjectMap.init(arena.allocator(), &.{}, &.{});
    var jc = std.json.Value{ .object = o2 };
    try jc.object.put(arena.allocator(), "name", .{ .string = "carol" });
    try arr.append(jb);
    try arr.append(jc);
    try w.setField("users", .{ .array = arr });
    try w.setField("user.name", .{ .string = "alice" });
    try testing.expectEqual(@as(usize, 2), w.cfg.users.len);
    try testing.expectEqualStrings("alice", w.cfg.users[0].name);
    try testing.expectEqualStrings("/bin/zsh", w.cfg.users[0].shell);
    try testing.expectEqualStrings("carol", w.cfg.users[1].name);
}

test "disk.luks_passphrase sets and clears" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var w = testWizard();
    w.alloc = arena.allocator();
    try w.setField("disk.luks_passphrase", .{ .string = "hunter2hunter" });
    try testing.expectEqualStrings("hunter2hunter", w.cfg.disk.luks_passphrase.?);
    try testing.expectError(error.BadValue, w.setField("disk.luks_passphrase", .{ .string = "short" }));
    try w.setField("disk.luks_passphrase", .{ .string = "" });
    try testing.expect(w.cfg.disk.luks_passphrase == null);
}

test "int fields reject out-of-range values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var w = testWizard();
    w.alloc = arena.allocator();
    try testing.expectError(error.BadValue, w.setField("disk.esp_mib", .{ .integer = -1 }));
    try testing.expectError(error.BadValue, w.setField("disk.esp_mib", .{ .integer = 1 << 40 }));
    try w.setField("disk.esp_mib", .{ .integer = 512 });
    try testing.expectEqual(@as(u32, 512), w.cfg.disk.esp_mib);
}

test "answer file and export refuse paths outside cwd" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var w = testWizard();
    w.alloc = arena.allocator();
    try testing.expectError(error.PathEscape, w.setField("answer_file", .{ .string = "/etc/hostname" }));
    try testing.expectError(error.PathEscape, w.setField("answer_file", .{ .string = "../escape.toml" }));
    try testing.expectError(error.PathEscape, w.exportAnswer("/tmp/out.toml"));
}

test "exportAnswer round-trips through loadAnswerFile" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var w = testWizard();
    w.alloc = alloc;
    w.cfg.disk.device = "/dev/vda";
    w.cfg.root.password_hash = "$6$abc$def";
    // confined paths: writes/reads live under the process cwd
    const path = ".zig-cache/gi-wizard-test-ans.toml";
    try w.exportAnswer(path);
    var w2 = testWizard();
    w2.alloc = alloc;
    try w2.loadAnswerFile(path);
    try testing.expectEqualStrings("/dev/vda", w2.cfg.disk.device);
    try testing.expectEqualStrings("$6$abc$def", w2.cfg.root.password_hash.?);
    try testing.expectEqualStrings("review", w2.currentPage().id);
}

test "applyEnv follows firmware both directions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var w = testWizard();
    w.alloc = arena.allocator();
    const e_bios = detect.Env{
        .arch = .amd64,
        .boot_mode = .bios,
        .ram_mib = 8192,
        .cpu_count = 4,
        .cpu_vendor = "test",
        .cpu_flags = &.{},
        .nics = &.{},
        .gpus = &.{},
        .disks = &.{},
        .net_reachable = false,
    };
    var e_uefi = e_bios;
    e_uefi.boot_mode = .uefi;
    w.applyEnv(e_bios);
    try testing.expectEqual(config.Scheme.@"bios-boot-swap-root", w.cfg.disk.scheme);
    // a later UEFI re-detect must un-apply the BIOS scheme
    w.applyEnv(e_uefi);
    try testing.expectEqual(config.Scheme.@"efi-swap-root", w.cfg.disk.scheme);
    // an explicit scheme survives the flip
    w.cfg.disk.scheme = .manual;
    w.cfg.disk.scheme_explicit = true;
    w.applyEnv(e_bios);
    try testing.expectEqual(config.Scheme.manual, w.cfg.disk.scheme);
}

test "preset defaults apply and locks reject divergence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const doc = try toml.parse(alloc,
        \\[preset]
        \\id = "dinit-distro"
        \\[defaults.system]
        \\init = "dinit"
        \\[defaults.disk]
        \\root_fs = "btrfs"
        \\[locks]
        \\fields = ["system.init"]
    , null);
    var p = preset_mod.Preset{ .doc = doc, .locks = &.{"system.init"} };
    var w = testWizard();
    w.alloc = alloc;
    w.preset = &p;
    try w.applyPresetDefaults();
    try testing.expectEqual(config.Init.dinit, w.cfg.system.init);
    try testing.expectEqual(config.RootFs.btrfs, w.cfg.disk.root_fs);
    // locked: only the preset default is accepted
    try testing.expectError(error.Locked, w.setField("system.init", .{ .string = "systemd" }));
    try w.setField("system.init", .{ .string = "dinit" });
    // unlocked fields still set normally
    try w.setField("system.hostname", .{ .string = "box" });
    try testing.expectEqualStrings("box", w.cfg.system.hostname);
}

test "export refuses an existing symlink that escapes cwd" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var w = testWizard();
    w.alloc = arena.allocator();
    const dir = ".zig-cache";
    std.Io.Dir.cwd().createDirPath(testing.io, dir) catch {};
    const link = ".zig-cache/gi-wizard-test-link.toml";
    std.Io.Dir.cwd().deleteFile(testing.io, link) catch {};
    std.Io.Dir.cwd().symLink(testing.io, "/etc/passwd", link, .{}) catch return;
    defer std.Io.Dir.cwd().deleteFile(testing.io, link) catch {};
    try testing.expectError(error.PathEscape, w.exportAnswer(link));
}
