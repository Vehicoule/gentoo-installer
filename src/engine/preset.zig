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
    // Accept a preset directory (containing preset.toml) or a file path.
    var file_path = path;
    if (std.Io.Dir.cwd().openDir(io, path, .{}) catch null) |dir| {
        dir.close(io);
        file_path = std.fmt.allocPrint(alloc, "{s}/preset.toml", .{path}) catch return error.OutOfMemory;
    }
    const text = std.Io.Dir.cwd().readFileAlloc(io, file_path, alloc, .limited(4 << 20)) catch
        return error.BadPreset;
    var perr: toml.ParseError = undefined;
    const doc = toml.parse(alloc, text, &perr) catch |e| {
        if (e == error.InvalidToml)
            std.log.err("preset {s}:{}: {s}", .{ file_path, perr.line, perr.msg });
        return e;
    };
    var p: Preset = .{ .doc = doc };
    if (doc.root.get("id")) |v| {
        if (v == .string) p.id = v.string;
    }
    if (doc.root.get("name")) |v| {
        if (v == .string) p.name = v.string;
    }
    // [locks] fields = ["system.init", ...]
    if (doc.root.get("locks")) |v| {
        if (v == .table) {
            if (v.table.get("fields")) |f| {
                if (f == .array) {
                    var locks: std.ArrayList([]const u8) = .empty;
                    for (f.array) |item| {
                        if (item == .string) try locks.append(alloc, item.string);
                    }
                    p.locks = locks.items;
                }
            }
        }
    }
    return p;
}

/// Enforce [locks]: for each locked dotted path, the user document may
/// either leave it unset (preset default fills it) or set exactly the
/// preset's [defaults] value. Divergence is a validation error.
pub fn checkLocks(alloc: Allocator, preset: *const Preset, user_doc: *const toml.Document) ![][]const u8 {
    var errs: std.ArrayList([]const u8) = .empty;
    const defaults = blk: {
        const v = preset.doc.root.get("defaults") orelse return errs.items;
        break :blk switch (v) {
            .table => |t| t,
            else => return errs.items,
        };
    };
    for (preset.locks) |path| {
        const want = lookup(defaults, path) orelse continue;
        const got = lookup(user_doc.root, path);
        if (got == null) continue; // unset → default wins, fine
        if (!valueEq(got.?, want))
            try errs.append(alloc, std.fmt.allocPrint(alloc,
                "preset lock: '{s}' is fixed by preset '{s}' — remove it or match the preset default",
                .{ path, preset.id }) catch @panic("oom"));
    }
    return errs.items;
}

pub const ResolvedSets = struct {
    atoms: [][]const u8,
    repos: [][]const u8,
};

/// Resolve `packages.sets` names against the preset's [[package_sets]]
/// (id → atoms + repos, honouring `extends`). `names == null` means the
/// config left `sets` unset → the preset's `default = true` sets apply;
/// an explicit `sets = []` selects nothing. Unknown names are a
/// validation-style error list the caller surfaces.
pub fn resolveSets(alloc: Allocator, preset: ?*const Preset, names: ?[]const []const u8) !struct { resolved: ResolvedSets, errs: [][]const u8 } {
    var atoms: std.ArrayList([]const u8) = .empty;
    var repos: std.ArrayList([]const u8) = .empty;
    // dedupe atoms/repos across extends chains (a child may restate
    // parent entries)
    var atoms_seen: std.StringHashMap(void) = .init(alloc);
    var repos_seen: std.StringHashMap(void) = .init(alloc);
    defer atoms_seen.deinit();
    defer repos_seen.deinit();
    var errs: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMap(void) = .init(alloc);
    defer seen.deinit();

    // No preset → set ids are unresolvable (they're preset-defined
    // vocabulary). Naming sets without --preset is a config error;
    // leaving them unset resolves to nothing.
    if (preset == null) {
        if (names) |ns| {
            for (ns) |name|
                try errs.append(alloc, std.fmt.allocPrint(alloc, "packages.sets: '{s}' needs --preset (set ids are preset-defined)", .{name}) catch @panic("oom"));
        }
        return .{ .resolved = .{ .atoms = &.{}, .repos = &.{} }, .errs = errs.items };
    }
    const sets_table: ?[]toml.Value = blk: {
        const p = preset.?;
        const v = p.doc.root.get("package_sets") orelse break :blk null;
        break :blk switch (v) {
            .array => |a| a,
            else => null,
        };
    };

    // `sets` absent from config → the preset's `default = true` sets
    // apply. An explicit `sets = []` selects nothing.
    var defaults: std.ArrayList([]const u8) = .empty;
    const effective = if (names) |ns| ns else blk: {
        if (sets_table) |arr| {
            for (arr) |v| {
                if (v != .table) continue;
                const d = v.table.get("default") orelse continue;
                if (d != .boolean or !d.boolean) continue;
                const iv = v.table.get("id") orelse continue;
                if (iv == .string) try defaults.append(alloc, iv.string);
            }
        }
        break :blk defaults.items;
    };

    for (effective) |name| {
        var stack: std.ArrayList([]const u8) = .empty;
        try stack.append(alloc, name);
        while (stack.pop()) |cur| {
            if (seen.contains(cur)) continue;
            try seen.put(cur, {});
            const set = findSet(sets_table, cur) orelse {
                try errs.append(alloc, std.fmt.allocPrint(alloc, "packages.sets: unknown set '{s}'", .{cur}) catch @panic("oom"));
                continue;
            };
            if (set.get("atoms")) |a| {
                if (a == .array)
                    for (a.array) |item| {
                        if (item == .string and !atoms_seen.contains(item.string)) {
                            try atoms_seen.put(item.string, {});
                            try atoms.append(alloc, item.string);
                        }
                    };
            }
            if (set.get("repos")) |a| {
                if (a == .array)
                    for (a.array) |item| {
                        if (item == .string and !repos_seen.contains(item.string)) {
                            try repos_seen.put(item.string, {});
                            try repos.append(alloc, item.string);
                        }
                    };
            }
            if (set.get("extends")) |e| {
                if (e == .string) try stack.append(alloc, e.string);
            }
        }
    }
    return .{ .resolved = .{ .atoms = atoms.items, .repos = repos.items }, .errs = errs.items };
}

fn findSet(sets: ?[]toml.Value, id: []const u8) ?toml.Value.Table {
    const arr = sets orelse return null;
    for (arr) |v| {
        if (v != .table) continue;
        if (v.table.get("id")) |iv| {
            if (iv == .string and std.mem.eql(u8, iv.string, id)) return v.table;
        }
    }
    return null;
}

fn lookup(root: toml.Value.Table, dotted: []const u8) ?toml.Value {
    var cur = root;
    var it = std.mem.splitScalar(u8, dotted, '.');
    while (it.next()) |seg| {
        const v = cur.get(seg) orelse return null;
        if (it.peek() == null) return v;
        cur = switch (v) {
            .table => |t| t,
            else => return null,
        };
    }
    return null;
}

fn valueEq(a: toml.Value, b: toml.Value) bool {
    return switch (a) {
        .string => |as| b == .string and std.mem.eql(u8, as, b.string),
        .integer => |ai| b == .integer and ai == b.integer,
        .float => |af| b == .float and af == b.float,
        .boolean => |ab| b == .boolean and ab == b.boolean,
        .array => |aa| blk: {
            if (b != .array or aa.len != b.array.len) break :blk false;
            for (aa, b.array) |x, y| if (!valueEq(x, y)) break :blk false;
            break :blk true;
        },
        .table => false,
    };
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
        // key slices live in the preset's arena — dupe into ours.
        const gop = try dst.getOrPut(alloc, try alloc.dupe(u8, key));
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
