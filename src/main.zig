//! gentoo-installer — CLI entry point.
//!   gentoo-installer tui        (M2 — not yet implemented)
//!   gentoo-installer headless   (NDJSON on stdio — minimal M1 surface)
//!   gentoo-installer --config f [--preset p] [--dry-run] [--skip s,...]

const std = @import("std");
const engine = @import("engine");

const usage =
    \\usage: gentoo-installer <command> [options]
    \\
    \\commands:
    \\  tui                 interactive TUI wizard (not yet implemented)
    \\  headless            NDJSON protocol on stdin/stdout
    \\  run                 execute an install
    \\  plan                print the install plan (implies --dry-run)
    \\  validate            validate config only
    \\  detect              print detected environment as JSON
    \\
    \\options:
    \\  --config FILE       TOML install config (required for run/plan/validate)
    \\  --preset FILE       preset.toml supplying defaults/locks
    \\  --dry-run           print the plan instead of executing
    \\  --journal FILE      journal path (default /tmp/gentoo-installer.journal)
    \\  --skip a,b          skip steps by id
    \\  -h, --help          this text
    \\
;

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const out = &fw.interface;
    var stderr_buf: [1024]u8 = undefined;
    var efw = std.Io.File.stderr().writer(init.io, &stderr_buf);
    const errw = &efw.interface;

    // One-shot CLI: everything lives in the process arena — freed at exit.
    const alloc = init.arena.allocator();
    const io = init.io;

    var cmd: enum { none, tui, headless, run, plan, validate, detect, help, version } = .none;
    var config_path: ?[]const u8 = null;
    var preset_path: ?[]const u8 = null;
    var journal_path: []const u8 = "/tmp/gentoo-installer.journal";
    var confirm_dev: ?[]const u8 = null;
    var dry_run = false;
    var skips: std.ArrayList([]const u8) = .empty;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    defer it.deinit();
    _ = it.skip(); // argv0
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "tui")) cmd = .tui else if (std.mem.eql(u8, arg, "headless")) cmd = .headless else if (std.mem.eql(u8, arg, "run")) cmd = .run else if (std.mem.eql(u8, arg, "plan")) {
            cmd = .plan;
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "validate")) cmd = .validate else if (std.mem.eql(u8, arg, "detect")) cmd = .detect else if (std.mem.eql(u8, arg, "--config")) {
            config_path = it.next() orelse return fatal(errw, "--config needs a path");
        } else if (std.mem.eql(u8, arg, "--preset")) {
            preset_path = it.next() orelse return fatal(errw, "--preset needs a path");
        } else if (std.mem.eql(u8, arg, "--confirm")) {
            confirm_dev = it.next() orelse return fatal(errw, "--confirm needs the target device");
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--journal")) {
            journal_path = it.next() orelse return fatal(errw, "--journal needs a path");
        } else if (std.mem.eql(u8, arg, "--skip")) {
            const list = it.next() orelse return fatal(errw, "--skip needs a,b");
            var parts = std.mem.splitScalar(u8, list, ',');
            while (parts.next()) |p| try skips.append(alloc, p);
        } else if (std.mem.eql(u8, arg, "--version")) {
            cmd = .version;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) {
            cmd = .help;
        } else {
            try errw.print("unknown argument: {s}\n", .{arg});
            try errw.flush();
            return fatal(errw, "");
        }
    }

    switch (cmd) {
        .version => {
            try out.print("{s}\n", .{engine.version});
            try out.flush();
            return;
        },
        .help, .none => {
            try out.writeAll(usage);
            try out.flush();
            return;
        },
        .detect => {
            const env = try engine.detect.detect(alloc, io);
            try engine.detect.envToJson(alloc, &env, out);
            try out.writeAll("\n");
            try out.flush();
            return;
        },
        else => {},
    }

    // The preset object is needed by every mode that can build a plan —
    // tui and headless resolve package sets through it just like run/
    // plan/validate do. Defaults/locks still merge below where a config
    // document exists.
    var preset: ?engine.preset.Preset = null;
    defer if (preset) |*p| p.deinit();
    if (preset_path) |pp| {
        preset = engine.preset.load(alloc, pp, io) catch |e| {
            try errw.print("preset {s}: {s}\n", .{ pp, @errorName(e) });
            try errw.flush();
            std.process.exit(2);
        };
        if (preset.?.engine_min) |min| {
            if (engine.preset.versionLt(engine.version, min)) {
                try errw.print("preset '{s}' needs engine >= {s} (running {s})\n", .{ preset.?.id, min, engine.version });
                try errw.flush();
                std.process.exit(2);
            }
        }
    }

    switch (cmd) {
        .tui => return @import("tui.zig").runTui(init, alloc, io, if (preset) |*pp| pp else null),
        .headless => return headless(init, alloc, io, out, errw, if (preset) |*pp| pp else null, config_path),
        else => {},
    }

    // run / plan / validate need a config
    const cp = config_path orelse {
        try errw.writeAll("this command needs --config FILE\n" ++ usage);
        try errw.flush();
        std.process.exit(2);
    };
    var cfg = loadCliConfig(io, alloc, errw, cp, if (preset) |*pp| pp else null);
    _ = &cfg;

    // Always probe the live env for run/plan/validate — it fills the
    // boot_mode/scheme defaults and feeds jobs/NICs/VIDEO_CARDS into the
    // plan (explicit arch is checked below; plan previews still work).
    var env_opt: ?engine.detect.Env = null;
    {
        env_opt = engine.detect.detect(alloc, io) catch null;
        if (env_opt) |*e| {
            if (cfg.arch == .detect) {
                cfg.arch = e.arch;
            } else if (cfg.arch != e.arch and cmd == .run and !dry_run) {
                try errw.print("config arch {s} does not match detected {s} — refusing to exec a foreign-arch install\n", .{ @tagName(cfg.arch), @tagName(e.arch) });
                try errw.flush();
                std.process.exit(2);
            }
            // boot_mode: detection fills the default; an explicit config
            // value wins, and a mismatch is a hard stop.
            if (!cfg.boot_mode_explicit) {
                cfg.boot_mode = e.boot_mode;
            } else if (cfg.boot_mode != e.boot_mode) {
                try errw.print("config requests {s} but the live env booted {s} — refusing (fix the config or boot firmware settings)\n", .{ @tagName(cfg.boot_mode), @tagName(e.boot_mode) });
                try errw.flush();
                std.process.exit(2);
            }
            // scheme follows boot_mode unless the config pinned one.
            if (!cfg.disk.scheme_explicit and cfg.boot_mode == .bios)
                cfg.disk.scheme = .@"bios-boot-swap-root";
        }
    }

    const nvidia: ?engine.config.NvidiaTier = if (env_opt) |*e| blk: {
        var any = false;
        var turing = false;
        for (e.gpus) |g| {
            if (std.mem.eql(u8, g.vendor, "nvidia")) {
                any = true;
                if (engine.detect.nvidiaIsTuringPlus(g)) turing = true;
            }
        }
        break :blk if (!any) .absent else if (turing) .open_capable else .legacy;
    } else null;

    const errs = try engine.config.validate(alloc, &cfg, nvidia, if (env_opt) |*e| e else null);
    if (errs.len > 0) {
        for (errs) |e| try errw.print("validate: {s}\n", .{e});
        try errw.flush();
        std.process.exit(1);
    }
    if (cmd == .validate) {
        try out.writeAll("config valid\n");
        try out.flush();
        return;
    }

    // Exec-mode gates for choices with no complete backend: a manual
    // kernel needs the user's .config, and alt inits install packages
    // but can't yet take over PID 1 or enable services (service
    // migration lands with the init backends in M6).
    if (cmd == .run and !dry_run and cfg.system.kernel == .manual and cfg.system.kernel_config.len == 0) {
        try errw.print("kernel=manual needs system.kernel_config=<path to .config> — or use dist|dist-bin\n", .{});
        try errw.flush();
        std.process.exit(2);
    }
    // Secrets are exec gates, not plan gates — an exported answer file
    // previews fine but can't run until the passphrase is provided.
    if (cmd == .run and !dry_run) if (engine.config.execPrechecks(&cfg)) |e| {
        try errw.print("{s}\n", .{e});
        try errw.flush();
        std.process.exit(2);
    };

    // Destructive exec runs require --confirm <device> matching the
    // configured disk — an answer file alone must never wipe a disk.
    // manual is always destructive: every listed row is partitioned
    // and formatted whether or not the table gets wiped first.
    // alongside mutates too: fs/partition shrink is the first
    // irreversible op, so it needs the same typed confirmation.
    const destructive = cfg.disk.scheme == .@"efi-swap-root" or cfg.disk.scheme == .@"bios-boot-swap-root" or
        cfg.disk.scheme == .manual or cfg.disk.scheme == .alongside;
    if (cmd == .run and !dry_run and destructive) {
        const cd = confirm_dev orelse {
            try errw.print("refusing to run without --confirm {s} (this will wipe the target disk)\n", .{cfg.disk.device});
            try errw.flush();
            std.process.exit(2);
        };
        if (!std.mem.eql(u8, cd, cfg.disk.device)) {
            try errw.print("--confirm {s} does not match disk.device {s}\n", .{ cd, cfg.disk.device });
            try errw.flush();
            std.process.exit(2);
        }

        // Capacity preflight before the first destructive command — an
        // undersized or unknown target must be refused, not wiped then
        // failed by sgdisk. The floor is the DOCUMENTED 8 GiB usable
        // root, expressed through the layout's actual allocation: LVM
        // linear gives root 70% of the VG, the thin pool 95%; LUKS/LVM
        // metadata and GPT overhead consume ~36 MiB on top.
        var need_mib: u64 = 4; // GPT overhead
        if (cfg.disk.scheme == .manual) {
            // Free-form: explicit sizes sum + an 8 GiB floor when the
            // root row is "rest". (Validation already refuses an
            // explicit root < 8 GiB.)
            var root_is_rest = false;
            for (cfg.disk.partitions) |p| {
                if (engine.config.parseSizeMiB(p.size)) |n|
                    need_mib +|= n
                else if (std.mem.eql(u8, p.mount, "/"))
                    root_is_rest = true;
            }
            if (root_is_rest) need_mib +|= 8192;
            if (cfg.disk.luks) need_mib +|= 32;
        } else {
            if (cfg.boot_mode == .uefi) need_mib +|= cfg.disk.esp_mib else need_mib +|= 2;
            if (cfg.disk.swap == .partition) need_mib +|= cfg.disk.swap_mib;
            if (cfg.disk.boot_part) need_mib +|= 1024;
            if (cfg.disk.luks or cfg.disk.lvm) need_mib +|= 32;
            need_mib +|= if (cfg.disk.lvm)
                (if (cfg.system.snapshots == .auto) (8192 * 100 + 94) / 95 else (8192 * 10 + 6) / 7)
            else
                8192;
        }
        var size_mib: ?u64 = null;
        if (env_opt) |*e| {
            // Match kernel names AND persistent names: resolve symlinks
            // so /dev/disk/by-id/... or /dev/mapper/... compares equal
            // to the detected /dev/<name> path.
            var rbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const rlen = std.Io.Dir.cwd().realPathFile(io, cfg.disk.device, &rbuf) catch null;
            const resolved: ?[]const u8 = if (rlen) |n| rbuf[0..n] else null;
            for (e.disks) |dk| {
                if (std.mem.eql(u8, dk.path, cfg.disk.device) or
                    (resolved != null and std.mem.eql(u8, dk.path, resolved.?)))
                {
                    size_mib = dk.size_bytes / (1 << 20);
                    // Canonicalize to the kernel path: partPath appends
                    // 1/pN while udev names by-id partitions <id>-partN —
                    // planning must target the resolved device.
                    cfg.disk.device = dk.path;
                }
            }
        }
        if (size_mib) |sz| {
            if (sz < need_mib) {
                try errw.print("{s} is {} MiB — layout needs {} MiB (esp+swap+boot+8GiB usable root)\n", .{ cfg.disk.device, sz, need_mib });
                try errw.flush();
                std.process.exit(2);
            }
        } else {
            try errw.print("{s} not among detected disks — refusing to wipe an unverified target\n", .{cfg.disk.device});
            try errw.flush();
            std.process.exit(2);
        }
    }

    // Resolve preset package sets → atoms + overlay repos (M1: preset
    // supplies the set table; absent preset = stock gentoo ids only).
    var pkg_sets: engine.plan.Sets = .{};
    // sets absent → null → preset defaults; explicit [] → selects none.
    const rs = try engine.preset.resolveSets(alloc, if (preset) |*pp| pp else null, if (cfg.packages.sets_explicit) cfg.packages.sets else null);
    for (rs.errs) |e| try errw.print("{s}\n", .{e});
    if (rs.errs.len > 0) {
        try errw.flush();
        std.process.exit(1);
    }
    pkg_sets = .{ .atoms = rs.resolved.atoms, .repos = rs.resolved.repos };

    const p = engine.plan.build(alloc, &cfg, if (env_opt) |*e| e else null, pkg_sets, if (preset) |*pp| pp else null, null) catch |e| {
        try errw.print("plan build failed: {s}\n", .{@errorName(e)});
        try errw.flush();
        std.process.exit(1);
    };
    try engine.runner.run(io, alloc, p, .{
        .mode = if (dry_run or cmd == .plan) .dry_run else .exec,
        .journal_path = if (cmd == .run and !dry_run) journal_path else null,
        .skip_steps = skips.items,
        .out = out,
    });
}

const JsonLine = struct { op: ?[]const u8, req: ?u64, version: ?u64, version_bad: bool, malformed: bool, val: ?std.json.Value };

/// Parse one NDJSON request line; op must be a string, req a non-negative
/// integer. Non-object or invalid JSON reports `malformed`. The full
/// object rides along in `val` for ops that carry payloads.
fn parseLine(alloc: std.mem.Allocator, line: []const u8) JsonLine {
    const none = JsonLine{ .op = null, .req = null, .version = null, .version_bad = false, .malformed = true, .val = null };
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return none;
    if (parsed.value != .object) return none;
    const obj = parsed.value.object;
    var op: ?[]const u8 = null;
    var req: ?u64 = null;
    var version: ?u64 = null;
    var version_bad = false;
    if (obj.get("op")) |ov| {
        if (ov == .string) op = ov.string;
    }
    if (obj.get("req")) |rv| {
        if (rv == .integer and rv.integer >= 0) req = @intCast(rv.integer);
    }
    if (obj.get("version")) |vv| {
        if (vv == .integer and vv.integer >= 0)
            version = @intCast(vv.integer)
        else
            version_bad = true; // present but not a non-negative int
    }
    return .{ .op = op, .req = req, .version = version, .version_bad = version_bad, .malformed = false, .val = parsed.value };
}

fn jfield(jl: JsonLine, key: []const u8) ?std.json.Value {
    const v = jl.val orelse return null;
    return v.object.get(key);
}
fn jstr(jl: JsonLine, key: []const u8) ?[]const u8 {
    const v = jfield(jl, key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}
fn jbool(jl: JsonLine, key: []const u8) ?bool {
    const v = jfield(jl, key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn fatal(w: *std.Io.Writer, msg: []const u8) noreturn {
    if (msg.len > 0) w.print("{s}\n", .{msg}) catch {};
    w.flush() catch {};
    std.process.exit(2);
}

/// Shared config-file pipeline for run/plan/validate and a prefilled
/// headless session (`--config` with `headless`, per protocol.md):
/// read → parse → preset defaults+locks → decode → explicit flags.
fn loadCliConfig(io: std.Io, alloc: std.mem.Allocator, errw: *std.Io.Writer, cp: []const u8, preset: ?*const engine.preset.Preset) engine.config.Config {
    const text = std.Io.Dir.cwd().readFileAlloc(io, cp, alloc, .limited(4 << 20)) catch |e| {
        errw.print("cannot read {s}: {s}\n", .{ cp, @errorName(e) }) catch {};
        errw.flush() catch {};
        std.process.exit(2);
    };
    var perr: engine.toml.ParseError = undefined;
    var doc = engine.toml.parse(alloc, text, &perr) catch |e| {
        if (e == error.InvalidToml) {
            errw.print("{s}:{}: invalid toml: {s}\n", .{ cp, perr.line, perr.msg }) catch {};
        } else {
            errw.print("{s}: {s}\n", .{ cp, @errorName(e) }) catch {};
        }
        errw.flush() catch {};
        std.process.exit(2);
    };

    // Record which detection-relevant keys the USER's document carried
    // before preset defaults merge in — a preset-supplied boot_mode or
    // scheme must not mark the value user-pinned.
    const user_set_boot = doc.root.get("boot_mode") != null;
    const user_set_scheme = blk: {
        const d = doc.root.get("disk") orelse break :blk false;
        break :blk d == .table and d.table.get("scheme") != null;
    };

    if (preset) |pp| {
        engine.preset.mergeDefaults(pp, &doc) catch return oom(errw);
        const lock_errs = engine.preset.checkLocks(alloc, pp, &doc) catch return oom(errw);
        for (lock_errs) |e| errw.print("preset: {s}\n", .{e}) catch {};
        if (lock_errs.len > 0) {
            errw.flush() catch {};
            std.process.exit(2);
        }
    }

    var cfg = engine.config.decode(alloc, doc) catch {
        errw.writeAll("config decode failed (see log)\n") catch {};
        errw.flush() catch {};
        std.process.exit(2);
    };
    // Only user-supplied keys are "explicit" — except preservation
    // schemes (alongside/manual), where a preset default is
    // data-preservation policy and must not be overwritten by
    // detection. A preset's erase scheme still yields to firmware
    // (efi-swap-root ↔ bios-boot-swap-root).
    cfg.boot_mode_explicit = user_set_boot;
    cfg.disk.scheme_explicit = user_set_scheme or blk: {
        const d = doc.root.get("disk") orelse break :blk false;
        if (d != .table) break :blk false;
        const sv = d.table.get("scheme") orelse break :blk false;
        if (sv != .string) break :blk false;
        break :blk std.mem.eql(u8, sv.string, "alongside") or std.mem.eql(u8, sv.string, "manual");
    };
    return cfg;
}

fn oom(errw: *std.Io.Writer) noreturn {
    errw.writeAll("out of memory\n") catch {};
    errw.flush() catch {};
    std.process.exit(2);
}

/// NDJSON protocol surface: hello/detect + the wizard ops (page, set,
/// next, back, goto, get_config, set_config, validate, plan,
/// export_answer, install) + quit. See docs/protocol.md.
fn headless(init: std.process.Init, alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, errw: *std.Io.Writer, preset: ?*const engine.preset.Preset, cfg_path: ?[]const u8) !void {
    _ = init;
    var stdin_buf: [8192]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &stdin_buf);
    const r = &fr.interface;

    var wiz = engine.wizard.Wizard.init(alloc, io, .{});
    wiz.preset = preset;
    wiz.applyPresetDefaults() catch {};
    // `--config` prefills the session per protocol.md — same
    // file pipeline (defaults merge, lock check, explicit flags) as
    // the CLI commands, then the wire drives from there.
    if (cfg_path) |cp| wiz.cfg = loadCliConfig(io, alloc, errw, cp, preset);
    var wiz_arena = std.heap.ArenaAllocator.init(alloc);
    defer wiz_arena.deinit();

    var line_buf: std.Io.Writer.Allocating = .init(alloc);
    defer line_buf.deinit();
    while (true) {
        line_buf.clearRetainingCapacity();
        // streamDelimiter leaves the delimiter buffered; consume it. An
        // EndOfStream with bytes still processes the unterminated final
        // line before breaking.
        var at_eof = false;
        if (r.streamDelimiter(&line_buf.writer, '\n')) |_| {
            if (r.peekGreedy(1)) |avail| {
                if (avail.len > 0 and avail[0] == '\n') r.toss(1);
            } else |_| at_eof = true;
        } else |e| switch (e) {
            error.EndOfStream => at_eof = true,
            else => return e,
        }
        const line = std.mem.trim(u8, line_buf.written(), " \r\n\t");
        if (line.len == 0) {
            if (at_eof) break;
            continue;
        }
        // Per-request arena: JSON trees + probe data die with the reply.
        var req_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const req_alloc = req_arena.allocator();
        const jl = parseLine(req_alloc, line);
        if (jl.malformed) {
            try writeErr(out, null, "invalid json");
            try out.flush();
            req_arena.deinit();
            if (at_eof) break;
            continue;
        }
        const req = jl.req;
        const op = jl.op orelse {
            try writeErr(out, req, "missing op");
            try out.flush();
            req_arena.deinit();
            if (at_eof) break;
            continue;
        };
        if (std.mem.eql(u8, op, "hello")) {
            // the hello reply doubles as ready, per docs/protocol.md
            if (jl.version_bad or (jl.version != null and jl.version.? != 1)) {
                try writeErr(out, req, "unsupported protocol version (server speaks 1)");
            } else {
                try out.writeAll("{\"ev\":\"hello\",");
                try writeReq(out, req);
                try out.writeAll("\"engine\":\"0.1.0\",\"version\":1,\"caps\":[\"hello\",\"detect\",\"wizard\",\"install\",\"quit\"]}\n");
            }
        } else if (std.mem.eql(u8, op, "detect")) {
            // env must outlive the request — disks/gpus populate
            // wizard field options for the rest of the session.
            const env = try engine.detect.detect(wiz_arena.allocator(), io);
            wiz.applyEnv(env);
            try out.writeAll("{\"ev\":\"env\",");
            try writeReq(out, req);
            try engine.detect.envFieldsJson(alloc, &env, out);
            try out.writeAll("}\n");
        } else if (std.mem.eql(u8, op, "quit")) {
            // bye has no payload fields — emit req without writeReq's
            // trailing comma.
            try out.writeAll("{\"ev\":\"bye\"");
            if (req) |rq| try out.print(",\"req\":{}", .{rq});
            try out.writeAll("}\n");
            try out.flush();
            return;
        } else if (std.mem.eql(u8, op, "page")) {
            const pgname = jstr(jl, "page");
            wiz.emitPage(out, req, pgname) catch |e| {
                try writeErr(out, req, switch (e) {
                    error.BadValue => "unknown page",
                    else => "page failed",
                });
            };
        } else if (std.mem.eql(u8, op, "next")) {
            const nv = wizNvidia(&wiz);
            const ok = wiz.next(req_alloc, nv) catch |e| blk: {
                break :blk e != error.OutOfMemory;
            };
            if (ok) {
                try wiz.emitPage(out, req, null);
            } else {
                const errs = wiz.pageErrors(req_alloc, nv, wiz.currentPage()) catch &.{};
                try writeValidate(out, req, errs);
            }
        } else if (std.mem.eql(u8, op, "back")) {
            wiz.back();
            try wiz.emitPage(out, req, null);
        } else if (std.mem.eql(u8, op, "goto")) {
            const pgname = jstr(jl, "page") orelse {
                try writeErr(out, req, "goto needs a page name");
                try out.flush();
                req_arena.deinit();
                if (at_eof) break;
                continue;
            };
            wiz.emitPage(out, req, pgname) catch |e| {
                try writeErr(out, req, switch (e) {
                    error.BadValue => "unknown page",
                    else => "page failed",
                });
            };
        } else if (std.mem.eql(u8, op, "set")) {
            const field = jstr(jl, "field") orelse {
                try writeErr(out, req, "set needs a field");
                try out.flush();
                req_arena.deinit();
                if (at_eof) break;
                continue;
            };
            const value = jfield(jl, "value") orelse {
                try writeErr(out, req, "set needs a value");
                try out.flush();
                req_arena.deinit();
                if (at_eof) break;
                continue;
            };
            wiz.setField(field, value) catch |e| {
                var aw: std.Io.Writer.Allocating = .init(req_alloc);
                aw.writer.print("set {s}: {s}", .{ field, @errorName(e) }) catch {};
                try writeErr(out, req, aw.written());
                try out.flush();
                req_arena.deinit();
                if (at_eof) break;
                continue;
            };
            try writeResult(out, req);
            // validate delta — the whole-config errors (frontend maps
            // them to the owning page by field prefix)
            const errs = engine.config.validate(req_alloc, &wiz.cfg, wizNvidia(&wiz), if (wiz.env) |*e| e else null) catch &.{};
            try writeValidate(out, null, errs);
        } else if (std.mem.eql(u8, op, "set_config")) {
            // {config:{dotted.path:value,…}} — same as N `set` ops; a
            // field that fails is reported, not silently dropped.
            const cv = jfield(jl, "config");
            // A missing/wrongly-typed payload is a client error, not a
            // no-op: replying ok would silently keep the old config.
            if (cv == null or cv.? != .object) {
                try writeErr(out, req, "set_config needs a config object");
                try out.flush();
                req_arena.deinit();
                if (at_eof) break;
                continue;
            }
            var set_errs: std.Io.Writer.Allocating = .init(req_alloc);
            var nerr: usize = 0;
            var it = cv.?.object.iterator();
            while (it.next()) |kv| {
                wiz.setField(kv.key_ptr.*, kv.value_ptr.*) catch |e| {
                    if (nerr > 0) set_errs.writer.writeAll("; ") catch {};
                    set_errs.writer.print("{s}: {s}", .{ kv.key_ptr.*, @errorName(e) }) catch {};
                    nerr += 1;
                };
            }
            if (nerr > 0)
                try writeErr(out, req, set_errs.written())
            else
                try writeResult(out, req);
            const errs = engine.config.validate(req_alloc, &wiz.cfg, wizNvidia(&wiz), if (wiz.env) |*e| e else null) catch &.{};
            try writeValidate(out, null, errs);
        } else if (std.mem.eql(u8, op, "get_config")) {
            try wiz.emitConfigJson(out, req);
        } else if (std.mem.eql(u8, op, "validate")) {
            const errs = engine.config.validate(req_alloc, &wiz.cfg, wizNvidia(&wiz), if (wiz.env) |*e| e else null) catch &.{};
            try writeValidate(out, req, errs);
        } else if (std.mem.eql(u8, op, "plan")) {
            // A plan is executable shell — never emit one from an
            // invalid config (e.g. an unsafe mirror a `set` accepted).
            const perrs = engine.config.validate(req_alloc, &wiz.cfg, wizNvidia(&wiz), if (wiz.env) |*e| e else null) catch &.{};
            if (perrs.len > 0) {
                try writeValidate(out, req, perrs);
                try out.flush();
                req_arena.deinit();
                if (at_eof) break;
                continue;
            }
            const ps = wiz.pkgSets(req_alloc) catch |e| {
                var aw2: std.Io.Writer.Allocating = .init(req_alloc);
                aw2.writer.print("set resolution failed: {s}", .{@errorName(e)}) catch {};
                try writeErr(out, req, aw2.written());
                try out.flush();
                req_arena.deinit();
                if (at_eof) break;
                continue;
            };
            if (ps.errs.len > 0) {
                var aw2: std.Io.Writer.Allocating = .init(req_alloc);
                for (ps.errs, 0..) |e2, i| {
                    if (i > 0) aw2.writer.writeAll("; ") catch {};
                    aw2.writer.writeAll(e2) catch {};
                }
                try writeErr(out, req, aw2.written());
                try out.flush();
                req_arena.deinit();
                if (at_eof) break;
                continue;
            }
            const p = engine.plan.build(req_alloc, &wiz.cfg, if (wiz.env) |*e| e else null, ps.sets, wiz.preset, null) catch |e| {
                var aw: std.Io.Writer.Allocating = .init(req_alloc);
                aw.writer.print("plan build failed: {s}", .{@errorName(e)}) catch {};
                try writeErr(out, req, aw.written());
                try out.flush();
                req_arena.deinit();
                if (at_eof) break;
                continue;
            };
            var aw: std.Io.Writer.Allocating = .init(req_alloc);
            try engine.runner.run(io, req_alloc, p, .{ .mode = .dry_run, .out = &aw.writer });
            try out.writeAll("{\"ev\":\"plan\",");
            try writeReq(out, req);
            try out.writeAll("\"cmds\":[");
            var lines = std.mem.splitScalar(u8, aw.written(), '\n');
            var first = true;
            while (lines.next()) |ln| {
                if (ln.len == 0) continue;
                if (!first) try out.writeAll(",");
                first = false;
                try out.writeAll("\"");
                jsonEsc(out, ln);
                try out.writeAll("\"");
            }
            try out.writeAll("]}\n");
        } else if (std.mem.eql(u8, op, "export_answer")) {
            const path = jstr(jl, "path") orelse {
                try writeErr(out, req, "export_answer needs a path");
                try out.flush();
                req_arena.deinit();
                if (at_eof) break;
                continue;
            };
            wiz.exportAnswer(path) catch |e| {
                var aw: std.Io.Writer.Allocating = .init(req_alloc);
                aw.writer.print("export failed: {s}", .{@errorName(e)}) catch {};
                try writeErr(out, req, aw.written());
                try out.flush();
                req_arena.deinit();
                if (at_eof) break;
                continue;
            };
            try writeResult(out, req);
        } else if (std.mem.eql(u8, op, "install")) {
            const dry = jbool(jl, "dry_run") orelse true;
            try doInstall(io, req_alloc, &wiz, out, req, dry, jl);
        } else {
            var aw: std.Io.Writer.Allocating = .init(alloc);
            aw.writer.writeAll("unknown op '") catch return error.OutOfMemory;
            jsonEsc(&aw.writer, op);
            aw.writer.writeAll("'") catch return error.OutOfMemory;
            try writeErr(out, req, aw.written());
        }
        try out.flush();
        req_arena.deinit();
        if (at_eof) break;
    }
}

/// Emit `{"ev":"error","req":N,"error":"<escaped>"}`.
fn writeErr(out: *std.Io.Writer, req: ?u64, msg: []const u8) !void {
    try out.writeAll("{\"ev\":\"error\",");
    try writeReq(out, req);
    try out.writeAll("\"error\":\"");
    jsonEsc(out, msg);
    try out.writeAll("\"}\n");
}

/// `"req":N,` prefix when the request carried one.
fn writeReq(out: *std.Io.Writer, req: ?u64) !void {
    if (req) |rq| try out.print("\"req\":{},", .{rq});
}

fn jsonEsc(w: *std.Io.Writer, str: []const u8) void {
    for (str) |ch| {
        switch (ch) {
            '"', '\\' => w.print("\\{c}", .{ch}) catch return,
            '\n' => w.writeAll("\\n") catch return,
            '\r' => w.writeAll("\\r") catch return,
            '\t' => w.writeAll("\\t") catch return,
            else => if (ch < 0x20) w.print("\\u{x:0>4}", .{ch}) catch return else w.writeByte(ch) catch return,
        }
    }
}

// ---------- headless helpers ----------

fn wizNvidia(wiz: *engine.wizard.Wizard) ?engine.config.NvidiaTier {
    const env = wiz.env orelse return null; // unknown, not absent
    for (env.gpus) |g| {
        if (std.mem.eql(u8, g.vendor, "nvidia"))
            return if (engine.detect.nvidiaIsTuringPlus(g)) .open_capable else .legacy;
    }
    return .absent;
}

fn writeResult(out: *std.Io.Writer, req: ?u64) !void {
    try out.writeAll("{\"ev\":\"result\",");
    try writeReq(out, req);
    try out.writeAll("\"ok\":true}\n");
}

fn writeValidate(out: *std.Io.Writer, req: ?u64, errs: []const []const u8) !void {
    try out.writeAll("{\"ev\":\"validate\",");
    try writeReq(out, req);
    try out.writeAll("\"errors\":[");
    for (errs, 0..) |e, i| {
        if (i > 0) try out.writeAll(",");
        try out.writeAll("{\"message\":\"");
        jsonEsc(out, e);
        try out.writeAll("\"}");
    }
    try out.writeAll("],\"warnings\":[]}\n");
}

const StepCtx = struct {
    out: *std.Io.Writer,
    dry: bool,
};
fn stepEventCb(ctx: ?*anyopaque, i: usize, of: usize, id: []const u8, state: []const u8) void {
    const c: *StepCtx = @ptrCast(@alignCast(ctx orelse return));
    c.out.writeAll("{\"ev\":\"step\",") catch return;
    c.out.print("\"i\":{},\"of\":{},\"name\":\"", .{ i, of }) catch return;
    jsonEsc(c.out, id);
    c.out.writeAll("\",\"state\":\"") catch return;
    jsonEsc(c.out, state);
    c.out.writeAll("\"}\n") catch return;
    c.out.flush() catch {};
}

/// `install` op — validates, mirrors the run path's exec gates
/// (confirm token, exec-blocked combos, capacity), then runs the plan
/// streaming `step` events, finished by a `done` or `error` event.
fn doInstall(io: std.Io, alloc: std.mem.Allocator, wiz: *engine.wizard.Wizard, out: *std.Io.Writer, req: ?u64, dry: bool, jl: JsonLine) !void {
    const cfg = &wiz.cfg;
    const errs = engine.config.validate(alloc, cfg, wizNvidia(wiz), if (wiz.env) |*e| e else null) catch &.{};
    if (errs.len > 0) {
        try writeValidate(out, req, errs);
        return;
    }
    const env_opt = wiz.env;
    if (!dry) {
        if (env_opt == null) {
            try writeErr(out, req, "install exec requires a prior detect op (no env)");
            return;
        }
        // Live-boot honesty: an explicit boot_mode (answer file) that
        // disagrees with the firmware we probed must refuse, not produce
        // a plan aimed at the wrong firmware. Non-explicit values were
        // already synced by applyEnv.
        if (cfg.boot_mode != env_opt.?.boot_mode) {
            var aw: std.Io.Writer.Allocating = .init(alloc);
            aw.writer.print("config requests {s} but the live env booted {s} — refusing", .{ @tagName(cfg.boot_mode), @tagName(env_opt.?.boot_mode) }) catch {};
            try writeErr(out, req, aw.written());
            return;
        }
        // Same for arch: cross-arch exec would write a foreign rootfs
        // (plan/dry-run still preview it).
        if (cfg.arch != env_opt.?.arch) {
            var aw: std.Io.Writer.Allocating = .init(alloc);
            aw.writer.print("config arch {s} does not match detected {s} — refusing to exec a foreign-arch install", .{ @tagName(cfg.arch), @tagName(env_opt.?.arch) }) catch {};
            try writeErr(out, req, aw.written());
            return;
        }
        if (cfg.system.kernel == .manual and cfg.system.kernel_config.len == 0) {
            try writeErr(out, req, "kernel=manual needs system.kernel_config=<path to .config>");
            return;
        }
        if (engine.config.execPrechecks(cfg)) |e| {
            try writeErr(out, req, e);
            return;
        }
        const destructive = cfg.disk.scheme == .@"efi-swap-root" or cfg.disk.scheme == .@"bios-boot-swap-root" or
            cfg.disk.scheme == .manual or cfg.disk.scheme == .alongside;
        if (destructive) {
            const confirm = jstr(jl, "confirm") orelse {
                try writeErr(out, req, "destructive install needs confirm=<disk basename>");
                return;
            };
            const base = std.fs.path.basename(cfg.disk.device);
            if (!std.mem.eql(u8, confirm, base) and !std.mem.eql(u8, confirm, cfg.disk.device)) {
                try writeErr(out, req, "confirm does not match disk.device");
                return;
            }
            // capacity preflight — same floor as `run`
            var need_mib: u64 = 4;
            if (cfg.disk.scheme == .manual) {
                var root_is_rest = false;
                for (cfg.disk.partitions) |p| {
                    if (engine.config.parseSizeMiB(p.size)) |n|
                        need_mib +|= n
                    else if (std.mem.eql(u8, p.mount, "/"))
                        root_is_rest = true;
                }
                if (root_is_rest) need_mib +|= 8192;
                if (cfg.disk.luks) need_mib +|= 32;
            } else {
                if (cfg.boot_mode == .uefi) need_mib +|= cfg.disk.esp_mib else need_mib +|= 2;
                if (cfg.disk.swap == .partition) need_mib +|= cfg.disk.swap_mib;
                if (cfg.disk.boot_part) need_mib +|= 1024;
                if (cfg.disk.luks or cfg.disk.lvm) need_mib +|= 32;
                need_mib +|= if (cfg.disk.lvm)
                    (if (cfg.system.snapshots == .auto) (8192 * 100 + 94) / 95 else (8192 * 10 + 6) / 7)
                else
                    8192;
            }
            var size_mib: ?u64 = null;
            const e = env_opt.?;
            var rbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const rlen = std.Io.Dir.cwd().realPathFile(io, cfg.disk.device, &rbuf) catch null;
            const resolved: ?[]const u8 = if (rlen) |n| rbuf[0..n] else null;
            for (e.disks) |dk| {
                if (std.mem.eql(u8, dk.path, cfg.disk.device) or
                    (resolved != null and std.mem.eql(u8, dk.path, resolved.?)))
                {
                    size_mib = dk.size_bytes / (1 << 20);
                    cfg.disk.device = dk.path;
                }
            }
            if (size_mib == null) {
                try writeErr(out, req, "disk.device not among detected disks — refusing to wipe an unverified target");
                return;
            }
            if (size_mib.? < need_mib) {
                var aw: std.Io.Writer.Allocating = .init(alloc);
                aw.writer.print("{s} is {} MiB — layout needs {} MiB", .{ cfg.disk.device, size_mib.?, need_mib }) catch {};
                try writeErr(out, req, aw.written());
                return;
            }
        }
    }
    const ps = wiz.pkgSets(alloc) catch |e| {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        aw.writer.print("set resolution failed: {s}", .{@errorName(e)}) catch {};
        try writeErr(out, req, aw.written());
        return;
    };
    if (ps.errs.len > 0) {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        for (ps.errs, 0..) |e2, i| {
            if (i > 0) aw.writer.writeAll("; ") catch {};
            aw.writer.writeAll(e2) catch {};
        }
        try writeErr(out, req, aw.written());
        return;
    }
    const p = engine.plan.build(alloc, cfg, if (env_opt) |*e| e else null, ps.sets, wiz.preset, null) catch |e| {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        aw.writer.print("plan build failed: {s}", .{@errorName(e)}) catch {};
        try writeErr(out, req, aw.written());
        return;
    };
    var sctx = StepCtx{ .out = out, .dry = dry };
    var logw: std.Io.Writer.Allocating = .init(alloc);
    engine.runner.run(io, alloc, p, .{
        .mode = if (dry) .dry_run else .exec,
        .journal_path = if (dry) null else "/tmp/gentoo-installer.journal",
        .out = &logw.writer,
        .on_step = stepEventCb,
        .ctx = &sctx,
    }) catch |e| {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        aw.writer.print("install failed: {s}", .{@errorName(e)}) catch {};
        try writeErr(out, req, aw.written());
        return;
    };
    try out.writeAll("{\"ev\":\"done\",");
    try writeReq(out, req);
    // reboot_ready is only true for a real exec — a dry-run preview
    // installed nothing, and frontends key reboot prompts off this.
    try out.print("\"ok\":true,\"reboot_ready\":{}}}\n", .{!dry});
}
