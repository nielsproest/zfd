//! Appearance: Finder-like light and dark themes, and "System" that follows the
//! desktop's preference (the XDG settings portal's color-scheme, else KDE's colour
//! scheme). `apply` writes the ImGui style; the views read the semantic colours
//! (`dim`, `err`, `accent`, …) from here instead of hard-coding RGB, so every
//! hint, error and highlight follows the theme.

const std = @import("std");
const cimgui = @import("cimgui.zig");
const c = cimgui.c;

pub const Mode = enum(u8) { system = 0, light = 1, dark = 2 };

/// Palette is what the views use beyond ImGui's own style colours.
pub const Palette = struct {
    dark: bool,
    text: c.ImVec4_c,
    dim: c.ImVec4_c, // secondary text: hints, counts, inactive places
    err: c.ImVec4_c,
    warn: c.ImVec4_c,
    info: c.ImVec4_c, // notices (archive banner, new device)
    accent: c.ImVec4_c, // selection / focus blue
    accent_hex: u32,
    sidebar_bg: c.ImVec4_c,
    content_bg: c.ImVec4_c,
    toolbar_bg: c.ImVec4_c, // the band holding the menu bar, tabs and toolbar
    toolbar_line: c.ImVec4_c, // the hairline under it
    row_alt: c.ImVec4_c,
    separator: c.ImVec4_c,
    folder: u32, // icon colours (ImU32, ABGR)
    folder_tab: u32,
    page: u32,
    page_fold: u32,
    icon_text: u32,
};

fn rgb(hex: u32) c.ImVec4_c {
    return rgba(hex, 1.0);
}
fn rgba(hex: u32, a: f32) c.ImVec4_c {
    return cimgui.vec4(@as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0, @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0, @as(f32, @floatFromInt(hex & 0xFF)) / 255.0, a);
}
/// u32 converts 0xRRGGBB (+alpha) to ImGui's packed ABGR.
pub fn u32c(hex: u32, a: u8) u32 {
    return (@as(u32, a) << 24) | ((hex & 0xFF) << 16) | (hex & 0xFF00) | ((hex >> 16) & 0xFF);
}

const light: Palette = .{
    .dark = false,
    // Sampled from Finder (Monterey), minus the wallpaper's tint.
    .text = rgb(0x262626),
    .dim = rgb(0x808080),
    .err = rgb(0xD70015),
    .warn = rgb(0xC93400),
    .info = rgb(0x1168DC),
    .accent = rgb(0x1168DC),
    .accent_hex = 0x1168DC,
    .sidebar_bg = rgb(0xE8E6EC),
    .content_bg = rgb(0xFFFFFF),
    .toolbar_bg = rgb(0xF5F5F5),
    .toolbar_line = rgb(0xE4E4E4),
    .row_alt = rgb(0xF4F5F5),
    .separator = rgb(0xE3E3E6),
    .folder = 0xFFF0B163, // ABGR of #63B1F0
    .folder_tab = 0xFFDE9A4A,
    .page = 0xFFFAFAFA,
    .page_fold = 0xFFCFCFCF,
    .icon_text = 0xFF303030,
};

const dark: Palette = .{
    .dark = true,
    .text = rgb(0xDFDFDF),
    .dim = rgb(0x98989D),
    .err = rgb(0xFF6961),
    .warn = rgb(0xFF9F43),
    .info = rgb(0x64AFFF),
    .accent = rgb(0x0E5CCD),
    .accent_hex = 0x0E5CCD,
    .sidebar_bg = rgb(0x2B2A2E),
    .content_bg = rgb(0x1E1E1E),
    .toolbar_bg = rgb(0x323234),
    .toolbar_line = rgb(0x000000),
    .row_alt = rgb(0x282828),
    .separator = rgb(0x38383B),
    .folder = 0xFFE0A25A,
    .folder_tab = 0xFFC98A48,
    .page = 0xFFF2F2F2,
    .page_fold = 0xFFBDBDBD,
    .icon_text = 0xFF202020,
};

var current: *const Palette = &dark;

/// p is the palette in effect.
pub fn p() *const Palette {
    return current;
}
pub fn dim() c.ImVec4_c {
    return current.dim;
}
pub fn err() c.ImVec4_c {
    return current.err;
}
pub fn warn() c.ImVec4_c {
    return current.warn;
}
pub fn info() c.ImVec4_c {
    return current.info;
}
pub fn text() c.ImVec4_c {
    return current.text;
}

/// pushFields makes the text fields drawn until popFields stand out from a dialog's
/// background: a recessed fill and a hairline border (FrameBg alone is nearly the
/// popup's own shade). Buttons keep their look, so push only around the fields.
pub fn pushFields() void {
    const d = current.dark;
    c.igPushStyleColor_Vec4(c.ImGuiCol_FrameBg, if (d) rgb(0x1A1A1C) else rgb(0xFFFFFF));
    c.igPushStyleColor_Vec4(c.ImGuiCol_FrameBgHovered, if (d) rgb(0x202023) else rgb(0xFFFFFF));
    c.igPushStyleColor_Vec4(c.ImGuiCol_FrameBgActive, if (d) rgb(0x202023) else rgb(0xFFFFFF));
    c.igPushStyleColor_Vec4(c.ImGuiCol_Border, if (d) rgb(0x55555A) else rgb(0xC4C4C9));
    c.igPushStyleVar_Float(c.ImGuiStyleVar_FrameBorderSize, 1);
}
pub fn popFields() void {
    c.igPopStyleVar(1);
    c.igPopStyleColor(4);
}

/// pushSelected styles the next selected file row as Finder does: solid accent, white
/// text. Pair with popSelected.
pub fn pushSelected() void {
    c.igPushStyleColor_Vec4(c.ImGuiCol_Header, current.accent);
    c.igPushStyleColor_Vec4(c.ImGuiCol_HeaderHovered, current.accent);
    c.igPushStyleColor_Vec4(c.ImGuiCol_HeaderActive, current.accent);
    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, rgb(0xFFFFFF));
}
pub fn popSelected() void {
    c.igPopStyleColor(4);
}

/// apply sets the ImGui style for `is_dark` (colours plus the Finder-ish metrics).
/// Cheap; the shell calls it when the effective theme changes.
pub fn apply(is_dark: bool) void {
    current = if (is_dark) &dark else &light;
    const st = c.igGetStyle();
    const col = &st.*.Colors;
    const P = current.*;
    const set = struct {
        fn f(cs: *[c.ImGuiCol_COUNT]c.ImVec4_c, i: c_int, v: c.ImVec4_c) void {
            cs[@intCast(i)] = v;
        }
    }.f;
    const acc = P.accent;
    const hover = if (is_dark) rgba(0xFFFFFF, 0.08) else rgba(0x000000, 0.06);
    const press = if (is_dark) rgba(0xFFFFFF, 0.14) else rgba(0x000000, 0.12);
    const frame = if (is_dark) rgb(0x2C2C2E) else rgb(0xF0F0F2);
    const frame_hover = if (is_dark) rgb(0x353538) else rgb(0xE8E8EC);
    set(col, c.ImGuiCol_Text, P.text);
    set(col, c.ImGuiCol_TextDisabled, P.dim);
    set(col, c.ImGuiCol_WindowBg, P.content_bg);
    set(col, c.ImGuiCol_ChildBg, rgba(0, 0));
    set(col, c.ImGuiCol_PopupBg, if (is_dark) rgb(0x2B2B2E) else rgb(0xFBFBFD));
    set(col, c.ImGuiCol_Border, P.separator);
    set(col, c.ImGuiCol_BorderShadow, rgba(0, 0));
    set(col, c.ImGuiCol_FrameBg, frame);
    set(col, c.ImGuiCol_FrameBgHovered, frame_hover);
    set(col, c.ImGuiCol_FrameBgActive, frame_hover);
    // Window title bars share the toolbar's shade (Settings' page row continues it).
    set(col, c.ImGuiCol_TitleBg, P.toolbar_bg);
    set(col, c.ImGuiCol_TitleBgActive, P.toolbar_bg);
    set(col, c.ImGuiCol_TitleBgCollapsed, P.toolbar_bg);
    set(col, c.ImGuiCol_MenuBarBg, rgba(0, 0)); // on the toolbar band
    set(col, c.ImGuiCol_ScrollbarBg, rgba(0, 0));
    set(col, c.ImGuiCol_ScrollbarGrab, if (is_dark) rgba(0xFFFFFF, 0.25) else rgba(0x000000, 0.25));
    set(col, c.ImGuiCol_ScrollbarGrabHovered, if (is_dark) rgba(0xFFFFFF, 0.4) else rgba(0x000000, 0.4));
    set(col, c.ImGuiCol_ScrollbarGrabActive, if (is_dark) rgba(0xFFFFFF, 0.5) else rgba(0x000000, 0.5));
    set(col, c.ImGuiCol_CheckMark, acc);
    set(col, c.ImGuiCol_SliderGrab, acc);
    set(col, c.ImGuiCol_SliderGrabActive, acc);
    set(col, c.ImGuiCol_Button, frame);
    set(col, c.ImGuiCol_ButtonHovered, frame_hover);
    set(col, c.ImGuiCol_ButtonActive, press);
    // Selection in lists, combos and menus: a soft accent. The file views draw their
    // own selected rows solid, with white text (pushSelected).
    set(col, c.ImGuiCol_Header, rgba(P.accent_hex, if (is_dark) 0.5 else 0.25));
    set(col, c.ImGuiCol_HeaderHovered, hover);
    set(col, c.ImGuiCol_HeaderActive, press);
    set(col, c.ImGuiCol_Separator, P.separator);
    set(col, c.ImGuiCol_SeparatorHovered, acc);
    set(col, c.ImGuiCol_SeparatorActive, acc);
    set(col, c.ImGuiCol_ResizeGrip, rgba(0, 0));
    set(col, c.ImGuiCol_ResizeGripHovered, rgba(0, 0));
    set(col, c.ImGuiCol_ResizeGripActive, rgba(0, 0));
    // Tabs stand apart from the toolbar band they sit on: the others recessed
    // (darker than the band), the selected one raised (lighter, white in light mode).
    const tab = if (is_dark) rgb(0x262628) else rgb(0xE2E2E5);
    const tab_sel = if (is_dark) rgb(0x4A4A4E) else rgb(0xFFFFFF);
    set(col, c.ImGuiCol_Tab, tab);
    set(col, c.ImGuiCol_TabHovered, if (is_dark) rgb(0x3A3A3D) else rgb(0xEEEEF0));
    set(col, c.ImGuiCol_TabSelected, tab_sel);
    set(col, c.ImGuiCol_TabSelectedOverline, rgba(0, 0));
    set(col, c.ImGuiCol_TabDimmed, tab); // the window not focused
    set(col, c.ImGuiCol_TabDimmedSelected, if (is_dark) rgb(0x404044) else rgb(0xF8F8F8));
    set(col, c.ImGuiCol_TableHeaderBg, P.content_bg);
    set(col, c.ImGuiCol_TableBorderStrong, P.separator);
    // Resizable tables always get inner column lines; Finder's list has none.
    set(col, c.ImGuiCol_TableBorderLight, rgba(0, 0));
    set(col, c.ImGuiCol_TableRowBg, rgba(0, 0));
    set(col, c.ImGuiCol_TableRowBgAlt, P.row_alt);
    set(col, c.ImGuiCol_TextSelectedBg, rgba(0x3D9BFF, 0.35));
    set(col, c.ImGuiCol_DragDropTarget, acc);
    set(col, c.ImGuiCol_NavCursor, acc);
    set(col, c.ImGuiCol_ModalWindowDimBg, if (is_dark) rgba(0, 0.45) else rgba(0, 0.2));
    set(col, c.ImGuiCol_PlotHistogram, acc);
}

/// applyMetrics sets Finder-ish spacing and rounding once (before DPI scaling).
pub fn applyMetrics() void {
    const st = c.igGetStyle();
    st.*.WindowRounding = 10;
    st.*.ChildRounding = 6;
    st.*.FrameRounding = 6;
    st.*.PopupRounding = 8;
    st.*.ScrollbarRounding = 8;
    st.*.GrabRounding = 6;
    st.*.TabRounding = 6;
    st.*.ScrollbarSize = 11;
    st.*.FramePadding = cimgui.vec2(8, 4);
    st.*.ItemSpacing = cimgui.vec2(8, 5);
    st.*.ItemInnerSpacing = cimgui.vec2(6, 4);
    st.*.CellPadding = cimgui.vec2(6, 3);
    st.*.WindowPadding = cimgui.vec2(10, 8);
    st.*.PopupBorderSize = 1;
    st.*.WindowBorderSize = 1;
    st.*.ChildBorderSize = 1;
    st.*.FrameBorderSize = 0;
    st.*.SeparatorTextBorderSize = 1;
    // How far either side of a window's edge it resizes from, and shows it (ImGui's
    // 4 px): a window with an OS window of its own (Quick Look) has only the inner
    // side, and 4 px of that was hard to find.
    st.*.WindowBorderHoverPadding = 8;
}

// --- following the desktop -----------------------------------------------------

/// selectedText is the text colour on a selected (accent-filled) row.
pub fn selectedText() c.ImVec4_c {
    return rgb(0xFFFFFF);
}

/// watch follows the desktop's preference (started once by the shell).
pub var watch: SystemWatch = .{};

/// SystemWatch re-reads the desktop's light/dark preference every few seconds on a
/// background thread (a D-Bus call can block); the UI just reads `prefersDark`.
pub const SystemWatch = struct {
    dark: std.atomic.Value(u8) = .init(2), // 0 light, 1 dark, 2 unknown
    stop: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *SystemWatch, io: std.Io, home: []const u8) void {
        // The thread runs for the life of the process: give it its own copy of home.
        const h = std.heap.page_allocator.dupe(u8, home) catch return;
        const t = std.Thread.spawn(.{}, run, .{ self, io, h }) catch return;
        t.detach();
    }

    /// prefersDark: the desktop's choice, or null when it couldn't be told.
    pub fn prefersDark(self: *const SystemWatch) ?bool {
        return switch (self.dark.load(.acquire)) {
            0 => false,
            1 => true,
            else => null,
        };
    }

    fn run(self: *SystemWatch, io: std.Io, home: []const u8) void {
        var last: u8 = 2;
        while (!self.stop.load(.acquire)) {
            const v: u8 = if (portalColorScheme()) |d| @intFromBool(d) else if (kdeDark(io, home)) |d| @intFromBool(d) else 2;
            self.dark.store(v, .release);
            if (v != last) c.glfwPostEmptyEvent();
            last = v;
            const ts: std.os.linux.timespec = .{ .sec = 3, .nsec = 0 };
            _ = std.os.linux.nanosleep(&ts, null);
        }
    }
};

const sd = @import("c_sdbus");

/// portalColorScheme asks org.freedesktop.portal.Settings for
/// org.freedesktop.appearance color-scheme: 1 = prefer dark, 2 = prefer light,
/// 0 = no preference (→ null, so the next source is tried).
fn portalColorScheme() ?bool {
    var bus: ?*sd.sd_bus = null;
    if (sd.sd_bus_open_user(&bus) < 0) return null;
    defer _ = sd.sd_bus_flush_close_unref(bus);
    var e: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
    defer sd.sd_bus_error_free(&e);
    var reply: ?*sd.sd_bus_message = null;
    if (sd.sd_bus_call_method(bus, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "ReadOne", &e, &reply, "ss", "org.freedesktop.appearance", "color-scheme") < 0) return null;
    defer _ = sd.sd_bus_message_unref(reply);
    var v: u32 = 0;
    if (sd.sd_bus_message_read(reply, "v", "u", &v) < 0) return null;
    return switch (v) {
        1 => true,
        2 => false,
        else => null,
    };
}

/// kdeDark reads KDE's window background colour from kdeglobals; dark when its
/// brightness is low. Null when there is no such setting.
fn kdeDark(io: std.Io, home: []const u8) ?bool {
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.mem.print(&pb, "{s}/.config/kdeglobals", .{home}) catch return null;
    var buf: [64 * 1024]u8 = undefined;
    const content = std.Io.Dir.cwd().readFile(io, path, &buf) catch return null;
    var in_window = false;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            in_window = std.mem.eql(u8, line, "[Colors:Window]");
            continue;
        }
        if (!in_window or !std.mem.startsWith(u8, line, "BackgroundNormal=")) continue;
        var parts = std.mem.splitScalar(u8, line["BackgroundNormal=".len..], ',');
        var sum: u32 = 0;
        var n: u32 = 0;
        while (parts.next()) |ps| {
            sum += std.fmt.parseInt(u8, std.mem.trim(u8, ps, " "), 10) catch return null;
            n += 1;
        }
        if (n < 3) return null;
        return sum / n < 128;
    }
    return null;
}
