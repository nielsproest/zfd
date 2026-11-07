//! Gallery view (Finder's, Ctrl+4): a large preview of the item under the cursor —
//! the same loaded preview as Quick Look, so pictures, PDFs, video frames, text and
//! archive listings all show — over a strip of thumbnails to step through. Selection,
//! drag and drop, context menus, rename, type-ahead and the shortcuts behave as in the
//! other views (they share the table's helpers); Left/Right step along the strip.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const c = cimgui.c;
const theme = @import("../theme.zig");
const core = @import("core");
const actions = @import("actions.zig");
const table = @import("table.zig");
const thumbs = @import("../thumbs.zig");
const icons = @import("icons.zig");

const Browser = core.browser.Browser;
const ViewActions = actions.ViewActions;

pub const GalleryView = struct {
    base: table.TableView = .{}, // rename + type-ahead state, shared code

    pub fn draw(self: *GalleryView, b: *Browser, act: *ViewActions, keyboard: bool, list_height: f32) void {
        if (b.takeWantRename() and b.count() > 0) self.base.beginRename(b, b.sel.cursor);
        const popup_open = c.igIsPopupOpen_Str(null, c.ImGuiPopupFlags_AnyPopup);
        if (keyboard and !popup_open and self.base.renaming == null) {
            handleNav(b, act);
            _ = self.base.typeAhead(b);
            self.base.handleOpKeys(b, act);
        }
        const fs = c.igGetFontSize();
        const avail = c.igGetContentRegionAvail();
        const area_h = if (list_height > 0) list_height else avail.y + list_height;
        const strip_h = @round(fs * 7.5 * act.gallery_scale);
        const name_h = c.igGetTextLineHeightWithSpacing() * 2;
        const preview_h = @max(area_h - strip_h - name_h, fs * 4);

        const area_min = c.igGetCursorScreenPos();
        self.drawPreview(b, act, cimgui.vec2(avail.x, preview_h));
        self.drawName(b, avail.x, name_h);
        self.drawStrip(b, act, strip_h, b.sel.takeReveal());
        self.base.list_min = area_min;
        self.base.list_max = cimgui.vec2(area_min.x + avail.x, area_min.y + area_h);
        self.base.listDropTarget(b, act);
    }

    fn drawPreview(self: *GalleryView, b: *Browser, act: *ViewActions, size: c.ImVec2_c) void {
        _ = self;
        const ql = act.gallery orelse {
            c.igDummy(size);
            return;
        };
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path: ?[]const u8 = if (b.count() > 0 and b.sel.cursor < b.count() and !b.loading)
            table.joinPath(&buf, b.dir, b.at(b.sel.cursor).name)
        else
            null;
        ql.update(b.io, b.alloc, path);
        if (ql.drawPreview(size)) |enter| {
            var nb: [256]u8 = undefined;
            const sel = if (enter.select) |n| (std.mem.print(&nb, "{s}", .{n}) catch null) else null;
            b.navigate(enter.path) catch return;
            if (sel) |n| b.setPendingSelect(n);
        }
    }

    /// drawName is the cursor item's name, centred under the preview (or its rename
    /// field while renaming).
    fn drawName(self: *GalleryView, b: *Browser, width: f32, h: f32) void {
        const start = c.igGetCursorPos();
        if (b.count() > 0 and b.sel.cursor < b.count()) {
            const i = b.sel.cursor;
            if (self.base.renaming != null and self.base.renaming.? == i) {
                const w = @min(width, c.igGetFontSize() * 24);
                c.igSetCursorPos(cimgui.vec2(start.x + (width - w) * 0.5, start.y + 4));
                self.base.rename_width = w;
                self.base.drawRenameField(b);
            } else {
                const name = std.fs.path.basename(b.at(i).name);
                const tw = c.igCalcTextSize(name.ptr, name.ptr + name.len, false, -1).x;
                c.igSetCursorPos(cimgui.vec2(start.x + @max((width - tw) * 0.5, 0), start.y + 4));
                cimgui.textUnformatted(name);
            }
        }
        c.igSetCursorPos(cimgui.vec2(start.x, start.y + h));
    }

    fn drawStrip(self: *GalleryView, b: *Browser, act: *ViewActions, h: f32, reveal: bool) void {
        const fs = c.igGetFontSize();
        const cell = @round(fs * 5.5);
        if (!c.igBeginChild_Str("##galstrip", cimgui.vec2(0, h), 0, c.ImGuiWindowFlags_HorizontalScrollbar)) {
            c.igEndChild();
            return;
        }
        defer c.igEndChild();
        const cnt = b.count();
        if (reveal and b.sel.cursor < cnt) {
            const left = @as(f32, @floatFromInt(b.sel.cursor)) * cell;
            const view_w = c.igGetWindowWidth();
            if (left < c.igGetScrollX()) c.igSetScrollX_Float(left) else if (left + cell > c.igGetScrollX() + view_w) c.igSetScrollX_Float(left + cell - view_w);
        }
        // A wheel over the strip scrolls it sideways.
        if (c.igIsWindowHovered(0)) {
            const wheel = cimgui.zfd_mouse_wheel();
            if (wheel != 0) c.igSetScrollX_Float(std.math.clamp(c.igGetScrollX() - wheel * cell, 0, c.igGetScrollMaxX()));
        }
        const origin = c.igGetCursorScreenPos();
        const scroll = c.igGetScrollX();
        const view_w = c.igGetWindowWidth();
        const first: usize = @intFromFloat(@max(@floor(scroll / cell), 0));
        const last: usize = @min(cnt, @as(usize, @intFromFloat(@ceil((scroll + view_w) / cell))) + 1);
        var open_idx: ?usize = null;
        var i = first;
        while (i < last) : (i += 1) {
            drawCell(b, act, act.thumbs, i, cimgui.vec2(origin.x + @as(f32, @floatFromInt(i)) * cell, origin.y), cell, &open_idx);
        }
        c.igSetCursorScreenPos(origin);
        c.igDummy(cimgui.vec2(@as(f32, @floatFromInt(cnt + 1)) * cell, cell));
        if (open_idx) |idx| act.open(b, idx);
        _ = self;
        table.backgroundMenu(b);
    }
};

fn handleNav(b: *Browser, act: *ViewActions) void {
    const shift = c.igIsKeyDown_Nil(c.ImGuiMod_Shift);
    if (c.igIsKeyDown_Nil(c.ImGuiMod_Alt)) return; // Alt+arrows are back/forward
    if (c.igIsKeyPressed_Bool(c.ImGuiKey_RightArrow, true) or c.igIsKeyPressed_Bool(c.ImGuiKey_DownArrow, true)) b.sel.moveCursor(1, shift);
    if (c.igIsKeyPressed_Bool(c.ImGuiKey_LeftArrow, true) or c.igIsKeyPressed_Bool(c.ImGuiKey_UpArrow, true)) b.sel.moveCursor(-1, shift);
    if (c.igIsKeyPressed_Bool(c.ImGuiKey_Enter, false)) act.openCursor(b);
    if (!c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl) and c.igIsKeyPressed_Bool(c.ImGuiKey_Backspace, false)) b.backOrUp();
}

/// drawCell is one thumbnail in the strip: selectable, draggable, a drop target when
/// it's a folder, with the row menu on right-click.
fn drawCell(b: *Browser, act: *ViewActions, cache: ?*thumbs.Cache, i: usize, pos: c.ImVec2_c, cell: f32, open_idx: *?usize) void {
    const e = b.at(i);
    b.wantDetails(i); // on screen: its details first
    const pad: f32 = 4;
    c.igPushID_Int(@intCast(i));
    defer c.igPopID();
    c.igSetCursorScreenPos(cimgui.vec2(pos.x + pad, pos.y + pad));
    const clicked = c.igSelectable_Bool("##gcell", b.sel.isSelected(i), 0, cimgui.vec2(cell - pad * 2, cell - pad * 2));
    if (clicked) {
        if (c.igIsKeyDown_Nil(c.ImGuiMod_Shift)) b.sel.selectRange(i) else if (c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl)) b.sel.toggle(i) else b.sel.click(i);
    }
    const hovered = c.igIsItemHovered(0);
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
    if (hovered) {
        if (c.igBeginItemTooltip()) {
            cimgui.textUnformatted(e.name);
            c.igEndTooltip();
        }
    }

    const dl = c.igGetWindowDrawList();
    const icon = cell - pad * 4;
    const ix = pos.x + pad * 2;
    const iy = pos.y + pad * 2;
    const faded = b.isCut(i);
    if (cache) |tc| if (thumbs.Cache.wants(e)) {
        var pbuf: [4200]u8 = undefined;
        if (table.joinPath(&pbuf, b.dir, e.name)) |p| if (tc.get(p, e.mtime_secs)) |t| {
            const s = @min(icon / t.w, icon / t.h);
            const w = t.w * s;
            const h = t.h * s;
            const p0 = cimgui.vec2(ix + (icon - w) * 0.5, iy + (icon - h) * 0.5);
            const ref: c.ImTextureRef_c = .{ ._TexData = null, ._TexID = t.tex };
            c.ImDrawList_AddImage(dl, ref, p0, cimgui.vec2(p0.x + w, p0.y + h), cimgui.vec2(0, 0), cimgui.vec2(1, 1), if (faded) 0x80FFFFFF else 0xFFFFFFFF);
            return;
        };
    };
    icons.draw(dl, e, ix, iy, icon, faded);
    act.pop.note(b, i, hovered, ix, iy, icon);
    if (e.tags != 0) _ = table.drawTagDots(dl, ix + icon * 0.72, iy + icon * 0.12, e.tags);
}
