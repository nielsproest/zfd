//! chrome: the pieces of a window's frame ZFD draws itself (it has no window
//! manager decorations): the title-bar buttons, the toolbar's height, the screen a
//! window is on, a title cut to fit. Shared by the main window and the sub-windows
//! (subwindow.zig).

const std = @import("std");
const cimgui = @import("cimgui.zig");
const c = cimgui.c;
const theme = @import("theme.zig");

pub fn windowButtonWidth() f32 {
    return @round(c.igGetFrameHeight() * 1.6);
}

pub const WinButton = enum { minimize, maximize, restore, close };

/// winButton is one of the window's title-bar buttons (minimize, maximize/restore,
/// close): a glyph that gets a soft box on hover, red for close. `bg` is what's
/// behind it (the restore glyph's front square is filled with it).
pub fn winButton(kind: WinButton, h: f32, tip: [:0]const u8, bg: u32) bool {
    const w = windowButtonWidth();
    const dl = c.igGetWindowDrawList();
    const pal = theme.p();
    const pos = c.igGetCursorScreenPos();
    const clicked = c.igInvisibleButton("##winbtn", cimgui.vec2(w, h), 0);
    const hovered = c.igIsItemHovered(0);
    const held = c.igIsItemActive();
    const close = kind == .close;
    if (hovered) {
        c.igSetTooltip("%s", tip.ptr);
        const hb: u32 = if (close) theme.u32c(0xE81123, if (held) 0xCC else 0xFF) else c.igGetColorU32_Vec4(if (pal.dark) cimgui.vec4(1, 1, 1, if (held) 0.18 else 0.1) else cimgui.vec4(0, 0, 0, if (held) 0.14 else 0.07));
        c.ImDrawList_AddRectFilled(dl, pos, cimgui.vec2(pos.x + w, pos.y + h), hb, 4, 0);
    }
    const gc: u32 = if (close and hovered) 0xFFFFFFFF else c.igGetColorU32_Vec4(pal.text);
    const g = @round(h * 0.34);
    const cx = @round(pos.x + w * 0.5);
    const cy = @round(pos.y + h * 0.5);
    switch (kind) {
        .minimize => c.ImDrawList_AddLine(dl, cimgui.vec2(cx - g * 0.5, cy + 0.5), cimgui.vec2(cx + g * 0.5, cy + 0.5), gc, 1.2),
        .maximize => c.ImDrawList_AddRect(dl, cimgui.vec2(cx - g * 0.5, cy - g * 0.5), cimgui.vec2(cx + g * 0.5, cy + g * 0.5), gc, 0, 1.2, 0),
        .restore => {
            // Two overlapping squares.
            const o = g * 0.22;
            c.ImDrawList_AddRect(dl, cimgui.vec2(cx - g * 0.5 + o, cy - g * 0.5), cimgui.vec2(cx + g * 0.5, cy + g * 0.5 - o), gc, 0, 1.2, 0);
            if (!hovered) c.ImDrawList_AddRectFilled(dl, cimgui.vec2(cx - g * 0.5, cy - g * 0.5 + o), cimgui.vec2(cx + g * 0.5 - o, cy + g * 0.5), bg, 0, 0);
            c.ImDrawList_AddRect(dl, cimgui.vec2(cx - g * 0.5, cy - g * 0.5 + o), cimgui.vec2(cx + g * 0.5 - o, cy + g * 0.5), gc, 0, 1.2, 0);
        },
        .close => {
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx - g * 0.5, cy - g * 0.5), cimgui.vec2(cx + g * 0.5, cy + g * 0.5), gc, 1.2);
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx - g * 0.5, cy + g * 0.5), cimgui.vec2(cx + g * 0.5, cy - g * 0.5), gc, 1.2);
        },
    }
    return clicked;
}

pub fn windowButtonsWidth() f32 {
    return windowButtonWidth() * 3;
}

/// ellipsize fits `text` into `max_w` at the current font, cutting it short with
/// "…" (on a UTF-8 boundary) when it's too wide. NUL-terminated into `buf`.
pub fn ellipsize(buf: []u8, text: []const u8, max_w: f32) [:0]const u8 {
    const ell = "\u{2026}";
    const full = std.mem.printSentinel(buf, "{s}", .{text}, 0) catch return "";
    if (c.igCalcTextSize(full.ptr, null, false, -1).x <= max_w) return full;
    var n = @min(text.len, buf.len - ell.len - 1);
    while (n > 0) {
        n -= 1;
        while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1; // not inside a UTF-8 sequence
        const z = std.mem.printSentinel(buf, "{s}{s}", .{ text[0..n], ell }, 0) catch return "";
        if (c.igCalcTextSize(z.ptr, null, false, -1).x <= max_w) return z;
    }
    return std.mem.printSentinel(buf, "{s}", .{ell}, 0) catch "";
}

/// monitorAt is the screen (x, y, w, h) holding the point x, y: Quick Look fills it.
/// The first monitor when none does.
pub fn monitorAt(x: f32, y: f32, work_area: bool) [4]f32 {
    var n: c_int = 0;
    const mons = c.glfwGetMonitors(&n) orelse return .{ 0, 0, 1280, 800 };
    var best: [4]f32 = .{ 0, 0, 1280, 800 };
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        const m = mons[i] orelse continue;
        var mx: c_int = 0;
        var my: c_int = 0;
        c.glfwGetMonitorPos(m, &mx, &my);
        const mode = c.glfwGetVideoMode(m) orelse continue;
        const r = [4]f32{ @floatFromInt(mx), @floatFromInt(my), @floatFromInt(mode.*.width), @floatFromInt(mode.*.height) };
        // The work area leaves out the panels.
        var wa = r;
        if (work_area) {
            var wx: c_int = 0;
            var wy: c_int = 0;
            var ww: c_int = 0;
            var wh: c_int = 0;
            c.glfwGetMonitorWorkarea(m, &wx, &wy, &ww, &wh);
            if (ww > 0 and wh > 0) wa = .{ @floatFromInt(wx), @floatFromInt(wy), @floatFromInt(ww), @floatFromInt(wh) };
        }
        if (i == 0) best = wa;
        if (x >= r[0] and x < r[0] + r[2] and y >= r[1] and y < r[1] + r[3]) return wa;
    }
    return best;
}

/// toolbarH is the height of the toolbar's buttons, title and search field: Finder's
/// are roomier than an ordinary widget.
pub fn toolbarH() f32 {
    return @round(c.igGetFontSize() * 2.1);
}
