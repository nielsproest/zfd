//! subwindow: a window of ZFD's own besides the main one (Quick Look, the Trash,
//! Progress, Settings, …), and everything about being one, in one place:
//!
//! - It always has an OS window of its own (ImGui would otherwise draw it inside
//!   the main window when it lies over it, and switch mid-drag).
//! - Its edges resize it through the window manager, which waits for our frame at
//!   each step (_NET_WM_SYNC_REQUEST, set up in gui.onViewportWindow): ImGui
//!   resizing its OS window itself raced the compositor, and the window blinked
//!   out or trailed black borders.
//! - It opens at the size it asks for, centred; a size you give it sticks.
//! - Full screen is the window manager's (over the panels), and Escape leaves it.
//! - It belongs to the main window (kept above it, minimised with it), and has a
//!   taskbar entry of its own only if it asks for one.
//! - A window that draws its own frame (Quick Look) gets the rounded background,
//!   the title bar (hidden in full screen till the pointer nears the top) and its
//!   full screen and close buttons from here too.
//!
//! The content is the caller's, between begin and end:
//!
//!     defer win.end();
//!     if (!win.begin(.{ .name = "Trash###trash", .preferred = .{ 640, 420 } }, &open)) return;
//!     ... draw ...

const std = @import("std");
const cimgui = @import("cimgui.zig");
const c = cimgui.c;
const x11 = @import("x11.zig");
const theme = @import("theme.zig");
const chrome = @import("chrome.zig");
const anim = @import("anim.zig");

/// Options say what kind of window it is (given to every begin).
pub const Options = struct {
    /// ImGui's name for it: what its title shows, then "###" and its ID.
    name: [:0]const u8,
    /// An entry of its own in the taskbar and Alt+Tab.
    taskbar: bool = false,
    /// Resized by its edges.
    resizable: bool = true,
    /// Sized to what it holds (it can't be resized then).
    auto_size: bool = false,
    /// Takes the keyboard when it appears.
    focus_on_appear: bool = true,
    /// It draws its own frame (frame, titleButtons): no ImGui title bar, background,
    /// border or padding, and rounded corners.
    frameless: bool = false,
    /// The size it would like: it opens at it (or at the size you last gave it),
    /// centred in `centre_in` (the main window's screen when null), and takes it
    /// again when it changes (`refit`) while you haven't resized it yourself.
    preferred: ?[2]f32 = null,
    refit: bool = true,
    /// Out of full screen, it takes `preferred` (centred where it was) rather than
    /// the size it had before.
    fit_after_full: bool = false,
    centre_in: ?[4]f32 = null,
    /// The smallest it gets, if resizable (0: default_min, in lines of text).
    min: [2]f32 = .{ 0, 0 },
    /// Its opacity.
    alpha: f32 = 1,
    /// More ImGui window flags.
    flags: c.ImGuiWindowFlags = 0,
};

/// rounding is a frameless window's corners (not in full screen).
pub const rounding: f32 = 10;

/// default_min is the smallest a resizable window gets unless it says otherwise:
/// in lines of text (wide, tall), so it follows the zoom.
pub const default_min: [2]f32 = .{ 14, 9 };

pub const SubWindow = struct {
    own: bool = false, // in an OS window of its own (as of its last begin)
    opened: bool = false, // shown since it last wasn't (placed for this opening)
    set: [2]f32 = .{ 0, 0 }, // the size it was last given
    user: ?[2]f32 = null, // the size you gave it (kept from then on)
    rect: [4]f32 = .{ 0, 0, 0, 0 }, // where it is (x, y, w, h), as of its last begin
    hovered: bool = false, // the pointer is over it (or what's in it)
    full: bool = false, // filling the screen
    before_full: [4]f32 = .{ 0, 0, 0, 0 }, // its place before that
    restore: bool = false, // put it back there on the next begin
    pending: ?[4]f32 = null, // a place asked for (growLeft), taken on the next begin
    wm_full: bool = false, // what the window manager was last asked for…
    wm_handle: ?*anyopaque = null, // …for this OS window (GLFW)
    pressed: bool = false, // this press went to the window manager
    sizing: bool = false, // its edges were dragged (until a press lands elsewhere)
    frameless: bool = false, // (from its options: end draws its edge)
    limits: [2]c_int = .{ 0, 0 }, // the minimum the window manager was last told…
    limits_handle: ?*anyopaque = null, // …for this OS window

    /// begin starts the window (ImGui's Begin, with all of the above); false when
    /// there's nothing to draw in it (collapsed, or closed with `open`). Call end
    /// whatever it returns.
    pub fn begin(w: *SubWindow, o: Options, open: ?*bool) bool {
        w.frameless = o.frameless;
        w.place(o);
        const min = minOf(o);
        if (min[0] > 0 or min[1] > 0)
            c.igSetNextWindowSizeConstraints(cimgui.vec2(min[0], min[1]), cimgui.vec2(std.math.floatMax(f32), std.math.floatMax(f32)), null, null);
        cimgui.zfd_next_window_class(o.taskbar);

        var flags = o.flags | c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoDocking;
        if (!o.focus_on_appear) flags |= c.ImGuiWindowFlags_NoFocusOnAppearing;
        if (o.auto_size) flags |= c.ImGuiWindowFlags_AlwaysAutoResize;
        // The window manager resizes it by its edges once it's in a window of its own
        // (ImGui does, inside the main window, with no window manager or viewports).
        if (!o.resizable or w.own or w.full) flags |= c.ImGuiWindowFlags_NoResize;
        if (w.full) flags |= c.ImGuiWindowFlags_NoMove;
        var vars: c_int = 1;
        c.igPushStyleVar_Float(c.ImGuiStyleVar_Alpha, o.alpha);
        if (o.frameless) {
            flags |= c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoBackground | c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoScrollbar;
            // Its background and edge are drawn by frame and end, rounded: ImGui draws a
            // window that has an OS window to itself square, whatever the rounding, and
            // makes its background opaque even when it's set see-through.
            c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, cimgui.vec2(0, 0));
            c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowRounding, if (w.full) 0 else rounding);
            c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowBorderSize, 0);
            vars += 3;
        }
        const shown = c.igBegin(o.name.ptr, open, flags);
        c.igPopStyleVar(vars);
        w.opened = true;

        const vp = c.igGetWindowViewport();
        w.own = vp != c.igGetMainViewport() and vp.*.PlatformHandle != null;
        w.hovered = shown and c.igIsWindowHovered(c.ImGuiHoveredFlags_RootAndChildWindows);
        w.syncFull(vp);
        w.applyLimits(vp, min);
        w.edges(vp, o.resizable and !o.auto_size and !w.full);
        const p = c.igGetWindowPos();
        const z = c.igGetWindowSize();
        w.rect = .{ p.x, p.y, z.x, z.y };
        // Resized by hand (its edges, or ImGui's while it's inside the main window): that
        // size sticks. (Focus may be in what it shows: a PDF's view.)
        const by_hand = w.sizing or (c.igIsWindowFocused(c.ImGuiFocusedFlags_RootAndChildWindows) and c.igIsMouseDown_Nil(0));
        if (!w.full and !w.restore and !o.auto_size and by_hand and (@abs(z.x - w.set[0]) > 1 or @abs(z.y - w.set[1]) > 1)) {
            w.user = .{ z.x, z.y };
            w.set = .{ z.x, z.y };
        }
        return shown;
    }

    /// end finishes the window (ImGui's End): a frameless one's hairline edge goes on
    /// top of everything in it.
    pub fn end(w: *SubWindow) void {
        if (w.frameless and !w.full) {
            const r = w.rect;
            c.ImDrawList_AddRect(c.igGetWindowDrawList(), cimgui.vec2(r[0] + 0.5, r[1] + 0.5), cimgui.vec2(r[0] + r[2] - 0.5, r[1] + r[3] - 0.5), c.igGetColorU32_Vec4(theme.p().separator), rounding, 1, 0); // rounding, thickness, flags
        }
        c.igEnd();
    }

    /// hide is for a frame it isn't shown in: its next opening starts afresh (at its
    /// size, out of full screen).
    pub fn hide(w: *SubWindow) void {
        w.opened = false;
        w.hovered = false;
        w.full = false;
        w.restore = false;
        w.set = .{ 0, 0 };
    }

    /// growLeft widens it by `dx` (narrows it, negative) to the left, so what's on its
    /// right stays where it is (a sidebar coming out); a size you gave it grows too.
    pub fn growLeft(w: *SubWindow, dx: f32) void {
        if (w.full or dx == 0) return;
        const r = w.rect;
        w.pending = .{ r[0] - dx, r[1], r[2] + dx, r[3] };
        w.set = .{ w.set[0] + dx, w.set[1] };
        if (w.user) |u| w.user = .{ u[0] + dx, u[1] };
    }

    /// toggleFull fills the screen it's on, or puts it back.
    pub fn toggleFull(w: *SubWindow) void {
        if (!w.full) w.before_full = w.rect else w.restore = true;
        w.full = !w.full;
    }

    /// escape is Escape pressed for it: out of full screen first (false), as on macOS;
    /// true when it should close.
    pub fn escape(w: *SubWindow) bool {
        if (!w.full) return true;
        w.toggleFull();
        return false;
    }

    /// background draws a frameless window's background (rounded, but in full screen).
    pub fn background(w: *SubWindow) void {
        const r = w.rect;
        const round: f32 = if (w.full) 0 else rounding;
        c.ImDrawList_AddRectFilled(c.igGetWindowDrawList(), cimgui.vec2(r[0], r[1]), cimgui.vec2(r[0] + r[2], r[1] + r[3]), c.igGetColorU32_Vec4(theme.p().content_bg), round, 0);
    }

    /// beginTitleBar starts a frameless window's title bar, `bar_h` tall across its top
    /// and drawn over what's in the window already (so: after the content), with the
    /// main window's toolbar look. In full screen there's none, but while the pointer is
    /// near the top it fades in over the content. False when there's nothing to draw
    /// into; call endTitleBar after a true one.
    pub fn beginTitleBar(w: *SubWindow, bar_h: f32) bool {
        var a: f32 = 1;
        if (w.full) {
            const m = c.igGetMousePos();
            const near = w.hovered and m.y < w.rect[1] + bar_h * 1.5;
            a = anim.toward(c.igGetID_Str("##subwinbar"), near, anim.quick);
            if (a < 0.01) return false;
        }
        const r = w.rect;
        c.igSetCursorScreenPos(cimgui.vec2(r[0], r[1]));
        c.igPushStyleVar_Float(c.ImGuiStyleVar_Alpha, c.igGetStyle().*.Alpha * a);
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, cimgui.vec2(0, 0));
        // (a child window of its own, so it's drawn over the content's)
        _ = c.igBeginChild_Str("##subwinbar", cimgui.vec2(r[2], bar_h), 0, c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoBackground);
        c.igPopStyleVar(1);
        const pal = theme.p();
        const dl = c.igGetWindowDrawList();
        const round: f32 = if (w.full) 0 else rounding;
        c.ImDrawList_AddRectFilled(dl, cimgui.vec2(r[0], r[1]), cimgui.vec2(r[0] + r[2], r[1] + bar_h), c.igGetColorU32_Vec4(pal.toolbar_bg), round, c.ImDrawFlags_RoundCornersTop);
        c.ImDrawList_AddLine(dl, cimgui.vec2(r[0], r[1] + bar_h - 0.5), cimgui.vec2(r[0] + r[2], r[1] + bar_h - 0.5), c.igGetColorU32_Vec4(pal.toolbar_line), 1);
        return true;
    }

    pub fn endTitleBar(_: *SubWindow) void {
        c.igEndChild();
        c.igPopStyleVar(1);
    }

    /// TitleButtons is what titleButtons drew: where they start (what's left of the
    /// title bar ends there), and whether Close was clicked.
    pub const TitleButtons = struct { left: f32, close: bool };

    /// titleButtons draws full screen and close at the right of a frameless window's
    /// title bar (`pad` in from its edges), the same buttons as the main window's.
    pub fn titleButtons(w: *SubWindow, pad: f32, close_tip: [:0]const u8) TitleButtons {
        const r = w.rect;
        const bw = chrome.windowButtonWidth();
        const h = chrome.toolbarH();
        const left = r[0] + r[2] - pad - bw * 2;
        const bg = c.igGetColorU32_Vec4(theme.p().toolbar_bg);
        c.igSetCursorScreenPos(cimgui.vec2(left, r[1] + pad));
        c.igPushID_Str("##subwintitle");
        defer c.igPopID();
        if (chrome.winButton(if (w.full) .restore else .maximize, h, if (w.full) "Exit Full Screen" else "Full Screen", bg)) w.toggleFull();
        c.igSameLine(0, 0);
        c.igPushID_Str("##close");
        const close = chrome.winButton(.close, h, close_tip, bg);
        c.igPopID();
        return .{ .left = left, .close = close };
    }

    /// place asks ImGui for where it should be this frame, if anywhere new: filling its
    /// screen, back from that, at its size when it opens, or refitted.
    fn place(w: *SubWindow, o: Options) void {
        if (w.full) {
            const b = w.before_full;
            const m = chrome.monitorAt(b[0] + b[2] * 0.5, b[1] + b[3] * 0.5, false);
            setRect(.{ m[0], m[1] }, .{ 0, 0 }, .{ m[2], m[3] });
        } else if (w.restore) {
            w.restore = false;
            const b = w.before_full;
            if (o.fit_after_full) if (o.preferred) |pref| {
                w.user = null;
                w.set = pref;
                return setRect(.{ b[0] + b[2] * 0.5, b[1] + b[3] * 0.5 }, .{ 0.5, 0.5 }, pref);
            };
            setRect(.{ b[0], b[1] }, .{ 0, 0 }, .{ b[2], b[3] });
        } else if (w.pending) |p| {
            w.pending = null;
            setRect(.{ p[0], p[1] }, .{ 0, 0 }, .{ p[2], p[3] });
        } else if (!w.opened) {
            const pref = o.preferred orelse return;
            const vp = c.igGetMainViewport();
            const work = o.centre_in orelse chrome.monitorAt(vp.*.Pos.x + vp.*.Size.x * 0.5, vp.*.Pos.y + vp.*.Size.y * 0.5, true);
            const sz = w.user orelse pref;
            setRect(.{ work[0] + work[2] * 0.5, work[1] + work[3] * 0.5 }, .{ 0.5, 0.5 }, sz);
            w.set = sz;
        } else if (o.preferred) |pref| {
            // Something of another shape in it: refitted, keeping its centre.
            if (w.user != null or !o.refit or (@abs(pref[0] - w.set[0]) <= 1 and @abs(pref[1] - w.set[1]) <= 1)) return;
            const r = w.rect;
            setRect(.{ r[0] + r[2] * 0.5, r[1] + r[3] * 0.5 }, .{ 0.5, 0.5 }, pref);
            w.set = pref;
        }
    }

    /// minOf is the smallest it may get (none if it isn't resized by hand).
    fn minOf(o: Options) [2]f32 {
        if (!o.resizable or o.auto_size) return .{ 0, 0 };
        if (o.min[0] > 0 or o.min[1] > 0) return o.min;
        const fs = c.igGetFontSize();
        return .{ @round(fs * default_min[0]), @round(fs * default_min[1]) };
    }

    /// applyLimits tells the window manager the smallest its OS window gets (as the
    /// main window does): ImGui's own limit alone let the window manager shrink it
    /// further, and ImGui then sized it back up against the drag.
    fn applyLimits(w: *SubWindow, vp: *c.ImGuiViewport, min: [2]f32) void {
        const handle = vp.*.PlatformHandle orelse return;
        if (!w.own) return;
        const lim: [2]c_int = .{ @intFromFloat(min[0]), @intFromFloat(min[1]) };
        if (handle == w.limits_handle and lim[0] == w.limits[0] and lim[1] == w.limits[1]) return;
        w.limits = lim;
        w.limits_handle = handle;
        const none = c.GLFW_DONT_CARE;
        c.glfwSetWindowSizeLimits(@ptrCast(handle), if (lim[0] > 0) lim[0] else none, if (lim[1] > 0) lim[1] else none, none, none);
    }

    fn setRect(pos: [2]f32, pivot: [2]f32, size: [2]f32) void {
        c.igSetNextWindowPos(cimgui.vec2(pos[0], pos[1]), c.ImGuiCond_Always, cimgui.vec2(pivot[0], pivot[1]));
        c.igSetNextWindowSize(cimgui.vec2(size[0], size[1]), c.ImGuiCond_Always);
    }

    /// syncFull asks the window manager for full screen (or out of it) whenever that
    /// changes, and when its OS window is new.
    fn syncFull(w: *SubWindow, vp: *c.ImGuiViewport) void {
        if (!w.own) {
            w.wm_handle = null;
            return;
        }
        const handle = vp.*.PlatformHandle;
        if (handle != null and (w.full != w.wm_full or handle != w.wm_handle)) {
            x11.setFullscreen(handle, w.full);
            w.wm_full = w.full;
            w.wm_handle = handle;
        }
    }

    /// edges makes its edges grips that hand the drag to the window manager (with the
    /// resize cursors), when it's in an OS window of its own.
    fn edges(w: *SubWindow, vp: *c.ImGuiViewport, resizable: bool) void {
        if (!c.igIsMouseDown_Nil(0)) w.pressed = false;
        if (!w.own or !resizable) return;
        // (only where nothing else lies over it, and not while something is dragged:
        // a text field that has the keyboard is active too, and doesn't count)
        const dragging = c.igIsAnyItemActive() and c.igIsMouseDown_Nil(0) and !c.igIsMouseClicked_Bool(0, false);
        if (!c.igIsWindowHovered(c.ImGuiHoveredFlags_RootAndChildWindows | c.ImGuiHoveredFlags_AllowWhenBlockedByActiveItem) or dragging) {
            if (c.igIsMouseClicked_Bool(0, false)) w.sizing = false;
            return;
        }
        const p = c.igGetWindowPos();
        const z = c.igGetWindowSize();
        const g: f32 = 6; // edge thickness
        const k: f32 = 14; // corners' reach
        const grips = [_]struct { x: f32, y: f32, w: f32, h: f32, dir: x11.Direction, cursor: c_int }{
            .{ .x = p.x, .y = p.y, .w = k, .h = k, .dir = .size_topleft, .cursor = c.ImGuiMouseCursor_ResizeNWSE },
            .{ .x = p.x + z.x - k, .y = p.y, .w = k, .h = k, .dir = .size_topright, .cursor = c.ImGuiMouseCursor_ResizeNESW },
            .{ .x = p.x + z.x - k, .y = p.y + z.y - k, .w = k, .h = k, .dir = .size_bottomright, .cursor = c.ImGuiMouseCursor_ResizeNWSE },
            .{ .x = p.x, .y = p.y + z.y - k, .w = k, .h = k, .dir = .size_bottomleft, .cursor = c.ImGuiMouseCursor_ResizeNESW },
            .{ .x = p.x + k, .y = p.y, .w = z.x - 2 * k, .h = g, .dir = .size_top, .cursor = c.ImGuiMouseCursor_ResizeNS },
            .{ .x = p.x + z.x - g, .y = p.y + k, .w = g, .h = z.y - 2 * k, .dir = .size_right, .cursor = c.ImGuiMouseCursor_ResizeEW },
            .{ .x = p.x + k, .y = p.y + z.y - g, .w = z.x - 2 * k, .h = g, .dir = .size_bottom, .cursor = c.ImGuiMouseCursor_ResizeNS },
            .{ .x = p.x, .y = p.y + k, .w = g, .h = z.y - 2 * k, .dir = .size_left, .cursor = c.ImGuiMouseCursor_ResizeEW },
        };
        for (grips) |r| {
            if (!c.igIsMouseHoveringRect(cimgui.vec2(r.x, r.y), cimgui.vec2(r.x + @max(r.w, 1), r.y + @max(r.h, 1)), false)) continue;
            c.igSetMouseCursor(r.cursor);
            if (c.igIsMouseClicked_Bool(0, false) and !w.pressed) {
                w.pressed = true;
                w.sizing = true;
                x11.startMoveResize(vp.*.PlatformHandle, r.dir);
                // The window manager has the pointer now; ImGui won't see the button come up.
                cimgui.releaseMouse();
            }
            return;
        }
        if (c.igIsMouseClicked_Bool(0, false)) w.sizing = false;
    }
};
