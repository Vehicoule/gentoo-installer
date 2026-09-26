//! Distro preset handling: a preset.toml supplies `[defaults]` that sit
//! underneath the user config, `[locks]` that fix values outright, and
//! package sets/branding. M1 implements load + defaults-merge; lock
//! enforcement via validation errors when a locked key differs.

const std = @import("std");
const toml = @import("toml.zig");
const Allocator = std.mem.Allocator;

pub const Preset = struct {
    id: []const u8 = "gentoo",
    name: []const u8 = "Gentoo",
    doc: toml.Document,
    /// Locked dotted paths inside the effective config (e.g.
    /// "system.init"). The wizard hides them; VALIDATE rejects configs
    /// that diverge from the locked default.
    locks: []const []const u8 = &.{},

    pub fn deinit(p: *Preset) void {
        p.doc.deinit();
    }
};

pub const LoadError = error{ BadPreset, InvalidToml, OutOfMemory };

pub fn load(alloc: Allocator, path: []const u8, io: std.Io) LoadError!Preset {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(4 << 20)) catch
        return error.BadPreset;
    var perr: toml.ParseError = undefined;
    const doc = toml.parse(alloc, text, &perr) catch |e| {
        if (e == error.InvalidToml)
            std.log.err("preset {s}:{}: {s}", .{ path, perr.line, perr.msg });
        return e;
    };
    var p: Preset = .{ .doc = doc };
    if (doc.root.get("id")) |v| {
        if (v == .string) p.id = v.string;
    }
    if (doc.root.get("name")) |v| {
        if (v == .string) p.name = v.string;
    }
    if (doc.root.get("locks")) |v| {
        if (v == .table) {
            var locks: std.ArrayList([]const u8) = .empty;
            var it = v.table.iterator();
            while (it.next()) |kv| try locks.append(alloc, kv.key_ptr.*);
            p.locks = locks.items;
        }
    }
    return p;
}

/// Merge preset `[defaults]` under the user document: user keys win,
/// recursing into tables. Both documents share the user's arena — the
/// preset's tree is *copied in* so the preset can be freed after.
pub fn mergeDefaults(preset: *const Preset, user_doc: *toml.Document) !void {
    const defaults = blk: {
        const v = preset.doc.root.get("defaults") orelse return;
        break :blk switch (v) {
            .table => |t| t,
            else => return,
        };
    };
    const alloc = user_doc.arena.allocator();
    try mergeTable(alloc, &user_doc.root, defaults);
}

fn mergeTable(alloc: Allocator, dst: *toml.Value.Table, src: toml.Value.Table) !void {
    var it = src.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const val = kv.value_ptr.*;
        const gop = try dst.getOrPut(alloc, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = try deepCopy(alloc, val);
            continue;
        }
        // User key exists — recurse when both are tables.
        if (val == .table and gop.value_ptr.* == .table)
            try mergeTable(alloc, &gop.value_ptr.table, val.table);
    }
}

fn deepCopy(alloc: Allocator, v: toml.Value) !toml.Value {
    return switch (v) {
        .table => |t| blk: {
            var nt: toml.Value.Table = .empty;
            var it = t.iterator();
            while (it.next()) |kv|
                try nt.put(alloc, try alloc.dupe(u8, kv.key_ptr.*), try deepCopy(alloc, kv.value_ptr.*));
            break :blk .{ .table = nt };
        },
        .array => |a| blk: {
            const na = try alloc.alloc(toml.Value, a.len);
            for (a, 0..) |item, i| na[i] = try deepCopy(alloc, item);
            break :blk .{ .array = na };
        },
        .string => |str| .{ .string = try alloc.dupe(u8, str) },
        else => v,
    };
}

test "defaults merge" {
    const alloc = std.testing.allocator;
    const preset_src =
        \\id = "test"
        \\[defaults.system]
        \\init = "dinit"
        \\hostname = "preset-host"
    ;
    const pdoc = try toml.parse(alloc, preset_src, null);
    var p: Preset = .{ .doc = pdoc };
    defer p.deinit();

    var udoc = try toml.parse(alloc,
        \\[system]
        \\hostname = "user-host"
    , null);
    defer udoc.deinit();

    try mergeDefaults(&p, &udoc);
    const sys = udoc.root.get("system").?.table;
    try std.testing.expectEqualStrings("user-host", sys.get("hostname").?.string);
    try std.testing.expectEqualStrings("dinit", sys.get("init").?.string);
}
