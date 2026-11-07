//! Column (Miller) view, Finder's third layout, shows the path as side-by-side lists: a
//! few ancestor folders, the current folder, and on the right what the selected item
//! holds (a folder's contents, or a file's details). The current folder's column is
//! the browser's own list, so selection, drag and drop, menus, rename and every
//! shortcut behave as in the list view; Left/Right move along the path. The other
//! columns come from a DirCache (read off the render thread).

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const c = cimgui.c;
const theme = @import("../theme.zig");
const core = @import("core");
const scan = core.scan;
const actions = @import("actions.zig");
const table = @import("table.zig");
const thumbs = @import("../thumbs.zig");
const dircache = @import("../dircache.zig");
const icons = @import("icons.zig");

const Browser = core.browser.Browser;
const ViewActions = actions.ViewActions;

const ancestors_shown = 2; // parent columns to the left of the current folder

pub const ColumnsView = struct {
    base: table.TableView = .{}, // rename + type-ahead state and shared helpers
    last_dir_len: usize = 0, // to scroll to the right end when the path changes
    last_dir_hash: u64 = 0,
    // The folder the columns were last laid out for. While the browser loads a new
    // folder it still holds the old listing, so the old layout stays on screen until
    // the new one is complete; otherwise the columns jump twice per step.
    shown_dir: [std.fs.max_path_bytes]u8 = undefined,
    shown_dir_len: usize = 0,
    // A click in a side column: go to nav_dir with nav_name selected, applied after
    // the frame's columns are drawn, since navigating frees the b.dir they slice.
    nav_dir: [std.fs.max_path_bytes]u8 = undefined,
    nav_dir_len: usize = 0,
    nav_name: [512]u8 = undefined,
    nav_name_len: usize = 0,
    row_h: f32 = 0, // a row's height this frame: the text's, taller with the item size

    fn queueNav(self: *ColumnsView, dir: []const u8, name: []const u8) void {
        if (dir.len > self.nav_dir.len or name.len > self.nav_name.len) return;
        @memcpy(self.nav_dir[0..dir.len], dir);
        self.nav_dir_len = dir.len;
        @memcpy(self.nav_name[0..name.len], name);
        self.nav_name_len = name.len;
    }

    pub fn draw(self: *ColumnsView, b: *Browser, act: *ViewActions, keyboard: bool, list_height: f32) void {
        self.row_h = @round(c.igGetTextLineHeight() * act.columns_scale);
        if (b.takeWantRename() and b.count() > 0) self.base.beginRename(b, b.sel.cursor);
        const popup_open = c.igIsPopupOpen_Str(null, c.ImGuiPopupFlags_AnyPopup);
        if (keyboard and !popup_open and self.base.renaming == null) {
            handleNav(b);
            _ = self.base.typeAhead(b);
            self.base.handleOpKeys(b, act);
        }
        const reveal = b.sel.takeReveal();
        if (!b.loading) {
            const n = @min(b.dir.len, self.shown_dir.len);
            @memcpy(self.shown_dir[0..n], b.dir[0..n]);
            self.shown_dir_len = n;
        }
        const dir: []const u8 = if (b.loading and self.shown_dir_len > 0) self.shown_dir[0..self.shown_dir_len] else b.dir;
        const cache = act.dirs orelse {
            cimgui.textUnformatted("Loading\u{2026}");
            return;
        };

        const fs = c.igGetFontSize();
        const col_w = @round(fs * 17);
        const area_min = c.igGetCursorScreenPos();
        const avail = c.igGetContentRegionAvail();
        const h = if (list_height > 0) list_height else avail.y + list_height;

        // Path columns: ancestors (outermost first), then the current folder.
        var anc: [ancestors_shown][]const u8 = undefined;
        var n_anc: usize = 0;
        if (!b.virtualView()) {
            var p: []const u8 = dir;
            while (n_anc < ancestors_shown) {
                const parent = std.fs.path.dirname(p) orelse break;
                anc[n_anc] = parent;
                n_anc += 1;
                p = parent;
            }
        }

        if (!c.igBeginChild_Str("##columns", cimgui.vec2(0, list_height), 0, c.ImGuiWindowFlags_HorizontalScrollbar)) {
            c.igEndChild();
            return;
        }
        defer c.igEndChild();

        var k: usize = n_anc;
        while (k > 0) : (k -= 1) {
            const adir = anc[k - 1];
            // The child of `adir` on the way to the current folder: highlighted.
            const on_path = std.fs.path.basename(if (k - 1 == 0) dir else anc[k - 2]);
            self.drawSideColumn(b, cache, adir, on_path, col_w, k);
            c.igSameLine(0, 0);
        }
        // Keep this folder's own listing cached too: step back with Left and its
        // column is ready instead of reading it again.
        _ = cache.get(dir);
        self.drawCurrentColumn(b, act, dir, col_w, reveal);
        c.igSameLine(0, 0);
        self.drawPreviewColumn(b, act, cache, dir, col_w * 1.25);

        // A new folder: scroll so the current column and the preview are in view.
        const hsh = std.hash.Wyhash.hash(0, dir);
        if (hsh != self.last_dir_hash) {
            self.last_dir_hash = hsh;
            c.igSetScrollHereX(1.0);
        }

        self.base.list_min = area_min;
        self.base.list_max = cimgui.vec2(area_min.x + avail.x, area_min.y + h);
        if (b.pendingDropPos() != null) b.commitExternalDrop(b.dir);
        if (self.nav_dir_len > 0) {
            b.navigate(self.nav_dir[0..self.nav_dir_len]) catch {};
            b.setPendingSelect(self.nav_name[0..self.nav_name_len]);
            self.nav_dir_len = 0;
        }
    }

    /// drawSideColumn lists folder `dir` (an ancestor): `mark` is highlighted; clicking
    /// an item goes to `dir` with that item selected.
    fn drawSideColumn(self: *ColumnsView, b: *Browser, cache: *dircache.DirCache, dir: []const u8, mark: []const u8, w: f32, id: usize) void {
        c.igPushID_Int(@intCast(id));
        defer c.igPopID();
        _ = c.igBeginChild_Str("##side", cimgui.vec2(w, 0), c.ImGuiChildFlags_Borders, 0);
        defer c.igEndChild();
        const d = cache.get(dir) orelse return;
        const l = d.listing orelse {
            // A first read takes a moment; an empty column for it beats a flashing
            // "Loading…".
            if (d.failed) dimText("Can't read this folder");
            return;
        };
        const idx = d.sorted(cache.alloc, b.sort_order, b.show_hidden);
        for (idx, 0..) |ei, row| {
            const e = l.entries[ei];
            const is_mark = std.mem.eql(u8, e.name, mark);
            c.igPushID_Int(@intCast(row));
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, table.nameColor(e));
            if (entryRow(e, e.name, is_mark, false, self.row_h)) self.queueNav(dir, e.name);
            c.igPopStyleColor(1);
            c.igPopID();
            if (is_mark and c.igIsWindowAppearing()) c.igSetScrollHereY(0.5);
        }
    }

    /// drawCurrentColumn is the browser's own list (selection, menus, drag and drop).
    fn drawCurrentColumn(self: *ColumnsView, b: *Browser, act: *ViewActions, dir: []const u8, w: f32, reveal: bool) void {
        _ = c.igBeginChild_Str("##current", cimgui.vec2(w, 0), c.ImGuiChildFlags_Borders, 0);
        defer c.igEndChild();
        if (b.loading and b.count() == 0) return;
        var open_idx: ?usize = null;
        const cnt = b.count();
        const clip = cimgui.ImGuiListClipper_ImGuiListClipper();
        cimgui.ImGuiListClipper_Begin(clip, @intCast(cnt), -1);
        if (reveal and b.sel.cursor < cnt) cimgui.ImGuiListClipper_IncludeItemByIndex(clip, @intCast(b.sel.cursor));
        while (cimgui.ImGuiListClipper_Step(clip)) {
            const range = cimgui.clipperRange(clip);
            var i: usize = @intCast(range.start);
            while (i < @as(usize, @intCast(range.end))) : (i += 1) {
                const e = b.at(i);
                b.wantDetails(i); // on screen: its details first
                if (self.base.renaming != null and self.base.renaming.? == i) {
                    self.base.rename_width = -1;
                    self.base.drawRenameField(b);
                    continue;
                }
                c.igPushID_Int(@intCast(i));
                c.igPushStyleColor_Vec4(c.ImGuiCol_Text, if (b.isCut(i)) theme.dim() else table.nameColor(e));
                const clicked = entryRow(e, std.fs.path.basename(e.name), b.sel.isSelected(i), b.isCut(i), self.row_h);
                c.igPopStyleColor(1);
                c.igPopID();
                if (e.tags != 0) {
                    const rmin = c.igGetItemRectMin();
                    const rmax = c.igGetItemRectMax();
                    const dots_w = @as(f32, @floatFromInt(@popCount(e.tags))) * c.igGetFontSize() * 0.4 + c.igGetFontSize() * 0.6;
                    _ = table.drawTagDots(c.igGetWindowDrawList(), rmax.x - dots_w, (rmin.y + rmax.y) * 0.5, e.tags);
                }
                if (clicked) {
                    if (c.igIsKeyDown_Nil(c.ImGuiMod_Shift)) b.sel.selectRange(i) else if (c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl)) b.sel.toggle(i) else b.sel.click(i);
                }
                if (c.igBeginDragDropSource(0)) {
                    if (!b.sel.isSelected(i)) b.sel.click(i);
                    b.beginDrag();
                    const pl = ViewActions.dragPayload(b);
                    _ = c.igSetDragDropPayload(table.DRAG_PAYLOAD, &pl, pl.len, 0);
                    table.drawDragPreview(b);
                    c.igEndDragDropSource();
                }
                if (e.isDir() and !table.isDragged(act, dir, e.name) and c.igBeginDragDropTarget()) {
                    const payload = c.igAcceptDragDropPayload(table.DRAG_PAYLOAD, 0);
                    if (payload != null and payload.*.Delivery) {
                        var dbuf: [4200]u8 = undefined;
                        if (act.dragSource(payload)) |src| if (table.joinPath(&dbuf, dir, e.name)) |dst|
                            b.dropDraggedInto(src.dragPaths(), dst, c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl));
                    }
                    c.igEndDragDropTarget();
                }
                if (c.igBeginPopupContextItem(null, c.ImGuiPopupFlags_MouseButtonRight)) {
                    if (!b.sel.isSelected(i)) b.sel.click(i);
                    act.rowMenu(b, i);
                    c.igEndPopup();
                }
                if (c.igIsItemHovered(0) and c.igIsMouseDoubleClicked_Nil(0)) open_idx = i;
                if (reveal and i == b.sel.cursor) c.igSetScrollHereY(0.5);
            }
        }
        cimgui.ImGuiListClipper_destroy(clip);
        if (open_idx) |idx| {
            if (b.at(idx).isDir()) ViewActions.swallowRelease();
            b.open(b.at(idx)) catch {};
        }
        table.backgroundMenu(b);
    }

    /// drawPreviewColumn shows what the cursor item holds: a folder's contents (click
    /// to go there with that item selected), or a file's thumbnail and details.
    fn drawPreviewColumn(self: *ColumnsView, b: *Browser, act: *ViewActions, cache: *dircache.DirCache, dir: []const u8, w: f32) void {
        _ = c.igBeginChild_Str("##preview", cimgui.vec2(w, 0), c.ImGuiChildFlags_Borders, 0);
        defer c.igEndChild();
        if (b.count() == 0 or b.sel.cursor >= b.count()) return;
        const e = b.at(b.sel.cursor);
        var pbuf: [4200]u8 = undefined;
        const path = table.joinPath(&pbuf, dir, e.name) orelse return;
        if (e.isDir()) {
            const d = cache.get(path) orelse return;
            const l = d.listing orelse {
                if (d.failed) dimText("Can't read this folder");
                return;
            };
            const idx = d.sorted(cache.alloc, b.sort_order, b.show_hidden);
            if (idx.len == 0) dimText("Empty folder");
            for (idx, 0..) |ei, row| {
                const ce = l.entries[ei];
                c.igPushID_Int(@intCast(row));
                c.igPushStyleColor_Vec4(c.ImGuiCol_Text, table.nameColor(ce));
                if (entryRow(ce, ce.name, false, false, self.row_h)) self.queueNav(path, ce.name);
                c.igPopStyleColor(1);
                c.igPopID();
            }
            return;
        }
        // A file: its thumbnail (images) and details, Finder's preview column.
        const fs = c.igGetFontSize();
        const box = @min(w - fs * 2, fs * 12);
        if (act.thumbs) |tc| if (thumbs.Cache.wants(e)) if (tc.get(path, e.mtime_secs)) |t| {
            const s = @min(box / t.w, box / t.h);
            const iw = t.w * s;
            const ih = t.h * s;
            const cur = c.igGetCursorPos();
            c.igSetCursorPos(cimgui.vec2(cur.x + (c.igGetContentRegionAvail().x - iw) * 0.5, cur.y + fs * 0.5));
            const ref: c.ImTextureRef_c = .{ ._TexData = null, ._TexID = t.tex };
            c.igImage(ref, cimgui.vec2(iw, ih), cimgui.vec2(0, 0), cimgui.vec2(1, 1));
        };
        c.igSpacing();
        c.igPushTextWrapPos(0);
        cimgui.textUnformatted(std.fs.path.basename(e.name));
        c.igPopTextWrapPos();
        var tb: [64]u8 = undefined;
        dimText(b.typeLabel(e, &tb));
        c.igSpacing();
        var sb: [32]u8 = undefined;
        var db: [24]u8 = undefined;
        infoRow("Size", scan.humanizeSize(&sb, e.size));
        infoRow("Modified", scan.formatDateFriendly(&db, e.mtime_secs, table.nowSecs()));
        if (e.btime_secs > 0) {
            var cb: [24]u8 = undefined;
            infoRow("Created", scan.formatDateFriendly(&cb, e.btime_secs, table.nowSecs()));
        }
        c.igSpacing();
        dimText("Space: Quick Look");
    }
};

/// handleNav: Up/Down move in the current column; Right enters the selected folder,
/// Left goes up with the folder you came from selected (Finder's column keys).
fn handleNav(b: *Browser) void {
    const shift = c.igIsKeyDown_Nil(c.ImGuiMod_Shift);
    if (c.igIsKeyDown_Nil(c.ImGuiMod_Alt)) return; // Alt+arrows are back/forward
    if (c.igIsKeyPressed_Bool(c.ImGuiKey_DownArrow, true)) b.sel.moveCursor(1, shift);
    if (c.igIsKeyPressed_Bool(c.ImGuiKey_UpArrow, true)) b.sel.moveCursor(-1, shift);
    if (c.igIsKeyPressed_Bool(c.ImGuiKey_RightArrow, false) and b.count() > 0 and b.sel.cursor < b.count()) {
        const e = b.at(b.sel.cursor);
        if (e.isDir()) b.open(e) catch {};
    }
    if (c.igIsKeyPressed_Bool(c.ImGuiKey_LeftArrow, false) and !b.virtualView()) {
        if (std.fs.path.dirname(b.dir)) |parent| {
            var nb: [std.fs.max_path_bytes]u8 = undefined;
            const name = std.fs.path.basename(b.dir);
            if (name.len <= nb.len) {
                @memcpy(nb[0..name.len], name);
                const pdup = b.alloc.dupe(u8, parent) catch return;
                defer b.alloc.free(pdup);
                b.navigate(pdup) catch {};
                b.setPendingSelect(nb[0..name.len]);
            }
        }
    }
    if (c.igIsKeyPressed_Bool(c.ImGuiKey_Enter, false)) b.openCursor() catch {};
    if (!c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl) and c.igIsKeyPressed_Bool(c.ImGuiKey_Backspace, false)) b.backOrUp();
}

fn dimText(s: []const u8) void {
    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
    cimgui.textUnformatted(s);
    c.igPopStyleColor(1);
}

fn infoRow(label: []const u8, value: []const u8) void {
    var buf: [128]u8 = undefined;
    const s = std.mem.print(&buf, "{s}: {s}", .{ label, value }) catch value;
    cimgui.textUnformatted(s);
}

/// entryRow is one row of a column, `rh` tall: the item's icon, its name (elided in
/// the middle to fit), and a chevron after a folder. Selected, it's the accent row.
/// Returns whether it was clicked.
fn entryRow(e: scan.Entry, name: []const u8, selected: bool, faded: bool, rh: f32) bool {
    if (selected) theme.pushSelected();
    defer if (selected) theme.popSelected();
    const dir = e.isDir();
    const fs = c.igGetFontSize();
    const chev = if (dir) fs * 1.2 else 0;
    const gap = @round(fs * 0.35);
    const pos = c.igGetCursorScreenPos();
    const room = c.igGetContentRegionAvail().x - chev - rh - gap;
    const clicked = c.igSelectable_Bool("##row", selected, 0, cimgui.vec2(0, rh));
    const dl = c.igGetWindowDrawList();
    icons.draw(dl, e, pos.x, pos.y, rh, faded);
    var fit: [600]u8 = undefined;
    const shown = core.elide.middle(&fit, name, room, cimgui.Measure{});
    const ty = pos.y + @round((rh - c.igGetTextLineHeight()) * 0.5);
    c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(pos.x + rh + gap, ty), c.igGetColorU32_Col(c.ImGuiCol_Text, 1), shown.ptr, shown.ptr + shown.len);
    if (dir) {
        const mx = c.igGetItemRectMax();
        const mn = c.igGetItemRectMin();
        const h = mx.y - mn.y;
        const x = mx.x - fs * 0.6;
        const y = mn.y + h * 0.5;
        const g = fs * 0.22;
        const col = c.igGetColorU32_Vec4(if (selected) theme.selectedText() else theme.dim());
        c.ImDrawList_AddLine(dl, cimgui.vec2(x - g, y - g * 1.6), cimgui.vec2(x + g * 0.4, y), col, 1.5);
        c.ImDrawList_AddLine(dl, cimgui.vec2(x + g * 0.4, y), cimgui.vec2(x - g, y + g * 1.6), col, 1.5);
    }
    return clicked;
}
