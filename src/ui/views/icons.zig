//! File icons drawn with ImDrawList (no image assets): a folder, or a document page
//! whose extension badge (large) or stripe (small) takes the file type's colour.
//! Shared by the list, icon and column views. Colours come from the theme.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const c = cimgui.c;
const core = @import("core");
const scan = core.scan;
const theme = @import("../theme.zig");
const table = @import("table.zig");

/// draw draws a generic icon in a size×size box at x,y: a folder, or a document page
/// with its extension on a badge in the file type's colour.
pub fn draw(dl: *c.ImDrawList, e: scan.Entry, x: f32, y: f32, size: f32, faded: bool) void {
    const a: u32 = if (faded) 0x80 else 0xFF;
    if (e.isDir()) return drawFolder(dl, x, y, size, @intCast(a));
    const pal = theme.p();
    const tint = table.typeColor(e);
    const accent: u32 = (a << 24) | (@as(u32, @intFromFloat(tint.z * 255)) << 16) | (@as(u32, @intFromFloat(tint.y * 255)) << 8) | @as(u32, @intFromFloat(tint.x * 255));
    const page: u32 = (a << 24) | (pal.page & 0xFFFFFF);
    const x0 = x + size * 0.18;
    const x1 = x + size * 0.82;
    const y0 = y + size * 0.04;
    const y1 = y + size * 0.96;
    const fold = size * 0.18;
    c.ImDrawList_AddRectFilled(dl, cimgui.vec2(x0, y0 + fold), cimgui.vec2(x1, y1), page, 2, 0);
    c.ImDrawList_AddRectFilled(dl, cimgui.vec2(x0, y0), cimgui.vec2(x1 - fold, y0 + fold), page, 0, 0);
    c.ImDrawList_AddTriangleFilled(dl, cimgui.vec2(x1 - fold, y0), cimgui.vec2(x1 - fold, y0 + fold), cimgui.vec2(x1, y0 + fold), (a << 24) | (pal.page_fold & 0xFFFFFF));
    // Small (list) icons: a coloured stripe stands in for the extension badge.
    if (size < c.igGetFontSize() * 2.5) {
        c.ImDrawList_AddRectFilled(dl, cimgui.vec2(x0, y0 + (y1 - y0) * 0.55), cimgui.vec2(x1, y0 + (y1 - y0) * 0.78), accent, 0, 0);
        c.ImDrawList_AddRect(dl, cimgui.vec2(x0, y0 + fold), cimgui.vec2(x1, y1), (a << 24) | (pal.page_fold & 0xFFFFFF), 1, 1, 0);
    }
    // Extension badge in the file's category colour.
    var eb: [6]u8 = undefined;
    const ext = upperExt(e.name, &eb);
    if (ext.len > 0 and size >= c.igGetFontSize() * 2.5) {
        const tw = c.igCalcTextSize(ext.ptr, ext.ptr + ext.len, false, -1).x;
        const by = y0 + (y1 - y0) * 0.58;
        const bh = c.igGetTextLineHeight() + 2;
        c.ImDrawList_AddRectFilled(dl, cimgui.vec2(x0 - 2, by), cimgui.vec2(@max(x1 + 2, x0 + tw + 8), by + bh), accent, 3, 0);
        c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(x0 + ((x1 - x0) - tw) * 0.5, by + 1), (a << 24) | (pal.icon_text & 0xFFFFFF), ext.ptr, ext.ptr + ext.len);
    }
}

/// drawFolder draws the folder icon in a size×size box at x,y, at opacity `alpha`.
pub fn drawFolder(dl: *c.ImDrawList, x: f32, y: f32, size: f32, alpha: u8) void {
    const a: u32 = alpha;
    const pal = theme.p();
    const body: u32 = (a << 24) | (pal.folder & 0xFFFFFF);
    const tab: u32 = (a << 24) | (pal.folder_tab & 0xFFFFFF);
    const top = y + size * 0.22;
    c.ImDrawList_AddRectFilled(dl, cimgui.vec2(x + size * 0.04, top - size * 0.08), cimgui.vec2(x + size * 0.42, top + size * 0.05), tab, size * 0.05, 0);
    c.ImDrawList_AddRectFilled(dl, cimgui.vec2(x + size * 0.04, top), cimgui.vec2(x + size * 0.96, y + size * 0.9), body, size * 0.07, 0);
}

fn upperExt(name: []const u8, buf: []u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return "";
    const e = name[dot + 1 ..];
    if (e.len == 0 or e.len > buf.len) return "";
    for (e, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    return buf[0..e.len];
}
