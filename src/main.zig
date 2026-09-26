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

    var cmd: enum { none, tui, headless, run, plan, validate, detect, help } = .none;
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
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) {
            cmd = .help;
        } else {
            try errw.print("unknown argument: {s}\n", .{arg});
            try errw.flush();
            return fatal(errw, "");
        }
    }

    switch (cmd) {
        .help, .none => {
            try out.writeAll(usage);
            try out.flush();
            return;
        },
        .tui => {
            try errw.writeAll("tui: not yet implemented (M2)\n");
            try errw.flush();
            std.process.exit(2);
        },
        .detect => {
            const env = try engine.detect.detect(alloc, io);
            try engine.detect.envToJson(alloc, &env, out);
            try out.writeAll("\n");
            try out.flush();
            return;
        },
        .headless => return headless(init, alloc, io, out, errw),
        else => {},
    }

    // run / plan / validate need a config
    const cp = config_path orelse {
        try errw.writeAll("this command needs --config FILE\n" ++ usage);
        try errw.flush();
        std.process.exit(2);
    };
    const text = std.Io.Dir.cwd().readFileAlloc(io, cp, alloc, .limited(4 << 20)) catch |e| {
        try errw.print("cannot read {s}: {s}\n", .{ cp, @errorName(e) });
        try errw.flush();
        std.process.exit(2);
    };
    var perr: engine.toml.ParseError = undefined;
    var doc = engine.toml.parse(alloc, text, &perr) catch |e| {
        if (e == error.InvalidToml) {
            try errw.print("{s}:{}: invalid toml: {s}\n", .{ cp, perr.line, perr.msg });
        } else {
            try errw.print("{s}: {s}\n", .{ cp, @errorName(e) });
        }
        try errw.flush();
        std.process.exit(2);
    };
    defer doc.deinit();

    // Record which detection-relevant keys the USER's document carried
    // before preset defaults merge in — a preset-supplied boot_mode or
    // scheme must not mark the value user-pinned.
    const user_set_boot = doc.root.get("boot_mode") != null;
    const user_set_scheme = blk: {
        const d = doc.root.get("disk") orelse break :blk false;
        break :blk d == .table and d.table.get("scheme") != null;
    };

    var preset: ?engine.preset.Preset = null;
    defer if (preset) |*p| p.deinit();
    if (preset_path) |pp| {
        preset = engine.preset.load(alloc, pp, io) catch |e| {
            try errw.print("preset {s}: {s}\n", .{ pp, @errorName(e) });
            try errw.flush();
            std.process.exit(2);
        };
        try engine.preset.mergeDefaults(&preset.?, &doc);
        const lock_errs = try engine.preset.checkLocks(alloc, &preset.?, &doc);
        for (lock_errs) |e| try errw.print("preset: {s}\n", .{e});
        if (lock_errs.len > 0) {
            try errw.flush();
            std.process.exit(2);
        }
    }

    var cfg = engine.config.decode(alloc, doc) catch {
        try errw.writeAll("config decode failed (see log)\n");
        try errw.flush();
        std.process.exit(2);
    };
    // Only user-supplied keys are "explicit"; preset defaults yield to
    // live-environment detection.
    cfg.boot_mode_explicit = user_set_boot;
    cfg.disk.scheme_explicit = user_set_scheme;

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

    const nvidia = if (env_opt) |*e| blk: {
        var has = false;
        for (e.gpus) |g| {
            if (std.mem.eql(u8, g.vendor, "nvidia")) has = true;
        }
        break :blk has;
    } else null;

    const errs = try engine.config.validate(alloc, &cfg, nvidia);
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

    // Exec-mode gates for scheme: alongside/manual don't create the
    // root partition yet (partition-level detection + dual-boot logic
    // are M6) — refuse real runs, dry-run still prints the plan.
    if (cmd == .run and !dry_run and (cfg.disk.scheme == .alongside or cfg.disk.scheme == .manual)) {
        try errw.print("scheme '{s}' is not executable yet (dual-boot lands in M6) — use --dry-run to preview\n", .{@tagName(cfg.disk.scheme)});
        try errw.flush();
        std.process.exit(2);
    }

    // Destructive exec runs require --confirm <device> matching the
    // configured disk — an answer file alone must never wipe a disk.
    const destructive = cfg.disk.scheme == .@"efi-swap-root" or cfg.disk.scheme == .@"bios-boot-swap-root";
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

    const p = try engine.plan.build(alloc, &cfg, if (env_opt) |*e| e else null, pkg_sets);
    try engine.runner.run(io, alloc, p, .{
        .mode = if (dry_run or cmd == .plan) .dry_run else .exec,
        .journal_path = if (cmd == .run and !dry_run) journal_path else null,
        .skip_steps = skips.items,
        .out = out,
    });
}

const JsonLine = struct { op: ?[]const u8, req: ?u64, malformed: bool };

/// Parse one NDJSON request line; op must be a string, req a non-negative
/// integer. Non-object or invalid JSON reports `malformed`.
fn parseLine(alloc: std.mem.Allocator, line: []const u8) JsonLine {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch
        return .{ .op = null, .req = null, .malformed = true };
    if (parsed.value != .object) return .{ .op = null, .req = null, .malformed = true };
    const obj = parsed.value.object;
    var op: ?[]const u8 = null;
    var req: ?u64 = null;
    if (obj.get("op")) |ov| {
        if (ov == .string) op = ov.string;
    }
    if (obj.get("req")) |rv| {
        if (rv == .integer and rv.integer >= 0) req = @intCast(rv.integer);
    }
    return .{ .op = op, .req = req, .malformed = false };
}

fn fatal(w: *std.Io.Writer, msg: []const u8) noreturn {
    if (msg.len > 0) w.print("{s}\n", .{msg}) catch {};
    w.flush() catch {};
    std.process.exit(2);
}

/// Minimal NDJSON protocol surface for M1: reads op lines, answers
/// `hello` (with env), `detect`, and `quit`. Full op set lands with
/// the wizard state machine (M2).
fn headless(init: std.process.Init, alloc: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, errw: *std.Io.Writer) !void {
    _ = init;
    _ = errw;
    var stdin_buf: [8192]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &stdin_buf);
    const r = &fr.interface;

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
            try out.writeAll("{\"ev\":\"hello\",");
            try writeReq(out, req);
            try out.writeAll("\"engine\":\"0.1.0\",\"version\":1,\"caps\":[\"hello\",\"detect\",\"quit\"]}\n");
        } else if (std.mem.eql(u8, op, "detect")) {
            const env = try engine.detect.detect(req_alloc, io);
            try out.writeAll("{\"ev\":\"env\",");
            try writeReq(out, req);
            try engine.detect.envFieldsJson(alloc, &env, out);
            try out.writeAll("}\n");
        } else if (std.mem.eql(u8, op, "quit")) {
            try out.writeAll("{\"ev\":\"result\",");
            try writeReq(out, req);
            try out.writeAll("\"ok\":true}\n");
            try out.flush();
            return;
        } else {
            var aw: std.Io.Writer.Allocating = .init(alloc);
            aw.writer.writeAll("unknown op '") catch return error.OutOfMemory;
            jsonEsc(&aw.writer, op);
            aw.writer.writeAll("' (m1 supports hello/detect/quit)") catch return error.OutOfMemory;
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
