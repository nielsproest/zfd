//! The GUI platform loop: GLFW window + OpenGL3 context + Dear ImGui. `run` drives
//! the tabbed browser; `runPick` drives the `--pick` chooser and prints the chosen
//! path(s) to stdout. Both share the `Backend` (window + imgui lifecycle). GLFW is
//! the platform/render backend (imgui_impl_glfw); we don't hand-roll an X11 one.

const std = @import("std");
const cimgui = @import("cimgui.zig");
const theme = @import("theme.zig");
const c = cimgui.c;
const core = @import("core");
const shell_mod = @import("shell.zig");
const x11 = @import("x11.zig");

/// run opens the window and drives the tabbed shell until it's closed. `reveal_name`,
/// when set, is an entry in `start_override` to select + scroll into view once it loads
/// — how `zfd <file>` / `zfd --select <file>` reveals a file in its folder.
pub fn run(alloc: std.mem.Allocator, io: std.Io, trash_home: []const u8, home: []const u8, start_override: ?[]const u8, reveal_name: ?[]const u8, pos: ?[2]i32, csd: bool, debug: bool, settings: *core.config.Settings) !void {
    x11.debug = debug;
    var be = try Backend.init(csd, true);
    defer be.deinit();
    installFont(io, alloc); // before the first frame builds the font atlas
    c.glfwSetWindowSize(be.window, settings.win_w, settings.win_h);
    if (pos) |p| c.glfwSetWindowPos(be.window, p[0], p[1]); // a torn-off tab's window opens under the pointer

    // A folder given on the command line wins; else resume in the last directory (if
    // enabled + it still exists), else home.
    const last_dir = settings.lastDir();
    const last_ok = last_dir.len > 0 and (core.recent.isUri(last_dir) or dirExists(io, last_dir));
    const start = if (start_override) |s| s else if (settings.reopen_last and last_ok) last_dir else home;
    var shell = try shell_mod.Shell.init(alloc, io, trash_home, home, start, null, settings.*);
    defer shell.deinit();
    shell.win = be.window; // for CSD move/resize + min/max/close
    shell.csd = csd;
    if (reveal_name) |n| shell.activeBrowser().setPendingSelect(n); // select the file once it loads
    applyDpi(be.window, &shell);

    // Accept files dropped onto the window from other apps (GLFW-native, no X11).
    c.glfwSetWindowUserPointer(be.window, @ptrCast(&shell));
    _ = c.glfwSetDropCallback(be.window, dropCallback);
    x11.markTabWindow(be.window); // other ZFD windows may drop torn-off tabs on us
    // Our own launch is done: the desktop can stop its launch feedback.
    if (core.fsops.launch_env) |env| if (env.get("DESKTOP_STARTUP_ID")) |id| x11.completeStartup(be.window, id);

    var awake: i32 = 30; // frames of full-refresh rendering remaining after interaction
    var last = [2]f64{ -1, -1 };
    var saved = false;
    while (true) {
        if (be.shouldClose()) {
            if (!shell.opsRunning()) break;
            // Closed while copying or moving: those carry on, in a small window of
            // their own, and ZFD quits when they're done. Closing that one stops them
            // (at a safe point), and then it quits.
            c.glfwSetWindowShouldClose(be.window, 0);
            if (!shell.finishing) {
                settings.* = shell.gatherSettings(be.window); // the window as you left it
                saved = true;
                shell.finishInBackground();
            } else shell.stopAll();
        }
        if (shell.finishing and !shell.opsRunning()) break;
        // Active (recent interaction or streaming) → poll + vsync = full display
        // refresh, but the CPU sleeps in glfwSwapBuffers between frames. Idle → block
        // fully until input (a long timeout only as a fallback heartbeat).
        // The 1s heartbeat also bounds how late an external folder change (inotify, which
        // can't wake GLFW) or a device hotplug is noticed while idle.
        if (awake > 0 or shell.busy()) c.glfwPollEvents() else c.glfwWaitEventsTimeout(1.0);
        if (!shell.finishing) if (x11.takeTabs(be.window, alloc)) |list| {
            defer alloc.free(list);
            shell.adoptTabs(list);
            awake = 30;
        };
        if (!shell.finishing) if (x11.takeMerge(be.window)) |target| shell.mergeInto(target);
        shell.updateTabs();
        cimgui.zfd_set_blocky(shell.font_nearest); // NewFrame reads io.FontDefault
        be.beginFrame();
        shell.draw();
        awake = nextAwake(be.window, &last, awake);
        be.endFrame();
        cimgui.zfd_set_font_filter(shell.font_nearest); // after render: backend reset it
    }
    if (!saved) settings.* = shell.gatherSettings(be.window); // persist state for next launch
    shell.orphanScanners(); // detach scan workers so a slow in-flight read can't freeze exit
    be.hide();
}

/// installFont installs a real TTF as the UI font (crisp when zoomed, unlike the
/// blocky built-in bitmap font). Resolves the system default via fontconfig
/// (`fc-match`), falling back to a few well-known paths, then the bitmap font.
fn installFont(io: std.Io, alloc: std.mem.Allocator) void {
    var buf: [1024]u8 = undefined;
    const loaded = if (fontFromFontconfig(io, alloc, &buf)) |path_z|
        cimgui.zfd_load_font(path_z, 16.0)
    else
        false;
    if (!loaded) cimgui.loadUiFont(16.0);
    // Also keep the built-in bitmap font for the "Blocky font" toggle.
    cimgui.zfd_add_default_font();
}

/// fontFromFontconfig asks `fc-match` for the default sans-serif font's file path,
/// NUL-terminated into `buf`. Null if fontconfig isn't available.
fn fontFromFontconfig(io: std.Io, alloc: std.mem.Allocator, buf: *[1024]u8) ?[*:0]const u8 {
    const out_path = "/tmp/zfd-fontpath";
    const f = std.Io.Dir.cwd().createFile(io, out_path, .{}) catch return null;
    var child = std.process.spawn(io, .{
        .argv = &.{ "fc-match", "-f", "%{file}", "sans-serif" },
        .stdout = .{ .file = f },
    }) catch {
        f.close(io);
        return null;
    };
    _ = child.wait(io) catch {};
    f.close(io);

    const content = std.Io.Dir.cwd().readFileAlloc(io, out_path, alloc, .limited(4096)) catch return null;
    defer alloc.free(content);
    const path = std.mem.trim(u8, content, " \t\r\n");
    if (path.len == 0 or path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

/// applyDpi records the monitor's content scale; the shell applies it each frame
/// (so the Options toggle can enable/disable HiDPI scaling live).
fn applyDpi(window: ?*c.GLFWwindow, shell: *shell_mod.Shell) void {
    var xscale: f32 = 1.0;
    var yscale: f32 = 1.0;
    c.glfwGetWindowContentScale(window, &xscale, &yscale);
    if (xscale > 1.01) shell.dpi_scale = xscale;
}

/// dirExists reports whether `path` is an openable directory.
fn dirExists(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// nextAwake keeps the loop rendering at full rate for ~0.5s after any interaction
/// (mouse move, an active/held widget, or an open popup), then lets it idle.
fn nextAwake(win: ?*c.GLFWwindow, last: *[2]f64, awake: i32) i32 {
    var mx: f64 = 0;
    var my: f64 = 0;
    c.glfwGetCursorPos(win, &mx, &my);
    const moved = mx != last[0] or my != last[1];
    last.* = .{ mx, my };
    const interacting = moved or key_activity or c.igIsAnyItemActive() or c.igIsAnyMouseDown() or
        c.igIsPopupOpen_Str(null, c.ImGuiPopupFlags_AnyPopup);
    key_activity = false;
    return if (interacting) 30 else @max(awake - 1, 0);
}

/// Set by keyCallback (main thread, during event polling); read + cleared by nextAwake.
var key_activity: bool = false;

/// keyCallback handles Ctrl+ +/-/0 (item size) by the key's LAYOUT character (via glfwGetKeyName /
/// XKB), not GLFW's US-physical key code — so "+"/"-" work on any keyboard layout
/// (ImGui only sees the US physical position, which conflates them on non-US layouts).
/// Chained after ImGui's own key callback (installed before ImGui_ImplGlfw init).
fn keyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    key_activity = true; // keep rendering for a moment: keyboard-driven changes (tab
    // switches, focus moves) take a second frame to settle, and the idle loop would
    // otherwise sleep right after the first one
    if (action == c.GLFW_RELEASE or (mods & c.GLFW_MOD_CONTROL) == 0) return;
    const ptr = c.glfwGetWindowUserPointer(window) orelse return;
    const shell: *shell_mod.Shell = @ptrCast(@alignCast(ptr));
    const namep = c.glfwGetKeyName(key, scancode) orelse return;
    const name = std.mem.span(namep);
    if (name.len != 1) return;
    switch (name[0]) {
        '+', '=' => shell.sizeItems(shell.activeBrowser(), 1.1),
        '-' => shell.sizeItems(shell.activeBrowser(), 1.0 / 1.1),
        '0' => shell.sizeItems(shell.activeBrowser(), null),
        else => {},
    }
}

/// dropCallback receives files dropped onto the window from another app. It records the
/// paths + the drop position on the active tab; the table resolves the position next
/// frame — onto a folder row (import into it) or anywhere else (into the current dir).
/// GLFW invokes it during glfwPollEvents on the main thread, so touching the shell is
/// safe. If nothing ever prints under ZFD_DEBUG when you drag files in, GLFW isn't
/// receiving the XDND drop at all (e.g. a Wayland source into our XWayland window).
fn dropCallback(win: ?*c.GLFWwindow, count: c_int, paths: [*c][*c]const u8) callconv(.c) void {
    const ptr = c.glfwGetWindowUserPointer(win) orelse return;
    const shell: *shell_mod.Shell = @ptrCast(@alignCast(ptr));
    var mx: f64 = 0;
    var my: f64 = 0;
    c.glfwGetCursorPos(win, &mx, &my);
    // ImGui works in desktop coordinates when windows can leave the main one.
    if (cimgui.zfd_viewports_enabled()) {
        var wx: c_int = 0;
        var wy: c_int = 0;
        c.glfwGetWindowPos(win, &wx, &wy);
        mx += @floatFromInt(wx);
        my += @floatFromInt(wy);
    }
    if (x11.debug) std.debug.print("zfd[drop]: {d} item(s) at {d:.0},{d:.0}\n", .{ count, mx, my });

    const n: usize = @intCast(count);
    var srcs = std.ArrayList([]u8).empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // GLFW strips "file://" but leaves the URI's percent escapes in place, so a
        // dropped "My%20Photos/a%20b.png" would name a file that doesn't exist and the
        // import would quietly do nothing. decodeDroppedPath un-escapes only when that
        // is what actually makes the path resolve.
        const dup = core.fsops.decodeDroppedPath(shell.io, shell.alloc, std.mem.span(paths[i])) catch continue;
        srcs.append(shell.alloc, dup) catch shell.alloc.free(dup);
    }
    const owned = srcs.toOwnedSlice(shell.alloc) catch return;
    shell.activeBrowser().queueExternalDrop(owned, @floatCast(mx), @floatCast(my));
}

/// pickDropCallback: a file dropped onto the Save/Open chooser is a way of POINTING at
/// it, not of importing it — so instead of copying (the browser's drop), jump to the
/// dropped item: a folder is opened; a file's folder is opened with the file selected,
/// and in a Save dialog its name also becomes the Name (drop the file you want to
/// overwrite). Only the first item counts; the chooser picks within one folder.
fn pickDropCallback(win: ?*c.GLFWwindow, count: c_int, paths: [*c][*c]const u8) callconv(.c) void {
    if (count < 1) return;
    const ptr = c.glfwGetWindowUserPointer(win) orelse return;
    const shell: *shell_mod.Shell = @ptrCast(@alignCast(ptr));
    const path = core.fsops.decodeDroppedPath(shell.io, shell.alloc, std.mem.span(paths[0])) catch return;
    defer shell.alloc.free(path);
    shell.pointAt(path);
}

/// runInfo is a Get Info window for `name` in `dir`: a small window of its own (like
/// Finder's), drawn by the shell in info mode, open until it's closed.
pub fn runInfo(alloc: std.mem.Allocator, io: std.Io, trash_home: []const u8, home: []const u8, dir: []const u8, name: []const u8, pos: ?[2]i32, csd: bool, settings: core.config.Settings) !void {
    var be = try Backend.init(csd, false); // shown once sized and placed
    defer be.deinit();
    installFont(io, alloc);
    var shell = try shell_mod.Shell.init(alloc, io, trash_home, home, dir, null, settings);
    defer shell.deinit();
    shell.win = be.window;
    shell.csd = csd;
    shell.info_mode = true;
    shell.info_name = name;
    shell.actions.info_window = true;
    c.glfwSetWindowUserPointer(be.window, @ptrCast(&shell));
    applyDpi(be.window, &shell);
    const k = (if (shell.dpi_enabled) shell.dpi_scale else 1.0) * shell.zoom;
    c.glfwSetWindowSize(be.window, @intFromFloat(420 * k), @intFromFloat(640 * k));
    if (pos) |p| c.glfwSetWindowPos(be.window, p[0], p[1]);
    c.glfwShowWindow(be.window);

    var awake: i32 = 30;
    var last = [2]f64{ -1, -1 };
    while (!be.shouldClose()) {
        if (awake > 0 or shell.busy()) c.glfwPollEvents() else c.glfwWaitEventsTimeout(1.0);
        shell.updateTabs(); // takes in the folder's listing
        cimgui.zfd_set_blocky(shell.font_nearest);
        be.beginFrame();
        shell.draw();
        awake = nextAwake(be.window, &last, awake);
        be.endFrame();
        cimgui.zfd_set_font_filter(shell.font_nearest);
    }
    shell.orphanScanners();
    be.hide();
}

/// runPick shows a one-shot chooser and prints the chosen path(s), one per line.
/// Returns the process exit code: 0 = chosen, 1 = cancelled / closed.
pub fn runPick(alloc: std.mem.Allocator, io: std.Io, trash_home: []const u8, home: []const u8, start_dir: []const u8, cfg: shell_mod.PickConfig, csd: bool, settings: *core.config.Settings) !u8 {
    // Created hidden: the WM reads a window's dialog type, parent and initial state when
    // it's mapped, and ignores _NET_WM_STATE written to an already-visible window.
    var be = try Backend.init(csd, false); // CSD (our own titlebar) unless ZFD_NO_CSD, same as standalone
    defer be.deinit();
    installFont(io, alloc);

    // Seed the chooser from the persisted prefs (zoom, view toggles, sidebar width) so
    // it matches the standalone browser. home is the REAL $HOME (for the sidebar's
    // Places + bookmarks path); start_dir is the folder the dialog opens in.
    var shell = try shell_mod.Shell.init(alloc, io, trash_home, home, start_dir, cfg, settings.*);
    defer shell.deinit();
    shell.win = be.window;
    shell.csd = csd; // draw our own dialog titlebar (title + window buttons) when borderless
    c.glfwSetWindowUserPointer(be.window, @ptrCast(&shell)); // for the zoom key callback
    applyDpi(be.window, &shell);
    _ = c.glfwSetDropCallback(be.window, pickDropCallback);

    // Set the WM window title regardless of CSD: even borderless, it's what the taskbar
    // and alt-tab show. Under CSD the same text is also drawn in our titlebar
    // (drawDialogTitleRow). Use the requesting app's title (portal `title`) if it sent
    // one, else a purpose default, instead of the generic "ZFD" baked in at creation.
    var title_buf: [256]u8 = undefined;
    c.glfwSetWindowTitle(be.window, dialogTitle(&title_buf, cfg).ptr);

    // Keep the chooser over the requesting app: transient-for its window when the portal
    // gave an X11 parent, else (a Wayland handle an X11 window can't attach to, or no
    // parent at all) keep-above so it can't fall behind the app it's blocking.
    x11.setDialogParent(be.window, parseX11Parent(cfg.parent));
    c.glfwShowWindow(be.window);
    c.glfwFocusWindow(be.window);

    var awake: i32 = 60;
    var last = [2]f64{ -1, -1 };
    var code: u8 = 1; // window closed without confirming
    while (!be.shouldClose()) {
        if (awake > 0 or shell.busy()) c.glfwPollEvents() else c.glfwWaitEventsTimeout(0.5);
        shell.updateTabs();
        cimgui.zfd_set_blocky(shell.font_nearest);
        be.beginFrame();
        shell.draw();
        awake = nextAwake(be.window, &last, awake);
        be.endFrame();
        cimgui.zfd_set_font_filter(shell.font_nearest);

        if (shell.dialogDone()) {
            if (try shell.dialogResult(alloc)) |paths| {
                defer freeOwned(alloc, paths);
                printPaths(paths);
                code = 0;
            }
            break;
        }
    }

    // Persist UI prefs (zoom, view toggles, sidebar) for next time — but keep the
    // standalone browser's remembered folder and window size: the chooser opens at a
    // portal-specified folder in its own window, neither of which should hijack the
    // main browser's resume state. (Copy the dir out first: the struct assignment
    // below overwrites the very buffer `lastDir()` slices into.)
    var keep_dir: [4097]u8 = undefined;
    const kd = settings.lastDir();
    @memcpy(keep_dir[0..kd.len], kd);
    const keep_len = kd.len;
    const keep_w = settings.win_w;
    const keep_h = settings.win_h;
    settings.* = shell.gatherSettings(be.window);
    settings.setLastDir(keep_dir[0..keep_len]);
    settings.win_w = keep_w;
    settings.win_h = keep_h;
    shell.orphanScanners(); // detach scan workers: pressing Save mid-load must not freeze exit
    be.hide();
    return code;
}

/// The main GLFW window: windows ImGui opens outside it (dragged-out dialogs, popups
/// crossing its edge) are made its children.
var g_main_window: ?*c.GLFWwindow = null;

fn startupId(buf: []u8) ?[]const u8 {
    return x11.newStartupId(g_main_window, buf);
}

fn onViewportWindow(w: ?*anyopaque) callconv(.c) void {
    x11.makeChildWindow(w, g_main_window);
}

/// Tm is glibc's struct tm, for localtime_r.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;

/// utcOffset is the local UTC offset at `secs` (daylight saving included), which the
/// core uses to show dates in local time (it has no C library of its own).
fn utcOffset(secs: i64) i64 {
    var tm: Tm = undefined;
    if (localtime_r(&secs, &tm) == null) return 0;
    return tm.gmtoff;
}

const Backend = struct {
    window: *c.GLFWwindow,
    transparent: bool, // CSD: the corners outside the rounded window are see-through
    resize_until: f64 = 0, // vsync stays off until then (glfwGetTime), after a resize step
    last_frame: u64 = 0, // the hash of the last frame drawn (0: none): see endFrame

    fn init(csd: bool, visible: bool) !Backend {
        core.scan.utc_offset = utcOffset; // dates in local time
        // Force GLFW onto X11 (goal 4): our WM integration is Xlib; native Wayland
        // would silently no-op it. XWayland gives a real X11 window.
        c.glfwInitHint(c.GLFW_PLATFORM, c.GLFW_PLATFORM_X11);
        if (c.glfwInit() == 0) return error.GlfwInit;
        errdefer c.glfwTerminate();

        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);
        c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);
        // CSD: borderless, so we draw our own titlebar (moved/resized via X11).
        if (csd) c.glfwWindowHint(c.GLFW_DECORATED, 0);
        // CSD windows have rounded corners: what's outside them must be see-through
        // (a compositor shows the desktop there).
        if (csd) c.glfwWindowHint(c.GLFW_TRANSPARENT_FRAMEBUFFER, 1);
        // Created hidden, always: resize sync must be set up before the WM takes the
        // window on (it's mapped below, unless the caller shows it itself).
        c.glfwWindowHint(c.GLFW_VISIBLE, 0);

        const window = c.glfwCreateWindow(1100, 700, "ZFD", null, null) orelse return error.GlfwCreateWindow;
        x11.enableResizeSync(window);
        if (visible) c.glfwShowWindow(window);
        c.glfwMakeContextCurrent(window);
        c.glfwSwapInterval(1); // vsync

        _ = c.igCreateContext(null);
        cimgui.zfd_enable_viewports();
        c.igStyleColorsDark(null);
        theme.applyMetrics();
        theme.apply(true); // the shell switches to the chosen/system theme on its first frame
        // Our layout-aware zoom key callback — set BEFORE ImGui installs its callbacks
        // (install_callbacks=true) so ImGui chains to it instead of replacing it.
        _ = c.glfwSetKeyCallback(window, keyCallback);
        if (!c.ImGui_ImplGlfw_InitForOpenGL(window, true)) return error.ImGuiGlfwInit;
        if (!c.ImGui_ImplOpenGL3_Init("#version 330 core")) return error.ImGuiOpenGLInit;
        g_main_window = window;
        core.fsops.startup_id = startupId; // programs we open may take focus
        cimgui.zfd_hook_viewport_windows(onViewportWindow);
        cimgui.zfd_free_ctrl_tab();

        c.glfwWindowHint(c.GLFW_TRANSPARENT_FRAMEBUFFER, 0); // not for ImGui's own windows
        _ = c.glfwSetWindowRefreshCallback(window, onRefresh);
        return .{ .window = window, .transparent = csd };
    }

    fn deinit(self: *Backend) void {
        c.ImGui_ImplOpenGL3_Shutdown();
        c.ImGui_ImplGlfw_Shutdown();
        c.igDestroyContext(null);
        c.glfwDestroyWindow(self.window);
        c.glfwTerminate();
    }

    /// hide takes the windows off screen at once when closing: what's left of tearing
    /// down (letting go of a slow share's lookups, background threads) happens unseen
    /// instead of in a window that looks frozen.
    fn hide(self: *Backend) void {
        c.igDestroyPlatformWindows(); // Quick Look, Progress, … (their own OS windows)
        c.glfwHideWindow(self.window);
        c.glfwPollEvents();
    }

    fn shouldClose(self: *Backend) bool {
        return c.glfwWindowShouldClose(self.window) != 0;
    }

    fn beginFrame(self: *Backend) void {
        _ = self;
        // Events are pumped by glfwWaitEventsTimeout in the loop (idle throttle).
        c.ImGui_ImplOpenGL3_NewFrame();
        c.ImGui_ImplGlfw_NewFrame();
        c.igNewFrame();
    }

    fn endFrame(self: *Backend) void {
        c.igRender();
        var fb_w: c_int = 0;
        var fb_h: c_int = 0;
        c.glfwGetFramebufferSize(self.window, &fb_w, &fb_h);
        // ImGui builds every frame from scratch, which is cheap; drawing it (and the
        // swap) is what costs. A frame that comes out the same as the one on screen
        // (the idle heartbeat, the pointer over empty space, a spinner-less wait) isn't
        // drawn again. The WM asking for a redraw, a resize, or a font texture to
        // upload always draws.
        const resizing_now = x11.resizeSyncPending();
        const h = frameHash(fb_w, fb_h);
        const redraw = g_redraw or resizing_now or h == null or h.? != self.last_frame;
        g_redraw = false;
        if (!redraw) {
            c.igUpdatePlatformWindows(); // (windows still open, move and close)
            c.glfwMakeContextCurrent(self.window);
            // No swap to wait on: pace the loop here instead, waking early for input.
            c.glfwWaitEventsTimeout(1.0 / 60.0);
            return;
        }
        self.last_frame = h orelse 0;
        c.glViewport(0, 0, fb_w, fb_h);
        if (self.transparent) c.glClearColor(0, 0, 0, 0) else c.glClearColor(0.10, 0.10, 0.12, 1.00);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        c.ImGui_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
        // Windows dragged outside the main one live in their own OS windows; draw
        // those, then hand the GL context back to the main window.
        c.igUpdatePlatformWindows();
        c.igRenderPlatformWindowsDefault(null, null);
        c.glfwMakeContextCurrent(self.window);
        // While the WM waits on a resize step it paces the frames itself; vsync on top
        // would hold every step for a screen refresh. On again once the drag has rested.
        const resizing = x11.resizeSyncPending();
        const now = c.glfwGetTime();
        if (resizing) {
            if (self.resize_until == 0) c.glfwSwapInterval(0);
            self.resize_until = now + 0.5;
        } else if (self.resize_until != 0 and now >= self.resize_until) {
            self.resize_until = 0;
            c.glfwSwapInterval(1);
        }
        c.glfwSwapBuffers(self.window);
        // The swap only queues the frame: let the GPU finish it before telling the WM
        // it's ready, or the compositor may show the old one (a stale strip, flicker).
        if (resizing) c.glFinish();
        x11.ackResizeSync(); // this frame is drawn at the size the WM asked for
    }
};

/// g_redraw: the WM asked for the window to be drawn again (it was uncovered,
/// mapped, …), so the next frame is drawn even if nothing in it changed.
var g_redraw = true;

fn onRefresh(_: ?*c.GLFWwindow) callconv(.c) void {
    g_redraw = true;
}

/// frameHash is the shim's hash of the frame just rendered (null: draw it anyway).
fn frameHash(fb_w: c_int, fb_h: c_int) ?u64 {
    const v = cimgui.zfd_frame_hash(fb_w, fb_h);
    return if (v == 0) null else v;
}

fn printPaths(paths: [][]u8) void {
    for (paths) |p| {
        writeStdout(p);
        writeStdout("\n");
    }
}

/// dialogTitle picks the chooser window title: the requesting app's title if it sent
/// one, else a purpose-based default. Returns a NUL-terminated string for GLFW.
fn dialogTitle(buf: []u8, cfg: shell_mod.PickConfig) [:0]const u8 {
    // NUL-terminated (GLFW) form of the shared title text, so the WM title and the CSD
    // titlebar (drawDialogTitleRow) never drift apart.
    return std.mem.printSentinel(buf, "{s}", .{shell_mod.dialogTitleText(cfg)}, 0) catch "ZFD";
}

fn writeStdout(bytes: []const u8) void {
    // Raw stdout write (fd 1): the 0.16 std file I/O now threads an Io everywhere,
    // but the chooser result is a tiny, fire-and-forget print, so the direct Linux
    // syscall is simplest. An error encodes as a huge return → caught by the bound.
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.os.linux.write(1, bytes.ptr + off, bytes.len - off);
        if (rc == 0 or rc > bytes.len - off) return;
        off += rc;
    }
}

fn freeOwned(alloc: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| alloc.free(p);
    alloc.free(paths);
}

/// parseX11Parent decodes a portal parent handle like "x11:1a00007" to an XID.
fn parseX11Parent(s: []const u8) ?c_ulong {
    if (!std.mem.startsWith(u8, s, "x11:")) return null;
    const xid = std.fmt.parseInt(c_ulong, s[4..], 16) catch return null;
    return if (xid == 0) null else xid;
}
