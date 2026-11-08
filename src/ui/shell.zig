//! The app shell: the OS window, CSD titlebar (tabs + window buttons on one row),
//! toolbar (back/forward/up, hidden, disk-usage toggle, path bar, search), status
//! line, a navigation sidebar (Places + Devices), and the content area (file table
//! + an optional treemap pane below). Model/representation stays split: the shell
//! owns chrome and delegates the file view to `ContentView` and the treemap to
//! `views/treemap`, both drawing the same browser model.

const std = @import("std");
const cimgui = @import("cimgui.zig");
const c = cimgui.c;
const theme = @import("theme.zig");
const core = @import("core");
const table = @import("views/table.zig");
const grid = @import("views/grid.zig");
const columns = @import("views/columns.zig");
const gallery = @import("views/gallery.zig");
const dircache = @import("dircache.zig");
const thumbs = @import("thumbs.zig");
const dirsizes = @import("dirsizes.zig");
const treemap = @import("views/treemap.zig");
const actions = @import("views/actions.zig");
const anim = @import("anim.zig");
const x11 = @import("x11.zig");
const subwindow = @import("subwindow.zig");
const chrome = @import("chrome.zig");
const WinButton = chrome.WinButton;
const winButton = chrome.winButton;
const windowButtonWidth = chrome.windowButtonWidth;
const windowButtonsWidth = chrome.windowButtonsWidth;
const ellipsize = chrome.ellipsize;
const monitorAt = chrome.monitorAt;
const toolbarH = chrome.toolbarH;
const notify = @import("notify.zig");
const quicklook = @import("quicklook.zig");
const pdfview = @import("pdfview.zig");
const connect_mod = @import("connect.zig");

const Browser = core.browser.Browser;
const mounts_mod = core.mounts;

/// ContentView is the pluggable file-view (table now; icon/list grid later). Every
/// view is handed the shared ViewActions so its right-click menu + modals match.
pub const ContentView = union(enum) {
    table: table.TableView,
    grid: grid.GridView,
    columns: columns.ColumnsView,
    gallery: gallery.GalleryView,

    fn draw(self: *ContentView, b: *Browser, act: *actions.ViewActions, keyboard: bool, list_height: f32) void {
        // Follow the folder's layout (remembered per folder; Ctrl+1/2 or the toolbar).
        switch (b.view_mode) {
            .list => if (self.* != .table) {
                self.* = .{ .table = .{} };
            },
            .grid => if (self.* != .grid) {
                self.* = .{ .grid = .{} };
            },
            .columns => if (self.* != .columns) {
                self.* = .{ .columns = .{} };
            },
            .gallery => if (self.* != .gallery) {
                self.* = .{ .gallery = .{} };
            },
        }
        switch (self.*) {
            inline else => |*v| v.draw(b, act, keyboard, list_height),
        }
    }

    /// isRenaming reports whether an inline rename edit (e.g. a freshly-created New
    /// Folder awaiting its name) owns the keyboard. The Save dialog reads this so
    /// Enter-to-commit-the-name isn't also treated as Enter-to-save.
    fn isRenaming(self: *const ContentView) bool {
        return switch (self.*) {
            .table => |*v| v.renaming != null,
            .grid => |*v| v.base.renaming != null,
            .columns => |*v| v.base.renaming != null,
            .gallery => |*v| v.base.renaming != null,
        };
    }
};

pub const PickConfig = struct {
    save: bool = false,
    multiple: bool = false,
    directory: bool = false,
    name: []const u8 = "",
    parent: []const u8 = "",
    filters: []const []const u8 = &.{}, // raw "Name|*.png *.jpg" specs (borrowed from argv)
    current_filter: []const u8 = "", // name of the filter to select initially
    title: []const u8 = "", // window title the requesting app asked for (portal `title`)
    accept: []const u8 = "", // the accept button's label ("" = Open / Save)
};

const Dialog = struct {
    cfg: PickConfig,
    name_buf: [512]u8 = @splat(0),
    name_focus: bool = true,
    name_select: bool = true, // select the stem (not the extension) on focus
    name_active: bool = false, // Name input has keyboard focus (gates the file list's keys)
    confirm_overwrite: bool = false, // raise the "replace existing file?" modal next frame
    name_reason: ?[:0]const u8 = null, // why the current Save name is invalid (null = OK); disables Save
    done: bool = false,
    cancelled: bool = false,
};

/// dialogTitleText is the chooser's title: the requesting app's title if it sent one
/// (portal `title`), else a purpose-based default. Returns a borrowed slice (cfg.title
/// borrows argv and lives for the process; the defaults are static). Used both for the
/// CSD dialog titlebar (drawn) and the WM window title (gui.zig, for taskbar/alt-tab).
pub fn dialogTitleText(cfg: PickConfig) []const u8 {
    if (cfg.title.len > 0) return cfg.title;
    if (cfg.save) return "Save File";
    if (cfg.directory) return "Select Folder";
    if (cfg.multiple) return "Open Files";
    return "Open File";
}

pub const Shell = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    trash_home: []const u8,
    home: []const u8 = "/",
    tabs: std.ArrayList(*Browser) = .empty,
    active: usize = 0,
    clipboard: *core.clipboard.Clipboard = undefined, // ONE clipboard shared by every tab (heap: Shell is moved)
    select_tab: ?*Browser = null, // make this tab the selected one on the next tab-bar draw
    tab_drag: ?*Browser = null, // tab whose header is being held (tear-off candidate)
    closed_tabs: std.ArrayList([]u8) = .empty, // folders of recently closed tabs (owned), newest last
    // Tabs closed this frame, freed at the next one's start: the rest of the frame
    // that closed them (the toolbar, the files) may still be drawing them.
    dying_tabs: std.ArrayList(*Browser) = .empty,
    // Closed tabs (and split panes) still copying or moving: kept, unseen, until their
    // operations are done (they show in the progress list meanwhile).
    finishing_tabs: std.ArrayList(*Browser) = .empty,
    // The window was closed with operations running: it's become a small window with
    // just their progress, and ZFD quits once they're done (gui.run).
    finishing: bool = false,
    finishing_h: c_int = 0, // the height last given to that window
    live_buf: [80]*Browser = undefined, // backing store for actions.live (tabs + split pane)
    // Split view (F3): a second, independent pane beside the current tab. The focused
    // pane is the one the toolbar, path bar, status line and keyboard act on.
    split_b: ?*Browser = null,
    split_view: ContentView = .{ .table = .{} },
    split_focus: bool = false, // true = the right (split) pane has focus
    content: ContentView = .{ .table = .{} },
    actions: actions.ViewActions = .{}, // shared right-click menu + modals for all views
    show_treemap: bool = false,
    files_frac: f32 = 0.6, // file-list share of the main area when the treemap is open (resizable)
    files_frac_press: f32 = 0.6, // files_frac at the splitter drag start
    preview_w: f32 = 0, // the Preview pane's width (0 = the default, from the font size)
    preview_w_press: f32 = 0, // preview_w at the splitter drag start
    load_tab: ?*Browser = null, // the tab whose loading the status line is timing
    load_start: f64 = 0, // when load_tab started loading (ImGui time)
    show_trash: bool = false, // the "Open trashcan" view is open
    trash_items: []core.trash.Item = &.{}, // cached trash listing (owned)
    trash_sorted: bool = false, // trash_items is in the Trash window's chosen order
    net_mounts: []mounts_mod.Mount = &.{}, // network + gvfs/kio shares (owned)
    sidebar_w: f32 = 190, // resizable via the splitter
    min_size: [2]c_int = .{ 0, 0 }, // the window's size limit as last set (applyMinSize)
    body_top: f32 = 0, // the files' top below the column's top (last frame): how tall the toolbar band is
    grip_press: bool = false, // this press is resizing the window: nothing else takes it
    // A Get Info window (`zfd --get-info <path>`): the browser is on the item's folder
    // and the window shows only Get Info for `info_name` (see drawInfoWindow).
    info_mode: bool = false,
    info_name: []const u8 = "",
    info_ready: bool = false,
    info_title: [320]u8 = undefined,
    info_title_len: usize = 0,
    sidebar_w_press: f32 = 190, // sidebar width at the splitter drag start
    mounts: []mounts_mod.Mount = &.{},
    devices: ?*core.devices.Devices = null, // block volumes + mount/unmount/eject (worker thread)
    vols: []core.blockdev.Volume = &.{}, // snapshot of devices' volumes (owned)
    vols_gen: u64 = 0, // devices generation `vols` was taken at
    fstab_entries: []core.fstab.Entry = &.{}, // unmounted fstab mounts, same generation (owned)
    remotes: []core.devices.Devices.RemoteView = &.{}, // rclone remotes, same generation (owned)
    net_base: []u8 = &.{}, // where rclone remotes get mounted (owned)
    // "Connect to Server" dialog fields.
    // The Network page (Locations > Network): shown in place of the files until you go
    // anywhere else; net_page_loc is where the browser was when it opened.
    net_page: bool = false,
    net_page_loc: [1024]u8 = undefined,
    net_page_loc_len: usize = 0,
    connect: connect_mod.Connect = undefined, // Connect to Server (set up in init)
    ffmpeg_path: ?[]u8 = null, // ffmpeg, for the pictures' Quick Actions (owned; null: not installed)
    ffprobe_path: ?[]u8 = null, // ffprobe, for media files' More Info (owned; null: not installed)
    dev_msg: [512]u8 = undefined, // last device error (udisksctl's reason), shown under Devices
    dev_msg_len: usize = 0,
    // New-device notices: the volume paths seen so far (owned; null until the first
    // snapshot, which is the baseline, not news), the in-app banner, and the desktop
    // notifier (browser windows only; one ZFD per session sends desktop ones).
    known_vols: ?std.ArrayList([]u8) = null,
    new_dev_path: [256]u8 = undefined,
    new_dev_path_len: usize = 0,
    new_dev_name: [128]u8 = undefined,
    new_dev_name_len: usize = 0,
    notifier: ?*notify.Notifier = null,
    notify_desktop: bool = false,
    gallery_ql: quicklook.View = .{}, // the gallery view's big preview
    preview: quicklook.View = .{}, // what the Preview pane and the Quick Look window show
    show_preview: bool = false, // View > Show Preview (Ctrl+Shift+P): the pane right of the files
    ql_open: bool = false, // the Quick Look window (Space)
    ql_win: subwindow.SubWindow = .{}, // its window (place, size, full screen, edges)
    ql_pdf_side: bool = false, // a PDF's sidebar was out last frame (the window grows by it)…
    ql_pdf_doc: ?*pdfview.PdfDoc = null, // …in this document
    trash_win: subwindow.SubWindow = .{}, // the Trash window
    progress_win: subwindow.SubWindow = .{}, // Window > Show Progress
    settings_win: subwindow.SubWindow = .{},
    customize_win: subwindow.SubWindow = .{}, // View > Customize Toolbar
    viewopts_win: subwindow.SubWindow = .{}, // View Options (Ctrl+J)
    // Browsing inside Quick Look (a double-click in a folder's view): what it shows
    // instead of the selected item (owned), and that item's path when it started
    // (owned): picking another item in the window, or closing it, ends it.
    ql_path: ?[]u8 = null,
    ql_from: ?[]u8 = null,
    ql_fwd: ?[]u8 = null, // where Back stepped out of: Forward goes back in (owned)
    ql_zoom: quicklook.Zoom = .{}, // its picture's zoom (the Preview pane's stays fitted)
    ql_opened_at: f64 = 0, // when it was opened (it waits a moment for the content)
    folder_sizes: bool = false, // View > Show Folder Sizes (files directly inside)
    view_opts_open: bool = false, // View > Show View Options (Ctrl+J)
    progress_open: bool = false, // Window > Show Progress: the operations in a window
    procwatch: ?*core.procwatch.ProcWatch = null, // copies outside ZFD, open downloads
    scope_home: bool = false, // the search scope is "Home" (vs this folder's subfolders)
    bars_hide: u8 = 0, // Bar bits hidden from the View menu (toolbar, sidebar, path/status bar)
    theme_mode: theme.Mode = .system, // Appearance: follow the desktop, or light/dark
    theme_dark: ?bool = null, // the theme currently applied (null = not yet)
    menu_bar: bool = true, // show File/Edit/View/Go/Window/Help (View > Show Menu Bar)
    settings_open: bool = false, // the Settings window (File > Settings…, Ctrl+,)
    archive_browse: bool = true, // opening an archive browses into it
    notify_devices: bool = true, // desktop notifications for plugged-in devices
    sidebar_hide: u16 = 0, // SideItem bits switched off in Settings > Sidebar
    tags_hide: u16 = 0, // tags switched off in Settings > Tags
    settings_page: u8 = 0, // the Settings window's page (SettingsPage)
    help_pending: enum { none, shortcuts, about } = .none,
    // Passphrase prompt for an encrypted volume.
    unlock_pending: bool = false,
    empty_trash_pending: bool = false, // raise the "Empty Trash?" confirmation
    remove_remote: [64]u8 = @splat(0), // a server to remove, once confirmed ("" = none)
    remove_mp: [std.fs.max_path_bytes]u8 = undefined, // where it's connected ("" = isn't)
    remove_mp_len: usize = 0,
    remove_pending: bool = false, // raise the "Remove server?" confirmation
    unlock_path: [256]u8 = undefined,
    unlock_path_len: usize = 0,
    unlock_name: [128]u8 = undefined,
    unlock_name_len: usize = 0,
    unlock_pass: [512]u8 = @splat(0),
    places: []mounts_mod.Mount = &.{}, // dirs under /mnt, /media, /run/media/<user> (owned)
    bookmarks: std.ArrayList(core.bookmarks.Bookmark) = .empty, // persisted (see core/bookmarks.zig)
    bm_rename: ?usize = null, // bookmark whose label is being edited
    side_open: [3]bool = .{ true, true, true }, // sidebar sections: Favourites, Locations, Tags
    bm_rename_buf: [128]u8 = @splat(0),
    bm_dead: std.ArrayList(bool) = .empty, // per bookmark: its folder isn't there (drawn dimmed)
    bm_checked: f64 = -100, // when bm_dead was last worked out (ImGui time)
    bm_msg: [400]u8 = undefined, // a note under Favourites (a favourite that's gone)
    bm_msg_len: usize = 0,
    bm_edit: ?usize = null, // the bookmark in the Edit Favourite dialog
    bm_edit_pending: bool = false, // open that dialog next frame
    bm_edit_name: [128]u8 = @splat(0),
    bm_edit_loc: [std.fs.max_path_bytes]u8 = @splat(0),
    bm_edit_loc0: [std.fs.max_path_bytes]u8 = @splat(0), // the location as the dialog opened
    // A bookmark on a device/remote that had to be mounted first: when the mount for
    // `after_mount_key` (device path, remote name or fstab target) lands, open this
    // sub-folder of it instead of its top.
    after_mount_key: [512]u8 = undefined,
    after_mount_key_len: usize = 0,
    after_mount_sub: [1024]u8 = undefined,
    after_mount_sub_len: usize = 0,
    bm_path: []u8 = &.{}, // bookmarks file path (owned)
    tags_path: []u8 = &.{}, // the tag list's file (owned): names and colours
    tag_new: [48]u8 = @splat(0), // Settings > Tags: the name for "Add"
    tag_edit: [16][48]u8 = undefined, // Settings > Tags: the names being edited
    tag_edit_live: u16 = 0, // which tag_edit buffers are open (being typed in)
    prefs: *core.folderprefs.FolderPrefs = undefined, // per-folder views, shared by all tabs (owned)
    prefs_path: []u8 = &.{}, // ~/.config/zfd/folders (owned)
    recent_folders: std.ArrayList([]u8) = .empty, // Go ▸ Recent Folders, newest first (owned)
    rf_path: []u8 = &.{}, // ~/.config/zfd/recent-folders (owned)
    rf_seen: [std.fs.max_path_bytes]u8 = undefined, // the folder last noted (rf_seen_len)
    rf_seen_len: usize = 0,
    prefs_mtime: i96 = 0, // the folders file's mtime when last read or written
    prefs_checked: f64 = 0, // when it was last looked at (ImGui time)
    // Where files taken out of archives go (owned); null: archives aren't browsed.
    temp_files: ?*core.archives.TempFiles = null,
    path_buf: [4097]u8 = @splat(0),
    path_active: bool = false,
    focus_path: bool = false, // grab keyboard focus for the path bar next frame (Ctrl+L)
    path_edit: bool = false, // the path bar shows the text field (else breadcrumbs)
    // Address-bar inline autocomplete (Explorer-style): when the user types, the matching
    // subdirectory's remaining letters are inserted and *selected*, so typing overwrites
    // them and Tab/Enter accepts. `ac_typed` is the user-typed prefix we last suggested
    // against (excludes the auto-selected tail); recompletion only fires when it grows,
    // so backspacing deletes the suggestion instead of fighting the user.
    ac_typed: [4097]u8 = @splat(0),
    ac_typed_len: usize = 0,
    ac_active: bool = false, // a suggestion tail is currently inserted+selected
    search_buf: [256]u8 = @splat(0),
    search_active: bool = false,
    focus_search: bool = false, // grab keyboard focus for the search box next frame (Ctrl+F)
    search_open: bool = false, // the search field is unfolded from its magnifier
    dialog: ?Dialog = null,
    dlg_filters: []core.filter.FileFilter = &.{}, // parsed chooser filters (owned); index 0 in the combo = "All files"
    dlg_filter_idx: usize = 0, // 0 = All files; k = dlg_filters[k-1]
    win: ?*anyopaque = null,
    csd: bool = false,
    wm_active: bool = false, // a WM move/resize is in flight (one-shot guard)
    drag_active: bool = false, // an XDND drag-out fired this press (one-shot guard, like wm_active)
    zoom: f32 = 1.0, // the interface's size (Settings ▸ Appearance)
    toolbar_items: [16]ToolItem = default_toolbar ++ @as([10]ToolItem, undefined), // the toolbar's right side, in order
    toolbar_len: usize = default_toolbar.len,
    customize_open: bool = false, // the Customize Toolbar window
    zoom_drag: ?c_int = null, // the Interface slider's value (%) while it's being dragged
    fs_rect: [4]c_int = .{ 0, 0, 0, 0 }, // the window's place before full screen (x, y, w, h)
    thumb_workers: usize = 2, // Settings > Advanced: thumbnails decoded at once, at most
    bg: ?*core.bgio.Bg = null, // the UI's own disk work (config files, path checks), off-thread
    bm_probe: std.ArrayList(usize) = .empty, // favourites asked about, by index (the probe's order)
    bm_probe_n: usize = 0, // how many favourites there were when asked
    drop_probe: std.ArrayList([]u8) = .empty, // paths dropped on "Add current folder", being checked (owned)
    climb_label: [128]u8 = @splat(0), // the favourite being opened (for "it's gone")
    edit_probe: [std.fs.max_path_bytes]u8 = @splat(0), // the path Edit Favourite asked about
    edit_probe_ok: ?bool = null, // its answer (null: not in yet)
    point_path: [std.fs.max_path_bytes]u8 = @splat(0), // a path dropped on the chooser, being checked
    rule_bufs: [8][32]u8 = @splat(@splat(0)), // the search rules' value fields (while typed in)
    dpi_scale: f32 = 1.0, // detected monitor content scale (HiDPI)
    dpi_enabled: bool = true, // apply the DPI scale (toggle in Options); persisted
    reopen_last: bool = true, // reopen the last folder on launch (persisted)
    font_nearest: bool = false, // blocky font (no anti-aliasing); re-asserted each frame
    reduce_motion: bool = false, // Settings > Appearance: no animations
    style_scale: f32 = 1.0, // scale currently baked into the ImGui style (for live toggling)

    pub fn init(alloc: std.mem.Allocator, io: std.Io, trash_home: []const u8, home: []const u8, start_dir: []const u8, pick: ?PickConfig, settings: core.config.Settings) !Shell {
        var self = Shell{ .alloc = alloc, .io = io, .trash_home = trash_home, .home = home };
        self.zoom = settings.zoom;
        self.dpi_enabled = settings.dpi;
        self.reopen_last = settings.reopen_last;
        self.font_nearest = settings.font_nearest;
        self.reduce_motion = settings.reduce_motion;
        self.theme_mode = @fromBackingInt(@intCast(@min(settings.theme, 2)));
        self.menu_bar = settings.menu_bar;
        self.archive_browse = settings.archive_browse;
        self.notify_devices = settings.notify_devices;
        pdfview.snap_pages = settings.pdf_snap;
        pdfview.sidebar_shown = settings.pdf_sidebar;
        self.sidebar_hide = settings.sidebar_hide;
        self.tags_hide = settings.tags_hide;
        self.show_preview = settings.preview_pane;
        self.bars_hide = settings.bars_hide;
        self.folder_sizes = settings.folder_sizes;
        inline for (.{ .grid, .list, .columns, .gallery }, .{ settings.icon_scale, settings.list_scale, settings.columns_scale, settings.gallery_scale }) |mode, v| {
            const s = self.actions.itemSize(mode);
            s.v.* = std.math.clamp(v, s.min, s.max);
        }
        self.actions.grid_spacing = std.math.clamp(settings.grid_spacing, 0.5, 2.0);
        self.actions.label_right = settings.label_right;
        self.actions.item_info = settings.item_info;
        self.actions.icon_preview = settings.icon_preview;
        self.actions.text_scale = std.math.clamp(settings.text_scale, 0.8, 1.5);
        self.thumb_workers = std.math.clamp(settings.thumb_workers, 1, thumbs.Cache.max_workers);
        if (settings.toolbar().len > 0) {
            // Unknown names (from a newer zfd) are skipped.
            self.toolbar_len = 0;
            var it = std.mem.splitScalar(u8, settings.toolbar(), ',');
            while (it.next()) |name| {
                const item = std.meta.stringToEnum(ToolItem, name) orelse continue;
                if (self.toolbar_len == self.toolbar_items.len or std.mem.indexOfScalar(ToolItem, self.toolbar_items[0..self.toolbar_len], item) != null) continue;
                self.toolbar_items[self.toolbar_len] = item;
                self.toolbar_len += 1;
            }
        }
        theme.watch.start(io, home);
        self.sidebar_w = settings.sidebar_w;
        self.sidebar_w_press = settings.sidebar_w;
        if (pick) |cfg| {
            var d = Dialog{ .cfg = cfg };
            if (cfg.save) {
                const n = @min(cfg.name.len, d.name_buf.len - 1);
                @memcpy(d.name_buf[0..n], cfg.name[0..n]);
                d.name_buf[n] = 0;
            }
            self.dialog = d;
            // Parse the app's file-type filters; select `current_filter` if given, else
            // the first (the app asked for filtering), else "All files" (index 0).
            self.parseDialogFilters(cfg);
        }

        // Sidebar sources: read in BOTH standalone and dialog/chooser mode so a Save/
        // Open dialog gets the same Places/Bookmarks/Devices navigation (including NFS
        // and other network shares). Devices come from /proc/mounts (read once; hotplug
        // is a TODO).
        self.reloadMounts();
        // Block volumes (USB sticks, other disks' partitions) with mount/unmount/eject.
        // Best-effort: without it the sidebar still shows /proc/mounts as before.
        self.devices = core.devices.Devices.create(io, alloc, wakeUi) catch null;
        // rclone remotes mount under the runtime dir (a per-session tmpfs; nothing is
        // stored there, it only holds the mount points).
        {
            const rt = std.c.getenv("XDG_RUNTIME_DIR");
            self.net_base = if (rt != null and std.mem.span(rt.?).len > 0)
                (std.fs.path.join(alloc, &.{ std.mem.span(rt.?), "zfd-net" }) catch &.{})
            else
                (alloc.print("/tmp/zfd-net-{d}", .{std.os.linux.getuid()}) catch &.{});
            if (self.devices) |d| d.setNetBase(self.net_base);
        }
        self.ffmpeg_path = core.fsops.findOnPath(io, alloc, "ffmpeg");
        self.ffprobe_path = core.fsops.findOnPath(io, alloc, "ffprobe");
        @import("quicklook.zig").ffprobe = self.ffprobe_path;
        self.actions.ffmpeg = self.ffmpeg_path;
        // Connect to Server's rclone listens next to the mounts, in the runtime dir.
        self.connect = connect_mod.Connect.init(alloc, io, self.net_base, home);

        // Bookmarks persist under ~/.config/zfd/bookmarks.
        const bm_cfg = core.xdg.configHome(alloc, null, home) catch null;
        if (bm_cfg) |cfg_dir| {
            defer alloc.free(cfg_dir);
            self.bm_path = std.fs.path.join(alloc, &.{ cfg_dir, "zfd", "bookmarks" }) catch &.{};
            self.loadBookmarks();
            self.prefs_path = std.fs.path.join(alloc, &.{ cfg_dir, "zfd", "folders" }) catch &.{};
            self.rf_path = std.fs.path.join(alloc, &.{ cfg_dir, "zfd", "recent-folders" }) catch &.{};
            self.loadRecentFolders();
            self.tags_path = std.fs.path.join(alloc, &.{ cfg_dir, "zfd", "tags" }) catch &.{};
            self.loadTags();
        }
        // Archives open as folders, read in place (core/arcfs.zig); a file opened from
        // one is taken out to the cache dir (core/archives.zig). Not in a file chooser:
        // a file picked inside an archive has no path the app could open.
        if (self.dialog == null) {
            const ch = std.c.getenv("XDG_CACHE_HOME");
            const cache_home = if (ch != null and std.mem.span(ch.?).len > 0)
                (alloc.dupe(u8, std.mem.span(ch.?)) catch null)
            else
                (std.fs.path.join(alloc, &.{ home, ".cache" }) catch null);
            if (cache_home) |dir| {
                defer alloc.free(dir);
                if (alloc.create(core.archives.TempFiles)) |tf| {
                    if (core.archives.TempFiles.init(io, alloc, dir)) |t| {
                        tf.* = t;
                        self.temp_files = tf;
                        @import("quicklook.zig").temp_files = tf; // PDFs, videos inside archives
                    } else |_| alloc.destroy(tf);
                } else |_| {}
            }
        }
        // Per-folder views: folders the user set a view in; the rest use the saved
        // default (the settings file's sort/hidden keys).
        self.prefs = try alloc.create(core.folderprefs.FolderPrefs);
        self.prefs.* = core.folderprefs.FolderPrefs.init(alloc);
        if (self.prefs_path.len > 0) {
            self.prefs.load(io, self.prefs_path);
            self.prefs_mtime = folderViewsMtime(io, self.prefs_path);
        }
        self.bg = core.bgio.Bg.create(io, alloc, wakeUi) catch null;
        self.prefs.default = .{
            .sort = .{
                .column = @fromBackingInt(@intCast(@min(settings.sort_column, @typeInfo(core.scan.SortColumn).@"enum".field_names.len - 1))),
                .ascending = settings.sort_ascending,
                .dirs_first = settings.dirs_first,
            },
            .show_hidden = settings.show_hidden,
            .mode = if (settings.view_mode <= 3) @fromBackingInt(@intCast(settings.view_mode)) else .list,
            .group = if (settings.group_by <= @backingInt(core.scan.GroupBy.tags)) @fromBackingInt(@intCast(settings.group_by)) else .none,
        };
        self.clipboard = try alloc.create(core.clipboard.Clipboard);
        self.clipboard.* = .{};
        errdefer alloc.destroy(self.clipboard);
        const b = try Browser.init(alloc, io, start_dir, trash_home, home);
        errdefer b.deinit();
        b.shareClipboard(self.clipboard);
        // Apply persisted view preferences to the first tab (they take effect when
        // the async listing arrives and rebuildView runs).
        b.search_ci = settings.search_ci;
        b.prefs = self.prefs;
        b.temp_files = self.temp_files;
        b.applyFolderView();
        // Probe for bsdtar here (not in Browser.init): the pure `core` module stays
        // libc-free, and findTool reads std.c.environ. null just hides the archive menu.
        b.archive_tool = core.archive.findTool(io, alloc);
        // The active chooser filter takes effect when the first listing arrives.
        if (self.dlg_filter_idx > 0 and self.dlg_filter_idx <= self.dlg_filters.len)
            b.active_filter = self.dlg_filters[self.dlg_filter_idx - 1];
        try self.tabs.append(alloc, b);
        return self;
    }

    /// reloadMounts (re)reads the mount-derived sidebar sources. Called at start and
    /// whenever the device worker sees the mount table change.
    fn reloadMounts(self: *Shell) void {
        if (self.mounts.len > 0) mounts_mod.free(self.alloc, self.mounts);
        if (self.net_mounts.len > 0) mounts_mod.free(self.alloc, self.net_mounts);
        if (self.places.len > 0) mounts_mod.free(self.alloc, self.places);
        self.mounts = mounts_mod.read(self.io, self.alloc) catch &.{};
        self.net_mounts = mounts_mod.readNetwork(self.io, self.alloc); // network + gvfs/kio shares
        // Also list the directories directly under /mnt, /media and /run/media/<user>
        // so every mount target there is reachable (even ones not in /proc/mounts),
        // skipping any path already shown above as a real mount.
        var excl = std.ArrayList([]const u8).empty;
        defer excl.deinit(self.alloc);
        for (self.mounts) |m| excl.append(self.alloc, m.mountpoint) catch {};
        for (self.net_mounts) |m| excl.append(self.alloc, m.mountpoint) catch {};
        self.places = mounts_mod.readPlaces(self.io, self.alloc, std.fs.path.basename(self.home), excl.items);
    }

    /// pollDevices folds in the device worker's news once per frame: a changed volume
    /// list (hotplug, or a mount made anywhere), and finished mount/unmount/eject actions.
    fn pollDevices(self: *Shell) void {
        const d = self.devices orelse return;
        const g = d.generation();
        if (g != self.vols_gen) {
            self.vols_gen = g;
            core.blockdev.free(self.alloc, self.vols);
            self.vols = d.snapshot(self.alloc);
            core.fstab.free(self.alloc, self.fstab_entries);
            self.fstab_entries = d.fstabSnapshot(self.alloc);
            core.devices.Devices.freeRemoteViews(self.alloc, self.remotes);
            self.remotes = d.remotesSnapshot(self.alloc);
            self.noticeNewVolumes();
            self.reloadMounts();
        }
        if (self.notifier) |n| if (n.takeAction()) |key| {
            defer self.alloc.free(key);
            if (self.glfwWin()) |w| c.glfwFocusWindow(w); // clicked in the desktop's notification
            self.openNewDevice(key);
        };
        while (d.takeEvent()) |ev| {
            defer ev.deinit(self.alloc);
            switch (ev) {
                .mounted => |m| {
                    self.dev_msg_len = 0;
                    // Opened through a bookmark deeper inside: go there instead.
                    if (self.after_mount_key_len > 0 and std.mem.eql(u8, m.path, self.after_mount_key[0..self.after_mount_key_len])) {
                        self.after_mount_key_len = 0;
                        var jb: [std.fs.max_path_bytes]u8 = undefined;
                        self.activeBrowser().navigate(joinSub(&jb, m.mountpoint, self.after_mount_sub[0..self.after_mount_sub_len])) catch {};
                    } else if (m.open) self.activeBrowser().navigate(m.mountpoint) catch {};
                },
                .unmounted => |u| {
                    self.dev_msg_len = 0;
                    // Tabs still inside the volume would only show an error now.
                    for (self.liveBrowsers()) |t| {
                        if (isUnder(t.dir, u.mountpoint)) t.navigate(self.home) catch {};
                    }
                },
                .failed => |f| {
                    const n = @min(f.msg.len, self.dev_msg.len);
                    @memcpy(self.dev_msg[0..n], f.msg[0..n]);
                    self.dev_msg_len = n;
                },
            }
        }
    }

    /// noticeNewVolumes compares a fresh volume snapshot with the volumes seen before:
    /// one that just appeared (plugged in) gets the in-app banner and, in the browser,
    /// a desktop notification with an Open action. The first snapshot is the baseline.
    fn noticeNewVolumes(self: *Shell) void {
        const first = self.known_vols == null;
        if (first) self.known_vols = .empty;
        var known = &self.known_vols.?;
        var fresh: ?core.blockdev.Volume = null;
        for (self.vols) |v| {
            var seen = false;
            for (known.items) |p| if (std.mem.eql(u8, p, v.path)) {
                seen = true;
                break;
            };
            if (seen) continue;
            const dup = self.alloc.dupe(u8, v.path) catch continue;
            known.append(self.alloc, dup) catch self.alloc.free(dup);
            if (!first and fresh == null) fresh = v;
        }
        // Forget unplugged volumes, so plugging the same stick in again is news again.
        var i: usize = 0;
        while (i < known.items.len) {
            var present = false;
            for (self.vols) |v| if (std.mem.eql(u8, v.path, known.items[i])) {
                present = true;
                break;
            };
            if (present) i += 1 else self.alloc.free(known.swapRemove(i));
        }
        const v = fresh orelse return;
        const pn = @min(v.path.len, self.new_dev_path.len);
        @memcpy(self.new_dev_path[0..pn], v.path[0..pn]);
        self.new_dev_path_len = pn;
        const nn = @min(v.name.len, self.new_dev_name.len);
        @memcpy(self.new_dev_name[0..nn], v.name[0..nn]);
        self.new_dev_name_len = nn;

        if (self.dialog != null) return; // a file chooser doesn't announce hardware
        if (self.notifier == null) {
            self.notifier = notify.Notifier.create(self.io, self.alloc, wakeUi) catch null;
            const rt = std.c.getenv("XDG_RUNTIME_DIR");
            self.notify_desktop = notify.primary(if (rt) |r| std.mem.span(r) else "");
        }
        if (!self.notify_desktop or !self.notify_devices) return;
        const n = self.notifier orelse return;
        var bb: [300]u8 = undefined;
        var sb: [24]u8 = undefined;
        const body = std.mem.print(&bb, "{s}{s}  \u{00B7}  {s}", .{
            if (v.locked) "Encrypted  \u{00B7}  " else "", v.fstype, core.blockdev.humanSize(&sb, v.size),
        }) catch "";
        var tb: [160]u8 = undefined;
        const title = std.mem.print(&tb, "{s} connected", .{v.name}) catch "Device connected";
        n.send(title, body, if (v.removable) "drive-removable-media" else "drive-harddisk", if (v.mounted()) "Open" else if (v.locked) "Unlock" else "Mount and Open", v.path);
    }

    /// openNewDevice handles "Open" on a new-device notice (banner or notification):
    /// open it if mounted, ask for the passphrase if locked, else mount and open it.
    fn openNewDevice(self: *Shell, path: []const u8) void {
        self.new_dev_path_len = 0;
        const d = self.devices orelse return;
        for (self.vols) |v| {
            if (!std.mem.eql(u8, v.path, path)) continue;
            if (v.locked) {
                self.askUnlock(v);
            } else if (v.mounted()) {
                self.activeBrowser().navigate(v.mountpoint) catch {};
            } else d.mount(v.path, true);
            return;
        }
    }

    /// drawNewDeviceBanner is the in-app notice for a just-plugged volume.
    fn drawNewDeviceBanner(self: *Shell) void {
        if (self.new_dev_path_len == 0) return;
        var lb: [200]u8 = undefined;
        const msg = std.mem.print(&lb, "New: {s}", .{self.new_dev_name[0..self.new_dev_name_len]}) catch "New device";
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.info());
        cimgui.textUnformatted(msg);
        c.igPopStyleColor(1);
        if (c.igSmallButton("Open##newdev")) {
            var pb: [256]u8 = undefined;
            const n = self.new_dev_path_len;
            @memcpy(pb[0..n], self.new_dev_path[0..n]);
            self.openNewDevice(pb[0..n]);
        }
        c.igSameLine(0, -1);
        if (c.igSmallButton("Dismiss##newdev")) self.new_dev_path_len = 0;
    }

    /// fstabRow draws an fstab mount that isn't mounted (dimmed, like an unmounted
    /// volume): click mounts it (asking for a password unless fstab lets users) and
    /// opens it.
    fn fstabRow(self: *Shell, e: core.fstab.Entry, i: usize) void {
        const d = self.devices orelse return;
        const fbusy = d.isBusy(e.target);
        var lbuf: [320]u8 = undefined;
        const label = std.mem.printSentinel(&lbuf, "{s}{s}##fst{d}", .{ e.label(), if (fbusy) " \u{2026}" else "", i }, 0) catch return;
        // Not mounted: a click (left or right) offers to mount it, as its menu.
        _ = sideItem(label, false, .drive, true);
        c.igOpenPopupOnItemClick(null, c.ImGuiPopupFlags_MouseButtonLeft);
        if (c.igBeginItemTooltip()) {
            var tb: [900]u8 = undefined;
            const tip = std.mem.print(&tb, "{s}  \u{00B7}  {s}\n{s}\nNot mounted. Click to mount it{s}", .{
                e.spec, e.fstype, e.target, if (e.user_mountable) "" else " (asks for your password)",
            }) catch e.target;
            cimgui.textUnformatted(tip);
            c.igEndTooltip();
        }
        if (c.igBeginPopupContextItem(null, c.ImGuiPopupFlags_MouseButtonRight)) {
            if (c.igMenuItem_Bool("Mount and Open", null, false, !fbusy)) d.mountTarget(e.target, e.user_mountable, true);
            if (c.igMenuItem_Bool("Mount", null, false, !fbusy)) d.mountTarget(e.target, e.user_mountable, false);
            c.igSeparator();
            var ib: [600]u8 = undefined;
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
            cimgui.textUnformatted(std.mem.print(&ib, "{s} ({s})", .{ e.spec, e.fstype }) catch e.spec);
            c.igPopStyleColor(1);
            c.igEndPopup();
        }
    }

    /// fstabAt reports whether `path` is an unmounted fstab mount point (listed by
    /// fstabRow, so the plain folder under /mnt is not shown twice).
    fn fstabAt(self: *Shell, path: []const u8) bool {
        for (self.fstab_entries) |e| if (std.mem.eql(u8, e.target, path)) return true;
        return false;
    }

    /// volumeRow draws one block volume in the Devices section. Mounted: click opens it,
    /// it takes drops, right-click offers unmount/eject. Unmounted (dimmed): click mounts
    /// it and opens it.
    fn volumeRow(self: *Shell, b: *Browser, v: core.blockdev.Volume, i: usize) void {
        const d = self.devices orelse return;
        const vbusy = d.isBusy(v.path) or d.isBusy(v.drive);
        var lbuf: [320]u8 = undefined;
        const label = std.mem.printSentinel(&lbuf, "{s}{s}{s}##vol{d}", .{ v.name, if (v.locked) " (locked)" else "", if (vbusy) " \u{2026}" else "", i }, 0) catch return;
        const clicked = sideItem(label, v.mounted() and isUnder(b.dir, v.mountpoint) and std.mem.eql(u8, b.dir, v.mountpoint), if (v.removable) .usb else .drive, !v.mounted());
        if (clicked and !vbusy) {
            if (v.locked) {
                self.askUnlock(v);
            } else if (v.mounted()) b.navigate(v.mountpoint) catch {} else d.mount(v.path, true);
        }
        if (v.mounted() and c.igIsItemClicked(c.ImGuiMouseButton_Middle)) self.newTabAt(v.mountpoint);
        if (c.igBeginItemTooltip()) {
            var sb: [24]u8 = undefined;
            var tb: [600]u8 = undefined;
            const tip = std.mem.print(&tb, "{s}  \u{00B7}  {s}  \u{00B7}  {s}\n{s}", .{
                v.path,                                                                                                                           v.fstype, core.blockdev.humanSize(&sb, v.size),
                if (v.locked) "Encrypted. Click to unlock" else if (v.mounted()) v.mountpoint else "Not mounted. Click to mount",
            }) catch v.path;
            cimgui.textUnformatted(tip);
            c.igEndTooltip();
        }
        if (v.mounted()) self.dropZone(v.mountpoint);
        if (c.igBeginPopupContextItem(null, c.ImGuiPopupFlags_MouseButtonRight)) {
            defer c.igEndPopup();
            if (v.mounted()) {
                if (c.igMenuItem_Bool("Open", null, false, true)) b.navigate(v.mountpoint) catch {};
                self.newTabMenuItem(v.mountpoint);
                c.igSeparator();
                if (c.igMenuItem_Bool(if (v.crypt_parent.len > 0) "Unmount and Lock" else "Unmount", null, false, !vbusy))
                    d.unmount(v.path, v.mountpoint, v.crypt_parent);
            } else if (v.locked) {
                if (c.igMenuItem_Bool("Unlock\u{2026}", null, false, !vbusy)) self.askUnlock(v);
            } else {
                if (c.igMenuItem_Bool("Mount", null, false, !vbusy)) d.mount(v.path, false);
                if (c.igMenuItem_Bool("Mount and Open", null, false, !vbusy)) d.mount(v.path, true);
            }
            if (v.removable and c.igMenuItem_Bool("Eject", null, false, !vbusy)) d.eject(v.drive);
        }
    }

    fn drawEmptyTrashModal(self: *Shell) void {
        if (self.empty_trash_pending) {
            c.igOpenPopup_Str("Empty Trash", 0);
            self.empty_trash_pending = false;
        }
        if (!c.igBeginPopupModal("Empty Trash", null, c.ImGuiWindowFlags_AlwaysAutoResize)) return;
        defer c.igEndPopup();
        cimgui.textUnformatted("Permanently delete everything in the Trash?\nThis cannot be undone.");
        c.igSeparator();
        if (c.igButton("Empty Trash", cimgui.vec2(0, 0))) {
            self.trashDo(.empty, null); // off the render thread (it can be a lot of files)
            c.igCloseCurrentPopup();
        }
        c.igSameLine(0, -1);
        if (c.igButton("Cancel", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) c.igCloseCurrentPopup();
    }

    /// drawRemoveRemoteModal asks before a server is removed: it's disconnected and
    /// forgotten (rclone's settings for it go), its files stay on the server.
    fn drawRemoveRemoteModal(self: *Shell) void {
        if (self.remove_pending) {
            c.igOpenPopup_Str("Remove Server", 0);
            self.remove_pending = false;
        }
        if (!c.igBeginPopupModal("Remove Server", null, c.ImGuiWindowFlags_AlwaysAutoResize)) return;
        defer c.igEndPopup();
        const name = std.mem.sliceTo(&self.remove_remote, 0);
        var tb: [256]u8 = undefined;
        cimgui.textUnformatted(std.mem.print(&tb, "Remove \u{201C}{s}\u{201D}?\nIt's disconnected and its settings are forgotten.\nThe files on it stay where they are.", .{name}) catch "Remove this server?");
        c.igSeparator();
        if (c.igButton("Remove", cimgui.vec2(0, 0))) {
            const mp = self.remove_mp[0..self.remove_mp_len];
            if (mp.len > 0) for (self.liveBrowsers()) |t| if (isUnder(t.dir, mp)) t.navigate(self.home) catch {};
            if (self.devices) |d| d.removeRemote(name, mp);
            c.igCloseCurrentPopup();
        }
        c.igSameLine(0, -1);
        if (c.igButton("Cancel", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) c.igCloseCurrentPopup();
    }

    fn askRemoveRemote(self: *Shell, r: core.devices.Devices.RemoteView) void {
        @memset(&self.remove_remote, 0);
        const n = @min(r.name.len, self.remove_remote.len - 1);
        @memcpy(self.remove_remote[0..n], r.name[0..n]);
        const mp = if (r.mounted) r.mountpoint else "";
        self.remove_mp_len = @min(mp.len, self.remove_mp.len);
        @memcpy(self.remove_mp[0..self.remove_mp_len], mp[0..self.remove_mp_len]);
        self.remove_pending = true;
    }

    /// remoteMenu is a server's menu (the sidebar's and the Network page's): open or
    /// connect it, disconnect it, change its settings, or remove it.
    fn remoteMenu(self: *Shell, b: *Browser, r: core.devices.Devices.RemoteView) void {
        const d = self.devices orelse return;
        const busy_r = d.isBusy(r.name) or d.isBusy(r.mountpoint);
        if (r.mounted) {
            if (c.igMenuItem_Bool("Open", null, false, true)) b.navigate(r.mountpoint) catch {};
            self.newTabMenuItem(r.mountpoint);
            if (c.igMenuItem_Bool("Disconnect", null, false, !busy_r)) {
                for (self.liveBrowsers()) |t| if (isUnder(t.dir, r.mountpoint)) t.navigate(self.home) catch {};
                d.unmountRemote(r.mountpoint);
            }
        } else {
            if (c.igMenuItem_Bool("Connect and Open", null, false, !busy_r)) d.mountRemote(r.name, true);
            if (c.igMenuItem_Bool("Connect", null, false, !busy_r)) d.mountRemote(r.name, false);
        }
        c.igSeparator();
        if (c.igMenuItem_Bool("Edit\u{2026}", null, false, !busy_r)) self.connect.openEdit(r.name);
        if (c.igMenuItem_Bool("Remove\u{2026}", null, false, !busy_r)) self.askRemoveRemote(r);
    }

    fn askUnlock(self: *Shell, v: core.blockdev.Volume) void {
        const pn = @min(v.path.len, self.unlock_path.len);
        @memcpy(self.unlock_path[0..pn], v.path[0..pn]);
        self.unlock_path_len = pn;
        const nn = @min(v.name.len, self.unlock_name.len);
        @memcpy(self.unlock_name[0..nn], v.name[0..nn]);
        self.unlock_name_len = nn;
        std.crypto.secureZero(u8, &self.unlock_pass);
        self.unlock_pending = true;
    }

    /// drawUnlockModal asks for an encrypted volume's passphrase. It goes straight to
    /// the device worker (which pipes it to udisksctl) and is wiped here right after.
    fn drawUnlockModal(self: *Shell) void {
        if (self.unlock_pending) {
            c.igOpenPopup_Str("Unlock volume", 0);
            self.unlock_pending = false;
        }
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(cimgui.vec2(vp.*.WorkPos.x + vp.*.WorkSize.x * 0.5, vp.*.WorkPos.y + vp.*.WorkSize.y * 0.5), c.ImGuiCond_Appearing, cimgui.vec2(0.5, 0.5));
        if (!c.igBeginPopupModal("Unlock volume", null, c.ImGuiWindowFlags_AlwaysAutoResize)) return;
        defer c.igEndPopup();
        var tb: [200]u8 = undefined;
        cimgui.textUnformatted(std.mem.print(&tb, "\"{s}\" is encrypted. Enter its passphrase:", .{self.unlock_name[0..self.unlock_name_len]}) catch "Enter the passphrase:");
        if (c.igIsWindowAppearing()) c.igSetKeyboardFocusHere(0);
        c.igSetNextItemWidth(320);
        theme.pushFields();
        const entered = c.igInputText("##pass", &self.unlock_pass, self.unlock_pass.len, c.ImGuiInputTextFlags_Password | c.ImGuiInputTextFlags_EnterReturnsTrue, null, null);
        theme.popFields();
        const pass = std.mem.sliceTo(&self.unlock_pass, 0);
        c.igBeginDisabled(pass.len == 0);
        const go = c.igButton("Unlock", cimgui.vec2(0, 0)) or (entered and pass.len > 0);
        c.igEndDisabled();
        c.igSameLine(0, -1);
        const cancel = c.igButton("Cancel", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false);
        if (go) if (self.devices) |d| d.unlock(self.unlock_path[0..self.unlock_path_len], pass, true);
        if (go or cancel) {
            std.crypto.secureZero(u8, &self.unlock_pass);
            c.igCloseCurrentPopup();
        }
    }

    fn openNetworkPage(self: *Shell, b: *Browser) void {
        const loc = b.location();
        const n = @min(loc.len, self.net_page_loc.len);
        @memcpy(self.net_page_loc[0..n], loc[0..n]);
        self.net_page_loc_len = n;
        self.net_page = true;
        if (self.devices) |d| d.browseNetwork(true);
    }

    fn closeNetworkPage(self: *Shell) void {
        self.net_page = false;
        if (self.devices) |d| d.browseNetwork(false);
    }

    /// drawNetworkPage is Finder's Network: the computers and servers on the local
    /// network offering a file service (found by avahi), then the servers you've
    /// added, and Connect to Server. Connecting to a found one fills in the dialog.
    fn drawNetworkPage(self: *Shell, b: *Browser) void {
        _ = c.igBeginChild_Str("##network", cimgui.vec2(0, 0), c.ImGuiChildFlags_AlwaysUseWindowPadding, 0);
        defer c.igEndChild();
        const d = self.devices orelse {
            dimText("Network locations aren't available here.");
            return;
        };
        const snap = d.serversSnapshot(self.alloc);
        defer core.netbrowse.freeSlice(self.alloc, snap.servers);

        const bw = c.igCalcTextSize("Connect to Server\u{2026}", null, false, -1).x + c.igGetStyle().*.FramePadding.x * 2;
        c.igSetCursorPosX(c.igGetCursorPosX() + @max(c.igGetContentRegionAvail().x - bw, 0));
        if (c.igButton("Connect to Server\u{2026}", cimgui.vec2(0, 0))) self.connect.open(null);

        c.igSeparatorText("On this network");
        if (snap.servers.len == 0) switch (snap.state) {
            .no_avahi => wrapDim("To see the computers and servers around you, install avahi and start avahi-daemon (they announce themselves over Bonjour / mDNS)."),
            .ready => wrapDim("Nothing on this network is offering files (SMB, SFTP, WebDAV or FTP)."),
            else => dimText("Looking\u{2026}"),
        };
        for (snap.servers, 0..) |sv, i| {
            c.igPushID_Int(@intCast(i));
            defer c.igPopID();
            var db: [160]u8 = undefined;
            const kind_name = switch (sv.kind) {
                .smb => "SMB",
                .sftp => "SFTP",
                .webdav => if (sv.secure) "WebDAV (https)" else "WebDAV",
                .ftp => "FTP",
            };
            const detail = std.mem.print(&db, "{s} \u{00B7} {s}", .{ kind_name, sv.host }) catch kind_name;
            if (self.networkRow(sv.name, detail, false, "Connect\u{2026}")) self.prefillConnect(sv);
        }

        c.igSpacing();
        c.igSeparatorText("Your servers");
        if (self.remotes.len == 0) wrapDim("Servers you connect to appear here and in the sidebar.");
        for (self.remotes, 0..) |r, i| {
            c.igPushID_Int(@intCast(i + 10_000));
            defer c.igPopID();
            var db: [160]u8 = undefined;
            const detail = std.mem.print(&db, "{s} \u{00B7} {s}", .{ r.kind, if (r.mounted) "connected" else "not connected" }) catch r.kind;
            if (self.networkRow(r.name, detail, r.mounted, if (r.mounted) "Open" else "Connect")) {
                if (r.mounted) b.navigate(r.mountpoint) catch {} else d.mountRemote(r.name, true);
            }
            if (c.igBeginPopup("##netmenu", 0)) {
                defer c.igEndPopup();
                self.remoteMenu(b, r);
            }
        }
    }

    /// networkRow is one server on the Network page: an icon, its name over a dim
    /// detail line, and a button on the right. Returns whether it (or a double-click
    /// on the row) was used.
    fn networkRow(self: *Shell, name: []const u8, detail: []const u8, on: bool, action: [:0]const u8) bool {
        _ = self;
        const fs = c.igGetFontSize();
        const row_h = @round(fs * 2.8);
        const pos = c.igGetCursorScreenPos();
        const w = c.igGetContentRegionAvail().x;
        _ = c.igSelectable_Bool("##netrow", false, c.ImGuiSelectableFlags_AllowOverlap, cimgui.vec2(w, row_h));
        const dbl = c.igIsItemHovered(0) and c.igIsMouseDoubleClicked_Nil(0);
        c.igOpenPopupOnItemClick("##netmenu", c.ImGuiPopupFlags_MouseButtonRight); // (a row's menu, if its caller has one)
        const dl = c.igGetWindowDrawList();
        const ih = @round(fs * 1.6);
        drawSideIcon(dl, .network, pos.x + fs * 0.4, pos.y + (row_h - ih) * 0.5, ih, c.igGetColorU32_Vec4(if (on) theme.p().accent else theme.dim()));
        const tx = pos.x + fs * 0.4 + ih + fs * 0.6;
        const lh = c.igGetTextLineHeight();
        c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(tx, pos.y + row_h * 0.5 - lh), c.igGetColorU32_Vec4(theme.text()), name.ptr, name.ptr + name.len);
        c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(tx, pos.y + row_h * 0.5), c.igGetColorU32_Vec4(theme.dim()), detail.ptr, detail.ptr + detail.len);
        const bw = c.igCalcTextSize(action.ptr, null, false, -1).x + c.igGetStyle().*.FramePadding.x * 2;
        c.igSetCursorScreenPos(cimgui.vec2(pos.x + w - bw - fs * 0.4, pos.y + (row_h - c.igGetFrameHeight()) * 0.5));
        const clicked = c.igButton(action.ptr, cimgui.vec2(0, 0));
        // Back under the row, then an (empty) item: a window can't end on a moved cursor.
        c.igSetCursorScreenPos(cimgui.vec2(pos.x, pos.y + row_h));
        c.igDummy(cimgui.vec2(0, 0));
        return clicked or dbl;
    }

    /// prefillConnect opens Connect to Server filled in for a server the Network page
    /// found: its type, a name for it, and how to reach it.
    fn prefillConnect(self: *Shell, sv: core.netbrowse.Server) void {
        // A remote's name: the server's, with what rclone doesn't allow made dashes.
        var nb: [64]u8 = undefined;
        var n: usize = 0;
        for (sv.name) |ch| {
            if (n + 1 >= nb.len) break;
            const ok = std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_-.+@ ", ch) != null;
            nb[n] = if (ok) ch else '-';
            n += 1;
        }
        const name = std.mem.trim(u8, nb[0..n], " -");
        const v6 = std.mem.indexOfScalar(u8, sv.host, ':') != null;
        var hb: [300]u8 = undefined;
        var pb: [8]u8 = undefined;
        const default_port: u16 = switch (sv.kind) {
            .sftp => 22,
            .smb => 445,
            .ftp => 21,
            .webdav => sv.port,
        };
        const port = if (sv.port == default_port) "" else (std.mem.print(&pb, "{d}", .{sv.port}) catch "");
        if (sv.kind == .webdav) {
            const url = std.mem.print(&hb, "{s}://{s}{s}{s}:{d}/", .{ if (sv.secure) "https" else "http", if (v6) "[" else "", sv.host, if (v6) "]" else "", sv.port }) catch sv.host;
            self.connect.open(.{ .typ = "webdav", .name = name, .values = &.{ .{ "url", url }, .{ "vendor", "other" } } });
        } else {
            self.connect.open(.{ .typ = @tagName(sv.kind), .name = name, .values = &.{ .{ "host", sv.host }, .{ "port", port } } });
        }
    }

    /// remoteRow is one rclone remote in the sidebar.
    fn remoteRow(self: *Shell, b: *Browser, r: core.devices.Devices.RemoteView, i: usize) void {
        const d = self.devices orelse return;
        const busy_r = d.isBusy(r.name) or d.isBusy(r.mountpoint);
        var lb: [200]u8 = undefined;
        const label = std.mem.printSentinel(&lb, "{s}{s}##rem{d}", .{ r.name, if (busy_r) " \u{2026}" else "", i }, 0) catch return;
        const icon: SideIcon = if (core.rclone.isServerType(r.kind)) .network else .cloud;
        const clicked = sideItem(label, r.mounted and std.mem.eql(u8, b.dir, r.mountpoint), icon, !r.mounted);
        if (clicked and r.mounted) b.navigate(r.mountpoint) catch {};
        // Not connected: a click offers to connect, as its menu.
        if (!r.mounted) c.igOpenPopupOnItemClick(null, c.ImGuiPopupFlags_MouseButtonLeft);
        if (r.mounted) {
            if (c.igIsItemClicked(c.ImGuiMouseButton_Middle)) self.newTabAt(r.mountpoint);
            self.dropZone(r.mountpoint);
        }
        if (c.igBeginItemTooltip()) {
            var tb: [400]u8 = undefined;
            cimgui.textUnformatted(std.mem.print(&tb, "{s} ({s} via rclone)\n{s}", .{
                r.name, r.kind, if (r.mounted) r.mountpoint else "Not connected. Click to connect",
            }) catch r.name);
            c.igEndTooltip();
        }
        if (c.igBeginPopupContextItem(null, c.ImGuiPopupFlags_MouseButtonRight)) {
            defer c.igEndPopup();
            self.remoteMenu(b, r);
        }
    }

    /// drawConnectModal is Connect to Server (connect.zig); a location it finished
    /// setting up is mounted and opened.
    fn drawConnectModal(self: *Shell) void {
        const done = self.connect.draw() orelse return;
        const d = self.devices orelse return;
        const name = done.name[0..done.len];
        if (!done.edited) return d.mountRemote(name, true);
        // Edited: a connected one reconnects with its new settings (and a tab that
        // was in it opens it again).
        for (self.remotes) |r| if (std.mem.eql(u8, r.name, name) and r.mounted) {
            var inside = false;
            for (self.liveBrowsers()) |t| if (isUnder(t.dir, r.mountpoint)) {
                inside = true;
                t.navigate(self.home) catch {};
            };
            d.unmountRemote(r.mountpoint);
            d.mountRemote(name, inside);
        };
    }

    /// volumeAt reports whether a block volume row already shows `mountpoint`, so the
    /// plain /proc/mounts rows don't list the same stick twice.
    fn volumeAt(self: *Shell, mountpoint: []const u8) bool {
        for (self.vols) |v| {
            if (std.mem.eql(u8, v.mountpoint, mountpoint)) return true;
        }
        return false;
    }

    /// parseDialogFilters turns the chooser's raw "Name|*.png *.jpg" specs into owned
    /// FileFilters and picks the initial selection (dlg_filter_idx). Best-effort: specs
    /// that don't parse are skipped.
    fn parseDialogFilters(self: *Shell, cfg: PickConfig) void {
        if (cfg.filters.len == 0) return;
        var list = std.ArrayList(core.filter.FileFilter).empty;
        for (cfg.filters) |spec| {
            const f = core.filter.parseFilterSpec(self.alloc, spec) catch continue orelse continue;
            list.append(self.alloc, f) catch {
                f.deinit(self.alloc);
                continue;
            };
        }
        self.dlg_filters = list.toOwnedSlice(self.alloc) catch &.{};
        // Default: current_filter by name, else the first filter, else "All files".
        self.dlg_filter_idx = if (self.dlg_filters.len > 0) 1 else 0;
        if (cfg.current_filter.len > 0) {
            for (self.dlg_filters, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, cfg.current_filter)) {
                    self.dlg_filter_idx = i + 1;
                    break;
                }
            }
        }
    }

    /// gatherSettings snapshots the current UI state for persistence on exit.
    pub fn gatherSettings(self: *Shell, win: ?*c.GLFWwindow) core.config.Settings {
        const b = self.activeBrowser();
        // The view keys hold the DEFAULT view; folders with their own live in the
        // folders file, written here too since this runs on the way out.
        if (self.prefs_path.len > 0) self.prefs.save(self.io, self.prefs_path);
        const dv = self.prefs.default;
        var s = core.config.Settings{
            .show_hidden = dv.show_hidden,
            .dirs_first = dv.sort.dirs_first,
            .search_ci = b.search_ci,
            .reopen_last = self.reopen_last,
            .dpi = self.dpi_enabled,
            .font_nearest = self.font_nearest,
            .reduce_motion = self.reduce_motion,
            .zoom = self.zoom,
            .sort_column = @backingInt(dv.sort.column),
            .sort_ascending = dv.sort.ascending,
            .view_mode = @backingInt(dv.mode),
            .group_by = @backingInt(dv.group),
            .sidebar_w = self.sidebar_w,
            .theme = @backingInt(self.theme_mode),
            .menu_bar = self.menu_bar,
            .archive_browse = self.archive_browse,
            .notify_devices = self.notify_devices,
            .pdf_snap = pdfview.snap_pages,
            .pdf_sidebar = pdfview.sidebar_shown,
            .sidebar_hide = self.sidebar_hide,
            .tags_hide = self.tags_hide,
            .preview_pane = self.show_preview,
            .bars_hide = self.bars_hide,
            .folder_sizes = self.folder_sizes,
            .icon_scale = self.actions.icon_scale,
            .list_scale = self.actions.list_scale,
            .columns_scale = self.actions.columns_scale,
            .gallery_scale = self.actions.gallery_scale,
            .grid_spacing = self.actions.grid_spacing,
            .label_right = self.actions.label_right,
            .item_info = self.actions.item_info,
            .icon_preview = self.actions.icon_preview,
            .text_scale = self.actions.text_scale,
            .thumb_workers = @intCast(self.thumb_workers),
        };
        s.setLastDir(b.location());
        {
            // The toolbar's items, by name ("" while it's the default).
            var tb: [256]u8 = undefined;
            var n: usize = 0;
            const items = self.toolbar_items[0..self.toolbar_len];
            if (!std.mem.eql(ToolItem, items, &default_toolbar)) for (items, 0..) |it, i| {
                const w = std.mem.print(tb[n..], "{s}{s}", .{ if (i > 0) "," else "", @tagName(it) }) catch break;
                n += w.len;
            };
            s.setToolbar(tb[0..n]);
        }
        if (win) |w| {
            if (c.glfwGetWindowAttrib(w, c.GLFW_MAXIMIZED) == 0) {
                var ww: c_int = 0;
                var wh: c_int = 0;
                c.glfwGetWindowSize(w, &ww, &wh);
                if (ww > 0 and wh > 0) {
                    s.win_w = ww;
                    s.win_h = wh;
                }
            }
        }
        return s;
    }

    /// orphanScanners detaches every tab's scan worker so process-exit teardown never
    /// blocks on an in-flight slow directory read (the "pressing Save mid-load freezes"
    /// case). Call once, right before deinit, on the way out of the render loop.
    pub fn orphanScanners(self: *Shell) void {
        for (self.opBrowsers()) |b| b.orphan();
    }

    pub fn deinit(self: *Shell) void {
        self.connect.deinit();
        if (self.bg) |g| g.destroy(); // (writes what's still queued first)
        self.bm_probe.deinit(self.alloc);
        for (self.drop_probe.items) |p| self.alloc.free(p);
        self.drop_probe.deinit(self.alloc);
        if (self.ffmpeg_path) |p| self.alloc.free(p);
        if (self.ffprobe_path) |p| self.alloc.free(p);
        if (self.actions.probe) |pr| pr.release();
        self.actions.freeBatch(self.alloc);
        self.actions.br_olds.deinit(self.alloc);
        self.actions.br_all.deinit(self.alloc);
        if (self.devices) |d| d.destroy();
        core.blockdev.free(self.alloc, self.vols);
        core.mimeinfo.deinit();
        core.fstab.free(self.alloc, self.fstab_entries);
        core.devices.Devices.freeRemoteViews(self.alloc, self.remotes);
        if (self.net_base.len > 0) self.alloc.free(self.net_base);
        if (self.known_vols) |*k| {
            for (k.items) |p| self.alloc.free(p);
            k.deinit(self.alloc);
        }
        if (self.notifier) |n| n.release();
        self.preview.deinit(self.alloc);
        self.gallery_ql.deinit(self.alloc);
        if (self.actions.thumbs) |t| t.destroy();
        if (self.actions.dir_sizes) |d| d.destroy();
        if (self.procwatch) |pw| pw.destroy();
        if (self.actions.dirs) |d| d.destroy();
        for (self.tabs.items) |b| b.deinit();
        self.tabs.deinit(self.alloc);
        self.freeDyingTabs();
        self.dying_tabs.deinit(self.alloc);
        for (self.finishing_tabs.items) |b| b.deinit(); // (quitting: their operations stop)
        self.finishing_tabs.deinit(self.alloc);
        if (self.split_b) |sb| sb.deinit();
        self.clipboard.deinit(self.alloc);
        self.alloc.destroy(self.clipboard);
        for (self.closed_tabs.items) |p| self.alloc.free(p);
        self.closed_tabs.deinit(self.alloc);
        if (self.mounts.len > 0) mounts_mod.free(self.alloc, self.mounts);
        if (self.net_mounts.len > 0) mounts_mod.free(self.alloc, self.net_mounts);
        if (self.places.len > 0) mounts_mod.free(self.alloc, self.places);
        for (self.bookmarks.items) |bm| bm.deinit(self.alloc);
        self.bookmarks.deinit(self.alloc);
        self.bm_dead.deinit(self.alloc);
        for (self.dlg_filters) |f| f.deinit(self.alloc);
        if (self.dlg_filters.len > 0) self.alloc.free(self.dlg_filters);
        if (self.bm_path.len > 0) self.alloc.free(self.bm_path);
        for (self.recent_folders.items) |p| self.alloc.free(p);
        self.recent_folders.deinit(self.alloc);
        if (self.rf_path.len > 0) self.alloc.free(self.rf_path);
        if (self.tags_path.len > 0) self.alloc.free(self.tags_path);
        if (self.prefs_path.len > 0) self.alloc.free(self.prefs_path);
        self.qlStopBrowsing();
        self.prefs.deinit();
        self.alloc.destroy(self.prefs);
        if (self.temp_files) |t| {
            t.deinit(); // removes the files taken out of archives
            self.alloc.destroy(t);
        }
        if (self.trash_items.len > 0) core.trash.free(self.alloc, self.trash_items);
    }

    /// mountpoints collects the external mountpoints (borrowed from self.mounts) that
    /// the trash sweep checks for per-filesystem `.Trash-$uid` cans. Caller frees the
    /// returned slice (the strings stay owned by self.mounts).
    fn mountpoints(self: *Shell) []const []const u8 {
        var mps = std.ArrayList([]const u8).empty;
        for (self.mounts) |m| mps.append(self.alloc, m.mountpoint) catch {};
        return mps.toOwnedSlice(self.alloc) catch &.{};
    }

    /// refreshTrash re-lists the trash (off the render thread; pollBg takes it).
    fn refreshTrash(self: *Shell) void {
        self.trashDo(.list, null);
    }

    /// trashDo has the background worker do `action` in the trash, then list it.
    fn trashDo(self: *Shell, action: core.bgio.TrashAction, item: ?core.trash.Item) void {
        const mps = self.mountpoints();
        defer self.alloc.free(mps);
        if (self.bg) |g| g.trashJob(action, self.trash_home, mps, item);
    }

    fn openTrash(self: *Shell) void {
        self.show_trash = true;
        self.refreshTrash();
    }

    /// drawTrashView is the "Open trashcan" window: list trashed items with their
    /// original location, and Restore / Delete each, or Empty Trash.
    fn drawTrashView(self: *Shell) void {
        if (!self.show_trash) return self.trash_win.hide();
        var open = true;
        if (self.trash_win.begin(.{ .name = "Trash##trashview", .preferred = .{ 640, 420 } }, &open)) {
            if (c.igButton("Empty Trash", cimgui.vec2(0, 0))) self.trashDo(.empty, null);
            c.igSameLine(0, -1);
            if (c.igButton("Refresh", cimgui.vec2(0, 0))) self.refreshTrash();
            c.igSeparator();

            if (self.trash_items.len == 0) {
                cimgui.textUnformatted("Trash is empty.");
            } else if (c.igBeginTable("##trashtbl", 4, c.ImGuiTableFlags_RowBg | c.ImGuiTableFlags_ScrollY | c.ImGuiTableFlags_BordersInnerV | c.ImGuiTableFlags_Resizable | c.ImGuiTableFlags_Sortable, cimgui.vec2(0, 0), 0)) {
                c.igTableSetupColumn("Name", c.ImGuiTableColumnFlags_WidthStretch, 0, 0);
                c.igTableSetupColumn("Original location", c.ImGuiTableColumnFlags_WidthStretch, 0, 1);
                // Newest trashed first, as Finder's Trash opens.
                c.igTableSetupColumn("Date Trashed", c.ImGuiTableColumnFlags_WidthFixed | c.ImGuiTableColumnFlags_DefaultSort | c.ImGuiTableColumnFlags_PreferSortDescending, @round(c.igGetFontSize() * 9), 2);
                c.igTableSetupColumn("", c.ImGuiTableColumnFlags_WidthFixed | c.ImGuiTableColumnFlags_NoSort, 150, 3);
                c.igTableSetupScrollFreeze(0, 1);
                c.igTableHeadersRow();
                if (c.igTableGetSortSpecs()) |specs| if (specs.*.SpecsDirty or !self.trash_sorted) {
                    if (specs.*.SpecsCount > 0) sortTrash(self.trash_items, @intCast(specs.*.Specs[0].ColumnUserID), specs.*.Specs[0].SortDirection == c.ImGuiSortDirection_Descending);
                    specs.*.SpecsDirty = false;
                    self.trash_sorted = true;
                };
                const now = table.nowSecs();

                var do_restore: ?usize = null;
                var do_remove: ?usize = null;
                for (self.trash_items, 0..) |item, i| {
                    c.igTableNextRow(0, 0);
                    _ = c.igTableSetColumnIndex(0);
                    cimgui.textUnformatted(item.name);
                    _ = c.igTableSetColumnIndex(1);
                    cimgui.textUnformatted(item.orig_path);
                    _ = c.igTableSetColumnIndex(2);
                    var tb: [32]u8 = undefined;
                    cimgui.textUnformatted(if (item.deleted > 0) core.scan.formatDateFriendly(&tb, item.deleted, now) else "--");
                    _ = c.igTableSetColumnIndex(3);
                    var rbuf: [24]u8 = undefined;
                    const rid = std.mem.printSentinel(&rbuf, "Restore##{d}", .{i}, 0) catch continue;
                    if (c.igSmallButton(rid.ptr)) do_restore = i;
                    c.igSameLine(0, -1);
                    var dbuf: [24]u8 = undefined;
                    const did = std.mem.printSentinel(&dbuf, "Delete##{d}", .{i}, 0) catch continue;
                    if (c.igSmallButton(did.ptr)) do_remove = i;
                }
                c.igEndTable();

                if (do_restore) |i| {
                    self.trashDo(.restore, self.trash_items[i]);
                } else if (do_remove) |i| {
                    self.trashDo(.remove, self.trash_items[i]);
                }
            }
        }
        self.trash_win.end();
        if (!open) self.show_trash = false;
    }

    /// loadTags reads your tag list (names and colours); none yet = the seven colours.
    fn loadTags(self: *Shell) void {
        if (self.tags_path.len == 0) return;
        const content = std.Io.Dir.cwd().readFileAlloc(self.io, self.tags_path, self.alloc, .limited(1 << 14)) catch return;
        defer self.alloc.free(content);
        core.tags.parseTable(content);
    }

    fn saveTags(self: *Shell) void {
        if (self.tags_path.len == 0) return;
        const text = core.tags.formatTable(self.alloc) catch return;
        defer self.alloc.free(text);
        self.writeConfig(self.tags_path, text);
        for (self.liveBrowsers()) |t| t.refresh(); // re-read which tags each file has
    }

    fn loadBookmarks(self: *Shell) void {
        if (self.bm_path.len == 0) return;
        const content = std.Io.Dir.cwd().readFileAlloc(self.io, self.bm_path, self.alloc, .limited(1 << 16)) catch return;
        defer self.alloc.free(content);
        self.bookmarks = core.bookmarks.parseFile(self.alloc, content) catch .empty;
    }

    fn saveBookmarks(self: *Shell) void {
        if (self.bm_path.len == 0) return;
        const text = core.bookmarks.format(self.alloc, self.bookmarks.items) catch return;
        defer self.alloc.free(text);
        self.writeConfig(self.bm_path, text);
    }

    /// addBookmark bookmarks folder `path`, remembering what it is: a folder on an
    /// rclone remote or on a removable volume is stored by remote name / volume UUID,
    /// so the bookmark still works when that isn't connected (it connects first).
    fn addBookmark(self: *Shell, path: []const u8) void {
        const a = self.alloc;
        var label: []const u8 = std.fs.path.basename(path);
        if (self.remoteFor(path)) |hit| {
            if (hit.sub.len == 0) label = hit.r.name;
        } else if (self.volumeFor(path)) |hit| {
            if (hit.sub.len == 0) label = hit.v.name;
        }
        const loc = self.locFor(path) orelse return;
        for (self.bookmarks.items) |bm| {
            if (std.mem.eql(u8, bm.loc, loc)) return a.free(loc); // already bookmarked
        }
        const l = a.dupe(u8, if (label.len > 0) label else path) catch return a.free(loc);
        self.bookmarks.append(a, .{ .loc = loc, .label = l }) catch {
            a.free(loc);
            a.free(l);
            return;
        };
        self.saveBookmarks();
    }

    /// locFor is how a bookmark remembers folder `path` (owned): by remote name or
    /// volume UUID when it's on one, else the path itself.
    fn locFor(self: *Shell, path: []const u8) ?[]u8 {
        if (self.remoteFor(path)) |hit| return core.bookmarks.remoteLoc(self.alloc, hit.r.name, hit.sub) catch null;
        if (self.volumeFor(path)) |hit| return core.bookmarks.deviceLoc(self.alloc, hit.v.uuid, hit.sub) catch null;
        return self.alloc.dupe(u8, path) catch null;
    }

    const RemoteHit = struct { r: core.devices.Devices.RemoteView, sub: []const u8 };
    const VolumeHit = struct { v: core.blockdev.Volume, sub: []const u8 };

    /// remoteFor finds the mounted rclone remote holding `path`, with the rest of it.
    fn remoteFor(self: *Shell, path: []const u8) ?RemoteHit {
        for (self.remotes) |r| {
            if (!r.mounted or !isUnder(path, r.mountpoint)) continue;
            return .{ .r = r, .sub = std.mem.trimStart(u8, path[r.mountpoint.len..], "/") };
        }
        return null;
    }

    /// volumeFor finds the removable volume (with a UUID) holding `path`.
    fn volumeFor(self: *Shell, path: []const u8) ?VolumeHit {
        for (self.vols) |v| {
            if (!v.removable or v.uuid.len == 0 or !v.mounted() or !isUnder(path, v.mountpoint)) continue;
            return .{ .v = v, .sub = std.mem.trimStart(u8, path[v.mountpoint.len..], "/") };
        }
        return null;
    }

    /// bookmarkPath is where bookmark `bm` is right now, or null if it first has to be
    /// connected/mounted (or its device isn't plugged in).
    fn bookmarkPath(self: *Shell, buf: []u8, bm: core.bookmarks.Bookmark) ?[]const u8 {
        switch (bm.target()) {
            .path => |p| return p,
            .remote => |t| for (self.remotes) |r| {
                if (!std.mem.eql(u8, r.name, t.name)) continue;
                if (!r.mounted) return null;
                return joinSub(buf, r.mountpoint, t.sub);
            },
            .device => |t| for (self.vols) |v| {
                if (!std.mem.eql(u8, v.uuid, t.uuid)) continue;
                if (!v.mounted()) return null;
                return joinSub(buf, v.mountpoint, t.sub);
            },
            .search => return null, // not a place: openBookmark runs it
        }
        return null;
    }

    /// bookmarkAvailable: false when the bookmark's device isn't plugged in or its
    /// remote no longer exists in rclone's config (drawn dimmed).
    fn bookmarkAvailable(self: *Shell, bm: core.bookmarks.Bookmark) bool {
        switch (bm.target()) {
            .path => return true,
            .remote => |t| {
                for (self.remotes) |r| if (std.mem.eql(u8, r.name, t.name)) return true;
                return false;
            },
            .device => |t| {
                for (self.vols) |v| if (std.mem.eql(u8, v.uuid, t.uuid)) return true;
                return false;
            },
            .search => return true,
        }
    }

    /// checkBookmarks works out, every few seconds, which favourites point at a folder
    /// that's gone. Only plain local paths are looked at: one on a network share or an
    /// fstab mount could hang the window if its server is away, and one on a device
    /// or remote that isn't mounted yet isn't gone (clicking mounts it).
    fn checkBookmarks(self: *Shell) void {
        const now = c.igGetTime();
        const n = self.bookmarks.items.len;
        if (self.bm_dead.items.len != n) {
            const old = self.bm_dead.items.len;
            self.bm_dead.resize(self.alloc, n) catch return;
            if (n > old) @memset(self.bm_dead.items[old..], false);
        }
        if (now - self.bm_checked < 3) return;
        self.bm_checked = now;
        const g = self.bg orelse return;
        // Ask the background worker; the answer marks them (pollBg).
        self.bm_probe.clearRetainingCapacity();
        var paths = std.ArrayList([]const u8).empty;
        defer paths.deinit(self.alloc);
        for (self.bookmarks.items, 0..) |bm, i| {
            if (bm.target() != .path) continue;
            const p = bm.target().path;
            if (self.onMountedShare(p)) continue;
            self.bm_probe.append(self.alloc, i) catch return;
            paths.append(self.alloc, p) catch return;
        }
        self.bm_probe_n = n;
        g.probe(bg_favourites, paths.items);
    }

    /// writeConfig saves one of zfd's config files, off the render thread.
    fn writeConfig(self: *Shell, path: []const u8, data: []const u8) void {
        if (path.len == 0) return;
        if (self.bg) |g| return g.write(path, data);
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data }) catch {};
    }

    /// pollBg takes the background worker's answers (once per frame).
    fn pollBg(self: *Shell) void {
        const g = self.bg orelse return;
        while (g.take()) |a| {
            if (a == .trash) {
                // The trash's new contents replace the old.
                if (self.trash_items.len > 0) core.trash.free(self.alloc, self.trash_items);
                self.trash_items = a.trash;
                self.trash_sorted = false;
                continue;
            }
            defer a.deinit(self.alloc);
            switch (a) {
                .probe => |p| switch (p.id) {
                    bg_favourites => if (self.bm_probe_n == self.bookmarks.items.len and self.bm_dead.items.len == self.bm_probe_n) {
                        for (self.bm_probe.items, p.kinds) |i, k| self.bm_dead.items[i] = k != .dir;
                    },
                    bg_edit => self.edit_probe_ok = p.kinds.len == 1 and p.kinds[0] == .dir,
                    bg_add_favourites => for (self.drop_probe.items, p.kinds) |dp, k| {
                        if (k == .dir) self.addBookmark(dp);
                    },
                    bg_point => if (p.kinds.len == 1 and p.kinds[0] != .missing) self.pointAtKind(std.mem.sliceTo(&self.point_path, 0), p.kinds[0] == .dir),
                    else => {},
                },
                .changed => |ch| if (ch.id == bg_folder_views) {
                    self.prefs_mtime = ch.mtime;
                    self.prefs.reloadFrom(ch.data);
                },
                .trash => {}, // (taken above)
            }
        }
        // A favourite that wasn't there: say where it landed instead.
        const b = self.activeBrowser();
        if (b.takeClimbed()) |p| {
            self.alloc.free(p);
            self.setBmMsg("\u{201C}{s}\u{201D} is gone; this is the folder above it. Right-click it to edit.", .{std.mem.sliceTo(&self.climb_label, 0)});
            self.bm_checked = -100;
        }
    }

    /// onMountedShare: `path` is on a network share, an rclone remote or an fstab
    /// mount: somewhere a stat might wait on a server.
    fn onMountedShare(self: *Shell, path: []const u8) bool {
        for (self.net_mounts) |m| if (isUnder(path, m.mountpoint)) return true;
        for (self.remotes) |r| if (r.mountpoint.len > 0 and isUnder(path, r.mountpoint)) return true;
        for (self.fstab_entries) |e| if (isUnder(path, e.target)) return true;
        return false;
    }

    fn bookmarkDead(self: *Shell, i: usize) bool {
        return i < self.bm_dead.items.len and self.bm_dead.items[i];
    }

    fn setBmMsg(self: *Shell, comptime fmt: []const u8, args: anytype) void {
        const msg: []const u8 = std.mem.print(&self.bm_msg, fmt, args) catch "";
        self.bm_msg_len = msg.len;
    }

    /// openBookmark goes to `bm`, connecting or mounting what it lives on first.
    fn openBookmark(self: *Shell, b: *Browser, bm: core.bookmarks.Bookmark) void {
        // A saved search: go to its folder and run it again.
        if (bm.target() == .search) {
            const t = bm.target().search;
            b.navigate(t.dir) catch return;
            b.setSearch(t.query);
            if (t.deep) b.setDeep(true);
            return;
        }
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (self.bookmarkPath(&buf, bm)) |p| {
            // A plain path on an fstab mount that isn't mounted (the list holds only
            // those): mount it, then open.
            if (bm.target() == .path) for (self.fstab_entries) |e| {
                if (!isUnder(p, e.target)) continue;
                const d = self.devices orelse break;
                self.setAfterMount(e.target, std.mem.trimStart(u8, p[e.target.len..], "/"));
                d.mountTarget(e.target, e.user_mountable, true);
                return;
            };
            // Gone (moved, renamed, deleted)? Then the nearest folder above it that's
            // still there, found by loading as usual, and a note says so (pollBg).
            self.bm_msg_len = 0;
            setField(&self.climb_label, bm.displayName());
            b.navigateOrClimb(p) catch {};
            return;
        }
        const d = self.devices orelse return;
        switch (bm.target()) {
            .path => {},
            .remote => |t| {
                self.setAfterMount(t.name, t.sub);
                d.mountRemote(t.name, true);
            },
            .device => |t| {
                for (self.vols) |v| {
                    if (!std.mem.eql(u8, v.uuid, t.uuid)) continue;
                    self.setAfterMount(v.path, t.sub);
                    if (v.locked) self.askUnlock(v) else d.mount(v.path, true);
                    return;
                }
                self.showDevMsg("That device isn't connected.");
            },
            .search => {},
        }
    }

    fn setAfterMount(self: *Shell, key: []const u8, sub: []const u8) void {
        if (key.len > self.after_mount_key.len or sub.len > self.after_mount_sub.len) return;
        @memcpy(self.after_mount_key[0..key.len], key);
        self.after_mount_key_len = key.len;
        @memcpy(self.after_mount_sub[0..sub.len], sub);
        self.after_mount_sub_len = sub.len;
    }

    fn showDevMsg(self: *Shell, msg: []const u8) void {
        const n = @min(msg.len, self.dev_msg.len);
        @memcpy(self.dev_msg[0..n], msg[0..n]);
        self.dev_msg_len = n;
    }

    fn moveBookmark(self: *Shell, from: usize, to: usize) void {
        const n = self.bookmarks.items.len;
        if (from >= n or to >= n or from == to) return;
        const item = self.bookmarks.orderedRemove(from);
        self.bookmarks.insert(self.alloc, to, item) catch {
            self.bookmarks.append(self.alloc, item) catch item.deinit(self.alloc);
        };
        self.bm_checked = -100;
        self.saveBookmarks();
    }

    fn removeBookmark(self: *Shell, index: usize) void {
        if (index >= self.bookmarks.items.len) return;
        self.bookmarks.orderedRemove(index).deinit(self.alloc);
        self.bm_checked = -100;
        self.bm_msg_len = 0;
        self.saveBookmarks();
    }

    /// editBookmark opens the Edit Favourite dialog for bookmark `index`.
    fn editBookmark(self: *Shell, index: usize) void {
        if (index >= self.bookmarks.items.len) return;
        const bm = self.bookmarks.items[index];
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const loc = if (bm.target() == .search) bm.loc else self.bookmarkPath(&pbuf, bm) orelse bm.loc;
        setField(&self.bm_edit_name, bm.displayName());
        setField(&self.bm_edit_loc, loc);
        setField(&self.bm_edit_loc0, loc);
        self.bm_edit = index;
        self.bm_edit_pending = true;
    }

    /// drawEditBookmarkModal is Edit Favourite: its name, and the folder it opens
    /// (typed, or the folder on screen). A device or remote that isn't mounted shows
    /// its stored location; left as it is, that's kept.
    fn drawEditBookmarkModal(self: *Shell, b: *Browser) void {
        const title = "Edit Favourite";
        if (self.bm_edit_pending) {
            c.igOpenPopup_Str(title, 0);
            self.bm_edit_pending = false;
        }
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(cimgui.vec2(vp.*.WorkPos.x + vp.*.WorkSize.x * 0.5, vp.*.WorkPos.y + vp.*.WorkSize.y * 0.5), c.ImGuiCond_Appearing, cimgui.vec2(0.5, 0.5));
        if (!c.igBeginPopupModal(title, null, c.ImGuiWindowFlags_AlwaysAutoResize)) return;
        defer c.igEndPopup();
        const idx = self.bm_edit orelse {
            c.igCloseCurrentPopup();
            return;
        };
        if (idx >= self.bookmarks.items.len) {
            self.bm_edit = null;
            c.igCloseCurrentPopup();
            return;
        }
        const is_search = self.bookmarks.items[idx].target() == .search;
        const fs = c.igGetFontSize();
        const label_w = fs * 5;
        const field_w = fs * 24;
        theme.pushFields();
        formLabel("Name", label_w);
        if (c.igIsWindowAppearing()) c.igSetKeyboardFocusHere(0);
        c.igSetNextItemWidth(field_w);
        var enter = c.igInputText("##bmname", &self.bm_edit_name, self.bm_edit_name.len, c.ImGuiInputTextFlags_EnterReturnsTrue, null, null);
        const loc = std.mem.trim(u8, std.mem.sliceTo(&self.bm_edit_loc, 0), " ");
        const loc0 = std.mem.sliceTo(&self.bm_edit_loc0, 0);
        const changed = !std.mem.eql(u8, loc, loc0);
        var ok = true;
        if (!is_search) {
            formLabel("Folder", label_w);
            c.igSetNextItemWidth(field_w);
            if (c.igInputText("##bmloc", &self.bm_edit_loc, self.bm_edit_loc.len, c.ImGuiInputTextFlags_EnterReturnsTrue, null, null)) enter = true;
            c.igDummy(cimgui.vec2(label_w, 0));
            c.igSameLine(0, c.igGetStyle().*.ItemSpacing.x);
            if (c.igSmallButton("Use Current Folder")) setField(&self.bm_edit_loc, b.dir);
            // Checked only once you change it (it may be on a share that's away).
            if (changed) {
                // Asked in the background when the text changes; Save waits for the answer.
                if (!std.mem.eql(u8, loc, std.mem.sliceTo(&self.edit_probe, 0))) {
                    setField(&self.edit_probe, loc);
                    self.edit_probe_ok = null;
                    if (loc.len > 0 and loc[0] == '/') if (self.bg) |g| g.probe(bg_edit, &.{loc});
                }
                ok = loc.len > 0 and loc[0] == '/' and (self.edit_probe_ok orelse false);
                if (!ok and self.edit_probe_ok != null) {
                    c.igSameLine(0, -1);
                    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.err());
                    cimgui.textUnformatted("There's no folder there.");
                    c.igPopStyleColor(1);
                }
            }
        }
        theme.popFields();
        c.igSeparator();
        c.igBeginDisabled(!ok);
        const save = c.igButton("Save", cimgui.vec2(0, 0)) or (enter and ok);
        c.igEndDisabled();
        c.igSameLine(0, -1);
        const cancel = c.igButton("Cancel", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false);
        if (save) {
            const bm = &self.bookmarks.items[idx];
            if (!is_search and changed) if (self.locFor(loc)) |nl| {
                self.alloc.free(bm.loc);
                bm.loc = nl;
            };
            const name = std.mem.trim(u8, std.mem.sliceTo(&self.bm_edit_name, 0), " ");
            // An empty name falls back to the folder's own.
            if (self.alloc.dupe(u8, name)) |l| {
                self.alloc.free(bm.label);
                bm.label = l;
            } else |_| {}
            self.bm_checked = -100;
            self.bm_msg_len = 0;
            self.saveBookmarks();
        }
        if (save or cancel) {
            self.bm_edit = null;
            c.igCloseCurrentPopup();
        }
    }

    fn renameBookmark(self: *Shell, index: usize, label: []const u8) void {
        if (index >= self.bookmarks.items.len) return;
        const l = self.alloc.dupe(u8, label) catch return;
        const bm = &self.bookmarks.items[index];
        self.alloc.free(bm.label);
        bm.label = l;
        self.saveBookmarks();
    }

    /// goHomeSub opens the home folder's `sub` (Desktop, Documents, Downloads).
    fn goHomeSub(self: *Shell, b: *Browser, sub: []const u8) void {
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.mem.print(&pb, "{s}/{s}", .{ self.home, sub }) catch return;
        b.navigate(p) catch {};
    }

    const recent_folders_max = 12;

    /// noteRecentFolder puts the folder on screen at the top of Go ▸ Recent Folders once
    /// it has opened (not Recent or search results, nor one that failed to read).
    fn noteRecentFolder(self: *Shell) void {
        const b = self.activeBrowser();
        if (b.loading or b.err_name != null or b.virtualView() or b.insideArchive() != null) return;
        const dir = b.dir;
        if (std.mem.eql(u8, dir, self.rf_seen[0..self.rf_seen_len]) or dir.len > self.rf_seen.len) return;
        @memcpy(self.rf_seen[0..dir.len], dir);
        self.rf_seen_len = dir.len;
        for (self.recent_folders.items, 0..) |p, i| if (std.mem.eql(u8, p, dir)) {
            self.alloc.free(self.recent_folders.orderedRemove(i));
            break;
        };
        const dup = self.alloc.dupe(u8, dir) catch return;
        self.recent_folders.insert(self.alloc, 0, dup) catch return self.alloc.free(dup);
        while (self.recent_folders.items.len > recent_folders_max) self.alloc.free(self.recent_folders.pop().?);
        self.saveRecentFolders();
    }

    fn loadRecentFolders(self: *Shell) void {
        if (self.rf_path.len == 0) return;
        const content = std.Io.Dir.cwd().readFileAlloc(self.io, self.rf_path, self.alloc, .limited(1 << 16)) catch return;
        defer self.alloc.free(content);
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (line.len == 0 or line[0] != '/' or self.recent_folders.items.len >= recent_folders_max) continue;
            const dup = self.alloc.dupe(u8, line) catch continue;
            self.recent_folders.append(self.alloc, dup) catch self.alloc.free(dup);
        }
    }

    fn saveRecentFolders(self: *Shell) void {
        if (self.rf_path.len == 0) return;
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        for (self.recent_folders.items) |p| {
            out.appendSlice(self.alloc, p) catch return;
            out.append(self.alloc, '\n') catch return;
        }
        self.writeConfig(self.rf_path, out.items);
    }

    fn clearRecentFolders(self: *Shell) void {
        for (self.recent_folders.items) |p| self.alloc.free(p);
        self.recent_folders.clearRetainingCapacity();
        self.saveRecentFolders();
    }

    /// syncFolderViews writes folder views as soon as they change (a crash or another
    /// window mustn't lose them), and every couple of seconds picks up what other
    /// windows wrote. A reloaded view applies the next time a folder is opened.
    fn syncFolderViews(self: *Shell) void {
        if (self.prefs_path.len == 0) return;
        const now = c.igGetTime();
        const g = self.bg orelse return;
        if (self.prefs.dirty()) {
            if (self.prefs.takeChanges()) |ch| g.saveViews(self.prefs_path, ch) else |_| {}
            self.prefs_checked = now;
            return;
        }
        if (now - self.prefs_checked < 2) return;
        self.prefs_checked = now;
        g.ifChanged(bg_folder_views, self.prefs_path, self.prefs_mtime); // answered in pollBg
    }

    pub fn updateTabs(self: *Shell) void {
        // A finished file op can change folders OTHER tabs are showing (a cut pasted in
        // tab B empties tab A's folder, a drop onto a tab header fills that tab's), and
        // there's no inotify, so reload every tab that didn't just reload itself.
        self.syncFolderViews();
        self.pollBg();
        self.noteRecentFolder();
        self.reapFinishingTabs();
        const all = self.opBrowsers();
        var just_reloaded: [80]bool = @splat(false);
        var any = false;
        for (all, 0..) |b, i| {
            const seq = b.op_seq;
            b.wake = wakeUi; // the details pool nudges an idle loop when results come
            _ = b.update();
            if (b.op_seq != seq) {
                any = true;
                just_reloaded[i] = true;
            }
        }
        if (!any) return;
        for (all, 0..) |b, i| {
            if (just_reloaded[i]) continue;
            if (!b.loading) b.refresh();
        }
    }

    /// busy reports whether async work is streaming (so the loop should tick fast);
    /// when false the loop idles at a low frame rate to save CPU.
    pub fn busy(self: *Shell) bool {
        if (anim.running()) return true; // something is still moving
        if (x11.resizeSyncPending()) return true; // the WM waits on our next frame
        if (self.actions.thumbs) |t| if (t.busy()) return true;
        if (self.actions.dir_sizes) |d| if (d.busy()) return true;
        if (self.finishing_tabs.items.len > 0) return true; // their progress is shown
        for (self.liveBrowsers()) |b| {
            if (b.loading or b.opsBusy() or b.watchPending() or b.expandBusy() or b.detailsPending()) return true;
        }
        if (self.show_treemap and self.activeBrowser().usageScanning()) return true;
        return false;
    }

    /// liveBrowsers lists every browser that exists right now (drag payloads are only
    /// trusted if their source is among these).
    fn liveBrowsers(self: *Shell) []const *Browser {
        var n: usize = 0;
        for (self.tabs.items) |t| {
            if (n == self.live_buf.len - 1) break;
            self.live_buf[n] = t;
            n += 1;
        }
        if (self.split_b) |sb| {
            self.live_buf[n] = sb;
            n += 1;
        }
        return self.live_buf[0..n];
    }

    /// activeBrowser is the FOCUSED pane's browser: the current tab, or the split pane
    /// when that was clicked last. Everything that acts on "the current folder" uses it.
    pub fn activeBrowser(self: *Shell) *Browser {
        if (self.split_focus) if (self.split_b) |sb| return sb;
        return self.tabs.items[self.active];
    }

    /// tabBrowser is the current TAB's browser (the left pane), regardless of focus.
    fn tabBrowser(self: *Shell) *Browser {
        return self.tabs.items[self.active];
    }

    /// toggleSplit opens a second pane on the focused folder (focused, like Dolphin),
    /// or closes it.
    fn toggleSplit(self: *Shell) void {
        if (self.split_b) |sb| {
            self.letGoLater(sb);
            self.split_b = null;
            self.split_focus = false;
            self.split_view = .{ .table = .{} };
            return;
        }
        const src = self.activeBrowser();
        const nb = Browser.init(self.alloc, self.io, src.location(), self.trash_home, self.home) catch return;
        nb.shareClipboard(self.clipboard);
        nb.prefs = self.prefs;
        nb.temp_files = self.temp_files;
        nb.applyFolderView();
        nb.search_ci = src.search_ci;
        nb.archive_tool = core.archive.findTool(self.io, self.alloc);
        self.split_b = nb;
        self.split_focus = true;
    }

    pub fn draw(self: *Shell) void {
        self.freeDyingTabs();
        anim.reduce_motion = self.reduce_motion;
        // Appearance: re-apply when the choice or (for System) the desktop's changes.
        const want_dark = switch (self.theme_mode) {
            .light => false,
            .dark => true,
            .system => theme.watch.prefersDark() orelse true,
        };
        if (self.theme_dark == null or self.theme_dark.? != want_dark) {
            theme.apply(want_dark);
            self.theme_dark = want_dark;
        }
        // Grid thumbnails: started the first time any pane shows icons.
        for (self.liveBrowsers()) |t| {
            if (t.view_mode != .list and self.actions.thumbs == null)
                self.actions.thumbs = thumbs.Cache.create(self.io, self.alloc, self.thumb_workers) catch null;
            if (t.view_mode == .columns and self.actions.dirs == null)
                self.actions.dirs = dircache.DirCache.create(self.io, self.alloc) catch null;
        }
        if (self.actions.thumbs) |t| t.pump();
        // Folder sizes: measured only while shown; turning them off frees the worker.
        // Folder sizes (the list's) and item counts (the icon view's item info) both
        // come from it.
        const want_sizes = self.folder_sizes or self.actions.item_info;
        self.actions.folder_sizes = self.folder_sizes;
        if (want_sizes and self.actions.dir_sizes == null) {
            self.actions.dir_sizes = dirsizes.Cache.create(self.io, self.alloc) catch null;
        } else if (!want_sizes) if (self.actions.dir_sizes) |d| {
            d.destroy();
            self.actions.dir_sizes = null;
        };
        if (self.actions.dir_sizes) |d| d.pump();
        // Outside copies and downloads: watched in the browser, not in a file chooser.
        if (self.dialog == null and !self.info_mode and self.procwatch == null)
            self.procwatch = core.procwatch.ProcWatch.create(self.io, self.alloc) catch null;
        if (self.procwatch) |pw| {
            var partials = false;
            for (self.liveBrowsers()) |t| partials = partials or t.has_partials;
            pw.wantDownloads(partials);
        }
        self.actions.procwatch = self.procwatch;
        self.actions.gallery = &self.gallery_ql;
        // Settings > General: archives open as folders, or in their default app.
        for (self.liveBrowsers()) |t| t.temp_files = if (self.archive_browse) self.temp_files else null;
        if (self.actions.dirs) |d| d.pump();
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(vp.*.WorkPos, c.ImGuiCond_Always, cimgui.vec2(0, 0));
        c.igSetNextWindowSize(vp.*.WorkSize, c.ImGuiCond_Always);

        const win_flags: c_int = c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize |
            c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoBringToFrontOnFocus | c.ImGuiWindowFlags_NoNavFocus |
            c.ImGuiWindowFlags_NoSavedSettings |
            c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse; // the shell window itself never scrolls

        // Reset the WM-drag guard once the button is up. Use ImGui's state (which we
        // fix up with the injected release in startWm), NOT glfwGetMouseButton; that
        // stays stuck at PRESS after the WM grab, so the guard would never clear and
        // you'd have to click once before the next move.
        if (self.csd and !c.igIsMouseDown_Nil(0)) self.wm_active = false;
        // Same guard for drag-out (any window mode), but keyed on the PAYLOAD, not the
        // button: after a drag-out the injected release reaches ImGui one frame before
        // the payload elapses, so a button-keyed guard re-armed while the payload was
        // still live, and the pointer, now over the drop target, was "outside", so a
        // second drag-out fired straight into Discord with no button held.
        if (c.igGetDragDropPayload() == null) self.drag_active = false;

        // Edge to edge: the sidebar and the column beside it bring their own padding. A
        // borderless window gets rounded corners, except when it fills the screen.
        // ImGui keeps a viewport's own window square, so the shell draws its background
        // and edge itself (drawFrame) and the ImGui window stays clear.
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, cimgui.vec2(0, 0));
        c.igPushStyleVar_Float(c.ImGuiStyleVar_WindowBorderSize, 0);
        c.igPushStyleColor_Vec4(c.ImGuiCol_WindowBg, cimgui.vec4(0, 0, 0, 0));
        const shown = c.igBegin("##zfd", null, win_flags);
        c.igPopStyleColor(1);
        c.igPopStyleVar(2);
        if (shown) self.drawFrame();
        if (shown and self.finishing) {
            self.applyScale();
            self.drawFinishing();
            c.igEnd();
            return;
        }
        if (shown and self.info_mode) {
            self.applyScale();
            if (self.csd) self.drawResizeGrips();
            self.drawInfoWindow();
            c.igEnd();
            return;
        }
        if (shown) {
            self.applyScale();
            self.pollDevices();
            // The resize grips get the first look at a press: a top corner is also the
            // titlebar (which would start a move) and the window buttons.
            if (self.csd) self.drawResizeGrips();
            self.drawHelp();
            self.drawSettings();
            if (self.dialog == null) self.drawViewOptions();
            if (self.dialog == null) self.drawCustomizeToolbar();
            if (self.dialog == null) self.drawProgressWindow();
            self.drawTabGhost();
            self.handleFocusKeys(); // Ctrl+L / Ctrl+F, in the chooser too
            self.actions.tabs = self.dialog == null; // views offer "Open in New Tab" only with tabs
            self.actions.live = self.liveBrowsers();
            if (self.dialog == null) self.handleShellKeys();
            const b = self.activeBrowser();
            self.handleMouseNav(b); // mouse back/forward; works in the dialog too
            // Ctrl+scroll, in the dialog too; over Quick Look it zooms the picture instead.
            if (!(self.ql_open and self.ql_win.hovered)) self.handleItemSize(b);
            // Going anywhere (a place, a tab, the path bar) leaves the Network page.
            if (self.net_page and !std.mem.eql(u8, b.location(), self.net_page_loc[0..self.net_page_loc_len])) self.closeNetworkPage();

            // Finder's layout: the sidebar runs the window's full height on the left;
            // the menu bar, tabs, toolbar, files and path bar share the column beside it.
            // Finder's toolbar band: menu bar, tabs and toolbar on their own shade with a
            // hairline under, as tall as last frame's (body_top). Drawn on the shell
            // window, under the sidebar, so it reaches the sidebar's edge.
            if (self.body_top > 0) {
                const wp = c.igGetWindowPos();
                const right = wp.x + c.igGetWindowWidth();
                const line_y = wp.y + self.body_top - @round(c.igGetStyle().*.ItemSpacing.y * 0.5);
                const dl = c.igGetWindowDrawList();
                c.ImDrawList_AddRectFilled(dl, wp, cimgui.vec2(right, line_y), c.igGetColorU32_Vec4(theme.p().toolbar_bg), self.cornerRadius(), c.ImDrawFlags_RoundCornersTop);
                c.ImDrawList_AddLine(dl, cimgui.vec2(wp.x, line_y), cimgui.vec2(right, line_y), c.igGetColorU32_Vec4(theme.p().toolbar_line), 1);
            }
            self.drawSidebarColumn(b);
            const with_menu = self.dialog == null and self.menu_bar;
            _ = c.igBeginChild_Str("##column", cimgui.vec2(0, 0), c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse |
                (if (with_menu) c.ImGuiWindowFlags_MenuBar else 0));
            const column_top = c.igGetWindowPos().y;
            if (with_menu) self.drawMenuBar(b);
            if (self.dialog == null) {
                self.drawTitleRow(); // tabs + (CSD) window buttons
            } else if (self.csd) {
                self.drawDialogTitleRow(); // chooser: title + window buttons, no tabs
            }
            // A hidden toolbar still appears while you type a path (Ctrl+L) or search
            // (Ctrl+F), since those fields live in it.
            self.preparePath(b);
            const path_here = !self.showsBar(.path_bar) and self.path_edit;
            if (self.showsBar(.toolbar) or path_here or self.focus_search or self.search_active or self.search_buf[0] != 0)
                self.drawToolbar(b);
            // The whole band above the files moves the window, as Finder's toolbar does
            // (CSD): the menu bar, the tabs, the toolbar and the gaps between them.
            if (self.csd) {
                const wp = c.igGetWindowPos();
                self.dragZone(wp, cimgui.vec2(wp.x + c.igGetWindowWidth(), c.igGetCursorScreenPos().y));
            }
            if (self.search_buf[0] != 0 or b.deep) self.drawSearchScope(b);
            self.body_top = c.igGetCursorScreenPos().y - column_top; // where the sidebar's places start (next frame)
            self.drawLoadingBar(b, column_top + self.body_top - @round(c.igGetStyle().*.ItemSpacing.y * 0.5));

            // The file list only listens to the keyboard when no text field owns it:
            // the path bar, the search box, or (in a Save dialog) the Name field. Without
            // the Name check, typing a filename drives the list (type-ahead, Delete,
            // Enter-to-open, …). name_active is last frame's value (the Name field draws
            // in the footer, after the list), which is exactly the right gate.
            const name_typing = if (self.dialog) |*d| d.name_active else false;
            // A text field in another window (Settings, View Options, a dialog) typing
            // too: WantTextInput is on while any text field has the keyboard, except
            // the list's own rename box, which the views handle.
            const other_text = cimgui.zfd_want_text_input() and !self.content.isRenaming() and !self.split_view.isRenaming();
            var keyboard = !self.path_active and !self.search_active and !name_typing and !other_text;
            if (self.dialog) |*d| {
                // Validate the Save name once per frame: it disables the Save button, gates
                // the Enter shortcuts below, and (when the name is non-empty but bad)
                // reserves a footer row for the inline reason. null = fine (or not a Save
                // dialog). Computed here, before the Enter check and the footer reservation
                // both read it. name_hint is the *visible* case: an empty name still blocks
                // Save (reason set) but shows nothing, so opening with a blank name is quiet.
                const name_hint = blk: {
                    if (!d.cfg.save) break :blk false;
                    const nm = std.mem.trim(u8, std.mem.sliceTo(&d.name_buf, 0), " \t");
                    d.name_reason = core.fsops.invalidNameReason(nm);
                    break :blk nm.len > 0 and d.name_reason != null;
                };
                // In a Save dialog, Enter means "save here". When the file list (not the
                // Name field) owns the keyboard, Enter would otherwise open the
                // highlighted folder and descend, so intercept it and accept instead.
                // Navigate into folders with a double-click or the path bar (Ctrl+L).
                // Only with a valid name (name_reason == null also rejects empty).
                // An inline rename (New Folder, F2) draws in the file list *below* this
                // check, so name_typing doesn't cover it. Without this guard, pressing
                // Enter to commit the folder name would also accept the Save.
                const any_popup = c.igIsPopupOpen_Str(null, c.ImGuiPopupFlags_AnyPopup);
                if (d.cfg.save and keyboard and !any_popup and !self.content.isRenaming() and d.name_reason == null and
                    (c.igIsKeyPressed_Bool(c.ImGuiKey_Enter, false) or c.igIsKeyPressed_Bool(c.ImGuiKey_KeypadEnter, false)))
                {
                    self.requestSave(d);
                    keyboard = false; // don't also let the list open the folder this frame
                }
                // Choosing a folder: with nothing selected, Enter takes the one you're in
                // (as the button does); with a folder selected it still goes into it.
                if (d.cfg.directory and !d.cfg.save and keyboard and !any_popup and !self.content.isRenaming() and
                    b.sel.count() == 0 and b.err_name == null and
                    (c.igIsKeyPressed_Bool(c.ImGuiKey_Enter, false) or c.igIsKeyPressed_Bool(c.ImGuiKey_KeypadEnter, false)))
                {
                    d.done = true;
                    keyboard = false;
                }
                // Reserve a footer (file-type filter combo + Name/buttons, + a row for the
                // invalid-name hint when shown) below the sidebar+list; drawBody keeps that
                // many pixels free at the bottom.
                const base_rows: f32 = if (self.dlg_filters.len > 0) 2 else 1;
                const rows: f32 = if (name_hint) base_rows + 1 else base_rows;
                const footer_h = c.igGetFrameHeightWithSpacing() * rows + 8;
                self.drawBody(b, keyboard, footer_h + self.bottomBarHeight());
                self.drawBottomBar(b);
                drawFooter(self, d);
                self.drawOverwriteModal(d);
            } else {
                self.drawBody(b, keyboard, self.bottomBarHeight());
                self.drawBottomBar(b);
            }
            // A folder middle-clicked (or "Open in New Tab") in the file list.
            if (b.takeNewTabRequest()) |p| {
                defer self.alloc.free(p);
                self.newTabAt(p);
            }
            // Draw the shared view modals once, at shell scope, so OpenPopup and
            // BeginPopupModal share an ID scope no matter which view raised the menu.
            self.actions.drawModals(b);
            if (self.actions.takeInfoRequest()) |p| self.spawnInfo(p);
            self.drawUnlockModal();
            self.drawConnectModal();
            self.drawEditBookmarkModal(self.activeBrowser());
            self.drawEmptyTrashModal();
            self.drawRemoveRemoteModal();
            self.maybeDragOut(b);
            // Fallback: the table resolves an external drop against its folder rows; if
            // it wasn't the active view (e.g. the treemap), import into the current dir
            // so the drop is never silently dropped.
            if (b.pendingDropPos() != null) b.commitExternalDrop(b.dir);
            // Free the drag snapshot once ImGui's payload is gone. Deliberately AFTER the
            // body: EndDragDropTarget clears the payload the instant a target accepts, so
            // on the delivery frame the payload is already null here, by which point every
            // drop zone has run and consumed the snapshot it needed. An abandoned drag
            // (released over nothing, or Escape) lands here the same way.
            if (c.igGetDragDropPayload() == null) {
                for (self.liveBrowsers()) |t| t.endDrag();
            }
            c.igEndChild(); // ##column
        }
        c.igEnd();
        if (!c.igIsMouseDown_Nil(0)) self.grip_press = false; // after the release frame's clicks

        self.drawTrashView();
        self.updatePreview();
        self.drawQuickLook();
        self.actions.pop.draw(); // a folder opening, over everything
    }

    /// applyScale applies DPI and zoom. Live: re-scales the style by the delta whenever
    /// the effective scale changes (the Settings checkbox, or the first frame).
    /// ScaleAllSizes is multiplicative, so what's already baked in is divided out.
    fn applyScale(self: *Shell) void {
        const target_scale = if (self.dpi_enabled) self.dpi_scale else 1.0;
        if (target_scale != self.style_scale) {
            c.ImGuiStyle_ScaleAllSizes(c.igGetStyle(), target_scale / self.style_scale);
            self.style_scale = target_scale;
        }
        cimgui.zfd_set_font_scale(self.zoom * target_scale);
        self.applyMinSize();
    }

    /// applyMinSize keeps the window from shrinking past what its layout fits: the
    /// sidebar beside a toolbar's worth of room (a Get Info window, a narrow column).
    /// In ems, so it follows the zoom and the screen's scale.
    fn applyMinSize(self: *Shell) void {
        if (self.finishing) return; // (that window sizes itself)
        const fs = c.igGetFontSize();
        const side: f32 = if (!self.info_mode and self.showsBar(.sidebar)) self.sidebar_w else 0;
        const w: c_int = @intFromFloat(@round(side + fs * (if (self.info_mode) @as(f32, 20) else 38)));
        const h: c_int = @intFromFloat(@round(fs * (if (self.info_mode) @as(f32, 16) else 20)));
        if (w == self.min_size[0] and h == self.min_size[1]) return;
        self.min_size = .{ w, h };
        c.glfwSetWindowSizeLimits(self.glfwWin(), w, h, c.GLFW_DONT_CARE, c.GLFW_DONT_CARE);
    }

    /// drawInfoWindow is a Get Info window's whole frame: a title bar (CSD) over the
    /// item's Get Info, scrolling. It waits for the folder to load, then picks out the
    /// item; closing the window (or Escape) ends the process.
    fn drawInfoWindow(self: *Shell) void {
        const b = self.activeBrowser();
        if (!self.info_ready and !b.loading) {
            var waiting = false;
            for (0..b.count()) |i| if (std.mem.eql(u8, b.at(i).name, self.info_name)) {
                // Its size and dates come after its name: wait for them (one item's
                // lookup), or it showed 0 B and no dates.
                if (b.at(i).pending) {
                    waiting = true;
                    break;
                }
                b.sel.click(i);
                self.actions.openProperties(b, i);
                self.info_ready = true;
                const t = std.mem.printSentinel(&self.info_title, "{s} Info", .{self.info_name}, 0) catch "Info";
                self.info_title_len = t.len;
                c.glfwSetWindowTitle(self.glfwWin(), t.ptr);
                break;
            };
            if (!self.info_ready and !waiting) self.info_ready = true; // gone: say so below
        }
        const title = if (self.info_title_len > 0) self.info_title[0..self.info_title_len] else self.info_name;
        if (self.csd) {
            c.igSetCursorScreenPos(cimgui.vec2(c.igGetWindowPos().x + c.igGetStyle().*.WindowPadding.x, c.igGetWindowPos().y));
            self.drawCsdTitleRow(title);
        }
        _ = c.igBeginChild_Str("##info", cimgui.vec2(0, 0), c.ImGuiChildFlags_AlwaysUseWindowPadding, 0);
        if (self.info_title_len == 0) {
            if (b.loading) dimText("Loading\u{2026}") else dimText("This item is no longer there.");
        } else {
            // More Info comes from the preview's loader, which reads the file on its
            // own thread; it shows once it's in.
            var ib: [std.fs.max_path_bytes]u8 = undefined;
            const ip = std.mem.print(&ib, "{s}/{s}", .{ if (std.mem.eql(u8, b.dir, "/")) "" else b.dir, self.info_name }) catch "";
            self.preview.update(self.io, self.alloc, if (ip.len > 0) ip else null, 0);
            self.actions.more_info = self.preview.moreInfo(ip) orelse "";
            if (self.actions.drawInfo(b)) self.closeWindow();
        }
        self.actions.drawModals(b); // Open With's chooser, delete confirmations
        c.igEndChild();
    }

    /// spawnInfo opens a Get Info window for `path` (its own process, near the pointer).
    fn spawnInfo(self: *Shell, path: []const u8) void {
        const exe = std.process.executablePathAlloc(self.io, self.alloc) catch return;
        defer self.alloc.free(exe);
        var wx: c_int = 0;
        var wy: c_int = 0;
        c.glfwGetWindowPos(self.glfwWin(), &wx, &wy);
        const mp = c.igGetMousePos();
        var pbuf: [48]u8 = undefined;
        const ps = std.mem.print(&pbuf, "{d},{d}", .{ wx + @as(c_int, @intFromFloat(mp.x)) + 20, wy + @as(c_int, @intFromFloat(@max(mp.y - 80, 0))) }) catch return;
        var child = std.process.spawn(self.io, .{ .argv = &.{ exe, "--detach", "--pos", ps, "--get-info", path } }) catch return;
        _ = child.wait(self.io) catch {}; // --detach forks away at once; this reaps the stub
    }

    /// updatePreview opens or closes Quick Look (Space) and keeps the preview on the
    /// cursor's item while the Preview pane or Quick Look shows it; drawBody draws the
    /// pane, drawQuickLook the window.
    fn updatePreview(self: *Shell) void {
        if (self.actions.quicklook_toggle) {
            self.actions.quicklook_toggle = false;
            self.ql_open = !self.ql_open;
            if (self.ql_open) self.ql_opened_at = c.igGetTime();
        }
        if (!self.ql_open) self.qlStopBrowsing();
        if (!self.show_preview and !self.ql_open) return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const b = self.activeBrowser();
        const cur = cursorPath(b, &buf);
        // A Forward step left over from the item it came out of, once another's picked.
        if (self.ql_path == null) if (self.ql_fwd) |f| {
            const fits = if (cur) |cp| std.mem.eql(u8, std.fs.path.dirname(f) orelse "", cp) else false;
            if (!fits) {
                self.alloc.free(f);
                self.ql_fwd = null;
            }
        };
        if (self.ql_path) |p| {
            const same = if (cur) |cp| (if (self.ql_from) |f| std.mem.eql(u8, cp, f) else false) else false;
            if (same) return self.preview.update(self.io, self.alloc, p, 0);
            self.qlStopBrowsing(); // another item picked in the window: follow it again
        }
        const stamp = if (b.count() > 0 and b.sel.cursor < b.count()) quicklook.stampOf(b.at(b.sel.cursor)) else 0;
        self.preview.update(self.io, self.alloc, cur, stamp);
    }

    /// qlBrowse makes Quick Look show `path` (a folder or file inside the one it
    /// shows) in place of the selected item, as a double-click in a folder's view does.
    fn qlBrowse(self: *Shell, b: *Browser, path: []const u8) void {
        const dup = self.alloc.dupe(u8, path) catch return;
        if (self.ql_fwd) |f| self.alloc.free(f); // a new way in: nothing to go forward to
        self.ql_fwd = null;
        if (self.ql_from == null) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const cp = cursorPath(b, &buf) orelse {
                self.alloc.free(dup);
                return;
            };
            self.ql_from = self.alloc.dupe(u8, cp) catch {
                self.alloc.free(dup);
                return;
            };
        }
        if (self.ql_path) |old| self.alloc.free(old);
        self.ql_path = dup;
    }

    /// qlBack steps Quick Look out of what it browsed into: to the folder holding it,
    /// and back to the selected item from there.
    fn qlBack(self: *Shell) void {
        const p = self.ql_path orelse return;
        self.preview.pickWhenIn(std.fs.path.basename(p)); // where it came back from
        if (self.ql_fwd) |f| self.alloc.free(f);
        self.ql_fwd = self.alloc.dupe(u8, p) catch null; // (Forward goes back in)
        if (self.ql_from) |f| if (std.mem.eql(u8, std.fs.path.dirname(p) orelse "", f)) {
            // Out to the selected item itself: browsing ends, Forward still knows the way.
            const keep = self.ql_fwd;
            self.ql_fwd = null;
            self.qlStopBrowsing();
            self.ql_fwd = keep;
            return;
        };
        const parent = std.fs.path.dirname(p) orelse return self.qlStopBrowsing();
        const dup = self.alloc.dupe(u8, parent) catch return;
        self.alloc.free(p);
        self.ql_path = dup;
    }

    /// qlForward steps back into what Back stepped out of.
    fn qlForward(self: *Shell) void {
        const f = self.ql_fwd orelse return;
        self.ql_fwd = null;
        defer self.alloc.free(f);
        self.qlBrowse(self.activeBrowser(), f);
    }

    fn qlStopBrowsing(self: *Shell) void {
        if (self.ql_path) |p| self.alloc.free(p);
        if (self.ql_from) |f| self.alloc.free(f);
        if (self.ql_fwd) |f| self.alloc.free(f);
        self.ql_path = null;
        self.ql_from = null;
        self.ql_fwd = null;
    }

    /// qlFitSize is the size Quick Look takes for what it shows, as macOS sizes it: an
    /// image at its own size (shrunk to fit the screen, never under a minimum), a text
    /// or document a tall page, anything else (a folder, a message) a modest box.
    fn qlFitSize(self: *Shell, work: [4]f32, frame: [2]f32) [2]f32 {
        const fs = c.igGetFontSize();
        const v = &self.preview;
        const max_w = work[2] * 0.85;
        const max_h = work[3] * 0.85;
        const min_w = fs * 24;
        const min_h = fs * 16;
        if (v.tex != 0 and v.tex_w > 0 and v.tex_h > 0) {
            // (a PDF's page, and its sidebar beside it when that's out)
            const doc = v.pdfDoc();
            const side_room = if (doc) |d| d.widthFor(1000) - 1000 else 0;
            const s = @min(1.0, @min((max_w - frame[0] - side_room) / v.tex_w, (max_h - frame[1]) / v.tex_h));
            const page_w = @round(v.tex_w * s);
            const w = if (doc) |d| d.widthFor(page_w) else page_w;
            return .{ @max(w + frame[0], min_w), @max(@round(v.tex_h * s + frame[1]), min_h) };
        }
        if (v.text != null and !v.is_message and !v.is_folder)
            return .{ @round(@min(work[2] * 0.6, fs * 60)), @round(max_h) };
        // A folder's view: its list and the picked item side by side.
        if (v.isFolderView()) return .{ @round(@min(max_w, fs * 58)), @round(@min(max_h, fs * 38)) };
        return .{ @round(@min(max_w, fs * 36)), @round(@min(max_h, fs * 26)) };
    }

    /// drawQuickLook is Finder's Quick Look: a window of its own over the files with
    /// the cursor's item big, sized to it (qlFitSize) until you resize it yourself.
    /// "Open with …" on the left of its title bar, the name in the middle, full screen
    /// and close on the right as on the main window. The file list keeps the keyboard,
    /// so the arrow keys step through the files and Space closes it; so does Esc. It
    /// appears once its content is there (or after a moment). Its window (place, size,
    /// full screen, edges, taskbar entry) is a SubWindow's.
    fn drawQuickLook(self: *Shell) void {
        const ready = !self.preview.loading or c.igGetTime() - self.ql_opened_at > 0.3;
        const shown = anim.toward(c.igGetID_Str("##qlshown"), self.ql_open and ready, anim.quick);
        if (shown < 0.01) return self.ql_win.hide();
        const fs = c.igGetFontSize();
        const vp = c.igGetMainViewport();
        const work = monitorAt(vp.*.Pos.x + vp.*.Size.x * 0.5, vp.*.Pos.y + vp.*.Size.y * 0.5, true);
        const pad = @round(fs * 0.5);
        const bar_h = toolbarH() + pad * 2;
        const b = self.activeBrowser();
        const has = b.count() > 0 and b.sel.cursor < b.count(); // (the item on screen, loading or not)
        // Its title (the taskbar's too) is the item's name.
        var nb: [600]u8 = undefined;
        const item_name = if (self.ql_path) |p| std.fs.path.basename(p) else if (has) std.fs.path.basename(b.at(b.sel.cursor).name) else "Quick Look";
        const name = std.mem.printSentinel(&nb, "{s}###quicklook", .{item_name}, 0) catch "Quick Look###quicklook";
        // Sized to its item until you resize it yourself (not refitted mid-load: to the
        // last item's shape).
        const fit = self.qlFitSize(work, .{ pad * 2, toolbarH() + pad * 4 });
        // A PDF's sidebar coming out (or going): the window grows by it to the left
        // (shrinks), so the page stays where it is: to its fitted size, or by the
        // sidebar's width when you've sized it yourself.
        const doc = self.preview.pdfDoc();
        const side_now = if (doc) |d| d.sideShown() else false;
        if (doc) |d| if (doc == self.ql_pdf_doc and side_now != self.ql_pdf_side and self.ql_win.opened) {
            const body_w = self.ql_win.rect[2] - pad * 2;
            const by_side = if (side_now) d.widthFor(body_w) - body_w else -pdfview.PdfDoc.barWidth(body_w);
            self.ql_win.growLeft(if (self.ql_win.user == null) fit[0] - self.ql_win.rect[2] else by_side);
        };
        self.ql_pdf_side = side_now;
        self.ql_pdf_doc = doc; // (another document is fitted, not grown)
        defer self.ql_win.end();
        const open = self.ql_win.begin(.{
            .name = name,
            .taskbar = true,
            .frameless = true,
            .focus_on_appear = false, // (the file list keeps the keyboard)
            .preferred = fit,
            .refit = !self.preview.loading,
            .fit_after_full = true,
            .centre_in = work,
            .min = .{ fs * 16, fs * 10 },
            .flags = c.ImGuiWindowFlags_NoScrollbar,
        }, &self.ql_open); // (closed from outside too: its taskbar entry's Close)
        if (!open) return;
        // Escape leaves full screen first, as on macOS; then it closes Quick Look.
        if (self.ql_open and c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false) and !cimgui.zfd_want_text_input() and !pdfview.takesEscape()) {
            if (self.ql_win.escape()) self.ql_open = false;
        }

        const r = self.ql_win.rect;
        const wp = cimgui.vec2(r[0], r[1]);
        const ws = cimgui.vec2(r[2], r[3]);
        self.ql_win.background();

        // The preview fills the rest (all of it in full screen, the title bar over it).
        const top: f32 = if (self.ql_win.full) 0 else bar_h;
        c.igSetCursorScreenPos(cimgui.vec2(wp.x + pad, wp.y + top + pad));
        const body = cimgui.vec2(ws.x - pad * 2, @max(ws.y - top - pad * 2, 1));
        const enter = if (self.preview.isFolderView())
            self.preview.drawFolderView(self.io, self.alloc, body, b)
        else
            self.preview.drawPreview(body, &self.ql_zoom);

        // The title bar, over that: full screen and close on the right; "Open with
        // <app>" on the left, the name centred in what's left.
        if (self.ql_win.beginTitleBar(bar_h)) {
            defer self.ql_win.endTitleBar();
            const dl = c.igGetWindowDrawList();
            const tb = self.ql_win.titleButtons(pad, "Close (Space)");
            if (tb.close) self.ql_open = false;
            var right = tb.left;
            // Rotate, for a picture (as macOS's Quick Look has them), left of those; a
            // PDF's pages turn in the view (the file stays as it is).
            const browsing = self.ql_path != null;
            const pdf_doc = self.preview.pdfDoc();
            if (pdf_doc != null or (has and !browsing and self.canRotate(b) and self.ffmpeg_path != null)) {
                const tbw = @round(toolbarH() * 1.2);
                right -= tbw * 2 + fs * 0.4;
                c.igSetCursorScreenPos(cimgui.vec2(right, wp.y + pad));
                if (toolButton("##qlrotl", .rotate_left, true, false, "Rotate Left")) {
                    if (pdf_doc) |d| d.rotate(false) else self.runImageAction(b, self.ffmpeg_path.?, .{ .rotate = false });
                }
                c.igSameLine(0, 0);
                if (toolButton("##qlrotr", .rotate_right, true, false, "Rotate Right")) {
                    if (pdf_doc) |d| d.rotate(true) else self.runImageAction(b, self.ffmpeg_path.?, .{ .rotate = true });
                }
            }
            var left_end = wp.x + pad;
            var ob: [160]u8 = undefined;
            // Browsed into something: a back button first, out to where it came from.
            if (browsing) {
                c.igSetCursorScreenPos(cimgui.vec2(left_end, wp.y + pad));
                if (toolButton("##qlback", .back, true, false, "Back")) self.qlBack();
                left_end += @round(toolbarH() * 1.2) + fs * 0.3;
            }
            if (has and !browsing and !b.at(b.sel.cursor).isDir()) {
                const app = b.opensWith(b.at(b.sel.cursor).name);
                const label = (if (app.len > 0) std.mem.printSentinel(&ob, "Open with {s}##qlopen", .{app}, 0) else std.mem.printSentinel(&ob, "Open##qlopen", .{}, 0)) catch "Open##qlopen";
                const lw = c.igCalcTextSize(label.ptr, null, true, -1).x + c.igGetStyle().*.FramePadding.x * 2;
                if (left_end + lw < right - fs * 4) {
                    c.igSetCursorScreenPos(cimgui.vec2(left_end, wp.y + pad + (toolbarH() - c.igGetFrameHeight()) * 0.5));
                    if (c.igButton(label.ptr, cimgui.vec2(0, 0)) and !b.loading) b.openCursor() catch {}; // (not mid-load: the path would be the next folder's)
                    left_end += lw;
                }
            }
            if (has) {
                var tbuf: [512]u8 = undefined;
                const span = right - left_end - fs;
                const title = ellipsize(&tbuf, item_name, span);
                const tw = c.igCalcTextSize(title.ptr, null, false, -1).x;
                // Centred on the window if it fits there, else in the space between.
                const cx = std.math.clamp(wp.x + (ws.x - tw) * 0.5, left_end + fs * 0.5, @max(right - fs * 0.5 - tw, left_end + fs * 0.5));
                c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(cx, wp.y + (bar_h - c.igGetTextLineHeight()) * 0.5), c.igGetColorU32_Col(c.ImGuiCol_Text, 1), title.ptr, null);
            }
        }

        // A double-click in a folder's view stays in Quick Look: it shows that folder,
        // or that file (Back steps out again).
        if (enter) |e| {
            var eb: [std.fs.max_path_bytes]u8 = undefined;
            const target = if (e.select) |n| (std.fmt.bufPrint(&eb, "{s}/{s}", .{ if (std.mem.eql(u8, e.path, "/")) "" else e.path, n }) catch e.path) else e.path;
            self.qlBrowse(b, target);
        }
    }

    /// canRotate reports whether the item at the cursor is a picture its Quick Actions
    /// apply to (rotated in place with ffmpeg: not inside an archive or Recent).
    fn canRotate(self: *Shell, b: *Browser) bool {
        if (self.ffmpeg_path == null or b.virtualView() or b.count() == 0 or b.sel.cursor >= b.count()) return false;
        const e = b.at(b.sel.cursor);
        return !e.isDir() and core.imagetool.isImage(e.name);
    }

    /// runImageAction rotates (or converts) the picture at the cursor, in place,
    /// with ffmpeg on its own thread; the folder's watch then reloads it, and the
    /// preview follows (it watches the item's time and size).
    fn runImageAction(self: *Shell, b: *Browser, ff: []const u8, a: core.imagetool.Action) void {
        var cpb: [std.fs.max_path_bytes]u8 = undefined;
        if (cursorPath(b, &cpb)) |p| core.imagetool.run(self.io, self.alloc, ff, a, &.{p});
    }

    /// openQuickLook shows Quick Look on the cursor's item.
    fn openQuickLook(self: *Shell) void {
        if (self.ql_open) return;
        self.ql_open = true;
        self.ql_opened_at = c.igGetTime();
    }

    /// OpsSummary is what the toolbar's operations button shows: how many operations
    /// are running (past the brief "don't bother showing it" moment) and their
    /// combined progress.
    const OpsSummary = struct { count: usize, fraction: f32 };

    fn opsSummary(self: *Shell) OpsSummary {
        var n: usize = 0;
        var sum: f32 = 0;
        var name_buf: [512]u8 = undefined;
        for (self.opBrowsers()) |b| {
            for (0..b.opLanes()) |lane| {
                const snap = b.opProgress(lane, &name_buf);
                if (!snap.active() or snap.elapsed_ns < 300 * std.time.ns_per_ms) continue;
                n += 1;
                sum += snap.fraction();
            }
        }
        if (self.procwatch) |pw| {
            var ob: [core.procwatch.max_outside]core.procwatch.Outside = undefined;
            for (ob[0..pw.outsideOps(&ob)]) |*o| {
                n += 1;
                sum += o.fraction();
            }
        }
        return .{ .count = n, .fraction = if (n > 0) sum / @as(f32, @floatFromInt(n)) else 0 };
    }

    /// drawOpsButton is Finder's progress indicator in the toolbar: a ring filling up
    /// with the running operations' progress (and how many there are). Clicking it opens
    /// the list of operations, each with its bar and a Cancel, like a downloads list.
    /// Nothing floats over the window or gets its own taskbar entry.
    fn drawOpsButton(self: *Shell, sum: OpsSummary) void {
        const h = toolbarH();
        const w = @round(h * 1.25);
        const pos = c.igGetCursorScreenPos();
        if (c.igInvisibleButton("##ops", cimgui.vec2(w, h), 0)) c.igOpenPopup_Str("##opslist", 0);
        const hovered = c.igIsItemHovered(0);
        const dl = c.igGetWindowDrawList();
        const pal = theme.p();
        if (hovered) c.ImDrawList_AddRectFilled(dl, pos, cimgui.vec2(pos.x + w, pos.y + h), c.igGetColorU32_Vec4(if (pal.dark) cimgui.vec4(1, 1, 1, 0.08) else cimgui.vec4(0, 0, 0, 0.05)), 6, 0);
        const cen = cimgui.vec2(pos.x + w * 0.5, pos.y + h * 0.5);
        const r = h * 0.3;
        c.ImDrawList_AddCircle(dl, cen, r, c.igGetColorU32_Vec4(pal.separator), 24, 2.5);
        const start: f32 = -std.math.pi / 2.0;
        const frac = @max(sum.fraction, 0.03);
        c.ImDrawList_PathArcTo(dl, cen, r, start, start + frac * 2 * std.math.pi, 24);
        c.ImDrawList_PathStroke(dl, c.igGetColorU32_Vec4(pal.accent), 2.5, 0); // thickness, flags
        if (sum.count > 1) {
            var nb: [8]u8 = undefined;
            const t = std.mem.print(&nb, "{d}", .{sum.count}) catch "";
            const ts = c.igCalcTextSize(t.ptr, t.ptr + t.len, false, -1);
            c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(cen.x - ts.x * 0.5, cen.y - ts.y * 0.5), c.igGetColorU32_Vec4(pal.text), t.ptr, t.ptr + t.len);
        }
        if (hovered) {
            const tip: [:0]const u8 = if (sum.count == 1) "1 operation in progress" else "Operations in progress";
            c.igSetTooltip("%s", tip.ptr);
        }
        self.drawOpsList();
    }

    fn drawOpsList(self: *Shell) void {
        if (!c.igBeginPopup("##opslist", 0)) return;
        defer c.igEndPopup();
        self.drawOpsRows();
        c.igSeparator();
        if (c.igMenuItem_Bool("Show in a Window", null, false, true)) self.progress_open = true;
    }

    /// drawProgressWindow is Window > Show Progress: the same list as the toolbar
    /// ring's, in a small window you can leave open (Finder's copy window). It stays
    /// with ZFD's window; it has no taskbar entry of its own.
    fn drawProgressWindow(self: *Shell) void {
        if (!self.progress_open) return self.progress_win.hide();
        const fs = c.igGetFontSize();
        const vp = c.igGetMainViewport();
        // Bottom-right of the window, placed by its (fixed) width.
        c.igSetNextWindowPos(cimgui.vec2(vp.*.WorkPos.x + vp.*.WorkSize.x - fs * 29, vp.*.WorkPos.y + vp.*.WorkSize.y - fs * 3), c.ImGuiCond_Appearing, cimgui.vec2(0, 1));
        // A fixed width, so it doesn't grow sideways (off its corner) as rows come and go.
        c.igSetNextWindowSizeConstraints(cimgui.vec2(fs * 28, 0), cimgui.vec2(fs * 28, 100000), null, null);
        c.igSetNextWindowBgAlpha(1.0);
        defer self.progress_win.end();
        if (!self.progress_win.begin(.{ .name = "Progress", .auto_size = true, .focus_on_appear = false, .flags = c.ImGuiWindowFlags_NoCollapse }, &self.progress_open)) return;
        self.drawOpsRows();
    }

    /// drawOpsRows lists every running operation (all tabs), or says all is done.
    fn drawOpsRows(self: *Shell) void {
        var any = false;
        for (self.opBrowsers()) |b| {
            for (0..b.opLanes()) |lane| {
                if (drawOpRow(b, lane)) any = true;
            }
        }
        // Copies running outside ZFD (cp, mv, rsync… in a terminal): shown, not ours to stop.
        if (self.procwatch) |pw| {
            var ob: [core.procwatch.max_outside]core.procwatch.Outside = undefined;
            for (ob[0..pw.outsideOps(&ob)]) |*o| {
                any = true;
                var lb: [400]u8 = undefined;
                cimgui.textUnformatted(std.mem.print(&lb, "\"{s}\"", .{o.name()}) catch o.name());
                c.igSameLine(0, -1);
                c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
                cimgui.textUnformatted(std.mem.print(&lb, "{s}, outside ZFD", .{o.tool()}) catch o.tool());
                c.igPopStyleColor(1);
                var db: [24]u8 = undefined;
                var tb: [24]u8 = undefined;
                const over = std.mem.printSentinel(&lb, "{s} / {s}", .{ core.scan.humanizeSize(&db, o.done), core.scan.humanizeSize(&tb, o.total) }, 0) catch "";
                c.igProgressBar(o.fraction(), cimgui.vec2(c.igGetFontSize() * 22, 0), over.ptr);
                c.igSpacing();
            }
        }
        if (!any) {
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
            cimgui.textUnformatted("All done.");
            c.igPopStyleColor(1);
        }
    }

    /// drawOpRow is one operation in the list: what it's doing, a bar, Cancel.
    fn drawOpRow(b: *Browser, lane: usize) bool {
        var name_buf: [512]u8 = undefined;
        const snap = b.opProgress(lane, &name_buf);
        if (!snap.active()) return false;
        const phase_label: []const u8 = switch (snap.phase) {
            .copying => "Copying",
            .moving => "Moving",
            .deleting => "Deleting",
            .trashing => "Moving to Trash",
            .compressing => "Compressing",
            .extracting => "Extracting",
            .tagging => "Tagging",
            .idle => "",
        };
        c.igPushID_Ptr(b);
        c.igPushID_Int(@intCast(lane));
        defer {
            c.igPopID();
            c.igPopID();
        }
        var lb: [600]u8 = undefined;
        cimgui.textUnformatted(if (snap.current.len > 0)
            (std.mem.print(&lb, "{s} \"{s}\"", .{ phase_label, snap.current }) catch phase_label)
        else
            phase_label);
        var over_buf: [96]u8 = undefined;
        const overlay = progressOverlay(&over_buf, snap);
        c.igProgressBar(snap.fraction(), cimgui.vec2(c.igGetFontSize() * 22, 0), overlay.ptr);
        c.igSameLine(0, -1);
        if (snap.canceled) {
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
            cimgui.textUnformatted("Stopping\u{2026}");
            c.igPopStyleColor(1);
        } else if (c.igSmallButton("Cancel")) b.cancelOp(lane);
        c.igSpacing();
        return true;
    }

    /// drawBody lays out the sidebar (left) and the content area (file table, plus
    /// an optional treemap pane below it). `bottom_reserve` keeps that many pixels free
    /// at the bottom of the body (0 in the browser; the footer height in a dialog) so a
    /// Save/Open chooser shows the sidebar above its Name/filter footer.
    /// drawSidebarColumn is the sidebar running the window's full height on the left,
    /// with its splitter; the places start at its top. Shown or hidden, it slides: the
    /// places keep their width and the column clips them.
    fn drawSidebarColumn(self: *Shell, b: *Browser) void {
        const want: f32 = if (self.showsBar(.sidebar)) self.sidebar_w else 0;
        const w = @round(anim.value(c.igGetID_Str("##sidebarw"), want, anim.normal, .out_cubic));
        if (w < 1) return;
        // Its fill is drawn on the shell window, so the window's left corners round it.
        const sp = c.igGetCursorScreenPos();
        c.ImDrawList_AddRectFilled(c.igGetWindowDrawList(), sp, cimgui.vec2(sp.x + w, sp.y + c.igGetContentRegionAvail().y), c.igGetColorU32_Vec4(theme.p().sidebar_bg), self.cornerRadius(), c.ImDrawFlags_RoundCornersLeft);
        _ = c.igBeginChild_Str("##sidebar", cimgui.vec2(w, 0), 0, c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse);
        _ = c.igBeginChild_Str("##places", cimgui.vec2(@max(self.sidebar_w, w), 0), c.ImGuiChildFlags_AlwaysUseWindowPadding, 0);
        side_net_page = self.net_page;
        side_left = false;
        self.drawSidebar(b);
        if (side_left and self.net_page) self.closeNetworkPage(); // gone somewhere else in the sidebar
        c.igEndChild();
        c.igEndChild();
        c.igSameLine(0, 0);
        if (w != want) return; // no splitter mid-slide

        // Draggable splitter between the sidebar and the column.
        _ = c.igInvisibleButton("##split", cimgui.vec2(5, c.igGetContentRegionAvail().y), 0);
        if (c.igIsItemHovered(0) or c.igIsItemActive()) c.igSetMouseCursor(c.ImGuiMouseCursor_ResizeEW);
        if (c.igIsItemActivated()) self.sidebar_w_press = self.sidebar_w;
        if (c.igIsItemActive()) {
            const d = c.igGetMouseDragDelta(0, 0);
            self.sidebar_w = std.math.clamp(self.sidebar_w_press + d.x, 120, 500);
        }
        c.igSameLine(0, 0);
    }

    /// drawFrame paints the window's background, rounded at the corners when borderless
    /// (what's outside them is see-through), with a hairline edge.
    fn drawFrame(self: *Shell) void {
        const dl = c.igGetWindowDrawList();
        const p0 = c.igGetWindowPos();
        const p1 = cimgui.vec2(p0.x + c.igGetWindowWidth(), p0.y + c.igGetWindowHeight());
        const r = self.cornerRadius();
        c.ImDrawList_AddRectFilled(dl, p0, p1, c.igGetColorU32_Vec4(theme.p().content_bg), r, 0);
        if (self.csd) c.ImDrawList_AddRect(c.igGetForegroundDrawList_ViewportPtr(c.igGetMainViewport()), p0, p1, c.igGetColorU32_Vec4(theme.p().separator), r, 1, 0); // rounding, thickness, flags
    }

    /// cornerRadius is the window's corner rounding: borderless and not filling the
    /// screen, else square.
    fn cornerRadius(self: *Shell) f32 {
        if (!self.csd or self.isMaximized()) return 0;
        return @round(10 * self.style_scale);
    }

    /// dragZone moves the window when a press lands on nothing in the min–max rect
    /// (CSD); a double-click maximizes. Hit-tested by rect, like the resize grips.
    fn dragZone(self: *Shell, min: c.ImVec2_c, max: c.ImVec2_c) void {
        if (self.grip_press or !c.igIsMouseHoveringRect(min, max, false) or c.igIsAnyItemHovered()) return;
        if (!c.igIsWindowHovered(0)) return; // a menu open over the band has the pointer
        if (c.igIsMouseDoubleClicked_Nil(0)) {
            self.toggleMaximize();
        } else if (c.igIsMouseClicked_Bool(0, false)) {
            self.startWm(.move);
        }
    }

    fn drawBody(self: *Shell, b: *Browser, keyboard: bool, bottom_reserve: f32) void {
        // Child height -bottom_reserve = "fill, minus the reserved footer" (0 = fill).
        // The sidebar sits on its own tint, like Finder's, with no frame around it.
        const split_h = @max(c.igGetContentRegionAvail().y - bottom_reserve, 1);

        // NoScrollbar on the wrappers: only the table (its own ScrollY) scrolls, so
        // we don't get a second scrollbar from the wrapping child.
        // The Preview pane: to the right of the files, with its own splitter.
        const fs = c.igGetFontSize();
        if (self.preview_w == 0) self.preview_w = fs * 18;
        // The pane slides in and out (pv_shown); its contents keep their width.
        const pv_full = std.math.clamp(self.preview_w, fs * 10, @max(c.igGetContentRegionAvail().x * 0.6, fs * 10));
        const pv_shown = @round(anim.value(c.igGetID_Str("##previeww"), if (self.show_preview) pv_full else 0, anim.normal, .out_cubic));
        const pv_open = pv_shown >= 1;
        const main_w: f32 = if (pv_open) -(pv_shown + 6) else 0;
        _ = c.igBeginChild_Str("##main", cimgui.vec2(main_w, -bottom_reserve), 0, c.ImGuiWindowFlags_NoScrollbar);
        if (self.net_page) {
            self.drawNetworkPage(b);
        } else if (self.split_b) |sb| {
            self.drawPanes(sb, keyboard);
        } else if (self.show_treemap) {
            const avail = c.igGetContentRegionAvail();
            _ = c.igBeginChild_Str("##files", cimgui.vec2(0, avail.y * self.files_frac), 0, c.ImGuiWindowFlags_NoScrollbar);
            self.content.draw(b, &self.actions, keyboard, 0);
            c.igEndChild();

            // Draggable horizontal splitter: drag it to resize the treemap pane.
            const split_w = c.igGetContentRegionAvail().x;
            _ = c.igInvisibleButton("##tmsplit", cimgui.vec2(split_w, 6), 0);
            if (c.igIsItemHovered(0) or c.igIsItemActive()) c.igSetMouseCursor(c.ImGuiMouseCursor_ResizeNS);
            if (c.igIsItemActivated()) self.files_frac_press = self.files_frac;
            if (c.igIsItemActive() and avail.y > 0) {
                const d = c.igGetMouseDragDelta(0, 0);
                self.files_frac = std.math.clamp(self.files_frac_press + d.y / avail.y, 0.15, 0.85);
            }

            _ = c.igBeginChild_Str("##treemap", cimgui.vec2(0, 0), c.ImGuiChildFlags_Borders, 0);
            treemap.draw(b, &self.actions); // share the same right-click menu
            c.igEndChild();
        } else {
            self.content.draw(b, &self.actions, keyboard, 0);
        }
        c.igEndChild();
        if (!pv_open) return;

        c.igSameLine(0, 0);
        _ = c.igInvisibleButton("##previewsplit", cimgui.vec2(6, split_h), 0);
        if (pv_shown == pv_full) { // resizable once it has slid in
            if (c.igIsItemHovered(0) or c.igIsItemActive()) c.igSetMouseCursor(c.ImGuiMouseCursor_ResizeEW);
            if (c.igIsItemActivated()) self.preview_w_press = pv_full;
            if (c.igIsItemActive()) self.preview_w = self.preview_w_press - c.igGetMouseDragDelta(0, 0).x;
        }
        c.igSameLine(0, 0);
        c.igPushStyleColor_Vec4(c.ImGuiCol_ChildBg, theme.p().sidebar_bg);
        c.igPushStyleVar_Float(c.ImGuiStyleVar_ChildRounding, 8);
        _ = c.igBeginChild_Str("##preview", cimgui.vec2(0, -bottom_reserve), 0, c.ImGuiWindowFlags_NoScrollbar);
        _ = c.igBeginChild_Str("##previewbody", cimgui.vec2(pv_full, 0), c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_NoScrollbar);
        self.drawPreviewPane(self.activeBrowser());
        c.igEndChild();
        c.igEndChild();
        c.igPopStyleVar(1);
        c.igPopStyleColor(1);
    }

    /// drawPreviewPane is the Preview pane's contents: the preview on top, then the
    /// item's name, kind and dates, like Finder's.
    fn drawPreviewPane(self: *Shell, b: *Browser) void {
        // (While the next folder loads, the item on screen stays shown: no blank.)
        const has = b.count() > 0 and b.sel.cursor < b.count();
        const fs = c.igGetFontSize();
        const avail = c.igGetContentRegionAvail();
        const line = c.igGetTextLineHeightWithSpacing();
        const info_h = line * 7 + fs * 1.5;
        var ph = @max(avail.y - info_h, fs * 4);
        // A picture sits at the top at its own aspect (no taller than it draws), with
        // the details right under it, as in Finder.
        const ql = &self.preview;
        if (ql.tex != 0) ph = @min(ph, @min(avail.x / ql.tex_w, 1.0) * ql.tex_h);
        if (ql.drawPreview(cimgui.vec2(avail.x, ph), null)) |enter| enterFromPreview(b, enter); // (fitted: zoom is Quick Look's)
        if (ql.takeOpenRequest()) self.openQuickLook(); // a double-click on the picture
        if (!has) return;
        const e = b.at(b.sel.cursor);
        c.igSpacing();
        cimgui.pushFontTimes(1.15);
        c.igPushTextWrapPos(0);
        cimgui.textUnformatted(std.fs.path.basename(e.name));
        c.igPopTextWrapPos();
        c.igPopFont();
        var tb: [64]u8 = undefined;
        dimText(b.typeLabel(e, &tb));
        c.igSeparatorText("Information");
        var sb: [32]u8 = undefined;
        if (!e.isDir()) infoRow("Size", core.scan.humanizeSize(&sb, e.size));
        var db: [24]u8 = undefined;
        if (e.mtime_secs > 0) infoRow("Modified", core.scan.formatDateFriendly(&db, e.mtime_secs, table.nowSecs()));
        var cb: [24]u8 = undefined;
        if (e.btime_secs > 0) infoRow("Created", core.scan.formatDateFriendly(&cb, e.btime_secs, table.nowSecs()));
        // A picture's, video's or recording's details, once read (the preview's loader).
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        if (cursorPath(b, &pb)) |p| if (ql.moreInfo(p)) |more| {
            c.igSeparatorText("More Info");
            var it = std.mem.splitScalar(u8, more, '\n');
            while (it.next()) |ln| {
                const tab = std.mem.indexOfScalar(u8, ln, '\t') orelse continue;
                infoRow(ln[0..tab], ln[tab + 1 ..]);
            }
        };
        // Quick Actions for a picture, as under Finder's preview.
        if (self.ffmpeg_path) |ff| if (!e.isDir() and !b.virtualView() and core.imagetool.isImage(e.name)) {
            c.igSpacing();
            var act: ?core.imagetool.Action = null;
            if (c.igButton("Rotate Left", cimgui.vec2(0, 0))) act = .{ .rotate = false };
            c.igSameLine(0, -1);
            if (c.igButton("Rotate Right", cimgui.vec2(0, 0))) act = .{ .rotate = true };
            if (act) |a| self.runImageAction(b, ff, a);
        };
    }

    /// drawPanes lays out split view: the current tab on the left, the split pane on the
    /// right. A click in a pane focuses it; the focused one gets an accent outline and
    /// is the only one that receives list keys.
    fn drawPanes(self: *Shell, sb: *Browser, keyboard: bool) void {
        const gap: f32 = 6;
        const avail = c.igGetContentRegionAvail();
        const half = @max((avail.x - gap) / 2, 50);
        const panes = [_]struct { b: *Browser, right: bool }{
            .{ .b = self.tabBrowser(), .right = false },
            .{ .b = sb, .right = true },
        };
        for (panes, 0..) |p, i| {
            if (i == 1) c.igSameLine(0, gap);
            _ = c.igBeginChild_Str(if (p.right) "##paneR" else "##paneL", cimgui.vec2(half, 0), 0, c.ImGuiWindowFlags_NoScrollbar);
            const focused = p.right == self.split_focus;
            const hovered = c.igIsWindowHovered(c.ImGuiHoveredFlags_ChildWindows);
            if (hovered and (c.igIsMouseClicked_Bool(0, false) or c.igIsMouseClicked_Bool(1, false) or c.igIsMouseClicked_Bool(2, false)))
                self.split_focus = p.right;
            const view = if (p.right) &self.split_view else &self.content;
            view.draw(p.b, &self.actions, keyboard and focused, 0);
            c.igEndChild();
            if (focused) {
                const dl = c.igGetWindowDrawList();
                const col = c.igGetColorU32_Col(c.ImGuiCol_ButtonActive, 1);
                c.ImDrawList_AddRect(dl, c.igGetItemRectMin(), c.igGetItemRectMax(), col, 0, 2, 0); // rounding, thickness, flags
            }
        }
    }

    fn drawSidebar(self: *Shell, b: *Browser) void {
        // Finder's sidebar: Favourites (places + your bookmarks + Trash), Locations
        // (this computer, devices, network), Tags: grey section titles that fold.
        if (self.sideSection("Favourites", 0)) {
            // Recent: no dropZone; it isn't a folder anything can be put into.
            if (self.shows(.recent)) {
                if (sideItem("Recent", b.in_recent, .recent, false)) b.navigate(core.recent.uri) catch {};
                if (c.igIsItemClicked(c.ImGuiMouseButton_Middle)) self.newTabAt(core.recent.uri);
                self.linkMenu(core.recent.uri);
            }
            if (self.shows(.home)) self.place(b, "Home", self.home, .home);
            if (self.shows(.desktop)) self.placeSub(b, "Desktop", "Desktop", .desktop);
            if (self.shows(.documents)) self.placeSub(b, "Documents", "Documents", .document);
            if (self.shows(.downloads)) self.placeSub(b, "Downloads", "Downloads", .download);
            var remove_idx: ?usize = null;
            var move: ?[2]usize = null; // bookmark reorder: from → to
            var rename_done: ?[]const u8 = null;
            self.checkBookmarks();
            for (self.bookmarks.items, 0..) |bm, i| {
                if (self.bm_rename != null and self.bm_rename.? == i) {
                    // Inline rename: Enter keeps it, Escape or clicking away cancels.
                    if (c.igIsWindowAppearing() or !c.igIsAnyItemActive()) c.igSetKeyboardFocusHere(0);
                    c.igSetNextItemWidth(-1);
                    if (c.igInputText("##bmren", &self.bm_rename_buf, self.bm_rename_buf.len, c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_AutoSelectAll, null, null))
                        rename_done = std.mem.trim(u8, std.mem.sliceTo(&self.bm_rename_buf, 0), " ");
                    if (c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false) or (c.igIsItemDeactivated() and rename_done == null)) self.bm_rename = null;
                    continue;
                }
                var lbuf: [320]u8 = undefined;
                const name = bm.displayName();
                const label = std.mem.printSentinel(&lbuf, "{s}##bm{d}", .{ name, i }, 0) catch continue;
                const avail = self.bookmarkAvailable(bm);
                var pbuf: [std.fs.max_path_bytes]u8 = undefined;
                const where = self.bookmarkPath(&pbuf, bm);
                const here = if (where) |p| std.mem.eql(u8, p, b.dir) else false;
                const is_search = bm.target() == .search;
                const icon: SideIcon = switch (bm.target()) {
                    .path => .folder,
                    .remote => .network,
                    .device => .drive,
                    .search => .search,
                };
                const dead = self.bookmarkDead(i);
                if (sideItem(label, here, icon, !avail or dead or (where == null and !is_search))) self.openBookmark(b, bm);
                if (where) |p| if (!dead) {
                    if (c.igIsItemClicked(c.ImGuiMouseButton_Middle)) self.newTabAt(p);
                    self.dropZone(p);
                };
                if (c.igBeginItemTooltip()) {
                    var tb: [1200]u8 = undefined;
                    const how: []const u8 = switch (bm.target()) {
                        .path => if (dead) "\nThis folder isn't there any more" else "",
                        .remote => if (where == null) "\nOn a network location. Click to connect" else "",
                        .device => if (!avail) "\nOn a device that isn't plugged in" else if (where == null) "\nOn a device. Click to mount" else "",
                        .search => "",
                    };
                    const tip = if (is_search) blk: {
                        const t = bm.target().search;
                        break :blk std.mem.print(&tb, "Saved search: \"{s}\" in {s}{s}", .{ t.query, t.dir, if (t.deep) " and its subfolders" else "" }) catch bm.loc;
                    } else std.mem.print(&tb, "{s}{s}", .{ where orelse bm.loc, how }) catch bm.loc;
                    cimgui.textUnformatted(tip);
                    c.igEndTooltip();
                }
                // Drag a bookmark onto another to reorder.
                if (c.igBeginDragDropSource(0)) {
                    var idx: usize = i;
                    _ = c.igSetDragDropPayload("ZFD_BM", &idx, @sizeOf(usize), 0);
                    cimgui.textUnformatted(name);
                    c.igEndDragDropSource();
                }
                if (c.igBeginDragDropTarget()) {
                    const pl = c.igAcceptDragDropPayload("ZFD_BM", c.ImGuiDragDropFlags_AcceptBeforeDelivery | c.ImGuiDragDropFlags_AcceptNoDrawDefaultRect);
                    if (pl != null and pl.*.DataSize == @sizeOf(usize)) {
                        const bytes: [*]const u8 = @ptrCast(pl.*.Data);
                        const from = std.mem.bytesToValue(usize, bytes[0..@sizeOf(usize)]);
                        // A blue line where it'll land: above this row when moving up,
                        // below it when moving down.
                        if (from != i) {
                            const mn = c.igGetItemRectMin();
                            const mx = c.igGetItemRectMax();
                            const y = if (from > i) mn.y else mx.y;
                            const th = @max(2.0, @round(2.0 * self.style_scale));
                            const col = c.igGetColorU32_Vec4(theme.p().accent);
                            const dl = c.igGetWindowDrawList();
                            c.ImDrawList_AddLine(dl, cimgui.vec2(mn.x + th * 2, y), cimgui.vec2(mx.x, y), col, th);
                            c.ImDrawList_AddCircleFilled(dl, cimgui.vec2(mn.x + th * 2, y), th * 1.6, col, 0);
                        }
                        if (pl.*.Delivery) move = .{ from, i };
                    }
                    c.igEndDragDropTarget();
                }
                if (c.igBeginPopupContextItem(null, c.ImGuiPopupFlags_MouseButtonRight)) {
                    if (where) |p| if (!dead) self.newTabMenuItem(p);
                    if (c.igMenuItem_Bool("Edit\u{2026}", null, false, true)) self.editBookmark(i);
                    if (c.igMenuItem_Bool("Rename", null, false, true)) {
                        self.bm_rename = i;
                        @memset(&self.bm_rename_buf, 0);
                        const n = @min(name.len, self.bm_rename_buf.len - 1);
                        @memcpy(self.bm_rename_buf[0..n], name[0..n]);
                    }
                    if (c.igMenuItem_Bool("Remove bookmark", null, false, true)) remove_idx = i;
                    c.igEndPopup();
                }
            }
            if (rename_done) |label| {
                if (self.bm_rename) |ri| self.renameBookmark(ri, label);
                self.bm_rename = null;
            }
            if (remove_idx) |i| self.removeBookmark(i);
            if (move) |m| self.moveBookmark(m[0], m[1]);
            if (self.bm_msg_len > 0) {
                c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
                c.igPushTextWrapPos(0);
                cimgui.textUnformatted(self.bm_msg[0..self.bm_msg_len]);
                c.igPopTextWrapPos();
                c.igPopStyleColor(1);
                if (c.igSmallButton("Dismiss##bmmsg")) self.bm_msg_len = 0;
            }
            if (self.dialog == null) {
                // Add the folder on screen (or drop folders here); Finder takes drops too.
                if (sideItem("Add current folder##bmadd", false, .plus, true)) self.addBookmark(b.dir);
                if (c.igBeginDragDropTarget()) {
                    const payload = c.igAcceptDragDropPayload(table.DRAG_PAYLOAD, 0);
                    if (payload != null and payload.*.Delivery) {
                        // Only folders become favourites: asked in the background (pollBg).
                        if (self.actions.dragSource(payload)) |src| if (self.bg) |g| {
                            for (self.drop_probe.items) |p| self.alloc.free(p);
                            self.drop_probe.clearRetainingCapacity();
                            for (src.dragPaths()) |dp| {
                                const d = self.alloc.dupe(u8, dp) catch continue;
                                self.drop_probe.append(self.alloc, d) catch self.alloc.free(d);
                            }
                            g.probe(bg_add_favourites, src.dragPaths());
                        };
                    }
                    c.igEndDragDropTarget();
                }
            }
            if (self.shows(.trash)) {
                if (sideItem("Trash", self.show_trash, .trash, false)) self.openTrash();
                if (c.igBeginPopupContextItem(null, c.ImGuiPopupFlags_MouseButtonRight)) {
                    if (c.igMenuItem_Bool("Open Trash", null, false, true)) self.openTrash();
                    if (c.igMenuItem_Bool("Empty Trash\u{2026}", null, false, true)) self.empty_trash_pending = true;
                    c.igEndPopup();
                }
            }
            // Drop rows on Trash to trash them (Ctrl+Z undoes it). Internal drags only:
            // an external drop would mean deleting files another app still owns, decided
            // by nothing but a coordinate hit-test. Everything from outside is copied.
            if (self.shows(.trash) and c.igBeginDragDropTarget()) {
                const payload = c.igAcceptDragDropPayload(table.DRAG_PAYLOAD, 0);
                if (payload != null and payload.*.Delivery) {
                    if (self.actions.dragSource(payload)) |src| src.trashPaths(src.dragPaths());
                }
                c.igEndDragDropTarget();
            }
        }

        // Locations: the computer, volumes (mounted or not), unmounted fstab entries,
        // other mounts, and rclone network locations.
        if (self.sideSection("Locations", 1)) {
            self.drawNewDeviceBanner();
            if (self.shows(.computer)) self.place(b, "Computer", "/", .computer);
            if (self.shows(.devices)) for (self.vols, 0..) |v, i| self.volumeRow(b, v, i);
            if (self.shows(.devices)) for (self.fstab_entries, 0..) |e, i| self.fstabRow(e, i);
            if (self.shows(.mounts)) for (self.mounts, 0..) |m, i| {
                if (self.volumeAt(m.mountpoint)) continue; // already listed as a volume
                var lbuf: [320]u8 = undefined;
                const label = std.mem.printSentinel(&lbuf, "{s}##dev{d}", .{ std.fs.path.basename(m.mountpoint), i }, 0) catch continue;
                self.navLink(b, label, m.mountpoint, .drive);
                self.linkMenu(m.mountpoint);
            };
            if (self.shows(.mounts)) for (self.net_mounts, 0..) |m, i| {
                if (self.net_base.len > 0 and std.mem.startsWith(u8, m.mountpoint, self.net_base)) continue; // listed as a remote
                var lbuf: [320]u8 = undefined;
                const label = std.mem.printSentinel(&lbuf, "{s}##net{d}", .{ std.fs.path.basename(m.mountpoint), i }, 0) catch continue;
                self.navLink(b, label, m.mountpoint, .network);
                self.linkMenu(m.mountpoint);
            };
            if (self.shows(.mounts)) for (self.places, 0..) |m, i| {
                if (self.volumeAt(m.mountpoint) or self.fstabAt(m.mountpoint)) continue;
                var lbuf: [320]u8 = undefined;
                const label = std.mem.printSentinel(&lbuf, "{s}##plc{d}", .{ std.fs.path.basename(m.mountpoint), i }, 0) catch continue;
                self.navLink(b, label, m.mountpoint, .drive);
                self.linkMenu(m.mountpoint);
            };
            // rclone remotes: mounted ones open like a folder; others connect on click.
            if (self.shows(.network)) for (self.remotes, 0..) |r, i| self.remoteRow(b, r, i);
            // Finder's Network: the servers around, your own, and Connect to Server.
            if (self.dialog == null and self.shows(.network) and sideItem("Network", self.net_page, .network, false)) self.openNetworkPage(b);
            if (self.dev_msg_len > 0) {
                c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.err());
                c.igPushTextWrapPos(0);
                cimgui.textUnformatted(self.dev_msg[0..self.dev_msg_len]);
                c.igPopTextWrapPos();
                c.igPopStyleColor(1);
                if (c.igSmallButton("Dismiss##devmsg")) self.dev_msg_len = 0;
            }
        }

        // Tags: show only this folder's items with that colour (click again for all).
        if (self.shows(.tags) and self.sideSection("Tags", 2)) {
            for (core.tags.list(), 0..) |col, k| {
                if (self.tags_hide & col.bit() != 0) continue;
                var lb: [48]u8 = undefined;
                const label = std.mem.printSentinel(&lb, "{s}##tagf{d}", .{ col.name(), k }, 0) catch continue;
                const on = b.tag_filter == col.bit();
                if (sideItemTag(label, on, col.color())) b.setTagFilter(if (on) 0 else col.bit());
            }
        }
    }

    /// sideSection draws a Finder-style section title (small grey text) that folds
    /// its section on click, with "Hide"/"Show" on hover. Returns whether it's open.
    fn sideSection(self: *Shell, title: [:0]const u8, idx: usize) bool {
        c.igSpacing();
        const w = c.igGetContentRegionAvail().x;
        const h = c.igGetTextLineHeight();
        const pos = c.igGetCursorScreenPos();
        c.igPushID_Str(title.ptr);
        defer c.igPopID();
        if (c.igInvisibleButton("##sec", cimgui.vec2(w, h), 0)) self.side_open[idx] = !self.side_open[idx];
        const dl = c.igGetWindowDrawList();
        const col = c.igGetColorU32_Vec4(theme.dim());
        c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(pos.x + 4, pos.y), col, title.ptr, null);
        if (c.igIsItemHovered(0)) {
            const hint: [:0]const u8 = if (self.side_open[idx]) "Hide" else "Show";
            const tw = c.igCalcTextSize(hint.ptr, null, false, -1).x;
            c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(pos.x + w - tw - 4, pos.y), col, hint.ptr, null);
        }
        return self.side_open[idx];
    }

    /// dropZone makes the item just submitted a drop destination for `dst_dir`,
    /// covering BOTH kinds of drag: an internal row drag (the ImGui payload) and a
    /// pending external drop from another app (resolved by the position GLFW recorded).
    /// Sidebar places, bookmarks, devices and tab headers all route through here, so a
    /// file dropped on "Documents" or on another tab lands where it was aimed instead of
    /// in whatever folder happened to be on screen.
    ///
    /// The op always runs on the ACTIVE browser's runner: a move empties the folder we
    /// are looking at, so that's the listing that has to refresh.
    fn dropZone(self: *Shell, dst_dir: []const u8) void {
        if (self.dropZoneSpring(dst_dir) and !std.mem.eql(u8, dst_dir, self.activeBrowser().dir))
            self.activeBrowser().navigate(dst_dir) catch {};
    }

    /// dropZoneSpring is dropZone that also reports a drag resting on the item long
    /// enough to open it (spring-loaded), for a caller that opens it its own way.
    fn dropZoneSpring(self: *Shell, dst_dir: []const u8) bool {
        const sprung = self.actions.spring.open(dst_dir);
        self.dropZoneAt(dst_dir);
        return sprung;
    }

    /// dropZoneAt makes the last item a drop target for `dst_dir`: dragged rows move
    /// (Ctrl: copy) there, and files dropped from another app land there. A drag
    /// resting on it opens the folder (spring-loaded), except on a tab (see drawTabs).
    fn dropZoneAt(self: *Shell, dst_dir: []const u8) void {
        const b = self.activeBrowser();
        const rmin = c.igGetItemRectMin();
        const rmax = c.igGetItemRectMax();
        if (c.igBeginDragDropTarget()) {
            const payload = c.igAcceptDragDropPayload(table.DRAG_PAYLOAD, 0);
            if (payload != null and payload.*.Delivery) {
                if (self.actions.dragSource(payload)) |src|
                    b.dropDraggedInto(src.dragPaths(), dst_dir, c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl));
            }
            c.igEndDragDropTarget();
        }
        if (b.pendingDropPos()) |pos| {
            if (pos[0] >= rmin.x and pos[0] <= rmax.x and pos[1] >= rmin.y and pos[1] <= rmax.y)
                b.commitExternalDrop(dst_dir);
        }
    }

    fn dimText(s: []const u8) void {
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
        cimgui.textUnformatted(s);
        c.igPopStyleColor(1);
    }

    fn place(self: *Shell, b: *Browser, label: [:0]const u8, path: []const u8, icon: SideIcon) void {
        self.navLink(b, label, path, icon);
        self.linkMenu(path);
    }
    fn placeSub(self: *Shell, b: *Browser, label: [:0]const u8, sub: []const u8, icon: SideIcon) void {
        var buf: [4200]u8 = undefined;
        const path = std.mem.print(&buf, "{s}/{s}", .{ self.home, sub }) catch return;
        self.place(b, label, path, icon);
    }

    /// navLink is one sidebar entry for `path`: click opens it here, middle-click opens
    /// it in a new background tab (as in Dolphin/Explorer), and it accepts drops. It's
    /// highlighted while it's the folder on screen.
    fn navLink(self: *Shell, b: *Browser, label: [:0]const u8, path: []const u8, icon: SideIcon) void {
        const here = !b.in_recent and std.mem.eql(u8, b.dir, path);
        if (sideItem(label, here, icon, false)) b.navigate(path) catch {};
        if (c.igIsItemClicked(c.ImGuiMouseButton_Middle)) self.newTabAt(path);
        self.dropZone(path);
    }

    /// linkMenu is the right-click menu of a plain sidebar entry.
    fn linkMenu(self: *Shell, path: []const u8) void {
        if (self.dialog != null) return; // the chooser has no tabs
        if (c.igBeginPopupContextItem(null, c.ImGuiPopupFlags_MouseButtonRight)) {
            self.newTabMenuItem(path);
            c.igEndPopup();
        }
    }

    fn newTabMenuItem(self: *Shell, path: []const u8) void {
        if (self.dialog == null and c.igMenuItem_Bool("Open in New Tab", "Middle-click", false, true)) self.newTabAt(path);
    }

    /// newTabAt opens `path` in a new tab without switching to it (the browser only).
    pub fn newTabAt(self: *Shell, path: []const u8) void {
        if (self.dialog != null) return;
        const keep = self.active;
        const keep_b = self.tabBrowser();
        _ = self.openTab(path) orelse return;
        self.active = keep;
        self.select_tab = keep_b; // re-assert the current tab so ImGui doesn't jump
    }

    /// handleMouseNav wires the mouse thumb buttons to history navigation: X1
    /// (button 3) = back, X2 (button 4) = forward. Called in EVERY mode (the browser
    /// and the Save/Open dialog), whereas handleShellKeys (tabs, bookmarks, zoom) is
    /// browser-only, which is why the dialog used to ignore the thumb buttons.
    /// Back uses backOrUp so it climbs to the parent when there's no history yet,
    /// instead of silently doing nothing (the toolbar keeps a dedicated Up button).
    fn handleMouseNav(self: *Shell, b: *Browser) void {
        const back = c.igIsMouseClicked_Bool(3, false);
        const fwd = c.igIsMouseClicked_Bool(4, false);
        // Over Quick Look they step through what it browsed into, not the window
        // behind it (they used to do both).
        if (self.ql_open and self.ql_win.hovered) {
            if (back) self.qlBack();
            if (fwd) self.qlForward();
            return;
        }
        if (back) b.backOrUp();
        if (fwd) b.forward();
    }

    /// handleFocusKeys: Ctrl+L → path bar, Ctrl+F → search box. Separate from
    /// handleShellKeys because that one is browser-only and bails while any widget is
    /// active, so in the Save/Open chooser (where the Name field usually holds focus)
    /// Ctrl+F did nothing at all. Jumping between text fields is exactly what these keys
    /// are for, so only an inline rename (whose Ctrl+F/L are just typing) blocks them.
    fn handleFocusKeys(self: *Shell) void {
        if (!c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl) or self.content.isRenaming() or self.split_view.isRenaming()) return;
        // Plain Ctrl only: Ctrl+Shift+F is Go ▸ Recent and Ctrl+Alt+L Downloads.
        const plain = !c.igIsKeyDown_Nil(c.ImGuiMod_Shift) and !c.igIsKeyDown_Nil(c.ImGuiMod_Alt);
        if (plain and c.igIsKeyPressed_Bool(c.ImGuiKey_L, false)) self.focus_path = true;
        if (plain and c.igIsKeyPressed_Bool(c.ImGuiKey_F, false) and !pdfview.ownsKeys()) self.focus_search = true; // (a PDF in Quick Look finds in itself)
        // Ctrl+1 list, Ctrl+2 icons (Finder's Cmd+1/2), for the focused pane.
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_1, false)) self.activeBrowser().setViewMode(.list);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_2, false)) self.activeBrowser().setViewMode(.grid);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_3, false)) self.activeBrowser().setViewMode(.columns);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_4, false)) self.activeBrowser().setViewMode(.gallery);
        if (self.dialog == null and c.igIsKeyPressed_Bool(c.ImGuiKey_Comma, false)) self.settings_open = true;
    }

    fn handleShellKeys(self: *Shell) void {
        const b = self.activeBrowser();
        if (self.path_active or self.search_active) return;
        // While any widget is being edited (notably the inline-rename text box), let it
        // keep the keyboard. Otherwise Ctrl+Z here would fire the file-op undo instead of
        // the text field's own undo, and Ctrl+C/W/T/… would hijack normal text editing.
        if (c.igIsAnyItemActive()) return;
        const ctrl = c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl);
        const shift = c.igIsKeyDown_Nil(c.ImGuiMod_Shift);
        if (ctrl and shift and c.igIsKeyPressed_Bool(c.ImGuiKey_T, false)) {
            self.reopenClosedTab();
        } else if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_T, false)) self.addTab();
        // Cycle tabs: Ctrl+Tab / Ctrl+Shift+Tab and Ctrl+PgDn / Ctrl+PgUp (browser
        // conventions); Alt+1…9 jumps to a tab (9 = last), as in Dolphin.
        const nt = self.tabs.items.len;
        if (ctrl and (c.igIsKeyPressed_Bool(c.ImGuiKey_Tab, true) and !shift or c.igIsKeyPressed_Bool(c.ImGuiKey_PageDown, true)))
            self.selectTab((self.active + 1) % nt);
        if (ctrl and (c.igIsKeyPressed_Bool(c.ImGuiKey_Tab, true) and shift or c.igIsKeyPressed_Bool(c.ImGuiKey_PageUp, true)))
            self.selectTab((self.active + nt - 1) % nt);
        if (c.igIsKeyDown_Nil(c.ImGuiMod_Alt)) {
            const digits = [_]c.ImGuiKey{ c.ImGuiKey_1, c.ImGuiKey_2, c.ImGuiKey_3, c.ImGuiKey_4, c.ImGuiKey_5, c.ImGuiKey_6, c.ImGuiKey_7, c.ImGuiKey_8, c.ImGuiKey_9 };
            for (digits, 0..) |k, di| {
                if (c.igIsKeyPressed_Bool(k, false)) self.selectTab(if (di == 8) nt - 1 else di);
            }
        }
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_W, false)) {
            // With the split pane focused, Ctrl+W closes that pane, not the tab.
            if (self.split_focus and self.split_b != null) self.toggleSplit() else self.closeTab(self.active);
        }
        const alt_d = c.igIsKeyDown_Nil(c.ImGuiMod_Alt);
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_D, false)) {
            if (alt_d) b.duplicateSelection() else if (shift) self.goHomeSub(b, "Desktop") else self.addBookmark(b.dir);
        }
        // The Go menu's places, Finder's keys with Ctrl for ⌘.
        if (ctrl and shift and c.igIsKeyPressed_Bool(c.ImGuiKey_O, false)) self.goHomeSub(b, "Documents");
        if (ctrl and alt_d and c.igIsKeyPressed_Bool(c.ImGuiKey_L, false)) self.goHomeSub(b, "Downloads");
        if (ctrl and shift and c.igIsKeyPressed_Bool(c.ImGuiKey_H, false)) b.navigate(self.home) catch {};
        if (ctrl and shift and c.igIsKeyPressed_Bool(c.ImGuiKey_C, false)) b.navigate("/") catch {};
        if (ctrl and shift and c.igIsKeyPressed_Bool(c.ImGuiKey_F, false)) b.navigate(core.recent.uri) catch {};
        if (ctrl and shift and c.igIsKeyPressed_Bool(c.ImGuiKey_G, false)) self.focus_path = true;
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_F3, false)) self.toggleSplit();
        if (ctrl and shift and c.igIsKeyPressed_Bool(c.ImGuiKey_P, false)) self.show_preview = !self.show_preview;
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_J, false)) self.view_opts_open = !self.view_opts_open;
        const alt = c.igIsKeyDown_Nil(c.ImGuiMod_Alt);
        if (ctrl and alt and c.igIsKeyPressed_Bool(c.ImGuiKey_S, false)) self.toggleBar(.sidebar);
        if (ctrl and alt and c.igIsKeyPressed_Bool(c.ImGuiKey_P, false)) self.toggleBar(.path_bar);
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_Slash, false)) self.toggleBar(.status_bar);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_F4, false)) b.openTerminalHere();
        if (ctrl and alt and c.igIsKeyPressed_Bool(c.ImGuiKey_N, false)) {
            b.newFolderWithSelection();
        } else if (ctrl and shift and c.igIsKeyPressed_Bool(c.ImGuiKey_N, false)) b.newFolder() else if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_N, false)) self.newWindow(b);
        if (c.igIsKeyDown_Nil(c.ImGuiMod_Alt) and c.igIsKeyPressed_Bool(c.ImGuiKey_UpArrow, false)) self.goEnclosing(b);
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_Z, false)) {
            if (shift) b.redo() else b.undo();
        }
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_Y, false)) b.redo();
        // Finder's other keys (⌘ → Ctrl), where they don't take a Linux habit's place.
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_K, false)) {
            if (shift) self.openNetworkPage(b) else self.connect.open(null);
        }
        if (ctrl and !shift and c.igIsKeyPressed_Bool(c.ImGuiKey_O, false)) b.openCursor() catch {};
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_DownArrow, false)) b.openCursor() catch {};
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_UpArrow, false)) self.goEnclosing(b);
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_LeftBracket, false)) b.backOrUp();
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_RightBracket, false)) b.forward();
        if (ctrl and shift and c.igIsKeyPressed_Bool(c.ImGuiKey_Backspace, false)) self.empty_trash_pending = true;
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_E, false)) self.ejectHere(b);
        if (ctrl and shift and c.igIsKeyPressed_Bool(c.ImGuiKey_Period, false)) b.toggleHidden();
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_M, false)) self.minimize();
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_Q, false)) self.closeWindow();
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_F11, false)) self.toggleFullScreen();
    }

    /// ejectHere ejects (or unmounts, or disconnects) what the folder on screen is on:
    /// Finder's ⌘E. Tabs inside it leave once it's gone.
    fn ejectHere(self: *Shell, b: *Browser) void {
        const d = self.devices orelse return;
        for (self.vols) |v| {
            if (!v.mounted() or std.mem.eql(u8, v.mountpoint, "/") or !isUnder(b.dir, v.mountpoint)) continue;
            if (v.removable) d.eject(v.drive) else d.unmount(v.path, v.mountpoint, v.crypt_parent);
            return;
        }
        for (self.remotes) |r| {
            if (!r.mounted or !isUnder(b.dir, r.mountpoint)) continue;
            for (self.liveBrowsers()) |t| if (isUnder(t.dir, r.mountpoint)) t.navigate(self.home) catch {};
            d.unmountRemote(r.mountpoint);
            return;
        }
    }

    /// toggleFullScreen fills the screen the window is on (F11, Finder's ⌃⌘F), and puts
    /// it back where it was.
    fn toggleFullScreen(self: *Shell) void {
        const w = self.glfwWin() orelse return;
        if (c.glfwGetWindowMonitor(w) != null) {
            const r = self.fs_rect;
            c.glfwSetWindowMonitor(w, null, r[0], r[1], r[2], r[3], 0);
            return;
        }
        c.glfwGetWindowPos(w, &self.fs_rect[0], &self.fs_rect[1]);
        c.glfwGetWindowSize(w, &self.fs_rect[2], &self.fs_rect[3]);
        // The monitor holding the window's middle.
        var n: c_int = 0;
        const mons = c.glfwGetMonitors(&n) orelse return;
        const cx = self.fs_rect[0] + @divFloor(self.fs_rect[2], 2);
        const cy = self.fs_rect[1] + @divFloor(self.fs_rect[3], 2);
        var pick = mons[0];
        for (0..@intCast(n)) |i| {
            const m = mons[i] orelse continue;
            var mx: c_int = 0;
            var my: c_int = 0;
            c.glfwGetMonitorPos(m, &mx, &my);
            const mode = c.glfwGetVideoMode(m) orelse continue;
            if (cx >= mx and cx < mx + mode.*.width and cy >= my and cy < my + mode.*.height) pick = m;
        }
        const mode = c.glfwGetVideoMode(pick) orelse return;
        c.glfwSetWindowMonitor(w, pick, 0, 0, mode.*.width, mode.*.height, mode.*.refreshRate);
    }

    /// handleItemSize is Ctrl+scroll and Ctrl+keypad +/-/0: the size of the items in
    /// the view on screen (as Finder's ⌘+/⌘- and pinch, and Dolphin's Ctrl+scroll).
    /// The top-row +/=/-/0 keys come through gui.zig's layout-aware key callback. The
    /// interface's own size is a setting (Settings ▸ Appearance), not a key.
    fn handleItemSize(self: *Shell, b: *Browser) void {
        if (!c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl)) return;
        // Ctrl+scroll is ours, so nothing under the pointer scrolls with it too.
        c.igSetKeyOwner(c.ImGuiKey_MouseWheelY, c.igGetID_Str("##itemsize"), 0);
        const wheel = cimgui.zfd_mouse_wheel();
        if (wheel != 0) self.sizeItems(b, std.math.pow(f32, 1.1, wheel));
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_KeypadAdd, true)) self.sizeItems(b, 1.1);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_KeypadSubtract, true)) self.sizeItems(b, 1.0 / 1.1);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Keypad0, false)) self.sizeItems(b, null);
    }

    /// sizeItems scales the item size of `b`'s view by `factor` (null: back to the
    /// default), within its range.
    pub fn sizeItems(self: *Shell, b: *Browser, factor: ?f32) void {
        const s = self.actions.itemSize(b.view_mode);
        s.v.* = if (factor) |f| std.math.clamp(s.v.* * f, s.min, s.max) else 1;
    }

    fn addTab(self: *Shell) void {
        _ = self.openTab(self.activeBrowser().location());
    }

    /// openTab appends a tab at `dir` and selects it. Returns the new browser (null on
    /// failure). Used by Ctrl+T / "+" and by a tab dragged in from another window.
    pub fn openTab(self: *Shell, dir: []const u8) ?*Browser {
        const src = self.activeBrowser();
        const b = Browser.init(self.alloc, self.io, dir, self.trash_home, self.home) catch return null;
        b.shareClipboard(self.clipboard);
        // Inherit the active tab's view prefs so the (global) sort mode is consistent
        // across tabs; otherwise a new tab silently reverts to Browser.init's default
        // (name ascending) and it looks like the sort was forgotten. Takes effect when
        // the async listing arrives and rebuildView runs.
        b.prefs = self.prefs;
        b.temp_files = self.temp_files;
        b.applyFolderView();
        b.search_ci = src.search_ci;
        b.archive_tool = core.archive.findTool(self.io, self.alloc); // per-tab (owned); null hides the menu
        self.tabs.append(self.alloc, b) catch {
            b.deinit();
            return null;
        };
        self.active = self.tabs.items.len - 1;
        // ImGui owns which tab is selected; without SetSelected it kept the old one and
        // the tab bar dragged `active` straight back to it next frame.
        self.select_tab = b;
        return b;
    }
    fn closeTab(self: *Shell, idx: usize) void {
        if (idx >= self.tabs.items.len) return;
        // Closing the last tab closes the window, as in browsers and Dolphin (it used to
        // silently do nothing: the tab's X, Ctrl+W and middle-click all looked broken).
        if (self.tabs.items.len == 1) return self.closeWindow();
        const b = self.tabs.orderedRemove(idx);
        self.rememberClosed(b.location());
        if (self.tab_drag == b) self.tab_drag = null;
        if (self.select_tab == b) self.select_tab = null;
        self.letGoLater(b);
        // Keep `active` on the same tab when one before it goes away, and tell ImGui;
        // it would otherwise leave no tab selected when the selected one disappears.
        if (idx < self.active) self.active -= 1;
        if (self.active >= self.tabs.items.len) self.active = self.tabs.items.len - 1;
        self.select_tab = self.tabs.items[self.active];
    }

    /// letGoLater frees a closed tab or pane next frame, or, while it's still copying or
    /// moving, once that's done: closing a tab doesn't stop its operations.
    fn letGoLater(self: *Shell, b: *Browser) void {
        if (b.opsBusy()) {
            if (self.finishing_tabs.append(self.alloc, b)) |_| return else |_| {}
        }
        self.dying_tabs.append(self.alloc, b) catch b.letGo();
    }

    /// reapFinishingTabs lets go of the closed tabs whose operations are done.
    fn reapFinishingTabs(self: *Shell) void {
        var i: usize = 0;
        while (i < self.finishing_tabs.items.len) {
            const b = self.finishing_tabs.items[i];
            if (b.opsBusy()) {
                i += 1;
                continue;
            }
            _ = self.finishing_tabs.swapRemove(i);
            self.dying_tabs.append(self.alloc, b) catch b.letGo();
        }
    }

    /// opBrowsers is every browser whose operations count: the live ones and the
    /// closed tabs still finishing theirs.
    fn opBrowsers(self: *Shell) []const *Browser {
        const live = self.liveBrowsers();
        var n = live.len;
        for (self.finishing_tabs.items) |b| {
            if (n == self.live_buf.len) break;
            self.live_buf[n] = b;
            n += 1;
        }
        return self.live_buf[0..n];
    }

    /// opsRunning reports whether any copy, move, delete… is still going (or queued).
    pub fn opsRunning(self: *Shell) bool {
        for (self.opBrowsers()) |b| if (b.opsBusy()) return true;
        return false;
    }

    /// stopAll stops every operation (Stop All; closing the finishing window).
    pub fn stopAll(self: *Shell) void {
        for (self.opBrowsers()) |b| b.cancelAllOps();
    }

    /// finishInBackground turns the window, closed while operations run, into a
    /// small one showing just their progress (as Dolphin keeps its copy going after
    /// you close it); gui.run quits once they're done.
    pub fn finishInBackground(self: *Shell) void {
        self.finishing = true;
        self.progress_open = false;
        self.ql_open = false;
        self.finishing_h = 0;
        self.min_size = .{ 0, 0 };
        c.glfwSetWindowSizeLimits(self.glfwWin(), c.GLFW_DONT_CARE, c.GLFW_DONT_CARE, c.GLFW_DONT_CARE, c.GLFW_DONT_CARE);
        if (c.glfwGetWindowAttrib(self.glfwWin(), c.GLFW_MAXIMIZED) != 0) c.glfwRestoreWindow(self.glfwWin());
        c.glfwSetWindowTitle(self.glfwWin(), "ZFD: finishing");
    }

    /// drawFinishing is that window: what's still going, each with its bar and
    /// Cancel, and Stop All. It sizes itself to them.
    fn drawFinishing(self: *Shell) void {
        const fs = c.igGetFontSize();
        const pad = @round(fs * 0.9);
        var n: usize = 0;
        var nb: [512]u8 = undefined;
        for (self.opBrowsers()) |b| for (0..b.opLanes()) |lane| {
            if (b.opProgress(lane, &nb).active()) n += 1;
        };
        var tb: [64]u8 = undefined;
        const title = if (n == 1) "Finishing 1 operation" else std.mem.print(&tb, "Finishing {d} operations", .{n}) catch "Finishing";
        const wp = c.igGetWindowPos();
        if (self.csd) {
            c.igSetCursorScreenPos(cimgui.vec2(wp.x + pad, wp.y + 2));
            self.drawCsdTitleRow(title);
        }
        c.igSetCursorScreenPos(cimgui.vec2(wp.x + pad, c.igGetCursorScreenPos().y + (if (self.csd) fs * 0.3 else pad)));
        c.igBeginGroup();
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
        cimgui.textUnformatted("ZFD closes once these are done.");
        c.igPopStyleColor(1);
        c.igSpacing();
        c.igSpacing();
        self.drawOpsRows();
        c.igSpacing();
        if (c.igButton("Stop All", cimgui.vec2(0, 0))) self.stopAll();
        c.igEndGroup();
        // Fit the window to what's in it (rows come and go).
        const bottom = c.igGetItemRectMax().y - wp.y + pad;
        const want_w: c_int = @intFromFloat(@round(fs * 22 + fs * 6 + pad * 2));
        const want_h: c_int = @intFromFloat(@round(bottom));
        if (want_h != self.finishing_h) {
            self.finishing_h = want_h;
            c.glfwSetWindowSize(self.glfwWin(), want_w, want_h);
        }
        c.igDummy(cimgui.vec2(0, 0));
    }

    fn freeDyingTabs(self: *Shell) void {
        for (self.dying_tabs.items) |b| b.letGo(); // (a slow folder's read isn't waited for)
        self.dying_tabs.clearRetainingCapacity();
    }

    /// rememberClosed keeps a closed tab's folder for Ctrl+Shift+T (last 16).
    fn rememberClosed(self: *Shell, dir: []const u8) void {
        const d = self.alloc.dupe(u8, dir) catch return;
        if (self.closed_tabs.items.len >= 16) self.alloc.free(self.closed_tabs.orderedRemove(0));
        self.closed_tabs.append(self.alloc, d) catch self.alloc.free(d);
    }

    /// reopenClosedTab brings back the most recently closed tab (Ctrl+Shift+T).
    fn reopenClosedTab(self: *Shell) void {
        const d = self.closed_tabs.pop() orelse return;
        defer self.alloc.free(d);
        _ = self.openTab(d);
    }

    /// selectTab switches to tab `idx` (keyboard tab switching, the tab menu).
    fn selectTab(self: *Shell, idx: usize) void {
        if (idx >= self.tabs.items.len) return;
        self.active = idx;
        self.select_tab = self.tabs.items[idx];
    }

    /// closeOtherTabs closes every tab except `keep`; with `only_right`, just the ones
    /// to its right.
    fn closeOtherTabs(self: *Shell, keep: *Browser, only_right: bool) void {
        var i: usize = self.tabs.items.len;
        while (i > 0) {
            i -= 1;
            const t = self.tabs.items[i];
            if (t == keep) {
                if (only_right) break;
                continue;
            }
            self.closeTab(i);
        }
        if (self.tabIndex(keep)) |k| self.selectTab(k);
    }

    /// tabMenu is a tab header's right-click menu.
    fn tabMenu(self: *Shell, b: *Browser) void {
        if (!c.igBeginPopupContextItem(null, c.ImGuiPopupFlags_MouseButtonRight)) return;
        defer c.igEndPopup();
        const idx = self.tabIndex(b) orelse return;
        const n = self.tabs.items.len;
        if (c.igMenuItem_Bool("New Tab", "Ctrl+T", false, true)) _ = self.openTab(b.location());
        if (c.igMenuItem_Bool("Duplicate Tab", null, false, true)) {
            if (self.openTab(b.location())) |nb| {
                nb.prefs = self.prefs;
                nb.temp_files = self.temp_files;
                nb.applyFolderView();
            }
        }
        if (c.igMenuItem_Bool("Reopen Closed Tab", "Ctrl+Shift+T", false, self.closed_tabs.items.len > 0)) self.reopenClosedTab();
        c.igSeparator();
        if (c.igMenuItem_Bool(if (n > 1) "Close Tab" else "Close Window", "Ctrl+W", false, true)) self.closeTab(idx);
        if (c.igMenuItem_Bool("Close Other Tabs", null, false, n > 1)) self.closeOtherTabs(b, false);
        if (c.igMenuItem_Bool("Close Tabs to the Right", null, false, idx + 1 < n)) self.closeOtherTabs(b, true);
    }

    fn tabIndex(self: *Shell, b: *Browser) ?usize {
        for (self.tabs.items, 0..) |t, i| {
            if (t == b) return i;
        }
        return null;
    }

    /// tearOffTab handles a tab header released outside the window, Chrome-style: over
    /// another ZFD window the tab moves there; anywhere else it becomes a new window at
    /// the pointer. The lone tab of a window can only merge (detaching it would just be
    /// the same window again), and then this window closes, like Chrome.
    fn tearOffTab(self: *Shell, b: *Browser) void {
        const idx = self.tabIndex(b) orelse return;
        if (x11.zfdWindowUnderPointer(self.win)) |target| {
            x11.sendTab(target, b.dir);
            if (self.tabs.items.len == 1) self.closeWindow() else self.closeTab(idx);
            return;
        }
        if (self.tabs.items.len == 1) return;
        const pos = x11.pointerRoot(self.win) orelse return;
        if (!self.spawnWindow(b.dir, pos)) return;
        self.closeTab(idx);
    }

    /// moveTabToNewWindow opens the current tab in a window of its own, a little below
    /// and right of this one (Window > Move Tab to New Window).
    fn moveTabToNewWindow(self: *Shell) void {
        if (self.tabs.items.len < 2) return;
        const b = self.tabBrowser();
        const idx = self.tabIndex(b) orelse return;
        var wx: c_int = 0;
        var wy: c_int = 0;
        c.glfwGetWindowPos(self.glfwWin(), &wx, &wy);
        if (!self.spawnWindow(b.dir, .{ wx + 120, wy + 80 })) return;
        self.closeTab(idx);
    }

    /// spawnWindow launches a detached `zfd --pos X,Y <dir>`: a torn-off tab's window,
    /// placed so its tab strip lands under the pointer.
    fn spawnWindow(self: *Shell, dir: []const u8, pos: [2]i32) bool {
        const exe = std.process.executablePathAlloc(self.io, self.alloc) catch return false;
        defer self.alloc.free(exe);
        var pbuf: [48]u8 = undefined;
        const ps = std.mem.print(&pbuf, "{d},{d}", .{ pos[0] - 60, pos[1] - 12 }) catch return false;
        var child = std.process.spawn(self.io, .{ .argv = &.{ exe, "--detach", "--pos", ps, dir } }) catch return false;
        _ = child.wait(self.io) catch {}; // --detach forks away at once; this reaps the stub
        return true;
    }

    /// drawShareMenu is the toolbar's Share menu for the selection: copy the paths, or
    /// hand the files to the mail client or a phone (KDE Connect) when installed.
    fn drawShareMenu(self: *Shell, b: *Browser) void {
        const paths = b.selectedPaths() catch return;
        defer {
            for (paths) |p| self.alloc.free(p);
            self.alloc.free(paths);
        }
        if (paths.len == 0) return;
        if (c.igMenuItem_Bool(if (paths.len == 1) "Copy Path" else "Copy Paths", null, false, true)) {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(self.alloc);
            for (paths, 0..) |p, i| {
                if (i > 0) out.append(self.alloc, '\n') catch {};
                out.appendSlice(self.alloc, p) catch {};
            }
            out.append(self.alloc, 0) catch {};
            if (out.items.len > 0) c.igSetClipboardText(@ptrCast(out.items.ptr));
        }
        const mail = core.fsops.pathExists(self.io, "/usr/bin/xdg-email");
        if (c.igMenuItem_Bool("Email\u{2026}", null, false, mail)) {
            var argv = std.ArrayList([]const u8).empty;
            defer argv.deinit(self.alloc);
            argv.append(self.alloc, "xdg-email") catch return;
            for (paths) |p| {
                argv.append(self.alloc, "--attach") catch return;
                argv.append(self.alloc, p) catch return;
            }
            core.fsops.launch(self.io, self.alloc, argv.items, null);
        }
        if (core.fsops.pathExists(self.io, "/usr/bin/kdeconnect-handler")) {
            if (c.igMenuItem_Bool("Send to a Device (KDE Connect)\u{2026}", null, false, true)) {
                for (paths) |p| core.fsops.launch(self.io, self.alloc, &.{ "kdeconnect-handler", p }, null);
            }
        }
    }

    /// mergeInto answers Merge All Windows from another ZFD window: every tab moves
    /// there and this window closes. A window still copying or deleting keeps its tabs
    /// (closing would stop the work).
    pub fn mergeInto(self: *Shell, target: x11.x.Window) void {
        for (self.tabs.items) |b| {
            for (0..b.opLanes()) |lane| {
                var nb: [512]u8 = undefined;
                if (b.opProgress(lane, &nb).active()) return;
            }
        }
        for (self.tabs.items) |b| x11.sendTab(target, b.location());
        self.closeWindow();
    }

    /// adoptTabs opens the tabs another ZFD window handed us (newline-separated dirs)
    /// and raises the window.
    pub fn adoptTabs(self: *Shell, list: []const u8) void {
        var it = std.mem.splitScalar(u8, list, '\n');
        var any = false;
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            if (self.openTab(dir) != null) any = true;
        }
        if (any) c.glfwFocusWindow(self.glfwWin());
    }

    /// drawTitleRow puts the tab strip and (under CSD) the window buttons on one
    /// row, with a draggable gap between them.
    fn drawTitleRow(self: *Shell) void {
        const h = c.igGetFrameHeight();
        // Like Finder, the tab strip only shows once there's more than one tab (Ctrl+T
        // or File > New Tab adds one). Tabs dragged in from other windows still land.
        const show_tabs = self.tabs.items.len > 1 or self.tab_drag != null;
        if (!self.csd) {
            if (show_tabs) self.drawTabs();
            return;
        }
        // The window buttons sit on the menu bar; with it shown and no tabs, there's
        // nothing for this row to carry.
        if (!show_tabs and self.menu_bar) return;
        const sp = c.igGetStyle().*.ItemSpacing.x;
        const row_top = c.igGetCursorScreenPos();
        const full_w = c.igGetContentRegionAvail().x;
        // The window buttons live on the menu bar; with it hidden, at this row's end.
        const buttons_w: f32 = if (self.menu_bar) 0 else windowButtonsWidth();

        const tabs_w = @max(full_w - buttons_w - sp * 2, 60);
        _ = c.igBeginChild_Str("##tabbar", cimgui.vec2(tabs_w, h + sp), 0, c.ImGuiWindowFlags_NoScrollbar);
        if (show_tabs) self.drawTabs();
        c.igEndChild();
        if (!self.menu_bar) {
            c.igSameLine(0, 0);
            c.igSetCursorScreenPos(cimgui.vec2(row_top.x + full_w - buttons_w, row_top.y));
            self.drawWindowButtons(h);
        }

        // Drag the empty part of the titlebar: clip-independent hit-test, exactly like
        // the resize grips (which work). !IsAnyItemHovered ⇒ we only move when the click
        // is on blank titlebar, not on a tab or a window button.
        self.dragZone(row_top, cimgui.vec2(row_top.x + full_w - buttons_w, row_top.y + h));
    }

    fn drawTabs(self: *Shell) void {
        if (!c.igBeginTabBar("##tabs", c.ImGuiTabBarFlags_Reorderable)) return;
        defer c.igEndTabBar();
        var close_tab: ?*Browser = null;
        var held: ?*Browser = null;
        var spring_tab: ?*Browser = null;
        const forcing = self.select_tab != null;
        var i: usize = 0;
        while (i < self.tabs.items.len) : (i += 1) {
            const b = self.tabs.items[i];
            const base = if (b.in_recent) "Recent" else std.fs.path.basename(b.dir);
            var lbl_buf: [300]u8 = undefined;
            // "###" + the browser's address: the tab's ImGui ID is its IDENTITY, not its
            // label. It used to be "<folder>##<index>", and "##" hashes the visible part
            // too, so entering a folder (or mouse back/forward) renamed the tab into a
            // brand-new one, ImGui lost the selected tab and fell back to the first.
            const label = std.mem.printSentinel(&lbl_buf, "{s}###tab{x}", .{ if (base.len > 0) base else "/", @intFromPtr(b) }, 0) catch continue;
            var open = true;
            const flags: c_int = if (self.select_tab == b) c.ImGuiTabItemFlags_SetSelected else 0;
            if (c.igBeginTabItem(label.ptr, &open, flags)) {
                // SetSelected lands next frame; until then ImGui still reports the old tab,
                // which must not overwrite the choice we just made.
                if (!forcing) self.active = i;
                c.igEndTabItem();
            }
            if (c.igIsItemActive()) held = b;
            // Middle-click a tab header closes it (browser convention).
            if (c.igIsItemClicked(c.ImGuiMouseButton_Middle)) close_tab = b;
            self.tabMenu(b);
            // Drop onto a tab header → into that tab's folder. Reading b.dir here is safe
            // even for the active tab: dropDraggedInto skips items already in dst_dir, so
            // dropping on your own tab is a no-op rather than a self-move.
            // Resting a drag on a tab switches to it, so you can drop into its folder.
            if (self.dropZoneSpring(b.dir)) spring_tab = b;
            if (!open) close_tab = b;
        }
        self.select_tab = spring_tab; // selected next frame (null: nothing pending)
        if (c.igTabItemButton("+", c.ImGuiTabItemFlags_Trailing)) self.addTab();

        // Tear-off: remember the held tab; on the frame it is let go outside the window,
        // detach it (a tab released inside just reorders, which ImGui already did).
        if (held) |h| {
            self.tab_drag = h;
        } else if (self.tab_drag) |t| {
            self.tab_drag = null;
            if (c.igIsMouseReleased_Nil(0) and self.mouseOutside()) self.tearOffTab(t);
        }
        if (close_tab) |ct| if (self.tabIndex(ct)) |ci| self.closeTab(ci);
    }

    /// drawDialogTitleRow is the CSD titlebar for the Save/Open chooser: the dialog title
    /// on the left, the window buttons pinned right, and a draggable gap between; no tab
    /// strip (a chooser is single-folder). Mirrors drawTitleRow's right-side buttons and
    /// drag hit-test; only called when csd is on and a dialog is active.
    fn drawDialogTitleRow(self: *Shell) void {
        const cfg = (self.dialog orelse return).cfg;
        self.drawCsdTitleRow(dialogTitleText(cfg));
    }

    /// drawCsdTitleRow is a borderless window's title bar: `title` on the left, the
    /// window buttons on the right, and the space between moves the window.
    fn drawCsdTitleRow(self: *Shell, title: []const u8) void {
        const h = c.igGetFrameHeight();
        const row_top = c.igGetCursorScreenPos();
        const full_w = c.igGetContentRegionAvail().x - 4; // the buttons stay off the corner
        const buttons_w = if (self.finishing) windowButtonWidth() * 2 else windowButtonsWidth();
        c.igAlignTextToFramePadding();
        var tb: [320]u8 = undefined;
        cimgui.textUnformatted(ellipsize(&tb, title, @max(full_w - buttons_w - c.igGetFontSize(), 20)));
        // The buttons go by absolute position, leaving the middle empty for dragging.
        c.igSameLine(0, 0);
        c.igSetCursorScreenPos(cimgui.vec2(row_top.x + full_w - buttons_w, row_top.y));
        self.drawWindowButtons(h);
        self.dragZone(row_top, cimgui.vec2(row_top.x + full_w - buttons_w, row_top.y + h));
    }

    fn drawToolbar(self: *Shell, b: *Browser) void {
        // Finder's toolbar: back/forward, the folder's name, the view switch and the
        // actions menu, then (right-aligned) the operations ring and the search field. The path bar lives at
        // the bottom (drawBottomBar).
        const h = toolbarH();
        c.igDummy(cimgui.vec2(0, @round(c.igGetFontSize() * 0.25))); // Finder's roomy band
        const fs = c.igGetFontSize();
        // Back = history back, or climb to the parent when there's no history to go back
        // to (Up is folded in; no separate button). Forward re-descends. Disabled only
        // at the filesystem root with no history, where there's genuinely nowhere to go.
        if (toolButton("##back", .back, self.net_page or b.canBackOrUp(), false, "Back (Alt+Left)")) {
            if (self.net_page) self.closeNetworkPage() else b.backOrUp();
        }
        c.igSameLine(0, 2);
        if (toolButton("##fwd", .forward, b.canForward(), false, "Forward (Alt+Right)")) b.forward();
        c.igSameLine(0, fs * 0.8);

        const ops = self.opsSummary();
        const ops_w: f32 = if (ops.count > 0) @round(h * 1.25) + 10 else 0;
        const searching = self.search_buf[0] != 0 or b.deep;
        // Search sits open while it's wanted or in use, else folds into its button.
        if (self.focus_search) self.search_open = true; // Ctrl+F opens it too
        const search_open = self.search_open or self.search_active or searching or self.search_buf[0] != 0;
        // Like Finder: the free space follows the title, then the right-hand items you
        // chose (View > Customize Toolbar), single buttons side by side sharing a pill.
        const bw = @round(h * 1.25);
        const gpad: f32 = 2;
        const ggap = @round(fs * 0.6);
        const gap = fs * 0.8;
        const sw = anim.value(c.igGetID_Str("##searchw"), if (search_open) @round(fs * 13) else bw, anim.normal, .out_cubic);
        const items = self.toolbar_items[0..self.toolbar_len];
        var right_w: f32 = ops_w;
        {
            var k: usize = 0;
            var groups: usize = 0;
            while (k < items.len) {
                const n = groupLen(items[k..]);
                right_w += groupWidth(items[k .. k + n], bw, sw, gpad);
                groups += 1;
                k += n;
            }
            if (groups > 1) right_w += @as(f32, @floatFromInt(groups - 1)) * ggap;
        }
        const avail = c.igGetContentRegionAvail().x;
        const right_x = c.igGetCursorPosX() + avail - right_w;

        // The folder's name: click it for the enclosing folders. A typed path goes in
        // the path bar at the bottom; only with that bar hidden does it take this spot.
        if (self.path_edit and !self.showsBar(.path_bar)) {
            self.drawPathField(b, right_w + gap);
        } else {
            self.drawTitle(b, @max(avail - right_w - gap, 40));
        }
        // Right-click the toolbar's empty space to customize it.
        if (c.igIsWindowHovered(0) and !c.igIsAnyItemHovered() and c.igIsMouseClicked_Bool(c.ImGuiMouseButton_Right, false)) c.igOpenPopup_Str("##toolbarctx", 0);
        if (c.igBeginPopup("##toolbarctx", 0)) {
            if (c.igMenuItem_Bool("Customize Toolbar\u{2026}", null, false, true)) self.customize_open = true;
            c.igEndPopup();
        }

        // Right-aligned groups.
        c.igSameLine(right_x, 0);
        if (ops.count > 0) {
            self.drawOpsButton(ops);
            c.igSameLine(0, 10);
        }
        var k: usize = 0;
        var first = true;
        while (k < items.len) {
            const n = groupLen(items[k..]);
            if (!first) c.igSameLine(0, ggap);
            first = false;
            const grp = items[k .. k + n];
            if (grp[0] == .search) {
                self.drawSearchField(b, sw, search_open, bw);
            } else {
                toolGroup(groupWidth(grp, bw, sw, gpad), gpad);
                for (grp, 0..) |it, j| {
                    if (j > 0) c.igSameLine(0, 0);
                    self.toolItem(b, it, bw);
                }
                c.igSameLine(0, gpad); // to the pill's end
                c.igDummy(cimgui.vec2(0, h));
            }
            k += n;
        }
    }

    /// toolItem draws one of the toolbar's buttons (the view switch is four).
    fn toolItem(self: *Shell, b: *Browser, it: ToolItem, bw: f32) void {
        const has_sel = b.sel.count() > 0 and !b.loading;
        const has_cursor = b.count() > 0 and b.sel.cursor < b.count() and !b.loading;
        switch (it) {
            .view => {
                if (toolButton("##vlist", .view_list, true, b.view_mode == .list, "as List (Ctrl+1)")) b.setViewMode(.list);
                c.igSameLine(0, 0);
                if (toolButton("##vgrid", .view_grid, true, b.view_mode == .grid, "as Icons (Ctrl+2)")) b.setViewMode(.grid);
                c.igSameLine(0, 0);
                if (toolButton("##vcols", .view_columns, true, b.view_mode == .columns, "as Columns (Ctrl+3)")) b.setViewMode(.columns);
                c.igSameLine(0, 0);
                if (toolButton("##vgallery", .view_gallery, true, b.view_mode == .gallery, "as Gallery (Ctrl+4)")) b.setViewMode(.gallery);
            },
            .sort => {
                if (toolButtonW("##sort", .sort, @round(bw * 1.4), true, false, "Sort items by")) c.igOpenPopup_Str("##sortmenu", 0);
                if (c.igBeginPopup("##sortmenu", 0)) {
                    drawSortMenu(b);
                    c.igEndPopup();
                }
            },
            .share => {
                if (toolButton("##share", .share, has_sel, false, "Share")) c.igOpenPopup_Str("##sharemenu", 0);
                if (c.igBeginPopup("##sharemenu", 0)) {
                    self.drawShareMenu(b);
                    c.igEndPopup();
                }
            },
            .tags => {
                if (toolButton("##tags", .tag, has_sel and !b.virtualView(), false, "Tags")) c.igOpenPopup_Str("##tagmenu", 0);
                if (c.igBeginPopup("##tagmenu", 0)) {
                    drawTagMenu(b);
                    c.igEndPopup();
                }
            },
            .actions => {
                // "…" is Finder's Action menu: the right-click menu for what's selected,
                // or the folder's own actions when nothing is.
                if (toolButton("##actions", .more, true, false, "Actions")) c.igOpenPopup_Str("##actionmenu", 0);
                if (c.igBeginPopup("##actionmenu", 0)) {
                    if (selectedIndex(b)) |i| self.actions.rowMenu(b, i) else table.folderItems(b);
                    c.igSeparator();
                    if (c.igMenuItem_Bool("Show View Options", "Ctrl+J", self.view_opts_open, true)) self.view_opts_open = !self.view_opts_open;
                    if (c.igMenuItem_Bool("Customize Toolbar\u{2026}", null, false, true)) self.customize_open = true;
                    c.igEndPopup();
                }
            },
            .new_folder => if (toolButton("##newfolder", .new_folder, !b.virtualView(), false, "New Folder (Ctrl+Shift+N)")) b.newFolder(),
            .trash => if (toolButton("##trash", .trash, has_sel and !b.virtualView(), false, "Move to Trash (Del)")) b.trashSelection(),
            .get_info => if (toolButton("##info", .info, has_cursor, false, "Get Info (Alt+Enter)")) self.actions.openProperties(b, b.sel.cursor),
            .quicklook => if (toolButton("##ql", .eye, has_cursor, self.ql_open, "Quick Look (Space)")) {
                self.actions.quicklook_toggle = true;
            },
            .preview => if (toolButton("##pvpane", .preview_pane, true, self.show_preview, "Show Preview (Ctrl+Shift+P)")) {
                self.show_preview = !self.show_preview;
            },
            .terminal => if (toolButton("##term", .terminal, !b.virtualView(), false, "Open Terminal Here (F4)")) b.openTerminalHere(),
            .search => {},
        }
    }

    /// drawSearchField is the toolbar's search: a magnifier button that widens into the
    /// field (`sw` wide, animated) while it's wanted.
    fn drawSearchField(self: *Shell, b: *Browser, sw: f32, search_open: bool, bw: f32) void {
        const h = toolbarH();
        if (!self.search_active) self.syncSearch(b);
        // Collapsed, search is a magnifier; it widens into the field (sw, animated).
        if (!search_open and sw <= bw + 0.5) {
            if (toolButton("##searchbtn", .search, true, false, "Search (Ctrl+F)")) {
                self.search_open = true;
                self.focus_search = true;
            }
            return;
        }
        if (self.focus_search) {
            c.igSetKeyboardFocusHere(0); // Ctrl+F: focus (and select-all) the search box
            self.focus_search = false;
        }
        // The field, with the magnifier drawn inside on its left.
        const glyph = @round(h * 0.42);
        const pad = c.igGetStyle().*.FramePadding;
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_FramePadding, cimgui.vec2(pad.x * 1.5 + glyph, @round((h - c.igGetFontSize()) * 0.5)));
        c.igPushStyleVar_Float(c.ImGuiStyleVar_FrameRounding, @round(h * 0.3));
        c.igSetNextItemWidth(sw);
        c.igSetNextItemAllowOverlap(); // the clear button sits on its right end
        var changed = c.igInputTextWithHint("##search", "Search", &self.search_buf, self.search_buf.len, 0, null, null);
        c.igPopStyleVar(2);
        self.search_active = c.igIsItemActive();
        const empty_escape = self.search_active and self.search_buf[0] == 0 and c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false);
        if (c.igBeginItemTooltip()) {
            cimgui.textUnformatted("Filter by name; * and ? are wildcards (e.g. *.txt).\nkind:image (or movie, music, document, pdf, archive, folder, code) and tag:red narrow it.\nAfter a $, text to find inside the files: *.md$TODO (\\$ for a $ in a name).");
            c.igEndTooltip();
        }
        const fmin = c.igGetItemRectMin();
        const fmax = c.igGetItemRectMax();
        const dl = c.igGetWindowDrawList();
        drawMagnifier(dl, fmin.x + pad.x, fmin.y + (h - glyph) * 0.5, glyph, c.igGetColorU32_Vec4(theme.dim()));
        // It stays open until its clear button (✕) is clicked, which also ends the
        // search, or Escape in an empty field.
        const xs = @round(h * 0.62);
        if (sw > xs * 3) {
            c.igSetCursorScreenPos(cimgui.vec2(fmax.x - xs - pad.x * 0.5, fmin.y + (h - xs) * 0.5));
            const hide = c.igInvisibleButton("##searchhide", cimgui.vec2(xs, xs), 0);
            const hov = c.igIsItemHovered(0);
            if (hov) c.igSetTooltip("Clear and hide");
            const ctr = cimgui.vec2(fmax.x - xs * 0.5 - pad.x * 0.5, fmin.y + h * 0.5);
            c.ImDrawList_AddCircleFilled(dl, ctr, xs * 0.42, c.igGetColorU32_Vec4(if (hov) theme.text() else theme.dim()), 16);
            const g = xs * 0.17;
            const bg = c.igGetColorU32_Col(c.ImGuiCol_FrameBg, 1);
            c.ImDrawList_AddLine(dl, cimgui.vec2(ctr.x - g, ctr.y - g), cimgui.vec2(ctr.x + g, ctr.y + g), bg, 1.6);
            c.ImDrawList_AddLine(dl, cimgui.vec2(ctr.x - g, ctr.y + g), cimgui.vec2(ctr.x + g, ctr.y - g), bg, 1.6);
            if (hide) {
                self.search_buf[0] = 0;
                changed = true;
                if (b.deep) b.setDeep(false);
                self.search_open = false;
            }
            // The button was placed inside the field: end the row at the field's full
            // height again, or what follows would start too high.
            c.igSetCursorScreenPos(cimgui.vec2(fmax.x, fmin.y));
            c.igDummy(cimgui.vec2(0, fmax.y - fmin.y));
        }
        if (empty_escape) self.search_open = false;
        if (changed) b.setSearch(std.mem.sliceTo(&self.search_buf, 0));
    }

    /// drawSearchScope is Finder's search bar under the toolbar while searching: where
    /// to look (this folder, its subfolders too, or your whole home), a Kind filter
    /// (it writes a kind: word into the query), and Save, which keeps the search in the
    /// sidebar. Looking further than this folder walks the disk, so it's opt-in and
    /// stops when you leave.
    fn drawSearchScope(self: *Shell, b: *Browser) void {
        const fs = c.igGetFontSize();
        c.igAlignTextToFramePadding();
        dimText("Search:");
        c.igSameLine(0, fs * 0.6);
        const in_home = std.mem.eql(u8, b.dir, self.home);
        var nb: [300]u8 = undefined;
        const here_name = if (b.in_recent) "Recent" else if (std.mem.eql(u8, b.dir, "/")) "Computer" else std.fs.path.basename(b.dir);
        const here = std.mem.printSentinel(&nb, "\"{s}\"##scope0", .{here_name}, 0) catch "This Folder##scope0";
        if (viewButton(here, !b.deep)) b.setDeep(false);
        c.igSameLine(0, 2);
        if (viewButton("And Subfolders##scope1", b.deep and !(in_home and self.scope_home))) {
            self.scope_home = false;
            b.setDeep(true);
        }
        c.igSameLine(0, 2);
        if (viewButton("Home##scope2", b.deep and in_home and self.scope_home)) {
            // Search the whole home folder: go there and search it, subfolders too.
            var qb: [512]u8 = undefined;
            const q = std.mem.print(&qb, "{s}", .{b.search.items}) catch "";
            if (!in_home) b.navigate(self.home) catch {};
            b.setSearch(q);
            b.setDeep(true);
            self.scope_home = true;
        }
        if (c.igBeginItemTooltip()) {
            cimgui.textUnformatted("Your whole home folder and everything in it (slower).");
            c.igEndTooltip();
        }

        // Kind: rewrites the query's kind: word.
        c.igSameLine(0, fs * 1.2);
        c.igAlignTextToFramePadding();
        dimText("Kind:");
        c.igSameLine(0, -1);
        const kinds = [_]struct { []const u8, [:0]const u8 }{
            .{ "", "Any" },             .{ "folder", "Folders" },     .{ "image", "Images" }, .{ "movie", "Movies" },
            .{ "music", "Music" },      .{ "document", "Documents" }, .{ "pdf", "PDFs" },     .{ "archive", "Archives" },
            .{ "code", "Source Code" },
        };
        var qbuf: [512]u8 = undefined;
        const parsed = core.query.parse(b.search.items, &qbuf);
        var cur: usize = 0;
        if (parsed.kind) |pk| for (kinds[1..], 1..) |k, i| {
            if (core.query.kindNamed(k[0]) == pk) cur = i;
        };
        c.igSetNextItemWidth(fs * 8);
        if (c.igBeginCombo("##kind", kinds[cur][1].ptr, 0)) {
            for (kinds, 0..) |k, i| if (c.igSelectable_Bool(k[1].ptr, i == cur, 0, cimgui.vec2(0, 0))) {
                // Keep every other word, then add the new kind.
                var out = std.ArrayList(u8).empty;
                defer out.deinit(self.alloc);
                var it = std.mem.tokenizeScalar(u8, b.search.items, ' ');
                while (it.next()) |w| {
                    if (std.ascii.startsWithIgnoreCase(w, "kind:")) continue;
                    if (out.items.len > 0) out.append(self.alloc, ' ') catch {};
                    out.appendSlice(self.alloc, w) catch {};
                }
                if (k[0].len > 0) {
                    if (out.items.len > 0) out.append(self.alloc, ' ') catch {};
                    out.appendSlice(self.alloc, "kind:") catch {};
                    out.appendSlice(self.alloc, k[0]) catch {};
                }
                b.setSearch(out.items);
            };
            c.igEndCombo();
        }
        // + adds a rule (Finder's criteria): last modified within the last week to start.
        c.igSameLine(0, -1);
        if (c.igSmallButton("+##addrule")) self.setSearchWord(b, null, "modified:<7d");
        if (c.igBeginItemTooltip()) {
            cimgui.textUnformatted("Add a rule: when it was changed or made, or how big it is.");
            c.igEndTooltip();
        }

        if (self.dialog == null) {
            const save_w = c.igCalcTextSize("Save", null, false, -1).x + c.igGetStyle().*.FramePadding.x * 2;
            c.igSameLine(0, -1);
            c.igSetCursorPosX(@max(c.igGetCursorPosX(), c.igGetCursorPosX() + c.igGetContentRegionAvail().x - save_w));
            if (c.igButton("Save", cimgui.vec2(0, 0))) self.saveSearch(b);
            if (c.igBeginItemTooltip()) {
                cimgui.textUnformatted("Keep this search in the sidebar; clicking it runs it again.");
                c.igEndTooltip();
            }
        }
        self.drawSearchRules(b);
    }
    /// drawSearchRules is a row per rule in the search (Finder's criteria): what it
    /// looks at, how, the value, and − to drop it. Each row is a word in the query
    /// (`modified:<7d`), so a saved search keeps its rules.
    fn drawSearchRules(self: *Shell, b: *Browser) void {
        const fs = c.igGetFontSize();
        var idx: usize = 0; // word index in the query
        var row: usize = 0;
        var it = std.mem.tokenizeScalar(u8, b.search.items, ' ');
        while (it.next()) |word| : (idx += 1) {
            const r = core.query.Rule.ofWord(word) orelse continue;
            if (row == self.rule_bufs.len) break;
            defer row += 1;
            c.igPushID_Int(@intCast(row));
            defer c.igPopID();
            c.igSetCursorPosX(c.igGetCursorPosX() + fs * 3.5);
            // What it looks at.
            const whats = [_]struct { core.query.Rule.What, [:0]const u8 }{ .{ .modified, "Last modified" }, .{ .created, "Created" }, .{ .size, "Size" } };
            var nr = r;
            var vb: [32]u8 = undefined;
            c.igSetNextItemWidth(fs * 9.5);
            if (c.igBeginCombo("##what", whats[@intFromEnum(r.what)][1].ptr, 0)) {
                for (whats) |w| if (c.igSelectable_Bool(w[1].ptr, w[0] == r.what, 0, cimgui.vec2(0, 0)) and w[0] != r.what) {
                    nr.what = w[0];
                    // Size and dates take different values.
                    if (w[0] == .size) {
                        nr.op = .bigger;
                        nr.value = "10MB";
                    } else if (r.what == .size) {
                        nr.op = .within;
                        nr.value = "7d";
                    }
                };
                c.igEndCombo();
            }
            // How.
            c.igSameLine(0, -1);
            const ops = if (nr.what == .size)
                &[_]struct { core.query.Rule.Op, [:0]const u8 }{ .{ .bigger, "is bigger than" }, .{ .smaller, "is smaller than" } }
            else
                &[_]struct { core.query.Rule.Op, [:0]const u8 }{ .{ .within, "is within the last" }, .{ .older, "is more than (ago)" }, .{ .before, "is before" }, .{ .after, "is after" } };
            var op_label: [:0]const u8 = ops[0][1];
            for (ops) |o| if (o[0] == nr.op) {
                op_label = o[1];
            };
            c.igSetNextItemWidth(fs * 13);
            if (c.igBeginCombo("##op", op_label.ptr, 0)) {
                for (ops) |o| if (c.igSelectable_Bool(o[1].ptr, o[0] == nr.op, 0, cimgui.vec2(0, 0)) and o[0] != nr.op) {
                    const was_date = nr.op == .before or nr.op == .after;
                    nr.op = o[0];
                    const is_date = nr.op == .before or nr.op == .after;
                    // A span and a date are written differently: start from a sensible one.
                    if (is_date and !was_date) nr.value = todayDate(&vb) else if (!is_date and was_date) nr.value = "7d";
                };
                c.igEndCombo();
            }
            // The value: applied as soon as it reads (red until it does).
            c.igSameLine(0, -1);
            const buf = &self.rule_bufs[row];
            const hint: [:0]const u8 = switch (nr.op) {
                .within, .older => "7d, 2w, 3m, 1y",
                .before, .after => "2026-01-31",
                else => "10MB, 500KB",
            };
            var field_val = nr.value;
            c.igSetNextItemWidth(fs * 7);
            const valid_now = ruleValueOk(nr.op, std.mem.sliceTo(buf, 0));
            if (!valid_now) c.igPushStyleColor_Vec4(c.ImGuiCol_FrameBg, cimgui.vec4(0.9, 0.2, 0.2, 0.25));
            const edited = c.igInputTextWithHint("##val", hint.ptr, buf, buf.len, 0, null, null);
            const active = c.igIsItemActive();
            if (!valid_now) c.igPopStyleColor(1);
            if (!active and !edited) setField(buf, nr.value); // follow the query while not typed in
            if (edited and ruleValueOk(nr.op, std.mem.sliceTo(buf, 0))) field_val = std.mem.sliceTo(buf, 0);
            nr.value = field_val;
            // Drop it.
            c.igSameLine(0, -1);
            const drop = c.igSmallButton("\u{2212}##drop");
            if (drop) {
                self.setSearchWord(b, idx, null);
                return; // the query changed under the loop
            }
            if (nr.what != r.what or nr.op != r.op or !std.mem.eql(u8, nr.value, r.value)) {
                var wb: [64]u8 = undefined;
                self.setSearchWord(b, idx, nr.write(&wb));
                return;
            }
        }
    }

    /// setSearchWord replaces word `index` of the query with `word` (null removes it;
    /// a null index appends `word`), then searches with it.
    fn setSearchWord(self: *Shell, b: *Browser, index: ?usize, word: ?[]const u8) void {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.alloc);
        var it = std.mem.tokenizeScalar(u8, b.search.items, ' ');
        var i: usize = 0;
        while (it.next()) |w| : (i += 1) {
            const keep: ?[]const u8 = if (index != null and index.? == i) word else w;
            const k = keep orelse continue;
            if (out.items.len > 0) out.append(self.alloc, ' ') catch return;
            out.appendSlice(self.alloc, k) catch return;
        }
        if (index == null) if (word) |w| {
            if (out.items.len > 0) out.append(self.alloc, ' ') catch return;
            out.appendSlice(self.alloc, w) catch return;
        };
        b.setSearch(out.items);
        self.syncSearch(b);
    }


    /// saveSearch adds the current search to the sidebar's Favourites.
    fn saveSearch(self: *Shell, b: *Browser) void {
        const a = self.alloc;
        const q = std.mem.trim(u8, b.search.items, " ");
        if (q.len == 0) return;
        const loc = core.bookmarks.searchLoc(a, b.dir, q, b.deep) catch return;
        for (self.bookmarks.items) |bm| if (std.mem.eql(u8, bm.loc, loc)) return a.free(loc);
        const label = a.dupe(u8, q) catch return a.free(loc);
        self.bookmarks.append(a, .{ .loc = loc, .label = label }) catch {
            a.free(loc);
            a.free(label);
            return;
        };
        self.saveBookmarks();
    }

    /// drawWindowButtons draws minimize, maximize and close at the cursor, in the usual
    /// Linux/Windows order and place (the right end of the menu bar); close turns red
    /// on hover. Glyphs are drawn, so they look the same in the blocky font.
    fn drawWindowButtons(self: *Shell, h: f32) void {
        const kinds = [_]WinButton{ .minimize, if (self.isMaximized()) .restore else .maximize, .close };
        const tips = [_][:0]const u8{ "Minimize", "Maximize", "Close" };
        var clicked: ?usize = null;
        for (kinds, 0..) |k, i| {
            if (i == 1 and self.finishing) continue; // (the progress window: nothing to maximize)
            if (i > 0) c.igSameLine(0, 0);
            c.igPushID_Int(@intCast(i));
            // A press a resize grip took (the top-right corner) is not a click.
            if (winButton(k, h, tips[i], c.igGetColorU32_Col(c.ImGuiCol_MenuBarBg, 1)) and !self.grip_press) clicked = i;
            c.igPopID();
        }
        if (clicked) |i| switch (i) {
            0 => self.minimize(),
            1 => self.toggleMaximize(),
            else => self.closeWindow(),
        };
    }

    fn isMaximized(self: *Shell) bool {
        const w = self.glfwWin() orelse return false;
        return c.glfwGetWindowAttrib(w, c.GLFW_MAXIMIZED) != 0;
    }

    /// toggleTreemap shows or hides Disk Usage. Hiding it stops any size scan still
    /// running (it walks the whole tree, and nobody's looking); showing it again
    /// starts a fresh one.
    fn toggleTreemap(self: *Shell, b: *Browser) void {
        self.show_treemap = !self.show_treemap;
        if (self.show_treemap) {
            if (b.usageCanceled()) b.resetUsage();
        } else for (self.liveBrowsers()) |t| {
            if (t.usageScanning()) t.cancelUsage();
        }
    }

    /// drawTabGhost follows the pointer while a tab is dragged out of the window, like
    /// Chrome's detached tab: the folder's name and first few items, and what letting
    /// go will do (a new window, or moving the tab into the ZFD window underneath).
    fn drawTabGhost(self: *Shell) void {
        const t = self.tab_drag orelse return;
        if (!c.igIsMouseDown_Nil(0) or !self.mouseOutside()) return;
        const into_other = x11.zfdWindowUnderPointer(self.win) != null;
        if (!into_other and self.tabs.items.len == 1) return; // a lone tab only merges
        const mp = c.igGetMousePos();
        const fs = c.igGetFontSize();
        // Below-right of the pointer, never under it: "which ZFD window is under the
        // pointer" must see the window there, not this ghost.
        c.igSetNextWindowPos(cimgui.vec2(mp.x + fs * 1.2, mp.y + fs * 1.2), c.ImGuiCond_Always, cimgui.vec2(0, 0));
        c.igSetNextWindowSize(cimgui.vec2(fs * 18, 0), c.ImGuiCond_Always);
        c.igSetNextWindowBgAlpha(0.94);
        const flags: c_int = c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoInputs | c.ImGuiWindowFlags_NoFocusOnAppearing |
            c.ImGuiWindowFlags_NoNav | c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_AlwaysAutoResize;
        defer c.igEnd();
        if (!c.igBegin("##tabghost", null, flags)) return;
        const name = if (t.in_recent) "Recent" else std.fs.path.basename(t.dir);
        cimgui.textUnformatted(if (name.len > 0) name else "/");
        c.igSeparator();
        const n = @min(t.count(), 8);
        for (0..n) |i| {
            const e = t.at(i);
            var lb: [300]u8 = undefined;
            cimgui.textUnformatted(std.mem.print(&lb, "{s}{s}", .{ std.fs.path.basename(e.name), if (e.isDir()) "/" else "" }) catch e.name);
        }
        if (t.count() > n) dimText("\u{2026}");
        c.igSeparator();
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.info());
        cimgui.textUnformatted(if (into_other) "Release to move it into this window" else "Release to open it in a new window");
        c.igPopStyleColor(1);
    }

    /// newWindow opens another ZFD window on the current folder (File > New Window).
    fn newWindow(self: *Shell, b: *Browser) void {
        const exe = std.process.executablePathAlloc(self.io, self.alloc) catch return;
        defer self.alloc.free(exe);
        var child = std.process.spawn(self.io, .{ .argv = &.{ exe, "--detach", b.location() } }) catch return;
        _ = child.wait(self.io) catch {}; // --detach forks away at once; this reaps the stub
    }

    /// goEnclosing goes to the parent folder with the one you were in selected
    /// (Finder's Go > Enclosing Folder).
    fn goEnclosing(self: *Shell, b: *Browser) void {
        _ = self;
        if (b.in_recent) return;
        if (b.insideArchive()) |o| if (o.inner.len == 0) {
            _ = b.leaveArchive();
            return;
        };
        const parent = std.fs.path.dirname(b.dir) orelse return;
        var nb: [std.fs.max_path_bytes]u8 = undefined;
        const name = std.fs.path.basename(b.dir);
        if (name.len > nb.len) return;
        @memcpy(nb[0..name.len], name);
        const pdup = b.alloc.dupe(u8, parent) catch return;
        defer b.alloc.free(pdup);
        b.navigate(pdup) catch return;
        b.setPendingSelect(nb[0..name.len]);
    }

    /// drawMenuBar is the File / Edit / View / Go / Window / Help bar. Everything in it
    /// also has a shortcut or a place elsewhere; the menus make it discoverable.
    fn drawMenuBar(self: *Shell, b: *Browser) void {
        if (!c.igBeginMenuBar()) return;
        const has_cursor = b.count() > 0 and b.sel.cursor < b.count();
        const has_sel = b.sel.count() > 0;
        const act = &self.actions;
        if (c.igBeginMenu("File", true)) {
            if (c.igMenuItem_Bool("New Window", "Ctrl+N", false, true)) self.newWindow(b);
            if (c.igMenuItem_Bool("New Tab", "Ctrl+T", false, true)) self.addTab();
            if (c.igMenuItem_Bool("New Folder", "Ctrl+Shift+N", false, !b.virtualView())) b.newFolder();
            if (c.igMenuItem_Bool("New Folder with Selection", "Ctrl+Alt+N", false, has_sel and !b.virtualView())) b.newFolderWithSelection();
            if (c.igMenuItem_Bool("New File", null, false, !b.virtualView())) b.newFile();
            c.igSeparator();
            if (c.igMenuItem_Bool("Open", "Ctrl+O", false, has_cursor)) b.openCursor() catch {};
            if (c.igMenuItem_Bool("Open With\u{2026}", null, false, has_cursor and !b.at(b.sel.cursor).isDir())) act.openwith_pending = true;
            if (c.igMenuItem_Bool("Quick Look", "Space", false, has_cursor)) act.quicklook_toggle = true;
            if (c.igMenuItem_Bool("Get Info", "Alt+Enter", false, has_cursor)) act.openProperties(b, b.sel.cursor);
            if (c.igMenuItem_Bool("Open Terminal Here", "F4", false, !b.virtualView())) b.openTerminalHere();
            c.igSeparator();
            if (c.igMenuItem_Bool("Rename", "F2", false, has_sel)) {
                if (b.sel.count() > 1) act.openBatchRename(b) else b.requestRename();
            }
            if (c.igMenuItem_Bool("Make Link", null, false, has_sel)) b.linkSelection();
            if (c.igMenuItem_Bool("Move to Trash", "Del", false, has_sel)) b.trashSelection();
            if (c.igMenuItem_Bool("Delete Permanently\u{2026}", "Shift+Del", false, has_sel)) act.askDeleteConfirm(b);
            c.igSeparator();
            if (c.igMenuItem_Bool("Add to Favourites", "Ctrl+D", false, !b.virtualView())) self.addBookmark(b.dir);
            if (c.igMenuItem_Bool("Connect to Server\u{2026}", "Ctrl+K", false, true)) self.connect.open(null);
            if (c.igMenuItem_Bool("Empty Trash\u{2026}", "Ctrl+Shift+Backspace", false, true)) self.empty_trash_pending = true;
            if (c.igMenuItem_Bool("Eject", "Ctrl+E", false, true)) self.ejectHere(b);
            c.igSeparator();
            if (c.igMenuItem_Bool("Settings\u{2026}", "Ctrl+,", false, true)) self.settings_open = true;
            c.igSeparator();
            if (c.igMenuItem_Bool("Close Tab", "Ctrl+W", false, true)) self.closeTab(self.active);
            if (c.igMenuItem_Bool("Close Window", "Ctrl+Q", false, true)) self.closeWindow();
            if (b.insideArchive() != null and c.igMenuItem_Bool("Close Archive", null, false, true)) _ = b.leaveArchive();
            c.igEndMenu();
        }
        if (c.igBeginMenu("Edit", true)) {
            if (c.igMenuItem_Bool("Undo", "Ctrl+Z", false, b.canUndo())) b.undo();
            if (c.igMenuItem_Bool("Redo", "Ctrl+Shift+Z", false, b.canRedo())) b.redo();
            c.igSeparator();
            if (c.igMenuItem_Bool("Cut", "Ctrl+X", false, has_sel)) b.cutSelection();
            if (c.igMenuItem_Bool("Copy", "Ctrl+C", false, has_sel)) b.copySelection();
            if (c.igMenuItem_Bool("Paste", "Ctrl+V", false, !b.clipboard.isEmpty() and !b.virtualView())) b.paste();
            if (c.igMenuItem_Bool("Duplicate", "Ctrl+Alt+D", false, has_sel and !b.virtualView())) b.duplicateSelection();
            if (c.igMenuItem_Bool("Copy Path", null, false, has_cursor)) actions.copyPathToClipboard(b, b.sel.cursor);
            c.igSeparator();
            if (c.igMenuItem_Bool("Select All", "Ctrl+A", false, b.count() > 0)) b.selectAll();
            if (c.igMenuItem_Bool("Invert Selection", "Ctrl+I", false, b.count() > 0)) b.sel.invert();
            c.igSeparator();
            if (c.igMenuItem_Bool("Find", "Ctrl+F", false, true)) self.focus_search = true;
            if (c.igMenuItem_Bool("Search Subfolders Too", null, b.deep, true)) b.setDeep(!b.deep);
            c.igEndMenu();
        }
        if (c.igBeginMenu("View", true)) {
            if (c.igMenuItem_Bool("as List", "Ctrl+1", b.view_mode == .list, true)) b.setViewMode(.list);
            if (c.igMenuItem_Bool("as Icons", "Ctrl+2", b.view_mode == .grid, true)) b.setViewMode(.grid);
            if (c.igMenuItem_Bool("as Columns", "Ctrl+3", b.view_mode == .columns, true)) b.setViewMode(.columns);
            if (c.igMenuItem_Bool("as Gallery", "Ctrl+4", b.view_mode == .gallery, true)) b.setViewMode(.gallery);
            c.igSeparator();
            if (c.igBeginMenu("Sort By", true)) {
                const cols = [_]struct { [:0]const u8, core.scan.SortColumn }{
                    .{ "Name", .name }, .{ "Kind", .type }, .{ "Size", .size }, .{ "Date Modified", .date }, .{ "Date Created", .created }, .{ "Date Last Opened", .accessed },
                };
                for (cols) |sc| if (c.igMenuItem_Bool(sc[0].ptr, null, b.sort_order.column == sc[1], true)) b.setSort(sc[1], b.sort_order.ascending);
                c.igSeparator();
                if (c.igMenuItem_Bool("Ascending", null, b.sort_order.ascending, true)) b.setSort(b.sort_order.column, true);
                if (c.igMenuItem_Bool("Descending", null, !b.sort_order.ascending, true)) b.setSort(b.sort_order.column, false);
                c.igEndMenu();
            }
            if (c.igBeginMenu("Group By", true)) {
                groupItems(b);
                c.igEndMenu();
            }
            if (c.igMenuItem_Bool("Folders First", null, b.sort_order.dirs_first, true)) b.toggleDirsFirst();
            if (c.igMenuItem_Bool("Show Hidden Files", "Ctrl+H", b.show_hidden, true)) b.toggleHidden();
            if (c.igMenuItem_Bool("Show Folder Sizes", null, self.folder_sizes, true)) self.folder_sizes = !self.folder_sizes;
            if (c.igIsItemHovered(0)) c.igSetTooltip("In the list: the files directly in each folder (subfolders aren't counted)");
            if (c.igMenuItem_Bool("Use This View for All Folders", null, false, true)) {
                self.prefs.useForAll(b.currentView());
                for (self.liveBrowsers()) |t| t.reloadView();
            }
            if (c.igMenuItem_Bool("Reset This Folder's View", null, false, b.hasFolderView())) b.resetFolderView();
            c.igSeparator();
            if (c.igMenuItem_Bool(if (self.showsBar(.toolbar)) "Hide Toolbar" else "Show Toolbar", null, false, true)) self.toggleBar(.toolbar);
            if (c.igMenuItem_Bool(if (self.showsBar(.sidebar)) "Hide Sidebar" else "Show Sidebar", "Ctrl+Alt+S", false, true)) self.toggleBar(.sidebar);
            if (c.igMenuItem_Bool(if (self.showsBar(.path_bar)) "Hide Path Bar" else "Show Path Bar", "Ctrl+Alt+P", false, true)) self.toggleBar(.path_bar);
            if (c.igMenuItem_Bool(if (self.showsBar(.status_bar)) "Hide Status Bar" else "Show Status Bar", "Ctrl+/", false, true)) self.toggleBar(.status_bar);
            if (c.igMenuItem_Bool(if (self.show_preview) "Hide Preview" else "Show Preview", "Ctrl+Shift+P", false, true)) self.show_preview = !self.show_preview;
            if (c.igMenuItem_Bool("Show View Options", "Ctrl+J", self.view_opts_open, true)) self.view_opts_open = !self.view_opts_open;
            if (c.igMenuItem_Bool("Customize Toolbar\u{2026}", null, self.customize_open, true)) self.customize_open = !self.customize_open;
            if (c.igMenuItem_Bool("Split View", "F3", self.split_b != null, true)) self.toggleSplit();
            if (c.igMenuItem_Bool("Disk Usage", null, self.show_treemap, true)) self.toggleTreemap(b);
            c.igSeparator();
            if (c.igBeginMenu("Appearance", true)) {
                if (c.igMenuItem_Bool("Follow the System", null, self.theme_mode == .system, true)) self.theme_mode = .system;
                if (c.igMenuItem_Bool("Light", null, self.theme_mode == .light, true)) self.theme_mode = .light;
                if (c.igMenuItem_Bool("Dark", null, self.theme_mode == .dark, true)) self.theme_mode = .dark;
                c.igSeparator();
                _ = c.igMenuItem_BoolPtr("Blocky Font", null, &self.font_nearest, true);
                _ = c.igMenuItem_BoolPtr("Scale to Monitor DPI", null, &self.dpi_enabled, true);
                c.igEndMenu();
            }
            if (c.igMenuItem_Bool("Bigger Icons", "Ctrl++", false, true)) self.sizeItems(b, 1.1);
            if (c.igMenuItem_Bool("Smaller Icons", "Ctrl+-", false, true)) self.sizeItems(b, 1.0 / 1.1);
            if (c.igMenuItem_Bool("Default Icon Size", "Ctrl+0", false, true)) self.sizeItems(b, null);
            c.igSeparator();
            _ = c.igMenuItem_BoolPtr("Show Menu Bar", null, &self.menu_bar, true);
            c.igEndMenu();
        }
        if (c.igBeginMenu("Go", true)) {
            if (c.igMenuItem_Bool("Back", "Alt+Left", false, b.canBackOrUp())) b.backOrUp();
            if (c.igMenuItem_Bool("Forward", "Alt+Right", false, b.canForward())) b.forward();
            if (c.igMenuItem_Bool("Enclosing Folder", "Alt+Up", false, !b.in_recent and !std.mem.eql(u8, b.dir, "/"))) self.goEnclosing(b);
            c.igSeparator();
            if (c.igMenuItem_Bool("Recent", "Ctrl+Shift+F", false, true)) b.navigate(core.recent.uri) catch {};
            if (c.igMenuItem_Bool("Home", "Ctrl+Shift+H", false, true)) b.navigate(self.home) catch {};
            const subs = [_]struct { [:0]const u8, [:0]const u8 }{ .{ "Desktop", "Ctrl+Shift+D" }, .{ "Documents", "Ctrl+Shift+O" }, .{ "Downloads", "Ctrl+Alt+L" } };
            for (subs) |sub| if (c.igMenuItem_Bool(sub[0].ptr, sub[1].ptr, false, true)) self.goHomeSub(b, sub[0]);
            if (c.igMenuItem_Bool("Computer", "Ctrl+Shift+C", false, true)) b.navigate("/") catch {};
            if (c.igMenuItem_Bool("Trash", null, false, true)) self.openTrash();
            c.igSeparator();
            if (c.igBeginMenu("Recent Folders", self.recent_folders.items.len > 0)) {
                for (self.recent_folders.items, 0..) |p, i| {
                    var lb: [std.fs.max_path_bytes + 16]u8 = undefined;
                    const name = if (std.mem.eql(u8, p, "/")) "Computer" else std.fs.path.basename(p);
                    const label = std.mem.printSentinel(&lb, "{s}##rf{d}", .{ name, i }, 0) catch continue;
                    if (c.igMenuItem_Bool(label.ptr, null, false, true)) {
                        b.navigate(p) catch {};
                        break; // navigating may reorder the list
                    }
                    if (c.igIsItemHovered(0)) c.igSetTooltip("%.*s", @as(c_int, @intCast(p.len)), p.ptr);
                }
                c.igSeparator();
                if (c.igMenuItem_Bool("Clear Menu", null, false, true)) self.clearRecentFolders();
                c.igEndMenu();
            }
            if (c.igMenuItem_Bool("Network", "Ctrl+Shift+K", false, true)) self.openNetworkPage(b);
            if (c.igMenuItem_Bool("Go to Folder\u{2026}", "Ctrl+Shift+G", false, true)) self.focus_path = true;
            if (c.igMenuItem_Bool("Connect to Server\u{2026}", "Ctrl+K", false, true)) self.connect.open(null);
            c.igEndMenu();
        }
        if (c.igBeginMenu("Window", true)) {
            if (c.igMenuItem_Bool("Minimize", "Ctrl+M", false, true)) self.minimize();
            if (c.igMenuItem_Bool("Zoom", null, false, true)) self.toggleMaximize();
            if (c.igMenuItem_Bool("Full Screen", "F11", self.glfwWin() != null and c.glfwGetWindowMonitor(self.glfwWin()) != null, true)) self.toggleFullScreen();
            c.igSeparator();
            if (c.igMenuItem_Bool("Show Progress", null, self.progress_open, true)) self.progress_open = !self.progress_open;
            c.igSeparator();
            if (c.igMenuItem_Bool("Merge All Windows", null, false, true)) _ = x11.requestMerge(self.win);
            if (c.igMenuItem_Bool("Move Tab to New Window", null, false, self.tabs.items.len > 1)) self.moveTabToNewWindow();
            c.igSeparator();
            if (c.igMenuItem_Bool("Reopen Closed Tab", "Ctrl+Shift+T", false, true)) self.reopenClosedTab();
            if (c.igMenuItem_Bool("Duplicate Tab", null, false, true)) {
                if (self.openTab(b.location())) |nb| {
                    nb.prefs = self.prefs;
                    nb.temp_files = self.temp_files;
                    nb.applyFolderView();
                }
            }
            c.igSeparator();
            for (self.tabs.items, 0..) |t, i| {
                var lb: [300]u8 = undefined;
                const name = if (t.in_recent) "Recent" else std.fs.path.basename(t.dir);
                const label = std.mem.printSentinel(&lb, "{s}##wt{d}", .{ if (name.len > 0) name else "/", i }, 0) catch continue;
                if (c.igMenuItem_Bool(label.ptr, null, i == self.active, true)) self.selectTab(i);
            }
            c.igEndMenu();
        }
        if (c.igBeginMenu("Help", true)) {
            if (c.igMenuItem_Bool("Keyboard Shortcuts", null, false, true)) self.help_pending = .shortcuts;
            if (c.igMenuItem_Bool("About ZFD", null, false, true)) self.help_pending = .about;
            c.igEndMenu();
        }
        // Window buttons at the right end of the menu bar (CSD).
        if (self.csd) {
            const bw = windowButtonsWidth();
            const menu_h = c.igGetFrameHeight();
            // ImGui clips a menu bar's right end by the window's rounding; keep the
            // buttons inside that, and off the window's rounded corner.
            const st = c.igGetStyle();
            const inset = @max(st.*.ChildRounding, st.*.WindowPadding.x * 0.5) + 2;
            c.igSetCursorPosX(c.igGetWindowWidth() - bw - inset);
            self.drawWindowButtons(menu_h);
        }
        // Empty menu-bar space drags the window too (CSD), like the title row.
        if (self.csd) {
            const wp = c.igGetWindowPos();
            self.dragZone(wp, cimgui.vec2(wp.x + c.igGetWindowWidth(), wp.y + c.igGetFrameHeight()));
        }
        c.igEndMenuBar();
    }

    /// SideItem names what Settings > Sidebar can switch off.
    const SideItem = enum(u4) { recent, home, desktop, documents, downloads, trash, computer, devices, mounts, network, tags };

    fn shows(self: *const Shell, item: SideItem) bool {
        return self.sidebar_hide & (@as(u16, 1) << @backingInt(item)) == 0;
    }

    /// SettingsPage is one page of the Settings window.
    const SettingsPage = enum(u8) { general, tags, sidebar, appearance, advanced };

    /// drawSettings is the Settings window (File > Settings…, Ctrl+,), laid out like
    /// Finder's: a row of icon buttons picks the page, the window is titled after it,
    /// and each page is a two-column form. Changes apply at once and are saved with the
    /// other settings when ZFD closes.
    fn drawSettings(self: *Shell) void {
        if (!self.settings_open) return self.settings_win.hide();
        const fs = c.igGetFontSize();
        const pages = [_]struct { SettingsPage, [:0]const u8 }{
            .{ .general, "General" },       .{ .tags, "Tags" },         .{ .sidebar, "Sidebar" },
            .{ .appearance, "Appearance" }, .{ .advanced, "Advanced" },
        };
        const page: SettingsPage = @fromBackingInt(@intCast(@min(self.settings_page, pages.len - 1)));
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(cimgui.vec2(vp.*.WorkPos.x + vp.*.WorkSize.x * 0.5, vp.*.WorkPos.y + vp.*.WorkSize.y * 0.4), c.ImGuiCond_Appearing, cimgui.vec2(0.5, 0.5));
        c.igSetNextWindowBgAlpha(1.0);
        var tb: [48]u8 = undefined;
        const title = std.mem.printSentinel(&tb, "{s}###settings", .{pages[@backingInt(page)][1]}, 0) catch "Settings###settings";
        defer self.settings_win.end();
        if (!self.settings_win.begin(.{ .name = title, .auto_size = true, .flags = c.ImGuiWindowFlags_NoCollapse }, &self.settings_open)) return;
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false) and c.igIsWindowFocused(c.ImGuiFocusedFlags_RootAndChildWindows)) self.settings_open = false;

        // The page buttons: icon over label, centred, the current one on a soft pill,
        // on the title bar's shade, one band with it as in Finder, a hairline under.
        const content_w = fs * 30;
        const btn_w = fs * 5.2;
        const btn_h = fs * 3.4;
        {
            const wp = c.igGetWindowPos();
            const ww = c.igGetWindowWidth();
            const top = c.igGetCursorScreenPos().y - c.igGetStyle().*.WindowPadding.y;
            const bottom = c.igGetCursorScreenPos().y + btn_h + c.igGetStyle().*.ItemSpacing.y * 0.5;
            const dl = c.igGetWindowDrawList();
            c.ImDrawList_AddRectFilled(dl, cimgui.vec2(wp.x, top), cimgui.vec2(wp.x + ww, bottom), c.igGetColorU32_Vec4(theme.p().toolbar_bg), 0, 0);
            c.ImDrawList_AddLine(dl, cimgui.vec2(wp.x, bottom), cimgui.vec2(wp.x + ww, bottom), c.igGetColorU32_Vec4(theme.p().toolbar_line), 1);
        }
        const row_x = c.igGetCursorPosX() + (content_w - btn_w * @as(f32, pages.len)) * 0.5;
        c.igSetCursorPosX(row_x);
        for (pages, 0..) |pg, i| {
            if (i > 0) c.igSameLine(0, 0);
            if (settingsPageButton(pg[1], pg[0], page == pg[0], btn_w, btn_h)) self.settings_page = @backingInt(pg[0]);
        }
        c.igDummy(cimgui.vec2(content_w, 0)); // fixes the window's width
        c.igSpacing();
        c.igSpacing();

        const label_w = fs * 11;
        const b = self.activeBrowser();
        switch (page) {
            .general => {
                formLabel("New windows show:", label_w);
                c.igSetNextItemWidth(fs * 15);
                var nw: c_int = if (self.reopen_last) 0 else 1;
                if (c.igCombo_Str("##newwin", &nw, "The last folder you were in\x00Your home folder\x00", -1)) self.reopen_last = nw == 0;
                formLabel("Opening an archive:", label_w);
                c.igSetNextItemWidth(fs * 15);
                var ar: c_int = if (self.archive_browse) 0 else 1;
                if (c.igCombo_Str("##archive", &ar, "Shows what's inside\x00Opens it in its app\x00", -1)) self.archive_browse = ar == 0;
                formLabel("Devices:", label_w);
                _ = c.igCheckbox("Notify me when one is plugged in", &self.notify_devices);
                formLabel("Reading a PDF:", label_w);
                _ = c.igCheckbox("Page Up and Page Down go a whole page", &pdfview.snap_pages);
            },
            .tags => {
                c.igPushTextWrapPos(content_w);
                dimText("Tick the tags to list in the sidebar; click a dot to change its colour.");
                c.igPopTextWrapPos();
                c.igSpacing();
                var remove: ?usize = null;
                var changed = false;
                for (core.tags.list(), 0..) |tag, i| {
                    c.igPushID_Int(@intCast(i));
                    defer c.igPopID();
                    var on = self.tags_hide & tag.bit() == 0;
                    c.igSetCursorPosX(c.igGetCursorPosX() + fs * 0.5);
                    if (c.igCheckbox("##tagshow", &on)) {
                        if (on) self.tags_hide &= ~tag.bit() else self.tags_hide |= tag.bit();
                    }
                    if (c.igBeginItemTooltip()) {
                        cimgui.textUnformatted("Show in the sidebar");
                        c.igEndTooltip();
                    }
                    // The colour: a dot that opens the palette.
                    c.igSameLine(0, -1);
                    const fh = c.igGetFrameHeight();
                    const pos = c.igGetCursorScreenPos();
                    if (c.igInvisibleButton("##dot", cimgui.vec2(fh, fh), 0)) c.igOpenPopup_Str("##palette", 0);
                    drawTagDot(c.igGetWindowDrawList(), cimgui.vec2(pos.x + fh * 0.5, pos.y + fh * 0.5), fs * 0.42, tag.color());
                    if (c.igBeginPopup("##palette", 0)) {
                        for (core.tags.colors, 0..) |col, k| {
                            if (k > 0) c.igSameLine(0, 2);
                            c.igPushID_Int(@intCast(k));
                            const pp = c.igGetCursorScreenPos();
                            if (c.igInvisibleButton("##pick", cimgui.vec2(fh, fh), 0)) {
                                core.tags.setColor(i, col);
                                changed = true;
                                c.igCloseCurrentPopup();
                            }
                            if (c.igIsItemHovered(0)) c.igSetTooltip("%s", if (col == .none) "No colour" else col.name().ptr);
                            drawTagDot(c.igGetWindowDrawList(), cimgui.vec2(pp.x + fh * 0.5, pp.y + fh * 0.5), fs * 0.42, col);
                            c.igPopID();
                        }
                        c.igEndPopup();
                    }
                    // The name, renamed in place (applied when you leave the field).
                    c.igSameLine(0, -1);
                    const bit: u16 = @as(u16, 1) << @intCast(i);
                    if (self.tag_edit_live & bit == 0) {
                        const n = tag.name();
                        @memcpy(self.tag_edit[i][0..n.len], n);
                        self.tag_edit[i][n.len] = 0;
                    }
                    c.igSetNextItemWidth(fs * 14);
                    _ = c.igInputText("##name", &self.tag_edit[i], self.tag_edit[i].len, 0, null, null);
                    if (c.igIsItemActive()) self.tag_edit_live |= bit;
                    if (c.igIsItemDeactivated()) {
                        self.tag_edit_live &= ~bit;
                        const typed = std.mem.sliceTo(&self.tag_edit[i], 0);
                        if (!std.mem.eql(u8, typed, tag.name())) {
                            core.tags.rename(i, typed);
                            changed = true;
                        }
                    }
                    if (i >= 7) {
                        c.igSameLine(0, -1);
                        if (c.igSmallButton("Remove")) remove = i;
                    }
                }
                if (remove) |i| {
                    core.tags.remove(i);
                    changed = true;
                }
                c.igSpacing();
                c.igSetCursorPosX(c.igGetCursorPosX() + fs * 0.5);
                c.igSetNextItemWidth(fs * 14);
                const enter = c.igInputTextWithHint("##newtag", "New tag", &self.tag_new, self.tag_new.len, c.ImGuiInputTextFlags_EnterReturnsTrue, null, null);
                c.igSameLine(0, -1);
                const full = core.tags.list().len >= core.tags.max_tags;
                c.igBeginDisabled(full or self.tag_new[0] == 0);
                if ((c.igButton("Add", cimgui.vec2(0, 0)) or enter) and !full) {
                    if (core.tags.add(std.mem.sliceTo(&self.tag_new, 0), .none)) {
                        @memset(&self.tag_new, 0);
                        changed = true;
                    }
                }
                c.igEndDisabled();
                if (changed) self.saveTags();
                c.igSpacing();
                c.igPushTextWrapPos(content_w);
                dimText("Tags are kept with each file (as user.xdg.tags), so other file managers see them too. A renamed tag is written under its new name from now on; files tagged before still count.");
                c.igPopTextWrapPos();
            },
            .sidebar => {
                const groups = [_]struct { [:0]const u8, []const struct { SideItem, [:0]const u8 } }{
                    .{ "Favourites", &.{ .{ .recent, "Recent" }, .{ .home, "Home" }, .{ .desktop, "Desktop" }, .{ .documents, "Documents" }, .{ .downloads, "Downloads" }, .{ .trash, "Trash" } } },
                    .{ "Locations", &.{ .{ .computer, "Computer" }, .{ .devices, "Disks and USB devices" }, .{ .mounts, "Other mounted folders" }, .{ .network, "Network locations" } } },
                    .{ "Tags", &.{.{ .tags, "Tags" }} },
                };
                dimText("Show these items in the sidebar:");
                for (groups) |g| {
                    c.igSpacing();
                    cimgui.textUnformatted(g[0]);
                    for (g[1]) |it| {
                        const bit = @as(u16, 1) << @backingInt(it[0]);
                        var on = self.sidebar_hide & bit == 0;
                        c.igSetCursorPosX(c.igGetCursorPosX() + fs);
                        if (c.igCheckbox(it[1].ptr, &on)) {
                            if (on) self.sidebar_hide &= ~bit else self.sidebar_hide |= bit;
                        }
                    }
                }
            },
            .appearance => {
                formLabel("Theme:", label_w);
                c.igSetNextItemWidth(fs * 12);
                var tm: c_int = @backingInt(self.theme_mode);
                if (c.igCombo_Str("##theme", &tm, "Follow the system\x00Light\x00Dark\x00", -1)) self.theme_mode = @fromBackingInt(@intCast(tm));
                formLabel("Text:", label_w);
                _ = c.igCheckbox("Blocky font (no smoothing)", &self.font_nearest);
                formLabel("Motion:", label_w);
                _ = c.igCheckbox("Reduce motion (no animations)", &self.reduce_motion);
                // The size applies when you let go: applying it while dragging rescales the
                // slider under the pointer, and the window jumps about. 5% steps;
                // middle-click for 100%.
                formLabel("Interface:", label_w);
                var pct: c_int = self.zoom_drag orelse @intFromFloat(@round(self.zoom * 100));
                c.igSetNextItemWidth(fs * 12);
                if (c.igSliderInt("##zoom", &pct, 50, 300, "%d%%", c.ImGuiSliderFlags_AlwaysClamp)) self.zoom_drag = @divFloor(pct + 2, 5) * 5;
                if (c.igIsItemDeactivated()) {
                    if (self.zoom_drag) |p| self.zoom = @as(f32, @floatFromInt(p)) / 100;
                    self.zoom_drag = null;
                }
                if (c.igIsItemHovered(0) and c.igIsMouseClicked_Bool(c.ImGuiMouseButton_Middle, false)) {
                    self.zoom = 1;
                    self.zoom_drag = null;
                }
                if (c.igIsItemHovered(0) and !c.igIsItemActive()) c.igSetTooltip("Middle-click for 100%%");
                formLabel("", label_w);
                var dbuf: [56]u8 = undefined;
                const dlabel = std.mem.printSentinel(&dbuf, "Scale to the monitor ({d:.2}x)", .{self.dpi_scale}, 0) catch "Scale to the monitor";
                _ = c.igCheckbox(dlabel.ptr, &self.dpi_enabled);
                formLabel("Window:", label_w);
                _ = c.igCheckbox("Show the menu bar", &self.menu_bar);
            },
            .advanced => {
                var dv = self.prefs.default;
                var changed = false;
                formLabel("Show hidden files:", label_w);
                if (c.igCheckbox("In every folder##hid", &dv.show_hidden)) changed = true;
                formLabel("Keep folders on top:", label_w);
                if (c.igCheckbox("In windows##dirs", &dv.sort.dirs_first)) changed = true;
                if (changed) {
                    self.prefs.default = dv;
                    for (self.liveBrowsers()) |t| t.reloadView();
                }
                formLabel("", label_w);
                c.igPushTextWrapPos(content_w);
                dimText("Folders you changed keep their own view.");
                c.igPopTextWrapPos();
                formLabel("", label_w);
                if (c.igButton("Reset every folder", cimgui.vec2(0, 0))) {
                    self.prefs.useForAll(self.prefs.default);
                    for (self.liveBrowsers()) |t| t.reloadView();
                }
                c.igSpacing();
                formLabel("When searching:", label_w);
                var ci = b.search_ci;
                if (c.igCheckbox("Ignore upper/lower case", &ci)) for (self.liveBrowsers()) |t| {
                    if (t.search_ci != ci) t.toggleSearchCI();
                };
                // How many pictures are turned into thumbnails at once (at most).
                formLabel("Thumbnail workers:", label_w);
                var tw: c_int = @intCast(self.thumb_workers);
                c.igSetNextItemWidth(fs * 8);
                if (c.igSliderInt("##thumbw", &tw, 1, thumbs.Cache.max_workers, "%d at most", 0)) {
                    self.thumb_workers = @intCast(tw);
                    // Restart the pool with the new size (the thumbnails come back).
                    if (self.actions.thumbs) |t| t.destroy();
                    self.actions.thumbs = null;
                }
                if (c.igIsItemHovered(0)) c.igSetTooltip("More decode faster on a big folder of pictures, and use more CPU while they do; 1 decodes one at a time.");
            },
        }
        c.igSpacing();
    }

    /// drawCustomizeToolbar is View > Customize Toolbar: the toolbar's right-hand items,
    /// ticked to show and dragged into order (a blue line shows where one will land).
    fn drawCustomizeToolbar(self: *Shell) void {
        if (!self.customize_open) return self.customize_win.hide();
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(cimgui.vec2(vp.*.WorkPos.x + vp.*.WorkSize.x * 0.5, vp.*.WorkPos.y + vp.*.WorkSize.y * 0.3), c.ImGuiCond_Appearing, cimgui.vec2(0.5, 0));
        defer self.customize_win.end();
        if (!self.customize_win.begin(.{ .name = "Customize Toolbar###customize", .auto_size = true, .flags = c.ImGuiWindowFlags_NoCollapse }, &self.customize_open)) return;
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false) and c.igIsWindowFocused(0)) self.customize_open = false;
        dimText("Tick what the toolbar shows; drag to reorder.");
        c.igSpacing();
        var move: ?[2]usize = null;
        var toggle: ?ToolItem = null;
        // Shown ones first, in order; then the rest.
        const shown = self.toolbar_items[0..self.toolbar_len];
        for (shown, 0..) |it, i| {
            c.igPushID_Int(@intCast(i));
            defer c.igPopID();
            var on = true;
            if (c.igCheckbox("##on", &on)) toggle = it;
            c.igSameLine(0, -1);
            _ = c.igSelectable_Bool(it.label().ptr, false, 0, cimgui.vec2(0, 0));
            if (c.igBeginDragDropSource(0)) {
                var idx: usize = i;
                _ = c.igSetDragDropPayload("ZFD_TB", &idx, @sizeOf(usize), 0);
                cimgui.textUnformatted(it.label());
                c.igEndDragDropSource();
            }
            if (c.igBeginDragDropTarget()) {
                const pl = c.igAcceptDragDropPayload("ZFD_TB", c.ImGuiDragDropFlags_AcceptBeforeDelivery | c.ImGuiDragDropFlags_AcceptNoDrawDefaultRect);
                if (pl != null and pl.*.DataSize == @sizeOf(usize)) {
                    const bytes: [*]const u8 = @ptrCast(pl.*.Data);
                    const from = std.mem.bytesToValue(usize, bytes[0..@sizeOf(usize)]);
                    if (from != i) {
                        const mn = c.igGetItemRectMin();
                        const mx = c.igGetItemRectMax();
                        const y = if (from > i) mn.y else mx.y;
                        c.ImDrawList_AddLine(c.igGetWindowDrawList(), cimgui.vec2(mn.x, y), cimgui.vec2(mx.x, y), c.igGetColorU32_Vec4(theme.p().accent), 2);
                    }
                    if (pl.*.Delivery) move = .{ from, i };
                }
                c.igEndDragDropTarget();
            }
        }
        for (std.enums.values(ToolItem)) |it| {
            if (std.mem.indexOfScalar(ToolItem, shown, it) != null) continue;
            c.igPushID_Int(100 + @as(c_int, @intFromEnum(it)));
            defer c.igPopID();
            var on = false;
            if (c.igCheckbox("##on", &on)) toggle = it;
            c.igSameLine(0, -1);
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
            cimgui.textUnformatted(it.label());
            c.igPopStyleColor(1);
        }
        c.igSeparator();
        if (c.igButton("Restore Defaults", cimgui.vec2(0, 0))) {
            @memcpy(self.toolbar_items[0..default_toolbar.len], &default_toolbar);
            self.toolbar_len = default_toolbar.len;
        }
        if (move) |m| {
            const it = self.toolbar_items[m[0]];
            if (m[0] < m[1]) {
                std.mem.copyForwards(ToolItem, self.toolbar_items[m[0]..m[1]], self.toolbar_items[m[0] + 1 .. m[1] + 1]);
            } else {
                std.mem.copyBackwards(ToolItem, self.toolbar_items[m[1] + 1 .. m[0] + 1], self.toolbar_items[m[1]..m[0]]);
            }
            self.toolbar_items[m[1]] = it;
        }
        if (toggle) |it| {
            if (std.mem.indexOfScalar(ToolItem, self.toolbar_items[0..self.toolbar_len], it)) |i| {
                std.mem.copyForwards(ToolItem, self.toolbar_items[i .. self.toolbar_len - 1], self.toolbar_items[i + 1 .. self.toolbar_len]);
                self.toolbar_len -= 1;
            } else if (self.toolbar_len < self.toolbar_items.len) {
                // A new one goes before search when search is last (it stays at the end).
                const at = if (self.toolbar_len > 0 and self.toolbar_items[self.toolbar_len - 1] == .search) self.toolbar_len - 1 else self.toolbar_len;
                std.mem.copyBackwards(ToolItem, self.toolbar_items[at + 1 .. self.toolbar_len + 1], self.toolbar_items[at..self.toolbar_len]);
                self.toolbar_items[at] = it;
                self.toolbar_len += 1;
            }
        }
    }

    /// drawViewOptions is Finder's View Options panel (Ctrl+J) for the folder shown:
    /// how it opens, sorts and groups (remembered for it), the icon size, the list's
    /// columns, and "Use as Defaults" for every folder without a view of its own.
    fn drawViewOptions(self: *Shell) void {
        if (!self.view_opts_open) return self.viewopts_win.hide();
        const b = self.activeBrowser();
        const fs = c.igGetFontSize();
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(cimgui.vec2(vp.*.WorkPos.x + vp.*.WorkSize.x - fs * 2, vp.*.WorkPos.y + fs * 5), c.ImGuiCond_Appearing, cimgui.vec2(1, 0));
        c.igSetNextWindowBgAlpha(1.0);
        var tb: [300]u8 = undefined;
        const name = if (b.in_recent) "Recent" else if (std.mem.eql(u8, b.dir, "/")) "Computer" else std.fs.path.basename(b.dir);
        const title = std.mem.printSentinel(&tb, "{s}###viewopts", .{name}, 0) catch "View Options###viewopts";
        defer self.viewopts_win.end();
        if (!self.viewopts_win.begin(.{ .name = title, .auto_size = true, .focus_on_appear = false, .flags = c.ImGuiWindowFlags_NoCollapse }, &self.view_opts_open)) return;
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false) and c.igIsWindowFocused(0)) self.view_opts_open = false;
        const label_w = fs * 7;
        const field_w = fs * 11;

        // Each folder remembers what you set here; this also hands its layout down.
        if (!b.virtualView()) {
            const names = [_][]const u8{ "List", "Icon", "Column", "Gallery" };
            var browse = b.browsesIn();
            var bb: [64]u8 = undefined;
            const bl: [:0]const u8 = std.mem.printSentinel(&bb, "Folders inside open in {s} view", .{names[@backingInt(b.view_mode)]}, 0) catch "Folders inside open this way";
            if (c.igCheckbox(bl.ptr, &browse)) b.setBrowsesIn(browse);
            if (c.igIsItemHovered(0)) c.igSetTooltip("Unless one of them has a view of its own.");
            c.igSeparator();
        }

        formLabel("Open as:", label_w);
        c.igSetNextItemWidth(field_w);
        var mode: c_int = @backingInt(b.view_mode);
        if (c.igCombo_Str("##vomode", &mode, "List\x00Icons\x00Columns\x00Gallery\x00", -1)) b.setViewMode(@fromBackingInt(@intCast(mode)));
        formLabel("Sort by:", label_w);
        c.igSetNextItemWidth(field_w);
        const sort_cols = [_]core.scan.SortColumn{ .name, .type, .date, .created, .size };
        var si: c_int = 0;
        for (sort_cols, 0..) |col, k| if (b.sort_order.column == col) {
            si = @intCast(k);
        };
        if (c.igCombo_Str("##vosort", &si, "Name\x00Kind\x00Date Modified\x00Date Created\x00Size\x00", -1)) {
            const col = sort_cols[@intCast(si)];
            b.setSort(col, col == .name or col == .type);
        }
        formLabel("Group by:", label_w);
        c.igSetNextItemWidth(field_w);
        var gi: c_int = @backingInt(b.group_by);
        if (c.igCombo_Str("##vogroup", &gi, "None\x00Kind\x00Date Modified\x00Size\x00Tags\x00", -1)) b.setGroupBy(@fromBackingInt(@intCast(gi)));
        formLabel("", label_w);
        var hid = b.show_hidden;
        if (c.igCheckbox("Show hidden files", &hid)) b.toggleHidden();
        formLabel("", label_w);
        var df = b.sort_order.dirs_first;
        if (c.igCheckbox("Folders first", &df)) b.toggleDirsFirst();

        switch (b.view_mode) {
            .grid, .gallery => {
                c.igSeparatorText("Icons");
                self.itemSizeSlider(b, label_w, field_w);
                if (b.view_mode == .grid) {
                    formLabel("Grid spacing:", label_w);
                    c.igSetNextItemWidth(field_w);
                    var sp: c_int = @intFromFloat(@round(self.actions.grid_spacing * 100));
                    if (c.igSliderInt("##vospace", &sp, 50, 200, "%d%%", 0)) self.actions.grid_spacing = @as(f32, @floatFromInt(sp)) / 100;
                    formLabel("Text size:", label_w);
                    c.igSetNextItemWidth(field_w);
                    var ts: c_int = @intFromFloat(@round(self.actions.text_scale * 100));
                    if (c.igSliderInt("##votext", &ts, 80, 150, "%d%%", 0)) self.actions.text_scale = @as(f32, @floatFromInt(ts)) / 100;
                    formLabel("Labels:", label_w);
                    if (c.igRadioButton_Bool("Bottom", !self.actions.label_right)) self.actions.label_right = false;
                    c.igSameLine(0, -1);
                    if (c.igRadioButton_Bool("Right", self.actions.label_right)) self.actions.label_right = true;
                    formLabel("", label_w);
                    _ = c.igCheckbox("Show item info", &self.actions.item_info);
                    if (c.igIsItemHovered(0)) c.igSetTooltip("Under each name: a folder's item count, an image's size in pixels, a file's size.");
                    formLabel("", label_w);
                    _ = c.igCheckbox("Show icon preview", &self.actions.icon_preview);
                }
            },
            .list => {
                c.igSeparatorText("Icons");
                self.itemSizeSlider(b, label_w, field_w);
                c.igSeparatorText("Show Columns");
                const cols = [_]struct { c_int, [:0]const u8 }{
                    .{ 1, "Size" },     .{ 2, "Kind" },         .{ 3, "Date Modified" }, .{ 4, "Date Created" },
                    .{ 5, "Accessed" }, .{ 6, "Changed" },      .{ 7, "Permissions" },   .{ 8, "Owner" },
                    .{ 9, "Group" },    .{ 10, "Link target" }, .{ 11, "Opens with" },
                };
                for (cols, 0..) |col, k| {
                    if (k % 2 == 1) c.igSameLine(fs * 9, -1);
                    var on = self.actions.columns_on[@intCast(col[0])];
                    if (c.igCheckbox(col[1].ptr, &on)) self.actions.column_toggle = .{ .col = col[0], .on = on };
                }
                c.igSpacing();
                _ = c.igCheckbox("Show folder sizes (files directly inside)", &self.folder_sizes);
            },
            .columns => {
                c.igSeparatorText("Icons");
                self.itemSizeSlider(b, label_w, field_w);
            },
        }
        c.igSeparator();
        if (c.igButton("Use as Defaults", cimgui.vec2(0, 0))) {
            self.prefs.useForAll(b.currentView());
            for (self.liveBrowsers()) |t| t.reloadView();
        }
        if (c.igBeginItemTooltip()) {
            cimgui.textUnformatted("Every folder opens this way, except ones you change afterwards.");
            c.igEndTooltip();
        }
    }

    /// drawHelp shows Help > Keyboard Shortcuts / About.
    fn drawHelp(self: *Shell) void {
        switch (self.help_pending) {
            .none => {},
            .shortcuts => c.igOpenPopup_Str("Keyboard Shortcuts", 0),
            .about => c.igOpenPopup_Str("About ZFD", 0),
        }
        self.help_pending = .none;
        const vp = c.igGetMainViewport();
        const center = cimgui.vec2(vp.*.WorkPos.x + vp.*.WorkSize.x * 0.5, vp.*.WorkPos.y + vp.*.WorkSize.y * 0.5);
        c.igSetNextWindowPos(center, c.ImGuiCond_Appearing, cimgui.vec2(0.5, 0.5));
        if (c.igBeginPopupModal("Keyboard Shortcuts", null, c.ImGuiWindowFlags_AlwaysAutoResize)) {
            const rows = [_][2][:0]const u8{
                .{ "Enter", "Open" },                          .{ "Space", "Quick Look" }, .{ "Ctrl+Shift+P", "Show Preview" }, .{ "Ctrl+J", "View Options" },
                .{ "Alt+Left / Alt+Right", "Back / Forward" }, .{ "Alt+Up, Backspace", "Enclosing folder / back" },         .{ "Ctrl+1 / 2 / 3 / 4", "List / Icons / Columns / Gallery" },
                .{ "Ctrl+L", "Go to folder (type a path)" },   .{ "Ctrl+F", "Search this folder" },                         .{ "Ctrl+H", "Show hidden files" },
                .{ "F2", "Rename (several: batch rename)" },   .{ "Del / Shift+Del", "Move to Trash / delete" },            .{ "Ctrl+C / X / V", "Copy / cut / paste" },
                .{ "Ctrl+Z / Ctrl+Shift+Z", "Undo / redo" },                         .{ "Ctrl+A / Ctrl+I", "Select all / invert" },               .{ "Alt+Enter", "Get Info" },
                .{ "Ctrl+T / Ctrl+W", "New tab / close tab" }, .{ "Ctrl+Shift+T", "Reopen closed tab" },                    .{ "Ctrl+Tab, Alt+1..9", "Switch tabs" },
                .{ "Ctrl+N", "New window" },                   .{ "Ctrl+Shift+N", "New folder" },                           .{ "Ctrl+D", "Add to Favourites" },
                .{ "F3", "Split view" },                       .{ "F4", "Open terminal here" },                             .{ "Ctrl+ + / - / 0", "Icon size (or Ctrl+scroll)" },
                .{ "F5", "Reload" },                           .{ "Ctrl+Alt+D", "Duplicate" },                              .{ "Ctrl+Alt+N", "New folder with selection" },
                .{ "Ctrl+Shift+H / D / O", "Home / Desktop / Documents" }, .{ "Ctrl+Alt+L", "Downloads" },          .{ "Ctrl+Shift+C / F", "Computer / Recent" },
                .{ "Ctrl+O, Ctrl+Down", "Open" },               .{ "Ctrl+Up", "Enclosing folder" },                          .{ "Ctrl+[ / Ctrl+]", "Back / Forward" },
                .{ "Tab / Shift+Tab", "Next / previous by name" }, .{ "Ctrl+Backspace", "Move to Trash" },                  .{ "Ctrl+Shift+Backspace", "Empty Trash" },
                .{ "Ctrl+K / Ctrl+Shift+K", "Connect to Server / Network" }, .{ "Ctrl+E", "Eject" },                         .{ "Ctrl+Shift+.", "Show hidden files" },
                .{ "Ctrl+M / F11", "Minimize / full screen" },  .{ "Ctrl+Q", "Close window" },                               .{ "Ctrl+R", "Reload" },
            };
            if (c.igBeginTable("##keys", 2, c.ImGuiTableFlags_RowBg | c.ImGuiTableFlags_SizingFixedFit, cimgui.vec2(0, 0), 0)) {
                for (rows) |r| {
                    c.igTableNextRow(0, 0);
                    _ = c.igTableNextColumn();
                    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
                    cimgui.textUnformatted(r[0]);
                    c.igPopStyleColor(1);
                    _ = c.igTableNextColumn();
                    cimgui.textUnformatted(r[1]);
                }
                c.igEndTable();
            }
            if (c.igButton("Close", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) c.igCloseCurrentPopup();
            c.igEndPopup();
        }
        c.igSetNextWindowPos(center, c.ImGuiCond_Appearing, cimgui.vec2(0.5, 0.5));
        if (c.igBeginPopupModal("About ZFD", null, c.ImGuiWindowFlags_AlwaysAutoResize)) {
            cimgui.textUnformatted("ZFD: a fast file manager and file dialog");
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
            cimgui.textUnformatted("Zig + Dear ImGui. Also serves the desktop's file dialogs (xdg-desktop-portal).");
            c.igPopStyleColor(1);
            if (c.igButton("Close", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) c.igCloseCurrentPopup();
            c.igEndPopup();
        }
    }

    /// drawTitle is the folder's name in the toolbar, a little larger, as in Finder.
    /// Clicking it switches to the typed path (same as Ctrl+L).
    fn drawTitle(self: *Shell, b: *Browser, width: f32) void {
        var tb: [512]u8 = undefined;
        const title: []const u8 = if (self.net_page)
            "Network"
        else if (b.in_recent)
            "Recent"
        else if (std.mem.eql(u8, b.dir, "/"))
            "Computer"
        else if (std.mem.eql(u8, b.dir, self.home))
            std.fs.path.basename(self.home)
        else
            std.fs.path.basename(b.dir);
        const pos = c.igGetCursorScreenPos();
        const h = toolbarH();
        // Like Finder: the title is only as wide as its text, and clicking it (left or
        // right) drops down the enclosing folders. Typing a path is Ctrl+L.
        const pad = c.igGetFontSize() * 0.4;
        cimgui.pushFontTimes(1.3);
        // A long name is cut short with "…" so it never pushes the buttons along.
        const z = ellipsize(&tb, title, width - pad * 2);
        const ts = c.igCalcTextSize(z.ptr, null, false, -1);
        c.igPopFont();
        const bw = @min(ts.x + pad * 2, width);
        const clicked = c.igInvisibleButton("##title", cimgui.vec2(bw, h), c.ImGuiButtonFlags_MouseButtonLeft | c.ImGuiButtonFlags_MouseButtonRight);
        const hovered = c.igIsItemHovered(0);
        if (c.igBeginItemTooltip()) {
            cimgui.textUnformatted(b.location());
            c.igEndTooltip();
        }
        const dl = c.igGetWindowDrawList();
        const open = c.igIsPopupOpen_Str("##titlemenu", 0);
        if (hovered or open)
            c.ImDrawList_AddRectFilled(dl, pos, cimgui.vec2(pos.x + bw, pos.y + h), c.igGetColorU32_Col(if (open) c.ImGuiCol_ButtonActive else c.ImGuiCol_ButtonHovered, 1), c.igGetStyle().*.FrameRounding, 0);
        cimgui.pushFontTimes(1.3);
        c.ImDrawList_PushClipRect(dl, pos, cimgui.vec2(pos.x + bw, pos.y + h), true);
        c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(pos.x + pad, pos.y + (h - ts.y) * 0.5), c.igGetColorU32_Col(c.ImGuiCol_Text, 1), z.ptr, null);
        c.ImDrawList_PopClipRect(dl);
        c.igPopFont();
        if (clicked and !b.in_recent) {
            c.igSetNextWindowPos(cimgui.vec2(pos.x, pos.y + h + 2), c.ImGuiCond_Always, cimgui.vec2(0, 0));
            c.igOpenPopup_Str("##titlemenu", 0);
        }
        if (c.igBeginPopup("##titlemenu", 0)) {
            defer c.igEndPopup();
            self.drawTitleMenu(b);
        }
    }

    /// drawTitleMenu lists the current folder and every folder enclosing it, nearest
    /// first, down to the computer: Finder's title-bar path menu. Middle-click opens
    /// one in a new tab.
    fn drawTitleMenu(self: *Shell, b: *Browser) void {
        const dir = b.dir;
        var ends: [128]usize = undefined;
        const n = pathSegments(dir, &ends);
        var k = n;
        while (k > 0) {
            k -= 1;
            const target = dir[0..ends[k]];
            const name = if (k == 0) "Computer" else segName(dir, ends, k);
            var lb: [300]u8 = undefined;
            const label = std.mem.printSentinel(&lb, "{s}##tm{d}", .{ name, k }, 0) catch continue;
            const icon: SideIcon = if (k == 0) .computer else if (std.mem.eql(u8, target, self.home)) .home else .folder;
            if (sideItem(label, k == n - 1, icon, false)) {
                // navigate frees the old b.dir, which `dir` and `target` point into.
                if (!std.mem.eql(u8, target, b.dir)) b.navigate(target) catch {};
                return;
            }
            if (c.igIsItemClicked(c.ImGuiMouseButton_Middle)) {
                self.newTabAt(target);
                c.igCloseCurrentPopup();
            }
        }
    }

    /// loadingShown reports whether `b` has been loading long enough to say so (0.4 s),
    /// so a quick folder opens without anything flashing.
    fn loadingShown(self: *Shell, b: *Browser) bool {
        // Still loading while the details (sizes, dates, icons) come in, after the
        // names are on screen: on a slow share that's most of the wait.
        if (!b.loading and !b.detailsPending()) {
            if (self.load_tab == b) self.load_tab = null;
            return false;
        }
        const now = c.igGetTime();
        if (self.load_tab != b) {
            self.load_tab = b;
            self.load_start = now;
        }
        return now - self.load_start >= 0.4;
    }

    /// drawLoadingBar is the thin bar on the toolbar's hairline (at `y`) while a slow
    /// folder loads: an accent-coloured stretch sweeping left to right, as a browser
    /// shows a page loading. A folder has no known length, so it sweeps rather than
    /// fills. It fades in and out; with Reduce motion it's a still, full-width line.
    fn drawLoadingBar(self: *Shell, b: *Browser, y: f32) void {
        const a = anim.toward(c.igGetID_Str("##loadbar"), self.loadingShown(b), anim.normal);
        if (a <= 0.01) return;
        const dl = c.igGetWindowDrawList();
        const x0 = c.igGetWindowPos().x;
        const w = c.igGetWindowWidth();
        const h = @max(2.0, @round(2.0 * self.style_scale));
        var col = theme.p().accent;
        col.w *= a;
        const u = c.igGetColorU32_Vec4(col);
        if (anim.reduce_motion) {
            c.ImDrawList_AddRectFilled(dl, cimgui.vec2(x0, y - h * 0.5), cimgui.vec2(x0 + w, y + h * 0.5), u, 0, 0);
            return;
        }
        // One pass every 1.4 s, easing in and out, entering and leaving off the edges.
        const t = core.anim.Ease.in_out_cubic.at(anim.cycle(1.4));
        const seg = w * 0.3;
        const left = x0 - seg + (w + seg) * t;
        c.ImDrawList_PushClipRect(dl, cimgui.vec2(x0, y - h), cimgui.vec2(x0 + w, y + h), true);
        c.ImDrawList_AddRectFilled(dl, cimgui.vec2(left, y - h * 0.5), cimgui.vec2(left + seg, y + h * 0.5), u, h * 0.5, 0);
        c.ImDrawList_PopClipRect(dl);
    }

    /// itemSizeSlider is View Options' Icon size for `b`'s view.
    fn itemSizeSlider(self: *Shell, b: *Browser, label_w: f32, field_w: f32) void {
        const s = self.actions.itemSize(b.view_mode);
        formLabel("Icon size:", label_w);
        c.igSetNextItemWidth(field_w);
        var pct: c_int = @intFromFloat(@round(s.v.* * 100));
        if (c.igSliderInt("##voicon", &pct, @intFromFloat(s.min * 100), @intFromFloat(s.max * 100), "%d%%", 0)) s.v.* = @as(f32, @floatFromInt(pct)) / 100;
    }

    /// drawBottomBar is Finder's path bar (the breadcrumbs) with the status line
    /// (item count, selection, free space, errors) under it.
    fn drawBottomBar(self: *Shell, b: *Browser) void {
        const path = self.showsBar(.path_bar);
        const status = self.showsBar(.status_bar);
        if (!path and !status) return;
        c.igSeparator();
        if (path) {
            // Click its empty part (or Ctrl+L) and the path bar itself becomes the field.
            if (self.path_edit) self.drawPathField(b, 1) else self.drawBreadcrumbs(b, c.igGetContentRegionAvail().x);
        }
        if (status) drawStatus(self, b);
    }

    /// preparePath runs before the path field can draw (in the path bar, or the
    /// toolbar when that's hidden): Ctrl+L switches it on, and while it isn't being
    /// typed in it shows the current folder.
    fn preparePath(self: *Shell, b: *Browser) void {
        if (self.focus_path) self.path_edit = true;
        if (!self.path_edit) self.path_active = false; // no text field: the list gets the keys back
        if (!self.path_active) {
            self.syncPath(b);
            // While unfocused, keep the autocomplete baseline equal to the shown path, so
            // gaining focus never fires a spurious suggestion (the callback only re-suggests
            // when the typed prefix GROWS past this baseline).
            self.setAcTyped(std.mem.sliceTo(&self.path_buf, 0));
            self.ac_active = false;
        }
    }

    /// bottomBarHeight is what drawBottomBar takes (reserved below the body).
    fn bottomBarHeight(self: *Shell) f32 {
        const st = c.igGetStyle();
        const path = self.showsBar(.path_bar);
        const status = self.showsBar(.status_bar);
        if (!path and !status) return 0;
        var h: f32 = st.*.ItemSpacing.y + 2;
        if (path) h += c.igGetFrameHeightWithSpacing();
        if (status) h += c.igGetTextLineHeightWithSpacing();
        return h;
    }

    /// Bar is a part of the window the View menu can hide.
    const Bar = enum(u3) { toolbar, sidebar, path_bar, status_bar };

    fn showsBar(self: *const Shell, bar: Bar) bool {
        return self.bars_hide & (@as(u8, 1) << @backingInt(bar)) == 0;
    }

    fn toggleBar(self: *Shell, bar: Bar) void {
        self.bars_hide ^= @as(u8, 1) << @backingInt(bar);
    }

    /// drawPathField is the editable path (Ctrl+L, or a click on the empty part of the
    /// path bar), drawn in the path bar. It returns to breadcrumbs once it loses focus.
    fn drawPathField(self: *Shell, b: *Browser, right_w: f32) void {
        if (self.focus_path) {
            c.igSetKeyboardFocusHere(0);
            self.focus_path = false;
        }
        c.igSetNextItemWidth(-right_w);
        // CallbackAlways keeps an inline directory suggestion in sync as you type;
        // CallbackCompletion makes Tab accept it (instead of moving focus). See
        // pathAutoComplete. EnterReturnsTrue navigates to whatever's in the box, which,
        // with a suggestion showing, is the full completed path (Enter accepts too).
        const pflags = c.ImGuiInputTextFlags_EnterReturnsTrue |
            c.ImGuiInputTextFlags_CallbackAlways |
            c.ImGuiInputTextFlags_CallbackCompletion;
        const submitted = c.igInputText("##path", &self.path_buf, self.path_buf.len, pflags, pathAutoComplete, self);
        self.path_active = c.igIsItemActive();
        if (submitted) {
            const typed = std.mem.trim(u8, std.mem.sliceTo(&self.path_buf, 0), " \t");
            // "~/x" is in your home; a bare "x" is inside the folder shown.
            var rb: [std.fs.max_path_bytes]u8 = undefined;
            const target: []const u8 = if (std.mem.eql(u8, typed, "~") or std.mem.startsWith(u8, typed, "~/"))
                (std.mem.print(&rb, "{s}{s}", .{ self.home, typed[1..] }) catch typed)
            else if (typed.len > 0 and typed[0] != '/' and !core.recent.isUri(typed))
                (std.mem.print(&rb, "{s}/{s}", .{ if (std.mem.eql(u8, b.dir, "/")) "" else b.dir, typed }) catch typed)
            else
                typed;
            if (target.len > 0) b.navigate(target) catch {};
            // EnterReturnsTrue deactivates the input on submit, so path_active would
            // flip false this frame and re-enable the list's keyboard, which then sees
            // the SAME Enter and opens the highlighted row, landing a folder too deep.
            // Keep the list's keys suppressed for this frame.
            self.path_active = true;
        }
        if (c.igIsItemDeactivated()) self.path_edit = false;
    }

    /// drawBreadcrumbs shows the current path as clickable segments (Explorer/Dolphin
    /// style). Click a segment → go there; middle-click → new tab; drop files onto one
    /// → move/copy there. The blank rest of the bar switches to the text field. When
    /// the path is too long, leading segments collapse into "…".
    fn drawBreadcrumbs(self: *Shell, b: *Browser, width: f32) void {
        const style = c.igGetStyle();
        const h = c.igGetFrameHeight();
        const p0 = c.igGetCursorScreenPos();
        const dl = c.igGetWindowDrawList();
        _ = dl;

        // (Inside an archive the path goes through it: "…/Downloads/pics.zip/2025".)
        const dir = b.dir;

        var ends: [128]usize = undefined;
        var n = pathSegments(dir, &ends);
        if (b.in_recent) n = 0; // a virtual place: one "Recent" crumb, no path segments
        const sep_w = c.igCalcTextSize("\u{203A}", null, false, -1).x + 2;
        const pad = style.*.FramePadding.x * 2;
        // Keep as many trailing segments as fit; the dropped head becomes "…".
        var first: usize = 0;
        while (first + 1 < n) {
            var w: f32 = if (first > 0) c.igCalcTextSize("\u{2026}", null, false, -1).x + pad + sep_w else 0;
            var k = first;
            while (k < n) : (k += 1) w += c.igCalcTextSize(segName(dir, ends, k).ptr, segName(dir, ends, k).ptr + segName(dir, ends, k).len, false, -1).x + pad + sep_w;
            if (w <= width - 40) break; // leave a clickable gap for "edit"
            first += 1;
        }

        c.igPushStyleColor_Vec4(c.ImGuiCol_Button, cimgui.vec4(0, 0, 0, 0));
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_ItemSpacing, cimgui.vec2(0, style.*.ItemSpacing.y));
        defer {
            c.igPopStyleVar(1);
            c.igPopStyleColor(1);
        }
        if (b.in_recent) {
            _ = c.igButton("Recent##crumbrecent", cimgui.vec2(0, 0));
            c.igSameLine(0, 0);
        }
        if (first > 0) {
            c.igAlignTextToFramePadding();
            cimgui.textUnformatted(" \u{2026} ");
            c.igSameLine(0, 0);
        }
        var k = first;
        while (k < n) : (k += 1) {
            if (k > first or first > 0) { // a separator before every segment but the first
                c.igAlignTextToFramePadding();
                cimgui.textUnformatted("\u{203A}");
                c.igSameLine(0, 2);
            }
            const name = segName(dir, ends, k);
            var lb: [300]u8 = undefined;
            const label = std.mem.printSentinel(&lb, "{s}##crumb{d}", .{ name, k }, 0) catch continue;
            const target = dir[0..ends[k]];
            if (c.igButton(label.ptr, cimgui.vec2(0, 0)) and !std.mem.eql(u8, target, b.dir)) {
                // navigate frees the old b.dir, which `dir` and `target` point into:
                // the rest of the bar waits for the next frame.
                b.navigate(target) catch {};
                return;
            }
            if (c.igIsItemClicked(c.ImGuiMouseButton_Middle)) self.newTabAt(target);
            self.dropZone(target);
            c.igSameLine(0, 0);
        }
        // The rest of the bar: click it to type a path.
        const used = c.igGetCursorScreenPos().x - p0.x;
        const rest = @max(width - used, 1);
        if (c.igInvisibleButton("##crumbedit", cimgui.vec2(rest, h), 0)) {
            self.path_edit = true;
            self.focus_path = true;
        }
        if (c.igIsItemHovered(0)) c.igSetMouseCursor(c.ImGuiMouseCursor_TextInput);
    }

    fn syncPath(self: *Shell, b: *Browser) void {
        const loc = b.location();
        const n = @min(loc.len, self.path_buf.len - 1);
        @memcpy(self.path_buf[0..n], loc[0..n]);
        self.path_buf[n] = 0;
    }

    // --- Address-bar inline autocomplete --------------------------------------

    fn acTyped(self: *Shell) []const u8 {
        return self.ac_typed[0..self.ac_typed_len];
    }
    fn setAcTyped(self: *Shell, s: []const u8) void {
        const n = @min(s.len, self.ac_typed.len);
        @memcpy(self.ac_typed[0..n], s[0..n]);
        self.ac_typed_len = n;
    }

    /// pathSuggestion returns the completed path for the address-bar text `typed` plus
    /// the suffix beyond it (the letters to insert+select). Null when `typed` isn't an
    /// absolute path with a matchable trailing leaf. `full` is owned (caller frees).
    fn pathSuggestion(self: *Shell, typed: []const u8) ?struct { full: []u8, suffix: []const u8 } {
        if (typed.len == 0 or typed[0] != '/') return null; // the bar always shows an absolute path
        const sp = core.pathcomplete.splitLeaf(typed);
        if (sp.leaf.len == 0) return null;
        // sp.dir keeps its trailing '/'; the parent to scan drops it (except root itself).
        const dir_path = if (sp.dir.len > 1) sp.dir[0 .. sp.dir.len - 1] else "/";
        const name = core.pathcomplete.completeName(self.io, self.alloc, dir_path, sp.leaf) orelse return null;
        defer self.alloc.free(name);
        const full = self.alloc.print("{s}{s}", .{ sp.dir, name }) catch return null;
        if (full.len <= typed.len or !std.mem.startsWith(u8, full, typed)) {
            self.alloc.free(full);
            return null;
        }
        return .{ .full = full, .suffix = full[typed.len..] };
    }
    fn syncSearch(self: *Shell, b: *Browser) void {
        const q = b.search.items;
        const n = @min(q.len, self.search_buf.len - 1);
        @memcpy(self.search_buf[0..n], q[0..n]);
        self.search_buf[n] = 0;
    }

    // --- CSD window controls ---------------------------------------------------

    fn glfwWin(self: *Shell) ?*c.GLFWwindow {
        return @ptrCast(self.win);
    }
    /// startWm kicks off a WM move/resize once per press. The guard (`wm_active`,
    /// cleared when the real mouse button goes up) stops us from re-sending
    /// _NET_WM_MOVERESIZE every frame (the flood that caused the lag).
    fn startWm(self: *Shell, dir: x11.Direction) void {
        if (self.wm_active) return;
        self.wm_active = true;
        x11.startMoveResize(self.win, dir);
        // The WM grabbed the pointer; ImGui won't get the button release. Inject it so
        // hover/highlight works immediately after the move instead of needing a click.
        cimgui.releaseMouse();
    }
    fn minimize(self: *Shell) void {
        c.glfwIconifyWindow(self.glfwWin());
    }
    fn toggleMaximize(self: *Shell) void {
        const w = self.glfwWin();
        if (c.glfwGetWindowAttrib(w, c.GLFW_MAXIMIZED) != 0) c.glfwRestoreWindow(w) else c.glfwMaximizeWindow(w);
    }
    fn closeWindow(self: *Shell) void {
        c.glfwSetWindowShouldClose(self.glfwWin(), 1);
    }

    fn drawResizeGrips(self: *Shell) void {
        if (c.glfwGetWindowAttrib(self.glfwWin(), c.GLFW_MAXIMIZED) != 0) return;
        // Only the window's own edge: not where something lies over it (Quick Look, a
        // menu, a dialog), whose clicks are its own.
        if (!c.igIsWindowHovered(c.ImGuiHoveredFlags_RootAndChildWindows | c.ImGuiHoveredFlags_AllowWhenBlockedByActiveItem)) return;
        const vp = c.igGetMainViewport();
        const p = vp.*.WorkPos; // the window sits at WorkPos/WorkSize, not Pos/Size
        const s = vp.*.WorkSize;
        const g: f32 = 10; // edge thickness
        const cg: f32 = 22; // bottom corners' reach (a bigger target than the edges)
        const tg: f32 = 12; // top corners': just the corner, clear of the window buttons
        // Corners first, then the edges span the gap between them.
        self.grip(p.x, p.y, tg, tg, .size_topleft, c.ImGuiMouseCursor_ResizeNWSE);
        self.grip(p.x + s.x - tg, p.y, tg, tg, .size_topright, c.ImGuiMouseCursor_ResizeNESW);
        self.grip(p.x + s.x - cg, p.y + s.y - cg, cg, cg, .size_bottomright, c.ImGuiMouseCursor_ResizeNWSE);
        self.grip(p.x, p.y + s.y - cg, cg, cg, .size_bottomleft, c.ImGuiMouseCursor_ResizeNESW);
        self.grip(p.x + tg, p.y, s.x - 2 * tg, g * 0.6, .size_top, c.ImGuiMouseCursor_ResizeNS);
        self.grip(p.x + s.x - g, p.y + tg, g, s.y - tg - cg, .size_right, c.ImGuiMouseCursor_ResizeEW);
        self.grip(p.x + cg, p.y + s.y - g, s.x - 2 * cg, g, .size_bottom, c.ImGuiMouseCursor_ResizeNS);
        self.grip(p.x, p.y + tg, g, s.y - tg - cg, .size_left, c.ImGuiMouseCursor_ResizeEW);
    }
    /// grip hit-tests an edge band with clip=false (invisible buttons get clipped by
    /// the window's content region, which is why only the corner used to work).
    fn grip(self: *Shell, x: f32, y: f32, w: f32, h: f32, dir: x11.Direction, cursor: c_int) void {
        const p_min = cimgui.vec2(x, y);
        const p_max = cimgui.vec2(x + @max(w, 1), y + @max(h, 1));
        if (c.igIsMouseHoveringRect(p_min, p_max, false)) {
            c.igSetMouseCursor(cursor);
            if (c.igIsMouseClicked_Bool(0, false)) {
                self.grip_press = true;
                self.startWm(dir);
            }
        }
    }

    // --- XDND drag-out ---------------------------------------------------------

    fn maybeDragOut(self: *Shell, b: *Browser) void {
        if (self.win == null) return;
        if (self.drag_active) return; // already dragged out this press; wait for the button to lift
        const payload = c.igGetDragDropPayload();
        if (payload == null) return;
        // Only OUR row drag becomes an XDND drag-out. GetDragDropPayload reports any live
        // ImGui drag, so without the type check a future internal drag (reordering
        // something, a dragged splitter that grew a payload) would hand file URIs to
        // whatever window the pointer crossed.
        const dtype: [*:0]const u8 = @ptrCast(&payload.*.DataType);
        if (!std.mem.eql(u8, std.mem.span(dtype), table.DRAG_PAYLOAD)) return;
        const src = self.actions.dragSource(payload) orelse b;
        if (!self.mouseOutside()) return;
        // The snapshot, not the live selection: by the time the pointer has left the
        // window the listing may have been rebuilt underneath it.
        const dragged = src.dragPaths();
        if (dragged.len == 0) return;
        // Out of an archive, another app needs real files: each dragged item is taken
        // out (alone, to a temporary folder) and that's what's handed over. This waits
        // for the extraction; a big file holds the drag up that long.
        var taken = std.ArrayList([]u8).empty;
        defer {
            for (taken.items) |t| b.alloc.free(t);
            taken.deinit(b.alloc);
        }
        if (src.insideArchive() != null) {
            const tf = self.temp_files orelse return;
            for (dragged) |p| {
                const out = tf.takeOut(b.alloc, p, null) catch continue;
                taken.append(b.alloc, out) catch b.alloc.free(out);
            }
            if (taken.items.len == 0) return;
        }
        const paths: []const []const u8 = if (taken.items.len > 0) taken.items else dragged;
        // Two flavours of the same set: text/uri-list (what file managers and image
        // editors want) and plain text (what chat/editor windows paste). Advertising
        // both is why a drag into a text field now yields paths instead of nothing.
        var uris = std.ArrayList(u8).empty;
        defer uris.deinit(b.alloc);
        var plain = std.ArrayList(u8).empty;
        defer plain.deinit(b.alloc);
        for (paths) |p| {
            // Percent-encode the path (the same RFC-3986 encoder .trashinfo uses). A raw
            // "Holiday #2/my photo.png" is not a valid URI: receivers truncate it at the
            // '#' or choke on the space, which is what made drag-out hand some apps the
            // wrong file, or nothing at all.
            const enc = core.fsops.percentEncodePath(b.alloc, p) catch return;
            defer b.alloc.free(enc);
            uris.appendSlice(b.alloc, "file://") catch return;
            uris.appendSlice(b.alloc, enc) catch return;
            uris.appendSlice(b.alloc, "\r\n") catch return;
            plain.appendSlice(b.alloc, p) catch return;
            plain.append(b.alloc, '\n') catch return;
        }
        if (plain.items.len > 0) _ = plain.pop(); // no trailing newline on the text flavour
        self.drag_active = true;
        x11.startDragOut(self.win, uris.items, plain.items);
        // startDragOut's X pointer grab swallowed the mouse-button release, so GLFW/ImGui
        // never saw it and still believe button 0 is held. That keeps ImGui's drag-drop
        // payload "live", so without this we'd re-enter startDragOut every frame, and the drop
        // target keeps getting XdndEnter and never lets go ("Discord keeps asking for
        // files"). Inject the release so ImGui ends the drag exactly once, exactly as
        // startWm does after a WM move/resize grab.
        cimgui.releaseMouse();
    }
    fn mouseOutside(self: *Shell) bool {
        const w = self.glfwWin();
        var cx: f64 = 0;
        var cy: f64 = 0;
        c.glfwGetCursorPos(w, &cx, &cy);
        var ww: c_int = 0;
        var wh: c_int = 0;
        c.glfwGetWindowSize(w, &ww, &wh);
        return cx < 0 or cy < 0 or cx > @as(f64, @floatFromInt(ww)) or cy > @as(f64, @floatFromInt(wh));
    }

    // --- --pick dialog ---------------------------------------------------------

    /// requestSave resolves a Save accept: finish immediately when the target file is
    /// new, or raise the overwrite confirmation when it already exists. Callers ensure
    /// save mode + a non-empty Name.
    ///
    /// Refuses when the current folder failed to load (err_name set): the Save path is
    /// `<current dir>/<name>`, and if we never successfully read that directory we can't
    /// trust it exists/is-writable: handing the path back anyway is how a save landed in
    /// an unverified folder after an NFS BadPathName. The user sees the error + a Retry
    /// button and can re-load the folder (usually a transient) before saving.
    fn requestSave(self: *Shell, d: *Dialog) void {
        if (self.activeBrowser().err_name != null) return;
        if (self.saveTargetExists(d)) d.confirm_overwrite = true else d.done = true;
    }

    /// saveTargetExists reports whether "<current dir>/<Name>" already exists.
    fn saveTargetExists(self: *Shell, d: *Dialog) bool {
        const name = std.mem.trim(u8, std.mem.sliceTo(&d.name_buf, 0), " \t");
        if (name.len == 0) return false;
        // The folder's listing already says (no disk access on Save).
        const l = self.activeBrowser().listing orelse return false;
        for (l.entries) |e| if (std.mem.eql(u8, e.name, name)) return true;
        return false;
    }

    /// drawOverwriteModal shows the "replace existing file?" confirmation before a Save
    /// clobbers a file: the same guard native Save dialogs give you. Replace finishes
    /// the dialog; Cancel returns to it.
    fn drawOverwriteModal(_: *Shell, d: *Dialog) void {
        if (d.confirm_overwrite) {
            c.igOpenPopup_Str("Replace file?", 0);
            d.confirm_overwrite = false;
        }
        const vp = c.igGetMainViewport();
        const center = cimgui.vec2(vp.*.WorkPos.x + vp.*.WorkSize.x * 0.5, vp.*.WorkPos.y + vp.*.WorkSize.y * 0.5);
        c.igSetNextWindowPos(center, c.ImGuiCond_Appearing, cimgui.vec2(0.5, 0.5));
        if (c.igBeginPopupModal("Replace file?", null, c.ImGuiWindowFlags_AlwaysAutoResize)) {
            const name = std.mem.sliceTo(&d.name_buf, 0);
            var buf: [600]u8 = undefined;
            const msg = std.mem.print(&buf, "\"{s}\" already exists in this folder.\nReplace it?", .{name}) catch "Replace the existing file?";
            cimgui.textUnformatted(msg);
            c.igSeparator();
            if (c.igButton("Replace", cimgui.vec2(90, 0))) {
                d.done = true;
                c.igCloseCurrentPopup();
            }
            c.igSameLine(0, -1);
            if (c.igButton("Cancel", cimgui.vec2(90, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) c.igCloseCurrentPopup();
            c.igEndPopup();
        }
    }

    /// pointAt navigates the chooser to an absolute path dropped onto it: a folder
    /// opens; a file opens its folder with it selected (and, in Save mode, fills Name).
    pub fn pointAt(self: *Shell, path: []const u8) void {
        // Folder or file? Asked in the background; pointAtKind acts on the answer.
        setField(&self.point_path, path);
        if (self.bg) |g| g.probe(bg_point, &.{path});
    }

    fn pointAtKind(self: *Shell, path: []const u8, is_dir: bool) void {
        const b = self.activeBrowser();
        if (is_dir) {
            b.navigate(path) catch {};
            return;
        }
        const dir = std.fs.path.dirname(path) orelse return;
        const name = std.fs.path.basename(path);
        const same = std.mem.eql(u8, dir, b.dir);
        if (!same) b.navigate(dir) catch return;
        b.setPendingSelect(name);
        if (same) b.refresh(); // same folder: re-list so the pending select applies
        if (self.dialog) |*d| if (d.cfg.save) {
            const n = @min(name.len, d.name_buf.len - 1);
            @memcpy(d.name_buf[0..n], name[0..n]);
            d.name_buf[n] = 0;
            // The Name field is usually the ACTIVE widget, and ImGui edits its own copy
            // of an active field's text, so a write to name_buf alone would be ignored.
            // Drop the activation so the field reloads, then focus it again.
            c.igClearActiveID();
            d.name_select = true; // select the stem, ready to type over it
            d.name_focus = true;
        };
    }

    pub fn dialogResult(self: *Shell, alloc: std.mem.Allocator) !?[][]u8 {
        const d = &(self.dialog orelse return null);
        if (!d.done or d.cancelled) return null;
        const b = self.activeBrowser();
        if (d.cfg.save) {
            const name = std.mem.trim(u8, std.mem.sliceTo(&d.name_buf, 0), " \t");
            if (name.len == 0) return null;
            const p = try std.fs.path.join(alloc, &.{ b.dir, name });
            const out = try alloc.alloc([]u8, 1);
            out[0] = p;
            return out;
        }
        var sel = try b.selectedPaths();
        if (d.cfg.directory and sel.len == 0) {
            freeOwned(alloc, sel);
            const out = try alloc.alloc([]u8, 1);
            out[0] = try alloc.dupe(u8, b.dir);
            return out;
        }
        if (sel.len == 0) {
            freeOwned(alloc, sel);
            return null;
        }
        if (!d.cfg.multiple and sel.len > 1) {
            for (sel[1..]) |p| alloc.free(p);
            return try alloc.realloc(sel, 1);
        }
        return sel;
    }
    pub fn dialogDone(self: *Shell) bool {
        const d = self.dialog orelse return false;
        return d.done;
    }
};

/// pathAutoComplete is the address bar's InputText callback (Explorer-style inline
/// completion). Two events:
///   • CallbackCompletion (Tab): accept the current suggestion; collapse the selection
///     and drop the cursor at the end, so a following '/' suggests the next level.
///   • CallbackAlways: whenever the *typed* prefix (the buffer minus our selected tail)
///     grows, look up the matching subdirectory and insert its remaining letters as a
///     selected tail. Typing overwrites the selection; backspacing removes it and, since
///     the prefix then shrank rather than grew, we don't fight the user by re-suggesting.
/// UserData is the *Shell. One readdir per keystroke on the render thread, deliberate
/// (interactive completion needs a synchronous answer); it's the cheap no-stat pass.
fn pathAutoComplete(raw: [*c]c.ImGuiInputTextCallbackData) callconv(.c) c_int {
    const data: *cimgui.InputTextCallbackData = @ptrCast(@alignCast(raw));
    const self: *Shell = @ptrCast(@alignCast(data.UserData orelse return 0));
    const buf_ptr = data.Buf orelse return 0;
    const buf_len: usize = @intCast(data.BufTextLen);
    const buf = buf_ptr[0..buf_len];

    if (data.EventFlag == c.ImGuiInputTextFlags_CallbackCompletion) {
        if (self.ac_active) {
            data.SelectionStart = data.BufTextLen;
            data.SelectionEnd = data.BufTextLen;
            data.CursorPos = data.BufTextLen;
            self.setAcTyped(buf); // the whole path is now the confirmed prefix
            self.ac_active = false;
        }
        return 0;
    }

    // CallbackAlways: the typed prefix excludes our auto tail (a selection reaching the
    // buffer end while a suggestion is live).
    const has_sel = data.SelectionStart != data.SelectionEnd;
    const sel_to_end = data.SelectionEnd == data.BufTextLen;
    const typed_len: usize = if (self.ac_active and has_sel and sel_to_end)
        @intCast(data.SelectionStart)
    else
        buf_len;
    const typed = buf[0..typed_len];

    if (std.mem.eql(u8, typed, self.acTyped())) {
        // Unchanged prefix → stable. Re-derive whether a tail is actually still present
        // (a backspace may have deleted it), so ac_active never goes stale.
        self.ac_active = has_sel and sel_to_end and typed_len < buf_len;
        return 0;
    }
    const grew = typed_len > self.ac_typed_len and std.mem.startsWith(u8, typed, self.acTyped());
    self.setAcTyped(typed);
    self.ac_active = false;
    if (!grew) return 0; // a deletion/edit: track it but don't re-suggest

    // Strip any stale tail so the buffer is exactly `typed`, then insert the match.
    const typed_c: c_int = @intCast(typed_len);
    if (data.BufTextLen > typed_c)
        cimgui.ImGuiInputTextCallbackData_DeleteChars(raw, typed_c, data.BufTextLen - typed_c);
    const sugg = self.pathSuggestion(typed) orelse return 0;
    defer self.alloc.free(sugg.full);
    cimgui.ImGuiInputTextCallbackData_InsertChars(raw, typed_c, sugg.suffix.ptr, sugg.suffix.ptr + sugg.suffix.len);
    data.SelectionStart = typed_c;
    data.SelectionEnd = @intCast(typed_len + sugg.suffix.len);
    data.CursorPos = data.SelectionEnd;
    self.ac_active = true;
    return 0;
}

/// progressOverlay formats the bar's caption: byte totals when known, else a file
/// count. Returns a NUL-terminated string for igProgressBar's overlay.
fn progressOverlay(buf: []u8, snap: core.progress.Snapshot) [:0]const u8 {
    if (snap.bytes_total > 0) {
        var a: [24]u8 = undefined;
        var b: [24]u8 = undefined;
        return std.mem.printSentinel(buf, "{s} / {s}", .{
            core.scan.humanizeSize(&a, snap.bytes_done),
            core.scan.humanizeSize(&b, snap.bytes_total),
        }, 0) catch "";
    }
    return std.mem.printSentinel(buf, "{d} / {d} files", .{ snap.files_done, snap.files_total }, 0) catch "";
}

fn drawStatus(self: *Shell, b: *Browser) void {
    drawIconSizeSlider(self, b);
    if (b.deepStatus()) |ds| {
        var buf: [160]u8 = undefined;
        const msg = if (ds.text and !ds.sub)
            (if (!ds.done)
                std.mem.print(&buf, "Searching inside files\u{2026} {d} found", .{ds.found}) catch "Searching\u{2026}"
            else
                std.mem.print(&buf, "{d} file{s} with that text", .{ ds.found, if (ds.found == 1) "" else "s" }) catch "")
        else if (!ds.done)
            std.mem.print(&buf, "Searching {s}subfolders\u{2026} {d} found ({d} folders)", .{ if (ds.text) "inside files in " else "", ds.found, ds.dirs }) catch "Searching\u{2026}"
        else
            std.mem.print(&buf, "{d} found in {d} folders{s}", .{ ds.found, ds.dirs, if (ds.capped) " (showing the first 5000)" else "" }) catch "";
        cimgui.textUnformatted(msg);
        if (!ds.done) {
            c.igSameLine(0, -1);
            if (c.igSmallButton("Stop##deep")) b.stopDeepWalk();
        }
        return;
    }
    // Loading but not for long yet: the folder on screen keeps its line (no blank flash).
    if (b.loading and self.loadingShown(b)) {
        // The bar under the toolbar shows it's working (drawLoadingBar); the word here
        // fades in with it, so a quick folder flashes neither.
        var col = theme.dim();
        col.w *= anim.toward(c.igGetID_Str("##loadshown"), self.loadingShown(b), anim.normal);
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, col);
        cimgui.textUnformatted("Loading\u{2026}");
        c.igPopStyleColor(1);
        return;
    }
    drawReadOnly(b);
    if (b.err_name) |e| {
        var buf: [256]u8 = undefined;
        const msg = std.mem.print(&buf, "error: {s}", .{e}) catch "error";
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.err());
        cimgui.textUnformatted(msg);
        c.igPopStyleColor(1);
        // Re-load the same folder on demand. NFS BadPathName is usually transient, so a
        // Retry beats forcing the user to navigate away and back (and Save stays blocked
        // until the folder reads cleanly).
        c.igSameLine(0, -1);
        if (c.igButton("Retry", cimgui.vec2(0, 0))) b.refresh();
        return;
    }
    var buf: [128]u8 = undefined;
    const n = b.count();
    const sel = b.sel.count();
    const msg = if (sel > 0) blk: {
        var szbuf: [24]u8 = undefined;
        const sz = core.scan.humanizeSize(&szbuf, b.selectionSize());
        break :blk std.mem.print(&buf, "{d} item{s}, {d} selected ({s})", .{ n, plural(n), sel, sz }) catch return;
    } else std.mem.print(&buf, "{d} item{s}", .{ n, plural(n) }) catch return;
    cimgui.textUnformatted(msg);
    // Free space of the folder's filesystem (measured with the listing, off-thread).
    if (b.listing) |l| if (l.total_bytes > 0) {
        var fb: [24]u8 = undefined;
        var tb: [24]u8 = undefined;
        var sbuf: [80]u8 = undefined;
        const free_s = std.mem.print(&sbuf, "  \u{00B7}  {s} free of {s}", .{
            core.scan.humanizeSize(&fb, l.free_bytes), core.scan.humanizeSize(&tb, l.total_bytes),
        }) catch "";
        c.igSameLine(0, 0);
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
        cimgui.textUnformatted(free_s);
        c.igPopStyleColor(1);
    };
    if (b.op_err) |e| {
        c.igSameLine(0, -1);
        var ebuf: [128]u8 = undefined;
        const emsg = std.mem.print(&ebuf, "  (failed: {s})", .{core.fsops.errorMessage(e)}) catch return;
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.warn());
        cimgui.textUnformatted(emsg);
        c.igPopStyleColor(1);
    }
}

/// drawIconSizeSlider is Finder's icon size slider at the status line's right end: a
/// thin track between a small and a large icon, the same setting as View Options'
/// Icon size for the view on screen. Leaves the cursor where it was.
fn drawIconSizeSlider(self: *Shell, b: *Browser) void {
    const back = c.igGetCursorScreenPos();
    defer c.igSetCursorScreenPos(back);
    const h = c.igGetTextLineHeight();
    const w = @round(h * 7);
    const right = c.igGetWindowPos().x + c.igGetWindowWidth() - c.igGetStyle().*.WindowPadding.x;
    const sq_s = @round(h * 0.4); // the small icon
    const sq_l = @round(h * 0.75); // the large one
    const gap = @round(h * 0.4);
    const x0 = right - sq_l - gap - w - gap - sq_s;
    const cy = @round(back.y + h * 0.5);
    const dl = c.igGetWindowDrawList();
    const pal = theme.p();
    const dim = c.igGetColorU32_Vec4(theme.dim());
    c.ImDrawList_AddRect(dl, cimgui.vec2(x0, cy - sq_s * 0.5), cimgui.vec2(x0 + sq_s, cy + sq_s * 0.5), dim, 1, 1, 0); // rounding, thickness, flags
    c.ImDrawList_AddRect(dl, cimgui.vec2(right - sq_l, cy - sq_l * 0.5), cimgui.vec2(right, cy + sq_l * 0.5), dim, 2, 1, 0);

    const tx0 = x0 + sq_s + gap;
    const tx1 = tx0 + w;
    c.igSetCursorScreenPos(cimgui.vec2(tx0 - h * 0.3, back.y));
    _ = c.igInvisibleButton("##iconsize", cimgui.vec2(w + h * 0.6, h), 0);
    const s = self.actions.itemSize(b.view_mode);
    const span = s.max - s.min;
    if (c.igIsItemActive()) {
        const f = std.math.clamp((c.igGetMousePos().x - tx0) / w, 0, 1);
        s.v.* = s.min + f * span;
    }
    if (c.igIsItemHovered(0) and !c.igIsItemActive()) c.igSetTooltip("Icon size (Ctrl+scroll)");
    const f = (s.v.* - s.min) / span;
    const kx = @round(tx0 + f * w);
    const th: f32 = @max(2, @round(h * 0.15));
    c.ImDrawList_AddRectFilled(dl, cimgui.vec2(tx0, cy - th * 0.5), cimgui.vec2(tx1, cy + th * 0.5), c.igGetColorU32_Vec4(pal.toolbar_line), th, 0);
    c.ImDrawList_AddRectFilled(dl, cimgui.vec2(tx0, cy - th * 0.5), cimgui.vec2(kx, cy + th * 0.5), theme.u32c(pal.accent_hex, 0xFF), th, 0);
    const kr = @round(h * 0.38);
    const knob: u32 = if (pal.dark) 0xFFD8D8D8 else 0xFFFFFFFF;
    c.ImDrawList_AddCircleFilled(dl, cimgui.vec2(kx, cy), kr, knob, 0);
    c.ImDrawList_AddCircle(dl, cimgui.vec2(kx, cy), kr, c.igGetColorU32_Vec4(theme.dim()), 0, 1);
}

// What the background worker's answers are about (core/bgio.zig).
const bg_favourites: u32 = 1;
const bg_folder_views: u32 = 2;
const bg_edit: u32 = 3;
const bg_add_favourites: u32 = 4;
const bg_point: u32 = 5;

/// folderViewsMtime is the folders file's modification time (0 when it isn't there).
fn folderViewsMtime(io: std.Io, path: []const u8) i96 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return st.mtime.nanoseconds;
}

/// SideIcon is the glyph before a sidebar entry.
const SideIcon = enum { recent, home, desktop, document, download, folder, trash, computer, drive, usb, network, cloud, plus, search };

/// sideItem is one sidebar row: an icon, the label, a rounded highlight when `here`
/// (the place on screen), dimmed when not available yet. Returns whether clicked.
/// setField copies `s` into a NUL-terminated text field buffer (cut to fit).
fn setField(buf: []u8, s: []const u8) void {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
}

/// wrapDim is dimText wrapped at the window's edge.
fn wrapDim(s: []const u8) void {
    c.igPushTextWrapPos(0);
    Shell.dimText(s);
    c.igPopTextWrapPos();
}

/// side_net_page: the Network page is open while the sidebar is drawn; side_left: a
/// sidebar place other than Network was clicked this frame (the shell then closes
/// the page). The page stood in for the folder without changing it, so the folder's
/// own item stayed lit beside Network, and clicking it (going where you already
/// were) didn't close the page.
var side_net_page = false;
var side_left = false;

fn sideItem(label: [:0]const u8, here_in: bool, icon: SideIcon, dimmed: bool) bool {
    const is_network = std.mem.eql(u8, label, "Network");
    // While the Network page shows, it's the only place lit.
    const here = if (side_net_page) here_in and is_network else here_in;
    const fs = c.igGetFontSize();
    const pos = c.igGetCursorScreenPos();
    const row_h = sideRowH();
    const ind = fs * 1.9;
    c.igIndent(ind);
    if (dimmed) c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
    // The current place gets Finder's soft grey pill rather than the accent.
    if (here) c.igPushStyleColor_Vec4(c.ImGuiCol_Header, if (theme.p().dark) cimgui.vec4(1, 1, 1, 0.12) else cimgui.vec4(0, 0, 0, 0.08));
    c.igPushStyleVar_Vec2(c.ImGuiStyleVar_SelectableTextAlign, cimgui.vec2(0, 0.5));
    c.igPushStyleVar_Vec2(c.ImGuiStyleVar_ItemSpacing, cimgui.vec2(c.igGetStyle().*.ItemSpacing.x, 0));
    const clicked = c.igSelectable_Bool(label.ptr, here, 0, cimgui.vec2(0, row_h));
    if (clicked and !is_network) side_left = true;
    c.igPopStyleVar(2);
    if (here) c.igPopStyleColor(1);
    if (dimmed) c.igPopStyleColor(1);
    c.igUnindent(ind);
    const ih = @round(fs * 1.15);
    const col = if (dimmed) theme.dim() else theme.p().accent;
    drawSideIcon(c.igGetWindowDrawList(), icon, pos.x + fs * 0.3, pos.y + (row_h - ih) * 0.5, ih, c.igGetColorU32_Vec4(col));
    return clicked;
}

/// sideRowH is a sidebar row's height: Finder's are roomy.
fn sideRowH() f32 {
    return @round(c.igGetFontSize() * 1.85);
}

/// drawTagDot draws a tag's dot at `center`: filled with its colour, or a ring for a
/// tag without one.
fn drawTagDot(dl: *c.ImDrawList, center: c.ImVec2_c, r: f32, col: core.tags.Color) void {
    if (col == .none) {
        c.ImDrawList_AddCircle(dl, center, r * 0.85, theme.u32c(col.rgb(), 0xFF), 16, 1.6);
    } else c.ImDrawList_AddCircleFilled(dl, center, r, theme.u32c(col.rgb(), 0xFF), 16);
}

/// sideItemTag is a Tags row: a coloured dot, then the colour's name.
fn sideItemTag(label: [:0]const u8, on: bool, col: core.tags.Color) bool {
    const fs = c.igGetFontSize();
    const pos = c.igGetCursorScreenPos();
    const row_h = sideRowH();
    c.igIndent(fs * 1.9);
    c.igPushStyleVar_Vec2(c.ImGuiStyleVar_SelectableTextAlign, cimgui.vec2(0, 0.5));
    c.igPushStyleVar_Vec2(c.ImGuiStyleVar_ItemSpacing, cimgui.vec2(c.igGetStyle().*.ItemSpacing.x, 0));
    const clicked = c.igSelectable_Bool(label.ptr, on, 0, cimgui.vec2(0, row_h));
    c.igPopStyleVar(2);
    c.igUnindent(fs * 1.9);
    drawTagDot(c.igGetWindowDrawList(), cimgui.vec2(pos.x + fs * 0.3 + fs * 0.575, pos.y + row_h * 0.5), fs * 0.36, col);
    return clicked;
}

/// drawSideIcon draws a small line glyph (h×h at x,y) in `col`.
fn drawSideIcon(dl: *c.ImDrawList, icon: SideIcon, x: f32, y: f32, h: f32, col: u32) void {
    const t: f32 = @max(1.2, h / 11);
    const v = cimgui.vec2;
    const cx = x + h * 0.5;
    const cy = y + h * 0.5;
    switch (icon) {
        .recent => {
            c.ImDrawList_AddCircle(dl, v(cx, cy), h * 0.42, col, 20, t);
            c.ImDrawList_AddLine(dl, v(cx, cy), v(cx, cy - h * 0.25), col, t);
            c.ImDrawList_AddLine(dl, v(cx, cy), v(cx + h * 0.2, cy + h * 0.08), col, t);
        },
        .home => {
            c.ImDrawList_AddLine(dl, v(x + h * 0.08, cy), v(cx, y + h * 0.1), col, t);
            c.ImDrawList_AddLine(dl, v(cx, y + h * 0.1), v(x + h * 0.92, cy), col, t);
            c.ImDrawList_AddRect(dl, v(x + h * 0.22, cy - h * 0.05), v(x + h * 0.78, y + h * 0.9), col, 1, t, 0);
        },
        .desktop => {
            c.ImDrawList_AddRect(dl, v(x + h * 0.06, y + h * 0.14), v(x + h * 0.94, y + h * 0.7), col, 2, t, 0);
            c.ImDrawList_AddLine(dl, v(cx, y + h * 0.7), v(cx, y + h * 0.86), col, t);
            c.ImDrawList_AddLine(dl, v(x + h * 0.3, y + h * 0.88), v(x + h * 0.7, y + h * 0.88), col, t);
        },
        .document => {
            c.ImDrawList_AddRect(dl, v(x + h * 0.2, y + h * 0.08), v(x + h * 0.8, y + h * 0.92), col, 2, t, 0);
            for ([_]f32{ 0.35, 0.52, 0.69 }) |ly| c.ImDrawList_AddLine(dl, v(x + h * 0.32, y + h * ly), v(x + h * 0.68, y + h * ly), col, t * 0.8);
        },
        .download => {
            c.ImDrawList_AddCircle(dl, v(cx, cy), h * 0.42, col, 20, t);
            c.ImDrawList_AddLine(dl, v(cx, y + h * 0.25), v(cx, y + h * 0.7), col, t);
            c.ImDrawList_AddLine(dl, v(x + h * 0.32, y + h * 0.52), v(cx, y + h * 0.72), col, t);
            c.ImDrawList_AddLine(dl, v(x + h * 0.68, y + h * 0.52), v(cx, y + h * 0.72), col, t);
        },
        .folder => {
            c.ImDrawList_AddRect(dl, v(x + h * 0.06, y + h * 0.28), v(x + h * 0.94, y + h * 0.86), col, 2, t, 0);
            c.ImDrawList_AddLine(dl, v(x + h * 0.06, y + h * 0.28), v(x + h * 0.12, y + h * 0.16), col, t);
            c.ImDrawList_AddLine(dl, v(x + h * 0.12, y + h * 0.16), v(x + h * 0.42, y + h * 0.16), col, t);
            c.ImDrawList_AddLine(dl, v(x + h * 0.42, y + h * 0.16), v(x + h * 0.5, y + h * 0.28), col, t);
        },
        .trash => {
            c.ImDrawList_AddLine(dl, v(x + h * 0.14, y + h * 0.24), v(x + h * 0.86, y + h * 0.24), col, t);
            c.ImDrawList_AddLine(dl, v(x + h * 0.38, y + h * 0.12), v(x + h * 0.62, y + h * 0.12), col, t);
            c.ImDrawList_AddRect(dl, v(x + h * 0.24, y + h * 0.24), v(x + h * 0.76, y + h * 0.9), col, 2, t, 0);
        },
        .computer, .drive => {
            c.ImDrawList_AddRect(dl, v(x + h * 0.06, y + h * 0.3), v(x + h * 0.94, y + h * 0.74), col, 2, t, 0);
            c.ImDrawList_AddCircleFilled(dl, v(x + h * 0.78, y + h * 0.52), h * 0.06, col, 8);
        },
        .usb => {
            c.ImDrawList_AddRect(dl, v(x + h * 0.3, y + h * 0.3), v(x + h * 0.7, y + h * 0.92), col, 2, t, 0);
            c.ImDrawList_AddRect(dl, v(x + h * 0.38, y + h * 0.08), v(x + h * 0.62, y + h * 0.3), col, 0, t, 0);
        },
        .network => {
            c.ImDrawList_AddCircle(dl, v(cx, cy), h * 0.42, col, 20, t);
            c.ImDrawList_AddLine(dl, v(x + h * 0.08, cy), v(x + h * 0.92, cy), col, t * 0.8);
            c.ImDrawList_AddLine(dl, v(cx, y + h * 0.08), v(cx, y + h * 0.92), col, t * 0.8);
            c.ImDrawList_AddCircle(dl, v(cx, cy), h * 0.2, col, 16, t * 0.8);
        },
        .cloud => {
            // Three bumps over a flat base, drawn as one outline.
            const pi = std.math.pi;
            c.ImDrawList_PathLineTo(dl, v(x + h * 0.78, y + h * 0.76));
            c.ImDrawList_PathLineTo(dl, v(x + h * 0.24, y + h * 0.76));
            c.ImDrawList_PathArcTo(dl, v(x + h * 0.24, y + h * 0.6), h * 0.16, pi * 0.5, pi * 1.5, 8);
            c.ImDrawList_PathArcTo(dl, v(x + h * 0.46, y + h * 0.46), h * 0.21, pi * 1.08, pi * 1.9, 10);
            c.ImDrawList_PathArcTo(dl, v(x + h * 0.7, y + h * 0.61), h * 0.15, pi * 1.4, pi * 2.5, 8);
            c.ImDrawList_PathStroke(dl, col, t, c.ImDrawFlags_Closed); // thickness, flags
        },
        .plus => {
            c.ImDrawList_AddLine(dl, v(cx, y + h * 0.2), v(cx, y + h * 0.8), col, t);
            c.ImDrawList_AddLine(dl, v(x + h * 0.2, cy), v(x + h * 0.8, cy), col, t);
        },
        .search => {
            // A magnifier: a lens and its handle.
            c.ImDrawList_AddCircle(dl, v(x + h * 0.42, y + h * 0.42), h * 0.26, col, 16, t);
            c.ImDrawList_AddLine(dl, v(x + h * 0.61, y + h * 0.61), v(x + h * 0.85, y + h * 0.85), col, t * 1.3);
        },
    }
}

/// joinSub is `base`/`sub` (just `base` when sub is empty), in buf.
fn joinSub(buf: []u8, base: []const u8, sub: []const u8) []const u8 {
    if (sub.len == 0) return base;
    return std.mem.print(buf, "{s}/{s}", .{ base, sub }) catch base;
}

/// drawReadOnly is Finder's quiet read-only mark at the start of the status bar: a
/// small lock and the word, with the reason on hover (inside an archive, changes aren't
/// saved back into it).
fn drawReadOnly(b: *Browser) void {
    const o = b.insideArchive() orelse return;
    const pos = c.igGetCursorScreenPos();
    const h = c.igGetTextLineHeight();
    const col = c.igGetColorU32_Vec4(theme.dim());
    const dl = c.igGetWindowDrawList();
    const w = h * 0.55;
    const x = pos.x + 1;
    const y = pos.y + h * 0.42;
    c.ImDrawList_AddRect(dl, cimgui.vec2(x + w * 0.2, y - h * 0.3), cimgui.vec2(x + w * 0.8, y + 1), col, w * 0.3, 1.4, 0); // the shackle
    c.ImDrawList_AddRectFilled(dl, cimgui.vec2(x, y), cimgui.vec2(x + w, y + h * 0.45), col, 1.5, 0);
    c.igDummy(cimgui.vec2(w + 4, h));
    c.igSameLine(0, 0);
    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
    cimgui.textUnformatted("Read-only");
    c.igPopStyleColor(1);
    if (c.igIsItemHovered(0) or c.igIsMouseHoveringRect(pos, cimgui.vec2(pos.x + w + 4, pos.y + h), true)) {
        var buf: [600]u8 = undefined;
        const tip = std.mem.printSentinel(&buf, "Inside {s}, read in place: copy items out to change them.", .{std.fs.path.basename(o.src)}, 0) catch "Inside an archive";
        c.igSetTooltip("%s", tip.ptr);
    }
    c.igSameLine(0, 0);
    cimgui.textUnformatted("  \u{00B7}  ");
    c.igSameLine(0, 0);
}





/// enterFromPreview goes into the folder a preview was clicked in, picking the item
/// that was clicked (if one was).
fn enterFromPreview(b: *Browser, enter: quicklook.View.Enter) void {
    var nb: [256]u8 = undefined;
    const sel = if (enter.select) |n| (std.mem.print(&nb, "{s}", .{n}) catch null) else null;
    b.navigate(enter.path) catch return;
    if (sel) |n| b.setPendingSelect(n);
}

/// cursorPath is the absolute path of the item under `b`'s cursor (into `buf`), or
/// null when there's none.
/// cursorPath is the cursor item's path. While the next folder loads, that's still an
/// item of the folder on screen (so the preview keeps showing it, not a blank).
fn cursorPath(b: *Browser, buf: []u8) ?[]const u8 {
    if (b.count() == 0 or b.sel.cursor >= b.count()) return null;
    const dir = b.shownDir();
    return std.mem.print(buf, "{s}/{s}", .{ if (std.mem.eql(u8, dir, "/")) "" else dir, b.at(b.sel.cursor).name }) catch null;
}

/// sortTrash orders the Trash window's items by column (0 name, 1 where it was,
/// 2 when it was trashed), descending if asked, ties by name.
fn sortTrash(items: []core.trash.Item, column: u32, descending: bool) void {
    const Ctx = struct {
        col: u32,
        desc: bool,
        fn less(cx: @This(), a: core.trash.Item, b: core.trash.Item) bool {
            const ord: std.math.Order = switch (cx.col) {
                1 => std.mem.order(u8, a.orig_path, b.orig_path),
                2 => std.math.order(a.deleted, b.deleted),
                else => .eq,
            };
            const o = if (ord != .eq) ord else std.ascii.orderIgnoreCase(a.name, b.name);
            return if (cx.desc) o == .gt else o == .lt;
        }
    };
    std.mem.sort(core.trash.Item, items, Ctx{ .col = column, .desc = descending }, Ctx.less);
}

/// infoRow is a Finder "Information" line: the label dim on the left, the value
/// right-aligned.
fn infoRow(label: []const u8, value: []const u8) void {
    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
    cimgui.textUnformatted(label);
    c.igPopStyleColor(1);
    const vw = c.igCalcTextSize(value.ptr, value.ptr + value.len, false, -1).x;
    const lw = c.igGetItemRectSize().x;
    const room = c.igGetContentRegionAvail().x;
    if (vw <= room - lw - c.igGetStyle().*.ItemSpacing.x * 2) {
        // Beside its label, at the right edge.
        c.igSameLine(@max(room + c.igGetCursorPosX() - vw, 0), -1);
        cimgui.textUnformatted(value);
    } else {
        // Too long for that: under it, wrapped at the edge (not running off it).
        c.igPushTextWrapPos(0);
        cimgui.textUnformatted(value);
        c.igPopTextWrapPos();
    }
}

/// formLabel starts a form row: `label` right-aligned in a `w`-wide column, then the
/// cursor at the field's column.
fn formLabel(label: []const u8, w: f32) void {
    const tw = c.igCalcTextSize(label.ptr, label.ptr + label.len, false, -1).x;
    c.igAlignTextToFramePadding();
    c.igSetCursorPosX(c.igGetCursorPosX() + @max(w - tw - 8, 0));
    cimgui.textUnformatted(label);
    c.igSameLine(0, 0);
    c.igSetCursorPosX(c.igGetStyle().*.WindowPadding.x + w);
}

/// formHint is a small note to the right of the field just drawn, wrapped to a
/// `w`-wide column at `x` so a long hint grows the row downwards, not the window
/// sideways.
fn formHint(x: f32, text: []const u8, w: f32, col: c.ImVec4_c) void {
    c.igSameLine(x, -1);
    c.igAlignTextToFramePadding();
    c.igPushTextWrapPos(c.igGetCursorPosX() + w);
    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, col);
    cimgui.textUnformatted(text);
    c.igPopStyleColor(1);
    c.igPopTextWrapPos();
}

/// ToolIcon is a toolbar button's glyph.
const ToolIcon = enum { back, forward, view_list, view_grid, view_columns, view_gallery, more, sort, share, tag, search, new_folder, trash, info, eye, terminal, preview_pane, rotate_left, rotate_right };

/// ToolItem is one of the toolbar's right-hand items (View > Customize Toolbar).
pub const ToolItem = enum {
    view,
    sort,
    share,
    tags,
    actions,
    search,
    new_folder,
    trash,
    get_info,
    quicklook,
    preview,
    terminal,

    pub fn label(it: ToolItem) [:0]const u8 {
        return switch (it) {
            .view => "View (List, Icons, Columns, Gallery)",
            .sort => "Sort By",
            .share => "Share",
            .tags => "Tags",
            .actions => "Action (\u{2026})",
            .search => "Search",
            .new_folder => "New Folder",
            .trash => "Move to Trash",
            .get_info => "Get Info",
            .quicklook => "Quick Look",
            .preview => "Show Preview",
            .terminal => "Open Terminal Here",
        };
    }

    /// single: one button, sitting side by side with the singles next to it.
    fn single(it: ToolItem) bool {
        return it != .view and it != .sort and it != .search;
    }
};

const default_toolbar = [_]ToolItem{ .view, .sort, .share, .tags, .actions, .search };

/// groupLen is how many items at the start of `items` share a pill: a run of single
/// buttons, or one item that's a group of its own.
fn groupLen(items: []const ToolItem) usize {
    if (!items[0].single()) return 1;
    var n: usize = 1;
    while (n < items.len and items[n].single()) n += 1;
    return n;
}

fn groupWidth(grp: []const ToolItem, bw: f32, sw: f32, gpad: f32) f32 {
    return switch (grp[0]) {
        .view => bw * 4 + gpad * 2,
        .sort => @round(bw * 1.4) + gpad * 2,
        .search => sw,
        else => bw * @as(f32, @floatFromInt(grp.len)) + gpad * 2,
    };
}

/// toolButton is a borderless toolbar button showing a drawn glyph: a soft pill on
/// hover, and the pressed look while `on` (the active view). Returns whether clicked.
fn toolButton(id: [:0]const u8, icon: ToolIcon, enabled: bool, on: bool, tip: [:0]const u8) bool {
    return toolButtonW(id, icon, @round(toolbarH() * 1.2), enabled, on, tip);
}



/// toolButtonW is toolButton at width `w` (the sort menu's is wider, for its arrow).
fn toolButtonW(id: [:0]const u8, icon: ToolIcon, w: f32, enabled: bool, on: bool, tip: [:0]const u8) bool {
    const h = toolbarH();
    const pos = c.igGetCursorScreenPos();
    c.igBeginDisabled(!enabled);
    const clicked = c.igInvisibleButton(id.ptr, cimgui.vec2(w, h), 0);
    const hovered = c.igIsItemHovered(0);
    c.igEndDisabled();
    const dl = c.igGetWindowDrawList();
    const pal = theme.p();
    // The pill fades between rest, hover (0.5) and on (1).
    const level = anim.value(c.igGetItemID(), if (on) 1 else if (hovered and enabled) 0.5 else 0, anim.quick, .out_cubic);
    if (level > 0.01) {
        const a = level * (if (pal.dark) @as(f32, 0.16) else 0.1);
        const bg = if (pal.dark) cimgui.vec4(1, 1, 1, a) else cimgui.vec4(0, 0, 0, a);
        c.ImDrawList_AddRectFilled(dl, pos, cimgui.vec2(pos.x + w, pos.y + h), c.igGetColorU32_Vec4(bg), 6, 0);
    }
    const col = c.igGetColorU32_Vec4(if (enabled) pal.text else pal.dim);
    const g = @round(h * 0.46); // glyph box
    const x = pos.x + (w - g) * 0.5;
    const y = pos.y + (h - g) * 0.5;
    const t: f32 = @max(1.3, h / 18);
    const v = cimgui.vec2;
    switch (icon) {
        .back => {
            c.ImDrawList_AddLine(dl, v(x + g * 0.65, y), v(x + g * 0.25, y + g * 0.5), col, t * 1.2);
            c.ImDrawList_AddLine(dl, v(x + g * 0.25, y + g * 0.5), v(x + g * 0.65, y + g), col, t * 1.2);
        },
        .forward => {
            c.ImDrawList_AddLine(dl, v(x + g * 0.35, y), v(x + g * 0.75, y + g * 0.5), col, t * 1.2);
            c.ImDrawList_AddLine(dl, v(x + g * 0.75, y + g * 0.5), v(x + g * 0.35, y + g), col, t * 1.2);
        },
        .view_list => for ([_]f32{ 0.15, 0.5, 0.85 }) |ly| {
            c.ImDrawList_AddCircleFilled(dl, v(x + g * 0.08, y + g * ly), t * 0.9, col, 8);
            c.ImDrawList_AddLine(dl, v(x + g * 0.28, y + g * ly), v(x + g, y + g * ly), col, t);
        },
        .view_grid => for ([_]f32{ 0, 0.56 }) |gy| for ([_]f32{ 0, 0.56 }) |gx| {
            c.ImDrawList_AddRect(dl, v(x + g * gx, y + g * gy), v(x + g * (gx + 0.44), y + g * (gy + 0.44)), col, 2, t, 0);
        },
        .view_columns => {
            c.ImDrawList_AddRect(dl, v(x, y + g * 0.08), v(x + g, y + g * 0.92), col, 2, t, 0);
            c.ImDrawList_AddLine(dl, v(x + g * 0.36, y + g * 0.08), v(x + g * 0.36, y + g * 0.92), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.68, y + g * 0.08), v(x + g * 0.68, y + g * 0.92), col, t);
        },
        .view_gallery => {
            // A big picture over a row of small ones.
            c.ImDrawList_AddRect(dl, v(x, y), v(x + g, y + g * 0.62), col, 2, t, 0);
            for ([_]f32{ 0, 0.37, 0.74 }) |gx| c.ImDrawList_AddRectFilled(dl, v(x + g * gx, y + g * 0.78), v(x + g * (gx + 0.26), y + g), col, 1, 0);
        },
        .more => for ([_]f32{ 0.15, 0.5, 0.85 }) |lx| c.ImDrawList_AddCircleFilled(dl, v(x + g * lx, y + g * 0.5), t * 1.3, col, 10),
        .sort => {
            // Three shrinking lines, then a small down arrow: a menu.
            const sx = pos.x + (w - g * 1.5) * 0.5;
            for ([_][2]f32{ .{ 0.15, 1.0 }, .{ 0.5, 0.72 }, .{ 0.85, 0.44 } }) |r|
                c.ImDrawList_AddLine(dl, v(sx, y + g * r[0]), v(sx + g * r[1], y + g * r[0]), col, t);
            const ax = sx + g * 1.2;
            c.ImDrawList_AddLine(dl, v(ax - g * 0.18, y + g * 0.42), v(ax, y + g * 0.6), col, t);
            c.ImDrawList_AddLine(dl, v(ax, y + g * 0.6), v(ax + g * 0.18, y + g * 0.42), col, t);
        },
        .share => {
            // A tray open at the top with an arrow rising out of it.
            c.ImDrawList_AddLine(dl, v(x + g * 0.3, y + g * 0.38), v(x + g * 0.1, y + g * 0.38), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.1, y + g * 0.38), v(x + g * 0.1, y + g * 1.05), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.1, y + g * 1.05), v(x + g * 0.9, y + g * 1.05), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.9, y + g * 1.05), v(x + g * 0.9, y + g * 0.38), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.9, y + g * 0.38), v(x + g * 0.7, y + g * 0.38), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.5, y - g * 0.1), v(x + g * 0.5, y + g * 0.7), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.28, y + g * 0.12), v(x + g * 0.5, y - g * 0.1), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.5, y - g * 0.1), v(x + g * 0.72, y + g * 0.12), col, t);
        },
        .search => drawMagnifier(dl, x, y, g, col),
        .new_folder => {
            // A folder with a plus.
            const pts = [_]c.ImVec2_c{ v(x, y + g * 0.15), v(x + g * 0.38, y + g * 0.15), v(x + g * 0.5, y + g * 0.3), v(x + g, y + g * 0.3), v(x + g, y + g * 0.9), v(x, y + g * 0.9) };
            c.ImDrawList_AddPolyline(dl, &pts, pts.len, col, t, c.ImDrawFlags_Closed);
            c.ImDrawList_AddLine(dl, v(x + g * 0.5, y + g * 0.45), v(x + g * 0.5, y + g * 0.78), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.33, y + g * 0.61), v(x + g * 0.67, y + g * 0.61), col, t);
        },
        .trash => {
            // A bin: lid, handle, body with ribs.
            c.ImDrawList_AddLine(dl, v(x, y + g * 0.18), v(x + g, y + g * 0.18), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.38, y + g * 0.18), v(x + g * 0.38, y + g * 0.02), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.38, y + g * 0.02), v(x + g * 0.62, y + g * 0.02), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.62, y + g * 0.02), v(x + g * 0.62, y + g * 0.18), col, t);
            const body = [_]c.ImVec2_c{ v(x + g * 0.12, y + g * 0.18), v(x + g * 0.2, y + g), v(x + g * 0.8, y + g), v(x + g * 0.88, y + g * 0.18) };
            c.ImDrawList_AddPolyline(dl, &body, body.len, col, t, 0);
            for ([_]f32{ 0.38, 0.62 }) |rx| c.ImDrawList_AddLine(dl, v(x + g * rx, y + g * 0.35), v(x + g * rx, y + g * 0.85), col, t * 0.8);
        },
        .info => {
            c.ImDrawList_AddCircle(dl, v(x + g * 0.5, y + g * 0.5), g * 0.5, col, 20, t);
            c.ImDrawList_AddCircleFilled(dl, v(x + g * 0.5, y + g * 0.28), t * 0.9, col, 8);
            c.ImDrawList_AddLine(dl, v(x + g * 0.5, y + g * 0.44), v(x + g * 0.5, y + g * 0.76), col, t * 1.1);
        },
        .eye => {
            // An eye: two arcs and a pupil.
            c.ImDrawList_PathArcTo(dl, v(x + g * 0.5, y + g * 1.05), g * 0.68, std.math.pi * 1.2, std.math.pi * 1.8, 12);
            c.ImDrawList_PathStroke(dl, col, t, 0); // thickness, flags
            c.ImDrawList_PathArcTo(dl, v(x + g * 0.5, y - g * 0.05), g * 0.68, std.math.pi * 0.2, std.math.pi * 0.8, 12);
            c.ImDrawList_PathStroke(dl, col, t, 0);
            c.ImDrawList_AddCircleFilled(dl, v(x + g * 0.5, y + g * 0.5), g * 0.16, col, 12);
        },
        .terminal => {
            c.ImDrawList_AddRect(dl, v(x, y + g * 0.08), v(x + g, y + g * 0.92), col, 2, t, 0);
            c.ImDrawList_AddLine(dl, v(x + g * 0.2, y + g * 0.32), v(x + g * 0.4, y + g * 0.5), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.4, y + g * 0.5), v(x + g * 0.2, y + g * 0.68), col, t);
            c.ImDrawList_AddLine(dl, v(x + g * 0.5, y + g * 0.7), v(x + g * 0.78, y + g * 0.7), col, t);
        },
        .rotate_left, .rotate_right => {
            // A circular arrow, three quarters round, its head at the end it turns to.
            const cw = icon == .rotate_right;
            const cx = x + g * 0.5;
            const cy = y + g * 0.55;
            const r = g * 0.36;
            const pi = std.math.pi;
            // Screen angles turn clockwise. Right: from the left, over the top, round
            // to below the right; left: the mirror image.
            const a0: f32 = if (cw) pi else 0;
            const a1: f32 = if (cw) pi * 2.3 else -pi * 1.3;
            c.ImDrawList_PathArcTo(dl, v(cx, cy), r, a0, a1, 20);
            c.ImDrawList_PathStroke(dl, col, t, 0); // thickness, flags
            // The head: a filled wedge along the arc's direction at its end.
            const ex = cx + r * @cos(a1);
            const ey = cy + r * @sin(a1);
            const dir: f32 = if (cw) 1 else -1; // which way round it goes
            const tx = -@sin(a1) * dir; // tangent, in the direction of travel
            const ty = @cos(a1) * dir;
            const hs = g * 0.36;
            const head = v(ex + tx * hs * 0.9, ey + ty * hs * 0.9);
            const b1 = v(ex - ty * hs * 0.55, ey + tx * hs * 0.55);
            const b2 = v(ex + ty * hs * 0.55, ey - tx * hs * 0.55);
            c.ImDrawList_AddTriangleFilled(dl, head, b1, b2, col);
        },
        .preview_pane => {
            // A window with its right-hand pane.
            c.ImDrawList_AddRect(dl, v(x, y + g * 0.08), v(x + g, y + g * 0.92), col, 2, t, 0);
            c.ImDrawList_AddRectFilled(dl, v(x + g * 0.62, y + g * 0.08), v(x + g, y + g * 0.92), col, 2, c.ImDrawFlags_RoundCornersRight);
        },
        .tag => {
            // A luggage tag: pointed on the left, with its hole.
            const pts = [_]c.ImVec2_c{ v(x, y + g * 0.5), v(x + g * 0.35, y + g * 0.12), v(x + g, y + g * 0.12), v(x + g, y + g * 0.88), v(x + g * 0.35, y + g * 0.88) };
            c.ImDrawList_AddPolyline(dl, &pts, pts.len, col, t, c.ImDrawFlags_Closed);
            c.ImDrawList_AddCircle(dl, v(x + g * 0.38, y + g * 0.5), g * 0.1, col, 8, t);
        },
    }
    if (hovered and tip.len > 0) c.igSetTooltip("%s", tip.ptr);
    return clicked and enabled;
}

/// drawMagnifier draws the search glyph in the g-sized box at x, y.
fn drawMagnifier(dl: *c.ImDrawList, x: f32, y: f32, g: f32, col: u32) void {
    const t: f32 = @max(1.3, g / 7);
    const r = g * 0.34;
    const cx = x + r + t * 0.5;
    const cy = y + r + t * 0.5;
    c.ImDrawList_AddCircle(dl, cimgui.vec2(cx, cy), r, col, 20, t);
    const d = r * 0.7071;
    c.ImDrawList_AddLine(dl, cimgui.vec2(cx + d, cy + d), cimgui.vec2(x + g, y + g), col, t * 1.2);
}

/// settingsPageButton is one of the Settings window's page buttons: a drawn icon over
/// its label, on a soft pill when it's the current page. Returns whether clicked.
fn settingsPageButton(label: [:0]const u8, page: Shell.SettingsPage, on: bool, w: f32, h: f32) bool {
    const pos = c.igGetCursorScreenPos();
    c.igPushID_Str(label.ptr);
    defer c.igPopID();
    const clicked = c.igInvisibleButton("##page", cimgui.vec2(w, h), 0);
    const hovered = c.igIsItemHovered(0);
    const dl = c.igGetWindowDrawList();
    const pal = theme.p();
    if (on or hovered) {
        const bg = if (on) (if (pal.dark) cimgui.vec4(1, 1, 1, 0.12) else cimgui.vec4(0, 0, 0, 0.08)) else (if (pal.dark) cimgui.vec4(1, 1, 1, 0.06) else cimgui.vec4(0, 0, 0, 0.04));
        c.ImDrawList_AddRectFilled(dl, pos, cimgui.vec2(pos.x + w, pos.y + h), c.igGetColorU32_Vec4(bg), 8, 0);
    }
    const fs = c.igGetFontSize();
    const col = c.igGetColorU32_Vec4(if (on) pal.accent else pal.text);
    const g = fs * 1.3; // icon box
    const x = pos.x + (w - g) * 0.5;
    const y = pos.y + fs * 0.35;
    const t: f32 = @max(1.3, fs / 11);
    const v = cimgui.vec2;
    switch (page) {
        .general => {
            // A switch: a rounded track with its knob.
            c.ImDrawList_AddRect(dl, v(x, y + g * 0.25), v(x + g, y + g * 0.75), col, g * 0.25, t, 0);
            c.ImDrawList_AddCircleFilled(dl, v(x + g * 0.72, y + g * 0.5), g * 0.17, col, 12);
        },
        .tags => {
            const pts = [_]c.ImVec2_c{ v(x, y + g * 0.5), v(x + g * 0.35, y + g * 0.15), v(x + g, y + g * 0.15), v(x + g, y + g * 0.85), v(x + g * 0.35, y + g * 0.85) };
            c.ImDrawList_AddPolyline(dl, &pts, pts.len, col, t, c.ImDrawFlags_Closed);
            c.ImDrawList_AddCircle(dl, v(x + g * 0.38, y + g * 0.5), g * 0.09, col, 8, t);
        },
        .sidebar => {
            c.ImDrawList_AddRect(dl, v(x, y + g * 0.1), v(x + g, y + g * 0.9), col, 3, t, 0);
            c.ImDrawList_AddRectFilled(dl, v(x, y + g * 0.1), v(x + g * 0.35, y + g * 0.9), col, 3, c.ImDrawFlags_RoundCornersLeft);
        },
        .appearance => {
            // A circle half filled: light and dark.
            c.ImDrawList_AddCircle(dl, v(x + g * 0.5, y + g * 0.5), g * 0.42, col, 24, t);
            c.ImDrawList_PathArcTo(dl, v(x + g * 0.5, y + g * 0.5), g * 0.42, std.math.pi * 0.5, std.math.pi * 1.5, 16);
            c.ImDrawList_PathFillConvex(dl, col);
        },
        .advanced => {
            // Two sliders.
            for ([_][2]f32{ .{ 0.3, 0.3 }, .{ 0.7, 0.68 } }) |r| {
                c.ImDrawList_AddLine(dl, v(x, y + g * r[0]), v(x + g, y + g * r[0]), col, t);
                c.ImDrawList_AddCircleFilled(dl, v(x + g * r[1], y + g * r[0]), g * 0.13, col, 12);
            }
        },
    }
    const ts = c.igCalcTextSize(label.ptr, null, false, -1);
    c.ImDrawList_AddText_Vec2(dl, v(pos.x + (w - ts.x) * 0.5, y + g + fs * 0.3), col, label.ptr, null);
    return clicked;
}

/// toolGroup draws the soft rounded backing of a toolbar group `w` wide at the cursor
/// (Finder's grouped controls) and steps in by `pad` for the first button.
fn toolGroup(w: f32, pad: f32) void {
    const pos = c.igGetCursorScreenPos();
    const h = toolbarH();
    const bg = if (theme.p().dark) cimgui.vec4(1, 1, 1, 0.06) else cimgui.vec4(0, 0, 0, 0.045);
    c.ImDrawList_AddRectFilled(c.igGetWindowDrawList(), cimgui.vec2(pos.x, pos.y - pad), cimgui.vec2(pos.x + w, pos.y + h + pad), c.igGetColorU32_Vec4(bg), 8, 0);
    c.igSetCursorScreenPos(cimgui.vec2(pos.x + pad, pos.y));
}

/// drawSortMenu is the toolbar's sort menu: the column to sort by (checked) and the
/// direction, remembered per folder like a click on a column header.
fn drawSortMenu(b: *Browser) void {
    Shell.dimText("Sort By");
    const cols = [_]struct { core.scan.SortColumn, [:0]const u8 }{
        .{ .name, "Name" }, .{ .type, "Kind" }, .{ .date, "Date Modified" }, .{ .created, "Date Created" }, .{ .size, "Size" },
    };
    const cur = b.sort_order;
    for (cols) |it| {
        if (c.igMenuItem_Bool(it[1].ptr, null, cur.column == it[0], true)) b.setSort(it[0], if (cur.column == it[0]) cur.ascending else it[0] == .name or it[0] == .type);
    }
    c.igSeparator();
    if (c.igMenuItem_Bool("Ascending", null, cur.ascending, true)) b.setSort(cur.column, true);
    if (c.igMenuItem_Bool("Descending", null, !cur.ascending, true)) b.setSort(cur.column, false);
    c.igSeparator();
    var df = cur.dirs_first;
    if (c.igMenuItem_BoolPtr("Folders First", null, &df, true)) b.toggleDirsFirst();
    c.igSeparator();
    Shell.dimText("Group By");
    c.igPushID_Str("group"); // "Kind" and "Date Modified" appear in both sections
    groupItems(b);
    c.igPopID();
}

/// selectedIndex is the item an action on "the selection" names: the cursor when it's
/// selected, else the first selected item; null with nothing selected.
fn selectedIndex(b: *Browser) ?usize {
    if (b.loading or b.sel.count() == 0) return null;
    if (b.sel.cursor < b.count() and b.sel.isSelected(b.sel.cursor)) return b.sel.cursor;
    for (0..b.count()) |i| if (b.sel.isSelected(i)) return i;
    return null;
}

/// groupItems lists the Use Groups choices (checked = the folder's), for the toolbar's
/// sort menu and View > Group By.
fn groupItems(b: *Browser) void {
    const groups = [_]struct { core.scan.GroupBy, [:0]const u8 }{
        .{ .none, "None" }, .{ .kind, "Kind" }, .{ .date, "Date Modified" }, .{ .size, "Size" }, .{ .tags, "Tags" },
    };
    for (groups) |g| if (c.igMenuItem_Bool(g[1].ptr, null, b.group_by == g[0], true)) b.setGroupBy(g[0]);
}

/// drawTagMenu is the toolbar's Tags menu: each colour with a dot, checked when every
/// selected item has it; picking one puts it on (or takes it off) the selection.
fn drawTagMenu(b: *Browser) void {
    const fs = c.igGetFontSize();
    for (core.tags.list()) |col| {
        const st = b.selectionTagged(col.bit());
        const pos = c.igGetCursorScreenPos();
        var lb: [48]u8 = undefined;
        const label = std.mem.printSentinel(&lb, "      {s}", .{col.name()}, 0) catch continue;
        if (c.igMenuItem_Bool(label.ptr, null, st.of > 0 and st.with == st.of, true)) b.toggleTag(col.bit());
        const h = c.igGetTextLineHeight();
        const center = cimgui.vec2(pos.x + fs * 0.6, pos.y + h * 0.5);
        if (st.with > 0 and st.with < st.of) {
            c.ImDrawList_AddCircle(c.igGetWindowDrawList(), center, h * 0.3, theme.u32c(col.rgb(), 0xFF), 16, 2);
        } else drawTagDot(c.igGetWindowDrawList(), center, h * 0.3, col.color());
    }
}

/// viewButton is one half of the List/Icons switch: highlighted when `on`.
fn viewButton(label: [:0]const u8, on: bool) bool {
    if (on) c.igPushStyleColor_Vec4(c.ImGuiCol_Button, c.igGetStyleColorVec4(c.ImGuiCol_ButtonActive).*);
    defer if (on) c.igPopStyleColor(1);
    return c.igButton(label.ptr, cimgui.vec2(0, 0));
}

/// wakeUi nudges an idle render loop (it may be blocked in glfwWaitEventsTimeout) so a
/// device change shows up now rather than at the next heartbeat. Thread-safe.
fn wakeUi() void {
    c.glfwPostEmptyEvent();
}

/// isUnder reports whether `path` is `dir` or inside it.
fn isUnder(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or path[dir.len] == '/';
}

/// pathSegments splits `dir` into breadcrumb segments: "/" then each component.
/// ends[k] is the byte index where segment k's path ends (the prefix is that
/// segment's folder). Returns the count.
fn pathSegments(dir: []const u8, ends: *[128]usize) usize {
    var n: usize = 0;
    ends[n] = 1; // root "/"
    n += 1;
    var i: usize = 1;
    while (i <= dir.len and n < ends.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            if (i > 1 and dir[i - 1] != '/') {
                ends[n] = i;
                n += 1;
            }
        }
    }
    return n;
}

/// segName is breadcrumb k's label: "/" for the root, else the path component that
/// ends at ends[k].
fn segName(dir: []const u8, ends: [128]usize, k: usize) []const u8 {
    if (k == 0) return "/";
    const e = ends[k];
    const start = (std.mem.lastIndexOfScalar(u8, dir[0..e], '/') orelse 0) + 1;
    return dir[start..e];
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// drawFilterCombo shows the chooser's file-type filter dropdown: "All files (*)"
/// plus each app-provided filter. Picking one re-filters the current tab's view.
fn drawFilterCombo(self: *Shell) void {
    if (self.dlg_filters.len == 0) return;
    var pbuf: [128]u8 = undefined;
    const preview: [:0]const u8 = if (self.dlg_filter_idx == 0)
        "All files (*)"
    else
        (std.mem.printSentinel(&pbuf, "{s}", .{self.dlg_filters[self.dlg_filter_idx - 1].name}, 0) catch "Filter");
    c.igSetNextItemWidth(-1);
    if (c.igBeginCombo("##filetype", preview.ptr, 0)) {
        if (c.igSelectable_Bool("All files (*)", self.dlg_filter_idx == 0, 0, cimgui.vec2(0, 0)))
            selectFilter(self, 0);
        for (self.dlg_filters, 0..) |f, i| {
            var lbuf: [160]u8 = undefined;
            const label = std.mem.printSentinel(&lbuf, "{s}##f{d}", .{ f.name, i }, 0) catch continue;
            if (c.igSelectable_Bool(label.ptr, self.dlg_filter_idx == i + 1, 0, cimgui.vec2(0, 0)))
                selectFilter(self, i + 1);
        }
        c.igEndCombo();
    }
}

fn selectFilter(self: *Shell, idx: usize) void {
    self.dlg_filter_idx = idx;
    const f: ?core.filter.FileFilter = if (idx == 0) null else self.dlg_filters[idx - 1];
    self.activeBrowser().setActiveFilter(f);
    // Save mode: retarget the filename's extension to the chosen filter's (like every
    // native save dialog: pick "PNG (*.png)" and "doc.txt" becomes "doc.png").
    if (self.dialog) |*d| {
        if (d.cfg.save) {
            if (f) |ff| if (ff.primaryExt()) |newext| retargetSaveExt(self, d, newext);
        }
    }
}

fn retargetSaveExt(self: *Shell, d: *Dialog, newext: []const u8) void {
    const name = std.mem.sliceTo(&d.name_buf, 0);
    if (name.len == 0) return;
    const updated = core.fsops.withExt(self.alloc, name, newext) catch return;
    defer self.alloc.free(updated);
    const n = @min(updated.len, d.name_buf.len - 1);
    @memcpy(d.name_buf[0..n], updated[0..n]);
    d.name_buf[n] = 0;
}

fn drawFooter(self: *Shell, d: *Dialog) void {
    c.igSeparator();
    drawFilterCombo(self);
    // The app's own word for it ("Add", "Upload"), else Open / Save.
    var ab: [64]u8 = undefined;
    const accept: [:0]const u8 = if (d.cfg.accept.len > 0)
        (std.mem.printSentinel(&ab, "{s}##accept", .{d.cfg.accept}, 0) catch "Open")
    else if (d.cfg.save) "Save" else "Open";

    // Size the two buttons exactly so they sit flush at the right edge: the Name input
    // stretches to meet them (save mode), and in Open mode the pair is right-aligned.
    // A fixed reserve left dead space to the right of the last button.
    const style = c.igGetStyle();
    const pad = style.*.FramePadding.x * 2;
    const sp = style.*.ItemSpacing.x;
    const tc = c.igCalcTextSize("Cancel", null, false, -1);
    const ta = c.igCalcTextSize(accept.ptr, null, true, -1); // (not its "##" id)
    const w_cancel = tc.x + pad;
    const w_accept = ta.x + pad;
    const btns_w = w_cancel + sp + w_accept;

    if (d.cfg.save) {
        cimgui.textUnformatted("Name:");
        c.igSameLine(0, -1);
        if (d.name_focus) {
            c.igSetKeyboardFocusHere(0);
            d.name_focus = false;
        }
        c.igSetNextItemWidth(-(btns_w + sp)); // fill up to the flush-right buttons
        // When we want the stem selected (initial focus, or after a click), pass its
        // length to the C callback via `stem`; the callback selects [0, stem) once.
        const name = std.mem.sliceTo(&d.name_buf, 0);
        var stem: c_int = if (d.name_select) @intCast(cimgui.stemLen(name)) else -1;
        const flags = c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_CallbackAlways;
        if (c.igInputText("##pickname", &d.name_buf, d.name_buf.len, flags, cimgui.selectStem, &stem) and d.name_reason == null)
            self.requestSave(d);
        d.name_select = false;
        if (c.igIsItemActivated()) d.name_select = true; // re-select the stem on next focus/click
        // Gate the file list's keyboard while the Name field is focused (read next frame
        // in draw(), since the footer draws after the list).
        d.name_active = c.igIsItemActive();
        drawNameContextMenu(d); // right-click Cut/Copy/Paste/Clear (InputText has none built in)
        c.igSameLine(0, -1);
    } else {
        // No input row → right-align the button pair to the content edge.
        const avail = c.igGetContentRegionAvail().x;
        if (avail > btns_w) c.igSetCursorPosX(c.igGetCursorPosX() + (avail - btns_w));
    }
    if (c.igButton("Cancel", cimgui.vec2(w_cancel, 0))) {
        d.cancelled = true;
        d.done = true;
    }
    c.igSameLine(0, -1);
    // In save mode, grey out Save while the name is invalid (empty or an illegal leaf)
    // so a bad path can never be handed back; the reason shows on its own row below.
    const block_accept = d.cfg.save and d.name_reason != null;
    if (block_accept) c.igBeginDisabled(true);
    if (c.igButton(accept.ptr, cimgui.vec2(w_accept, 0))) {
        // Open/Choose-folder returns `b.dir` (or the selection); block it too while the
        // folder failed to load, so we never hand back a path from an unread directory.
        if (!d.cfg.save) {
            if (self.activeBrowser().err_name == null) d.done = true;
        } else if (d.name_reason == null) self.requestSave(d);
    }
    if (block_accept) c.igEndDisabled();

    // Inline reason under the Name row for a non-empty but illegal name (e.g. a slash).
    // An empty name leaves Save greyed but shows nothing (no nagging on a blank open).
    // The extra row is reserved in draw() (name_hint) so this never clips the window.
    if (d.cfg.save and nameNonEmpty(d)) if (d.name_reason) |r| {
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.err());
        cimgui.textUnformatted(r);
        c.igPopStyleColor(1);
    };
}

fn nameNonEmpty(d: *Dialog) bool {
    return std.mem.trim(u8, std.mem.sliceTo(&d.name_buf, 0), " \t").len > 0;
}

/// drawNameContextMenu is the right-click menu for the Save dialog's Name field, as an
/// ImGui InputText has none built in. It works on the whole field (a filename is a short
/// single leaf). Cut/Paste/Clear then re-focus the field so ImGui reloads the edited
/// buffer (it caches the text of the *active* input, so an external edit only takes
/// effect on re-activation) and the user can keep typing. Ctrl+Z/C/V/X still work inline.
fn drawNameContextMenu(d: *Dialog) void {
    if (!c.igBeginPopupContextItem(null, c.ImGuiPopupFlags_MouseButtonRight)) return;
    defer c.igEndPopup();
    const name = std.mem.sliceTo(&d.name_buf, 0);
    const has = name.len > 0;
    if (c.igMenuItem_Bool("Cut", null, false, has)) {
        copyToClipboard(name);
        clearName(d);
    }
    if (c.igMenuItem_Bool("Copy", null, false, has)) copyToClipboard(name);
    if (c.igMenuItem_Bool("Paste", null, false, true)) {
        const clip = c.igGetClipboardText();
        if (clip != null) setNameSanitized(d, std.mem.sliceTo(clip, 0));
        refocusName(d);
    }
    if (c.igMenuItem_Bool("Clear", null, false, has)) clearName(d);
}

/// copyToClipboard puts `s` (a filename, so short) on the ImGui clipboard, NUL-terminated.
fn copyToClipboard(s: []const u8) void {
    var buf: [520]u8 = undefined;
    const z = std.mem.printSentinel(&buf, "{s}", .{s}, 0) catch return; // too long → skip
    c.igSetClipboardText(z.ptr);
}

/// refocusName re-focuses the Name input next frame (so ImGui reloads the buffer) without
/// re-selecting the stem; used after a context-menu edit.
fn refocusName(d: *Dialog) void {
    d.name_focus = true;
    d.name_select = false;
}

fn clearName(d: *Dialog) void {
    d.name_buf[0] = 0;
    refocusName(d);
}

/// setNameSanitized replaces the Name buffer with `src`, keeping just the first line and
/// dropping path separators and control characters: a save target is a single leaf name.
fn setNameSanitized(d: *Dialog, src: []const u8) void {
    var n: usize = 0;
    for (src) |ch| {
        if (ch == '\n' or ch == '\r') break; // first line only
        if (ch == '/' or ch < 0x20) continue; // no separators / control chars
        if (n >= d.name_buf.len - 1) break;
        d.name_buf[n] = ch;
        n += 1;
    }
    d.name_buf[n] = 0;
}

fn freeOwned(alloc: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| alloc.free(p);
    alloc.free(paths);
}

/// ruleValueOk reports whether a search rule's value reads for its op.
fn ruleValueOk(op: core.query.Rule.Op, v: []const u8) bool {
    return switch (op) {
        .within, .older => core.query.parseSpan(v) != null,
        .before, .after => core.query.parseDate(v) != null,
        .bigger, .smaller => core.query.parseSize(v) != null,
    };
}

/// todayDate is today as "2026-01-31" (UTC) in `buf`.
fn todayDate(buf: []u8) []const u8 {
    const days = @divFloor(core.query.nowSecs(), 86400);
    // Civil date from days (Howard Hinnant's algorithm).
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return std.mem.print(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(y)), @as(u64, @intCast(m)), @as(u64, @intCast(d)) }) catch "2026-01-01";
}
