//! Minimal TOML parser covering the schema used by install configs and
//! distro presets: tables, [[array-of-tables]], dotted keys, strings
//! (basic and literal), integers, floats, booleans, arrays, and inline
//! tables. Multi-line strings and exotic int bases are not supported —
//! the config schema does not use them.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []Value,
    table: Table,

    pub const Table = std.StringHashMapUnmanaged(Value);

    pub fn get(v: Value, key: []const u8) ?Value {
        return switch (v) {
            .table => |t| t.get(key),
            else => null,
        };
    }
};

pub const Error = error{
    InvalidToml,
    OutOfMemory,
};

pub const ParseError = struct {
    line: usize,
    col: usize,
    msg: []const u8,
};

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,
    alloc: Allocator,
    err_line: usize = 0,
    err_col: usize = 0,
    err_msg: []const u8 = "",
    err_out: ?*ParseError = null,

    fn fail(p: *Parser, msg: []const u8) Error {
        p.err_line = p.line;
        p.err_col = p.pos;
        p.err_msg = msg;
        if (p.err_out) |eo| eo.* = .{ .line = p.line, .col = p.pos, .msg = msg };
        return error.InvalidToml;
    }

    fn peek(p: *Parser) ?u8 {
        if (p.pos >= p.src.len) return null;
        return p.src[p.pos];
    }

    fn peekAt(p: *Parser, off: usize) ?u8 {
        if (p.pos + off >= p.src.len) return null;
        return p.src[p.pos + off];
    }

    fn advance(p: *Parser) void {
        if (p.pos < p.src.len) {
            if (p.src[p.pos] == '\n') p.line += 1;
            p.pos += 1;
        }
    }

    fn skipSpaces(p: *Parser) void {
        while (p.peek()) |c| {
            if (c == ' ' or c == '\t') p.advance() else break;
        }
    }

    fn skipWhitespaceAndComments(p: *Parser) void {
        while (p.peek()) |c| {
            switch (c) {
                ' ', '\t', '\r', '\n' => p.advance(),
                '#' => {
                    while (p.peek()) |cc| {
                        if (cc == '\n') break;
                        p.advance();
                    }
                },
                else => return,
            }
        }
    }

    fn parseKeyPath(p: *Parser, buf: *std.ArrayList([]const u8)) Error!void {
        while (true) {
            p.skipSpaces();
            const c = p.peek() orelse return p.fail("expected key");
            if (c == '"' or c == '\'') {
                // quoted key (e.g. a package atom "sys-kernel/x")
                const seg = if (c == '"') try p.parseBasicString() else try p.parseLiteralString();
                try buf.append(p.alloc, seg);
            } else {
                const start = p.pos;
                while (p.peek()) |kc| {
                    if (std.ascii.isAlphanumeric(kc) or kc == '_' or kc == '-')
                        p.advance()
                    else
                        break;
                }
                if (p.pos == start) return p.fail("expected key");
                try buf.append(p.alloc, p.src[start..p.pos]);
            }
            p.skipSpaces();
            if (p.peek() == @as(u8, '.')) {
                p.advance();
                continue;
            }
            return;
        }
    }

    /// Resolve a dotted key path under `table`, creating intermediate
    /// tables. Returns the leaf table the last component belongs to,
    /// along with the leaf key.
    fn descend(p: *Parser, root: *Value.Table, path: []const []const u8) Error!struct { table: *Value.Table, key: []const u8 } {
        var table = root;
        for (path[0 .. path.len - 1]) |seg| {
            const gop = try table.getOrPut(p.alloc, seg);
            if (!gop.found_existing) gop.value_ptr.* = .{ .table = .empty };
            switch (gop.value_ptr.*) {
                .table => |*t| table = t,
                else => return p.fail("key conflicts with existing non-table value"),
            }
        }
        return .{ .table = table, .key = path[path.len - 1] };
    }

    fn parseValue(p: *Parser) Error!Value {
        p.skipSpaces();
        const c = p.peek() orelse return p.fail("expected value");
        switch (c) {
            '"' => return .{ .string = try p.parseBasicString() },
            '\'' => return .{ .string = try p.parseLiteralString() },
            '[' => return .{ .array = try p.parseArray() },
            '{' => return .{ .table = try p.parseInlineTable() },
            't', 'f' => {
                if (p.src.len >= p.pos + 4 and std.mem.eql(u8, p.src[p.pos .. p.pos + 4], "true")) {
                    p.pos += 4;
                    return .{ .boolean = true };
                }
                if (p.src.len >= p.pos + 5 and std.mem.eql(u8, p.src[p.pos .. p.pos + 5], "false")) {
                    p.pos += 5;
                    return .{ .boolean = false };
                }
                return p.fail("invalid boolean");
            },
            else => return p.parseNumber(),
        }
    }

    fn parseBasicString(p: *Parser) Error![]const u8 {
        p.advance(); // opening "
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = p.peek() orelse return p.fail("unterminated string");
            if (c == '"') {
                p.advance();
                return out.items;
            }
            if (c == '\\') {
                p.advance();
                const esc = p.peek() orelse return p.fail("unterminated escape");
                p.advance();
                switch (esc) {
                    'n' => try out.append(p.alloc, '\n'),
                    't' => try out.append(p.alloc, '\t'),
                    'r' => try out.append(p.alloc, '\r'),
                    '"' => try out.append(p.alloc, '"'),
                    '\\' => try out.append(p.alloc, '\\'),
                    'u' => {
                        var code: u21 = 0;
                        var i: usize = 0;
                        while (i < 4) : (i += 1) {
                            const h = p.peek() orelse return p.fail("bad \\u escape");
                            const d = std.fmt.charToDigit(h, 16) catch return p.fail("bad \\u escape");
                            code = code * 16 + d;
                            p.advance();
                        }
                        var utf8_buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(code, &utf8_buf) catch return p.fail("bad unicode escape");
                        try out.appendSlice(p.alloc, utf8_buf[0..n]);
                    },
                    else => return p.fail("unsupported escape"),
                }
            } else {
                try out.append(p.alloc, c);
                p.advance();
            }
        }
    }

    fn parseLiteralString(p: *Parser) Error![]const u8 {
        p.advance(); // opening '
        const start = p.pos;
        while (p.peek()) |c| {
            if (c == '\'') {
                const s = p.src[start..p.pos];
                p.advance();
                return s;
            }
            p.advance();
        }
        return p.fail("unterminated literal string");
    }

    fn parseNumber(p: *Parser) Error!Value {
        const start = p.pos;
        if (p.peek()) |c| {
            if (c == '-' or c == '+') p.advance();
        }
        var is_float = false;
        while (p.peek()) |c| {
            switch (c) {
                '0'...'9' => p.advance(),
                '.', 'e', 'E' => {
                    is_float = true;
                    p.advance();
                },
                '_', '+', '-' => p.advance(),
                else => break,
            }
        }
        const text = p.src[start..p.pos];
        if (text.len == 0 or std.mem.eql(u8, text, "-") or std.mem.eql(u8, text, "+"))
            return p.fail("expected number");
        const stripped = try std.mem.replaceOwned(u8, p.alloc, text, "_", "");
        if (is_float)
            return .{ .float = std.fmt.parseFloat(f64, stripped) catch return p.fail("bad float") };
        return .{ .integer = std.fmt.parseInt(i64, stripped, 10) catch return p.fail("bad integer") };
    }

    fn parseArray(p: *Parser) Error![]Value {
        p.advance(); // [
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            p.skipWhitespaceAndComments();
            const c = p.peek() orelse return p.fail("unterminated array");
            if (c == ']') {
                p.advance();
                return items.items;
            }
            try items.append(p.alloc, try p.parseValue());
            p.skipWhitespaceAndComments();
            const sep = p.peek() orelse return p.fail("unterminated array");
            if (sep == ',') {
                p.advance();
            } else if (sep != ']') {
                return p.fail("expected ',' or ']' in array");
            }
        }
    }

    fn parseInlineTable(p: *Parser) Error!Value.Table {
        p.advance(); // {
        var table: Value.Table = .empty;
        while (true) {
            p.skipWhitespaceAndComments();
            const c = p.peek() orelse return p.fail("unterminated inline table");
            if (c == '}') {
                p.advance();
                return table;
            }
            var path: std.ArrayList([]const u8) = .empty;
            try p.parseKeyPath(&path);
            p.skipSpaces();
            if (p.peek() != @as(u8, '=')) return p.fail("expected '=' in inline table");
            p.advance();
            const value = try p.parseValue();
            const leaf = try p.descend(&table, path.items);
            const gop = try leaf.table.getOrPut(p.alloc, leaf.key);
            if (gop.found_existing) return p.fail("duplicate key in inline table");
            gop.value_ptr.* = value;
            p.skipWhitespaceAndComments();
            const sep = p.peek() orelse return p.fail("unterminated inline table");
            if (sep == ',') {
                p.advance();
            } else if (sep != '}') {
                return p.fail("expected ',' or '}' in inline table");
            }
        }
    }
};

pub const Document = struct {
    root: Value.Table,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(d: *Document) void {
        const backing = d.arena.child_allocator;
        d.arena.deinit();
        backing.destroy(d.arena);
    }
};

pub fn parse(gpa: Allocator, src: []const u8, err_out: ?*ParseError) Error!Document {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    const alloc = arena.allocator();
    errdefer arena.deinit();

    var p: Parser = .{ .src = src, .alloc = alloc, .err_out = err_out };
    var root: Value.Table = .empty;
    var current: *Value.Table = &root;
    // TOML forbids redeclaring an explicit table header ([a] twice is
    // invalid); implicitly-created parents may still be declared later.
    // NUL-joined paths are unambiguous — NUL can't appear in a key.
    var declared: std.StringHashMap(void) = .init(alloc);

    while (true) {
        p.skipWhitespaceAndComments();
        const c = p.peek() orelse break;
        if (c == '[') {
            // [table] or [[array-of-tables]]
            const is_array = p.peekAt(1) == @as(u8, '[');
            p.advance();
            if (is_array) p.advance();
            var path: std.ArrayList([]const u8) = .empty;
            try p.parseKeyPath(&path);
            p.skipSpaces();
            if (p.peek() != @as(u8, ']')) return p.fail("expected ']' after table header");
            p.advance();
            if (is_array) {
                if (p.peek() != @as(u8, ']')) return p.fail("expected ']]'");
                p.advance();
            }
            const leaf = try p.descend(&root, path.items);
            if (is_array) {
                const gop = try leaf.table.getOrPut(alloc, leaf.key);
                if (!gop.found_existing) gop.value_ptr.* = .{ .array = try alloc.alloc(Value, 0) };
                switch (gop.value_ptr.*) {
                    .array => |*arr| {
                        var new_arr = try alloc.alloc(Value, arr.len + 1);
                        @memcpy(new_arr[0..arr.len], arr.*);
                        new_arr[arr.len] = .{ .table = .empty };
                        arr.* = new_arr;
                        current = &arr.*[arr.len - 1].table;
                    },
                    else => return p.fail("key conflicts with non-array value"),
                }
            } else {
                const dotted = try std.mem.join(alloc, "\x00", path.items);
                if ((try declared.getOrPut(dotted)).found_existing)
                    return p.fail("duplicate table header");
                const gop = try leaf.table.getOrPut(alloc, leaf.key);
                if (gop.found_existing and gop.value_ptr.* != .table)
                    return p.fail("key conflicts with non-table value");
                if (!gop.found_existing) gop.value_ptr.* = .{ .table = .empty };
                current = &gop.value_ptr.table;
            }
        } else {
            var path: std.ArrayList([]const u8) = .empty;
            try p.parseKeyPath(&path);
            p.skipSpaces();
            if (p.peek() != @as(u8, '=')) return p.fail("expected '=' after key");
            p.advance();
            const value = try p.parseValue();
            const leaf = try p.descend(current, path.items);
            const gop = try leaf.table.getOrPut(alloc, leaf.key);
            if (gop.found_existing) return p.fail("duplicate key");
            gop.value_ptr.* = value;
        }
    }

    return .{ .root = root, .arena = arena };
}

fn get(table: Value.Table, comptime path: []const u8) ?Value {
    var cur: Value = .{ .table = table };
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        cur = cur.get(seg) orelse return null;
    }
    return cur;
}

test "basic table and values" {
    const src =
        \\# comment
        \\arch = "amd64"
        \\wipe = true
        \\n = 42
        \\f = 1.5
        \\list = ["a", "b"]
        \\
        \\[disk]
        \\device = "/dev/sda"
        \\scheme = "efi-swap-root"
        \\
        \\[[users]]
        \\name = "larry"
        \\[[users]]
        \\name = "root"
        \\
        \\[use.pkg]
        \\flag = "on"
    ;
    var doc = try parse(std.testing.allocator, src, null);
    defer doc.deinit();
    try std.testing.expectEqualStrings("amd64", get(doc.root, "arch").?.string);
    try std.testing.expectEqual(true, get(doc.root, "wipe").?.boolean);
    try std.testing.expectEqual(42, get(doc.root, "n").?.integer);
    try std.testing.expectEqual(1.5, get(doc.root, "f").?.float);
    try std.testing.expectEqual(2, get(doc.root, "list").?.array.len);
    try std.testing.expectEqualStrings("/dev/sda", get(doc.root, "disk.device").?.string);
    const users = get(doc.root, "users").?.array;
    try std.testing.expectEqual(2, users.len);
    try std.testing.expectEqualStrings("larry", users[0].get("name").?.string);
    try std.testing.expectEqualStrings("on", get(doc.root, "use.pkg.flag").?.string);
}

test "dotted keys and inline table" {
    const src =
        \\services.sshd = true
        \\use.global = { bluetooth = false, "weird-name" = 3 }
    ;
    var doc = try parse(std.testing.allocator, src, null);
    defer doc.deinit();
    try std.testing.expectEqual(true, get(doc.root, "services.sshd").?.boolean);
    try std.testing.expectEqual(false, get(doc.root, "use.global.bluetooth").?.boolean);
}

test "error reports a line" {
    var err: ParseError = undefined;
    const res = parse(std.testing.allocator, "a = 1\nb = \n", &err);
    try std.testing.expectError(error.InvalidToml, res);
    try std.testing.expectEqual(2, err.line);
}
