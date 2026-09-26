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

    // detect if the config left arch/boot_mode to detection
    var env_opt: ?engine.detect.Env = null;
    if (cfg.arch == .detect or cmd == .run) {
        env_opt = engine.detect.detect(alloc, io) catch null;
        if (env_opt) |*e| {
            if (cfg.arch == .detect) cfg.arch = e.arch;
            // boot_mode: detection fills the default; an explicit config
            // value wins, and a mismatch is a hard stop.
            if (!cfg.boot_mode_explicit) {
                cfg.boot_mode = e.boot_mode;
            } else if (cfg.boot_mode != e.boot_mode) {
                try errw.print("config requests {s} but the live env booted {s} — refusing (fix the config or boot firmware settings)\n", .{ @tagName(cfg.boot_mode), @tagName(e.boot_mode) });
                try errw.flush();
                std.process.exit(2);
            }
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

    const p = try engine.plan.build(alloc, &cfg, if (env_opt) |*e| e else null);
    try engine.runner.run(io, alloc, p, .{
        .mode = if (dry_run or cmd == .plan) .dry_run else .exec,
        .journal_path = if (cmd == .run and !dry_run) journal_path else null,
        .skip_steps = skips.items,
        .out = out,
    });
}

/// Extract the string value of a top-level `"op"` key from an NDJSON
/// line. Minimal extractor — full JSON parse arrives with the M2 op set.
fn opField(line: []const u8) ?[]const u8 {
    const k = std.mem.indexOf(u8, line, "\"op\"") orelse return null;
    var i = k + 4;
    while (i < line.len and (line[i] == ' ' or line[i] == ':')) i += 1;
    if (i >= line.len or line[i] != '"') return null;
    const start = i + 1;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
    return line[start..end];
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

    try out.writeAll("{\"type\":\"ready\",\"version\":\"m1\"}\n");
    try out.flush();

    var line_buf: std.Io.Writer.Allocating = .init(alloc);
    defer line_buf.deinit();
    while (true) {
        line_buf.clearRetainingCapacity();
        // streamDelimiter leaves the delimiter buffered; consume it and
        // treat a peek failure as EOF.
        _ = r.streamDelimiter(&line_buf.writer, '\n') catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        const line = std.mem.trim(u8, line_buf.written(), " \r\n\t");
        if (line.len > 0) {
            // handled below
        } else if (r.peekGreedy(1) catch null) |_| {
            // empty line — consume the leftover delimiter and continue
            r.toss(1);
            continue;
        } else break;
        const op = opField(line) orelse {
            try out.writeAll("{\"type\":\"error\",\"error\":\"missing op\"}\n");
            try out.flush();
            continue;
        };
        if (std.mem.eql(u8, op, "detect")) {
            const env = try engine.detect.detect(alloc, io);
            try out.writeAll("{\"type\":\"env\",\"env\":");
            try engine.detect.envToJson(alloc, &env, out);
            try out.writeAll("}\n");
        } else if (std.mem.eql(u8, op, "hello")) {
            try out.writeAll("{\"type\":\"hello\",\"version\":\"m1\",\"ready\":true}\n");
        } else if (std.mem.eql(u8, op, "quit")) {
            try out.writeAll("{\"type\":\"bye\"}\n");
            try out.flush();
            return;
        } else {
            try out.print("{{\"type\":\"error\",\"error\":\"unknown op '{s}' (m1 supports hello/detect/quit)\"}}\n", .{op});
        }
        try out.flush();
        // consume the delimiter streamDelimiter left buffered; EOF → break
        const avail = r.peekGreedy(1) catch break;
        if (avail.len > 0 and avail[0] == '\n') r.toss(1);
    }
}
