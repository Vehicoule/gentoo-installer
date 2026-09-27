//! Executes a Plan, or prints it under --dry-run. Appends one complete
//! JSONL journal record per command to the live-env tmpfs — the records
//! are diagnostics today; resume/repair consume them in a later
//! milestone. stdin payloads are never journaled or printed.

const std = @import("std");
const plan = @import("plan.zig");
const Allocator = std.mem.Allocator;

pub const Mode = enum { dry_run, exec };

pub const Options = struct {
    mode: Mode,
    /// Where the journal goes; null = journal disabled (dry runs).
    journal_path: ?[]const u8 = null,
    /// Steps to skip entirely (resume support lands later — flag exists
    /// so callers can express it).
    skip_steps: []const []const u8 = &.{},
    out: *std.Io.Writer,
    /// Per-step observer for structured consumers (headless `step`
    /// events, TUI progress page). state: started/done/failed/skipped.
    on_step: ?*const fn (ctx: ?*anyopaque, i: usize, of: usize, id: []const u8, state: []const u8) void = null,
    ctx: ?*anyopaque = null,
};

pub const Journal = struct {
    file: ?std.Io.File = null,
    io: std.Io,

    pub fn open(io: std.Io, path: ?[]const u8) !Journal {
        const p = path orelse return .{ .io = io };
        const fd = try std.posix.openat(std.posix.AT.FDCWD, p, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
        return .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } }, .io = io };
    }

    /// Start a JSON object: `{"step":"<id>",` — callers append fields,
    /// `finish` closes and appends the line.
    fn begin(aw: *std.Io.Writer.Allocating, step_id: []const u8) void {
        aw.writer.writeAll("{\"step\":\"") catch return;
        esc(&aw.writer, step_id);
        aw.writer.writeAll("\",") catch return;
    }

    fn finish(j: *Journal, aw: *std.Io.Writer.Allocating) void {
        const f = j.file orelse return;
        aw.writer.writeAll("}\n") catch return;
        f.writePositionalAll(j.io, aw.written(), 0) catch {}; // O_APPEND → offset ignored
    }

    /// json-escape a string value (no surrounding quotes).
    fn esc(w: *std.Io.Writer, s: []const u8) void {
        for (s) |ch| {
            switch (ch) {
                '"', '\\' => w.print("\\{c}", .{ch}) catch return,
                '\n' => w.writeAll("\\n") catch return,
                '\r' => w.writeAll("\\r") catch return,
                '\t' => w.writeAll("\\t") catch return,
                else => if (ch < 0x20) w.print("\\u{x:0>4}", .{ch}) catch return else w.writeByte(ch) catch return,
            }
        }
    }

    pub fn cmdExec(j: *Journal, step_id: []const u8, e: plan.Exec, status: []const u8) void {
        if (j.file == null) return;
        var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer aw.deinit();
        const w = &aw.writer;
        begin(&aw, step_id);
        w.writeAll("\"type\":\"exec\",\"argv\":\"") catch return;
        for (e.argv, 0..) |a, i| {
            if (i > 0) w.writeAll(" ") catch return;
            esc(w, a);
        }
        w.writeAll("\",\"status\":\"") catch return;
        w.writeAll(status) catch return;
        w.writeAll("\"") catch return;
        j.finish(&aw);
    }

    pub fn cmdWriteFile(j: *Journal, step_id: []const u8, wf: plan.WriteFile, status: []const u8) void {
        if (j.file == null) return;
        var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer aw.deinit();
        const w = &aw.writer;
        begin(&aw, step_id);
        w.writeAll("\"type\":\"write_file\",\"path\":\"") catch return;
        esc(w, wf.path);
        w.writeAll("\",\"status\":\"") catch return;
        w.writeAll(status) catch return;
        w.writeAll("\"") catch return;
        j.finish(&aw);
    }

    pub fn stepDone(j: *Journal, step_id: []const u8, skipped_: bool) void {
        if (j.file == null) return;
        var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer aw.deinit();
        const w = &aw.writer;
        begin(&aw, step_id);
        w.writeAll("\"type\":\"step\",\"status\":\"") catch return;
        w.writeAll(if (skipped_) "skipped" else "done") catch return;
        w.writeAll("\"") catch return;
        j.finish(&aw);
    }

    pub fn close(j: *Journal) void {
        if (j.file) |f| f.close(j.io);
        j.file = null;
    }
};

pub fn run(io: std.Io, alloc: Allocator, p: plan.Plan, opts: Options) !void {
    var journal = try Journal.open(io, opts.journal_path);
    defer journal.close();
    const out = opts.out;

    for (p.steps, 0..) |step, i| {
        if (skipped(step.id, opts.skip_steps)) {
            journal.stepDone(step.id, true);
            if (opts.on_step) |cb| cb(opts.ctx, i + 1, p.steps.len, step.id, "skipped");
            continue;
        }
        if (opts.on_step) |cb| cb(opts.ctx, i + 1, p.steps.len, step.id, "started");
        try out.print("[{d:0>2}] {s}  ({s})\n", .{ i + 1, step.title, step.id });
        var skipped_fail = false;
        for (step.cmds) |cmd| {
            switch (cmd) {
                .note => |n| try out.print("     note: {s}\n", .{n}),
                .write_file => |w| {
                    try out.print("     write {s} ({} bytes, {o})\n", .{ w.path, w.content.len, w.mode });
                    if (opts.mode == .exec) {
                        if (writeFile(io, w.path, w.content, w.mode)) {
                            journal.cmdWriteFile(step.id, w, "ok");
                        } else |err| {
                            journal.cmdWriteFile(step.id, w, "fail");
                            if (opts.on_step) |cb| cb(opts.ctx, i + 1, p.steps.len, step.id, "failed");
                            if (step.skippable) {
                                try out.print("     warning: skippable step failed — continuing\n", .{});
                                skipped_fail = true;
                                break;
                            }
                            return err;
                        }
                    }
                },
                .exec => |e| {
                    try out.print("     $", .{});
                    if (e.chroot) try out.writeAll(" chroot /mnt/gentoo");
                    for (e.argv) |a| try out.print(" {s}", .{a});
                    if (e.stdin_label != null) try out.print("  <stdin:{s}>", .{e.stdin_label.?});
                    if (e.desc.len > 0) try out.print("    # {s}", .{e.desc});
                    try out.writeAll("\n");
                    if (opts.mode == .exec) {
                        if (e.stdin_label != null and e.stdin == null)
                            return error.MissingStdinData;
                        execCmd(io, alloc, e) catch |err| {
                            journal.cmdExec(step.id, e, "fail");
                            // the step event carries no context — name the
                            // failing command + error on stderr at least
                            var ebuf: [4096]u8 = undefined;
                            var ew = std.Io.File.stderr().writer(io, &ebuf);
                            ew.interface.print("command failed ({s}): {s}\n", .{ e.desc, @errorName(err) }) catch {};
                            ew.interface.flush() catch {};
                            if (opts.on_step) |cb| cb(opts.ctx, i + 1, p.steps.len, step.id, "failed");
                            if (step.skippable) {
                                try out.print("     warning: skippable step failed — continuing\n", .{});
                                skipped_fail = true;
                                break;
                            }
                            return err;
                        };
                        journal.cmdExec(step.id, e, "ok");
                    }
                },
            }
        }
        if (skipped_fail) {
            // failed skippable step is not a success — journal + observers
            // see it as skipped, and the install continues.
            journal.stepDone(step.id, true);
            if (opts.on_step) |cb| cb(opts.ctx, i + 1, p.steps.len, step.id, "skipped");
            continue;
        }
        journal.stepDone(step.id, false);
        if (opts.on_step) |cb| cb(opts.ctx, i + 1, p.steps.len, step.id, "done");
    }
    try out.flush();
}

fn skipped(id: []const u8, skip: []const []const u8) bool {
    for (skip) |s| if (std.mem.eql(u8, s, id)) return true;
    return false;
}

fn writeFile(io: std.Io, path: []const u8, content: []const u8, mode: u32) !void {
    // Ensure parent dir exists.
    if (std.fs.path.dirname(path)) |dir|
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = content,
        .flags = .{ .truncate = true, .permissions = .fromMode(mode) },
    });
}

/// Child output drain — runs on its own thread so a verbose child
/// can't deadlock against an unwritten stdin payload or a full stderr
/// pipe. `collect` buffers instead of streaming: stdin-bearing
/// commands need post-hoc redaction before anything reaches stderr.
const DrainArgs = struct { io: std.Io, file: std.Io.File, collect: ?*std.Io.Writer.Allocating };

/// Strip bytes that could drive terminal control sequences — child
/// output can carry attacker-controlled content (mirror metadata,
/// package logs). C0/DEL controls are dropped; \n/\t/\r and ≥0x80
/// (UTF-8 text) are kept — except the C1 range: U+0080–U+009F encode
/// as 0xC2 0x80–0x9F and real terminals honor them (U+009B is CSI),
/// so the pair is dropped as well.
fn termSanitize(dst: []u8, src: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const b = src[i];
        if (b == 0xC2 and i + 1 < src.len and src[i + 1] >= 0x80 and src[i + 1] <= 0x9F) {
            i += 2;
            continue;
        }
        const ok = switch (b) {
            '\n', '\t', '\r' => true,
            0x7f => false,
            else => b >= 0x20,
        };
        if (ok) {
            dst[n] = b;
            n += 1;
        }
        i += 1;
    }
    return dst[0..n];
}

fn drainChild(da: DrainArgs) void {
    var rbuf: [8192]u8 = undefined;
    var r = da.file.reader(da.io, &rbuf);
    if (da.collect) |out| {
        _ = r.interface.streamRemaining(&out.writer) catch {};
    } else {
        var sbuf: [8192]u8 = undefined;
        var sw = std.Io.File.stderr().writer(da.io, &sbuf);
        var fbuf: [8192]u8 = undefined;
        // peekGreedy(1) = one underlying read — forward each chunk
        // sanitized instead of waiting to fill a large buffer.
        while (true) {
            const chunk = r.interface.peekGreedy(1) catch break;
            if (chunk.len == 0) break;
            r.interface.toss(chunk.len);
            sw.interface.writeAll(termSanitize(&fbuf, chunk)) catch break;
        }
        sw.interface.flush() catch {};
    }
}

fn execCmd(io: std.Io, alloc: Allocator, e: plan.Exec) !void {
    var argv_buf: std.ArrayList([]const u8) = .empty;
    if (e.chroot) {
        try argv_buf.appendSlice(alloc, &.{ "chroot", "/mnt/gentoo" });
    }
    try argv_buf.appendSlice(alloc, e.argv);
    var child = try std.process.spawn(io, .{
        .argv = argv_buf.items,
        .stdin = if (e.stdin != null) .pipe else .inherit,
        // The headless wire is stdout-only — child output must never
        // reach it. Both streams are piped: a secret-bearing stdin
        // means collect+redact before forwarding, otherwise stream
        // straight to stderr (bounded memory over a long install).
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var out_buf: std.Io.Writer.Allocating = .init(alloc);
    var err_buf: std.Io.Writer.Allocating = .init(alloc);
    const collect = e.stdin != null;
    var out_th: ?std.Thread = null;
    var err_th: ?std.Thread = null;
    // Both pipes need a live reader before stdin is written; if a
    // drain thread can't start, kill+reap — never wait on an
    // undrained child.
    const drain_failed = blk: {
        if (child.stdout) |cs|
            out_th = std.Thread.spawn(.{}, drainChild, .{DrainArgs{ .io = io, .file = cs, .collect = if (collect) &out_buf else null }}) catch break :blk true;
        if (child.stderr) |cs|
            err_th = std.Thread.spawn(.{}, drainChild, .{DrainArgs{ .io = io, .file = cs, .collect = if (collect) &err_buf else null }}) catch break :blk true;
        break :blk false;
    };
    if (drain_failed) {
        child.kill(io);
        _ = child.wait(io) catch {};
        return error.DrainFailed;
    }
    if (e.stdin) |data| {
        // Feed the payload, flush the buffered writer, then close so the
        // child sees EOF. Closing without flushing would discard bytes
        // still sitting in wbuf (short passphrases fit entirely).
        var wbuf: [4096]u8 = undefined;
        var fw = child.stdin.?.writer(io, &wbuf);
        var werr: ?anyerror = null;
        fw.interface.writeAll(data) catch |e2| {
            werr = e2;
        };
        if (werr == null) fw.interface.flush() catch |e2| {
            werr = e2;
        };
        child.stdin.?.close(io);
        child.stdin = null;
        if (werr) |e2| {
            _ = child.wait(io) catch {};
            if (out_th) |th| th.join();
            if (err_th) |th| th.join();
            return e2;
        }
    }
    const term = try child.wait(io);
    if (out_th) |th| th.join();
    if (err_th) |th| th.join();
    if (child.stdout) |cs| {
        cs.close(io);
        child.stdout = null;
    }
    if (child.stderr) |cs| {
        cs.close(io);
        child.stderr = null;
    }
    // Buffered output of a secret-bearing command: forward to stderr
    // with the stdin payload (and each of its lines) redacted — a tool
    // echoing its input must not leak a passphrase into logs.
    if (collect) {
        const data = e.stdin.?;
        var sebuf: [8192]u8 = undefined;
        var sew = std.Io.File.stderr().writer(io, &sebuf);
        var fbuf: [8192]u8 = undefined;
        for ([_][]const u8{ out_buf.written(), err_buf.written() }) |raw| {
            var body = raw;
            if (body.len == 0) continue;
            if (data.len > 0)
                body = std.mem.replaceOwned(u8, alloc, body, data, "[redacted]") catch body;
            var lit = std.mem.splitScalar(u8, data, '\n');
            while (lit.next()) |ln| {
                const t = std.mem.trim(u8, ln, " \t\r");
                if (t.len == 0) continue;
                body = std.mem.replaceOwned(u8, alloc, body, t, "[redacted]") catch body;
            }
            // same terminal-escape filter as the streaming drain
            var off: usize = 0;
            while (off < body.len) {
                const n = @min(body.len - off, fbuf.len);
                sew.interface.writeAll(termSanitize(&fbuf, body[off..][0..n])) catch break;
                off += n;
            }
        }
        sew.interface.flush() catch {};
    }
    switch (term) {
        .exited => |code| {
            if (code != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}

test "termSanitize drops C0/C1/DEL, keeps text and utf8" {
    var buf: [256]u8 = undefined;
    const out = termSanitize(&buf, "a\x1b[2kb\xc2\x9bPAYLOAD\xc2\xa0ok\x7f\x08\t\n");
    try std.testing.expectEqualStrings("a[2kbPAYLOAD\xc2\xa0ok\t\n", out);
}
