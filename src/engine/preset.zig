//! Distro preset handling: a preset.toml supplies `[defaults]` that sit
//! underneath the user config, `[locks]` that fix values outright, and
//! package sets/branding. M1 implements load + defaults-merge; lock
//! enforcement via validation errors when a locked key differs.

const std = @import("std");
const toml = @import("toml.zig");
const Allocator = std.mem.Allocator;

/// A [[repos]] overlay entry: `eselect repository enable <name>` when
/// sync_uri is null; otherwise the engine writes a repos.conf file and
/// syncs it directly (upstream eselect doesn't know the repo).
pub const Repo = struct {
    name: []const u8,
    sync_uri: ?[]const u8 = null,
};

/// A [[extra_steps]] pipeline extension. `script` is the file's
/// *contents*, read at preset load (assets resolve against dir).
pub const ExtraStep = struct {
    name: []const u8,
    after: []const u8,
    description: []const u8 = "",
    skippable: bool = false,
    script: []const u8,
};

pub const Preset = struct {
    id: []const u8 = "gentoo",
    name: []const u8 = "Gentoo",
    doc: toml.Document,
    /// Locked dotted paths inside the effective config (e.g.
    /// "system.init"). The wizard hides them; VALIDATE rejects configs
    /// that diverge from the locked default.
    locks: []const []const u8 = &.{},
    /// Directory the preset.toml lives in (script assets resolve here).
    dir: []const u8 = "",
    repos: []const Repo = &.{},
    extra_steps: []const ExtraStep = &.{},
    /// [hooks].post_install script contents — runs last in the chroot,
    /// before the finish step unmounts.
    post_install: ?[]const u8 = null,
    engine_min: ?[]const u8 = null,

    pub fn deinit(p: *Preset) void {
        p.doc.deinit();
    }
};

pub const LoadError = error{ BadPreset, InvalidToml, OutOfMemory };

fn presetErr(comptime fmt: []const u8, args: anytype) LoadError {
    std.log.err("preset: " ++ fmt, args);
    return error.BadPreset;
}

/// Read a script asset relative to the preset dir; refuse missing,
/// non-executable, or escaping paths rather than half-applying.
fn loadScript(alloc: Allocator, dir: std.Io.Dir, io: std.Io, where: []const u8, rel: []const u8) LoadError![]const u8 {
    if (rel.len == 0 or rel[0] == '/' or rel[0] == '\\')
        return presetErr("{s}: script path '{s}' must be relative to the preset dir", .{ where, rel });
    {
        var it = std.mem.splitScalar(u8, rel, '/');
        while (it.next()) |seg|
            if (std.mem.eql(u8, seg, "..")) return presetErr("{s}: script path '{s}' escapes the preset dir", .{ where, rel });
    }
    // No symlink component may leave the preset dir: stat each segment
    // without following, so a shipped link to an outside file refuses.
    var rest = rel;
    while (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        const comp = rest[0..slash];
        const cst = dir.statFile(io, comp, .{ .follow_symlinks = false }) catch
            return presetErr("{s}: script '{s}' not found", .{ where, rel });
        if (cst.kind == .sym_link)
            return presetErr("{s}: script path '{s}' contains a symlink", .{ where, rel });
        rest = rest[slash + 1 ..];
    }
    const st = dir.statFile(io, rel, .{ .follow_symlinks = false }) catch
        return presetErr("{s}: script '{s}' not found", .{ where, rel });
    if (st.kind == .sym_link)
        return presetErr("{s}: script '{s}' is a symlink", .{ where, rel });
    if (st.kind != .file)
        return presetErr("{s}: script '{s}' is not a regular file", .{ where, rel });
    if (st.permissions.toMode() & 0o111 == 0)
        return presetErr("{s}: script '{s}' is not executable", .{ where, rel });
    return dir.readFileAlloc(io, rel, alloc, .limited(4 << 20)) catch
        presetErr("{s}: cannot read script '{s}'", .{ where, rel });
}

pub fn load(alloc: Allocator, path: []const u8, io: std.Io) LoadError!Preset {
    // Accept a preset directory (containing preset.toml) or a file path.
    var file_path = path;
    var dir_path: []const u8 = ".";
    if (std.Io.Dir.cwd().openDir(io, path, .{}) catch null) |dir| {
        dir.close(io);
        dir_path = path;
        file_path = std.fmt.allocPrint(alloc, "{s}/preset.toml", .{path}) catch return error.OutOfMemory;
    } else if (std.fs.path.dirname(path)) |d| dir_path = d;
    var preset_dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch
        return error.BadPreset;
    defer preset_dir.close(io);
    const text = std.Io.Dir.cwd().readFileAlloc(io, file_path, alloc, .limited(4 << 20)) catch
        return error.BadPreset;
    var perr: toml.ParseError = undefined;
    const doc = toml.parse(alloc, text, &perr) catch |e| {
        if (e == error.InvalidToml)
            std.log.err("preset {s}:{}: {s}", .{ file_path, perr.line, perr.msg });
        return e;
    };
    var p: Preset = .{ .doc = doc, .dir = dir_path };
    // identity lives in the [preset] table (presets/*.toml); bare-root
    // id/name accepted for hand-written minimal presets.
    const ident: *const toml.Value.Table = if (doc.root.get("preset")) |v|
        (if (v == .table) &v.table else &doc.root)
    else
        &doc.root;
    if (ident.get("id")) |v| {
        if (v == .string) p.id = v.string;
    }
    if (ident.get("name")) |v| {
        if (v == .string) p.name = v.string;
    }
    if (ident.get("engine_min")) |v| {
        if (v == .string) p.engine_min = v.string;
    }
    // [locks] fields = ["system.init", ...] — each must have a matching
    // [defaults] value or the lock can never be satisfied.
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
    const defaults_tbl: ?toml.Value.Table = blk: {
        const v = doc.root.get("defaults") orelse break :blk null;
        break :blk switch (v) {
            .table => |t| t,
            else => null,
        };
    };
    for (p.locks) |lock_path| {
        const has_default = if (defaults_tbl) |d| lookup(d, lock_path) != null else false;
        if (!has_default)
            return presetErr("[locks] '{s}' has no matching [defaults] value", .{lock_path});
    }
    // [[repos]] name + optional sync_uri (git URI for a direct sync).
    if (doc.root.get("repos")) |v| {
        if (v == .array) {
            var repos: std.ArrayList(Repo) = .empty;
            for (v.array) |item| {
                if (item != .table) continue;
                const nv = item.table.get("name") orelse continue;
                if (nv != .string) continue;
                if (!nameOk(nv.string))
                    return presetErr("repo name '{s}' must be [A-Za-z0-9_-]+", .{nv.string});
                var r: Repo = .{ .name = nv.string };
                if (item.table.get("sync_uri")) |sv| {
                    if (sv != .string)
                        return presetErr("repo '{s}': sync_uri must be a string", .{r.name});
                    if (sv.string.len != 0) {
                        if (!uriOk(sv.string))
                            return presetErr("repo '{s}': sync_uri must be a single-token https:// URI", .{r.name});
                        r.sync_uri = sv.string;
                    }
                    // "" = eselect enable
                }
                try repos.append(alloc, r);
            }
            p.repos = repos.items;
        }
    }
    // [[extra_steps]] journaled pipeline extensions.
    if (doc.root.get("extra_steps")) |v| {
        if (v == .array) {
            var exs: std.ArrayList(ExtraStep) = .empty;
            for (v.array) |item| {
                if (item != .table) continue;
                const t = item.table;
                const nv = t.get("name") orelse return presetErr("extra_steps entry missing 'name'", .{});
                if (nv != .string) return presetErr("extra_steps: 'name' must be a string", .{});
                if (!nameOk(nv.string))
                    return presetErr("extra_steps name '{s}' must be [A-Za-z0-9_-]+", .{nv.string});
                for (exs.items) |e2|
                    if (std.mem.eql(u8, e2.name, nv.string))
                        return presetErr("duplicate extra_steps name '{s}'", .{nv.string});
                const av = t.get("after") orelse return presetErr("extra_steps '{s}': missing 'after'", .{nv.string});
                if (av != .string) return presetErr("extra_steps '{s}': 'after' must be a string", .{nv.string});
                const sv = t.get("script") orelse return presetErr("extra_steps '{s}': missing 'script'", .{nv.string});
                if (sv != .string) return presetErr("extra_steps '{s}': 'script' must be a string", .{nv.string});
                var ex: ExtraStep = .{
                    .name = nv.string,
                    .after = av.string,
                    .script = try loadScript(alloc, preset_dir, io, "extra_steps", sv.string),
                };
                if (t.get("description")) |dv| {
                    if (dv == .string) ex.description = dv.string;
                }
                if (t.get("skippable")) |bv| {
                    if (bv == .boolean) ex.skippable = bv.boolean;
                }
                try exs.append(alloc, ex);
            }
            p.extra_steps = exs.items;
        }
    }
    // [hooks] post_install = "scripts/x.sh"
    if (doc.root.get("hooks")) |v| {
        if (v == .table) {
            if (v.table.get("post_install")) |hv| {
                if (hv == .string)
                    p.post_install = try loadScript(alloc, preset_dir, io, "hooks.post_install", hv.string);
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
    const defaults: ?toml.Value.Table = blk: {
        const v = preset.doc.root.get("defaults") orelse break :blk null;
        break :blk switch (v) {
            .table => |t| t,
            else => null,
        };
    };
    for (preset.locks) |path| {
        const want = (if (defaults) |d| lookup(d, path) else null) orelse {
            // A lock with no default can't be satisfied — the preset is
            // malformed, not the config.
            try errs.append(alloc, std.fmt.allocPrint(alloc, "preset lock: '{s}' has no matching [defaults] value", .{path}) catch @panic("oom"));
            continue;
        };
        const got = lookup(user_doc.root, path);
        if (got == null) continue; // unset → default wins, fine
        if (!valueEq(got.?, want))
            try errs.append(alloc, std.fmt.allocPrint(alloc, "preset lock: '{s}' is fixed by preset '{s}' — remove it or match the preset default", .{ path, preset.id }) catch @panic("oom"));
    }
    return errs.items;
}

pub const ResolvedSets = struct {
    atoms: [][]const u8,
    repos: []const Repo,
};

fn findRepo(preset: *const Preset, name: []const u8) Repo {
    for (preset.repos) |r|
        if (std.mem.eql(u8, r.name, name)) return r;
    // Not declared in [[repos]] — a repo eselect knows already.
    return .{ .name = name };
}

/// A URI headed for a repos.conf line: https://, ASCII printable only —
/// no whitespace, controls, or high bytes (a newline would inject extra
/// Portage directives; raw UTF-8 must arrive percent-encoded anyway).
fn uriOk(u: []const u8) bool {
    if (!std.mem.startsWith(u8, u, "https://")) return false;
    if (u.len <= "https://".len) return false;
    for (u) |ch|
        if (ch <= ' ' or ch >= 0x7f) return false;
    return true;
}

/// Names that land in paths / ini section headers — keep them tame.
fn nameOk(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch|
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

/// Dotted-numeric version compare: have < want. `want` must be fully
/// dotted-numeric — a malformed engine_min refuses. An unparseable `have`
/// component also fails closed (treated as "too old").
pub fn versionLt(have: []const u8, want: []const u8) bool {
    {
        var wi = std.mem.splitScalar(u8, want, '.');
        var n: usize = 0;
        while (wi.next()) |w| {
            n += 1;
            if (w.len == 0) return true;
            _ = std.fmt.parseInt(u32, w, 10) catch return true;
        }
        if (n == 0) return true;
    }
    var hi = std.mem.splitScalar(u8, have, '.');
    var wi2 = std.mem.splitScalar(u8, want, '.');
    while (true) {
        const h = hi.next();
        const w = wi2.next();
        if (h == null and w == null) return false;
        const hn = std.fmt.parseInt(u32, h orelse "0", 10) catch return true;
        const wn = std.fmt.parseInt(u32, w orelse "0", 10) catch unreachable;
        if (hn != wn) return hn < wn;
    }
}

/// Resolve `packages.sets` names against the preset's [[package_sets]]
/// (id → atoms + repos, honouring `extends`). `names == null` means the
/// config left `sets` unset → the preset's `default = true` sets apply;
/// an explicit `sets = []` selects nothing. Unknown names are a
/// validation-style error list the caller surfaces.
pub fn resolveSets(alloc: Allocator, preset: ?*const Preset, names: ?[]const []const u8) !struct { resolved: ResolvedSets, errs: [][]const u8 } {
    var atoms: std.ArrayList([]const u8) = .empty;
    var repos: std.ArrayList(Repo) = .empty;
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
                            if (!pkgTokenOk(item.string)) {
                                try errs.append(alloc, std.fmt.allocPrint(alloc, "packages.sets '{s}': atom '{s}' must not start with '-' or contain whitespace", .{ cur, item.string }) catch @panic("oom"));
                                continue;
                            }
                            try atoms_seen.put(item.string, {});
                            try atoms.append(alloc, item.string);
                        }
                    };
            }
            if (set.get("repos")) |a| {
                if (a == .array)
                    for (a.array) |item| {
                        if (item == .string and !repos_seen.contains(item.string)) {
                            if (!pkgTokenOk(item.string)) {
                                try errs.append(alloc, std.fmt.allocPrint(alloc, "packages.sets '{s}': repo '{s}' must not start with '-' or contain whitespace", .{ cur, item.string }) catch @panic("oom"));
                                continue;
                            }
                            try repos_seen.put(item.string, {});
                            try repos.append(alloc, findRepo(preset.?, item.string));
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

// Set entries land on emerge/eselect argv — a leading '-' would be a
// flag and whitespace would split into extra args.
fn pkgTokenOk(v: []const u8) bool {
    if (v.len == 0 or v.len > 128 or v[0] == '-') return false;
    for (v) |ch| {
        if (ch <= ' ' or ch == 0x7f) return false;
    }
    return true;
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

pub fn lookup(root: toml.Value.Table, dotted: []const u8) ?toml.Value {
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

pub fn valueEq(a: toml.Value, b: toml.Value) bool {
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
        .table => |at| blk: {
            if (b != .table) break :blk false;
            const bt = b.table;
            if (at.count() != bt.count()) break :blk false;
            var it = at.iterator();
            while (it.next()) |kv|
                if (!valueEq(kv.value_ptr.*, bt.get(kv.key_ptr.*) orelse break :blk false)) break :blk false;
            break :blk true;
        },
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

test "versionLt dotted compare" {
    try std.testing.expect(!versionLt("1.0.0", "1.0.0"));
    try std.testing.expect(versionLt("1.0.0", "1.0.1"));
    try std.testing.expect(versionLt("0.9", "1.0"));
    try std.testing.expect(!versionLt("1.0", "1.0.0"));
    try std.testing.expect(versionLt("1.0", "1.0.1"));
    try std.testing.expect(versionLt("1.0.0", "bogus")); // unparseable want → refuse
    try std.testing.expect(versionLt("1.0.0", "0.9.bogus")); // trailing junk → refuse
    try std.testing.expect(versionLt("1.0.0", "0.9.")); // empty component → refuse
    try std.testing.expect(versionLt("bogus", "0.9")); // unparseable have → refuse
    try std.testing.expect(versionLt("1.0.0", "")); // empty → refuse
}

test "resolveSets maps repos to [[repos]] sync_uri" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const src =
        \\[[repos]]
        \\name = "mine"
        \\sync_uri = "https://git.example/mine.git"
        \\[[package_sets]]
        \\id = "s1"
        \\atoms = ["app-misc/foo"]
        \\repos = ["mine", "gentoo-known"]
    ;
    const doc = try toml.parse(alloc, src, null);
    var p: Preset = .{ .doc = doc };
    p.repos = &.{.{ .name = "mine", .sync_uri = "https://git.example/mine.git" }};
    defer p.deinit();
    const rs = try resolveSets(alloc, &p, &.{"s1"});
    try std.testing.expectEqual(0, rs.errs.len);
    try std.testing.expectEqual(2, rs.resolved.repos.len);
    try std.testing.expectEqualStrings("https://git.example/mine.git", rs.resolved.repos[0].sync_uri.?);
    try std.testing.expectEqualStrings("gentoo-known", rs.resolved.repos[1].name);
    try std.testing.expect(rs.resolved.repos[1].sync_uri == null);
}
