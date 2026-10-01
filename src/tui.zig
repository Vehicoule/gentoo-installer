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
const NavItem = struct { id: []const u8, title: []const u8, section: []const u8, state: []const u8 };
const SumGroup = struct { title: []const u8, edit: []const u8 = "", lines: [][]const u8 };
const StepView = struct { id: []const u8, title: []const u8, state: []const u8 = "todo" };
const ErrItem = struct { field: ?[]const u8, msg: []const u8, on_page: bool };
const PageView = struct {
    page: []const u8,
    index: u32,
    of: u32,
    title: []const u8,
    section: []const u8 = "",
    subtitle: []const u8 = "",
    nav: []NavItem = &.{},
    fields: []FieldView = &.{},
    actions: [][]const u8 = &.{},
    summary: []SumGroup = &.{},
    steps: []StepView = &.{},
};

const Mode = enum { form, editing, confirm_install, progress, plan_preview, done, failed };

/// overlay listing the keys of the active mode — `?` toggles it
const HELP_TEXT =
    \\ keys ──────────────────────────────────────────
    \\  ↑/k ↓/j        move · scroll review/plan
    \\  ←/h →/l space  cycle option · pick action
    \\  enter          edit field · activate button
    \\  PgUp/PgDn      back / next page
    \\  g then digit   jump to a visited page (rail #)
    \\  ?              this help
    \\  q / ctrl+c     quit
    \\ ───────────────────────────────────────────────
    \\ editing:  enter commit · esc cancel
    \\ secrets:  type → enter → retype → enter
    \\ confirm:  type the disk name, enter, esc cancels
;

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
    errors: std.ArrayList(ErrItem) = .empty,
    status: []const u8 = "",
    /// status renders green for info and red for failures — the flag
    /// keeps the two apart instead of guessing from the text.
    status_err: bool = false,
    prog_lines: std.ArrayList([]const u8) = .empty,
    plan_lines: std.ArrayList([]const u8) = .empty,
    /// timeline for the install view — ids/titles live on `alloc`
    /// (frame arena resets each keypress), state mutates via on_step.
    install_steps: std.ArrayList(StepView) = .empty,
    frame_arena: std.heap.ArenaAllocator,
    scroll: usize = 0,
    /// pending digit for the `g<N>` nav jump — 0 = no jump armed.
    goto_armed: bool = false,
    /// `?` help overlay
    show_help: bool = false,
    /// plan preview scroll offset
    plan_scroll: usize = 0,
    /// set by the review-page whole-config gate — refreshErrors shows
    /// every error, not just this page's, until the user navigates.
    gate_errors: bool = false,

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
            .section = if (o.get("section")) |s| s.string else "",
            .subtitle = if (o.get("subtitle")) |s| s.string else "",
        };
        if (o.get("nav")) |nv| {
            var nav: std.ArrayList(NavItem) = .empty;
            for (nv.array.items) |n| {
                const no = n.object;
                try nav.append(fa, .{
                    .id = no.get("id").?.string,
                    .title = no.get("title").?.string,
                    .section = if (no.get("section")) |s| s.string else "",
                    .state = no.get("state").?.string,
                });
            }
            pv.nav = nav.items;
        }
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
                try groups.append(fa, .{ .title = go.get("title").?.string, .edit = if (go.get("edit")) |e| e.string else "", .lines = lines.items });
            }
            pv.summary = groups.items;
        }
        if (o.get("steps")) |sv| {
            var steps: std.ArrayList(StepView) = .empty;
            for (sv.array.items) |s| {
                const so = s.object;
                try steps.append(fa, .{ .id = so.get("id").?.string, .title = so.get("title").?.string });
            }
            pv.steps = steps.items;
        }
        if (o.get("actions")) |av| {
            var acts: std.ArrayList([]const u8) = .empty;
            for (av.array.items) |a| try acts.append(fa, a.string);
            pv.actions = acts.items;
        }
        t.pv = pv;
        if (t.focus > pv.fields.len) t.focus = pv.fields.len;
        // action_sel outlives the page it was chosen on — a stale index
        // past the new actions list would crash Enter.
        t.action_sel = if (pv.actions.len == 0) 0 else @min(t.action_sel, pv.actions.len - 1);
        t.ensureFocusVisible();
    }

    /// First content row under title/subtitle/rule — must match draw().
    fn contentStart(t: *Tui) usize {
        return if (t.pv.subtitle.len > 0) 5 else 4;
    }
    /// Rendered height of field `i` at current focus/mode — the focused
    /// enum expands into an option list, help + error rows hang under
    /// their field. Scroll math must use the same layout as draw(), or
    /// focus lands on a field whose rows are already clipped away.
    fn fieldRows(t: *Tui, i: usize) usize {
        const f = t.pv.fields[i];
        var r: usize = 1;
        if (i == t.focus and std.mem.eql(u8, f.ftype, "enum") and f.options.len > 0 and t.mode == .form) {
            r += @min(f.options.len, 6);
            if (f.options.len > 6) r += 1;
        } else if (i == t.focus and f.help != null) {
            r += 1;
        }
        for (t.errors.items) |e| {
            if (e.field) |ef| {
                if (std.mem.eql(u8, ef, f.name)) r += 1;
            }
        }
        return r;
    }

    /// Keep the focused row inside the visible window — short terminals
    /// must scroll as focus moves, or the user edits invisible fields.
    /// On the review page (no fields) the arrows drive summary scroll
    /// instead, so this must not touch t.scroll.
    fn ensureFocusVisible(t: *Tui) void {
        const start = t.contentStart();
        if (t.pv.fields.len == 0) {
            // review page — clamp the offset to its content (summary +
            // any gate-error block appended to the scroll stream).
            // summary lines render at rows start..h-8 (draw clips at
            // row < h-7), so that many rows are visible.
            const vis: usize = ((t.last_h -| 8) -| start) + 1;
            const total = scrollTotal(t);
            t.scroll = @min(t.scroll, total -| vis);
            return;
        }
        // the pinned actions row is always visible — no scroll needed
        if (t.focus >= t.pv.fields.len) return;
        if (t.focus < t.scroll) {
            t.scroll = t.focus;
            return;
        }
        // field rows render at start..h-7 (draw clips at row > h-7)
        const vis: usize = ((t.last_h -| 7) -| start) + 1;
        // scroll counts field indices but visibility counts rendered
        // rows — advance until the focused field's full height fits.
        while (t.scroll < t.focus) {
            var used: usize = 0;
            var fits = false;
            for (t.scroll..t.focus + 1) |i| {
                used += t.fieldRows(i);
                if (i == t.focus) fits = used <= vis;
            }
            if (fits) break;
            t.scroll += 1;
        }
    }

    fn summaryLines(summary: []SumGroup) usize {
        var n: usize = 0;
        for (summary) |g| n += 1 + g.lines.len;
        return n;
    }

    /// Virtual lines the review scroll covers — summary groups plus the
    /// gate-error block (one " problems" header + a line per error).
    fn scrollTotal(t: *Tui) usize {
        var n = summaryLines(t.pv.summary);
        var errs: usize = 0;
        for (t.errors.items) |e| {
            if (e.on_page) errs += 1;
        }
        if (errs > 0) n += 1 + errs;
        return n;
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
            t.status_err = true;
            return;
        };
        t.mode = .form;
        t.status = "";
        t.status_err = false;
        try t.refreshErrors();
        try t.refreshPage();
    }

    fn refreshErrors(t: *Tui) !void {
        // error strings live on the frame arena — this runs per
        // keypress for live validation.
        const fa = t.frame_arena.allocator();
        const errs = try engine.config.validate(fa, &t.wiz.cfg, nvidiaTier(&t.wiz), if (t.wiz.env) |*e| e else null);
        const mine = try t.wiz.pageErrors(fa, nvidiaTier(&t.wiz), t.wiz.currentPage());
        t.errors.clearRetainingCapacity();
        // only this page's errors surface — global noise on every
        // screen is the incoherence we're removing; a pending gate
        // (review's install/export refusal) lists the whole config.
        for (errs) |e| {
            var on_page = t.gate_errors;
            for (mine) |m| {
                if (std.mem.eql(u8, e, m)) on_page = true;
            }
            try t.errors.append(t.alloc, .{ .field = wizard.errorField(e), .msg = e, .on_page = on_page });
        }
    }

    fn doNext(t: *Tui) !void {
        t.gate_errors = false;
        if (try t.wiz.next(t.alloc, nvidiaTier(&t.wiz))) {
            t.focus = 0;
            t.errors.clearRetainingCapacity();
        } else {
            const errs = try t.wiz.pageErrors(t.alloc, nvidiaTier(&t.wiz), t.wiz.currentPage());
            t.errors.clearRetainingCapacity();
            for (errs) |e| try t.errors.append(t.alloc, .{ .field = wizard.errorField(e), .msg = e, .on_page = true });
        }
        try t.refreshPage();
    }

    /// `g<N>` — jump the nav rail. Backward hops only: the engine's
    /// `goto` refuses todo pages (a forward jump would land on Review
    /// with the gate pages unvalidated), so only done/current respond.
    fn gotoPage(t: *Tui, i: usize) !void {
        if (i >= t.pv.nav.len) return;
        const st = t.pv.nav[i].state;
        if (!std.mem.eql(u8, st, "done") and !std.mem.eql(u8, st, "current")) return;
        const id = t.pv.nav[i].id;
        var aw: std.Io.Writer.Allocating = .init(t.alloc);
        defer aw.deinit();
        t.wiz.gotoPage(&aw.writer, null, id) catch return;
        t.gate_errors = false;
        t.focus = 0;
        t.scroll = 0;
        try t.refreshPage();
    }

    fn doAction(t: *Tui, act: []const u8) !void {
        if (std.mem.eql(u8, act, "next")) {
            try t.doNext();
        } else if (std.mem.eql(u8, act, "back")) {
            t.wiz.back();
            t.gate_errors = false;
            t.focus = 0;
            try t.refreshPage();
        } else if (std.mem.eql(u8, act, "quit")) {
            t.mode = .done;
            t.status = "quit";
            t.status_err = false;
        } else if (std.mem.eql(u8, act, "plan")) {
            try t.showPlanPreview();
        } else if (std.mem.eql(u8, act, "export_answer")) {
            // cwd-relative — export is confined to the launch dir.
            if (!try t.requireValidConfig()) return;
            try t.wiz.exportAnswer("gentoo-installer-answer.toml");
            t.status = "answer file → ./gentoo-installer-answer.toml";
            t.status_err = false;
        } else if (std.mem.eql(u8, act, "install")) {
            if (!try t.requireValidConfig()) return;
            t.mode = .confirm_install;
            t.edit_buf.clearRetainingCapacity();
        }
    }

    /// Whole-config gate for the review actions — Review can be reached
    /// without `next` having validated every page (answer-file load,
    /// rail jump), so export/install re-check the full validator first.
    fn requireValidConfig(t: *Tui) !bool {
        const errs = try engine.config.validate(t.alloc, &t.wiz.cfg, nvidiaTier(&t.wiz), if (t.wiz.env) |*e| e else null);
        if (errs.len == 0) return true;
        t.errors.clearRetainingCapacity();
        for (errs) |e| try t.errors.append(t.alloc, .{ .field = wizard.errorField(e), .msg = e, .on_page = true });
        // refreshErrors runs per keypress — without this flag it would
        // re-scope the gate list to the review page (no prefixes → all
        // hidden) and the user couldn't see what blocks the install.
        t.gate_errors = true;
        t.status = "fix the listed problems first";
        t.status_err = true;
        return false;
    }

    fn showPlanPreview(t: *Tui) !void {
        const ps = try t.wiz.pkgSets(t.alloc);
        if (ps.errs.len > 0) {
            t.status = std.fmt.allocPrint(t.alloc, "set resolution: {s}", .{ps.errs[0]}) catch "set resolution failed";
            t.status_err = true;
            return;
        }
        const p = engine.plan.build(t.alloc, &t.wiz.cfg, if (t.wiz.env) |*e| e else null, ps.sets, t.wiz.preset, null) catch |e| {
            t.status = std.fmt.allocPrint(t.alloc, "plan failed: {s}", .{@errorName(e)}) catch "plan failed";
            t.status_err = true;
            return;
        };
        t.plan_lines.clearRetainingCapacity();
        t.plan_scroll = 0;
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
            t.status_err = true;
            t.mode = .failed;
            return;
        };
        if (ps.errs.len > 0) {
            t.status = std.fmt.allocPrint(t.alloc, "set resolution: {s}", .{ps.errs[0]}) catch "set resolution failed";
            t.status_err = true;
            t.mode = .failed;
            return;
        }
        const p = engine.plan.build(t.alloc, &t.wiz.cfg, if (t.wiz.env) |*e| e else null, ps.sets, t.wiz.preset, null) catch |e| {
            t.status = std.fmt.allocPrint(t.alloc, "plan failed: {s}", .{@errorName(e)}) catch "plan failed";
            t.status_err = true;
            t.mode = .failed;
            return;
        };
        // snapshot the review page's step list for the timeline — pv
        // lives in frame_arena and would go stale mid-run.
        t.install_steps.clearRetainingCapacity();
        for (t.pv.steps) |s| {
            try t.install_steps.append(t.alloc, .{
                .id = try t.alloc.dupe(u8, s.id),
                .title = try t.alloc.dupe(u8, s.title),
            });
        }
        const sctx = struct {
            lines: *std.ArrayList([]const u8),
            steps: *std.ArrayList(StepView),
            alloc: Allocator,
        };
        var ctx = sctx{ .lines = &t.prog_lines, .steps = &t.install_steps, .alloc = t.alloc };
        const cb = struct {
            fn f(c: ?*anyopaque, i: usize, of: usize, id: []const u8, state: []const u8) void {
                const sc: *sctx = @ptrCast(@alignCast(c orelse return));
                const ln = std.fmt.allocPrint(sc.alloc, "[{}/{}] {s} — {s}", .{ i, of, state, id }) catch return;
                sc.lines.append(sc.alloc, ln) catch return;
                for (sc.steps.items) |*s| {
                    if (std.mem.eql(u8, s.id, id)) s.state = state;
                }
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
            t.status_err = true;
            t.mode = .failed;
            return;
        };
        t.mode = .done;
        t.status = "install preview complete (dry-run)";
        t.status_err = false;
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
        var matched = false;
        for (f.options, 0..) |o, i| {
            if (std.mem.eql(u8, o.v, cur)) {
                idx = i;
                matched = true;
                break;
            }
        }
        const n = f.options.len;
        // unset value → first option on forward cycle, last on backward
        const ni: usize = if (!matched)
            (if (dir > 0) 0 else n - 1)
        else
            @intCast(@mod(@as(i32, @intCast(idx)) + dir, @as(i32, @intCast(n))));
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
    const env = wiz.env orelse return null; // unknown, not absent
    for (env.gpus) |g| {
        if (std.mem.eql(u8, g.vendor, "nvidia"))
            return if (engine.detect.nvidiaIsTuringPlus(g)) .open_capable else .legacy;
    }
    return .absent;
}

const fg_green: vaxis.Color = .{ .index = 10 };
const fg_red: vaxis.Color = .{ .index = 9 };
const fg_dim: vaxis.Color = .{ .index = 8 };
const fg_cyan: vaxis.Color = .{ .index = 14 };
const accent: vaxis.Style = .{ .fg = fg_cyan, .bold = true };
const sel: vaxis.Style = .{ .reverse = true };
/// editing reads differently from mere focus — underline marks the row
/// whose keys are currently being captured.
const editing_style: vaxis.Style = .{ .reverse = true, .ul_style = .single };
const dim: vaxis.Style = .{ .fg = fg_dim };
const err_style: vaxis.Style = .{ .fg = fg_red };
const ok_style: vaxis.Style = .{ .fg = fg_green };

fn repStr(a: Allocator, s: []const u8, n: usize) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    for (0..n) |_| try aw.writer.writeAll(s);
    return aw.written();
}

fn fieldOnPage(pv: PageView, name: []const u8) bool {
    for (pv.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

/// draw the nav rail: section headers dim-caps, pages numbered for
/// `g<N>` jumps, done/current/todo glyphs.
fn drawRail(t: *Tui, win: vaxis.Window, fa: Allocator, h: u16) !void {
    var row: u16 = 1;
    var last_section: []const u8 = "";
    for (t.pv.nav, 0..) |n, i| {
        if (row >= h -| 2) break;
        if (!std.mem.eql(u8, n.section, last_section)) {
            _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " {s}", .{n.section}), .style = .{ .fg = fg_dim, .bold = true } }}, .{ .row_offset = row });
            last_section = n.section;
            row += 1;
            if (row >= h -| 2) break;
        }
        const done_ = std.mem.eql(u8, n.state, "done");
        const cur = std.mem.eql(u8, n.state, "current");
        const glyph = if (done_) "✓" else if (cur) "▶" else "○";
        const sty: vaxis.Style = if (cur) accent else if (done_) ok_style else dim;
        // clip long titles rather than bleeding over the divider
        const title = if (n.title.len > 17) n.title[0..16] else n.title;
        // tenth entry shows 0 — the key handler maps '0' to index 9,
        // and only single digits are accepted
        const ln = try std.fmt.allocPrint(fa, " {d} {s} {s}", .{ (i + 1) % 10, glyph, title });
        _ = win.print(&.{.{ .text = ln, .style = sty }}, .{ .row_offset = row });
        row += 1;
    }
}

fn drawModal(t: *Tui, win: vaxis.Window, fa: Allocator, w: u16, h: u16) !void {
    const bw: u16 = @min(w -| 4, 52);
    const bh: u16 = 9;
    const bx = (w -| bw) / 2;
    const by = (h -| bh) / 2;
    const dev = t.wiz.cfg.disk.device;
    const base = std.fs.path.basename(dev);
    // size makes the destructive choice concrete — "vdb" alone is a
    // name; "vdb · 25 GiB" is the thing being wiped
    var dev_line: []const u8 = dev;
    if (t.wiz.env) |env| {
        for (env.disks) |d| {
            if (std.mem.eql(u8, d.path, dev)) {
                // match the disk list's precision — sub-GiB disks read
                // MiB, not "0 GiB"
                dev_line = if (d.size_bytes >= (1 << 30))
                    try std.fmt.allocPrint(fa, "{s} · {} GiB{s}", .{ dev, d.size_bytes / (1 << 30), if (d.removable) " (removable)" else "" })
                else if (d.size_bytes > 0)
                    try std.fmt.allocPrint(fa, "{s} · {} MiB{s}", .{ dev, d.size_bytes >> 20, if (d.removable) " (removable)" else "" })
                else
                    dev;
                break;
            }
        }
    }
    const bar = try repStr(fa, "─", bw - 2);
    _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, "╭{s}╮", .{bar}), .style = err_style }}, .{ .row_offset = by, .col_offset = bx });
    _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, "╰{s}╯", .{bar}), .style = err_style }}, .{ .row_offset = by + bh - 1, .col_offset = bx });
    for (1..bh - 1) |i| {
        _ = win.print(&.{.{ .text = "│", .style = err_style }}, .{ .row_offset = by + @as(u16, @intCast(i)), .col_offset = bx });
        _ = win.print(&.{.{ .text = "│", .style = err_style }}, .{ .row_offset = by + @as(u16, @intCast(i)), .col_offset = bx + bw - 1 });
        _ = win.print(&.{.{ .text = try repStr(fa, " ", bw - 2), .style = .{} }}, .{ .row_offset = by + @as(u16, @intCast(i)), .col_offset = bx + 1 });
    }
    _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " Install onto {s}?", .{dev_line}), .style = .{ .bold = true, .fg = fg_red } }}, .{ .row_offset = by + 1, .col_offset = bx + 1 });
    _ = win.print(&.{.{ .text = " All data on the disk will be erased.", .style = .{} }}, .{ .row_offset = by + 2, .col_offset = bx + 1 });
    _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " type `{s}` to continue — TUI previews only (dry-run)", .{base}), .style = dim }}, .{ .row_offset = by + 4, .col_offset = bx + 1 });
    _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " > {s}▌", .{t.edit_buf.items}), .style = .{} }}, .{ .row_offset = by + 6, .col_offset = bx + 1 });
    _ = win.print(&.{.{ .text = " esc cancel · enter confirm", .style = dim }}, .{ .row_offset = by + 7, .col_offset = bx + 1 });
}

/// install progress: left = step timeline, right = tail of the run log;
/// done/failed add a centered result panel over the timeline.
fn drawProgress(t: *Tui, win: vaxis.Window, fa: Allocator, w: u16, h: u16) !void {
    var row: u16 = 2;
    if (t.install_steps.items.len > 0) {
        var done_n: usize = 0;
        for (t.install_steps.items) |s| {
            if (std.mem.eql(u8, s.state, "done") or std.mem.eql(u8, s.state, "skipped")) done_n += 1;
        }
        _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " steps  ({d}/{d})", .{ done_n, t.install_steps.items.len }), .style = .{ .fg = fg_dim, .bold = true } }}, .{ .row_offset = 1 });
        for (t.install_steps.items) |s| {
            if (row >= h -| 4) break;
            const done_ = std.mem.eql(u8, s.state, "done");
            const started = std.mem.eql(u8, s.state, "started");
            const failed_ = std.mem.eql(u8, s.state, "failed");
            const skipped_ = std.mem.eql(u8, s.state, "skipped");
            const glyph = if (done_) "✓" else if (failed_) "✗" else if (started) "▸" else if (skipped_) "·" else "○";
            const sty: vaxis.Style = if (failed_) err_style else if (started) accent else if (done_) ok_style else dim;
            _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " {s} {s}", .{ glyph, s.title }), .style = sty }}, .{ .row_offset = row });
            row += 1;
        }
    }
    // log tail on the right — last N lines that fit
    const lx: u16 = 30;
    const cap = h -| 4;
    const first = if (t.prog_lines.items.len > cap) t.prog_lines.items.len - cap else 0;
    var lr: u16 = 2;
    for (t.prog_lines.items[first..]) |ln| {
        if (lr >= h -| 3) break;
        _ = win.print(&.{.{ .text = ln, .style = .{} }}, .{ .row_offset = lr, .col_offset = lx });
        lr += 1;
    }
    const sty: vaxis.Style = if (t.mode == .failed) err_style else if (t.mode == .done) ok_style else .{};
    _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " {s}", .{t.status}), .style = sty }}, .{ .row_offset = h -| 2 });

    // result panel — a boxed verdict on the finished state. .failed
    // always deserves it (even a pre-step failure), but .done also
    // covers quitting the wizard — no steps ran, and "✓ finished"
    // would falsely report completion.
    if (t.mode == .failed or (t.mode == .done and t.install_steps.items.len > 0)) {
        const psty: vaxis.Style = if (t.mode == .done) ok_style else err_style;
        const title = if (t.mode == .done) " ✓ finished " else " ✗ failed ";
        const bw: u16 = @min(w -| 4, @max(title.len + 6, t.status.len + 8));
        const bh: u16 = 5;
        const bx = (w -| bw) / 2;
        const by = (h -| bh) / 2;
        _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, "╭{s}╮", .{try repStr(fa, "─", bw - 2)}), .style = psty }}, .{ .row_offset = by, .col_offset = bx });
        _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, "╰{s}╯", .{try repStr(fa, "─", bw - 2)}), .style = psty }}, .{ .row_offset = by + bh - 1, .col_offset = bx });
        for (1..bh - 1) |i| {
            _ = win.print(&.{.{ .text = "│", .style = psty }}, .{ .row_offset = by + @as(u16, @intCast(i)), .col_offset = bx });
            _ = win.print(&.{.{ .text = "│", .style = psty }}, .{ .row_offset = by + @as(u16, @intCast(i)), .col_offset = bx + bw - 1 });
            _ = win.print(&.{.{ .text = try repStr(fa, " ", bw - 2), .style = .{} }}, .{ .row_offset = by + @as(u16, @intCast(i)), .col_offset = bx + 1 });
        }
        _ = win.print(&.{.{ .text = title, .style = .{ .bold = true, .fg = if (t.mode == .done) fg_green else fg_red } }}, .{ .row_offset = by + 1, .col_offset = bx + 1 });
        _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " {s}", .{t.status}), .style = .{} }}, .{ .row_offset = by + 2, .col_offset = bx + 1 });
        _ = win.print(&.{.{ .text = " q to quit", .style = dim }}, .{ .row_offset = by + 3, .col_offset = bx + 1 });
    }
}

fn draw(t: *Tui, win: vaxis.Window) !void {
    win.clear();
    // transient draw strings live on the frame arena — the process
    // allocator would grow by one redraw per keypress otherwise.
    const fa = t.frame_arena.allocator();
    const w = win.width;
    const h = win.height;
    if (w < 30 or h < 12) {
        _ = win.print(&.{.{ .text = "terminal too small", .style = err_style }}, .{});
        return;
    }

    // header — brand + flow badge, page position right-aligned.
    const head = try std.fmt.allocPrint(fa, " gentoo-installer  ·  {s} flow", .{@tagName(t.wiz.flow)});
    _ = win.print(&.{.{ .text = head, .style = .{ .reverse = true, .bold = true } }}, .{ .row_offset = 0, .col_offset = 0 });
    const pos = if (t.mode == .form or t.mode == .editing or t.mode == .confirm_install)
        try std.fmt.allocPrint(fa, "{d}/{d} ", .{ t.pv.index, t.pv.of })
    else
        " ";
    _ = win.print(&.{.{ .text = pos, .style = .{ .reverse = true, .bold = true } }}, .{ .row_offset = 0, .col_offset = w -| @as(u16, @intCast(pos.len)) });
    _ = win.print(&.{.{ .text = try repStr(fa, " ", w -| @as(u16, @intCast(head.len)) -| @as(u16, @intCast(pos.len))), .style = .{ .reverse = true } }}, .{ .row_offset = 0, .col_offset = @intCast(head.len) });
    t.last_h = h;

    if (t.mode == .plan_preview) {
        const total = t.plan_lines.items.len;
        // "commands" = `     $` exec lines only — step headings, notes
        // and write_file lines ride in the same stream
        var ncmd: usize = 0;
        for (t.plan_lines.items) |ln| {
            if (std.mem.startsWith(u8, ln, "     $")) ncmd += 1;
        }
        const vis = h -| 4;
        t.plan_scroll = @min(t.plan_scroll, total -| vis);
        _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " plan preview — {d} commands  ·  ↑↓ scroll · esc return", .{ncmd}), .style = accent }}, .{ .row_offset = 2 });
        var prow: u16 = 3;
        for (t.plan_lines.items[@min(t.plan_scroll, total)..]) |ln| {
            if (prow >= h -| 1) break;
            _ = win.print(&.{.{ .text = ln, .style = .{} }}, .{ .row_offset = prow });
            prow += 1;
        }
        if (t.plan_scroll > 0)
            _ = win.print(&.{.{ .text = " ↑", .style = dim }}, .{ .row_offset = 2, .col_offset = w -| 3 });
        if (t.plan_scroll + vis < total)
            _ = win.print(&.{.{ .text = " ↓", .style = dim }}, .{ .row_offset = h -| 2, .col_offset = w -| 3 });
        if (t.show_help) try drawHelp(win, fa, w, h);
        return;
    }

    if (t.mode == .progress or t.mode == .done or t.mode == .failed) {
        try drawProgress(t, win, fa, w, h);
        _ = win.print(&.{.{ .text = " q quit", .style = .{ .reverse = true } }}, .{ .row_offset = h -| 1 });
        if (t.show_help) try drawHelp(win, fa, w, h);
        return;
    }

    if (t.mode == .confirm_install) {
        if (w >= 60) try drawRail(t, win, fa, h);
        try drawModal(t, win, fa, w, h);
        if (t.show_help) try drawHelp(win, fa, w, h);
        return;
    }

    // the rail collapses on narrow terminals — 24 cols of rail leaves
    // almost no room for fields under ~60 cols of terminal
    const rail_w: u16 = if (w < 60) 0 else 24;
    const cx: u16 = if (rail_w == 0) 1 else rail_w + 2;
    if (rail_w > 0) {
        try drawRail(t, win, fa, h);
        // rail/content divider
        for (1..h -| 2) |i| {
            _ = win.print(&.{.{ .text = "│", .style = dim }}, .{ .row_offset = @intCast(i), .col_offset = rail_w });
        }
    }

    var row: u16 = 1;
    _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " {s}", .{t.pv.title}), .style = .{ .bold = true, .fg = fg_cyan } }}, .{ .row_offset = row, .col_offset = cx });
    row += 1;
    if (t.pv.subtitle.len > 0) {
        _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " {s}", .{t.pv.subtitle}), .style = dim }}, .{ .row_offset = row, .col_offset = cx });
        row += 1;
    }
    _ = win.print(&.{.{ .text = try repStr(fa, "─", w -| cx -| 1), .style = dim }}, .{ .row_offset = row, .col_offset = cx });
    row += 2;

    // review page: grouped config cards — scrollable; 'g<N>' jumps to
    // the owning page, arrows scroll the summary (fields.len == 0).
    var li: usize = 0;
    if (t.pv.summary.len > 0) {
        for (t.pv.summary) |g| {
            if (li >= t.scroll and row < h -| 7) {
                var gi: []const u8 = "";
                for (t.pv.nav, 0..) |n, i| {
                    if (std.mem.eql(u8, n.id, g.edit)) gi = try std.fmt.allocPrint(fa, "  (g{d} to edit)", .{(i + 1) % 10});
                }
                _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " {s}{s}", .{ g.title, gi }), .style = accent }}, .{ .row_offset = row, .col_offset = cx });
                row += 1;
            }
            li += 1;
            for (g.lines) |ln| {
                if (li >= t.scroll and row < h -| 7) {
                    _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, "   {s}", .{ln}), .style = .{} }}, .{ .row_offset = row, .col_offset = cx });
                    row += 1;
                }
                li += 1;
            }
        }
    }
    // pages without fields can't show errors inline — a whole-config
    // gate joins the scroll stream so >3 problems stay reachable.
    // Under ~3 scroll rows the stream can't render at all — the gate
    // list goes flat in the content rows instead of vanishing.
    const short_stream = (h -| 11) < 3;
    if (t.pv.fields.len == 0) {
        var has_err = false;
        for (t.errors.items) |e| {
            if (e.on_page) {
                has_err = true;
                break;
            }
        }
        if (has_err) {
            // the "problems" header is one virtual item in both modes —
            // short mode leaves its slot so scrollTotal's numbering
            // lines up whether or not the stream has room to draw it
            if (!short_stream and li >= t.scroll and row < h -| 7) {
                _ = win.print(&.{.{ .text = " problems", .style = err_style }}, .{ .row_offset = row, .col_offset = cx });
                row += 1;
            }
            li += 1;
            var er: u16 = 5;
            var shown: usize = 0;
            var skipped: usize = 0;
            var on_total: usize = 0;
            for (t.errors.items) |e| {
                if (!e.on_page) continue;
                on_total += 1;
                if (short_stream) {
                    // flat rows 5..h-6, still offset by scroll — items
                    // above the window are skipped, items below counted
                    if (li < t.scroll) {
                        skipped += 1;
                    } else if (er < h -| 5) {
                        _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " ↳ {s}", .{e.msg}), .style = err_style }}, .{ .row_offset = er, .col_offset = cx });
                        er += 1;
                        shown += 1;
                    }
                } else if (li >= t.scroll and row < h -| 7) {
                    _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, "   ↳ {s}", .{e.msg}), .style = err_style }}, .{ .row_offset = row, .col_offset = cx });
                    row += 1;
                }
                li += 1;
            }
            if (short_stream and on_total - shown - skipped > 0) {
                _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " … +{d} problems", .{on_total - shown - skipped}), .style = err_style }}, .{ .row_offset = h -| 5, .col_offset = cx });
            }
        }
    }

    // fields — label col, value col, focused enum expands into an
    // option list, help + errors inline under the field.
    var vi: usize = 0;
    const max_rows = h -| 9;
    for (t.pv.fields, 0..) |f, i| {
        if (vi < t.scroll) {
            vi += 1;
            continue;
        }
        if (row > 2 + max_rows) break;
        vi += 1;
        const is_focus = i == t.focus;
        const sty: vaxis.Style = if (t.mode == .editing and i == t.edit_field) editing_style else if (is_focus) sel else .{};
        _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " {s}", .{f.label}), .style = sty }}, .{ .row_offset = row, .col_offset = cx });
        var vbuf: std.Io.Writer.Allocating = .init(fa);
        try renderValue(&vbuf.writer, f, t, i);
        _ = win.print(&.{.{ .text = vbuf.written(), .style = sty }}, .{ .row_offset = row, .col_offset = cx + @min(26, w / 4) });
        row += 1;
        // focused enum expands inline: option list w/ current marked;
        // the window follows the selection so options past the first
        // six stay visible while cycling.
        if (is_focus and std.mem.eql(u8, f.ftype, "enum") and f.options.len > 0 and t.mode == .form) {
            const cur = switch (f.value) {
                .string => |s| s,
                else => "",
            };
            const show = @min(f.options.len, 6);
            var cur_i: usize = 0;
            for (f.options, 0..) |o, opt_i| {
                if (std.mem.eql(u8, o.v, cur)) {
                    cur_i = opt_i;
                    break;
                }
            }
            const oi = if (f.options.len <= show) 0 else @min(cur_i -| 2, f.options.len - show);
            for (f.options[oi .. oi + show]) |o| {
                if (row > 2 + max_rows) break;
                const on = std.mem.eql(u8, o.v, cur);
                var obuf: std.Io.Writer.Allocating = .init(fa);
                try obuf.writer.print("   {s} {s}", .{ if (on) "●" else "○", o.label });
                if (o.help) |oh| try obuf.writer.print("  ·  {s}", .{oh});
                _ = win.print(&.{.{ .text = obuf.written(), .style = if (on) accent else dim }}, .{ .row_offset = row, .col_offset = cx });
                row += 1;
            }
            if (f.options.len > show and row <= 2 + max_rows) {
                _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, "   … {} more", .{f.options.len - show}), .style = dim }}, .{ .row_offset = row, .col_offset = cx });
                row += 1;
            }
        }
        // focused field help line
        if (is_focus and f.help != null and row <= 2 + max_rows and !std.mem.eql(u8, f.ftype, "enum")) {
            _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, "   {s}", .{f.help.?}), .style = dim }}, .{ .row_offset = row, .col_offset = cx });
            row += 1;
        }
        // inline errors for this field
        for (t.errors.items) |e| {
            if (e.field) |ef| {
                if (std.mem.eql(u8, ef, f.name)) {
                    if (row > 2 + max_rows) break;
                    _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, "   ↳ {s}", .{e.msg}), .style = err_style }}, .{ .row_offset = row, .col_offset = cx });
                    row += 1;
                }
            }
        }
    }

    // clipped-field indicators — a scrolled list reads as complete
    // otherwise
    if (t.pv.fields.len > 0) {
        if (t.scroll > 0)
            _ = win.print(&.{.{ .text = " ↑", .style = dim }}, .{ .row_offset = @intCast(t.contentStart() -| 1), .col_offset = w -| 4 });
        if (vi < t.pv.fields.len)
            _ = win.print(&.{.{ .text = " ↓", .style = dim }}, .{ .row_offset = h -| 8, .col_offset = w -| 4 });
    }

    // actions row — pinned above the footer so a long page can't push
    // buttons offscreen.
    if (t.pv.actions.len > 0) {
        const act_row = h -| 3;
        var col: u16 = cx;
        for (t.pv.actions, 0..) |a, i| {
            const is_focus = (t.focus == t.pv.fields.len) and t.action_sel == i;
            // the TUI's install is a dry-run preview — label it so.
            const shown = if (std.mem.eql(u8, a, "install")) "install (dry-run)" else a;
            const label = try std.fmt.allocPrint(fa, "[ {s} ]", .{shown});
            _ = win.print(&.{.{ .text = label, .style = if (is_focus) sel else accent }}, .{ .row_offset = act_row, .col_offset = col });
            col += @intCast(label.len + 1);
        }
    }

    // page-level errors (unattributed or off-page) as a banner — only
    // when the error actually belongs to the page being shown. Field-less
    // pages render them in the scroll stream instead (see above).
    var n_banner: u16 = 0;
    for (t.errors.items) |e| {
        if (t.pv.fields.len == 0) break;
        if (!e.on_page) continue;
        const unattributed = e.field == null or !fieldOnPage(t.pv, e.field.?);
        if (!unattributed) continue;
        if (n_banner > 2) {
            var more: usize = 0;
            for (t.errors.items) |e2| {
                if (e2.on_page and (e2.field == null or !fieldOnPage(t.pv, e2.field.?))) more += 1;
            }
            _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, "  … {} problems", .{more}), .style = err_style }}, .{ .row_offset = h -| 6 + n_banner, .col_offset = cx });
            break;
        }
        _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, " {s}", .{e.msg}), .style = err_style }}, .{ .row_offset = h -| 6 + n_banner, .col_offset = cx });
        n_banner += 1;
    }

    // footer
    const foot = if (t.mode == .editing)
        if (t.confirming) " confirm: type again · enter commit · esc cancel" else " editing — enter commit · esc cancel"
    else if (t.goto_armed)
        " g<N>: pick a page number from the rail"
    else
        " ↑↓ navigate · enter edit · ←→/space pick · PgUp/Dn page · g<N> jump · ? keys · q quit";
    _ = win.print(&.{.{ .text = foot, .style = .{ .reverse = true } }}, .{ .row_offset = h -| 1 });
    if (t.status.len > 0)
        _ = win.print(&.{.{ .text = t.status, .style = if (t.status_err) err_style else ok_style }}, .{ .row_offset = h -| 2, .col_offset = cx });

    if (t.show_help) try drawHelp(win, fa, w, h);
}

/// `?` overlay — a centered box of key help; drawn last so it floats
/// above whatever mode is underneath.
fn drawHelp(win: vaxis.Window, fa: Allocator, w: u16, h: u16) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, HELP_TEXT, '\n');
    while (it.next()) |l| try lines.append(fa, l);
    // bound by the terminal — the overlay must stay drawable at the
    // supported 30-col minimum, so shrink the box and clip lines to
    // the interior rather than spilling off the right edge
    const bw: u16 = @min(52, w -| 4);
    const iw: usize = bw -| 4;
    const bh: u16 = @intCast(@min(lines.items.len + 2, h -| 4));
    const bx = (w -| bw) / 2;
    const by = (h -| bh) / 2;
    _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, "╭{s}╮", .{try repStr(fa, "─", bw - 2)}), .style = accent }}, .{ .row_offset = by, .col_offset = bx });
    _ = win.print(&.{.{ .text = try std.fmt.allocPrint(fa, "╰{s}╯", .{try repStr(fa, "─", bw - 2)}), .style = accent }}, .{ .row_offset = by + bh - 1, .col_offset = bx });
    for (1..bh - 1) |i| {
        _ = win.print(&.{.{ .text = "│", .style = accent }}, .{ .row_offset = by + @as(u16, @intCast(i)), .col_offset = bx });
        _ = win.print(&.{.{ .text = "│", .style = accent }}, .{ .row_offset = by + @as(u16, @intCast(i)), .col_offset = bx + bw - 1 });
        _ = win.print(&.{.{ .text = try repStr(fa, " ", bw - 2), .style = .{} }}, .{ .row_offset = by + @as(u16, @intCast(i)), .col_offset = bx + 1 });
    }
    for (lines.items[0..@min(lines.items.len, bh -| 2)], 0..) |l, i| {
        _ = win.print(&.{.{ .text = l[0..@min(l.len, iw)], .style = .{} }}, .{ .row_offset = by + 1 + @as(u16, @intCast(i)), .col_offset = bx + 1 });
    }
}

fn renderValue(w: *std.Io.Writer, f: FieldView, t: *Tui, i: usize) !void {
    if (t.mode == .editing and i == t.edit_field) {
        if (std.mem.eql(u8, f.ftype, "secret")) {
            for (0..t.edit_buf.items.len) |_| try w.writeAll("●");
            if (t.confirming) try w.writeAll("  [confirm]");
            try w.writeAll("▌");
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
        if (cur.len == 0) {
            try w.writeAll("◀ (not set) ▶");
            return;
        }
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
        .string => |s| {
            if (s.len == 0) try w.writeAll("(not set)") else try w.writeAll(s);
        },
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
        else => try w.writeAll("(not set)"),
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
    defer t.wiz.deinit();

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
                // help overlay swallows keys until dismissed — no
                // `continue`: the redraw at loop end must paint the
                // toggle
                if (t.show_help) {
                    if (key.matches('?', .{}) or key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{}))
                        t.show_help = false;
                } else if (key.text != null and key.text.?.len == 1 and key.text.?[0] == '?' and
                    // '?' is literal input in the text-entry modes —
                    // help can't take it there
                    (t.mode == .form or t.mode == .plan_preview or t.mode == .done or t.mode == .failed))
                {
                    t.show_help = true;
                } else if (t.mode == .done or t.mode == .failed) {
                    if (key.matches('q', .{})) break;
                } else if (t.mode == .plan_preview) {
                    if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
                        t.mode = .form;
                    } else if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                        t.plan_scroll = t.plan_scroll -| 1;
                    } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                        t.plan_scroll +|= 1;
                    } else if (key.matches(vaxis.Key.page_up, .{})) {
                        t.plan_scroll = t.plan_scroll -| 10;
                    } else if (key.matches(vaxis.Key.page_down, .{})) {
                        t.plan_scroll +|= 10;
                    }
                } else if (t.mode == .confirm_install) {
                    if (key.matches(vaxis.Key.enter, .{})) {
                        const base = std.fs.path.basename(t.wiz.cfg.disk.device);
                        if (std.mem.eql(u8, std.mem.trim(u8, t.edit_buf.items, " "), base)) {
                            try t.runInstall();
                        } else {
                            t.mode = .form;
                            t.status = "confirm mismatch";
                            t.status_err = true;
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
                                t.status_err = true;
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
                    if (t.goto_armed) {
                        t.goto_armed = false;
                        if (key.text) |txt| {
                            if (txt.len == 1 and txt[0] >= '1' and txt[0] <= '9')
                                try t.gotoPage(txt[0] - '1')
                            else if (txt.len == 1 and txt[0] == '0')
                                try t.gotoPage(9);
                        }
                    } else if (key.matches('g', .{})) {
                        t.goto_armed = true;
                    } else if (key.matches('q', .{})) break;
                    // review page (no fields): ↑/↓ scroll the summary
                    const review_scroll = t.pv.fields.len == 0 and t.pv.summary.len > 0;
                    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
                        if (review_scroll) {
                            t.scroll = t.scroll -| 1;
                        } else {
                            if (t.focus > 0) t.focus -= 1 else {
                                // wrap to action row
                                t.focus = t.pv.fields.len;
                            }
                            t.ensureFocusVisible();
                        }
                    } else if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
                        if (review_scroll) {
                            const total = t.scrollTotal();
                            const vis: usize = ((t.last_h -| 8) -| t.contentStart()) + 1;
                            t.scroll = @min(t.scroll + 1, total -| vis);
                        } else {
                            t.focus = @min(t.focus + 1, t.pv.fields.len);
                            t.ensureFocusVisible();
                        }
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
        try t.refreshErrors();
        const win = vx.window();
        try draw(&t, win);
        try vx.render(tty.writer());
    }
}
