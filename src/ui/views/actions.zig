//! ViewActions: the shared right-click menu and its modals (Properties, Open-with,
//! Delete-confirm) for the file views. The table, the treemap, and any future view
//! (icon grid) are all representations of one Browser, so they raise the SAME menu
//! through this component: the shell owns one ViewActions and hands it to every view.
//!
//! The modals open via pending flags and are drawn once at SHELL scope (drawModals),
//! so OpenPopup and BeginPopupModal share an ImGui ID scope regardless of which view's
//! nested context popup raised the menu (calling OpenPopup from inside the row popup
//! scoped it wrong; that's why Properties "did nothing" before this was centralized).
//! Rename routes through the model (b.requestRename); the table (always present) picks
//! it up and does the inline edit, so rename works from any view.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const c = cimgui.c;
const theme = @import("../theme.zig");
const core = @import("core");
const icons = @import("icons.zig");
const anim = @import("../anim.zig");
const table = @import("table.zig");
const scan = core.scan;
const archive = core.archive;

const Browser = core.browser.Browser;

/// ItemSize is a view's item size setting and how far it goes (1 = the default).
pub const ItemSize = struct { v: *f32, min: f32, max: f32 };

pub const ViewActions = struct {
    prop_buf: [1200]u8 = undefined, // formatted Properties text (snapshotted at open)
    prop_len: usize = 0,
    prop_path_buf: [4200]u8 = undefined, // the item the dialog is about (for chmod)
    prop_path_len: usize = 0,
    prop_mode: u32 = 0, // permission bits as loaded
    prop_edit: u32 = 0, // permission bits as edited in the grid
    prop_err: ?[]const u8 = null, // last chmod failure (@errorName)
    // Get Info's header and the editable parts (snapshotted at open).
    prop_name: [256]u8 = @splat(0), // Name & Extension, as edited
    prop_name_orig: [256]u8 = @splat(0),
    prop_kind: scan.Kind = .file,
    prop_head: [96]u8 = undefined, // "2.9 KB · Modified 2026-10-22 21:06"
    prop_head_len: usize = 0,
    prop_comment: [1024]u8 = @splat(0), // Comments, as edited
    prop_comment_saved: [1024]u8 = @splat(0), // ... as on the file
    prop_app: usize = std.math.maxInt(usize), // Open with: the app picked (index into appList)
    prop_buf_app: [256]u8 = undefined,
    prop_msg: ?[]const u8 = null, // last Get Info failure (comment, rename)
    probe: ?*core.sizeprobe.SizeProbe = null, // folder total, computed in the background
    // Batch rename (F2 with several items selected).
    br_pending: bool = false,
    br_mode: core.batchrename.Mode = .pattern,
    br_a: [256]u8 = @splat(0), // pattern, or "find"
    br_b: [256]u8 = @splat(0), // "replace with"
    br_olds: std.ArrayList([]u8) = .empty, // the selected names, in view order (owned)
    br_taken: std.StringHashMap(void) = undefined, // every name in the folder at open (keys owned by br_all)
    br_all: std.ArrayList([]u8) = .empty,
    br_taken_live: bool = false,
    del_count: usize = 0, // pending permanent-delete count
    openwith_search: [128]u8 = @splat(0),
    openwith_sel: usize = 0, // highlighted app in the Open-with dialog
    conflict_all: bool = true, // conflict dialog: one answer for every remaining clash
    thumbs: ?*@import("../thumbs.zig").Cache = null, // grid thumbnails (owned by the shell)
    dir_sizes: ?*@import("../dirsizes.zig").Cache = null, // folder sizes, when shown (owned by the shell)
    dirs: ?*@import("../dircache.zig").DirCache = null, // column view side listings (owned by the shell)
    gallery: ?*@import("../quicklook.zig").View = null, // gallery view's big preview (owned by the shell)
    procwatch: ?*core.procwatch.ProcWatch = null, // which partial downloads are still being written (owned by the shell)
    spring: Spring = .{}, // spring-loaded folders: the folder a drag is resting on
    pop: Pop = .{}, // a folder opening: its icon zooms out of its place and fades
    // Item sizes per view (1 = default): View Options, the status bar slider, Ctrl+scroll.
    icon_scale: f32 = 1.0, // icon view: the icons
    list_scale: f32 = 1.0, // list view: rows and their icons
    columns_scale: f32 = 1.0, // column view: rows and their icons
    gallery_scale: f32 = 1.0, // gallery view: the thumbnail strip
    grid_spacing: f32 = 1.0, // View Options: room between icons (1 = default)
    label_right: bool = false, // View Options: names beside the icons
    item_info: bool = false, // View Options: a line under each name (items, pixels, size)
    folder_sizes: bool = false, // list view: folders show the size of the files inside (dir_sizes)
    ffmpeg: ?[]const u8 = null, // for the pictures' Quick Actions (borrowed from the shell; null: not installed)
    icon_preview: bool = true, // View Options: thumbnails, not just type icons
    text_scale: f32 = 1.0, // View Options: the icon view's name size
    columns_on: [12]bool = .{ true, true, true, true, false, false, false, false, false, false, false, false }, // list columns shown (the table reports them)
    column_toggle: ?struct { col: c_int, on: bool } = null, // View Options asked to show/hide a list column
    quicklook_toggle: bool = false, // Space / menu asked to open or close Quick Look (shell consumes)
    // Get Info opens in a window of its own (a `zfd --get-info` process): the browser
    // asks for one here (the shell spawns it), and that process draws drawInfo.
    info_window: bool = false, // this process IS a Get Info window
    info_request: bool = false, // the item at prop_path wants a Get Info window
    del_pending: bool = false,
    openwith_pending: bool = false,
    tabs: bool = false, // the shell has tabs (browser, not the chooser): offer "Open in New Tab"
    live: []const *Browser = &.{}, // every browser that exists this frame (tabs + split pane)

    /// open opens item `i` the way a double-click or Enter does; a folder pops open.
    /// itemSize is the item size of view `mode`. A list's text stays its size, so its
    /// rows only grow.
    pub fn itemSize(self: *ViewActions, mode: core.folderprefs.Mode) ItemSize {
        return switch (mode) {
            .grid => .{ .v = &self.icon_scale, .min = 0.5, .max = 2.5 },
            .list => .{ .v = &self.list_scale, .min = 1, .max = 2.5 },
            .columns => .{ .v = &self.columns_scale, .min = 1, .max = 2.5 },
            .gallery => .{ .v = &self.gallery_scale, .min = 0.6, .max = 2 },
        };
    }

    pub fn open(self: *ViewActions, b: *Browser, i: usize) void {
        if (i >= b.count()) return;
        const e = b.at(i);
        if (e.isDir()) {
            self.pop.start(i);
            swallowRelease();
        }
        b.open(e) catch {};
    }

    /// swallowRelease keeps the press that opened a folder (a double-click's second)
    /// from also clicking in it: the folder's rows reuse the old ones' IDs, so its
    /// release would select whatever's now under the pointer. The press is dropped
    /// and the button held for nobody until it's let go.
    pub fn swallowRelease() void {
        if (!c.igIsMouseDown_Nil(c.ImGuiMouseButton_Left)) return; // (opened by key)
        c.igClearActiveID();
        c.igSetKeyOwner(c.ImGuiKey_MouseLeft, c.igGetID_Str("##opened-folder"), c.ImGuiInputFlags_LockUntilRelease);
    }

    /// openCursor is `open` for the item under the cursor (Enter).
    pub fn openCursor(self: *ViewActions, b: *Browser) void {
        self.open(b, b.sel.cursor);
    }

    /// dragSource resolves a row-drag payload to the browser it came from. The payload
    /// carries that browser's address (so a drop in another tab or pane reads the right
    /// snapshot); it's only trusted if that browser still exists: a tab closed
    /// mid-drag must not leave a dangling pointer behind.
    pub fn dragSource(self: *const ViewActions, payload: ?*const c.ImGuiPayload) ?*Browser {
        const p = payload orelse return null;
        if (p.DataSize != @sizeOf(usize) or p.Data == null) return null;
        const bytes: [*]const u8 = @ptrCast(p.Data);
        const addr = std.mem.readInt(usize, bytes[0..@sizeOf(usize)], .little);
        for (self.live) |b| {
            if (@intFromPtr(b) == addr) return b;
        }
        return null;
    }

    /// dragPayload is the payload bytes naming `b` as a drag's source.
    pub fn dragPayload(b: *Browser) [@sizeOf(usize)]u8 {
        var out: [@sizeOf(usize)]u8 = undefined;
        std.mem.writeInt(usize, &out, @intFromPtr(b), .little);
        return out;
    }

    /// rowMenu is the right-click context menu (operates on the current selection).
    pub fn rowMenu(self: *ViewActions, b: *Browser, i: usize) void {
        const e = b.at(i);
        const ro = b.insideArchive() != null; // read in place: nothing here changes
        if (c.igMenuItem_Bool("Open", null, false, true)) b.open(e) catch {};
        if (!e.isDir() and c.igMenuItem_Bool("Open with\u{2026}", null, false, true)) self.openwith_pending = true;
        if (c.igMenuItem_Bool("Quick Look", "Space", false, true)) {
            b.sel.click(i);
            self.quicklook_toggle = true;
        }
        if (e.isDir() and self.tabs and c.igMenuItem_Bool("Open in New Tab", "Middle-click", false, true)) {
            var pbuf: [4200]u8 = undefined;
            if (std.mem.print(&pbuf, "{s}/{s}", .{ if (std.mem.eql(u8, b.dir, "/")) "" else b.dir, e.name })) |path|
                b.requestNewTab(path)
            else |_| {}
        }
        if (e.isDir() and !ro) {
            if (c.igMenuItem_Bool("Open Terminal Here", null, false, true)) {
                var pbuf: [4200]u8 = undefined;
                const path = std.mem.print(&pbuf, "{s}/{s}", .{ b.dir, e.name }) catch b.dir;
                b.openTerminalIn(path);
            }
        }
        c.igSeparator();
        if (c.igMenuItem_Bool("Cut", "Ctrl+X", false, !ro)) b.cutSelection();
        if (c.igMenuItem_Bool("Copy", "Ctrl+C", false, true)) b.copySelection();
        // Paste into the right-clicked folder (like Explorer/Dolphin); into the current
        // directory for a file row or empty clipboard.
        const paste_label = if (e.isDir()) "Paste into folder" else "Paste";
        if (c.igMenuItem_Bool(paste_label, "Ctrl+V", false, !b.clipboard.isEmpty() and !ro)) b.pasteIntoDir(i);
        if (!b.virtualView()) {
            if (c.igMenuItem_Bool("Duplicate", "Ctrl+Alt+D", false, true)) b.duplicateSelection();
            var nb: [64]u8 = undefined;
            const n = b.sel.count();
            const nl = std.mem.printSentinel(&nb, "New Folder with Selection ({d} Item{s})", .{ n, if (n == 1) "" else "s" }, 0) catch "New Folder with Selection";
            if (c.igMenuItem_Bool(nl.ptr, "Ctrl+Alt+N", false, true)) b.newFolderWithSelection();
        }
        self.imageSection(b);
        self.archiveSection(b, e);
        c.igSeparator();
        if (b.sel.count() > 1 and c.igMenuItem_Bool("Rename\u{2026}", "F2", false, !ro)) {
            self.openBatchRename(b);
        } else if (b.sel.count() <= 1 and c.igMenuItem_Bool("Rename", "F2", false, !ro)) {
            b.sel.click(i); // rename the clicked row; the table does the inline edit
            b.requestRename();
        }
        if (c.igMenuItem_Bool("Move to Trash", "Del", false, !ro)) b.trashSelection();
        if (c.igMenuItem_Bool("Delete permanently", "Shift+Del", false, !ro)) self.askDeleteConfirm(b);
        c.igSeparator();
        if (!ro) {
            tagRow(b);
            c.igSeparator();
        }
        if (c.igMenuItem_Bool("Copy Path", null, false, true)) copyPathToClipboard(b, i);
        if (c.igMenuItem_Bool("Create Link", null, false, !ro)) b.linkSelection();
        if (c.igMenuItem_Bool("Get Info", "Alt+Enter", false, true)) self.openProperties(b, i);
    }

    /// archiveSection draws the WinRAR-style extract/compress items (only when bsdtar is
    /// present). An all-archive selection gets Extract; anything else gets Compress,
    /// never both. All actions run off-thread via the OpRunner (progress + refresh).
    /// imageSection is Finder's Quick Actions for pictures: rotate, convert (ffmpeg).
    fn imageSection(self: *ViewActions, b: *Browser) void {
        if (!allImages(b)) return;
        const ff = self.ffmpeg orelse return;
        c.igSeparator();
        var act: ?core.imagetool.Action = null;
        if (c.igMenuItem_Bool("Rotate Left", null, false, true)) act = .{ .rotate = false };
        if (c.igMenuItem_Bool("Rotate Right", null, false, true)) act = .{ .rotate = true };
        if (c.igBeginMenu("Convert Image", true)) {
            if (c.igMenuItem_Bool("To JPEG", null, false, true)) act = .{ .convert = .jpeg };
            if (c.igMenuItem_Bool("To PNG", null, false, true)) act = .{ .convert = .png };
            if (c.igMenuItem_Bool("To WebP", null, false, true)) act = .{ .convert = .webp };
            c.igEndMenu();
        }
        if (act) |a| {
            const paths = b.selectedPaths() catch return;
            defer {
                for (paths) |p| b.alloc.free(p);
                b.alloc.free(paths);
            }
            core.imagetool.run(b.io, b.alloc, ff, a, paths);
        }
    }

    fn archiveSection(self: *ViewActions, b: *Browser, e: scan.Entry) void {
        _ = self;
        // Inside an archive there's nothing to extract or compress in place: copying
        // items out is how they come out.
        if (b.virtualView()) return;
        // A package or document that's an archive inside (Finder's Show Package
        // Contents).
        if (b.sel.count() == 1 and !e.isDir() and b.canShowContents(e.name)) {
            c.igSeparator();
            if (c.igMenuItem_Bool("Show Contents", null, false, true)) {
                var pb: [4200]u8 = undefined;
                if (table.joinPath(&pb, b.dir, e.name)) |p| b.showContents(p);
            }
        }
        if (!b.hasArchiveTool()) return;
        c.igSeparator();
        if (b.selectionAllArchives()) {
            if (c.igMenuItem_Bool("Extract Here", null, false, true)) b.extractSelection(false);
            if (b.sel.count() > 1) {
                if (c.igMenuItem_Bool("Extract Each to Own Folder", null, false, true)) b.extractSelection(true);
            } else {
                var lbuf: [320]u8 = undefined;
                const stem = archive.stripArchiveExt(e.name);
                const label = std.mem.printSentinel(&lbuf, "Extract to \"{s}/\"", .{stem}, 0) catch "Extract to Folder";
                if (c.igMenuItem_Bool(label.ptr, null, false, true)) b.extractSelection(true);
            }
            // Archives only get Extract: re-compressing something that is already an
            // archive is never what the menu is for (and a .zip of a .zip is noise).
            return;
        }
        // Compress: the formats sit inline on one row instead of in an "Add to archive ▶"
        // submenu. Popups are confined to the main window (multi-viewport stays off; it
        // made menus blink), so a submenu that didn't fit beside the context menu was
        // clamped right on top of it. Hover a format to see the resulting file name.
        var nb: [512]u8 = undefined;
        const base = b.compressBaseName(&nb);
        c.igAlignTextToFramePadding();
        cimgui.textUnformatted("Compress to");
        for (archive.formats) |fmt| {
            c.igSameLine(0, -1);
            if (c.igSmallButton(fmt.label.ptr)) {
                b.compressSelection(fmt.ext);
                c.igCloseCurrentPopup();
            }
            if (c.igBeginItemTooltip()) {
                var lbuf: [640]u8 = undefined;
                cimgui.textUnformatted(std.mem.print(&lbuf, "{s}{s}", .{ base, fmt.ext }) catch fmt.ext);
                c.igEndTooltip();
            }
        }
    }

    /// openProperties snapshots the entry's metadata into prop_buf and marks the modal
    /// to open. Snapshotting (not holding the index) keeps it valid across reloads.
    pub fn openProperties(self: *ViewActions, b: *Browser, i: usize) void {
        if (i >= b.count()) return;
        const e = b.at(i);
        if (!self.info_window) {
            const p = std.mem.print(&self.prop_path_buf, "{s}/{s}", .{ if (std.mem.eql(u8, b.dir, "/")) "" else b.dir, e.name }) catch return;
            self.prop_path_len = p.len;
            self.info_request = true;
            return;
        }
        var szb: [32]u8 = undefined;
        var mb: [10]u8 = undefined;
        var mtb: [24]u8 = undefined;
        var atb: [24]u8 = undefined;
        var ctb: [24]u8 = undefined;
        var btb: [24]u8 = undefined;
        var tyb: [64]u8 = undefined;
        const size: []const u8 = if (e.isDir()) "-" else scan.humanizeSize(&szb, e.size);
        const created = if (e.btime_secs > 0) scan.formatDateFriendly(&btb, e.btime_secs, table.nowSecs()) else "-";
        const link = if (e.link_target.len > 0) e.link_target else "-";
        // General: one "Label\tValue" line per row.
        const text = std.mem.print(&self.prop_buf, "Kind\t{s}\nSize\t{s}\nWhere\t{s}\nCreated\t{s}\nModified\t{s}\nAccessed\t{s}\nChanged\t{s}\nOwner\t{s} ({s})\nLinks\t{d}    Inode {d}\nLink to\t{s}", .{
            b.typeLabel(e, &tyb),                size,
            b.dir,                               created,
            scan.formatDateFriendly(&mtb, e.mtime_secs, table.nowSecs()), scan.formatDateFriendly(&atb, e.atime_secs, table.nowSecs()),
            scan.formatDateFriendly(&ctb, e.ctime_secs, table.nowSecs()), scan.ownerName(e.uid),
            scan.groupName(e.gid),               e.nlink,
            e.inode,                             link,
        }) catch return;
        _ = &mb;
        const shown = std.fs.path.basename(e.name);
        const nl = @min(shown.len, self.prop_name.len - 1);
        @memcpy(self.prop_name[0..nl], shown[0..nl]);
        self.prop_name[nl] = 0;
        self.prop_name_orig = self.prop_name;
        self.prop_kind = e.kind;
        var hb: [24]u8 = undefined;
        const head = std.mem.print(&self.prop_head, "{s}{s}Modified {s}", .{ if (e.isDir()) "" else size, if (e.isDir()) "" else "  \u{00B7}  ", scan.formatDateFriendly(&hb, e.mtime_secs, table.nowSecs()) }) catch "";
        self.prop_head_len = head.len;
        self.prop_app = std.math.maxInt(usize);
        self.prop_msg = null;
        self.prop_len = text.len;
        const full = std.mem.print(&self.prop_path_buf, "{s}/{s}", .{ if (std.mem.eql(u8, b.dir, "/")) "" else b.dir, e.name }) catch return;
        self.prop_path_len = full.len;
        @memset(&self.prop_comment_saved, 0);
        if (std.mem.printSentinel(&self.prop_comment, "{s}", .{full}, 0)) |pz| {
            const cm = core.comments.read(pz, self.prop_comment_saved[0 .. self.prop_comment_saved.len - 1]);
            self.prop_comment_saved[cm.len] = 0;
        } else |_| {}
        self.prop_comment = self.prop_comment_saved;
        self.prop_mode = e.mode & 0o7777;
        self.prop_edit = self.prop_mode;
        self.prop_err = null;
        if (self.probe) |pr| pr.release();
        self.probe = if (e.isDir()) (core.sizeprobe.SizeProbe.start(b.io, b.alloc, full) catch null) else null;
    }

    /// takeInfoRequest is the path the browser wants a Get Info window for, once.
    pub fn takeInfoRequest(self: *ViewActions) ?[]const u8 {
        if (!self.info_request) return null;
        self.info_request = false;
        return self.prop_path_buf[0..self.prop_path_len];
    }

    /// openBatchRename snapshots the selected names (and every name in the folder, for
    /// the "already exists" check) and raises the batch-rename dialog.
    pub fn openBatchRename(self: *ViewActions, b: *Browser) void {
        self.freeBatch(b.alloc);
        self.br_taken = std.StringHashMap(void).init(b.alloc);
        self.br_taken_live = true;
        const l = b.listing orelse return;
        for (l.entries) |e| {
            const d = b.alloc.dupe(u8, e.name) catch continue;
            self.br_all.append(b.alloc, d) catch {
                b.alloc.free(d);
                continue;
            };
            self.br_taken.put(d, {}) catch {};
        }
        var i: usize = 0;
        while (i < b.count()) : (i += 1) {
            if (!b.sel.isSelected(i)) continue;
            const d = b.alloc.dupe(u8, b.at(i).name) catch continue;
            self.br_olds.append(b.alloc, d) catch b.alloc.free(d);
        }
        if (self.br_olds.items.len == 0) return;
        // Start from something useful: the first name's stem + a counter.
        const first = self.br_olds.items[0];
        const dot = std.mem.lastIndexOfScalar(u8, first, '.') orelse first.len;
        const stem = first[0..if (dot == 0) first.len else dot];
        _ = std.mem.printSentinel(&self.br_a, "{s} #", .{stem[0..@min(stem.len, 200)]}, 0) catch {};
        self.br_b[0] = 0;
        self.br_pending = true;
    }

    /// freeBatch drops the batch-rename snapshot (safe to call any number of times).
    pub fn freeBatch(self: *ViewActions, alloc: std.mem.Allocator) void {
        for (self.br_olds.items) |n| alloc.free(n);
        self.br_olds.clearRetainingCapacity();
        for (self.br_all.items) |n| alloc.free(n);
        self.br_all.clearRetainingCapacity();
        if (self.br_taken_live) self.br_taken.deinit();
        self.br_taken_live = false;
    }

    fn takenIn(ctx: *anyopaque, name: []const u8) bool {
        const self: *ViewActions = @ptrCast(@alignCast(ctx));
        return self.br_taken.contains(name);
    }

    fn drawBatchRenameModal(self: *ViewActions, b: *Browser) void {
        if (self.br_pending) {
            c.igOpenPopup_Str("Rename items", 0);
            self.br_pending = false;
        }
        c.igSetNextWindowSize(cimgui.vec2(620, 460), c.ImGuiCond_Appearing);
        if (!c.igBeginPopupModal("Rename items", null, 0)) return;
        defer c.igEndPopup();
        const n = self.br_olds.items.len;
        var hb: [64]u8 = undefined;
        cimgui.textUnformatted(std.mem.print(&hb, "Rename {d} items", .{n}) catch "Rename");

        var mode_i: c_int = @backingInt(self.br_mode);
        _ = c.igRadioButton_IntPtr("Pattern", &mode_i, 0);
        c.igSameLine(0, -1);
        _ = c.igRadioButton_IntPtr("Find and replace", &mode_i, 1);
        self.br_mode = @fromBackingInt(@intCast(mode_i));
        if (c.igIsWindowAppearing()) c.igSetKeyboardFocusHere(0);
        c.igSetNextItemWidth(-1);
        if (self.br_mode == .pattern) {
            _ = c.igInputTextWithHint("##brpat", "e.g. photo_###", &self.br_a, self.br_a.len, 0, null, null);
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
            c.igPushTextWrapPos(0);
            cimgui.textUnformatted("# = number (### pads to 001), * = original name. The extension is kept unless you type one.");
            c.igPopTextWrapPos();
            c.igPopStyleColor(1);
        } else {
            _ = c.igInputTextWithHint("##brfind", "Find", &self.br_a, self.br_a.len, 0, null, null);
            c.igSetNextItemWidth(-1);
            _ = c.igInputTextWithHint("##brrepl", "Replace with", &self.br_b, self.br_b.len, 0, null, null);
        }

        // Preview every new name and validate the batch.
        const a = b.alloc;
        const pat = std.mem.sliceTo(&self.br_a, 0);
        const rep_s = std.mem.sliceTo(&self.br_b, 0);
        var news = std.ArrayList([]u8).empty;
        defer {
            for (news.items) |x| a.free(x);
            news.deinit(a);
        }
        for (self.br_olds.items, 0..) |o, i| {
            const nn = core.batchrename.newName(a, self.br_mode, pat, rep_s, o, i) catch a.dupe(u8, o) catch continue;
            news.append(a, nn) catch a.free(nn);
        }
        if (news.items.len != n) return;
        var blocking = false;
        var changes: usize = 0;
        _ = c.igBeginChild_Str("##brprev", cimgui.vec2(0, -c.igGetFrameHeightWithSpacing() - 4), c.ImGuiChildFlags_Borders, 0);
        if (c.igBeginTable("##brtbl", 2, c.ImGuiTableFlags_RowBg | c.ImGuiTableFlags_BordersInnerV, cimgui.vec2(0, 0), 0)) {
            c.igTableSetupColumn("Current name", c.ImGuiTableColumnFlags_WidthStretch, 0, 0);
            c.igTableSetupColumn("New name", c.ImGuiTableColumnFlags_WidthStretch, 0, 0);
            c.igTableHeadersRow();
            const nsl: []const []const u8 = @ptrCast(news.items);
            const osl: []const []const u8 = @ptrCast(self.br_olds.items);
            for (news.items, 0..) |nn, i| {
                const prob = core.batchrename.check(nn, i, nsl, osl, takenIn, self);
                if (prob != .none and prob != .unchanged) blocking = true;
                if (prob != .unchanged) changes += 1;
                c.igTableNextRow(0, 0);
                _ = c.igTableSetColumnIndex(0);
                cimgui.textUnformatted(self.br_olds.items[i]);
                _ = c.igTableSetColumnIndex(1);
                const why: []const u8 = switch (prob) {
                    .none => "",
                    .unchanged => "  (unchanged)",
                    .empty => "  (empty name)",
                    .invalid => "  (invalid name)",
                    .duplicate => "  (duplicate)",
                    .exists => "  (already exists)",
                };
                var lb: [700]u8 = undefined;
                const line = std.mem.print(&lb, "{s}{s}", .{ nn, why }) catch nn;
                const col = switch (prob) {
                    .none => cimgui.vec4(1, 1, 1, 1),
                    .unchanged => theme.dim(),
                    else => theme.err(),
                };
                c.igPushStyleColor_Vec4(c.ImGuiCol_Text, col);
                cimgui.textUnformatted(line);
                c.igPopStyleColor(1);
            }
            c.igEndTable();
        }
        c.igEndChild();

        const can = !blocking and changes > 0;
        c.igBeginDisabled(!can);
        const go = c.igButton("Rename", cimgui.vec2(0, 0)) or (can and c.igIsKeyPressed_Bool(c.ImGuiKey_Enter, false));
        c.igEndDisabled();
        c.igSameLine(0, -1);
        const cancel = c.igButton("Cancel", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false);
        if (go and can) {
            const osl: []const []const u8 = @ptrCast(self.br_olds.items);
            const nsl: []const []const u8 = @ptrCast(news.items);
            b.renameMany(osl, nsl);
        }
        if ((go and can) or cancel) {
            self.freeBatch(a);
            c.igCloseCurrentPopup();
        }
    }

    pub fn askDeleteConfirm(self: *ViewActions, b: *Browser) void {
        const n = b.sel.count();
        if (n == 0) return;
        self.del_count = n;
        self.del_pending = true;
    }

    /// drawModals opens any pending modal at THIS (shell) scope and draws them all.
    /// Call once per frame from the shell, outside the views' scopes.
    pub fn drawModals(self: *ViewActions, b: *Browser) void {
        if (self.del_pending) {
            c.igOpenPopup_Str("Delete permanently", 0);
            self.del_pending = false;
        }
        if (self.openwith_pending) {
            c.igOpenPopup_Str("Open with", 0);
            self.openwith_pending = false;
            self.openwith_search[0] = 0;
            self.openwith_sel = 0;
        }
        self.drawDeleteConfirmModal(b);
        self.drawOpenWithModal(b);
        self.drawConflictModal(b);
        self.drawBatchRenameModal(b);
        drawUntrashableModal(b);
    }

    /// drawUntrashableModal: some items couldn't go to the Trash (a network share
    /// without one, a drive we can't write a trash folder to, …). Ask whether to delete
    /// them permanently instead, as Finder and Explorer do.
    fn drawUntrashableModal(b: *Browser) void {
        const u = b.untrashablePending() orelse return;
        const title = "Can't move to Trash";
        if (!c.igIsPopupOpen_Str(title, 0)) c.igOpenPopup_Str(title, 0);
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(cimgui.vec2(vp.*.WorkPos.x + vp.*.WorkSize.x * 0.5, vp.*.WorkPos.y + vp.*.WorkSize.y * 0.5), c.ImGuiCond_Appearing, cimgui.vec2(0.5, 0.5));
        if (!c.igBeginPopupModal(title, null, c.ImGuiWindowFlags_AlwaysAutoResize)) return;
        defer c.igEndPopup();
        var buf: [600]u8 = undefined;
        const msg = if (u.count == 1)
            std.mem.print(&buf, "\"{s}\" can't be moved to the Trash.", .{u.first}) catch "This item can't be moved to the Trash."
        else
            std.mem.print(&buf, "{d} items can't be moved to the Trash.", .{u.count}) catch "These items can't be moved to the Trash.";
        cimgui.textUnformatted(msg);
        if (u.why.len > 0) {
            var wb: [200]u8 = undefined;
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
            cimgui.textUnformatted(std.mem.print(&wb, "Reason: {s}", .{core.fsops.errorMessage(u.why)}) catch u.why);
            c.igPopStyleColor(1);
        }
        c.igSpacing();
        cimgui.textUnformatted(if (u.count == 1) "Delete it permanently? This can't be undone." else "Delete them permanently? This can't be undone.");
        c.igSeparator();
        if (c.igButton("Cancel", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
            b.clearUntrashable();
            c.igCloseCurrentPopup();
        }
        c.igSameLine(0, -1);
        c.igPushStyleColor_Vec4(c.ImGuiCol_Button, theme.err());
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, cimgui.vec4(1, 1, 1, 1));
        if (c.igButton("Delete Permanently", cimgui.vec2(0, 0))) {
            b.deleteUntrashable();
            c.igCloseCurrentPopup();
        }
        c.igPopStyleColor(2);
    }

    /// drawConflictModal asks what to do with a copy/move whose names are already taken
    /// at the destination. Raised by the model (Browser.parked), so every way of starting
    /// a transfer (paste, drag, drop from another app) gets the same question.
    fn drawConflictModal(self: *ViewActions, b: *Browser) void {
        const info = b.conflictInfo() orelse return;
        const title = "Items already exist";
        if (!c.igIsPopupOpen_Str(title, 0)) {
            c.igOpenPopup_Str(title, 0);
            self.conflict_all = true;
        }
        const vp = c.igGetMainViewport();
        c.igSetNextWindowPos(cimgui.vec2(vp.*.WorkPos.x + vp.*.WorkSize.x * 0.5, vp.*.WorkPos.y + vp.*.WorkSize.y * 0.5), c.ImGuiCond_Appearing, cimgui.vec2(0.5, 0.5));
        if (!c.igBeginPopupModal(title, null, c.ImGuiWindowFlags_AlwaysAutoResize)) return;
        defer c.igEndPopup();

        var buf: [900]u8 = undefined;
        const folder = std.fs.path.basename(info.dst_dir);
        const where = if (folder.len > 0) folder else "/";
        const msg = if (info.clashes == 1)
            std.mem.print(&buf, "\"{s}\" already exists in \"{s}\".", .{ info.name, where }) catch "An item already exists."
        else
            std.mem.print(&buf, "Conflict {d} of {d}: \"{s}\" already exists in \"{s}\".", .{ info.step + 1, info.clashes, info.name, where }) catch "Some items already exist.";
        cimgui.textUnformatted(msg);
        c.igSpacing();
        drawConflictCompare(info);
        c.igSpacing();
        const folders = info.incoming.is_dir and info.existing.is_dir;
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
        cimgui.textUnformatted("Replace sends the existing item to the Trash.");
        if (folders) cimgui.textUnformatted("Write Into adds this folder's contents to the existing one.");
        c.igPopStyleColor(1);

        const left = info.clashes - info.step;
        if (left > 1) {
            var lbuf: [64]u8 = undefined;
            const lbl = std.mem.printSentinel(&lbuf, "Apply to all {d} remaining conflicts", .{left}, 0) catch "Apply to all";
            _ = c.igCheckbox(lbl.ptr, &self.conflict_all);
        }
        c.igSeparator();

        var choice: ?core.oprunner.OpRunner.Conflict = null;
        var answered = false;
        if (folders) {
            if (c.igButton("Write Into", cimgui.vec2(0, 0))) {
                choice = .merge;
                answered = true;
            }
            if (c.igIsItemHovered(0)) c.igSetTooltip(if (left > 1 and self.conflict_all)
                "Keep the existing folder and add this one's contents to it; files with the same name are overwritten.\nFiles among the remaining conflicts are replaced."
            else
                "Keep the existing folder and add this one's contents to it; files with the same name are overwritten.");
            c.igSameLine(0, -1);
        }
        if (c.igButton("Replace", cimgui.vec2(0, 0))) {
            choice = .replace;
            answered = true;
        }
        c.igSameLine(0, -1);
        if (c.igButton("Replace if newer", cimgui.vec2(0, 0))) {
            choice = .replace_older;
            answered = true;
        }
        if (c.igIsItemHovered(0)) c.igSetTooltip("Replace only when the incoming item was modified more recently; otherwise skip it");
        c.igSameLine(0, -1);
        if (c.igButton("Skip", cimgui.vec2(0, 0))) {
            choice = .skip;
            answered = true;
        }
        c.igSameLine(0, -1);
        if (c.igButton("Keep both", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Enter, false)) {
            choice = .keep_both; // the non-destructive default (Enter)
            answered = true;
        }
        c.igSameLine(0, -1);
        if (c.igButton("Cancel", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) answered = true;
        if (!answered) return;
        if (choice) |ch| {
            if (self.conflict_all or left == 1) b.resolveConflict(ch) else b.decideOne(ch);
        } else b.resolveConflict(null);
        if (b.conflictInfo() == null) c.igCloseCurrentPopup();
    }

    /// drawInfo is Get Info's contents, filling the window it's drawn in (a Get Info
    /// window: see Shell.drawInfoWindow). Returns true when it asks to close (Escape).
    pub fn drawInfo(self: *ViewActions, b: *Browser) bool {
        const fs = c.igGetFontSize();
        const path = self.prop_path_buf[0..self.prop_path_len];
        // Inside an archive (read in place) the item is shown, not changed.
        const ro = core.arcfs.split(path) != null and b.insideArchive() != null;

        // Header, as Finder's Get Info: the icon, the name, size and date.
        const head_pos = c.igGetCursorScreenPos();
        const icon_sz = fs * 3;
        const nm = std.mem.sliceTo(&self.prop_name_orig, 0);
        icons.draw(c.igGetWindowDrawList(), .{ .name = @constCast(nm), .kind = self.prop_kind }, head_pos.x, head_pos.y, icon_sz, false);
        c.igIndent(icon_sz + fs * 0.6);
        c.igPushFont(null, fs * 1.15);
        cimgui.textUnformatted(nm);
        c.igPopFont();
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
        cimgui.textUnformatted(self.prop_head[0..self.prop_head_len]);
        c.igPopStyleColor(1);
        c.igUnindent(icon_sz + fs * 0.6);
        c.igSetCursorScreenPos(cimgui.vec2(head_pos.x, @max(c.igGetCursorScreenPos().y, head_pos.y + icon_sz + fs * 0.3)));
        tagRowIn(b, false);

        if (infoSection("General:", true)) {
            if (c.igBeginTable("##general", 2, 0, cimgui.vec2(-1, 0), 0)) {
                // Finder's layout: labels right-aligned with a colon, values wrapping.
                c.igTableSetupColumn("", c.ImGuiTableColumnFlags_WidthFixed, @round(fs * 5.5), 0);
                c.igTableSetupColumn("", c.ImGuiTableColumnFlags_WidthStretch, 0, 0);
                var it = std.mem.splitScalar(u8, self.prop_buf[0..self.prop_len], '\n');
                while (it.next()) |line| {
                    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
                    const val = line[tab + 1 ..];
                    if (val.len == 0 or std.mem.eql(u8, val, "-")) continue; // nothing to say
                    c.igTableNextRow(0, 0);
                    _ = c.igTableSetColumnIndex(0);
                    var lb: [40]u8 = undefined;
                    const lbl = std.mem.print(&lb, "{s}:", .{line[0..tab]}) catch line[0..tab];
                    const lw = c.igCalcTextSize(lbl.ptr, lbl.ptr + lbl.len, false, -1).x;
                    c.igSetCursorPosX(c.igGetCursorPosX() + @max(c.igGetContentRegionAvail().x - lw, 0));
                    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
                    cimgui.textUnformatted(lbl);
                    c.igPopStyleColor(1);
                    _ = c.igTableSetColumnIndex(1);
                    c.igPushTextWrapPos(0);
                    cimgui.textUnformatted(val);
                    c.igPopTextWrapPos();
                }
                c.igEndTable();
            }
            // A folder's real size: totaled in the background, shown climbing.
            if (self.probe) |pr| {
                const t = pr.totals();
                var sb: [32]u8 = undefined;
                var lb: [160]u8 = undefined;
                const line = std.mem.print(&lb, "Contents: {d} files, {d} folders, {s}{s}", .{
                    t.files, t.dirs, scan.humanizeSize(&sb, t.bytes), if (t.done) "" else "  (counting\u{2026})",
                }) catch "";
                cimgui.textUnformatted(line);
            }
        }

        if (infoSection("Name & Extension:", false)) {
            c.igBeginDisabled(ro);
            defer c.igEndDisabled();
            c.igSetNextItemWidth(-1);
            const enter = c.igInputText("##propname", &self.prop_name, self.prop_name.len, c.ImGuiInputTextFlags_EnterReturnsTrue, null, null);
            const typed = std.mem.sliceTo(&self.prop_name, 0);
            const differs = !std.mem.eql(u8, typed, std.mem.sliceTo(&self.prop_name_orig, 0));
            c.igBeginDisabled(!differs or typed.len == 0);
            if ((c.igButton("Rename", cimgui.vec2(0, 0)) or enter) and differs and typed.len > 0) {
                // Only while the item is still the one under the cursor (it was opened
                // from there); otherwise the folder changed under the dialog.
                if (b.sel.cursor < b.count() and std.mem.eql(u8, std.fs.path.basename(b.at(b.sel.cursor).name), std.mem.sliceTo(&self.prop_name_orig, 0))) {
                    b.renameCursor(typed);
                    self.prop_name_orig = self.prop_name;
                } else self.prop_msg = "The folder changed; rename it from the list.";
            }
            c.igEndDisabled();
        }

        if (!ro and infoSection("Comments:", true)) {
            _ = c.igInputTextMultiline("##comment", &self.prop_comment, self.prop_comment.len, cimgui.vec2(-1, fs * 3.5), 0, null, null);
            if (c.igIsItemDeactivated() and !std.mem.eql(u8, std.mem.sliceTo(&self.prop_comment, 0), std.mem.sliceTo(&self.prop_comment_saved, 0))) {
                if (core.comments.write(b.alloc, path, std.mem.sliceTo(&self.prop_comment, 0))) |_| {
                    self.prop_comment_saved = self.prop_comment;
                    self.prop_msg = null;
                } else |e| self.prop_msg = switch (e) {
                    error.CommentsNotSupported => "This drive can't keep comments.",
                    error.AccessDenied => "You can't change this item.",
                    else => "The comment couldn't be saved.",
                };
            }
        }

        if (self.prop_kind != .dir and infoSection("Open with:", false)) {
            const apps = b.appList();
            const mime = b.cursorMime();
            if (self.prop_app >= apps.len) {
                // Start on the app that opens it now.
                const cur = b.opensWith(nm);
                for (apps, 0..) |a, i| if (std.mem.eql(u8, a.name, cur)) {
                    self.prop_app = i;
                };
            }
            c.igSetNextItemWidth(fs * 16);
            const preview: [*:0]const u8 = if (self.prop_app < apps.len) (std.mem.printSentinel(&self.prop_buf_app, "{s}", .{apps[self.prop_app].name}, 0) catch "Choose\u{2026}") else "Choose\u{2026}";
            if (c.igBeginCombo("##propapp", preview, 0)) {
                // Apps that handle this kind of file first.
                for (0..2) |pass| for (apps, 0..) |a, i| {
                    if ((pass == 0) != a.handles(mime)) continue;
                    var lb: [300]u8 = undefined;
                    const label = std.mem.printSentinel(&lb, "{s}##app{d}", .{ a.name, i }, 0) catch continue;
                    if (c.igSelectable_Bool(label.ptr, i == self.prop_app, 0, cimgui.vec2(0, 0))) self.prop_app = i;
                };
                c.igEndCombo();
            }
            c.igSameLine(0, -1);
            c.igBeginDisabled(self.prop_app >= apps.len or mime.len == 0);
            if (c.igButton("Change All\u{2026}", cimgui.vec2(0, 0))) c.igOpenPopup_Str("Change all", 0);
            c.igEndDisabled();
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
            c.igPushTextWrapPos(0);
            cimgui.textUnformatted("Change All makes it the app for every file of this kind.");
            c.igPopTextWrapPos();
            c.igPopStyleColor(1);
            if (c.igBeginPopupModal("Change all", null, c.ImGuiWindowFlags_AlwaysAutoResize)) {
                var qb: [600]u8 = undefined;
                const what = b.typeLabel(.{ .name = @constCast(nm), .kind = self.prop_kind }, qb[300..]);
                cimgui.textUnformatted(std.mem.print(qb[0..300], "Open every {s} with {s}?", .{ what, if (self.prop_app < apps.len) apps[self.prop_app].name else "" }) catch "Change the app for every file of this kind?");
                if (c.igButton("Change All", cimgui.vec2(0, 0))) {
                    b.setDefaultApp(self.prop_app);
                    c.igCloseCurrentPopup();
                }
                c.igSameLine(0, -1);
                if (c.igButton("Cancel", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) c.igCloseCurrentPopup();
                c.igEndPopup();
            }
        }

        if (self.prop_msg) |m| {
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.err());
            cimgui.textUnformatted(m);
            c.igPopStyleColor(1);
        }

        // Permissions: the classic 3×3 grid. Apply writes them with chmod.
        const close = c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false) and !c.igIsAnyItemActive();
        if (!infoSection("Sharing & Permissions:", false)) return close;
        c.igBeginDisabled(ro);
        defer c.igEndDisabled();
        if (c.igBeginTable("##perm", 4, c.ImGuiTableFlags_SizingFixedFit, cimgui.vec2(0, 0), 0)) {
            c.igTableSetupColumn("", 0, 0, 0);
            c.igTableSetupColumn("Read", 0, 0, 0);
            c.igTableSetupColumn("Write", 0, 0, 0);
            c.igTableSetupColumn("Execute", 0, 0, 0);
            c.igTableHeadersRow();
            const who = [_][:0]const u8{ "Owner", "Group", "Others" };
            for (who, 0..) |w, row| {
                c.igTableNextRow(0, 0);
                _ = c.igTableSetColumnIndex(0);
                cimgui.textUnformatted(w);
                const shift: u5 = @intCast(6 - row * 3);
                var col: usize = 0;
                while (col < 3) : (col += 1) {
                    _ = c.igTableSetColumnIndex(@intCast(col + 1));
                    const rwx: u32 = 0o4;
                    const bit: u32 = (rwx >> @as(u5, @intCast(col))) << shift;
                    var on = self.prop_edit & bit != 0;
                    var idb: [16]u8 = undefined;
                    const id = std.mem.printSentinel(&idb, "##p{d}{d}", .{ row, col }, 0) catch continue;
                    if (c.igCheckbox(id.ptr, &on)) {
                        if (on) self.prop_edit |= bit else self.prop_edit &= ~bit;
                    }
                }
            }
            c.igEndTable();
        }
        var ob: [48]u8 = undefined;
        const octal = std.mem.print(&ob, "Mode: {o:0>4}", .{self.prop_edit}) catch "";
        cimgui.textUnformatted(octal);
        if (self.prop_err) |e| {
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.err());
            var eb: [96]u8 = undefined;
            cimgui.textUnformatted(std.mem.print(&eb, "Could not change permissions: {s}", .{e}) catch e);
            c.igPopStyleColor(1);
        }
        c.igSeparator();
        const changed = self.prop_edit != self.prop_mode;
        c.igBeginDisabled(!changed);
        if (c.igButton("Apply", cimgui.vec2(0, 0))) {
            if (core.fsops.chmodPath(self.prop_path_buf[0..self.prop_path_len], self.prop_edit)) |_| {
                self.prop_mode = self.prop_edit;
                self.prop_err = null;
                b.refresh();
            } else |e| self.prop_err = @errorName(e);
        }
        c.igEndDisabled();
        return close;
    }

    fn drawDeleteConfirmModal(self: *ViewActions, b: *Browser) void {
        if (c.igBeginPopupModal("Delete permanently", null, c.ImGuiWindowFlags_AlwaysAutoResize)) {
            var buf: [128]u8 = undefined;
            const msg = std.mem.print(&buf, "Permanently delete {d} item(s)?\nThis cannot be undone.", .{self.del_count}) catch "Permanently delete?";
            cimgui.textUnformatted(msg);
            c.igSeparator();
            if (c.igButton("Delete", cimgui.vec2(90, 0))) {
                b.deleteSelection(true);
                c.igCloseCurrentPopup();
            }
            c.igSameLine(0, -1);
            if (c.igButton("Cancel", cimgui.vec2(90, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) c.igCloseCurrentPopup();
            c.igEndPopup();
        }
    }

    fn drawOpenWithModal(self: *ViewActions, b: *Browser) void {
        // NOTE: the 2nd arg is an ImGuiCond, NOT window flags; passing a WindowFlags
        // value here (256) fails ImGui's SetWindowSizeAllowFlags mask, so the size was
        // silently dropped and the modal auto-fit to near-zero, hiding the whole list.
        c.igSetNextWindowSize(cimgui.vec2(460, 440), c.ImGuiCond_Appearing);
        if (!c.igBeginPopupModal("Open with", null, c.ImGuiWindowFlags_NoSavedSettings)) return;
        defer c.igEndPopup();

        if (c.igIsWindowAppearing()) c.igSetKeyboardFocusHere(0); // focus the search box on open
        c.igSetNextItemWidth(-1);
        // EnterReturnsTrue: pressing Enter in the search box confirms the highlighted app.
        const entered = c.igInputTextWithHint("##owsearch", "Search applications\u{2026}", &self.openwith_search, self.openwith_search.len, c.ImGuiInputTextFlags_EnterReturnsTrue, null, null);
        const query = std.mem.sliceTo(&self.openwith_search, 0);

        const apps = b.appList();
        var open_now: ?usize = null;
        var first_visible: ?usize = null; // first row passing the filter (Enter/Open fallback)
        var sel_visible = false; // is the highlighted row still in the filtered set?

        // Apps that declare the file's MIME type come first, under "Recommended";
        // everything else follows under "Other applications".
        const mime = b.cursorMime();
        var n_rec: usize = 0;
        for (apps, 0..) |app, ai| {
            if (!app.handles(mime)) continue;
            // On open, highlight the first recommended app so Enter opens with it.
            if (n_rec == 0 and c.igIsWindowAppearing()) self.openwith_sel = ai;
            n_rec += 1;
        }

        _ = c.igBeginChild_Str("##owlist", cimgui.vec2(0, -c.igGetFrameHeightWithSpacing()), c.ImGuiChildFlags_Borders, 0);
        if (apps.len == 0) cimgui.textUnformatted("No applications found.");
        for ([_]bool{ true, false }) |recommended| {
            if (n_rec > 0 and (!recommended or n_rec < apps.len)) {
                c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
                cimgui.textUnformatted(if (recommended) "Recommended" else "Other applications");
                c.igPopStyleColor(1);
            }
            for (apps, 0..) |app, ai| {
                if (app.handles(mime) != recommended) continue;
                if (query.len > 0 and !containsCI(app.name, query)) continue;
                if (first_visible == null) first_visible = ai;
                if (self.openwith_sel == ai) sel_visible = true;
                var lbuf: [320]u8 = undefined;
                const label = std.mem.printSentinel(&lbuf, "{s}##ow{d}", .{ app.name, ai }, 0) catch continue;
                if (c.igSelectable_Bool(label.ptr, self.openwith_sel == ai, 0, cimgui.vec2(0, 0))) self.openwith_sel = ai;
                if (c.igIsItemHovered(0) and c.igIsMouseDoubleClicked_Nil(0)) open_now = ai;
            }
        }
        c.igEndChild();

        // The effective target: the highlighted row if it's still visible, else the
        // first match (so Enter/Open always does the obvious thing after filtering).
        const target: ?usize = if (sel_visible) self.openwith_sel else first_visible;
        if (entered) open_now = target;

        const can_open = target != null;
        if (c.igButton("Open", cimgui.vec2(0, 0)) and can_open) open_now = target;
        c.igSameLine(0, -1);
        if (c.igButton("Set as default & Open", cimgui.vec2(0, 0)) and can_open) {
            b.setDefaultApp(target.?);
            open_now = target;
        }
        c.igSameLine(0, -1);
        // Esc closes it, from the search field too.
        if (c.igButton("Cancel", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) c.igCloseCurrentPopup();

        if (open_now) |ai| {
            b.openWithApp(ai);
            c.igCloseCurrentPopup();
        }
    }
};

/// tagRow is the right-click menu's row of colour swatches (Finder's Tags): click one to
/// put that tag on the selection, or take it off when every selected item has it. A
/// filled swatch = all have it, a ring = some do.
fn tagRow(b: *Browser) void {
    tagRowIn(b, true);
}

/// tagRowIn is tagRow; `close` closes the popup it sits in after a click (the menu
/// does, Get Info doesn't).
fn tagRowIn(b: *Browser, close: bool) void {
    cimgui.textUnformatted("Tags");
    const fs = c.igGetFontSize();
    const d = @round(fs * 1.15);
    const dl = c.igGetWindowDrawList();
    for (core.tags.list(), 0..) |col, k| {
        c.igSameLine(0, if (k == 0) fs * 0.8 else fs * 0.35);
        c.igPushID_Int(@intCast(k));
        defer c.igPopID();
        const st = b.selectionTagged(col.bit());
        const clicked = c.igInvisibleButton("##tag", cimgui.vec2(d, d), 0);
        const mn = c.igGetItemRectMin();
        const center = cimgui.vec2(mn.x + d * 0.5, mn.y + d * 0.5);
        const rgb = col.rgb();
        const abgr: u32 = 0xFF000000 | ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF);
        const r = d * 0.42;
        if (st.with == st.of and st.of > 0) {
            c.ImDrawList_AddCircleFilled(dl, center, r, abgr, 16);
            c.ImDrawList_AddCircle(dl, center, r + 2, c.igGetColorU32_Col(c.ImGuiCol_Text, 1), 16, 1.5); // has it: ringed
        } else if (st.with > 0) {
            c.ImDrawList_AddCircleFilled(dl, center, r * 0.55, abgr, 16);
            c.ImDrawList_AddCircle(dl, center, r, abgr, 16, 2);
        } else {
            c.ImDrawList_AddCircleFilled(dl, center, r, abgr, 16);
        }
        if (c.igIsItemHovered(0)) c.igSetTooltip("%s", col.name().ptr);
        if (clicked) {
            b.toggleTag(col.bit());
            if (close) c.igCloseCurrentPopup();
        }
    }
}

/// drawConflictCompare shows the existing and incoming item side by side (size and
/// modified date), marking which one is newer and which is larger.
fn drawConflictCompare(info: core.browser.ConflictInfo) void {
    if (!c.igBeginTable("##cmp", 3, c.ImGuiTableFlags_SizingFixedFit | c.ImGuiTableFlags_BordersInnerV, cimgui.vec2(0, 0), 0)) return;
    defer c.igEndTable();
    c.igTableSetupColumn("", 0, 0, 0);
    c.igTableSetupColumn("Size", 0, 0, 0);
    c.igTableSetupColumn("Modified", 0, 0, 0);
    c.igTableHeadersRow();
    const rows = [_]struct { label: [:0]const u8, it: core.fsops.Brief, other: core.fsops.Brief }{
        .{ .label = "Existing", .it = info.existing, .other = info.incoming },
        .{ .label = if (info.copy) "Copying in" else "Moving in", .it = info.incoming, .other = info.existing },
    };
    for (rows) |r| {
        c.igTableNextRow(0, 0);
        _ = c.igTableNextColumn();
        cimgui.textUnformatted(r.label);
        _ = c.igTableNextColumn();
        var sb: [32]u8 = undefined;
        var line: [64]u8 = undefined;
        const size_s = if (r.it.is_dir) "folder" else core.scan.humanizeSize(&sb, r.it.size);
        const bigger = !r.it.is_dir and !r.other.is_dir and r.it.size > r.other.size;
        cimgui.textUnformatted(std.mem.print(&line, "{s}{s}", .{ size_s, if (bigger) "  (larger)" else "" }) catch size_s);
        _ = c.igTableNextColumn();
        var db: [32]u8 = undefined;
        var line2: [64]u8 = undefined;
        const date_s = core.scan.formatDateFriendly(&db, r.it.mtime_secs, table.nowSecs());
        const newer = r.it.mtime_secs > r.other.mtime_secs;
        cimgui.textUnformatted(std.mem.print(&line2, "{s}{s}", .{ if (date_s.len > 0) date_s else "unknown", if (newer) "  (newer)" else "" }) catch date_s);
    }
}

pub fn copyPathToClipboard(b: *Browser, i: usize) void {
    var buf: [4200]u8 = undefined;
    const p = std.mem.printSentinel(&buf, "{s}/{s}", .{ b.dir, b.at(i).name }, 0) catch return;
    c.igSetClipboardText(p.ptr);
}

/// containsCI reports whether `haystack` contains `needle`, case-insensitively.
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(ch)) continue :outer;
        }
        return true;
    }
    return false;
}

/// Spring times spring-loaded folders (Finder's): while files are dragged, resting
/// the pointer on a folder for a moment opens it, so you can drop deeper.
pub const Spring = struct {
    key: u64 = 0,
    since: f64 = 0,
    frame: c_int = -10,

    const delay = 0.8; // seconds of resting on a folder

    /// open reports, for the item just submitted (a folder, identified by `path`),
    /// whether a drag has rested on it long enough to open it. Once per rest.
    pub fn open(self: *Spring, path: []const u8) bool {
        if (c.igGetDragDropPayload() == null) return false; // only while dragging something
        // IsItemHovered is false while the drag source holds the mouse: test the rect.
        if (!c.igIsMouseHoveringRect(c.igGetItemRectMin(), c.igGetItemRectMax(), true)) return false;
        const key = std.hash.Wyhash.hash(0, path);
        const f = c.igGetFrameCount();
        const now = c.igGetTime();
        if (self.key != key or self.frame + 1 < f) {
            self.key = key;
            self.since = now;
        }
        self.frame = f;
        if (now - self.since < delay) {
            // A ring filling up on the folder says it's about to open.
            const mn = c.igGetItemRectMin();
            const mx = c.igGetItemRectMax();
            const r = (mx.y - mn.y) * 0.3;
            const ctr = cimgui.vec2(mx.x - r * 1.6, (mn.y + mx.y) * 0.5);
            const t: f32 = @floatCast((now - self.since) / delay);
            const dl = c.igGetForegroundDrawList_ViewportPtr(null);
            c.ImDrawList_PathArcTo(dl, ctr, r, -std.math.pi / 2.0, -std.math.pi / 2.0 + t * std.math.tau, 24);
            c.ImDrawList_PathStroke(dl, c.igGetColorU32_Col(c.ImGuiCol_CheckMark, 1), 2, 0); // thickness, flags
            return false;
        }
        self.since = std.math.inf(f64);
        return true;
    }
};

/// infoSection is a Get Info section heading: a thin rule, then the title after a
/// disclosure chevron, Finder's way (no filled bar). Returns whether it's open.
fn infoSection(title: [:0]const u8, default_open: bool) bool {
    c.igSpacing();
    c.igSeparator();
    const clear = cimgui.vec4(0, 0, 0, 0);
    c.igPushStyleColor_Vec4(c.ImGuiCol_Header, clear);
    c.igPushStyleColor_Vec4(c.ImGuiCol_HeaderHovered, clear);
    c.igPushStyleColor_Vec4(c.ImGuiCol_HeaderActive, clear);
    const open = c.igCollapsingHeader_TreeNodeFlags(title.ptr, if (default_open) c.ImGuiTreeNodeFlags_DefaultOpen else 0);
    c.igPopStyleColor(3);
    return open;
}

/// Pop is Finder's open animation: as a folder opens, its icon grows out of its place
/// and fades away over the folder it opened. The views report where they drew each
/// openable icon (`note`) and open through ViewActions.open, which starts it; the
/// shell draws it on top of everything (`draw`). The new listing is not held back.
pub const Pop = struct {
    hover: Spot = .{}, // the icon under the mouse (a double-click opens it)
    cursor: Spot = .{}, // the cursor's icon (Enter opens it)
    from: Spot = .{}, // the running pop's icon

    const key: c.ImGuiID = 0x7A46504F; // the one-shot's animation key
    const Spot = struct { idx: usize = std.math.maxInt(usize), frame: c_int = -10, x: f32 = 0, y: f32 = 0, size: f32 = 0 };

    /// note records that item `i`'s icon was drawn size×size at x, y this frame.
    pub fn note(self: *Pop, b: *const Browser, i: usize, hovered: bool, x: f32, y: f32, size: f32) void {
        const s: Spot = .{ .idx = i, .frame = c.igGetFrameCount(), .x = x, .y = y, .size = size };
        if (hovered) self.hover = s;
        if (i == b.sel.cursor) self.cursor = s;
    }

    fn start(self: *Pop, i: usize) void {
        const f = c.igGetFrameCount();
        // Enter is handled before the views draw, so last frame's spot counts too.
        for ([_]Spot{ self.hover, self.cursor }) |s| if (s.idx == i and s.frame >= f - 1) {
            self.from = s;
            anim.play(key, 0, 1, anim.slow, .out_cubic);
            return;
        };
    }

    pub fn draw(self: *const Pop) void {
        const t = anim.playing(key) orelse return;
        const s = self.from;
        // Small list icons grow further, so the pop reads at any icon size.
        const end = @max(s.size * 2.2, c.igGetFontSize() * 4.5);
        const size = s.size + (end - s.size) * t;
        const cx = s.x + s.size * 0.5;
        const cy = s.y + s.size * 0.5;
        const alpha: u8 = @intFromFloat((1 - t) * 230);
        icons.drawFolder(c.igGetForegroundDrawList_ViewportPtr(null), cx - size * 0.5, cy - size * 0.5, size, alpha);
    }
};

/// allImages: something's selected and all of it is pictures (Quick Actions apply).
fn allImages(b: *Browser) bool {
    if (b.sel.count() == 0 or b.virtualView()) return false;
    var i: usize = 0;
    while (i < b.count()) : (i += 1) {
        if (b.sel.isSelected(i) and (b.at(i).isDir() or !core.imagetool.isImage(b.at(i).name))) return false;
    }
    return true;
}
