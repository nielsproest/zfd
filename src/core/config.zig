//! Persisted UI settings — a tiny `key=value` file under ~/.config/zfd/settings.
//! GUI-free and pure (goal 2): parse/serialize are unit-tested; load/save do the
//! I/O. Unknown or missing keys keep their defaults, so an old or partial file still
//! loads. This is ZFD's answer to Go's internal/config.

const std = @import("std");
const Dir = std.Io.Dir;

pub const Settings = struct {
    show_hidden: bool = false,
    dirs_first: bool = true,
    search_ci: bool = true, // case-insensitive quick-search
    reopen_last: bool = true, // reopen the last folder on launch
    dpi: bool = true, // scale UI by the monitor content scale (HiDPI); toggle in Options
    font_nearest: bool = false, // blocky font (nearest-neighbour, no anti-aliasing)
    reduce_motion: bool = false, // no animations (Settings > Appearance)
    zoom: f32 = 1.0,
    sort_column: u8 = 0, // 0=name 1=size 2=date (scan.SortColumn order)
    sort_ascending: bool = true,
    view_mode: u8 = 0, // the default layout: 0 list, 1 icons, 2 columns, 3 gallery
    group_by: u8 = 0, // the default grouping (scan.GroupBy)
    sidebar_w: f32 = 190,
    theme: u8 = 0, // 0 follow the system, 1 light, 2 dark
    menu_bar: bool = true, // the File/Edit/View/Go/Window/Help bar
    archive_browse: bool = true, // opening an archive shows its contents (else: default app)
    notify_devices: bool = true, // desktop notification when a device is plugged in
    sidebar_hide: u16 = 0, // sidebar items switched off in Settings (bit per item)
    tags_hide: u16 = 0, // tags left out of the sidebar (tag bits)
    preview_pane: bool = false, // View > Show Preview
    folder_sizes: bool = false, // list view: folders show the files directly inside
    icon_scale: f32 = 1.0, // icon view's icon size (View Options)
    grid_spacing: f32 = 1.0, // icon view's room between icons (View Options)
    list_scale: f32 = 1.0, // list view's row and icon size
    columns_scale: f32 = 1.0, // column view's row and icon size
    gallery_scale: f32 = 1.0, // gallery view's thumbnail strip size
    label_right: bool = false, // icon view: names beside the icons, not under them
    item_info: bool = false, // icon view: item count / pixels / size under names
    icon_preview: bool = true, // icon view: thumbnails
    text_scale: f32 = 1.0, // icon view: name text size
    thumb_workers: u8 = 2, // thumbnails decoded at once, at most
    bars_hide: u8 = 0, // toolbar / sidebar / path bar / status bar hidden (bit each)
    win_w: i32 = 1100,
    win_h: i32 = 700,
    last_dir_buf: [4097]u8 = undefined,
    last_dir_len: usize = 0,
    toolbar_buf: [256]u8 = undefined, // the toolbar's items, comma-separated ("" = the default)
    toolbar_len: usize = 0,

    pub fn toolbar(self: *const Settings) []const u8 {
        return self.toolbar_buf[0..self.toolbar_len];
    }
    pub fn setToolbar(self: *Settings, items: []const u8) void {
        const n = @min(items.len, self.toolbar_buf.len);
        @memcpy(self.toolbar_buf[0..n], items[0..n]);
        self.toolbar_len = n;
    }

    pub fn lastDir(self: *const Settings) []const u8 {
        return self.last_dir_buf[0..self.last_dir_len];
    }
    pub fn setLastDir(self: *Settings, dir: []const u8) void {
        const n = @min(dir.len, self.last_dir_buf.len);
        @memcpy(self.last_dir_buf[0..n], dir[0..n]);
        self.last_dir_len = n;
    }
};

/// parse fills a Settings from `key=value` lines; blank/`#` lines and unknown keys
/// are ignored, and an unparseable value keeps the default.
pub fn parse(content: []const u8) Settings {
    var s = Settings{};
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        applyKey(&s, t[0..eq], t[eq + 1 ..]);
    }
    return s;
}

fn applyKey(s: *Settings, key: []const u8, val: []const u8) void {
    if (eql(key, "show_hidden")) {
        s.show_hidden = parseBool(val);
    } else if (eql(key, "dirs_first")) {
        s.dirs_first = parseBool(val);
    } else if (eql(key, "search_ci")) {
        s.search_ci = parseBool(val);
    } else if (eql(key, "reopen_last")) {
        s.reopen_last = parseBool(val);
    } else if (eql(key, "dpi")) {
        s.dpi = parseBool(val);
    } else if (eql(key, "font_nearest")) {
        s.font_nearest = parseBool(val);
    } else if (eql(key, "reduce_motion")) {
        s.reduce_motion = parseBool(val);
    } else if (eql(key, "zoom")) {
        s.zoom = std.fmt.parseFloat(f32, val) catch s.zoom;
    } else if (eql(key, "sort_column")) {
        s.sort_column = std.fmt.parseInt(u8, val, 10) catch s.sort_column;
    } else if (eql(key, "view_mode")) {
        s.view_mode = std.fmt.parseInt(u8, val, 10) catch s.view_mode;
    } else if (eql(key, "group_by")) {
        s.group_by = std.fmt.parseInt(u8, val, 10) catch s.group_by;
    } else if (eql(key, "sort_ascending")) {
        s.sort_ascending = parseBool(val);
    } else if (eql(key, "sidebar_w")) {
        s.sidebar_w = std.fmt.parseFloat(f32, val) catch s.sidebar_w;
    } else if (eql(key, "archive_browse")) {
        s.archive_browse = parseBool(val);
    } else if (eql(key, "notify_devices")) {
        s.notify_devices = parseBool(val);
    } else if (eql(key, "sidebar_hide")) {
        s.sidebar_hide = std.fmt.parseInt(u16, val, 10) catch s.sidebar_hide;
    } else if (eql(key, "icon_scale")) {
        s.icon_scale = std.fmt.parseFloat(f32, val) catch s.icon_scale;
    } else if (eql(key, "list_scale")) {
        s.list_scale = std.fmt.parseFloat(f32, val) catch s.list_scale;
    } else if (eql(key, "columns_scale")) {
        s.columns_scale = std.fmt.parseFloat(f32, val) catch s.columns_scale;
    } else if (eql(key, "gallery_scale")) {
        s.gallery_scale = std.fmt.parseFloat(f32, val) catch s.gallery_scale;
    } else if (eql(key, "grid_spacing")) {
        s.grid_spacing = std.fmt.parseFloat(f32, val) catch s.grid_spacing;
    } else if (eql(key, "label_right")) {
        s.label_right = parseBool(val);
    } else if (eql(key, "item_info")) {
        s.item_info = parseBool(val);
    } else if (eql(key, "icon_preview")) {
        s.icon_preview = parseBool(val);
    } else if (eql(key, "thumb_workers")) {
        s.thumb_workers = std.fmt.parseInt(u8, val, 10) catch s.thumb_workers;
    } else if (eql(key, "text_scale")) {
        s.text_scale = std.fmt.parseFloat(f32, val) catch s.text_scale;
    } else if (eql(key, "folder_sizes")) {
        s.folder_sizes = parseBool(val);
    } else if (eql(key, "bars_hide")) {
        s.bars_hide = std.fmt.parseInt(u8, val, 10) catch s.bars_hide;
    } else if (eql(key, "preview_pane")) {
        s.preview_pane = parseBool(val);
    } else if (eql(key, "tags_hide")) {
        s.tags_hide = std.fmt.parseInt(u16, val, 10) catch s.tags_hide;
    } else if (eql(key, "menu_bar")) {
        s.menu_bar = parseBool(val);
    } else if (eql(key, "theme")) {
        s.theme = @min(std.fmt.parseInt(u8, val, 10) catch s.theme, 2);
    } else if (eql(key, "win_w")) {
        s.win_w = std.fmt.parseInt(i32, val, 10) catch s.win_w;
    } else if (eql(key, "win_h")) {
        s.win_h = std.fmt.parseInt(i32, val, 10) catch s.win_h;
    } else if (eql(key, "last_dir")) {
        s.setLastDir(val);
    } else if (eql(key, "toolbar")) {
        s.setToolbar(val);
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn parseBool(v: []const u8) bool {
    return eql(v, "1") or eql(v, "true");
}

/// serialize renders the settings as `key=value` lines into `out` (an owned slice).
pub fn serialize(alloc: std.mem.Allocator, s: Settings) ![]u8 {
    // Two halves: a format call takes at most 32 arguments.
    const general = try alloc.print(
        \\show_hidden={d}
        \\dirs_first={d}
        \\search_ci={d}
        \\reopen_last={d}
        \\dpi={d}
        \\font_nearest={d}
        \\reduce_motion={d}
        \\zoom={d:.3}
        \\sort_column={d}
        \\sort_ascending={d}
        \\view_mode={d}
        \\group_by={d}
        \\sidebar_w={d:.0}
        \\theme={d}
        \\menu_bar={d}
        \\archive_browse={d}
        \\notify_devices={d}
        \\sidebar_hide={d}
        \\tags_hide={d}
        \\preview_pane={d}
        \\bars_hide={d}
        \\folder_sizes={d}
        \\win_w={d}
        \\win_h={d}
        \\last_dir={s}
        \\
    , .{
        @intFromBool(s.show_hidden),
        @intFromBool(s.dirs_first),
        @intFromBool(s.search_ci),
        @intFromBool(s.reopen_last),
        @intFromBool(s.dpi),
        @intFromBool(s.font_nearest),
        @intFromBool(s.reduce_motion),
        s.zoom,
        s.sort_column,
        @intFromBool(s.sort_ascending),
        s.view_mode,
        s.group_by,
        s.sidebar_w,
        s.theme,
        @intFromBool(s.menu_bar),
        @intFromBool(s.archive_browse),
        @intFromBool(s.notify_devices),
        s.sidebar_hide,
        s.tags_hide,
        @intFromBool(s.preview_pane),
        s.bars_hide,
        @intFromBool(s.folder_sizes),
        s.win_w,
        s.win_h,
        s.lastDir(),
    });
    defer alloc.free(general);
    // The views' item sizes and the icon view's options.
    return alloc.print(
        \\{s}icon_scale={d:.2}
        \\grid_spacing={d:.2}
        \\list_scale={d:.2}
        \\columns_scale={d:.2}
        \\gallery_scale={d:.2}
        \\label_right={d}
        \\item_info={d}
        \\icon_preview={d}
        \\text_scale={d:.2}
        \\toolbar={s}
        \\thumb_workers={d}
        \\
    , .{
        general,
        s.icon_scale,
        s.grid_spacing,
        s.list_scale,
        s.columns_scale,
        s.gallery_scale,
        @intFromBool(s.label_right),
        @intFromBool(s.item_info),
        @intFromBool(s.icon_preview),
        s.text_scale,
        s.toolbar(),
        s.thumb_workers,
    });
}

/// load reads and parses the settings file (defaults if it's missing/unreadable).
pub fn load(io: std.Io, alloc: std.mem.Allocator, path: []const u8) Settings {
    const content = Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 16)) catch return .{};
    defer alloc.free(content);
    return parse(content);
}

/// save writes the settings file, creating its parent directory. Best-effort.
pub fn save(io: std.Io, alloc: std.mem.Allocator, path: []const u8, s: Settings) void {
    if (std.fs.path.dirname(path)) |dir| Dir.cwd().createDirPath(io, dir) catch {};
    const text = serialize(alloc, s) catch return;
    defer alloc.free(text);
    Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {};
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "settings round-trip through serialize/parse preserves non-defaults" {
    const a = testing.allocator;
    var s = Settings{ .show_hidden = true, .dirs_first = false, .zoom = 1.25, .sort_column = 1, .sort_ascending = false, .sidebar_w = 240, .win_w = 1600, .win_h = 900 };
    s.setLastDir("/home/user/projects");

    const text = try serialize(a, s);
    defer a.free(text);

    // Before: defaults differ from what we set.
    const defaults = Settings{};
    try testing.expect(defaults.show_hidden != s.show_hidden);

    // After: parsing the serialized form reproduces the values (a real round-trip).
    const back = parse(text);
    try testing.expectEqual(s.show_hidden, back.show_hidden);
    try testing.expectEqual(s.dirs_first, back.dirs_first);
    try testing.expectApproxEqAbs(s.zoom, back.zoom, 0.001);
    try testing.expectEqual(s.sort_column, back.sort_column);
    try testing.expectEqual(s.sort_ascending, back.sort_ascending);
    try testing.expectEqual(s.win_w, back.win_w);
    try testing.expectEqualStrings("/home/user/projects", back.lastDir());
}

test "parse tolerates junk, comments, and missing keys" {
    const s = parse("# a comment\n\nnonsense line\nshow_hidden=1\nzoom=bogus\n");
    try testing.expect(s.show_hidden); // the good key applied
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.zoom, 0.001); // bad value kept the default
    try testing.expect(s.dirs_first); // missing key kept the default
}
