//! Executes a Plan, or prints it under --dry-run. Appends one complete
//! JSONL journal record per command so a real run can resume — the
//! journal lives on the live-env tmpfs and is consumed by
//! `detect --repair`. stdin payloads are never journaled or printed.

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
            continue;
        }
        try out.print("[{d:0>2}] {s}  ({s})\n", .{ i + 1, step.title, step.id });
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
                            return err;
                        };
                        journal.cmdExec(step.id, e, "ok");
                    }
                },
            }
        }
        journal.stepDone(step.id, false);
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

fn execCmd(io: std.Io, alloc: Allocator, e: plan.Exec) !void {
    var argv_buf: std.ArrayList([]const u8) = .empty;
    if (e.chroot) {
        try argv_buf.appendSlice(alloc, &.{ "chroot", "/mnt/gentoo" });
    }
    try argv_buf.appendSlice(alloc, e.argv);
    var child = try std.process.spawn(io, .{
        .argv = argv_buf.items,
        .stdin = if (e.stdin != null) .pipe else .inherit,
    });
    if (e.stdin) |data| {
        // Feed the payload, flush the buffered writer, then close so the
        // child sees EOF. Closing without flushing would discard bytes
        // still sitting in wbuf (short passphrases fit entirely).
        var wbuf: [4096]u8 = undefined;
        var fw = child.stdin.?.writer(io, &wbuf);
        var werr: ?anyerror = null;
        fw.interface.writeAll(data) catch |e2| { werr = e2; };
        if (werr == null) fw.interface.flush() catch |e2| { werr = e2; };
        child.stdin.?.close(io);
        child.stdin = null;
        if (werr) |e2| {
            _ = child.wait(io) catch {};
            return e2;
        }
    }
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}
