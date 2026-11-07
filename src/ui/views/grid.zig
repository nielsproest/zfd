//! Icon grid representation of a Browser (Finder's icon view): a wrapped grid of
//! cells (a thumbnail for images, else a drawn folder/document icon) with the name
//! below. Selection, drag and drop, context menus, rename, type-ahead and the
//! shortcuts behave exactly as in the table (they share the table's helpers and its
//! rename/type-ahead state); only layout and arrow-key movement differ.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const c = cimgui.c;
const theme = @import("../theme.zig");
const core = @import("core");
const scan = core.scan;
const actions = @import("actions.zig");
const table = @import("table.zig");
const thumbs = @import("../thumbs.zig");
const icons = @import("icons.zig");

const Browser = core.browser.Browser;
const ViewActions = actions.ViewActions;

pub const GridView = struct {
    base: table.TableView = .{}, // rename + type-ahead + marquee state, shared code
    cols: usize = 1, // columns in the last frame's layout (for Up/Down)

    pub fn draw(self: *GridView, b: *Browser, act: *ViewActions, keyboard: bool, list_height: f32) void {
        if (b.takeWantRename() and b.count() > 0) self.base.beginRename(b, b.sel.cursor);
        const popup_open = c.igIsPopupOpen_Str(null, c.ImGuiPopupFlags_AnyPopup);
        if (keyboard and !popup_open and self.base.renaming == null) {
            self.handleNav(b, act);
            _ = self.base.typeAhead(b);
            self.base.handleOpKeys(b, act);
        }
        self.drawGrid(b, act, b.sel.takeReveal(), list_height);
        self.base.listDropTarget(b, act);
    }

    fn handleNav(self: *GridView, b: *Browser, act: *ViewActions) void {
        const shift = c.igIsKeyDown_Nil(c.ImGuiMod_Shift);
        if (c.igIsKeyDown_Nil(c.ImGuiMod_Alt)) return; // Alt+arrows are back/forward
        const cols: isize = @intCast(@max(self.cols, 1));
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_RightArrow, true)) b.sel.moveCursor(1, shift);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_LeftArrow, true)) b.sel.moveCursor(-1, shift);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_DownArrow, true)) b.sel.moveCursor(cols, shift);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_UpArrow, true)) b.sel.moveCursor(-cols, shift);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Enter, false)) act.openCursor(b);
        if (!c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl) and c.igIsKeyPressed_Bool(c.ImGuiKey_Backspace, false)) b.backOrUp();
    }

    fn drawGrid(self: *GridView, b: *Browser, act: *ViewActions, reveal: bool, list_height: f32) void {
        const fs = c.igGetFontSize();
        const icon = @round(fs * 5.2 * act.icon_scale);
        // Two lines of name at the chosen text size, and the item info line.
        const label_h = c.igGetTextLineHeight() * act.text_scale * (if (act.item_info) @as(f32, 3) else 2);
        const sp = act.grid_spacing;
        // Names under the icons (Finder's default), or beside them in a wider cell.
        const cell_w = if (act.label_right) @round(icon + fs * 11 + fs * 1.2 * sp) else @round(icon + fs * 3.6 * sp);
        const cell_h = if (act.label_right) @round(@max(icon, label_h) + fs * 0.8 * sp) else @round(icon + label_h + fs * 1.1 * sp);

        const area_min = c.igGetCursorScreenPos();
        const avail = c.igGetContentRegionAvail();
        const area_h = if (list_height > 0) list_height else avail.y + list_height;
        const area_max = cimgui.vec2(area_min.x + avail.x, area_min.y + area_h);

        // Rubber band, as in the table: a press on empty space starts it.
        const tv = &self.base;
        if (!tv.marquee_active and c.igIsWindowHovered(c.ImGuiHoveredFlags_ChildWindows) and c.igIsMouseHoveringRect(area_min, area_max, false) and
            !c.igIsAnyItemHovered() and c.igIsMouseClicked_Bool(0, false))
        {
            tv.marquee_active = true;
            tv.marquee_add = c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl) or c.igIsKeyDown_Nil(c.ImGuiMod_Shift);
            tv.marquee_start = c.igGetMousePos();
            if (!tv.marquee_add) b.sel.clear();
        }
        if (tv.marquee_active and (c.igGetDragDropPayload() != null or !c.igIsMouseDown_Nil(0))) tv.marquee_active = false;
        var mr_min = cimgui.vec2(0, 0);
        var mr_max = cimgui.vec2(0, 0);
        if (tv.marquee_active) {
            const cur = c.igGetMousePos();
            mr_min = cimgui.vec2(@min(tv.marquee_start.x, cur.x), @min(tv.marquee_start.y, cur.y));
            mr_max = cimgui.vec2(@max(tv.marquee_start.x, cur.x), @max(tv.marquee_start.y, cur.y));
            if (!tv.marquee_add) b.sel.clear();
        }

        if (!c.igBeginChild_Str("##grid", cimgui.vec2(0, list_height), 0, 0)) {
            c.igEndChild();
            return;
        }
        defer c.igEndChild();

        const width = c.igGetContentRegionAvail().x;
        const cols: usize = @max(1, @as(usize, @intFromFloat(@floor(width / cell_w))));
        self.cols = cols;
        // Spread the slack evenly so the grid fills the width (Finder does the same).
        const gap = (width - @as(f32, @floatFromInt(cols)) * cell_w) / @as(f32, @floatFromInt(cols));
        const pitch = cell_w + gap;
        const cnt = b.count();
        const rows = (cnt + cols - 1) / cols;

        // Drag auto-scroll near the top/bottom edge.
        if (c.igIsDragDropActive()) {
            const mp = c.igGetMousePos();
            const band = fs * 2.5;
            if (mp.x >= area_min.x and mp.x <= area_max.x) {
                var dy: f32 = 0;
                if (mp.y >= area_min.y and mp.y < area_min.y + band) dy = -(band - (mp.y - area_min.y));
                if (mp.y <= area_max.y and mp.y > area_max.y - band) dy = band - (area_max.y - mp.y);
                if (dy != 0) c.igSetScrollY_Float(std.math.clamp(c.igGetScrollY() + dy * 0.35, 0, c.igGetScrollMaxY()));
            }
        }
        if (reveal and b.sel.cursor < cnt and (b.group_by == .none or b.group_starts.items.len == 0)) {
            const row: f32 = @floatFromInt(b.sel.cursor / cols);
            const top = row * cell_h;
            const view_h = c.igGetWindowHeight();
            if (top < c.igGetScrollY()) c.igSetScrollY_Float(top) else if (top + cell_h > c.igGetScrollY() + view_h) c.igSetScrollY_Float(top + cell_h - view_h);
        }

        const origin = c.igGetCursorScreenPos();
        var open_idx: ?usize = null;
        var drop_target: ?usize = null;
        const cache = act.thumbs;
        if (b.group_by != .none and b.group_starts.items.len > 0) {
            // Grouped: each section is a heading, then its own rows of cells.
            const starts = b.group_starts.items;
            const head_h = c.igGetTextLineHeightWithSpacing() + fs * 0.6;
            const scroll = c.igGetScrollY();
            const view_h = c.igGetWindowHeight();
            var y: f32 = 0;
            for (starts, 0..) |st, g| {
                const end = if (g + 1 < starts.len) starts[g + 1] else cnt;
                const n_rows = (end - st + cols - 1) / cols;
                if (y + head_h >= scroll and y <= scroll + view_h) {
                    c.igSetCursorScreenPos(cimgui.vec2(origin.x + gap * 0.5, origin.y + y + fs * 0.3));
                    c.igPushID_Int(@intCast(g + 1_000_000));
                    table.drawGroupHeader(b.groupLabelAt(st));
                    c.igPopID();
                }
                y += head_h;
                if (reveal and b.sel.cursor >= st and b.sel.cursor < end) {
                    const top = y + @as(f32, @floatFromInt((b.sel.cursor - st) / cols)) * cell_h;
                    if (top < scroll) c.igSetScrollY_Float(top) else if (top + cell_h > scroll + view_h) c.igSetScrollY_Float(top + cell_h - view_h);
                }
                var r: usize = 0;
                while (r < n_rows) : (r += 1) {
                    const ry = y + @as(f32, @floatFromInt(r)) * cell_h;
                    if (ry + cell_h < scroll or ry > scroll + view_h) continue;
                    var col: usize = 0;
                    while (col < cols) : (col += 1) {
                        const i = st + r * cols + col;
                        if (i >= end) break;
                        const x = origin.x + @as(f32, @floatFromInt(col)) * pitch + gap * 0.5;
                        self.drawCell(b, act, cache, i, cimgui.vec2(x, origin.y + ry), cell_w, cell_h, icon, &open_idx, &drop_target, mr_min, mr_max);
                    }
                }
                y += @as(f32, @floatFromInt(n_rows)) * cell_h;
            }
            c.igSetCursorScreenPos(origin);
            c.igDummy(cimgui.vec2(width, y + cell_h));
        } else {
            // Only the rows in view are submitted; one Dummy sizes the whole scroll area
            // (rows + a free row to drop on / right-click under the last items).
            const scroll = c.igGetScrollY();
            const view_h = c.igGetWindowHeight();
            const first_row: usize = @intFromFloat(@max(@floor(scroll / cell_h), 0));
            const last_row: usize = @min(rows, @as(usize, @intFromFloat(@ceil((scroll + view_h) / cell_h))) + 1);
            var r: usize = first_row;
            while (r < last_row) : (r += 1) {
                var col: usize = 0;
                while (col < cols) : (col += 1) {
                    const i = r * cols + col;
                    if (i >= cnt) break;
                    const x = origin.x + @as(f32, @floatFromInt(col)) * pitch + gap * 0.5;
                    const y = origin.y + @as(f32, @floatFromInt(r)) * cell_h;
                    self.drawCell(b, act, cache, i, cimgui.vec2(x, y), cell_w, cell_h, icon, &open_idx, &drop_target, mr_min, mr_max);
                }
            }
            c.igSetCursorScreenPos(origin);
            c.igDummy(cimgui.vec2(width, @as(f32, @floatFromInt(rows + 1)) * cell_h));
        }

        if (tv.marquee_active) {
            const dl = c.igGetForegroundDrawList_ViewportPtr(null);
            c.ImDrawList_AddRectFilled(dl, mr_min, mr_max, 0x22FFFFFF, 0, 0);
            c.ImDrawList_AddRect(dl, mr_min, mr_max, 0x99FFFFFF, 0, 1.0, 0);
        }
        if (open_idx) |idx| act.open(b, idx);
        tv.list_min = area_min;
        tv.list_max = area_max;

        if (b.pendingDropPos()) |pos| {
            const inside = pos[0] >= area_min.x and pos[0] <= area_max.x and pos[1] >= area_min.y and pos[1] <= area_max.y;
            if (inside) {
                var dbuf: [4200]u8 = undefined;
                if (drop_target) |ti| {
                    if (table.joinPath(&dbuf, b.dir, b.at(ti).name)) |dst| b.commitExternalDrop(dst) else b.commitExternalDrop(b.dir);
                } else b.commitExternalDrop(b.dir);
            }
        }
        table.backgroundMenu(b);
    }

    fn drawCell(
        self: *GridView,
        b: *Browser,
        act: *ViewActions,
        cache: ?*thumbs.Cache,
        i: usize,
        pos: c.ImVec2_c,
        cell_w: f32,
        cell_h: f32,
        icon: f32,
        open_idx: *?usize,
        drop_target: *?usize,
        mr_min: c.ImVec2_c,
        mr_max: c.ImVec2_c,
    ) void {
        const e = b.at(i);
        b.wantDetails(i); // on screen: its details first
        const pad: f32 = 3;
        const cmin = cimgui.vec2(pos.x + pad, pos.y + pad);
        const cmax = cimgui.vec2(pos.x + cell_w - pad, pos.y + cell_h - pad);
        if (self.base.marquee_active and table.rectsOverlap(mr_min, mr_max, cmin, cmax)) b.sel.select(i);

        c.igPushID_Int(@intCast(i));
        defer c.igPopID();
        c.igSetCursorScreenPos(cmin);
        // The cell is the hit area only: Finder marks a selected item on its icon and
        // its name (drawn below), not with a box round the whole cell.
        const clear = cimgui.vec4(0, 0, 0, 0);
        c.igPushStyleColor_Vec4(c.ImGuiCol_Header, clear);
        c.igPushStyleColor_Vec4(c.ImGuiCol_HeaderHovered, clear);
        c.igPushStyleColor_Vec4(c.ImGuiCol_HeaderActive, clear);
        const clicked = c.igSelectable_Bool("##cell", b.sel.isSelected(i), 0, cimgui.vec2(cmax.x - cmin.x, cmax.y - cmin.y));
        c.igPopStyleColor(3);
        if (clicked) {
            if (c.igIsKeyDown_Nil(c.ImGuiMod_Shift)) b.sel.selectRange(i) else if (c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl)) b.sel.toggle(i) else b.sel.click(i);
        }
        const hovered = c.igIsItemHovered(0);
        if (e.isDir()) if (b.pendingDropPos()) |p| {
            if (p[0] >= cmin.x and p[0] <= cmax.x and p[1] >= cmin.y and p[1] <= cmax.y) drop_target.* = i;
        };
        if (c.igBeginDragDropSource(0)) {
            if (!b.sel.isSelected(i)) b.sel.click(i);
            b.beginDrag();
            const pl = ViewActions.dragPayload(b);
            _ = c.igSetDragDropPayload(table.DRAG_PAYLOAD, &pl, pl.len, 0);
            table.drawDragPreview(b);
            c.igEndDragDropSource();
        }
        if (e.isDir() and !table.isDragged(act, b.dir, e.name) and c.igBeginDragDropTarget()) {
            const payload = c.igAcceptDragDropPayload(table.DRAG_PAYLOAD, 0);
            if (payload != null and payload.*.Delivery) {
                var dbuf: [4200]u8 = undefined;
                if (act.dragSource(payload)) |src| if (table.joinPath(&dbuf, b.dir, e.name)) |dst|
                    b.dropDraggedInto(src.dragPaths(), dst, c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl));
            }
            c.igEndDragDropTarget();
        }
        if (e.isDir() and !table.isDragged(act, b.dir, e.name)) {
            var sbuf: [4200]u8 = undefined;
            if (table.joinPath(&sbuf, b.dir, e.name)) |sp| if (act.spring.open(sp)) {
                b.open(e) catch {};
                return; // the listing is being replaced
            };
        }
        if (c.igBeginPopupContextItem(null, c.ImGuiPopupFlags_MouseButtonRight)) {
            if (!b.sel.isSelected(i)) b.sel.click(i);
            act.rowMenu(b, i);
            c.igEndPopup();
        }
        if (hovered and c.igIsMouseDoubleClicked_Nil(0)) open_idx.* = i;
        if (e.isDir() and hovered and c.igIsMouseClicked_Bool(c.ImGuiMouseButton_Middle, false)) {
            var tbuf: [4200]u8 = undefined;
            if (table.joinPath(&tbuf, b.dir, e.name)) |p| b.requestNewTab(p);
        }

        // Icon box, centered at the top of the cell (or at its left, the name beside
        // it); selected, it sits on a soft box.
        const dl = c.igGetWindowDrawList();
        const right = act.label_right;
        const ix = if (right) pos.x + pad * 3 else pos.x + (cell_w - icon) * 0.5;
        const iy = if (right) pos.y + @round((cell_h - icon) * 0.5) else pos.y + pad * 2;
        const faded = b.isCut(i);
        const selected = b.sel.isSelected(i);
        if (selected) {
            const m = @round(icon * 0.08);
            const box = if (theme.p().dark) cimgui.vec4(1, 1, 1, 0.12) else cimgui.vec4(0, 0, 0, 0.08);
            c.ImDrawList_AddRectFilled(dl, cimgui.vec2(ix - m, iy - m), cimgui.vec2(ix + icon + m, iy + icon + m), c.igGetColorU32_Vec4(box), @round(icon * 0.1), 0);
        }
        var drew_thumb = false;
        var full: [2]u32 = .{ 0, 0 }; // an image's own size, for item info
        if (cache) |tc| if (act.icon_preview and thumbs.Cache.wants(e)) {
            var pbuf: [4200]u8 = undefined;
            if (table.joinPath(&pbuf, b.dir, e.name)) |p| if (tc.get(p, e.mtime_secs)) |t| {
                const s = @min(icon / t.w, icon / t.h);
                const w = t.w * s;
                const h = t.h * s;
                const p0 = cimgui.vec2(ix + (icon - w) * 0.5, iy + (icon - h));
                const ref: c.ImTextureRef_c = .{ ._TexData = null, ._TexID = t.tex };
                const tint: u32 = if (faded) 0x80FFFFFF else 0xFFFFFFFF;
                c.ImDrawList_AddImage(dl, ref, p0, cimgui.vec2(p0.x + w, p0.y + h), cimgui.vec2(0, 0), cimgui.vec2(1, 1), tint);
                c.ImDrawList_AddRect(dl, p0, cimgui.vec2(p0.x + w, p0.y + h), 0x40FFFFFF, 0, 1, 0); // rounding, thickness, flags
                drew_thumb = true;
                full = .{ t.full_w, t.full_h };
            };
        };
        if (!drew_thumb) icons.draw(dl, e, ix, iy, icon, faded);
        act.pop.note(b, i, hovered, ix, iy, icon);

        // Name: up to two lines (centred under the icon, or left-aligned beside it),
        // the rest elided.
        // The names at View Options' text size (only here: menus and tooltips keep theirs).
        c.igPushFont(null, c.igGetStyle().*.FontSizeBase * act.text_scale);
        var popped = false;
        defer if (!popped) c.igPopFont();
        const line_h = c.igGetTextLineHeight();
        var ib: [64]u8 = undefined;
        const info = if (act.item_info) itemInfo(&ib, act, b, e, full) else "";
        const lx = if (right) ix + icon + @round(line_h * 0.6) else pos.x + pad;
        const lw = if (right) pos.x + cell_w - pad - lx else cell_w - pad * 2;
        if (self.base.renaming != null and self.base.renaming.? == i) {
            c.igSetCursorScreenPos(cimgui.vec2(lx, if (right) pos.y + (cell_h - c.igGetFrameHeight()) * 0.5 else iy + icon + pad));
            self.base.rename_width = lw;
            self.base.drawRenameField(b);
        } else {
            const shown = std.fs.path.basename(e.name);
            const col = c.igGetColorU32_Vec4(if (faded) theme.dim() else table.nameColor(e));
            const lines: f32 = if (fitChars(shown, lw) < shown.len) 2 else 1;
            const all_lines = lines + @as(f32, if (info.len > 0) 1 else 0);
            const ly = if (right) pos.y + @round((cell_h - line_h * all_lines) * 0.5) else iy + icon + pad * 2;
            const cut = drawLabel(dl, shown, lx, ly, lw, col, selected, !right);
            if (info.len > 0) {
                // Finder's item info: small, in the accent colour, under the name.
                const iw = c.igCalcTextSize(info.ptr, info.ptr + info.len, false, -1).x;
                const ix2 = if (right) lx + @round(line_h * 0.3) else lx + @max((lw - iw) * 0.5, 0);
                c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(ix2, ly + lines * line_h), theme.u32c(theme.p().accent_hex, 0xFF), info.ptr, info.ptr + info.len);
            }
            c.igPopFont();
            popped = true;
            // The whole name, only when the label had to shorten it.
            if (cut and hovered and c.igBeginItemTooltip()) {
                cimgui.textUnformatted(shown);
                c.igEndTooltip();
            }
            if (e.tags != 0) _ = table.drawTagDots(dl, ix + icon * 0.72, iy + icon * 0.12, e.tags); // on the icon's corner
        }
    }
};

/// itemInfo is the line Finder shows under a name: a folder's item count, an
/// image's size in pixels, else the file's size ("" while it isn't known yet).
fn itemInfo(buf: []u8, act: *ViewActions, b: *Browser, e: core.scan.Entry, full: [2]u32) []const u8 {
    if (e.pending) return ""; // its details are still on their way
    if (e.isDir()) {
        const ds = act.dir_sizes orelse return "";
        var pb: [4200]u8 = undefined;
        const p = table.joinPath(&pb, b.dir, e.name) orelse return "";
        const sz = ds.get(p, e.mtime_secs) orelse return "";
        return std.mem.print(buf, "{d}{s} item{s}", .{ sz.items, if (sz.partial) "+" else "", if (sz.items == 1) "" else "s" }) catch "";
    }
    if (full[0] > 0) return std.mem.print(buf, "{d} \u{00D7} {d}", .{ full[0], full[1] }) catch "";
    var sb: [24]u8 = undefined;
    return std.mem.print(buf, "{s}", .{scan.humanizeSize(&sb, e.size)}) catch "";
}

/// drawLabel draws an icon's name in `width`, centred (under the icon) or not
/// (beside it): wrapped onto a second line, which, when the rest is still too long,
/// keeps its start and end around an ellipsis (Finder). Selected, each line sits on
/// an accent pill in white. Returns whether the name had to be shortened.
fn drawLabel(dl: *c.ImDrawList, text: []const u8, x: f32, y: f32, width: f32, col: u32, selected: bool, centred: bool) bool {
    const line_h = c.igGetTextLineHeight();
    var lines: [2][]const u8 = .{ text, "" };
    var n: usize = 1;
    var fit_buf: [600]u8 = undefined;
    const pill_x: f32 = @round(line_h * 0.3);
    const fit_w = if (centred) width else width - pill_x * 2; // left-aligned, the pill's inset counts
    const first = fitChars(text, fit_w);
    if (first < text.len) {
        // Prefer breaking after a space, dash, dot or underscore in the first line.
        var end = first;
        var k = first;
        while (k > first / 2 and k > 0) : (k -= 1) {
            if (std.mem.indexOfScalar(u8, " -_.", text[k - 1]) != null) break;
        }
        if (k > first / 2) end = k;
        lines = .{ text[0..end], core.elide.middle(&fit_buf, text[end..], fit_w, cimgui.Measure{}) };
        n = 2;
    }
    const pal = theme.p();
    for (lines[0..n], 0..) |ln, li| {
        const tw = c.igCalcTextSize(ln.ptr, ln.ptr + ln.len, false, -1).x;
        const tx = if (centred) x + @max((width - tw) * 0.5, 0) else x + pill_x;
        const ty = y + @as(f32, @floatFromInt(li)) * line_h;
        if (selected) c.ImDrawList_AddRectFilled(dl, cimgui.vec2(tx - pill_x, ty), cimgui.vec2(tx + tw + pill_x, ty + line_h), theme.u32c(pal.accent_hex, 0xFF), @round(line_h * 0.25), 0);
        c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(tx, ty), if (selected) 0xFFFFFFFF else col, ln.ptr, ln.ptr + ln.len);
    }
    return n == 2 and lines[1].ptr == &fit_buf;
}

/// fitChars returns how many bytes of `s` fit in `width` (at a UTF-8 boundary, >= 1).
fn fitChars(s: []const u8, width: f32) usize {
    if (c.igCalcTextSize(s.ptr, s.ptr + s.len, false, -1).x <= width) return s.len;
    var lo: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const next = @min(i + n, s.len);
        if (c.igCalcTextSize(s.ptr, s.ptr + next, false, -1).x > width) break;
        lo = next;
        i = next;
    }
    return @max(lo, @min(1, s.len));
}
