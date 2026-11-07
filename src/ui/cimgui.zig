//! The single Dear ImGui / GLFW / OpenGL C surface for the whole app, via cimgui's
//! C API. Every GUI file imports `c` from here so the C dependency lives in exactly
//! one place (the discipline the Go project kept around cimgui-go/SDL/X11).

const std = @import("std");

pub const c = @import("c_imgui"); // src/c/imgui.h, translated in build.zig

/// Measure measures text in the current font (for core.elide).
pub const Measure = struct {
    pub fn width(_: Measure, s: []const u8) f32 {
        return c.igCalcTextSize(s.ptr, s.ptr + s.len, false, -1).x;
    }
};

// --- "poisoned struct" access -----------------------------------------------
// Several cimgui structs (ImGuiIO, ImGuiListClipper, ImGuiInputTextCallbackData)
// embed an `ImGuiContext*` field. ImGuiContext is the one genuinely-opaque type
// (cimgui never defines it), so Zig refuses to lay those structs out: a `[*c]` to an
// opaque type can't be indexed. Passing a pointer to them is fine; reading a FIELD is
// what triggers the error. So: where the field sits at a stable, padding-free offset,
// we redeclare the C funcs with an opaque handle and mirror just that prefix (no C
// shim). Where the struct is huge/heavily-padded (ImGuiIO's FontGlobalScale, the
// input-char queue) a tiny C shim in imgui_shim.cpp stays; a mirror there would be
// silently wrong on any ImGui layout change.

/// zfd_set_font_scale sets ImGuiIO.FontGlobalScale (imgui_shim.cpp). FontGlobalScale
/// is deep inside the huge ImGuiIO struct with no accessor, so a shim is the safe way.
pub extern fn zfd_set_font_scale(scale: f32) void;

/// zfd_input_chars copies this frame's typed ASCII chars into `out`, returns count.
/// (Reads ImGuiIO.InputQueueCharacters, an ImVector field, also shim-only.)
pub extern fn zfd_input_chars(out: [*]u8, max: c_int) c_int;

/// zfd_load_font adds a TTF/OTF at `path` to the atlas (shim; the atlas is in the
/// opaque ImGuiIO). Returns false if the file can't be loaded.
pub extern fn zfd_load_font(path: [*:0]const u8, size: f32) bool;

/// zfd_mouse_wheel returns this frame's vertical scroll delta (ImGuiIO field), for
/// Ctrl+scroll zoom, which works regardless of keyboard layout.
pub extern fn zfd_mouse_wheel() f32;
/// zfd_want_text_input reports whether a text field (in any window) has the keyboard.
pub extern fn zfd_want_text_input() bool;

/// zfd_frame_hash hashes the rendered frame's draw data (0: must draw; imgui_shim.cpp).
pub extern fn zfd_frame_hash(fb_w: c_int, fb_h: c_int) u64;

/// zfd_free_ctrl_tab unbinds ImGui's Ctrl+Tab window switcher (the shell cycles tabs).
pub extern fn zfd_free_ctrl_tab() void;

/// zfd_set_font_filter sets NEAREST (blocky, no AA) or LINEAR filtering on the font
/// texture. Re-assert every frame after render (the 1.92 backend resets it).
pub extern fn zfd_set_font_filter(nearest: bool) void;

/// zfd_add_default_font adds ImGui's built-in bitmap (blocky) font alongside the TTF.
pub extern fn zfd_add_default_font() void;

/// zfd_enable_viewports lets ImGui windows leave the main window as OS windows.
/// Call after creating the context, before the backends init.
pub extern fn zfd_enable_viewports() void;

/// zfd_hook_viewport_windows calls `cb` with each secondary viewport's GLFW window
/// right after it's created, before it's shown. Call after the GLFW backend init.
pub extern fn zfd_hook_viewport_windows(cb: *const fn (?*anyopaque, c_int) callconv(.c) void) void;

/// zfd_viewports_enabled reports whether ImGui coordinates are desktop coordinates
/// (multi-viewport on) rather than main-window ones.
pub extern fn zfd_viewports_enabled() bool;

/// zfd_set_blocky selects the bitmap (blocky) or TTF (smooth) default font. Call
/// before the frame's NewFrame.
pub extern fn zfd_set_blocky(blocky: bool) void;

/// loadUiFont installs the first available system sans-serif TTF as the UI font, so
/// text is crisp when zoomed (unlike the built-in bitmap font). No-op if none found.
pub fn loadUiFont(size: f32) void {
    const candidates = [_][:0]const u8{
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/TTF/LiberationSans-Regular.ttf",
        "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/gnu-free/FreeSans.otf",
        "/usr/share/fonts/TTF/Vera.ttf",
    };
    for (candidates) |path| {
        if (zfd_load_font(path.ptr, size)) return;
    }
}

// ImGuiIO.AddMouseButtonEvent IS a real cimgui function: call it with an opaque IO
// handle, no shim. (Used to inject a release after a WM move/resize grab.)
const OpaqueIO = opaque {};
extern fn igGetIO_Nil() *OpaqueIO;
extern fn ImGuiIO_AddMouseButtonEvent(self: *OpaqueIO, button: c_int, down: bool) void;

/// releaseMouse injects a mouse-button-0 release into ImGui (after a WM grab so it
/// doesn't think the button is stuck down).
pub fn releaseMouse() void {
    ImGuiIO_AddMouseButtonEvent(igGetIO_Nil(), 0, false);
}

// ImGuiListClipper: only DisplayStart/DisplayEnd are read, and they're the first two
// members (offsets 0 and 4, no padding), so a two-field mirror is safe.
pub const ListClipper = opaque {};
pub extern fn ImGuiListClipper_ImGuiListClipper() *ListClipper;
pub extern fn ImGuiListClipper_destroy(self: *ListClipper) void;
pub extern fn ImGuiListClipper_Begin(self: *ListClipper, items_count: c_int, items_height: f32) void;
pub extern fn ImGuiListClipper_Step(self: *ListClipper) bool;
pub extern fn ImGuiListClipper_IncludeItemByIndex(self: *ListClipper, item_index: c_int) void;

const ClipperHead = extern struct { display_start: c_int, display_end: c_int };

/// clipperRange returns the visible [start, end) row range of a stepped clipper.
pub fn clipperRange(self: *ListClipper) struct { start: c_int, end: c_int } {
    const head: *const ClipperHead = @ptrCast(@alignCast(self));
    return .{ .start = head.display_start, .end = head.display_end };
}

// InputText callback data: mirror of the fields up to SelectionEnd (Ctx as anyopaque
// so Zig will lay it out; exact field types → C ABI padding matches). Keeping the
// param type `[*c]c.ImGuiInputTextCallbackData` means the fn still matches what
// igInputText expects, so no fn-pointer cast is needed; we just view it as the mirror.
pub const InputTextCallbackData = extern struct {
    Ctx: ?*anyopaque,
    EventFlag: c_int,
    Flags: c_int,
    UserData: ?*anyopaque,
    ID: c_uint,
    EventKey: c_int,
    EventChar: u16,
    EventActivated: bool,
    BufDirty: bool,
    Buf: ?[*]u8,
    BufTextLen: c_int,
    BufSize: c_int,
    CursorPos: c_int,
    SelectionStart: c_int,
    SelectionEnd: c_int,
};

// InsertChars/DeleteChars are the sanctioned way to mutate an *active* InputText's text
// from its callback (writing the user buffer directly is ignored while editing). They
// take the real cimgui struct pointer, which is exactly what the callback receives.
pub extern fn ImGuiInputTextCallbackData_InsertChars(
    self: [*c]c.ImGuiInputTextCallbackData,
    pos: c_int,
    text: [*c]const u8,
    text_end: [*c]const u8,
) void;
pub extern fn ImGuiInputTextCallbackData_DeleteChars(
    self: [*c]c.ImGuiInputTextCallbackData,
    pos: c_int,
    bytes_count: c_int,
) void;

/// stemLen is the length of `name` up to (not including) its extension, so a text
/// field can select the stem and leave the ".ext" intact. Leading-dot dotfiles and
/// extension-less names return the full length. Pairs with selectStem below; used by
/// the Save dialog name field and inline rename.
pub fn stemLen(name: []const u8) usize {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name.len;
    return if (dot == 0) name.len else dot;
}

/// selectStem is an InputText callback: selects [0, stem) (the filename without its
/// extension) when *UserData (an int stem length) is >= 0, then sets it to -1 so it
/// fires once per focus. For the Save dialog's name field.
pub fn selectStem(data: [*c]c.ImGuiInputTextCallbackData) callconv(.c) c_int {
    const d: *InputTextCallbackData = @ptrCast(@alignCast(data));
    const stem: *c_int = @ptrCast(@alignCast(d.UserData orelse return 0));
    if (stem.* >= 0) {
        d.CursorPos = stem.*;
        d.SelectionStart = 0;
        d.SelectionEnd = stem.*;
        stem.* = -1;
    }
    return 0;
}

/// textUnformatted draws a non-owning byte slice as-is: no printf interpretation,
/// so a '%' in a filename is safe (the exact trap called out in the Go project).
pub fn textUnformatted(s: []const u8) void {
    c.igTextUnformatted(s.ptr, s.ptr + s.len);
}

/// vec2 / vec4 build cimgui's by-value vector structs tersely.
pub fn vec2(x: f32, y: f32) c.ImVec2_c {
    return .{ .x = x, .y = y };
}

pub fn vec4(x: f32, y: f32, z: f32, w: f32) c.ImVec4_c {
    return .{ .x = x, .y = y, .z = z, .w = w };
}
