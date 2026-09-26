//! Executes a Plan, or prints it under --dry-run. Appends a JSONL
//! journal line per command so a real run can resume — the journal
//! lives on the live-env tmpfs and is consumed by `detect --repair`.

const std = @import("std");
const plan = @import("plan.zig");
const Allocator = std.mem.Allocator;

pub const Mode = enum { dry_run, exec };

pub const Options = struct {
    mode: Mode,
    /// Where the journal goes; null = journal disabled (default for
    /// dry runs).
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

    pub fn write(j: *Journal, comptime fmt: []const u8, args: anytype) void {
        const f = j.file orelse return;
        var buf: [4096]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
        f.writePositionalAll(j.io, line, 0) catch {}; // O_APPEND → offset ignored
        f.writePositionalAll(j.io, "\n", 0) catch {};
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
        if (skipped(step.id, opts.skip_steps)) continue;
        try out.print("[{d:0>2}] {s}  ({s})\n", .{ i + 1, step.title, step.id });
        for (step.cmds) |cmd| {
            switch (cmd) {
                .note => |n| try out.print("     note: {s}\n", .{n}),
                .write_file => |w| {
                    try out.print("     write {s} ({} bytes, {o})\n", .{ w.path, w.content.len, w.mode });
                    if (opts.mode == .exec) {
                        try writeFile(io, w.path, w.content, w.mode);
                    }
                },
                .exec => |e| {
                    try out.print("     $", .{});
                    if (e.chroot) try out.writeAll(" chroot /mnt/gentoo");
                    for (e.argv) |a| try out.print(" {s}", .{a});
                    if (e.stdin) |sin| try out.print("  <stdin:{s}>", .{sin});
                    if (e.desc.len > 0) try out.print("    # {s}", .{e.desc});
                    try out.writeAll("\n");
                    journal.write("{{\"step\":\"{s}\",\"argv\":\"", .{step.id});
                    if (opts.mode == .exec) {
                        try execCmd(io, alloc, e);
                        journal.write("exec done", .{});
                    }
                },
            }
        }
        journal.write("{{\"step\":\"{s}\",\"status\":\"done\"}}", .{step.id});
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
    var child = try std.process.spawn(io, .{ .argv = argv_buf.items });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| {
            if (code != 0) return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}
