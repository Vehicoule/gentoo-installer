//! libvaxis frontend — renders the engine-owned wizard pages from the
//! same `page` event shape frontends get over the headless protocol
//! (parsed here in-process). Immediate-mode: each key event re-emits
//! the page event, reparses, redraws.

const std = @import("std");
const vaxis = @import("vaxis");
const engine = @import("engine");
const wizard = engine.wizard;
const Allocator = std.mem.Allocator;

const Event = vaxis.Event;

const OptView = struct { v: []const u8, label: []const u8, help: ?[]const u8 = null };
const FieldView = struct {
    name: []const u8,
    ftype: []const u8,
    label: []const u8,
    help: ?[]const u8 = null,
    confirm: bool = false,
    min: ?u32 = null,
    options: []OptView = &.{},
    value: std.json.Value = .null,
};
const SumGroup = struct { title: []const u8, lines: [][]const u8 };
const PageView = struct {
    page: []const u8,
    index: u32,
    of: u32,
    title: []const u8,
    fields: []FieldView = &.{},
    actions: [][]const u8 = &.{},
    summary: []SumGroup = &.{},
};

const Mode = enum { form, editing, confirm_install, progress, plan_preview, done, failed };

pub const Tui = struct {
    alloc: Allocator,
    io: std.Io,
    wiz: wizard.Wizard,
    /// last parsed page view — points into `frame_arena`
    pv: PageView = .{ .page = "", .index = 0, .of = 0, .title = "" },
    focus: usize = 0, // field index; focus == fields.len → actions row
    action_sel: usize = 0,
    last_h: u16 = 24, // drawn height — scroll math needs it outside draw()
    mode: Mode = .form,
    edit_buf: std.ArrayList(u8) = .empty,
    edit_field: usize = 0,
    edit_confirm: std.ArrayList(u8) = .empty,
    confirming: bool = false,
    errors: std.ArrayList([]const u8) = .empty,
    status: []const u8 = "",
    prog_lines: std.ArrayList([]const u8) = .empty,
    plan_lines: std.ArrayList([]const u8) = .empty,
    frame_arena: std.heap.ArenaAllocator,
    scroll: usize = 0,

    pub fn init(alloc: Allocator, io: std.Io) Tui {
        return .{
            .alloc = alloc,
            .io = io,
            .wiz = wizard.Wizard.init(alloc, io, .{}),
            .frame_arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    /// Re-emit the current page and reparse it into `pv`.
    fn refreshPage(t: *Tui) !void {
        _ = t.frame_arena.reset(.retain_capacity);
        const fa = t.frame_arena.allocator();
        var aw: std.Io.Writer.Allocating = .init(fa);
        try t.wiz.emitPage(&aw.writer, null, null);
        const parsed = try std.json.parseFromSlice(std.json.Value, fa, aw.written(), .{});
        const o = parsed.value.object;
        var pv = PageView{
            .page = o.get("page").?.string,
            .index = @intCast(o.get("index").?.integer),
            .of = @intCast(o.get("of").?.integer),
            .title = o.get("title").?.string,
        };
        if (o.get("fields")) |fv| {
            var fields: std.ArrayList(FieldView) = .empty;
            for (fv.array.items) |f| {
                const fo = f.object;
                var field = FieldView{
                    .name = fo.get("name").?.string,
                    .ftype = fo.get("type").?.string,
                    .label = fo.get("label").?.string,
                    .value = fo.get("value") orelse .null,
                };
                if (fo.get("help")) |h| field.help = h.string;
                if (fo.get("confirm")) |c| field.confirm = c == .bool and c.bool;
                if (fo.get("min")) |m| field.min = @intCast(m.integer);
                if (fo.get("options")) |ov| {
                    var opts: std.ArrayList(OptView) = .empty;
                    for (ov.array.items) |ovv| {
                        const oo = ovv.object;
                        try opts.append(fa, .{
                            .v = oo.get("v").?.string,
                            .label = oo.get("label").?.string,
                            .help = if (oo.get("help")) |h| h.string else null,
                        });
                    }
                    field.options = opts.items;
                }
                try fields.append(fa, field);
            }
            pv.fields = fields.items;
        }
        if (o.get("summary")) |sv| {
            var groups: std.ArrayList(SumGroup) = .empty;
            for (sv.array.items) |g| {
                const go = g.object;
                var lines: std.ArrayList([]const u8) = .empty;
                for (go.get("lines").?.array.items) |l| try lines.append(fa, l.string);
                try groups.append(fa, .{ .title = go.get("title").?.string, .lines = lines.items });
            }
            pv.summary = groups.items;
        }
        if (o.get("actions")) |av| {
            var acts: std.ArrayList([]const u8) = .empty;
            for (av.array.items) |a| try acts.append(fa, a.string);
            pv.actions = acts.items;
        }
        t.pv = pv;
        if (t.focus > pv.fields.len) t.focus = pv.fields.len;
        t.ensureFocusVisible();
    }

    /// Keep the focused row inside the visible window — short terminals
    /// must scroll as focus moves, or the user edits invisible fields.
    fn ensureFocusVisible(t: *Tui) void {
        const max_rows: usize = t.last_h -| 8;
        if (max_rows == 0) return;
        const target = @min(t.focus, t.pv.fields.len); // actions row counts
        if (target < t.scroll) t.scroll = target;
        if (target >= t.scroll + max_rows) t.scroll = target - max_rows + 1;
    }

    /// Mirror of engine set — translates a text buffer into the json
    /// value the field expects.
    fn commitEdit(t: *Tui) !void {
        const f = t.pv.fields[t.edit_field];
        const text = std.mem.trim(u8, t.edit_buf.items, " \t");
        var v: std.json.Value = undefined;
        if (std.mem.eql(u8, f.ftype, "int")) {
            v = .{ .integer = std.fmt.parseInt(i64, text, 10) catch return error.BadValue };
        } else if (std.mem.eql(u8, f.ftype, "list")) {
            var arr = std.json.Array.init(t.alloc);
            var it = std.mem.splitScalar(u8, text, ',');
            while (it.next()) |item| {
                const s = std.mem.trim(u8, item, " \t");
                if (s.len > 0) try arr.append(.{ .string = try t.alloc.dupe(u8, s) });
            }
            v = .{ .array = arr };
        } else if (std.mem.eql(u8, f.ftype, "record")) {
            var obj = try std.json.ObjectMap.init(t.alloc, &.{}, &.{});
            var it = std.mem.splitScalar(u8, text, ',');
            while (it.next()) |item| {
                const s = std.mem.trim(u8, item, " \t");
                if (s.len == 0) continue;
                if (std.mem.indexOfScalar(u8, s, '=')) |eq| {
                    const k = try t.alloc.dupe(u8, s[0..eq]);
                    const val = std.mem.trim(u8, s[eq + 1 ..], " \t");
                    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "on"))
                        try obj.put(t.alloc, k, .{ .bool = true })
                    else if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "off"))
                        try obj.put(t.alloc, k, .{ .bool = false })
                    else if (std.fmt.parseInt(i64, val, 10)) |n|
                        try obj.put(t.alloc, k, .{ .integer = n })
                    else |_|
                        try obj.put(t.alloc, k, .{ .string = try t.alloc.dupe(u8, val) });
                } else try obj.put(t.alloc, try t.alloc.dupe(u8, s), .{ .bool = true });
            }
            v = .{ .object = obj };
        } else if (std.mem.eql(u8, f.ftype, "table")) {
            // users: `name:pw:g1+g2:shell` per entry, `;`-separated
            var arr = std.json.Array.init(t.alloc);
            var it = std.mem.splitScalar(u8, text, ';');
            while (it.next()) |entry| {
                const s = std.mem.trim(u8, entry, " \t");
                if (s.len == 0) continue;
                var obj = try std.json.ObjectMap.init(t.alloc, &.{}, &.{});
                var parts = std.mem.splitScalar(u8, s, ':');
                try obj.put(t.alloc, "name", .{ .string = try t.alloc.dupe(u8, parts.next() orelse "") });
                if (parts.next()) |pw| try obj.put(t.alloc, "password", .{ .string = try t.alloc.dupe(u8, pw) });
                if (parts.next()) |gs| {
                    var groups = std.json.Array.init(t.alloc);
                    var git = std.mem.splitScalar(u8, gs, '+');
                    while (git.next()) |g| {
                        const gt = std.mem.trim(u8, g, " \t");
                        if (gt.len > 0) try groups.append(.{ .string = try t.alloc.dupe(u8, gt) });
                    }
                    try obj.put(t.alloc, "groups", .{ .array = groups });
                }
                if (parts.next()) |sh| try obj.put(t.alloc, "shell", .{ .string = try t.alloc.dupe(u8, sh) });
                try arr.append(.{ .object = obj });
            }
            v = .{ .array = arr };
        } else {
            v = .{ .string = try t.alloc.dupe(u8, text) };
        }
        t.wiz.setField(f.name, v) catch |e| {
            t.status = std.fmt.allocPrint(t.alloc, "set failed: {s}", .{@errorName(e)}) catch "set failed";
            return;
        };
        t.mode = .form;
        t.status = "";
        try t.refreshErrors();
        try t.refreshPage();
    }

    fn refreshErrors(t: *Tui) !void {
        const errs = try engine.config.validate(t.alloc, &t.wiz.cfg, nvidiaTier(&t.wiz));
        t.errors.clearRetainingCapacity();
        for (errs) |e| try t.errors.append(t.alloc, e);
    }

    fn doNext(t: *Tui) !void {
        if (try t.wiz.next(t.alloc, nvidiaTier(&t.wiz))) {
            t.focus = 0;
            t.errors.clearRetainingCapacity();
        } else {
            const errs = try t.wiz.pageErrors(t.alloc, nvidiaTier(&t.wiz), t.wiz.currentPage());
            t.errors.clearRetainingCapacity();
            for (errs) |e| try t.errors.append(t.alloc, e);
        }
        try t.refreshPage();
    }

    fn doAction(t: *Tui, act: []const u8) !void {
        if (std.mem.eql(u8, act, "next")) {
            try t.doNext();
        } else if (std.mem.eql(u8, act, "back")) {
            t.wiz.back();
            t.focus = 0;
            try t.refreshPage();
        } else if (std.mem.eql(u8, act, "quit")) {
            t.mode = .done;
            t.status = "quit";
        } else if (std.mem.eql(u8, act, "plan")) {
            try t.showPlanPreview();
        } else if (std.mem.eql(u8, act, "export_answer")) {
            // cwd-relative — export is confined to the launch dir.
            try t.wiz.exportAnswer("gentoo-installer-answer.toml");
            t.status = "answer file → ./gentoo-installer-answer.toml";
        } else if (std.mem.eql(u8, act, "install")) {
            t.mode = .confirm_install;
            t.edit_buf.clearRetainingCapacity();
        }
    }

    fn showPlanPreview(t: *Tui) !void {
        const ps = try t.wiz.pkgSets(t.alloc);
        if (ps.errs.len > 0) {
            t.status = std.fmt.allocPrint(t.alloc, "set resolution: {s}", .{ps.errs[0]}) catch "set resolution failed";
            return;
        }
        const p = try engine.plan.build(t.alloc, &t.wiz.cfg, if (t.wiz.env) |*e| e else null, ps.sets, null);
        t.plan_lines.clearRetainingCapacity();
        var aw: std.Io.Writer.Allocating = .init(t.alloc);
        try engine.runner.run(t.io, t.alloc, p, .{ .mode = .dry_run, .out = &aw.writer });
        var it = std.mem.splitScalar(u8, aw.written(), '\n');
        while (it.next()) |ln| if (ln.len > 0) try t.plan_lines.append(t.alloc, try t.alloc.dupe(u8, ln));
        t.mode = .plan_preview;
    }

    fn runInstall(t: *Tui) !void {
        t.mode = .progress;
        t.prog_lines.clearRetainingCapacity();
        const ps = t.wiz.pkgSets(t.alloc) catch |e| {
            t.status = std.fmt.allocPrint(t.alloc, "set resolution failed: {s}", .{@errorName(e)}) catch "set resolution failed";
            t.mode = .failed;
            return;
        };
        if (ps.errs.len > 0) {
            t.status = std.fmt.allocPrint(t.alloc, "set resolution: {s}", .{ps.errs[0]}) catch "set resolution failed";
            t.mode = .failed;
            return;
        }
        const p = engine.plan.build(t.alloc, &t.wiz.cfg, if (t.wiz.env) |*e| e else null, ps.sets, null) catch |e| {
            t.status = std.fmt.allocPrint(t.alloc, "plan failed: {s}", .{@errorName(e)}) catch "plan failed";
            t.mode = .failed;
            return;
        };
        const sctx = struct {
            lines: *std.ArrayList([]const u8),
            alloc: Allocator,
        };
        var ctx = sctx{ .lines = &t.prog_lines, .alloc = t.alloc };
        const cb = struct {
            fn f(c: ?*anyopaque, i: usize, of: usize, id: []const u8, state: []const u8) void {
                const sc: *sctx = @ptrCast(@alignCast(c orelse return));
                const ln = std.fmt.allocPrint(sc.alloc, "[{}/{}] {s} — {s}", .{ i, of, state, id }) catch return;
                sc.lines.append(sc.alloc, ln) catch return;
            }
        }.f;
        var logw: std.Io.Writer.Allocating = .init(t.alloc);
        engine.runner.run(t.io, t.alloc, p, .{
            .mode = .dry_run, // M2 TUI: preview only; exec rides on headless `install` + confirm gate
            .out = &logw.writer,
            .on_step = cb,
            .ctx = &ctx,
        }) catch |e| {
            t.status = std.fmt.allocPrint(t.alloc, "install failed: {s}", .{@errorName(e)}) catch "install failed";
            t.mode = .failed;
            return;
        };
        t.mode = .done;
        t.status = "install preview complete (dry-run)";
    }

    fn cycle(t: *Tui, dir: i32) !void {
        if (t.focus >= t.pv.fields.len) return;
        const f = t.pv.fields[t.focus];
        if (!std.mem.eql(u8, f.ftype, "enum") or f.options.len == 0) return;
        const cur = switch (f.value) {
            .string => |s| s,
            else => "",
        };
        var idx: usize = 0;
        for (f.options, 0..) |o, i| {
            if (std.mem.eql(u8, o.v, cur)) {
                idx = i;
                break;
            }
        }
        const n = f.options.len;
        const ni = @mod(@as(i32, @intCast(idx)) + dir, @as(i32, @intCast(n)));
        try t.wiz.setField(f.name, .{ .string = f.options[@intCast(ni)].v });
        try t.refreshErrors();
        try t.refreshPage();
    }

    fn toggleBool(t: *Tui) !void {
        if (t.focus >= t.pv.fields.len) return;
        const f = t.pv.fields[t.focus];
        if (!std.mem.eql(u8, f.ftype, "bool")) return;
        const cur = f.value == .bool and f.value.bool;
        try t.wiz.setField(f.name, .{ .bool = !cur });
        try t.refreshErrors();
        try t.refreshPage();
    }

    fn beginEdit(t: *Tui) !void {
        if (t.focus >= t.pv.fields.len) return;
        const f = t.pv.fields[t.focus];
        t.edit_buf.clearRetainingCapacity();
        t.edit_confirm.clearRetainingCapacity();
        t.confirming = false;
        // prefill from current value
        switch (f.value) {
            .string => |s| try t.edit_buf.appendSlice(t.alloc, s),
            .integer => |i| try t.edit_buf.print(t.alloc, "{}", .{i}),
            .bool => {},
            .array => |arr| {
                for (arr.items, 0..) |it, i| {
                    if (i > 0) try t.edit_buf.append(t.alloc, ',');
                    if (it == .string) try t.edit_buf.appendSlice(t.alloc, it.string);
                }
            },
            else => {},
        }
        t.edit_field = t.focus;
        t.mode = .editing;
    }
};

fn nvidiaTier(wiz: *wizard.Wizard) ?engine.config.NvidiaTier {
    const env = wiz.env orelse return null;
    for (env.gpus) |g| {
        if (std.mem.eql(u8, g.vendor, "nvidia"))
            return if (engine.detect.nvidiaIsTuringPlus(g)) .open_capable else .legacy;
    }
    return null;
}

const fg_green: vaxis.Color = .{ .index = 10 };
const fg_red: vaxis.Color = .{ .index = 9 };
const fg_dim: vaxis.Color = .{ .index = 8 };
const fg_cyan: vaxis.Color = .{ .index = 14 };
const accent: vaxis.Style = .{ .fg = fg_cyan, .bold = true };
const sel: vaxis.Style = .{ .reverse = true };
const dim: vaxis.Style = .{ .fg = fg_dim };
const err_style: vaxis.Style = .{ .fg = fg_red };
const ok_style: vaxis.Style = .{ .fg = fg_green };

fn draw(t: *Tui, win: vaxis.Window) !void {
    win.clear();
    var row: u16 = 0;
    const w = win.width;
    const h = win.height;
    if (w < 30 or h < 8) {
        _ = win.print(&.{.{ .text = "terminal too small", .style = err_style }}, .{});
        return;
    }

    // header
    const title = try std.fmt.allocPrint(t.alloc, " gentoo-installer — {s}  ({d}/{d})  [{s}]", .{ t.pv.title, t.pv.index, t.pv.of, @tagName(t.wiz.flow) });
    _ = win.print(&.{.{ .text = title, .style = .{ .reverse = true, .bold = true } }}, .{ .row_offset = row, .col_offset = 0 });
    row += 2;

    if (t.mode == .plan_preview) {
        _ = win.print(&.{.{ .text = " plan preview — esc to return", .style = accent }}, .{ .row_offset = row });
        row += 1;
        for (t.plan_lines.items, 0..) |ln, i| {
            if (row >= h -| 1) break;
            _ = i;
            _ = win.print(&.{.{ .text = ln, .style = .{} }}, .{ .row_offset = row });
            row += 1;
        }
        return;
    }

    if (t.mode == .progress or t.mode == .done or t.mode == .failed) {
        for (t.prog_lines.items) |ln| {
            if (row >= h -| 4) break;
            _ = win.print(&.{.{ .text = ln, .style = .{} }}, .{ .row_offset = row });
            row += 1;
        }
        _ = win.print(&.{.{ .text = t.status, .style = if (t.mode == .failed) err_style else ok_style }}, .{ .row_offset = row + 1 });
        return;
    }

    if (t.mode == .confirm_install) {
        _ = win.print(&.{.{ .text = "Type the disk name to confirm the dry-run preview (exec rides on headless):", .style = accent }}, .{ .row_offset = row });
        row += 1;
        _ = win.print(&.{.{ .text = t.edit_buf.items, .style = sel }}, .{ .row_offset = row });
        return;
    }

    // review page: grouped config summary instead of fields
    if (t.pv.summary.len > 0) {
        for (t.pv.summary) |g| {
            if (row >= h -| 6) break;
            _ = win.print(&.{.{ .text = g.title, .style = accent }}, .{ .row_offset = row, .col_offset = 1 });
            row += 1;
            for (g.lines) |ln| {
                if (row >= h -| 6) break;
                _ = win.print(&.{.{ .text = ln, .style = .{} }}, .{ .row_offset = row, .col_offset = 3 });
                row += 1;
            }
            row += 1;
        }
    }

    t.last_h = h;
    // fields
    var vi: usize = 0; // visible row index (fields + action row)
    const max_rows = h -| 8;
    for (t.pv.fields, 0..) |f, i| {
        if (vi < t.scroll) {
            vi += 1;
            continue;
        }
        if (row > 2 + max_rows) break;
        vi += 1;
        const is_focus = i == t.focus;
        const sty: vaxis.Style = if (is_focus) sel else .{};
        const label = try std.fmt.allocPrint(t.alloc, " {s}", .{f.label});
        _ = win.print(&.{.{ .text = label, .style = sty }}, .{ .row_offset = row, .col_offset = 0 });
        // value
        var vbuf: std.Io.Writer.Allocating = .init(t.alloc);
        try renderValue(&vbuf.writer, f, t, i);
        _ = win.print(&.{.{ .text = vbuf.written(), .style = sty }}, .{ .row_offset = row, .col_offset = @min(28, w / 3) });
        // help on focused field
        if (is_focus and f.help != null)
            _ = win.print(&.{.{ .text = f.help.?, .style = dim }}, .{ .row_offset = row, .col_offset = @min(60, w / 2) });
        row += 1;
    }

    // actions row — a long summary can't be allowed to push actions
    // offscreen; pin a fallback slot above the error block if the
    // natural position ran out of room.
    if (t.pv.actions.len > 0) {
        const pinned = h -| @as(u16, @intCast(@min(t.errors.items.len + 4, h -| 4)));
        const act_row: u16 = if (row <= 2 + max_rows) row + 1 else pinned;
        var col: u16 = 2;
        for (t.pv.actions, 0..) |a, i| {
            const is_focus = (t.focus == t.pv.fields.len) and t.action_sel == i;
            // the TUI's install is a dry-run preview — label it so.
            const shown = if (std.mem.eql(u8, a, "install")) "preview install (dry-run)" else a;
            const label = try std.fmt.allocPrint(t.alloc, "[ {s} ]", .{shown});
            _ = win.print(&.{.{ .text = label, .style = if (is_focus) sel else accent }}, .{ .row_offset = act_row, .col_offset = col });
            col += @intCast(label.len + 1);
        }
        row = act_row + 1;
    }

    // errors
    if (t.errors.items.len > 0) {
        row = h -| @as(u16, @intCast(@min(t.errors.items.len + 3, h -| 3)));
        _ = win.print(&.{.{ .text = " errors:", .style = err_style }}, .{ .row_offset = row });
        row += 1;
        for (t.errors.items) |e| {
            if (row >= h -| 2) break;
            _ = win.print(&.{.{ .text = e, .style = err_style }}, .{ .row_offset = row, .col_offset = 2 });
            row += 1;
        }
    }

    // footer
    const foot = if (t.mode == .editing)
        if (t.confirming) " confirm: type again · enter commit · esc cancel" else " editing — enter commit · esc cancel"
    else
        " ↑↓ navigate · enter edit/cycle · ←→ options · space toggle · PgUp/PgDn page · q quit";
    _ = win.print(&.{.{ .text = foot, .style = .{ .reverse = true } }}, .{ .row_offset = h -| 1 });
    if (t.status.len > 0)
        _ = win.print(&.{.{ .text = t.status, .style = ok_style }}, .{ .row_offset = h -| 2 });
}

fn renderValue(w: *std.Io.Writer, f: FieldView, t: *Tui, i: usize) !void {
    if (t.mode == .editing and i == t.edit_field) {
        if (std.mem.eql(u8, f.ftype, "secret")) {
            for (0..t.edit_buf.items.len) |_| try w.writeAll("●");
            if (t.confirming) try w.writeAll("  [confirm]");
            return;
        }
        try w.writeAll(t.edit_buf.items);
        try w.writeAll("▌");
        return;
    }
    if (std.mem.eql(u8, f.ftype, "bool")) {
        try w.writeAll(if (f.value == .bool and f.value.bool) "[x]" else "[ ]");
        return;
    }
    if (std.mem.eql(u8, f.ftype, "enum")) {
        const cur = switch (f.value) {
            .string => |s| s,
            else => "",
        };
        for (f.options) |o| {
            if (std.mem.eql(u8, o.v, cur)) {
                try w.print("◀ {s} ▶", .{o.label});
                return;
            }
        }
        try w.print("◀ {s} ▶", .{cur});
        return;
    }
    if (std.mem.eql(u8, f.ftype, "secret")) {
        const set = f.value == .object and f.value.object.get("is_set") != null and f.value.object.get("is_set").?.bool;
        try w.writeAll(if (set) "●●●●●●" else "(empty)");
        return;
    }
    switch (f.value) {
        .string => |s| try w.writeAll(s),
        .integer => |n| try w.print("{}", .{n}),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .array => |arr| {
            for (arr.items, 0..) |it, ai| {
                if (ai > 0) try w.writeAll(",");
                switch (it) {
                    .string => |s| try w.writeAll(s),
                    .object => |o| {
                        if (o.get("name")) |n| try w.writeAll(n.string);
                    },
                    else => try w.writeAll("?"),
                }
            }
        },
        .object => try w.writeAll("{…}"),
        else => try w.writeAll("(unset)"),
    }
}

pub fn runTui(init: std.process.Init, alloc: Allocator, io: std.Io, preset: ?*const engine.preset.Preset) !void {
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.tty.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.Vaxis.init(io, alloc, init.environ_map, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop = vaxis.Loop(Event).init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    var t = Tui.init(alloc, io);
    t.wiz.preset = preset;
    t.wiz.applyPresetDefaults() catch {};
    defer t.frame_arena.deinit();

    // detect → wizard env
    const env = try engine.detect.detect(alloc, io);
    t.wiz.applyEnv(env);
    try t.refreshPage();
    try t.refreshErrors();

    const win0 = vx.window();
    try draw(&t, win0);
    try vx.render(tty.writer());

    while (true) {
        const ev = loop.nextEvent() catch null orelse break;
        switch (ev) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) break;
                if (t.mode == .done or t.mode == .failed) {
                    if (key.matches('q', .{})) break;
                    continue;
                }
                if (t.mode == .plan_preview) {
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) t.mode = .form;
                } else if (t.mode == .confirm_install) {
                    if (key.matches(vaxis.Key.enter, .{})) {
                        const base = std.fs.path.basename(t.wiz.cfg.disk.device);
                        if (std.mem.eql(u8, std.mem.trim(u8, t.edit_buf.items, " "), base)) {
                            try t.runInstall();
                        } else {
                            t.mode = .form;
                            t.status = "confirm mismatch";
                        }
                    } else if (key.matches(vaxis.Key.escape, .{})) {
                        t.mode = .form;
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        _ = t.edit_buf.pop();
                    } else if (key.text) |txt| {
                        try t.edit_buf.appendSlice(t.alloc, txt);
                    }
                } else if (t.mode == .editing) {
                    if (key.matches(vaxis.Key.enter, .{})) {
                        const f = t.pv.fields[t.edit_field];
                        if (f.confirm and !t.confirming) {
                            t.confirming = true;
                            // Deep copy — struct assignment would alias
                            // the buffer and the re-entry would
                            // overwrite the stored first entry.
                            t.edit_confirm.clearRetainingCapacity();
                            try t.edit_confirm.appendSlice(t.alloc, t.edit_buf.items);
                            t.edit_buf.clearRetainingCapacity();
                        } else if (f.confirm and t.confirming) {
                            if (std.mem.eql(u8, t.edit_buf.items, t.edit_confirm.items)) {
                                t.edit_confirm.clearRetainingCapacity();
                                try t.commitEdit();
                            } else {
                                t.status = "entries differ";
                                t.confirming = false;
                                t.edit_confirm.clearRetainingCapacity();
                            }
                        } else try t.commitEdit();
                    } else if (key.matches(vaxis.Key.escape, .{})) {
                        t.mode = .form;
                    } else if (key.matches(vaxis.Key.backspace, .{})) {
                        _ = t.edit_buf.pop();
                    } else if (key.text) |txt| {
                        try t.edit_buf.appendSlice(t.alloc, txt);
                    }
                } else if (t.mode == .form) {
                    if (key.matches('q', .{})) break;
                    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                        if (t.focus > 0) t.focus -= 1 else {
                            // wrap to action row
                            t.focus = t.pv.fields.len;
                        }
                        t.ensureFocusVisible();
                    } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                        t.focus = @min(t.focus + 1, t.pv.fields.len);
                        t.ensureFocusVisible();
                    } else if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
                        if (t.focus == t.pv.fields.len) {
                            if (t.action_sel > 0) t.action_sel -= 1;
                        } else try t.cycle(-1);
                    } else if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
                        if (t.focus == t.pv.fields.len) {
                            if (t.action_sel + 1 < t.pv.actions.len) t.action_sel += 1;
                        } else try t.cycle(1);
                    } else if (key.matches(' ', .{})) {
                        if (t.focus < t.pv.fields.len) {
                            const f = t.pv.fields[t.focus];
                            if (std.mem.eql(u8, f.ftype, "bool")) try t.toggleBool() else try t.cycle(1);
                        }
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        if (t.focus == t.pv.fields.len) {
                            if (t.pv.actions.len > 0) try t.doAction(t.pv.actions[t.action_sel]);
                        } else {
                            const f = t.pv.fields[t.focus];
                            if (std.mem.eql(u8, f.ftype, "bool")) try t.toggleBool() else if (std.mem.eql(u8, f.ftype, "enum")) try t.cycle(1) else try t.beginEdit();
                        }
                    } else if (key.matches(vaxis.Key.page_down, .{})) {
                        try t.doNext();
                    } else if (key.matches(vaxis.Key.page_up, .{})) {
                        t.wiz.back();
                        t.focus = 0;
                        t.scroll = 0;
                        try t.refreshPage();
                    }
                }
            },
            .winsize => |ws| {
                vx.resize(alloc, tty.writer(), ws) catch {};
            },
            else => {},
        }
        _ = t.frame_arena.reset(.retain_capacity);
        // re-emit page inside frame arena so pv fields stay valid this frame
        try t.refreshPage();
        const win = vx.window();
        try draw(&t, win);
        try vx.render(tty.writer());
    }
}
