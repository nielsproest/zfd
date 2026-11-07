//! Browser: the navigation model the UI draws and drives. It owns the current
//! directory, the current listing, and the off-thread Scanner. Navigation is
//! always async — `navigate`/`up`/`open` just kick the Scanner; `update` (called
//! once per frame on the render thread) folds in a finished listing without ever
//! blocking. GUI-free and testable.
//!
//! Heap-pinned: the Scanner's worker thread holds `&self.scanner`, so a Browser
//! must not be moved after `init`. `init` returns a `*Browser` for exactly that
//! reason; free it with `deinit`.

const std = @import("std");
const scan = @import("scan.zig");
const fsops = @import("fsops.zig");
const glob = @import("glob.zig");
const query_mod = @import("query.zig");
const tags = @import("tags.zig");
const procwatch = @import("procwatch.zig");
const filter = @import("filter.zig");
const Scanner = @import("scanner.zig").Scanner;
const DirWatch = @import("dirwatch.zig").DirWatch;
const Selection = @import("selection.zig").Selection;
const Clipboard = @import("clipboard.zig").Clipboard;
const oprunner = @import("oprunner.zig");
const OpRunner = oprunner.OpRunner;
const progress = @import("progress.zig");
const desktop = @import("desktop.zig");
const mimeinfo = @import("mimeinfo.zig");
const trash = @import("trash.zig");
const usage = @import("usage.zig");
const Usage = usage.Usage;
const archive = @import("archive.zig");
const DeepSearch = @import("deepsearch.zig").DeepSearch;
const recent = @import("recent.zig");
const FolderPrefs = @import("folderprefs.zig").FolderPrefs;
const archives_mod = @import("archives.zig");
const details_mod = @import("details.zig");

/// UndoAction records the single most recent undoable operation (Ctrl+Z); undoing it
/// leaves a copy as the redo action (Ctrl+Shift+Z), which does it again. Move/copy
/// are recorded when the op-runner reports what actually landed where (destinations
/// can be unique-renamed, and a cancelled batch only did part of the work).
const UndoAction = union(enum) {
    none,
    rename: struct { dir: []u8, from: []u8, to: []u8 }, // undo: rename from→to (reverse)
    create: struct { path: []u8, dir: bool }, // undo: delete the created entry
    trash: struct { origs: [][]u8 }, // undo: restore each original path from trash
    move: struct { pairs: []OpRunner.Pair }, // undo: move each dst back to its exact src
    copy: struct { pairs: []OpRunner.Pair }, // undo: trash each copy (dst)
};

/// ExternalDrop is files dropped onto the window from another app (owned src paths) plus
/// the drop's window position, held until the view resolves which folder (or the current
/// dir) they landed on.
const ExternalDrop = struct { srcs: [][]u8, x: f32, y: f32 };

/// Parked is a copy/move held back because some of its items already exist at the
/// destination; the view asks Replace / Skip / Keep both, then resolveConflict runs it.
const Parked = struct {
    srcs: [][]u8,
    dst_dir: []u8,
    copy: bool,
    clashes: []Clash, // the colliding items, in source order (owned)
    // The user's answer per source (owned, parallel to srcs) while deciding item by
    // item; non-clashing items stay .keep_both (which for them just means "copy").
    answers: []OpRunner.Conflict,
    step: usize = 0, // index into clashes of the item being asked about
};

/// Clash is one source whose name is already taken at the destination, with what the
/// prompt shows to compare the two.
const Clash = struct {
    src_index: usize,
    incoming: fsops.Brief,
    existing: fsops.Brief,
};

/// ConflictInfo is what the conflict dialog shows (all borrowed from the Browser):
/// the counts, and the item currently being asked about (`step` of `clashes`).
pub const ConflictInfo = struct {
    clashes: usize,
    total: usize,
    step: usize,
    name: []const u8,
    incoming: fsops.Brief,
    existing: fsops.Brief,
    dst_dir: []const u8,
    copy: bool,
};

pub const Browser = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    scanner: Scanner,
    dir: []u8, // current directory, absolute (owned)
    history: std.ArrayList([]u8) = .empty, // visited dirs (owned) for back/forward
    hist_pos: usize = 0, // index into history of the current dir
    listing: ?scan.Listing = null, // current entries (owned), null until first load / on error
    // The folder the entries on screen came from (owned): while another one loads, the
    // list still shows this one's, and they open relative to it.
    shown_dir: []u8 = &.{},
    loading: bool = true,
    err_name: ?[]const u8 = null, // @errorName of the last failed scan (static string)
    sel: Selection = .{}, // selection over the VIEW, reset whenever the view rebuilds
    view: std.ArrayList(usize) = .empty, // indices into listing.entries: hidden-filtered + sorted
    // The listing came with names only: the details (sizes, dates, tags) arrive from
    // this pool, folded in by update (see details.zig).
    details: ?details_mod.Filler = null,
    // A new listing waiting for its details (names only so far) while the old one
    // stays on screen: it's shown once they're all in, or after `stage_ms`, whichever
    // is first, so a quick folder changes in one go instead of blinking through
    // blank columns, plain icons and a re-sort.
    staged: ?scan.Listing = null,
    details_stopping: std.ArrayList(details_mod.Filler) = .empty, // let go, workers finishing
    // How long deinit waits for details workers to stop: at exit they mustn't outlive
    // the allocator; a closed tab's can finish on their own (see letGo).
    details_wait_ms: u64 = 300,
    staged_ns: u64 = 0,
    // When goTo started the load (0 once the next folder is on screen). The folder
    // before stays shown for stage_ms; past that, the next one opens empty and its
    // files appear as they come, so a slow folder is entered at once.
    nav_ns: u64 = 0,
    entered: bool = false, // the folder being opened is on screen, empty, still loading
    view_pending: bool = false, // the folder navigated to hasn't had its view applied yet
    details_buf: std.ArrayList(details_mod.Details) = .empty,
    details_dirty: bool = false, // the view's order or filter waits on details that arrived
    details_sorted_ns: u64 = 0, // when the view was last re-sorted for them
    details_workers: usize = 0, // 0 = details_mod.defaultWorkers()
    wake: ?*const fn () void = null, // nudges an idle UI loop (thread-safe; set by the UI)
    climb_from: ?[]u8 = null, // navigateOrClimb's path (owned) while it may climb
    climbed: bool = false, // it wasn't there: the folder shown is one above it
    has_partials: bool = false, // the listing has .part/.crdownload files (worth watching)
    group_by: scan.GroupBy = .none, // Use Groups: sections in the list and icon views
    group_starts: std.ArrayList(usize) = .empty, // view positions where a section begins
    group_today: i64 = 0, // the local day the sections were made on (for date groups)
    // List view's disclosure triangles: subfolders opened in place, by relative path
    // (owned), parents before children. Their items join the listing named
    // "sub/child", like subfolder search results, so every action works on them.
    expanded: std.ArrayList([]u8) = .empty,
    // Opened folders are read off the render thread, one at a time, on their own
    // scanner (started on first use): the queue of ones still to read, and the one
    // being read (a result for anything else — closed, or a folder left — is dropped).
    exp_scanner: ?Scanner = null,
    exp_queue: std.ArrayList([]u8) = .empty, // relative names (owned), oldest first
    exp_inflight: ?[]u8 = null, // owned
    show_hidden: bool = false, // include dotfiles
    search_ci: bool = true, // case-insensitive quick-search (toggle in Options)
    sort_order: scan.SortOrder = .{}, // name ascending by default
    search: std.ArrayList(u8) = .empty, // quick-search glob; empty = no filter
    active_filter: ?filter.FileFilter = null, // chooser file-type filter (borrowed); files must match
    // The clipboard is a POINTER so a shell can share one across all its tabs (cut in
    // one tab, paste in another). Defaults to this browser's own `own_clipboard`.
    own_clipboard: Clipboard = .{},
    clipboard: *Clipboard = undefined, // set in init; see shareClipboard
    op_seq: u32 = 0, // bumped whenever a file op completes (lets the shell refresh other tabs)
    ops: OpRunner = undefined, // off-thread file-op runner (set in init)
    trash_home: []u8 = &.{}, // XDG home-trash dir (owned), set in init
    home: []u8 = &.{}, // user home (owned), for the Open-with apps scan
    apps: ?[]const desktop.App = null, // lazily-scanned .desktop apps (owned), cached
    undo_action: UndoAction = .none, // most recent undoable op (owned)
    redo_action: UndoAction = .none, // the op last undone, to do again (owned)
    rename_after_reload: ?[]u8 = null, // name to select + rename once the listing reloads (New Folder/File)
    select_after_load: ?[]u8 = null, // name to select + reveal once the first listing lands (`zfd <file>` reveal)
    drop_pending: ?ExternalDrop = null, // files dropped from another app, awaiting position resolution by the view
    drag_paths: ?[][]u8 = null, // absolute paths snapshotted when an internal drag starts (owned)
    parked: ?Parked = null, // a copy/move waiting on the user's answer to a name conflict (owned)
    want_rename: bool = false, // signal the table to enter rename mode on the cursor
    reloading: bool = false, // the pending scan re-reads the SAME dir (keep the selection)
    // Opt-in subfolder search. OFF by default and switched off on every navigation: the
    // normal quick-search only filters what's listed (instant, no I/O), whereas this
    // walks the tree — so it only ever runs while the user has it turned on.
    deep: bool = false,
    // Showing the Recent place: `dir` is "/" and entry names are paths relative to it
    // (see recent.zig), so joins still yield real paths; location() reports the URI.
    in_recent: bool = false,
    // Per-folder views, shared by every tab (owned by the shell); null = one global
    // view (tests, or no config dir).
    prefs: ?*FolderPrefs = null,
    view_mode: @import("folderprefs.zig").Mode = .list, // the layout: the window's, unless a folder insists
    carry_layout: bool = false, // the folder being opened is inside the one before: it keeps its layout
    archives: ?*archives_mod.Registry = null, // opened archives, shared by all tabs (owned by the shell)
    untrashable: ?[]OpRunner.Pair = null, // items Move to Trash couldn't move (owned), awaiting the user
    untrashable_why: []const u8 = "", // @errorName of why (static)
    tag_filter: tags.Mask = 0, // show only items with one of these colour tags (sidebar Tags; 0 = all)
    deep_search: ?*DeepSearch = null,
    deep_shown: usize = 0, // results already folded into the listing
    deep_last_ns: u64 = 0, // when results were last folded in (throttles rebuilds)
    // Folder watch (inotify): external changes to the current dir schedule a reload.
    watch: DirWatch = .{}, // (added off the render thread: a slow share's lookup)
    watch_dirty_ns: u64 = 0, // when the first unhandled change arrived (0 = none)
    watch_last_ns: u64 = 0, // when the latest change arrived
    new_tab_request: ?[]u8 = null, // a folder the view asked to open in a new tab (owned); the shell takes it
    op_err: ?[]const u8 = null, // last file-op error (@errorName), shown in status
    usage: Usage = undefined, // off-thread recursive-size scanner (treemap), set in init
    usage_snapshot: ?usage.Snapshot = null, // latest streamed usage snapshot (owned)
    usage_dir: ?[]u8 = null, // dir the usage snapshot belongs to (owned)
    archive_tool: ?[]u8 = null, // absolute path to bsdtar (owned), null hides the archive menu
    squash_tool: ?[]u8 = null, // unsquashfs, for an AppImage's or snap's contents (owned; found on first use)
    squash_looked: bool = false,
    usage_canceled: bool = false, // treemap scan canceled for the current dir

    /// init opens `start_dir` and kicks off the first (async) load. `trash_home` is
    /// the XDG home-trash directory (e.g. ~/.local/share/Trash), resolved by the
    /// caller from XDG_DATA_HOME.
    pub fn init(alloc: std.mem.Allocator, io: std.Io, start_dir: []const u8, trash_home: []const u8, home: []const u8) !*Browser {
        const self = try alloc.create(Browser);
        errdefer alloc.destroy(self);
        const dir = try alloc.dupe(u8, start_dir);
        errdefer alloc.free(dir);
        const th = try alloc.dupe(u8, trash_home);
        errdefer alloc.free(th);
        const hm = try alloc.dupe(u8, home);
        errdefer alloc.free(hm);
        self.* = .{
            .alloc = alloc,
            .io = io,
            .scanner = Scanner.init(io, alloc),
            .ops = OpRunner.init(io, alloc),
            .usage = Usage.init(io, alloc),
            .dir = dir,
            .trash_home = th,
            .home = hm,
        };
        self.clipboard = &self.own_clipboard;
        try self.scanner.start();
        errdefer self.scanner.deinit();
        try self.ops.start();
        errdefer self.ops.deinit();
        try self.usage.start();
        errdefer self.usage.deinit();
        self.watch = DirWatch.init(io, alloc); // (none: no auto-refresh, F5 still works)
        try self.history.append(alloc, try alloc.dupe(u8, start_dir)); // seed history
        if (recent.isUri(start_dir)) {
            alloc.free(self.dir);
            self.dir = try alloc.dupe(u8, "/");
            self.in_recent = true;
        } else self.watchDir(self.dir);
        try self.requestScan(); // kick off the initial load
        return self;
    }

    /// orphan detaches the scan worker so an in-flight slow read (e.g. an NFS folder
    /// still loading) can't freeze teardown. Call at process exit right before deinit:
    /// pressing Save while a folder loads would otherwise block on the scan worker's
    /// join until the read returns. Safe because the scanner's shared state is heap-
    /// allocated + refcounted; the worker frees it on its own. A following deinit's
    /// scanner.deinit() is then a no-op.
    /// shareClipboard points this browser at a clipboard owned elsewhere (the shell's,
    /// shared by every tab). The caller keeps it alive for the browser's lifetime.
    pub fn shareClipboard(self: *Browser, clip: *Clipboard) void {
        self.clipboard = clip;
    }

    pub fn orphan(self: *Browser) void {
        self.scanner.orphan();
        if (self.exp_scanner) |*es| es.orphan();
    }

    /// letGo frees a browser that closes while the app goes on (a tab): nothing waits
    /// for a slow folder's read or lookups, which finish on their own.
    pub fn letGo(self: *Browser) void {
        self.orphan();
        self.details_wait_ms = 0;
        self.deinit();
    }

    pub fn deinit(self: *Browser) void {
        self.ops.deinit(); // joins the op worker
        self.clearUntrashable();
        self.usage.deinit(); // joins the usage worker
        self.scanner.deinit(); // joins the scan worker; safe to free after
        self.alloc.free(self.shown_dir);
        if (self.usage_snapshot) |s| usage.freeSnapshot(self.alloc, s);
        if (self.usage_dir) |d| self.alloc.free(d);
        // Closing for good: wait (briefly, all of them together) for the details
        // workers to stop, at exit (a tab closing lets them finish on their own).
        if (self.details) |f| {
            f.stop();
            self.details_stopping.append(self.alloc, f) catch f.cancelWait(0);
        }
        self.details = null;
        const t0 = monoNs();
        for (self.details_stopping.items) |f| f.cancelWait(self.details_wait_ms -| (monoNs() - t0) / std.time.ns_per_ms);
        self.details_stopping.deinit(self.alloc);
        if (self.staged) |l| l.deinit(self.alloc);
        self.staged = null;
        self.details_buf.deinit(self.alloc);
        self.clearClimb();
        if (self.listing) |l| l.deinit(self.alloc);
        self.view.deinit(self.alloc);
        self.group_starts.deinit(self.alloc);
        for (self.expanded.items) |x| self.alloc.free(x);
        self.expanded.deinit(self.alloc);
        if (self.exp_scanner) |*es| es.deinit();
        for (self.exp_queue.items) |x| self.alloc.free(x);
        self.exp_queue.deinit(self.alloc);
        if (self.exp_inflight) |x| self.alloc.free(x);
        self.search.deinit(self.alloc);
        self.sel.deinit(self.alloc);
        self.own_clipboard.deinit(self.alloc);
        for (self.history.items) |p| self.alloc.free(p);
        self.history.deinit(self.alloc);
        if (self.apps) |a| desktop.freeApps(self.alloc, a);
        if (self.rename_after_reload) |r| self.alloc.free(r);
        if (self.select_after_load) |s| self.alloc.free(s);
        if (self.new_tab_request) |r| self.alloc.free(r);
        self.clearPendingDrop();
        self.clearParked();
        self.stopDeep();
        self.endDrag();
        self.watch.deinit();
        self.clearUndo();
        self.clearRedo();
        if (self.archive_tool) |t| self.alloc.free(t);
        if (self.squash_tool) |t| self.alloc.free(t);
        self.alloc.free(self.home);
        self.alloc.free(self.trash_home);
        self.alloc.free(self.dir);
        self.alloc.destroy(self);
    }

    /// count is the number of visible (hidden-filtered) rows.
    pub fn count(self: *const Browser) usize {
        return self.view.items.len;
    }

    /// at returns the visible entry at view row `i` (caller ensures i < count()).
    pub fn at(self: *const Browser, i: usize) scan.Entry {
        return self.listing.?.entries[self.view.items[i]];
    }

    /// setSort applies an explicit column/direction (from the table header) and
    /// re-sorts. The selection + cursor stay pinned to the same entries (by name), so
    /// you can keep arrow-keying from what you clicked — like Explorer.
    pub fn setSort(self: *Browser, column: scan.SortColumn, ascending: bool) void {
        self.sort_order.column = column;
        self.sort_order.ascending = ascending; // keep dirs_first
        self.rememberView();
        self.rebuildViewPreserving();
    }

    /// toggleDirsFirst flips whether directories are grouped ahead of files.
    pub fn toggleDirsFirst(self: *Browser) void {
        self.sort_order.dirs_first = !self.sort_order.dirs_first;
        self.rememberView();
        self.rebuildViewPreserving();
    }

    /// currentView is this folder's view settings as shown now.
    pub fn currentView(self: *const Browser) @import("folderprefs.zig").View {
        return .{ .sort = self.sort_order, .show_hidden = self.show_hidden, .mode = self.view_mode, .group = self.group_by };
    }

    /// rememberView records the current view, layout included, as this folder's own
    /// (per-folder prefs).
    fn rememberView(self: *Browser) void {
        const p = self.prefs orelse return;
        var v = self.currentView();
        v.always = true;
        if (p.lookup(self.location())) |own| v.browse = own.browse;
        p.set(self.location(), v);
    }

    /// browsesIn reports whether the folders inside this one open in its layout.
    pub fn browsesIn(self: *const Browser) bool {
        const p = self.prefs orelse return false;
        const v = p.lookup(self.location()) orelse return false;
        return v.always and v.browse;
    }

    /// setBrowsesIn sets whether the folders inside this one open in its layout.
    pub fn setBrowsesIn(self: *Browser, on: bool) void {
        const p = self.prefs orelse return;
        var v = self.currentView();
        v.always = true;
        v.browse = on;
        p.set(self.location(), v);
    }

    /// applyFolderView switches to the view remembered for this folder, else the
    /// default. Call after navigating; it applies when the listing is rebuilt. A
    /// folder without a layout of its own keeps the one on screen when it was opened
    /// from the folder it's in (and always in column view, which is a way of moving
    /// through folders); arriving any other way, it takes the default's.
    pub fn applyFolderView(self: *Browser) void {
        self.view_pending = false; // (applied now: not again when the listing lands)
        const p = self.prefs orelse return;
        const v = p.viewFor(self.location());
        self.sort_order = v.sort;
        self.show_hidden = v.show_hidden;
        self.group_by = v.group;
        if (p.modeFor(self.location())) |m| {
            self.view_mode = m;
        } else if (!self.carry_layout and self.view_mode != .columns) self.view_mode = p.default.mode;
        self.carry_layout = false;
    }

    /// isExpanded reports whether folder `rel` (a name in the listing) is open in place.
    pub fn isExpanded(self: *const Browser, rel: []const u8) bool {
        for (self.expanded.items) |x| if (std.mem.eql(u8, x, rel)) return true;
        return false;
    }

    /// reselect applies a pending selection (setPendingSelect) to the current view.
    pub fn reselect(self: *Browser) void {
        self.applyPendingSelect();
    }

    /// expandBusy reports whether an opened folder is still being read (keep frames
    /// coming so it shows up as soon as it's in).
    pub fn expandBusy(self: *const Browser) bool {
        return self.exp_inflight != null;
    }

    /// canExpand reports whether folders can open in place here (not in subfolder
    /// search results or Recent, whose names are already paths).
    pub fn canExpand(self: *const Browser) bool {
        return self.deep_search == null and !self.in_recent;
    }

    /// depthOf is how deep an opened-in-place item sits (0 = the folder's own items).
    pub fn depthOf(self: *const Browser, e: scan.Entry) usize {
        if (self.expanded.items.len == 0 or self.deep_search != null or self.in_recent) return 0;
        return std.mem.count(u8, e.name, "/");
    }

    /// toggleExpand opens view item `i` (a folder) in place below itself, or closes it
    /// and everything opened inside it. Reads the folder now: one listing, on click.
    pub fn toggleExpand(self: *Browser, i: usize) void {
        if (i >= self.count() or self.deep_search != null or self.in_recent) return;
        const e = self.at(i);
        if (!e.isDir()) return;
        const name = self.alloc.dupe(u8, e.name) catch return;
        defer self.alloc.free(name);
        if (self.isExpanded(name)) {
            var k: usize = 0;
            while (k < self.expanded.items.len) {
                const x = self.expanded.items[k];
                if (std.mem.eql(u8, x, name) or isUnderRel(x, name)) {
                    self.alloc.free(self.expanded.orderedRemove(k));
                } else k += 1;
            }
            self.dropChildren(name);
        } else {
            const owned = self.alloc.dupe(u8, name) catch return;
            self.expanded.append(self.alloc, owned) catch {
                self.alloc.free(owned);
                return;
            };
            self.queueExpand(name); // its items appear once read (pollExpand)
        }
        // The listing changed under the view's indices (and closing freed names), so
        // rebuild from scratch and put the cursor back on the folder.
        self.setPendingSelect(name);
        self.rebuildView();
    }

    fn clearExpanded(self: *Browser) void {
        for (self.expanded.items) |x| self.alloc.free(x);
        self.expanded.clearRetainingCapacity();
        self.clearExpandQueue();
    }

    fn clearExpandQueue(self: *Browser) void {
        for (self.exp_queue.items) |x| self.alloc.free(x);
        self.exp_queue.clearRetainingCapacity();
        if (self.exp_inflight) |x| self.alloc.free(x);
        self.exp_inflight = null; // its result, when it comes, matches nothing
    }

    /// mergeExpanded re-reads every opened subfolder for a fresh listing (in the
    /// background, parents first); one that's gone closes when its read fails.
    fn mergeExpanded(self: *Browser) void {
        self.clearExpandQueue();
        for (self.expanded.items) |x| self.queueExpand(x);
    }

    /// queueExpand asks for folder `rel` to be read in the background.
    fn queueExpand(self: *Browser, rel: []const u8) void {
        const owned = self.alloc.dupe(u8, rel) catch return;
        self.exp_queue.append(self.alloc, owned) catch return self.alloc.free(owned);
        self.startNextExpand();
    }

    fn startNextExpand(self: *Browser) void {
        if (self.exp_inflight != null or self.exp_queue.items.len == 0) return;
        if (self.exp_scanner == null) {
            var sc = Scanner.init(self.io, self.alloc);
            sc.start() catch return;
            self.exp_scanner = sc;
        }
        const rel = self.exp_queue.orderedRemove(0);
        const path = std.fs.path.join(self.alloc, &.{ self.dir, rel }) catch return self.alloc.free(rel);
        defer self.alloc.free(path);
        self.exp_scanner.?.request(path) catch return self.alloc.free(rel);
        self.exp_inflight = rel;
    }

    /// pollExpand takes in a finished read of an opened folder: its items join the
    /// listing (the selection stays put), then the next queued folder starts.
    fn pollExpand(self: *Browser) bool {
        const es = &(self.exp_scanner orelse return false);
        const res = es.poll() orelse return false;
        const rel = self.exp_inflight;
        self.exp_inflight = null;
        defer if (rel) |r| self.alloc.free(r);
        switch (res) {
            .listing => |sub| {
                // Still wanted (not closed, not another folder by now)?
                if (rel == null or !self.isExpanded(rel.?) or self.listing == null or self.deep_search != null) {
                    sub.deinit(self.alloc);
                } else {
                    self.appendChildren(rel.?, sub);
                    self.rebuildViewPreserving();
                }
            },
            .err => if (rel) |r| {
                // Can't be read (gone, no permission): close it.
                for (self.expanded.items, 0..) |x, k| if (std.mem.eql(u8, x, r)) {
                    self.alloc.free(self.expanded.orderedRemove(k));
                    break;
                };
            },
        }
        self.startNextExpand();
        return true;
    }

    /// appendChildren adds folder `rel`'s listing `sub` (consumed) to the listing as
    /// "rel/name".
    fn appendChildren(self: *Browser, rel: []const u8, sub: scan.Listing) void {
        const l = &(self.listing orelse return sub.deinit(self.alloc));
        defer self.alloc.free(sub.entries);
        const grown = self.alloc.realloc(l.entries, l.entries.len + sub.entries.len) catch {
            for (sub.entries) |se| {
                self.alloc.free(se.name);
                if (se.link_target.len > 0) self.alloc.free(se.link_target);
            }
            return;
        };
        var n = l.entries.len;
        for (sub.entries) |se| {
            var ne = se;
            ne.name = self.alloc.print("{s}/{s}", .{ rel, se.name }) catch {
                self.alloc.free(se.name);
                if (se.link_target.len > 0) self.alloc.free(se.link_target);
                continue;
            };
            self.alloc.free(se.name);
            grown[n] = ne;
            n += 1;
        }
        l.entries = self.alloc.realloc(grown, n) catch grown[0..n];
    }

    /// dropChildren removes the items under `rel` from the listing (closing it).
    fn dropChildren(self: *Browser, rel: []const u8) void {
        const l = &(self.listing orelse return);
        var n: usize = 0;
        for (l.entries) |e| {
            if (isUnderRel(e.name, rel)) {
                self.alloc.free(e.name);
                if (e.link_target.len > 0) self.alloc.free(e.link_target);
            } else {
                l.entries[n] = e;
                n += 1;
            }
        }
        l.entries = self.alloc.realloc(l.entries, n) catch l.entries[0..n];
    }

    /// nestExpanded reorders the sorted view so each opened folder's items follow it
    /// (themselves sorted), at any depth.
    fn nestExpanded(self: *Browser, entries: []const scan.Entry) void {
        var kids = std.StringHashMap(std.ArrayList(usize)).init(self.alloc);
        defer {
            var it = kids.valueIterator();
            while (it.next()) |v| v.deinit(self.alloc);
            kids.deinit();
        }
        for (self.view.items) |ei| {
            const name = entries[ei].name;
            const parent = if (std.mem.lastIndexOfScalar(u8, name, '/')) |sl| name[0..sl] else "";
            const gop = kids.getOrPut(parent) catch return;
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            gop.value_ptr.append(self.alloc, ei) catch return;
        }
        var out = std.ArrayList(usize).initCapacity(self.alloc, self.view.items.len) catch return;
        defer out.deinit(self.alloc);
        self.emitNested(entries, &kids, "", &out);
        if (out.items.len != self.view.items.len) return; // an orphan (hidden parent): keep it flat
        @memcpy(self.view.items, out.items);
    }

    fn emitNested(self: *Browser, entries: []const scan.Entry, kids: *std.StringHashMap(std.ArrayList(usize)), parent: []const u8, out: *std.ArrayList(usize)) void {
        const list = kids.get(parent) orelse return;
        for (list.items) |ei| {
            out.appendAssumeCapacity(ei);
            const e = entries[ei];
            if (e.isDir() and self.isExpanded(e.name)) self.emitNested(entries, kids, e.name, out);
        }
    }

    /// setGroupBy splits the view into sections (or none), remembered per folder.
    pub fn setGroupBy(self: *Browser, by: scan.GroupBy) void {
        if (self.group_by == by) return;
        self.group_by = by;
        self.rememberView();
        self.rebuildViewPreserving();
    }

    /// groupLabelAt is the heading of the section starting at view position `pos`.
    pub fn groupLabelAt(self: *const Browser, pos: usize) []const u8 {
        const l = self.listing orelse return "";
        return scan.groupLabel(self.group_by, scan.groupKey(self.group_by, l.entries[self.view.items[pos]], self.group_today));
    }

    /// setViewMode switches this folder between list and grid (remembered per folder).
    pub fn setViewMode(self: *Browser, mode: @import("folderprefs.zig").Mode) void {
        if (self.view_mode == mode) return;
        self.view_mode = mode;
        self.rememberView(); // the folder opens this way from now on
    }

    /// resetFolderView makes this folder follow the default view again.
    pub fn resetFolderView(self: *Browser) void {
        const p = self.prefs orelse return;
        p.reset(self.location());
        self.view_mode = p.default.mode; // and the default layout
        self.applyFolderView();
        self.rebuildViewPreserving();
    }

    /// reloadView re-applies this folder's view (after the defaults changed).
    pub fn reloadView(self: *Browser) void {
        self.applyFolderView();
        self.rebuildViewPreserving();
    }

    /// hasFolderView reports whether this folder has its own remembered view.
    pub fn hasFolderView(self: *const Browser) bool {
        const p = self.prefs orelse return false;
        return p.lookup(self.location()) != null;
    }

    /// toggleSearchCI flips case-insensitive quick-search and refilters.
    pub fn toggleSearchCI(self: *Browser) void {
        self.search_ci = !self.search_ci;
        self.rebuildViewPreserving();
    }

    /// toggleHidden shows/hides dotfiles and rebuilds the view.
    pub fn toggleHidden(self: *Browser) void {
        self.show_hidden = !self.show_hidden;
        self.rememberView();
        self.rebuildViewPreserving();
    }

    /// setSearch sets the quick-search glob (empty clears it) and rebuilds the view.
    pub fn setSearch(self: *Browser, query: []const u8) void {
        self.search.clearRetainingCapacity();
        self.search.appendSlice(self.alloc, query) catch {};
        if (self.deep) return self.restartDeep();
        self.rebuildViewPreserving();
    }

    // --- opt-in subfolder search ------------------------------------------------

    /// setDeep turns "search subfolders" on or off. Off restores the plain listing.
    pub fn setDeep(self: *Browser, on: bool) void {
        if (on == self.deep) return;
        self.deep = on;
        if (on) return self.restartDeep();
        self.stopDeep();
        self.refresh(); // back to the folder's own listing
    }

    /// deepActive reports whether the shown listing is subfolder-search results.
    pub fn deepActive(self: *const Browser) bool {
        return self.deep_search != null;
    }

    pub const DeepStatus = struct { found: usize, dirs: u64, done: bool, capped: bool };

    pub fn deepStatus(self: *Browser) ?DeepStatus {
        const d = self.deep_search orelse return null;
        return .{ .found = d.count(), .dirs = d.dirsSearched(), .done = d.isDone(), .capped = d.wasCapped() };
    }

    /// stopDeepWalk ends the walk early, keeping the results found so far.
    pub fn stopDeepWalk(self: *Browser) void {
        if (self.deep_search) |d| d.stop();
    }

    fn stopDeep(self: *Browser) void {
        if (self.deep_search) |d| d.release();
        self.deep_search = null;
        self.deep_shown = 0;
    }

    /// restartDeep (re)starts the walk for the current query; with no query there's
    /// nothing to search for, so the folder's own listing comes back.
    fn restartDeep(self: *Browser) void {
        const had = self.deep_search != null;
        self.stopDeep();
        if (self.search.items.len == 0) {
            if (had) self.refresh();
            return self.rebuildViewPreserving();
        }
        self.deep_search = DeepSearch.start(self.io, self.alloc, self.dir, self.search.items, self.search_ci, self.show_hidden) catch null;
        self.deep_last_ns = 0;
        // Show the (empty) result set right away rather than the folder's listing
        // filtered by the new query, which would look like the finished answer.
        self.foldDeep(true);
    }

    /// foldDeep swaps the latest results in as the listing — at most ~5×/s while the
    /// walk streams, so a big result set isn't re-sorted every frame.
    fn foldDeep(self: *Browser, force: bool) void {
        const d = self.deep_search orelse return;
        const n = d.count();
        const done = d.isDone();
        const now = monoNs();
        if (!force and n == self.deep_shown and !(done and self.loading)) return;
        if (!force and !done and now -| self.deep_last_ns < 200 * std.time.ns_per_ms) return;
        const l = d.snapshot(self.alloc) catch return;
        self.deep_shown = n;
        self.deep_last_ns = now;
        const old = self.listing;
        var snap = if (old != null) self.snapSelection() else null;
        defer if (snap) |*sn| sn.deinit();
        self.stopDetails(); // the folder's own listing goes
        self.listing = l;
        self.err_name = null;
        self.loading = !done;
        self.rebuildView();
        if (snap) |*sn| self.restoreSelection(sn, false);
        if (old) |o| o.deinit(self.alloc);
    }

    /// setActiveFilter sets the chooser's file-type filter (borrowed; null = show all)
    /// and refilters. The dialog owns the FileFilter for its lifetime.
    pub fn setActiveFilter(self: *Browser, f: ?filter.FileFilter) void {
        self.active_filter = f;
        self.rebuildViewPreserving();
    }

    /// rebuildView refilters (hidden + search) and resorts the listing into `view`,
    /// then resizes the selection to match. Cheap for normal directories; a
    /// huge-folder off-thread pass is a later refinement.
    fn rebuildView(self: *Browser) void {
        self.view.clearRetainingCapacity();
        self.has_partials = false;
        if (self.listing) |l| {
            for (l.entries) |e| if (procwatch.isDownloadName(e.name)) {
                self.has_partials = true;
                break;
            };
            var qbuf: [512]u8 = undefined;
            const q = query_mod.parse(self.search.items, &qbuf);
            for (l.entries, 0..) |e, i| {
                if (!self.show_hidden and isHidden(std.fs.path.basename(e.name))) continue;
                // Subfolder results were matched by the walk (against the NAME, while the
                // entry is shown as a relative path) — re-filtering here would drop them.
                if (self.deep_search == null and !q.isEmpty() and !q.matches(e, self.search_ci)) continue;
                if (self.tag_filter != 0 and e.tags & self.tag_filter == 0) continue;
                // The chooser file-type filter hides non-matching FILES; directories
                // always show so you can still navigate through them.
                if (self.active_filter) |f| {
                    if (!e.isDir() and !f.matches(e.name)) continue;
                }
                self.view.append(self.alloc, i) catch {};
            }
            scan.sortView(self.view.items, l.entries, self.sort_order);
        }
        if (self.listing) |l| if (self.group_by == .none and self.expanded.items.len > 0 and self.search.items.len == 0 and self.deep_search == null)
            self.nestExpanded(l.entries);
        self.group_starts.clearRetainingCapacity();
        if (self.listing) |l| if (self.group_by != .none) {
            self.group_today = @divFloor(scan.localSecs(std.Io.Clock.real.now(self.io).toSeconds()), 86400);
            scan.groupView(self.view.items, l.entries, self.group_by, self.group_today);
            if (self.expanded.items.len > 0 and self.search.items.len == 0 and self.deep_search == null)
                self.nestExpanded(l.entries); // children follow their folder, in its section
            var prev: ?u8 = null;
            for (self.view.items, 0..) |ei, pos| {
                if (std.mem.indexOfScalar(u8, l.entries[ei].name, '/') != null) continue; // a child: its folder's section
                const k = scan.groupKey(self.group_by, l.entries[ei], self.group_today);
                if (prev == null or prev.? != k) self.group_starts.append(self.alloc, pos) catch {};
                prev = k;
            }
        };
        self.sel.reset(self.alloc, self.view.items.len) catch {};
        self.applyPendingRename();
        self.applyPendingSelect();
    }

    /// rebuildViewPreserving re-sorts/re-filters the SAME listing while keeping the
    /// selection and keyboard cursor pinned to the same entries BY NAME — like Explorer,
    /// where changing the sort keeps what you had selected so the arrow keys keep moving
    /// from it. Entries the new filter hides simply fall out of the selection. Only valid
    /// when the listing is unchanged (a sort or filter toggle): the view indices read
    /// below must still point into self.listing. A fresh scan renumbers from scratch, so
    /// it uses the plain rebuildView instead.
    fn rebuildViewPreserving(self: *Browser) void {
        if (self.listing == null) return self.rebuildView();
        // A just-created New Folder/File wants the cursor for inline rename — let that
        // win rather than pinning to the old cursor.
        if (self.rename_after_reload != null) return self.rebuildView();
        var snap = self.snapSelection();
        defer snap.deinit();
        self.rebuildView(); // clears the view + resets the selection
        self.restoreSelection(&snap, true);
    }

    /// SelSnap is the selection by NAME (plus the cursor's entry name), so it survives
    /// a rebuild that renumbers the view. The names borrow from the listing they were
    /// taken from, which must outlive the restore.
    const SelSnap = struct {
        names: std.StringHashMap(void),
        cursor: ?[]const u8,
        fn deinit(sn: *SelSnap) void {
            sn.names.deinit();
        }
    };

    fn snapSelection(self: *Browser) SelSnap {
        var sn = SelSnap{ .names = std.StringHashMap(void).init(self.alloc), .cursor = null };
        const l = self.listing orelse return sn;
        for (self.view.items, 0..) |ent_idx, view_i| {
            if (self.sel.isSelected(view_i)) sn.names.put(l.entries[ent_idx].name, {}) catch {};
        }
        if (self.sel.cursor < self.view.items.len) sn.cursor = l.entries[self.view.items[self.sel.cursor]].name;
        return sn;
    }

    /// restoreSelection re-selects surviving entries by name and puts the cursor back
    /// on its entry. `reveal` scrolls to it (a sort change) — a background reload must
    /// not yank the list away from where the user is looking.
    fn restoreSelection(self: *Browser, sn: *const SelSnap, reveal: bool) void {
        var restored_cursor = false;
        for (self.view.items, 0..) |ent_idx, view_i| {
            const name = self.listing.?.entries[ent_idx].name;
            if (sn.names.contains(name)) self.sel.select(view_i);
            if (sn.cursor) |cn| {
                if (std.mem.eql(u8, cn, name)) {
                    self.sel.cursor = view_i;
                    self.sel.anchor = view_i;
                    restored_cursor = true;
                }
            }
        }
        if (restored_cursor and reveal) self.sel.requestReveal();
    }

    /// applyPendingRename, after a reload, moves the cursor to a just-created entry and
    /// asks the view to reveal it + start a rename.
    fn applyPendingRename(self: *Browser) void {
        const target = self.rename_after_reload orelse return;
        defer {
            self.alloc.free(target);
            self.rename_after_reload = null;
        }
        var idx: usize = 0;
        while (idx < self.count()) : (idx += 1) {
            if (std.mem.eql(u8, self.at(idx).name, target)) {
                self.sel.cursor = idx;
                self.sel.requestReveal();
                self.want_rename = true;
                return;
            }
        }
    }

    /// setPendingSelect asks the browser to select + reveal the entry named `name` once
    /// the (first) listing lands — how `zfd <file>` reveals a file inside its parent
    /// folder ("show in folder"). Owns its own copy.
    pub fn setPendingSelect(self: *Browser, name: []const u8) void {
        if (self.select_after_load) |old| self.alloc.free(old);
        self.select_after_load = self.alloc.dupe(u8, name) catch null;
    }

    /// applyPendingSelect, once a real listing exists, selects + reveals the entry the
    /// reveal request named, then clears the request (one-shot). Left pending while the
    /// folder is still loading or errored (no listing yet).
    fn applyPendingSelect(self: *Browser) void {
        if (self.select_after_load == null) return;
        if (self.listing == null) return; // no listing yet — try again on the next rebuild
        const target = self.select_after_load.?;
        defer {
            self.alloc.free(target);
            self.select_after_load = null;
        }
        var idx: usize = 0;
        while (idx < self.count()) : (idx += 1) {
            if (std.mem.eql(u8, self.at(idx).name, target)) {
                self.sel.click(idx); // select just this row + set cursor/anchor
                self.sel.requestReveal(); // scroll it into view
                return;
            }
        }
    }

    /// requestRename asks the table to enter inline-rename on the cursor — used by the
    /// shared context menu so Rename works from any view (the table does the edit).
    pub fn requestRename(self: *Browser) void {
        self.want_rename = true;
    }

    /// takeWantRename returns whether the table should enter rename mode on the cursor
    /// (a freshly-created New Folder/File), clearing the signal.
    /// requestNewTab asks the shell to open `path` in a new tab (a middle-clicked
    /// folder). The view can't reach the shell; the shell polls takeNewTabRequest.
    pub fn requestNewTab(self: *Browser, path: []const u8) void {
        if (self.new_tab_request) |old| self.alloc.free(old);
        self.new_tab_request = self.alloc.dupe(u8, path) catch null;
    }

    /// takeNewTabRequest hands the pending request to the caller (who frees it).
    pub fn takeNewTabRequest(self: *Browser) ?[]u8 {
        const r = self.new_tab_request;
        self.new_tab_request = null;
        return r;
    }

    pub fn takeWantRename(self: *Browser) bool {
        const r = self.want_rename;
        self.want_rename = false;
        return r;
    }

    /// goTo switches to `path` (absolute) and starts an async scan — the raw
    /// navigation, without touching history (used by back/forward).
    fn goTo(self: *Browser, path: []const u8) !void {
        const virtual = recent.isUri(path);
        const dup = try self.alloc.dupe(u8, if (virtual) "/" else path); // copy before freeing self.dir (path may alias it)
        // Opening a folder inside this one: it keeps the layout on screen.
        self.carry_layout = !virtual and !self.in_recent and dup.len > self.dir.len and std.mem.startsWith(u8, dup, self.dir) and
            (dup[self.dir.len] == '/' or std.mem.endsWith(u8, self.dir, "/"));
        self.alloc.free(self.dir);
        self.dir = dup;
        self.loading = true;
        self.err_name = null;
        // A quick-search glob belongs to the folder you ran it in — carrying it into the
        // next directory silently hides files there. Clear it on every real navigation
        // (back/forward/up/open all route through goTo); refresh() reloads the same dir
        // without goTo, so it keeps the filter. The toolbar re-syncs its box from this on
        // the next frame (syncSearch), so the visible text clears too.
        self.search.clearRetainingCapacity();
        self.reloading = false;
        self.deep = false; // subfolder search never follows you into another folder
        self.tag_filter = 0; // a tag filter belongs to the folder it was set in
        self.clearExpanded(); // opened subfolders belong to the folder too
        self.stopDeep();
        self.in_recent = virtual;
        self.dropStaged(); // a folder we're leaving before it showed
        // The folder we're leaving stops looking up its details, so they don't hold
        // up reading the next one (on a share, they'd compete for it).
        self.stopDetails();
        self.nav_ns = monoNs();
        self.entered = false;
        // Its view (layout, sort, …) is applied when its listing goes on screen, so
        // the folder still showing never flashes in the next one's layout.
        self.view_pending = true;
        self.watchDir(if (virtual) "" else dup); // Recent: nothing to watch; F5 reloads
        try self.requestScan();
    }

    /// requestScan asks the scanner for the current location: the folder, or the
    /// Recent list (read from the XDG data home, the trash home's parent).
    fn requestScan(self: *Browser) !void {
        if (!self.in_recent) return self.scanner.request(self.dir);
        const req = try recent.scanRequest(self.alloc, std.fs.path.dirname(self.trash_home) orelse self.home);
        defer self.alloc.free(req);
        try self.scanner.request(req);
    }

    /// location is where the browser is, for the path bar, tab title, history and
    /// saved settings: the folder, or recent.uri while showing the Recent place.
    pub fn location(self: *const Browser) []const u8 {
        return if (self.in_recent) recent.uri else self.dir;
    }

    /// virtualView reports whether the listing isn't a real folder (Recent), so
    /// creating or pasting items "here" makes no sense.
    pub fn virtualView(self: *const Browser) bool {
        return self.in_recent;
    }

    /// navigateOrClimb opens `path`, and if it isn't there any more (a favourite whose
    /// folder was moved or deleted), the nearest folder above it that is: each failed
    /// read climbs one level, through the same async loading as any folder. takeClimbed
    /// then says so.
    pub fn navigateOrClimb(self: *Browser, path: []const u8) !void {
        try self.navigate(path);
        self.climb_from = self.alloc.dupe(u8, path) catch null;
    }

    /// takeClimbed is the path navigateOrClimb was asked for, once it had to settle for
    /// a folder above it (owned), else null.
    pub fn takeClimbed(self: *Browser) ?[]u8 {
        if (!self.climbed or self.loading) return null;
        const p = self.climb_from;
        self.climb_from = null;
        self.climbed = false;
        return p;
    }

    fn clearClimb(self: *Browser) void {
        if (self.climb_from) |p| self.alloc.free(p);
        self.climb_from = null;
        self.climbed = false;
    }

    /// navigate is a user-initiated move: it records history (dropping any forward
    /// entries) and then navigates. A typed "." or ".." is resolved first ("folder/."
    /// is the folder itself). Going to the folder you're in starts it afresh (a search
    /// is cleared) without a second history entry for it.
    pub fn navigate(self: *Browser, raw: []const u8) !void {
        const clean: ?[]u8 = if (!recent.isUri(raw) and std.fs.path.isAbsolute(raw)) try std.fs.path.resolveAllocPosix(self.alloc, &.{raw}) else null;
        defer if (clean) |c| self.alloc.free(c);
        const path = clean orelse raw;
        self.clearClimb();
        if (std.mem.eql(u8, path, self.history.items[self.hist_pos])) return self.goTo(path);
        for (self.history.items[self.hist_pos + 1 ..]) |p| self.alloc.free(p);
        self.history.shrinkRetainingCapacity(self.hist_pos + 1);
        try self.history.append(self.alloc, try self.alloc.dupe(u8, path));
        self.hist_pos = self.history.items.len - 1;
        try self.goTo(path);
    }

    pub fn back(self: *Browser) void {
        self.clearClimb();
        if (self.hist_pos == 0) return;
        self.hist_pos -= 1;
        self.goTo(self.history.items[self.hist_pos]) catch {};
    }
    pub fn forward(self: *Browser) void {
        self.clearClimb();
        if (self.hist_pos + 1 >= self.history.items.len) return;
        self.hist_pos += 1;
        self.goTo(self.history.items[self.hist_pos]) catch {};
    }
    /// backOrUp goes back in history if there's anywhere to go back to, otherwise it
    /// climbs to the parent directory — so a Back input (the mouse thumb button) always
    /// does something instead of dead-ending the moment you open a folder with no
    /// history yet. The parent is prepended (cursor stays at 0) so repeated Back keeps
    /// walking up toward the root, while Forward re-descends into where you came from.
    pub fn backOrUp(self: *Browser) void {
        self.clearClimb();
        if (self.hist_pos > 0) {
            self.hist_pos -= 1;
            self.goTo(self.history.items[self.hist_pos]) catch {};
            return;
        }
        // Up from an archive's top level leaves it, back to the archive's own folder.
        if (self.archives) |reg| if (reg.atRoot(self.dir) != null) {
            _ = self.leaveArchive();
            return;
        };
        const parent = std.fs.path.dirname(self.dir) orelse return; // at root → no-op
        const dup = self.alloc.dupe(u8, parent) catch return;
        self.history.insert(self.alloc, 0, dup) catch {
            self.alloc.free(dup);
            return;
        };
        // hist_pos stays 0: `parent` is now the current entry and the folder we left is
        // history[1], reachable via Forward. `parent` still aliases self.dir here, but
        // goTo dupes its argument before freeing self.dir, so this is safe.
        self.goTo(parent) catch {};
    }
    pub fn canBack(self: *const Browser) bool {
        return self.hist_pos > 0;
    }
    pub fn canForward(self: *const Browser) bool {
        return self.hist_pos + 1 < self.history.items.len;
    }
    /// canBackOrUp reports whether backOrUp would move: there's history to go back to, or
    /// the current dir has a parent to climb to. False only at the filesystem root with
    /// no history — the one spot Back genuinely can't do anything.
    pub fn canBackOrUp(self: *const Browser) bool {
        return self.hist_pos > 0 or std.fs.path.dirname(self.dir) != null;
    }

    /// up navigates to the parent directory; a no-op at the filesystem root. Retained as
    /// a primitive (used in tests); the UI's Back folds this in via backOrUp instead.
    pub fn up(self: *Browser) !void {
        const parent = std.fs.path.dirname(self.dir) orelse return;
        try self.navigate(parent);
    }

    /// open enters a directory, or opens a file in its default app (xdg-open).
    pub fn open(self: *Browser, entry: scan.Entry) !void {
        // While a folder loads, the list still shows the previous one's entries, so an
        // entry opens relative to the folder it came from (joining it to the loading
        // folder made /a/b/c + "c" → /a/b/c/c). Nothing waits: a newer open replaces
        // the one in flight, and Back then goes to where you were, not to it.
        const base = if (self.shown_dir.len > 0) self.shown_dir else self.dir;
        const child = try std.fs.path.join(self.alloc, &.{ base, entry.name });
        defer self.alloc.free(child);
        if (entry.isDir()) {
            const in_flight = self.loading and !std.mem.eql(u8, base, self.dir);
            if (in_flight and self.hist_pos > 0 and std.mem.eql(u8, self.history.items[self.hist_pos - 1], base))
                self.hist_pos -= 1; // navigate drops the unfinished one from the history
            try self.navigate(child);
        } else if (self.canBrowseArchive(entry.name)) {
            self.browseArchive(child);
        } else {
            fsops.openWith(self.io, self.alloc, child);
        }
    }

    /// canBrowseArchive reports whether opening `name` browses into it (an archive,
    /// with bsdtar available) rather than handing it to another app.
    pub fn canBrowseArchive(self: *const Browser, name: []const u8) bool {
        return self.archives != null and self.archive_tool != null and archive.isArchive(name);
    }

    /// browseArchive shows the inside of archive `path`: its extracted copy, extracting
    /// it in the background first if this is the first time (the folder fills in as
    /// the extraction runs; the progress window shows for a big one).
    pub fn browseArchive(self: *Browser, path: []const u8) void {
        self.browseWith(path, self.archive_tool orelse return);
    }

    /// canShowContents reports whether Show Contents can open `name`: a package or
    /// document that's an archive inside, or an AppImage/snap (with unsquashfs).
    pub fn canShowContents(self: *Browser, name: []const u8) bool {
        if (self.archives == null) return false;
        if (archive.isPackage(name)) return self.archive_tool != null;
        if (archive.isSquashImage(name)) return self.squashTool() != null;
        return false;
    }

    /// showContents browses the inside of a package or an AppImage, as an archive.
    pub fn showContents(self: *Browser, path: []const u8) void {
        const name = std.fs.path.basename(path);
        const tool = if (archive.isSquashImage(name)) self.squashTool() else self.archive_tool;
        self.browseWith(path, tool orelse return);
    }

    fn squashTool(self: *Browser) ?[]const u8 {
        if (!self.squash_looked) {
            self.squash_looked = true;
            self.squash_tool = fsops.findOnPath(self.io, self.alloc, "unsquashfs");
        }
        return self.squash_tool;
    }

    fn browseWith(self: *Browser, path: []const u8, tool: []const u8) void {
        const reg = self.archives orelse return;
        if (reg.rootOf(path)) |root| {
            self.navigate(root) catch {};
            return;
        }
        const root = reg.add(path) catch |e| {
            self.op_err = @errorName(e);
            return;
        };
        const t = self.alloc.dupe(u8, tool) catch return;
        const list = self.alloc.alloc([]u8, 1) catch {
            self.alloc.free(t);
            return;
        };
        list[0] = self.alloc.dupe(u8, path) catch {
            self.alloc.free(t);
            self.alloc.free(list);
            return;
        };
        const dst = self.alloc.dupe(u8, root) catch {
            self.alloc.free(t);
            freePaths(self.alloc, list);
            return;
        };
        self.ops.submit(.{ .extract = .{ .tool = t, .archives = list, .dst_dir = dst, .own_folder = false } }) catch {};
        self.navigate(root) catch {};
    }

    /// insideArchive returns the archive the current folder belongs to, if any.
    pub fn insideArchive(self: *const Browser) ?archives_mod.Opened {
        const reg = self.archives orelse return null;
        return reg.containing(self.dir);
    }

    /// leaveArchive goes to the folder holding the archive being browsed, with the
    /// archive selected (Up at an archive's top level, or the banner's Close).
    pub fn leaveArchive(self: *Browser) bool {
        const o = self.insideArchive() orelse return false;
        const parent = std.fs.path.dirname(o.src) orelse return false;
        self.navigate(parent) catch return false;
        self.setPendingSelect(std.fs.path.basename(o.src));
        return true;
    }

    /// openNamed opens a child by name: navigate if a directory, else xdg-open.
    pub fn openNamed(self: *Browser, name: []const u8, is_dir: bool) void {
        if (self.loading) return; // mid-navigation: the view is stale (see open())
        const child = std.fs.path.join(self.alloc, &.{ self.dir, name }) catch return;
        defer self.alloc.free(child);
        if (is_dir) {
            self.navigate(child) catch {};
        } else {
            fsops.openWith(self.io, self.alloc, child);
        }
    }

    /// openTerminalHere launches a terminal in the current directory.
    pub fn openTerminalHere(self: *Browser) void {
        fsops.openTerminal(self.io, self.alloc, self.dir);
    }

    /// openTerminalIn launches a terminal in `dir` (a folder row's own path).
    pub fn openTerminalIn(self: *Browser, dir: []const u8) void {
        fsops.openTerminal(self.io, self.alloc, dir);
    }

    /// newFolder / newFile create a uniquely-named empty entry and refresh.
    pub fn newFolder(self: *Browser) void {
        self.createEntry("New Folder", true);
    }
    pub fn newFile(self: *Browser) void {
        self.createEntry("New File", false);
    }
    /// createEntry makes a new folder or file here, off the render thread (a slow
    /// share mustn't freeze the window). When it's made, its name is offered to edit
    /// (see onCreated).
    fn createEntry(self: *Browser, base: []const u8, is_dir: bool) void {
        if (self.in_recent) return; // Recent isn't a folder you can create things in
        self.submitCreate(self.dir, base, is_dir, true, &.{});
    }

    /// submitCreate queues a create job (taking `srcs`, which are moved into a new folder).
    fn submitCreate(self: *Browser, dir: []const u8, name: []const u8, is_dir: bool, unique: bool, srcs: [][]u8) void {
        self.op_err = null;
        const d = self.alloc.dupe(u8, dir) catch return freePaths(self.alloc, srcs);
        const n = self.alloc.dupe(u8, name) catch {
            self.alloc.free(d);
            return freePaths(self.alloc, srcs);
        };
        self.ops.submit(.{ .create = .{ .dir = d, .name = n, .is_dir = is_dir, .unique = unique, .srcs = srcs } }) catch {};
    }

    /// onCreated takes what a create or link job made: a new folder or file becomes
    /// undoable and its name is offered to edit; a single new link gets selected.
    fn onCreated(self: *Browser, comp: OpRunner.Completion) void {
        if (comp.created.len == 0) return;
        const name = std.fs.path.basename(comp.created);
        if (comp.created_link) {
            if (comp.links == 1) self.setPendingSelect(name);
            return;
        }
        // A plain new folder or file: undo removes it. (With items moved in, the
        // move's own undo takes them back out.)
        if (comp.kind == .none) self.recordCreate(comp.created, comp.created_dir);
        if (self.rename_after_reload) |old| self.alloc.free(old);
        self.rename_after_reload = self.alloc.dupe(u8, name) catch null;
    }

    /// duplicateSelection copies the selected items next to themselves ("x (copy).txt"),
    /// as Finder's Duplicate. Undoable like any copy.
    pub fn duplicateSelection(self: *Browser) void {
        if (self.in_recent or self.virtualView() or self.sel.count() == 0) return;
        self.op_err = null;
        const srcs = self.selectedPaths() catch return;
        const dst = self.alloc.dupe(u8, self.dir) catch return freePaths(self.alloc, srcs);
        self.ops.submit(.{ .copy = .{ .srcs = srcs, .dst_dir = dst } }) catch return;
    }

    /// newFolderWithSelection makes a new folder here and moves the selected items into
    /// it (Finder's New Folder with Selection), then offers the folder's name to edit.
    pub fn newFolderWithSelection(self: *Browser) void {
        if (self.in_recent or self.virtualView() or self.sel.count() == 0) return;
        const srcs = self.selectedPaths() catch return;
        self.submitCreate(self.dir, "New Folder With Items", true, true, srcs);
    }

    /// selectAll selects every visible row.
    pub fn selectAll(self: *Browser) void {
        self.sel.selectAll();
    }

    /// deleteSelection removes the selection: to the trash, or permanently.
    pub fn deleteSelection(self: *Browser, permanent: bool) void {
        if (!permanent) {
            self.trashSelection();
            return;
        }
        self.op_err = null;
        const paths = self.selectedPaths() catch return;
        if (paths.len == 0) {
            freePaths(self.alloc, paths);
            return;
        }
        self.ops.submit(.{ .delete = .{ .paths = paths } }) catch return;
    }

    /// openCursor opens the keyboard-focused row (Enter). No-op if it isn't a
    /// directory or the view is empty.
    pub fn openCursor(self: *Browser) !void {
        if (self.sel.cursor >= self.count()) return;
        try self.open(self.at(self.sel.cursor));
    }

    /// refresh re-scans the current directory (after a file operation changed it).
    pub fn refresh(self: *Browser) void {
        self.loading = true;
        self.reloading = true;
        self.watch_dirty_ns = 0; // this scan covers whatever the watch had seen
        self.requestScan() catch {};
        if (self.usage_dir) |d| { // invalidate treemap sizes so they recompute
            self.alloc.free(d);
            self.usage_dir = null;
        }
    }

    /// ensureUsage requests a recursive-size scan of the current dir unless one is
    /// already current. The treemap view calls this each frame while active.
    pub fn ensureUsage(self: *Browser) void {
        if (self.usage_dir) |ud| {
            if (std.mem.eql(u8, ud, self.dir)) return;
            self.alloc.free(ud);
            self.usage_dir = null;
        }
        const ud = self.alloc.dupe(u8, self.dir) catch return;
        self.usage_dir = ud;
        self.usage_canceled = false; // new dir → fresh scan
        if (self.usage_snapshot) |s| {
            usage.freeSnapshot(self.alloc, s);
            self.usage_snapshot = null;
        }
        self.usage.request(self.dir) catch {};
    }

    /// cancelUsage stops the treemap scan for the current dir (the Cancel button).
    /// Partial sizes already computed stay on screen.
    pub fn cancelUsage(self: *Browser) void {
        self.usage.requestCancel();
        self.usage_canceled = true;
    }

    /// usageCanceled reports whether the current dir's treemap scan was canceled.
    pub fn usageCanceled(self: *const Browser) bool {
        return self.usage_canceled;
    }

    /// resetUsage forces a fresh treemap scan of the current dir — used when the user
    /// re-opens the treemap after canceling it (ensureUsage otherwise sees the dir as
    /// already scanned and won't restart).
    pub fn resetUsage(self: *Browser) void {
        if (self.usage_dir) |d| {
            self.alloc.free(d);
            self.usage_dir = null;
        }
        self.usage_canceled = false; // ensureUsage will re-request next frame
    }

    /// usageScanning reports whether the treemap should show its progress bar (a scan
    /// is in flight and not canceled).
    pub fn usageScanning(self: *const Browser) bool {
        if (self.usage_canceled) return false;
        if (self.usage_snapshot) |s| return s.total > 0 and s.done < s.total;
        return false;
    }

    /// usageItems is the treemap's current (possibly partial) child sizes.
    pub fn usageItems(self: *const Browser) []const usage.Item {
        if (self.usage_snapshot) |s| return s.items;
        return &.{};
    }

    /// usageProgress is {done, total} for the treemap progress bar (total 0 = not
    /// started; done == total = complete).
    pub fn usageProgress(self: *const Browser) struct { done: usize, total: usize } {
        if (self.usage_snapshot) |s| return .{ .done = s.done, .total = s.total };
        return .{ .done = 0, .total = 0 };
    }

    /// selectionTagged reports how many of the selected items carry colour `bit`, and
    /// how many are selected — so the menu can show a tag as on (all), off, or mixed.
    pub fn selectionTagged(self: *Browser, bit: tags.Mask) struct { with: usize, of: usize } {
        var with: usize = 0;
        var of: usize = 0;
        var i: usize = 0;
        while (i < self.count()) : (i += 1) {
            if (!self.sel.isSelected(i)) continue;
            of += 1;
            if (self.at(i).tags & bit != 0) with += 1;
        }
        return .{ .with = with, .of = of };
    }

    /// toggleTag puts colour `bit` on every selected item, or takes it off if they all
    /// have it already (Finder's tag menu). Runs on the op runner; the reload shows it.
    pub fn toggleTag(self: *Browser, bit: tags.Mask) void {
        const st = self.selectionTagged(bit);
        if (st.of == 0) return;
        const paths = self.selectedPaths() catch return;
        self.op_err = null;
        self.ops.submit(.{ .set_tags = .{ .paths = paths, .bit = bit, .add = st.with < st.of } }) catch {};
    }

    /// setTagFilter shows only items tagged with one of `mask` (0 = everything).
    pub fn setTagFilter(self: *Browser, mask: tags.Mask) void {
        self.tag_filter = mask;
        self.rebuildViewPreserving();
    }

    /// opLanes is how many op lanes exist; each may be running one operation. Index
    /// opProgress/cancelOp with 0..opLanes().
    pub fn opLanes(self: *Browser) usize {
        return self.ops.laneCount();
    }

    /// opProgress reads lane `lane`'s file-operation progress (copy/move/trash/delete)
    /// for the shell's progress windows; the current filename is copied into `buf`.
    pub fn opProgress(self: *Browser, lane: usize, buf: []u8) progress.Snapshot {
        return self.ops.progressSnapshot(lane, buf);
    }

    /// cancelOp asks lane `lane`'s operation to stop at the next safe point.
    pub fn cancelOp(self: *Browser, lane: usize) void {
        self.ops.requestCancel(lane);
    }

    /// appList returns the installed .desktop apps for the "Open with" menu, scanning
    /// (and caching) on first use. Empty if the scan finds nothing.
    pub fn appList(self: *Browser) []const desktop.App {
        if (self.apps == null) self.apps = desktop.listApps(self.io, self.alloc, self.home);
        return self.apps.?;
    }

    /// cursorMime is the MIME type of the cursor's entry ("" if unknown) — the
    /// Open-with picker recommends the apps that declare it.
    pub fn cursorMime(self: *Browser) []const u8 {
        if (self.sel.cursor >= self.count()) return "";
        return mimeinfo.mimeType(self.io, self.alloc, self.home, self.at(self.sel.cursor).name);
    }

    /// opensWith is the default app's display name for a file (the "Opens with"
    /// column), or "" if none resolves. Backed by the shared MIME database.
    pub fn opensWith(self: *Browser, name: []const u8) []const u8 {
        return mimeinfo.opensWith(self.io, self.alloc, self.home, name);
    }

    /// typeLabel is the friendly Type-column label: "Folder"/"Link" for those kinds,
    /// else a MIME-derived name ("PNG image"), falling back to the extension category.
    pub fn typeLabel(self: *Browser, e: scan.Entry, out: []u8) []const u8 {
        if (e.isDir()) return "Folder";
        if (e.kind == .symlink) return "Link";
        const t = mimeinfo.typeName(self.io, self.alloc, self.home, e.name, out);
        if (t.len > 0) return t;
        const generic = scan.typeName(e);
        // "File" says nothing; the extension at least tells what it is.
        if (std.mem.eql(u8, generic, "File")) {
            const x = scan.extLabel(e.name, out);
            if (x.len > 0) return x;
        }
        return generic;
    }

    /// setDefaultApp makes app `index` the default for the cursor file's MIME type,
    /// via `xdg-mime default` (no GLib; matches Go's shell-out approach).
    pub fn setDefaultApp(self: *Browser, index: usize) void {
        const apps = self.appList();
        if (index >= apps.len or self.sel.cursor >= self.count()) return;
        const mime = mimeinfo.mimeType(self.io, self.alloc, self.home, self.at(self.sel.cursor).name);
        if (mime.len == 0) return;
        fsops.launch(self.io, self.alloc, &.{ "xdg-mime", "default", apps[index].id, mime }, null);
    }

    /// openWithApp launches app `index` (from appList) on the cursor's entry.
    pub fn openWithApp(self: *Browser, index: usize) void {
        const apps = self.appList();
        if (index >= apps.len or self.sel.cursor >= self.count()) return;
        const e = self.at(self.sel.cursor);
        const path = std.fs.path.join(self.alloc, &.{ self.dir, e.name }) catch return;
        defer self.alloc.free(path);
        desktop.launch(self.io, self.alloc, apps[index].exec, path);
    }

    // --- undo (single level) -------------------------------------------------

    fn clearUndo(self: *Browser) void {
        self.freeAction(&self.undo_action);
    }

    fn clearRedo(self: *Browser) void {
        self.freeAction(&self.redo_action);
    }

    fn freeAction(self: *Browser, a: *UndoAction) void {
        switch (a.*) {
            .none => {},
            .rename => |r| {
                self.alloc.free(r.dir);
                self.alloc.free(r.from);
                self.alloc.free(r.to);
            },
            .create => |cr| self.alloc.free(cr.path),
            .trash => |t| {
                for (t.origs) |p| self.alloc.free(p);
                self.alloc.free(t.origs);
            },
            .move => |m| oprunner.freePairs(self.alloc, m.pairs),
            .copy => |cp| oprunner.freePairs(self.alloc, cp.pairs),
        }
        a.* = .none;
    }

    /// dupAction deep-copies `a` (null when out of memory).
    fn dupAction(self: *Browser, a: UndoAction) ?UndoAction {
        const al = self.alloc;
        return switch (a) {
            .none => .none,
            .rename => |r| .{ .rename = .{
                .dir = al.dupe(u8, r.dir) catch return null,
                .from = al.dupe(u8, r.from) catch return null,
                .to = al.dupe(u8, r.to) catch return null,
            } },
            .create => |cr| .{ .create = .{ .path = al.dupe(u8, cr.path) catch return null, .dir = cr.dir } },
            .trash => |t| blk: {
                const origs = al.alloc([]u8, t.origs.len) catch return null;
                for (t.origs, origs) |p, *o| o.* = al.dupe(u8, p) catch return null;
                break :blk .{ .trash = .{ .origs = origs } };
            },
            .move => |m| .{ .move = .{ .pairs = self.dupPairs(m.pairs) orelse return null } },
            .copy => |cp| .{ .copy = .{ .pairs = self.dupPairs(cp.pairs) orelse return null } },
        };
    }

    fn dupPairs(self: *Browser, pairs: []const OpRunner.Pair) ?[]OpRunner.Pair {
        const out = self.alloc.alloc(OpRunner.Pair, pairs.len) catch return null;
        for (pairs, out) |p, *o| o.* = .{
            .src = self.alloc.dupe(u8, p.src) catch return null,
            .dst = self.alloc.dupe(u8, p.dst) catch return null,
        };
        return out;
    }

    /// canRedo reports whether Ctrl+Shift+Z has something to do again.
    pub fn canRedo(self: *const Browser) bool {
        return self.redo_action != .none;
    }

    /// redo does again what the last undo reversed; that becomes undoable once more.
    pub fn redo(self: *Browser) void {
        const a = self.redo_action;
        self.redo_action = .none;
        switch (a) {
            .none => return,
            .rename => |r| {
                // Undo renamed `to` back to `from`: rename it to `to` again.
                self.recordRenameIn(r.dir, r.to, r.from);
                self.ops.submit(.{ .rename = .{ .dir = r.dir, .old_name = r.to, .new_name = r.from } }) catch {};
                return; // the job owns the strings now
            },
            .create => |cr| {
                // Made again by name, off the render thread; onCreated records it.
                self.submitCreate(std.fs.path.dirname(cr.path) orelse "/", std.fs.path.basename(cr.path), cr.dir, false, &.{});
            },
            .trash => |t| self.trashPaths(t.origs),
            .move => |m| {
                // Undo moved each dst back to src; move them on again (restore moves a
                // pair's dst to its src, so the pairs go in swapped).
                if (self.dupPairs(m.pairs)) |onward| {
                    for (onward) |*p| std.mem.swap([]u8, &p.src, &p.dst);
                    self.ops.submit(.{ .restore = .{ .pairs = onward } }) catch {};
                }
                self.clearUndo();
                self.undo_action = .{ .move = .{ .pairs = m.pairs } };
                return; // the undo slot owns the pairs now
            },
            .copy => |cp| if (cp.pairs.len > 0) {
                // Copy the originals again into the folder the copies were in; the job
                // reports what it made, which becomes the undo.
                if (self.dupPairs(cp.pairs)) |pairs| {
                    // Keep the sources, drop the old copies' names.
                    const srcs = self.alloc.alloc([]u8, pairs.len) catch return oprunner.freePairs(self.alloc, pairs);
                    for (pairs, srcs) |p, *s| {
                        s.* = p.src;
                        self.alloc.free(p.dst);
                    }
                    self.alloc.free(pairs);
                    if (self.alloc.dupe(u8, std.fs.path.dirname(cp.pairs[0].dst) orelse "/")) |dst| {
                        self.ops.submit(.{ .copy = .{ .srcs = srcs, .dst_dir = dst } }) catch {};
                    } else |_| freePaths(self.alloc, srcs);
                }
            },
        }
        var done = a;
        self.freeAction(&done);
    }

    /// canUndo reports whether Ctrl+Z has something to reverse.
    pub fn canUndo(self: *const Browser) bool {
        return self.undo_action != .none;
    }

    /// undo reverses the last recorded operation (rename/create/trash/move/copy).
    pub fn undo(self: *Browser) void {
        // What's undone can be done again.
        const again = self.dupAction(self.undo_action);
        defer if (again) |r| {
            self.clearRedo();
            self.redo_action = r;
        };
        switch (self.undo_action) {
            .none => return,
            .rename => |r| {
                const dir = self.alloc.dupe(u8, r.dir) catch return;
                const from = self.alloc.dupe(u8, r.from) catch {
                    self.alloc.free(dir);
                    return;
                };
                const to = self.alloc.dupe(u8, r.to) catch {
                    self.alloc.free(dir);
                    self.alloc.free(from);
                    return;
                };
                self.ops.submit(.{ .rename = .{ .dir = dir, .old_name = from, .new_name = to } }) catch {};
            },
            .create => |cr| {
                const p = self.alloc.dupe(u8, cr.path) catch return;
                const paths = self.alloc.alloc([]u8, 1) catch {
                    self.alloc.free(p);
                    return;
                };
                paths[0] = p;
                self.ops.submit(.{ .delete = .{ .paths = paths } }) catch {};
            },
            .trash => |t| {
                // Back out of the trash, off the render thread (the job reloads after).
                if (dupPaths(self.alloc, t.origs)) |origs| {
                    if (self.alloc.dupe(u8, self.trash_home)) |th| {
                        self.ops.submit(.{ .untrash = .{ .trash_home = th, .origs = origs } }) catch {};
                    } else |_| freePaths(self.alloc, origs);
                } else |_| {}
            },
            .move => |m| {
                // Hand the pairs to a restore job (it moves dst → src). The job owns
                // them now, so detach them from the undo slot before clearUndo frees.
                const pairs = m.pairs;
                self.undo_action = .none;
                self.ops.submit(.{ .restore = .{ .pairs = pairs } }) catch {};
            },
            .copy => |cp| {
                // Undoing a copy removes the copies — via the trash, not a permanent
                // delete, so a mistaken Ctrl+Z is itself recoverable.
                const th = self.alloc.dupe(u8, self.trash_home) catch return;
                const paths = self.alloc.alloc([]u8, cp.pairs.len) catch {
                    self.alloc.free(th);
                    return;
                };
                for (cp.pairs, 0..) |pr, i| {
                    paths[i] = pr.dst;
                    self.alloc.free(pr.src);
                }
                self.alloc.free(cp.pairs);
                self.undo_action = .none;
                self.ops.submit(.{ .trash = .{ .trash_home = th, .paths = paths } }) catch {};
            },
        }
        // No refresh here: rename/delete/restore/trash-a-copy run on the op worker and
        // reload the folder when they finish. Rescanning NOW would race the worker —
        // readdir during a rename can list both names. (The inline trash restore above
        // refreshes itself.)
        self.clearUndo();
    }

    fn recordRenameIn(self: *Browser, in_dir: []const u8, old_name: []const u8, new_name: []const u8) void {
        self.clearUndo();
        self.clearRedo();
        const dir = self.alloc.dupe(u8, in_dir) catch return;
        const from = self.alloc.dupe(u8, new_name) catch {
            self.alloc.free(dir);
            return;
        };
        const to = self.alloc.dupe(u8, old_name) catch {
            self.alloc.free(dir);
            self.alloc.free(from);
            return;
        };
        self.undo_action = .{ .rename = .{ .dir = dir, .from = from, .to = to } };
    }

    fn recordCreate(self: *Browser, path: []const u8, is_dir: bool) void {
        self.clearUndo();
        self.clearRedo();
        const p = self.alloc.dupe(u8, path) catch return;
        self.undo_action = .{ .create = .{ .path = p, .dir = is_dir } };
    }

    /// recordTransfer takes a finished job's report: an undoable copy/move becomes the
    /// new undo action (taking ownership of the pairs); anything else is freed.
    fn recordTransfer(self: *Browser, comp: OpRunner.Completion) void {
        switch (comp.kind) {
            .none => comp.deinit(self.alloc),
            .move, .copy => {
                self.clearUndo();
                self.clearRedo();
                // (no pairs: nothing to reverse — all skipped, or merged)
                self.undo_action = if (comp.pairs.len == 0) .none else if (comp.kind == .move) .{ .move = .{ .pairs = comp.pairs } } else .{ .copy = .{ .pairs = comp.pairs } };
                if (comp.pairs.len == 0) comp.deinit(self.alloc);
            },
            .untrashable => {
                self.clearUntrashable();
                self.untrashable = comp.pairs;
                self.untrashable_why = comp.err_name orelse "";
            },
        }
    }

    /// Untrashable describes items a Move to Trash couldn't move, for the "delete them
    /// permanently?" question (Finder/Explorer ask the same).
    pub const Untrashable = struct { count: usize, first: []const u8, why: []const u8 };

    pub fn untrashablePending(self: *const Browser) ?Untrashable {
        const u = self.untrashable orelse return null;
        if (u.len == 0) return null;
        return .{ .count = u.len, .first = std.fs.path.basename(u[0].src), .why = self.untrashable_why };
    }

    /// deleteUntrashable deletes those items permanently (the user said yes).
    pub fn deleteUntrashable(self: *Browser) void {
        const u = self.untrashable orelse return;
        self.untrashable = null;
        defer oprunner.freePairs(self.alloc, u);
        var list = std.ArrayList([]u8).empty;
        for (u) |pr| {
            const d = self.alloc.dupe(u8, pr.src) catch continue;
            list.append(self.alloc, d) catch self.alloc.free(d);
        }
        const paths = list.toOwnedSlice(self.alloc) catch return;
        self.op_err = null;
        self.ops.submit(.{ .delete = .{ .paths = paths } }) catch {};
    }

    /// clearUntrashable drops the question (No / Cancel).
    pub fn clearUntrashable(self: *Browser) void {
        if (self.untrashable) |u| oprunner.freePairs(self.alloc, u);
        self.untrashable = null;
    }

    fn recordTrash(self: *Browser, paths: []const []const u8) void {
        self.clearUndo();
        self.clearRedo();
        var origs = std.ArrayList([]u8).empty;
        for (paths) |p| {
            const dup = self.alloc.dupe(u8, p) catch continue;
            origs.append(self.alloc, dup) catch self.alloc.free(dup);
        }
        self.undo_action = .{ .trash = .{ .origs = origs.toOwnedSlice(self.alloc) catch &.{} } };
    }

    /// isCut reports whether view row `i` is on the clipboard for a MOVE (Ctrl+X) —
    /// the table draws those faded, like cut text in an editor. Called for every visible
    /// row each frame, so it compares path COMPONENTS (basename first, which usually
    /// mismatches and short-circuits) instead of formatting a full path per row.
    pub fn isCut(self: *Browser, i: usize) bool {
        if (!self.clipboard.isCut() or i >= self.count()) return false;
        const name = self.at(i).name;
        for (self.clipboard.list()) |p| {
            if (std.mem.eql(u8, std.fs.path.basename(p), name) and
                std.mem.eql(u8, std.fs.path.dirname(p) orelse "", self.dir)) return true;
        }
        return false;
    }

    /// selectionSize sums the (shallow) sizes of the selected entries — for the
    /// status bar's "N selected (X MB)" like Explorer. Directories count as 0.
    pub fn selectionSize(self: *Browser) u64 {
        var total: u64 = 0;
        var i: usize = 0;
        const cnt = self.count();
        while (i < cnt) : (i += 1) {
            if (self.sel.isSelected(i)) total += self.at(i).size;
        }
        return total;
    }

    /// opsBusy reports whether a file operation is running (drives the idle throttle).
    pub fn opsBusy(self: *Browser) bool {
        return self.ops.busy();
    }

    /// cancelAllOps stops this browser's operations: the queued ones never start.
    pub fn cancelAllOps(self: *Browser) void {
        self.ops.cancelAll();
    }

    /// usageSizeOf is the recursive size for a child by name (0 until computed) — so
    /// the treemap can size the SAME view entries the table shows (shared model).
    pub fn usageSizeOf(self: *const Browser, name: []const u8) u64 {
        if (self.usage_snapshot) |s| {
            for (s.items) |it| {
                if (std.mem.eql(u8, it.name, name)) return it.size;
            }
        }
        return 0;
    }

    // --- clipboard + file operations (all off-thread via the op-runner) --------

    /// copySelection / cutSelection stash the selected paths for a later paste.
    pub fn copySelection(self: *Browser) void {
        self.setClipboard(.copy);
    }
    pub fn cutSelection(self: *Browser) void {
        self.setClipboard(.cut);
    }

    fn setClipboard(self: *Browser, mode: @import("clipboard.zig").Mode) void {
        const paths = self.selectedPaths() catch return; // already-owned absolute paths
        self.clipboard.setOwned(self.alloc, paths, mode) catch {}; // moves them in (frees on error)
    }

    /// paste copies (or moves, if the clipboard was cut) its paths into the current
    /// directory, off-thread. A cut clears the clipboard once queued.
    pub fn paste(self: *Browser) void {
        if (self.in_recent) return; // "here" would be "/": Recent isn't a real folder
        self.pasteInto(self.dir);
    }

    /// pasteIntoDir pastes into view row `i` when it's a real subdirectory (the
    /// right-click-a-folder → Paste case), else into the current directory. Guards
    /// against the "." / ".." pseudo-entries so you can't paste into the parent link.
    pub fn pasteIntoDir(self: *Browser, i: usize) void {
        if (self.clipboard.isEmpty()) return;
        if (i >= self.count()) return self.paste();
        const e = self.at(i);
        if (!e.isDir() or std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, ".."))
            return self.paste();
        const dst = std.fs.path.join(self.alloc, &.{ self.dir, e.name }) catch return;
        defer self.alloc.free(dst);
        self.pasteInto(dst);
    }

    /// pasteInto is the shared engine: copy (or move, if cut) the clipboard paths into
    /// `dst_dir` (borrowed — duped here for the off-thread job). A cut clears the
    /// clipboard once queued.
    pub fn pasteInto(self: *Browser, dst_dir: []const u8) void {
        if (self.clipboard.isEmpty()) return;
        self.op_err = null;
        const srcs = dupPaths(self.alloc, self.clipboard.list()) catch return;
        const cut = self.clipboard.isCut();
        self.submitTransfer(srcs, dst_dir, !cut);
        if (cut) self.clipboard.clear(self.alloc);
    }

    /// renameMany renames items of the current folder in one job: olds[i] → news[i]
    /// (plain names). One Ctrl+Z puts every name back.
    pub fn renameMany(self: *Browser, olds: []const []const u8, news: []const []const u8) void {
        var list = std.ArrayList(OpRunner.Pair).empty;
        for (olds, news) |o, n| {
            if (std.mem.eql(u8, o, n)) continue;
            const src = std.fs.path.join(self.alloc, &.{ self.dir, o }) catch continue;
            const dst = std.fs.path.join(self.alloc, &.{ self.dir, n }) catch {
                self.alloc.free(src);
                continue;
            };
            list.append(self.alloc, .{ .src = src, .dst = dst }) catch {
                self.alloc.free(src);
                self.alloc.free(dst);
            };
        }
        const pairs = list.toOwnedSlice(self.alloc) catch {
            for (list.items) |pr| {
                self.alloc.free(pr.src);
                self.alloc.free(pr.dst);
            }
            list.deinit(self.alloc);
            return;
        };
        if (pairs.len == 0) return;
        self.op_err = null;
        self.ops.submit(.{ .rename_many = .{ .pairs = pairs } }) catch {};
    }

    /// linkSelection makes a symlink to each selected item, here in the current folder
    /// ("name (link)"), then selects the new link (for one) so it can be renamed or cut.
    pub fn linkSelection(self: *Browser) void {
        const paths = self.selectedPaths() catch return;
        self.op_err = null;
        const d = self.alloc.dupe(u8, self.dir) catch return freePaths(self.alloc, paths);
        self.ops.submit(.{ .link = .{ .dir = d, .targets = paths } }) catch {};
    }

    /// trashSelection moves the selected paths to the home trash, off-thread.
    pub fn trashSelection(self: *Browser) void {
        const paths = self.selectedPaths() catch return;
        defer freePaths(self.alloc, paths);
        self.trashPaths(paths);
    }

    /// trashPaths moves the given absolute paths to the XDG home trash (off-thread),
    /// recording them for undo. Takes borrowed paths — the drag snapshot outlives the
    /// drop, so it can't hand ownership to the job.
    pub fn trashPaths(self: *Browser, paths: []const []const u8) void {
        if (paths.len == 0) return;
        self.op_err = null;
        var owned = std.ArrayList([]u8).empty;
        errdefer {
            for (owned.items) |p| self.alloc.free(p);
            owned.deinit(self.alloc);
        }
        for (paths) |p| {
            const dup = self.alloc.dupe(u8, p) catch continue;
            owned.append(self.alloc, dup) catch {
                self.alloc.free(dup);
                continue;
            };
        }
        if (owned.items.len == 0) {
            owned.deinit(self.alloc);
            return;
        }
        const list = owned.toOwnedSlice(self.alloc) catch return;
        const th = self.alloc.dupe(u8, self.trash_home) catch {
            freePaths(self.alloc, list);
            return;
        };
        self.recordTrash(list); // record originals before ownership passes to the job
        self.ops.submit(.{ .trash = .{ .trash_home = th, .paths = list } }) catch return;
    }

    /// importExternal copies a path dropped onto the window from another app into
    /// the current directory (off-thread). External sources are always copied.
    pub fn importExternal(self: *Browser, src: []const u8) void {
        self.op_err = null;
        const srcs = self.alloc.alloc([]u8, 1) catch return;
        srcs[0] = self.alloc.dupe(u8, src) catch {
            self.alloc.free(srcs);
            return;
        };
        const dst = self.alloc.dupe(u8, self.dir) catch {
            freePaths(self.alloc, srcs);
            return;
        };
        self.ops.submit(.{ .copy = .{ .srcs = srcs, .dst_dir = dst } }) catch return;
    }

    /// queueExternalDrop records files dropped from another app (owned) plus the drop's
    /// window position, so the view can resolve WHERE they landed on the next frame —
    /// onto a folder row (import into it) or anywhere else (import into the current dir).
    /// A second drop before the first resolves supersedes it.
    pub fn queueExternalDrop(self: *Browser, srcs: [][]u8, x: f32, y: f32) void {
        self.clearPendingDrop();
        self.drop_pending = .{ .srcs = srcs, .x = x, .y = y };
    }

    /// pendingDropPos returns the queued drop's window position, if any — the view uses
    /// it to hit-test folder rows.
    pub fn pendingDropPos(self: *const Browser) ?[2]f32 {
        const d = self.drop_pending orelse return null;
        return .{ d.x, d.y };
    }

    /// commitExternalDrop copies the queued drop's files into dst_dir (off-thread) and
    /// clears the pending state. Called by the view once it has resolved the target.
    /// External sources are always COPIED — we can't know whether the other app still
    /// needs them, and GLFW doesn't surface the XDND action.
    ///
    /// Drops that would recurse are filtered out: another ZFD window (or any file
    /// manager) can hand us a folder and a target inside that same folder, and copying
    /// a directory into its own descendant never terminates.
    pub fn commitExternalDrop(self: *Browser, dst_dir: []const u8) void {
        const d = self.drop_pending orelse return;
        self.drop_pending = null;
        defer freePaths(self.alloc, d.srcs);
        if (self.in_recent and std.mem.eql(u8, dst_dir, self.dir)) return; // dropped on Recent itself
        if (d.srcs.len == 0) return;

        var list = std.ArrayList([]u8).empty;
        errdefer {
            for (list.items) |p| self.alloc.free(p);
            list.deinit(self.alloc);
        }
        for (d.srcs) |src| {
            if (isSelfOrDescendant(dst_dir, src)) continue; // into itself → would recurse
            const dup = self.alloc.dupe(u8, src) catch continue;
            list.append(self.alloc, dup) catch {
                self.alloc.free(dup);
                continue;
            };
        }
        if (list.items.len == 0) {
            list.deinit(self.alloc);
            return;
        }
        const srcs = list.toOwnedSlice(self.alloc) catch return;
        self.op_err = null;
        self.submitTransfer(srcs, dst_dir, true);
    }

    fn clearPendingDrop(self: *Browser) void {
        if (self.drop_pending) |d| freePaths(self.alloc, d.srcs);
        self.drop_pending = null;
    }

    // --- internal drag session -------------------------------------------------
    // A drag carries a SNAPSHOT of the dragged paths, taken when the drag starts, not
    // the live selection: the view's row indices are only meaningful for one listing,
    // and a background rescan (inotify-less refresh, a finished file op, a sort change)
    // can re-index the view mid-drag — which used to move whatever rows happened to
    // land on those indices at drop time. Paths are stable; indices are not.

    /// beginDrag snapshots the current selection's absolute paths as the dragged set.
    /// Idempotent: re-calling while a drag is live keeps the original snapshot, so the
    /// per-frame BeginDragDropSource call doesn't re-read a mutated selection.
    pub fn beginDrag(self: *Browser) void {
        if (self.drag_paths != null) return;
        self.drag_paths = self.selectedPaths() catch null;
    }

    /// dragPaths returns the live drag's snapshotted paths (empty when no drag).
    pub fn dragPaths(self: *const Browser) []const []u8 {
        return self.drag_paths orelse &.{};
    }

    /// endDrag frees the snapshot. Called when the drag is delivered or abandoned.
    pub fn endDrag(self: *Browser) void {
        if (self.drag_paths) |p| freePaths(self.alloc, p);
        self.drag_paths = null;
    }

    /// dropDraggedInto is the drop handler: move (or copy, when `copy`) the dragged
    /// snapshot into dst_dir. Runs on the DESTINATION browser, so a drop onto another
    /// tab is just this call on that tab with the source tab's snapshot.
    /// submitTransfer queues a copy/move of `srcs` (owned; consumed) into dst_dir. If
    /// any item's name is already taken there, the transfer is parked instead and the
    /// view asks what to do (see conflictInfo / resolveConflict). Copying an item into
    /// its own folder is never a conflict — that is always "make a copy".
    pub fn submitTransfer(self: *Browser, srcs: [][]u8, dst_dir: []const u8, copy: bool) void {
        var clashes = std.ArrayList(Clash).empty;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        for (srcs, 0..) |src, i| {
            if (std.mem.eql(u8, std.fs.path.dirname(src) orelse "", dst_dir)) continue;
            const base = std.fs.path.basename(src);
            const target = std.mem.print(&buf, "{s}/{s}", .{ if (std.mem.eql(u8, dst_dir, "/")) "" else dst_dir, base }) catch continue;
            const existing = fsops.brief(target) orelse {
                if (!fsops.pathExists(self.io, target)) continue; // e.g. a dangling link still clashes
                clashes.append(self.alloc, .{ .src_index = i, .incoming = fsops.brief(src) orelse .{}, .existing = .{} }) catch {};
                continue;
            };
            clashes.append(self.alloc, .{ .src_index = i, .incoming = fsops.brief(src) orelse .{}, .existing = existing }) catch {};
        }
        if (clashes.items.len == 0) {
            clashes.deinit(self.alloc);
            return self.submitResolved(srcs, dst_dir, copy, .keep_both, &.{});
        }

        self.clearParked(); // a newer request supersedes an unanswered one
        const dst = self.alloc.dupe(u8, dst_dir) catch {
            clashes.deinit(self.alloc);
            return freePaths(self.alloc, srcs);
        };
        const answers = self.alloc.alloc(OpRunner.Conflict, srcs.len) catch {
            self.alloc.free(dst);
            clashes.deinit(self.alloc);
            return freePaths(self.alloc, srcs);
        };
        @memset(answers, .keep_both);
        const owned = clashes.toOwnedSlice(self.alloc) catch {
            self.alloc.free(answers);
            self.alloc.free(dst);
            clashes.deinit(self.alloc);
            return freePaths(self.alloc, srcs);
        };
        self.parked = .{ .srcs = srcs, .dst_dir = dst, .copy = copy, .clashes = owned, .answers = answers };
    }

    /// submitResolved queues the transfer. `per_item` (owned, parallel to srcs, or
    /// empty) carries item-by-item answers; otherwise `policy` applies to all.
    fn submitResolved(self: *Browser, srcs: [][]u8, dst_dir: []const u8, copy: bool, policy: OpRunner.Conflict, per_item: []OpRunner.Conflict) void {
        const dst = self.alloc.dupe(u8, dst_dir) catch {
            if (per_item.len > 0) self.alloc.free(per_item);
            return freePaths(self.alloc, srcs);
        };
        var replaces = policy == .replace or policy == .replace_older or policy == .merge;
        for (per_item) |p| replaces = replaces or p == .replace or p == .replace_older or p == .merge;
        const th: []u8 = if (replaces) (self.alloc.dupe(u8, self.trash_home) catch &.{}) else &.{};
        const batch: OpRunner.Batch = .{ .srcs = srcs, .dst_dir = dst, .conflict = policy, .per_item = per_item, .trash_home = th };
        const job: OpRunner.Job = if (copy) .{ .copy = batch } else .{ .move = batch };
        self.ops.submit(job) catch return; // submit frees the job on failure
    }

    /// conflictInfo describes the parked transfer and the item being asked about, or
    /// null when nothing is waiting.
    pub fn conflictInfo(self: *const Browser) ?ConflictInfo {
        const p = self.parked orelse return null;
        const cl = p.clashes[p.step];
        return .{
            .clashes = p.clashes.len,
            .total = p.srcs.len,
            .step = p.step,
            .name = std.fs.path.basename(p.srcs[cl.src_index]),
            .incoming = cl.incoming,
            .existing = cl.existing,
            .dst_dir = p.dst_dir,
            .copy = p.copy,
        };
    }

    /// resolveConflict answers every item not yet decided with `choice` and runs the
    /// parked transfer, or drops it (null = Cancel).
    pub fn resolveConflict(self: *Browser, choice: ?OpRunner.Conflict) void {
        const p = self.parked orelse return;
        const policy = choice orelse return self.clearParked();
        if (p.step == 0) {
            // Nothing decided item by item: one policy for the whole batch.
            self.parked = null;
            self.op_err = null;
            self.submitResolved(p.srcs, p.dst_dir, p.copy, policy, &.{}); // dupes dst_dir
            self.alloc.free(p.answers);
            self.alloc.free(p.dst_dir);
            self.alloc.free(p.clashes);
            return;
        }
        for (p.clashes[p.step..]) |cl| p.answers[cl.src_index] = policy;
        self.finishParked();
    }

    /// decideOne answers just the item being asked about and moves to the next clash;
    /// after the last one the transfer runs with every answer.
    pub fn decideOne(self: *Browser, choice: OpRunner.Conflict) void {
        if (self.parked == null) return;
        const pk = &self.parked.?;
        pk.answers[pk.clashes[pk.step].src_index] = choice;
        pk.step += 1;
        if (pk.step < pk.clashes.len) return;
        self.finishParked();
    }

    /// finishParked submits the parked transfer with its per-item answers.
    fn finishParked(self: *Browser) void {
        const p = self.parked orelse return;
        self.parked = null;
        self.op_err = null;
        self.submitResolved(p.srcs, p.dst_dir, p.copy, .keep_both, p.answers); // dupes dst_dir
        self.alloc.free(p.dst_dir);
        self.alloc.free(p.clashes);
    }

    /// freeParkedMeta drops the parked transfer's bookkeeping (not srcs/answers, which
    /// the caller hands on) and clears it.
    fn freeParkedMeta(self: *Browser) void {
        const p = self.parked orelse return;
        self.alloc.free(p.dst_dir);
        self.alloc.free(p.clashes);
        self.parked = null;
    }

    fn clearParked(self: *Browser) void {
        const p = self.parked orelse return;
        freePaths(self.alloc, p.srcs);
        self.alloc.free(p.answers);
        self.freeParkedMeta();
    }

    pub fn dropDraggedInto(self: *Browser, srcs: []const []const u8, dst_dir: []const u8, copy: bool) void {
        self.op_err = null;

        var list = std.ArrayList([]u8).empty;
        errdefer {
            for (list.items) |p| self.alloc.free(p);
            list.deinit(self.alloc);
        }
        for (srcs) |src| {
            if (std.mem.eql(u8, std.fs.path.dirname(src) orelse "", dst_dir)) continue; // already there
            if (isSelfOrDescendant(dst_dir, src)) continue; // into itself → skip
            const dup = self.alloc.dupe(u8, src) catch continue;
            list.append(self.alloc, dup) catch {
                self.alloc.free(dup);
                continue;
            };
        }
        if (list.items.len == 0) {
            list.deinit(self.alloc);
            return;
        }
        const owned = list.toOwnedSlice(self.alloc) catch return;
        self.submitTransfer(owned, dst_dir, copy);
    }

    /// dropSelectionInto moves (or copies, when `copy`) the current selection into
    /// dst_dir. Kept for callers that act on the live selection (menus, tests); the
    /// drag path goes through dropDraggedInto with the drag snapshot.
    pub fn dropSelectionInto(self: *Browser, dst_dir: []const u8, copy: bool) void {
        const all = self.selectedPaths() catch return;
        defer freePaths(self.alloc, all);
        self.dropDraggedInto(all, dst_dir, copy);
    }

    /// renameCursor renames the keyboard-focused row to new_name, off-thread.
    pub fn renameCursor(self: *Browser, new_name: []const u8) void {
        if (self.sel.cursor >= self.count() or new_name.len == 0) return;
        const old = self.at(self.sel.cursor).name;
        if (std.mem.eql(u8, new_name, old)) return; // unchanged → no-op (e.g. committing on click-away)
        self.op_err = null;
        // A subfolder-search result is shown as "sub/x.txt": rename it where it lives.
        var dbuf: [std.fs.max_path_bytes]u8 = undefined;
        const sub = std.fs.path.dirname(old);
        const in_dir = if (sub) |sd| (std.mem.print(&dbuf, "{s}/{s}", .{ self.dir, sd }) catch return) else self.dir;
        const leaf = std.fs.path.basename(old);
        if (std.mem.eql(u8, new_name, leaf)) return;
        const dir = self.alloc.dupe(u8, in_dir) catch return;
        const on = self.alloc.dupe(u8, leaf) catch {
            self.alloc.free(dir);
            return;
        };
        const nn = self.alloc.dupe(u8, new_name) catch {
            self.alloc.free(dir);
            self.alloc.free(on);
            return;
        };
        self.recordRenameIn(in_dir, leaf, new_name); // undo: rename new_name → leaf, in its own folder
        self.ops.submit(.{ .rename = .{ .dir = dir, .old_name = on, .new_name = nn } }) catch return;
    }

    /// selectedPaths returns owned absolute paths of the selected rows. Caller (or
    /// the op-runner) takes ownership; free with the same allocator.
    pub fn selectedPaths(self: *Browser) ![][]u8 {
        var list = std.ArrayList([]u8).empty;
        errdefer {
            for (list.items) |p| self.alloc.free(p);
            list.deinit(self.alloc);
        }
        var i: usize = 0;
        while (i < self.count()) : (i += 1) {
            if (self.sel.isSelected(i)) {
                const p = try std.fs.path.join(self.alloc, &.{ self.dir, self.at(i).name });
                try list.append(self.alloc, p);
            }
        }
        return list.toOwnedSlice(self.alloc);
    }

    /// hasArchiveTool reports whether bsdtar was found — gates the archive menu.
    pub fn hasArchiveTool(self: *const Browser) bool {
        return self.archive_tool != null;
    }

    /// selectionAllArchives is true when at least one row is selected and EVERY selected
    /// row is an archive file — the condition for showing the Extract items.
    pub fn selectionAllArchives(self: *Browser) bool {
        var any = false;
        var i: usize = 0;
        while (i < self.count()) : (i += 1) {
            if (!self.sel.isSelected(i)) continue;
            const e = self.at(i);
            if (e.isDir() or !archive.isArchive(e.name)) return false;
            any = true;
        }
        return any;
    }

    /// compressBaseName writes the default archive name (no extension) into `buf` and
    /// returns the slice: a single file's stem / a single dir's name, else the current
    /// directory's name (WinRAR's convention for a multi-selection). Truncates to buf.
    pub fn compressBaseName(self: *Browser, buf: []u8) []const u8 {
        if (self.sel.count() == 1) {
            var i: usize = 0;
            while (i < self.count()) : (i += 1) {
                if (!self.sel.isSelected(i)) continue;
                const e = self.at(i);
                const base = if (e.isDir()) e.name else archive.fileStem(e.name);
                return copyInto(buf, base);
            }
        }
        const dn = std.fs.path.basename(self.dir);
        return copyInto(buf, if (dn.len == 0) "archive" else dn);
    }

    /// extractSelection queues a bsdtar extraction of the selected archives. own_folder:
    /// each archive into its own new subdir (Extract to <name>/ / each to own folder);
    /// else all into the current directory (Extract Here). Non-archive rows are skipped.
    pub fn extractSelection(self: *Browser, own_folder: bool) void {
        const tool_src = self.archive_tool orelse return;
        const a = self.alloc;
        var archives = std.ArrayList([]u8).empty;
        var committed = false;
        defer if (!committed) {
            for (archives.items) |p| a.free(p);
            archives.deinit(a);
        };
        var i: usize = 0;
        while (i < self.count()) : (i += 1) {
            if (!self.sel.isSelected(i)) continue;
            const e = self.at(i);
            if (e.isDir() or !archive.isArchive(e.name)) continue;
            const p = std.fs.path.join(a, &.{ self.dir, e.name }) catch return;
            archives.append(a, p) catch {
                a.free(p);
                return;
            };
        }
        if (archives.items.len == 0) return;
        const dst = a.dupe(u8, self.dir) catch return;
        const tool = a.dupe(u8, tool_src) catch {
            a.free(dst);
            return;
        };
        const list = archives.toOwnedSlice(a) catch {
            a.free(dst);
            a.free(tool);
            return;
        };
        // list now owns the path strings (archives is empty); submit takes the job and
        // frees it itself on failure, so there's nothing left to clean up either way.
        self.ops.submit(.{ .extract = .{ .tool = tool, .archives = list, .dst_dir = dst, .own_folder = own_folder } }) catch {};
        committed = true;
    }

    /// compressSelection queues a bsdtar archive of the selected items into the current
    /// directory, named compressBaseName + `ext` (e.g. ".zip"), uniquified. bsdtar's `-a`
    /// picks the format/compression from the extension. Sources are stored by basename.
    pub fn compressSelection(self: *Browser, ext: []const u8) void {
        const tool_src = self.archive_tool orelse return;
        const a = self.alloc;
        var srcs = std.ArrayList([]u8).empty;
        var committed = false;
        defer if (!committed) {
            for (srcs.items) |p| a.free(p);
            srcs.deinit(a);
        };
        var i: usize = 0;
        while (i < self.count()) : (i += 1) {
            if (!self.sel.isSelected(i)) continue;
            const nm = a.dupe(u8, self.at(i).name) catch return;
            srcs.append(a, nm) catch {
                a.free(nm);
                return;
            };
        }
        if (srcs.items.len == 0) return;

        var nb: [512]u8 = undefined;
        const base = self.compressBaseName(&nb);
        var fb: [640]u8 = undefined;
        const fname = std.mem.print(&fb, "{s}{s}", .{ base, ext }) catch return;
        // (The job takes the next free name when this one's taken, off the render thread.)
        const archive_path = std.fs.path.join(a, &.{ self.dir, fname }) catch return;
        const src_dir = a.dupe(u8, self.dir) catch {
            a.free(archive_path);
            return;
        };
        const tool = a.dupe(u8, tool_src) catch {
            a.free(archive_path);
            a.free(src_dir);
            return;
        };
        const list = srcs.toOwnedSlice(a) catch {
            a.free(archive_path);
            a.free(src_dir);
            a.free(tool);
            return;
        };
        self.ops.submit(.{ .compress = .{ .tool = tool, .archive_path = archive_path, .src_dir = src_dir, .srcs = list } }) catch {};
        committed = true;
    }

    // --- folder watch ---------------------------------------------------------------

    /// watchDir points the inotify watch at `dir` (dropping the previous one). Only
    /// changes to the folder's own entries matter: create/delete/rename, a file
    /// finishing being written, metadata. IN_MODIFY is left out on purpose — a file
    /// being written fires it thousands of times, and CLOSE_WRITE reports the end.
    fn watchDir(self: *Browser, dir: []const u8) void {
        self.watch_dirty_ns = 0;
        self.watch.watch(dir);
    }

    /// Changes are batched: the reload happens once things have been quiet for this
    /// long (an unzip or a big copy by another program would otherwise re-scan the
    /// folder for every file), but never later than watch_max_wait after the first.
    const watch_quiet_ns: u64 = 300 * std.time.ns_per_ms;
    const watch_max_wait_ns: u64 = 2 * std.time.ns_per_s;

    /// pollWatch drains pending inotify events and reloads the folder when they have
    /// settled. Non-blocking; called from update().
    fn pollWatch(self: *Browser) void {
        const got = self.watch.changed();
        const now = monoNs();
        if (got) {
            if (self.watch_dirty_ns == 0) self.watch_dirty_ns = now;
            self.watch_last_ns = now;
        }
        if (self.watch_dirty_ns == 0) return;
        if (self.loading or self.ops.busy()) return; // a reload is coming anyway
        const quiet = now -| self.watch_last_ns >= watch_quiet_ns;
        const overdue = now -| self.watch_dirty_ns >= watch_max_wait_ns;
        if (quiet or overdue) self.refresh(); // clears watch_dirty_ns
    }

    /// watchPending reports whether a folder change is waiting to be reloaded (keeps
    /// the render loop ticking until it lands).
    pub fn watchPending(self: *const Browser) bool {
        return self.watch_dirty_ns != 0;
    }

    /// startDetails starts looking up the new listing's details, when it came without.

    /// stage_ms is how long a new folder waits for its details before it's shown
    /// without them (the rest then fill in on screen), and the folder before stays.
    const stage_ms = 150;

    /// startDetails starts looking up `l`'s details (a listing of `dir`).
    fn startDetails(self: *Browser, l: *const scan.Listing, dir: []const u8) void {
        if (!l.needs_details or l.entries.len == 0) return;
        const workers = if (self.details_workers > 0) self.details_workers else details_mod.defaultWorkers();
        self.details = details_mod.Filler.start(self.io, self.alloc, dir, l.entries, workers, self.wake) catch null;
        self.details_sorted_ns = monoNs();
    }

    fn dropStaged(self: *Browser) void {
        if (self.staged) |l| {
            self.stopDetails(); // its lookups
            l.deinit(self.alloc);
        }
        self.staged = null;
    }

    /// stopDetails stops the lookups (without waiting: they finish the entry they're
    /// on, then reapDetails lets them go; closing waits for them).
    fn stopDetails(self: *Browser) void {
        if (self.details) |f| {
            f.stop();
            self.details_stopping.append(self.alloc, f) catch f.cancel();
        }
        self.details = null;
        self.details_dirty = false;
    }

    /// detailsPending reports whether details are still arriving (keep frames coming).
    pub fn detailsPending(self: *const Browser) bool {
        return self.details != null;
    }

    /// wantDetails puts view row `i` (on screen) first in line for its details.
    pub fn wantDetails(self: *const Browser, i: usize) void {
        const f = self.details orelse return;
        if (i < self.view.items.len) f.want(self.view.items[i]);
    }

    /// foldDetails applies the details that arrived since the last frame. When the
    /// view's order or filter depends on them, it's re-sorted, at most a few times a
    /// second while they stream in (so the list doesn't jitter) and once at the end.
    fn reapDetails(self: *Browser) void {
        var i: usize = 0;
        while (i < self.details_stopping.items.len) {
            const f = self.details_stopping.items[i];
            if (f.stopped()) {
                f.cancel();
                _ = self.details_stopping.swapRemove(i);
            } else i += 1;
        }
    }

    fn foldDetails(self: *Browser) void {
        self.reapDetails();
        const f = self.details orelse return;
        self.details_buf.clearRetainingCapacity();
        f.take(&self.details_buf, 50_000);
        const done = f.finished();
        // Into the staged listing while it waits, else the one on screen.
        const staged = self.staged != null;
        const target: ?*scan.Listing = if (self.staged) |*l| l else if (self.listing) |*l| l else null;
        if (target) |l| {
            for (self.details_buf.items) |d| {
                if (d.idx < l.entries.len and l.entries[d.idx].link_target.len == 0) d.apply(&l.entries[d.idx]) else if (d.link_target.len > 0) self.alloc.free(d.link_target);
            }
            if (done) l.needs_details = false;
        } else for (self.details_buf.items) |d| if (d.link_target.len > 0) self.alloc.free(d.link_target);
        if (!staged and self.details_buf.items.len > 0 and self.viewNeedsDetails()) self.details_dirty = true;
        if (done) {
            f.cancel();
            self.details = null;
        }
        const now = monoNs();
        if (self.details_dirty and (done or now - self.details_sorted_ns > 400 * std.time.ns_per_ms)) {
            self.details_dirty = false;
            self.details_sorted_ns = now;
            // What you selected stays selected and in view. With nothing selected the
            // cursor is just the first row, not a choice of yours: following it as it
            // sorts away would pull the list off its top on every re-sort.
            if (self.sel.count() > 0) self.rebuildViewPreserving() else self.rebuildView();
        }
    }

    /// viewNeedsDetails reports whether the view's order, grouping or filter reads
    /// details (a sort by size or date, a tag filter, a search rule).
    fn viewNeedsDetails(self: *const Browser) bool {
        if (self.sort_order.column != .name and self.sort_order.column != .type) return true;
        if (self.group_by != .none and self.group_by != .kind) return true;
        if (self.tag_filter != 0) return true;
        if (self.search.items.len > 0) {
            var qbuf: [512]u8 = undefined;
            const q = query_mod.parse(self.search.items, &qbuf);
            if (q.tag != 0 or q.modified.any() or q.created.any() or q.size.any()) return true;
        }
        return false;
    }

    /// installListing puts listing `l` on screen (its details may still be arriving).
    fn installListing(self: *Browser, l: scan.Listing) void {
        self.applyPendingView();
        const old = self.listing;
        // A reload of the same folder (F5, a finished op, an external change) keeps
        // what was selected — by name, since the entries are renumbered. A
        // newly-created entry's rename or a reveal still takes the cursor.
        const keep = self.reloading and old != null and
            self.rename_after_reload == null and self.select_after_load == null;
        var snap = if (keep) self.snapSelection() else null;
        defer if (snap) |*sn| sn.deinit();
        self.listing = l;
        self.err_name = null;
        self.noteShownDir();
        self.mergeExpanded(); // a reload re-reads the opened subfolders too
        self.rebuildView(); // filter + sort + reset selection
        if (snap) |*sn| self.restoreSelection(sn, false);
        if (old) |o| o.deinit(self.alloc); // after the restore: snap borrowed its names
        self.reloading = false;
        self.nav_ns = 0;
        self.entered = false;
    }

    /// carryDetails copies the details of the entries on screen onto the same-named
    /// ones of `l` (a re-read of this folder, names only), until fresh ones arrive.
    fn carryDetails(self: *Browser, l: scan.Listing) void {
        if (!l.needs_details) return;
        const old = self.listing orelse return;
        if (!std.mem.eql(u8, self.shownDir(), self.dir) or old.entries.len == 0) return;
        var by_name = std.StringHashMapUnmanaged(u32).empty;
        defer by_name.deinit(self.alloc);
        by_name.ensureTotalCapacity(self.alloc, @intCast(old.entries.len)) catch return;
        for (old.entries, 0..) |e, i| if (!e.pending) by_name.putAssumeCapacity(e.name, @intCast(i));
        for (l.entries) |*e| {
            const i = by_name.get(e.name) orelse continue;
            const o = old.entries[i];
            if (o.kind != e.kind) continue;
            e.size = o.size;
            e.mtime_secs = o.mtime_secs;
            e.atime_secs = o.atime_secs;
            e.ctime_secs = o.ctime_secs;
            e.btime_secs = o.btime_secs;
            e.mode = o.mode;
            e.uid = o.uid;
            e.gid = o.gid;
            e.inode = o.inode;
            e.nlink = o.nlink;
            e.tags = o.tags;
            e.pending = false;
        }
    }

    /// enterEmpty puts the folder being opened on screen before its listing has come:
    /// empty, with the loading bar, its files appearing once they're read.
    fn enterEmpty(self: *Browser) void {
        const none = self.alloc.alloc(scan.Entry, 0) catch return;
        self.installListing(.{ .entries = none });
        self.entered = true;
    }

    fn applyPendingView(self: *Browser) void {
        if (!self.view_pending) return;
        self.view_pending = false;
        self.applyFolderView();
    }

    /// shownDir is the folder the entries on screen are in: while the next one loads,
    /// `dir` already names it, but the listing (and its paths) are still the old one's.
    pub fn shownDir(self: *const Browser) []const u8 {
        return if (self.shown_dir.len > 0) self.shown_dir else self.dir;
    }

    /// noteShownDir records that the entries on screen are now the current folder's.
    fn noteShownDir(self: *Browser) void {
        if (std.mem.eql(u8, self.shown_dir, self.dir)) return;
        const d: []u8 = self.alloc.dupe(u8, self.dir) catch &.{}; // (none: open in self.dir)
        self.alloc.free(self.shown_dir);
        self.shown_dir = d;
    }

    /// update folds in a completed scan and/or a finished file operation. Call once
    /// per frame (render thread). Non-blocking. Returns true when it applied a scan.
    pub fn update(self: *Browser) bool {
        self.pollWatch();
        // A finished op → re-scan to reflect the change, and surface any error.
        if (self.ops.poll()) |comp| {
            self.op_err = comp.err_name;
            if (comp.created.len > 0) {
                self.onCreated(comp);
                self.alloc.free(comp.created);
            }
            var c2 = comp;
            c2.created = &.{};
            self.recordTransfer(c2);
            self.op_seq +%= 1;
            self.refresh();
        }
        // Fold in the latest streamed recursive-usage snapshot (for the treemap).
        if (self.usage.poll()) |snap| {
            if (self.usage_snapshot) |old| usage.freeSnapshot(self.alloc, old);
            self.usage_snapshot = snap;
        }
        if (self.deep_search != null) self.foldDeep(false);
        self.foldDetails();
        // A staged listing goes on screen once its details are in, or it's waited long
        // enough (the rest then fill in there).
        if (self.staged != null and (self.details == null or monoNs() - self.staged_ns > stage_ms * std.time.ns_per_ms)) {
            const l = self.staged.?;
            self.staged = null;
            self.installListing(l);
            self.loading = false;
            return true;
        }
        // The next folder is slow to come: open it now, empty (it fills in when read).
        if (self.loading and self.nav_ns != 0 and self.staged == null and monoNs() - self.nav_ns > stage_ms * std.time.ns_per_ms) {
            self.nav_ns = 0;
            self.enterEmpty();
        }
        const expanded = self.pollExpand();
        const res = self.scanner.poll() orelse return expanded;
        switch (res) {
            .listing => |l| if (blk: {
                // A reload: what's still there keeps its known details while they're
                // looked up again, so a folder that changes often (a download coming
                // in) doesn't blank its sizes, dates and icons each time.
                if (self.reloading) self.carryDetails(l);
                break :blk self.deep_search != null;
            }) {
                // A reload (F5, a finished op, an outside change) while showing subfolder
                // results: re-run the search so they reflect it, instead of replacing
                // them with the folder's own listing.
                l.deinit(self.alloc);
                self.reloading = false;
                self.restartDeep();
                return true;
            } else if (l.needs_details and l.entries.len > 0 and !self.entered) {
                // Names only: wait (briefly) for the details before showing it (not
                // when it's on screen already, empty: then the names show at once).
                self.dropStaged();
                self.stopDetails(); // the folder on screen is on its way out
                self.staged = l;
                self.staged_ns = monoNs();
                self.startDetails(&self.staged.?, self.dir);
                return true; // still loading
            } else {
                self.stopDetails();
                self.installListing(l);
                if (self.listing) |*shown| self.startDetails(shown, self.dir); // (names only: the rest fill in)
            },
            .err => |e| {
                self.dropStaged();
                self.nav_ns = 0;
                self.entered = false;
                self.applyPendingView();
                // A favourite that isn't there: one level up, and try again.
                if (self.climb_from != null and (e == error.FileNotFound or e == error.NotDir) and self.dir.len > 1) {
                    const parent = std.fs.path.dirname(self.dir) orelse "/";
                    if (self.alloc.dupe(u8, parent)) |dup| {
                        self.alloc.free(self.history.items[self.hist_pos]); // (not a stop in history)
                        self.history.items[self.hist_pos] = dup;
                        self.climbed = true;
                        self.goTo(dup) catch {};
                        return true;
                    } else |_| {}
                }
                self.reloading = false;
                self.stopDetails();
                if (self.listing) |old| old.deinit(self.alloc);
                self.listing = null;
                self.err_name = @errorName(e);
                self.noteShownDir();
                self.view.clearRetainingCapacity();
                self.sel.reset(self.alloc, 0) catch {};
            },
        }
        self.loading = false;
        return true;
    }
};

fn monoNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// copyInto memcpys `src` into `buf` (truncating to buf.len) and returns the written
/// slice — a tiny helper for building a menu/name string in a caller-owned buffer.
fn copyInto(buf: []u8, src: []const u8) []const u8 {
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}

fn dupPaths(alloc: std.mem.Allocator, list: []const []u8) ![][]u8 {
    const out = try alloc.alloc([]u8, list.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |p| alloc.free(p);
        alloc.free(out);
    }
    for (list) |p| {
        out[n] = try alloc.dupe(u8, p);
        n += 1;
    }
    return out;
}

fn freePaths(alloc: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| alloc.free(p);
    alloc.free(paths);
}

/// isHidden reports whether a name is a Unix dotfile.
/// isUnderRel reports whether relative name `name` lies inside folder `rel`.
fn isUnderRel(name: []const u8, rel: []const u8) bool {
    return name.len > rel.len and std.mem.startsWith(u8, name, rel) and name[rel.len] == '/';
}

fn isHidden(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

/// isSelfOrDescendant reports whether dst is src itself or a path under it — the
/// case where moving/copying src into dst would recurse into what we're creating.
fn isSelfOrDescendant(dst: []const u8, src: []const u8) bool {
    if (std.mem.eql(u8, dst, src)) return true;
    return dst.len > src.len and std.mem.startsWith(u8, dst, src) and dst[src.len] == '/';
}

// ---------------------------------------------------------------------------
const testing = std.testing;

// waitLoaded spins the frame-style update until a scan completes (bounded).
fn waitLoaded(b: *Browser) !void {
    var spins: usize = 0;
    while ((b.loading or b.detailsPending()) and spins < 400_000) : (spins += 1) {
        if (!b.update()) std.Thread.yield() catch {};
    }
    try testing.expect(!b.loading);
    try testing.expect(!b.detailsPending());
}

test "browser navigates into and back out of a subdirectory" {
    const a = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/inner.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top.txt", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root); // trash_home unused in these tests
    defer b.deinit();
    try waitLoaded(b);

    // Root has "sub" (dir, first) and "top.txt".
    try testing.expectEqual(@as(usize, 2), b.count());
    try testing.expectEqualStrings("sub", b.at(0).name);
    try testing.expect(b.at(0).isDir());

    // Enter "sub" → sees inner.txt.
    try b.open(b.at(0));
    try waitLoaded(b);
    try testing.expectEqual(@as(usize, 1), b.count());
    try testing.expectEqualStrings("inner.txt", b.at(0).name);

    // Back up → root again.
    try b.up();
    try waitLoaded(b);
    try testing.expectEqual(@as(usize, 2), b.count());
    try testing.expectEqualStrings("sub", b.at(0).name);
}

test "a typed . or .. is resolved, and the folder you're in isn't added to history again" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);
    const hist = b.history.items.len;

    const dot = try std.mem.concat(a, u8, &.{ root, "/." });
    defer a.free(dot);
    try b.navigate(dot);
    try waitLoaded(b);
    try testing.expectEqualStrings(root, b.dir);
    try testing.expectEqual(hist, b.history.items.len); // no second entry for it
    try testing.expect(!b.canBack());

    const via = try std.mem.concat(a, u8, &.{ root, "/sub/./../sub" });
    defer a.free(via);
    try b.navigate(via);
    try waitLoaded(b);
    const want = try std.mem.concat(a, u8, &.{ root, "/sub" });
    defer a.free(want);
    try testing.expectEqualStrings(want, b.dir);
}

test "backOrUp climbs to parent with no history, then Forward re-descends" {
    const a = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const sub = try std.fs.path.join(a, &.{ root, "sub" });
    defer a.free(sub);

    // Start INSIDE sub with a fresh history (no back entries).
    const b = try Browser.init(a, io, sub, root, root);
    defer b.deinit();
    try waitLoaded(b);
    try testing.expect(!b.canBack()); // nothing to go back to yet
    try testing.expect(b.canBackOrUp()); // ...but Back is still live: it can climb to the parent

    // Back with no history → climbs to the parent (acts like Up).
    b.backOrUp();
    try waitLoaded(b);
    try testing.expectEqualStrings(root, b.dir);

    // The folder we left is now reachable via Forward (prepend kept it ahead of us).
    try testing.expect(b.canForward());
    b.forward();
    try waitLoaded(b);
    try testing.expectEqualStrings(sub, b.dir);

    // With history present, Back is ordinary history-back (no bounce).
    try testing.expect(b.canBack());
    b.backOrUp();
    try waitLoaded(b);
    try testing.expectEqualStrings(root, b.dir);
}

test "open is ignored while a navigation is in flight (rapid double-click guard)" {
    const a = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    // Enter "sub" but do NOT let the scan land: b.loading is now true and the view
    // still shows root's entries.
    try testing.expectEqualStrings("sub", b.at(0).name);
    try b.open(b.at(0));
    try testing.expect(b.loading);
    const entered = try a.dupe(u8, b.dir);
    defer a.free(entered);

    // A second rapid open() would act on the STALE view (still root's "sub" entry).
    // Without the guard this navigates to <sub>/sub and dead-ends; the guard drops it.
    try b.open(b.at(0));
    try testing.expectEqualStrings(entered, b.dir); // unchanged by the second open

    try waitLoaded(b);
    try testing.expect(std.mem.endsWith(u8, b.dir, "/sub"));
    try testing.expect(!std.mem.endsWith(u8, b.dir, "/sub/sub"));
}

test "selection and cursor survive a re-sort (pinned by name)" {
    const a = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    // Name-ascending: a, b, c. Click "a" (index 0).
    try testing.expectEqualStrings("a.txt", b.at(0).name);
    b.sel.click(0);
    try testing.expect(b.sel.isSelected(0));

    // Flip to name-descending: order becomes c, b, a. "a" is now last.
    b.setSort(.name, false);
    try testing.expectEqualStrings("c.txt", b.at(0).name);
    try testing.expectEqualStrings("a.txt", b.at(2).name);

    // "a" is still selected and the cursor rode along to its new row.
    try testing.expectEqual(@as(usize, 1), b.sel.count());
    try testing.expect(b.sel.isSelected(2));
    try testing.expectEqual(@as(usize, 2), b.sel.cursor);
}

test "queueExternalDrop + commitExternalDrop copies dropped files into the target dir" {
    const a = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest"); // the folder we "drop" onto
    try tmp.dir.writeFile(io, .{ .sub_path = "ext.txt", .data = "hello" }); // the "external" file
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const src = try std.fs.path.join(a, &.{ root, "ext.txt" });
    defer a.free(src);
    const dest = try std.fs.path.join(a, &.{ root, "dest" });
    defer a.free(dest);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    // Simulate a drop of one external file at some position, then commit into "dest".
    const srcs = try a.alloc([]u8, 1);
    srcs[0] = try a.dupe(u8, src);
    b.queueExternalDrop(srcs, 10, 10); // browser takes ownership of srcs
    try testing.expect(b.pendingDropPos() != null);
    b.commitExternalDrop(dest);
    try testing.expect(b.pendingDropPos() == null); // cleared after commit

    // Enter "dest" and confirm the copy landed there.
    try b.navigate(dest);
    try waitSettled(b, "ext.txt", true);
}

test "a drag carries a snapshot of paths, not live row indices" {
    const a = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dest");
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "bee" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "cee" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const dest = try std.fs.path.join(a, &.{ root, "dest" });
    defer a.free(dest);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    // View is dirs-first, name-ascending: [dest, b.txt, c.txt]. Drag "b.txt".
    try testing.expectEqualStrings("b.txt", b.at(1).name);
    b.sel.click(1);
    b.beginDrag();
    try testing.expectEqual(@as(usize, 1), b.dragPaths().len);

    // Now the selection moves (a background rescan, a keyboard nudge, another view
    // acting on the model — anything that re-points row indices mid-drag). The drop
    // must still act on what the user picked up, not on what index 1 means now.
    b.sel.click(2); // c.txt
    b.dropDraggedInto(b.dragPaths(), dest, false); // move
    b.endDrag();
    try testing.expect(b.dragPaths().len == 0);

    try waitSettled(b, "b.txt", false); // b.txt left the source dir
    try testing.expect(indexOf(b, "c.txt") != null); // c.txt untouched
    try b.navigate(dest);
    try waitSettled(b, "b.txt", true);
}

test "dropDraggedInto refuses a folder dropped onto itself or its own descendant" {
    const a = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "outer/inner");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const outer = try std.fs.path.join(a, &.{ root, "outer" });
    defer a.free(outer);
    const inner = try std.fs.path.join(a, &.{ root, "outer", "inner" });
    defer a.free(inner);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    // Dragging "outer" into itself, and into its own child, are both no-ops — either
    // one would otherwise recurse forever while copying.
    b.dropDraggedInto(&.{outer}, outer, true);
    b.dropDraggedInto(&.{outer}, inner, true);
    // And an item already sitting in the destination isn't moved onto itself.
    b.dropDraggedInto(&.{outer}, root, false);

    var spins: usize = 0;
    while (b.opsBusy() and spins < 5_000_000) : (spins += 1) std.Thread.yield() catch {};
    try testing.expect(!b.opsBusy());
    try b.navigate(inner);
    try waitLoaded(b);
    try testing.expectEqual(@as(usize, 0), b.count()); // nothing was copied into it
}

test "commitExternalDrop skips a source that contains the destination" {
    const a = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "outer/inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.txt", .data = "fine" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const outer = try std.fs.path.join(a, &.{ root, "outer" });
    defer a.free(outer);
    const inner = try std.fs.path.join(a, &.{ root, "outer", "inner" });
    defer a.free(inner);
    const ok = try std.fs.path.join(a, &.{ root, "ok.txt" });
    defer a.free(ok);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    // Another file manager hands us "outer" AND a normal file, aimed at outer/inner.
    // The recursive one is dropped; the other still lands.
    const srcs = try a.alloc([]u8, 2);
    srcs[0] = try a.dupe(u8, outer);
    srcs[1] = try a.dupe(u8, ok);
    b.queueExternalDrop(srcs, 0, 0);
    b.commitExternalDrop(inner);

    try b.navigate(inner);
    try waitSettled(b, "ok.txt", true);
    try testing.expect(indexOf(b, "outer") == null);
}

test "setPendingSelect selects + reveals the named entry once loaded (show-in-folder)" {
    const a = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "two.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "three.txt", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    b.setPendingSelect("two.txt"); // requested BEFORE the first listing lands
    try waitLoaded(b);

    // Once the folder loads, "two.txt" is the sole selection and the cursor.
    try testing.expectEqual(@as(usize, 1), b.sel.count());
    try testing.expect(b.sel.isSelected(b.sel.cursor));
    try testing.expectEqualStrings("two.txt", b.at(b.sel.cursor).name);
    try testing.expect(b.select_after_load == null); // one-shot: cleared after applying
}

test "browser hides dotfiles until toggled" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "visible.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root); // trash_home unused in these tests
    defer b.deinit();
    try waitLoaded(b);

    try testing.expectEqual(@as(usize, 1), b.count()); // only visible.txt
    try testing.expectEqualStrings("visible.txt", b.at(0).name);

    b.toggleHidden();
    try testing.expectEqual(@as(usize, 2), b.count()); // ".hidden" now shown (sorts first)
    try testing.expectEqualStrings(".hidden", b.at(0).name);
}

test "browser filters by quick-search glob" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "photo.png", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "report.txt", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);
    try testing.expectEqual(@as(usize, 3), b.count());

    b.setSearch("*.txt"); // glob → only .txt files
    try testing.expectEqual(@as(usize, 2), b.count());
    b.setSearch("report"); // bare word → substring
    try testing.expectEqual(@as(usize, 1), b.count());
    try testing.expectEqualStrings("report.txt", b.at(0).name);
    b.setSearch(""); // cleared → all back
    try testing.expectEqual(@as(usize, 3), b.count());
}

test "browser resorts on setSort" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "xxx" }); // 3 bytes
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "x" }); // 1 byte
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root); // trash_home unused in these tests
    defer b.deinit();
    try waitLoaded(b);

    try testing.expectEqualStrings("a.txt", b.at(0).name); // name asc
    b.setSort(.size, true); // size asc → b.txt (1) before a.txt (3)
    try testing.expectEqualStrings("b.txt", b.at(0).name);
}

test "browser surfaces a scan error for a missing directory" {
    const a = testing.allocator;
    const b = try Browser.init(a, testing.io, "/no/such/dir/zfd-browser-test", "/tmp", "/tmp");
    defer b.deinit();
    try waitLoaded(b);
    try testing.expect(b.err_name != null);
    try testing.expectEqual(@as(usize, 0), b.count());
}

// ---------------------------------------------------------------------------
// File-operation tests. These drive real (off-thread) ops against a temp dir,
// so each asserts a before-state and an after-state that DIFFER — proving the op
// actually changed the filesystem, not just that a post-condition happened to hold.

// indexOf finds the view row with the given name (post-filter/sort), or null.
fn indexOf(b: *Browser, name: []const u8) ?usize {
    var i: usize = 0;
    while (i < b.count()) : (i += 1) {
        if (std.mem.eql(u8, b.at(i).name, name)) return i;
    }
    return null;
}

// waitSettled spins update() until the directory reflects the expected presence of
// `name` and no scan is in flight — robust to ops that refresh more than once (undo
// kicks an async op AND an immediate refresh, so a single reload cycle isn't enough).
/// waitOps lets the file ops finish and their completions be taken.
fn waitOps(b: *Browser) !void {
    var spins: usize = 0;
    while (b.ops.busy() and spins < 5_000_000) : (spins += 1) {
        _ = b.update();
        std.Thread.yield() catch {};
    }
    try testing.expect(!b.ops.busy());
    for (0..100) |_| _ = b.update();
}

fn waitSettled(b: *Browser, name: []const u8, present: bool) !void {
    var spins: usize = 0;
    while (spins < 5_000_000) : (spins += 1) {
        _ = b.update();
        if (!b.loading and (indexOf(b, name) != null) == present) break;
        std.Thread.yield() catch {};
    }
    try testing.expectEqual(present, indexOf(b, name) != null);
    try testing.expect(!b.loading);
}

test "newFolder creates a directory and arms inline-rename on it" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // An existing directory "AAA" sorts before "New Folder" (default sort is dirs-first,
    // then by name), so the new folder lands at index 1 — asserting the cursor moved
    // there then proves a real move off the default row 0 (index 0 would pass even if
    // applyPendingRename never touched the cursor).
    try tmp.dir.createDirPath(io, "AAA");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);
    try testing.expectEqual(@as(usize, 1), b.count());
    try testing.expect(indexOf(b, "New Folder") == null); // before: doesn't exist
    try testing.expectEqual(@as(usize, 0), b.sel.cursor); // before: cursor on row 0
    try testing.expect(!b.takeWantRename()); // before: rename not armed

    b.newFolder();
    try waitSettled(b, "New Folder", true); // after: created and shown

    const idx = indexOf(b, "New Folder").?;
    try testing.expect(b.at(idx).isDir());
    try testing.expectEqual(@as(usize, 2), b.count()); // 1 → 2
    try testing.expect(idx > 0); // it sorted after "1.txt"…
    try testing.expectEqual(idx, b.sel.cursor); // …and the cursor moved onto it (off row 0)
    try testing.expect(b.takeWantRename()); // inline-rename armed (false → true)…
    try testing.expect(!b.takeWantRename()); // …and consumed exactly once
}

test "copy then paste duplicates a file into another directory" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "hello" });
    try tmp.dir.createDirPath(io, "sub");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    b.sel.click(indexOf(b, "file.txt").?);
    b.copySelection();

    try b.open(b.at(indexOf(b, "sub").?)); // into the empty subdir
    try waitLoaded(b);
    try testing.expectEqual(@as(usize, 0), b.count()); // before: sub is empty

    b.paste();
    try waitSettled(b, "file.txt", true); // after: the copy landed in sub

    try b.up();
    try waitLoaded(b);
    try testing.expect(indexOf(b, "file.txt") != null); // original still in root (copy, not move)
}

test "pasteIntoDir drops the clipboard into the right-clicked folder, not the current dir" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "hello" });
    try tmp.dir.createDirPath(io, "sub");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    b.sel.click(indexOf(b, "file.txt").?);
    b.copySelection();

    // Right-click "sub" and Paste while still standing in root: the copy must land
    // inside sub, and root keeps its original file (copy, not move).
    b.pasteIntoDir(indexOf(b, "sub").?);
    try waitSettled(b, "file.txt", true); // root still has the original
    try testing.expect(indexOf(b, "sub") != null);

    try b.open(b.at(indexOf(b, "sub").?));
    try waitSettled(b, "file.txt", true); // …and the copy is inside sub
}

test "cut then paste moves a file and clears the clipboard" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "hello" });
    try tmp.dir.createDirPath(io, "sub");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    const fi = indexOf(b, "file.txt").?;
    b.sel.click(fi);
    b.cutSelection();
    try testing.expect(b.isCut(fi)); // marked for a move

    try b.open(b.at(indexOf(b, "sub").?));
    try waitLoaded(b);
    b.paste();
    try waitSettled(b, "file.txt", true); // moved into sub
    try testing.expect(b.clipboard.isEmpty()); // a cut clears the clipboard on paste

    try b.up();
    try waitSettled(b, "file.txt", false); // …and it's gone from the source dir
}

test "tabs sharing a clipboard: cut in one browser, paste in another moves the file" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "hello" });
    try tmp.dir.createDirPath(io, "sub");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const sub = try std.fs.path.join(a, &.{ root, "sub" });
    defer a.free(sub);

    var shared: Clipboard = .{};
    defer shared.deinit(a);
    const src = try Browser.init(a, io, root, root, root);
    defer src.deinit();
    const dst = try Browser.init(a, io, sub, root, root);
    defer dst.deinit();
    src.shareClipboard(&shared);
    dst.shareClipboard(&shared);
    try waitLoaded(src);
    try waitLoaded(dst);

    src.sel.click(indexOf(src, "file.txt").?);
    src.cutSelection();
    try testing.expect(!dst.clipboard.isEmpty()); // the other tab sees the cut

    const seq = dst.op_seq;
    dst.paste();
    try waitSettled(dst, "file.txt", true); // moved into sub via the OTHER browser
    try testing.expect(dst.op_seq != seq); // completion is observable (shell refreshes other tabs)
    try testing.expect(shared.isEmpty()); // the cut was consumed
}

test "undo of a move restores the ORIGINAL name even when the move had to rename it" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "mine" });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/a.txt", .data = "theirs" }); // forces a unique name
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const sub = try std.fs.path.join(a, &.{ root, "sub" });
    defer a.free(sub);
    const src = try std.fs.path.join(a, &.{ root, "a.txt" });
    defer a.free(src);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);
    try testing.expect(!b.canUndo());

    b.dropDraggedInto(&.{src}, sub, false); // move
    // sub/a.txt exists: the move waits for the user's answer instead of guessing.
    const info = b.conflictInfo().?;
    try testing.expectEqual(@as(usize, 1), info.clashes);
    try testing.expectEqualStrings("a.txt", info.name);
    b.resolveConflict(.keep_both);
    try waitSettled(b, "a.txt", false);
    try testing.expect(b.canUndo()); // the completed move was recorded

    b.undo();
    try waitSettled(b, "a.txt", true); // back under its original name
    const back = try tmp.dir.readFileAlloc(io, "a.txt", a, .limited(64));
    defer a.free(back);
    try testing.expectEqualStrings("mine", back);
    const theirs = try tmp.dir.readFileAlloc(io, "sub/a.txt", a, .limited(64));
    defer a.free(theirs);
    try testing.expectEqualStrings("theirs", theirs); // the other file was never touched
}

test "opening a folder while another loads goes there, not into the loading one" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "A");
    try tmp.dir.createDirPath(io, "B");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);
    const ia = indexOf(b, "A").?;
    const ib = indexOf(b, "B").?;
    const entry_b = b.at(ib);

    // Open A; before its listing lands (the root's is still shown), open B from it.
    try b.open(b.at(ia));
    try testing.expect(b.loading);
    try b.open(entry_b);
    const want_b = try std.fs.path.join(a, &.{ root, "B" });
    defer a.free(want_b);
    try testing.expectEqualStrings(want_b, b.dir);
    try waitLoaded(b);
    // Back goes to where B was opened from, not to the unfinished A.
    b.back();
    try testing.expectEqualStrings(root, b.dir);
}

test "conflict answers: Replace trashes the old file, Skip leaves it, Cancel does nothing" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "dst");
    try tmp.dir.createDirPath(io, "Trash");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/r.txt", .data = "new" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dst/r.txt", .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/s.txt", .data = "new" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dst/s.txt", .data = "old" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const th = try std.fs.path.join(a, &.{ root, "Trash" });
    defer a.free(th);
    const dst = try std.fs.path.join(a, &.{ root, "dst" });
    defer a.free(dst);
    const r = try std.fs.path.join(a, &.{ root, "src", "r.txt" });
    defer a.free(r);
    const sp = try std.fs.path.join(a, &.{ root, "src", "s.txt" });
    defer a.free(sp);

    const b = try Browser.init(a, io, dst, th, root);
    defer b.deinit();
    try waitLoaded(b);

    // Cancel: nothing happens, nothing stays parked.
    b.dropDraggedInto(&.{r}, dst, true);
    try testing.expect(b.conflictInfo() != null);
    b.resolveConflict(null);
    try testing.expect(b.conflictInfo() == null);

    // Replace: the new content lands, the old file is in the trash (recoverable).
    b.dropDraggedInto(&.{r}, dst, true);
    b.resolveConflict(.replace);
    var spins: usize = 0;
    while (spins < 5_000_000) : (spins += 1) {
        _ = b.update();
        const got = tmp.dir.readFileAlloc(io, "dst/r.txt", a, .limited(64)) catch continue;
        defer a.free(got);
        if (std.mem.eql(u8, got, "new")) break;
        std.Thread.yield() catch {};
    }
    const now_r = try tmp.dir.readFileAlloc(io, "dst/r.txt", a, .limited(64));
    defer a.free(now_r);
    try testing.expectEqualStrings("new", now_r);
    const trashed = try tmp.dir.readFileAlloc(io, "Trash/files/r.txt", a, .limited(64));
    defer a.free(trashed);
    try testing.expectEqualStrings("old", trashed);

    // Skip: the existing file is untouched and no "s (2).txt" appears.
    b.dropDraggedInto(&.{sp}, dst, true);
    b.resolveConflict(.skip);
    try waitSettled(b, "s (2).txt", false);
    const now_s = try tmp.dir.readFileAlloc(io, "dst/s.txt", a, .limited(64));
    defer a.free(now_s);
    try testing.expectEqualStrings("old", now_s);
}

test "folder conflicts: Merge adds the contents, Replace trashes the old folder" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/F");
    try tmp.dir.createDirPath(io, "dst/F");
    try tmp.dir.createDirPath(io, "Trash");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/F/new.txt", .data = "new" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/F/both.txt", .data = "incoming" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dst/F/old.txt", .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dst/F/both.txt", .data = "existing" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const th = try std.fs.path.join(a, &.{ root, "Trash" });
    defer a.free(th);
    const dst = try std.fs.path.join(a, &.{ root, "dst" });
    defer a.free(dst);
    const f = try std.fs.path.join(a, &.{ root, "src", "F" });
    defer a.free(f);

    const b = try Browser.init(a, io, dst, th, root);
    defer b.deinit();
    try waitLoaded(b);

    // Merge: both folders' files end up in the existing one; the clash is overwritten.
    b.dropDraggedInto(&.{f}, dst, true);
    try testing.expect(b.conflictInfo().?.existing.is_dir);
    b.resolveConflict(.merge);
    var spins: usize = 0;
    while (spins < 5_000_000) : (spins += 1) {
        _ = b.update();
        if (tmp.dir.access(io, "dst/F/new.txt", .{})) |_| break else |_| {}
        std.Thread.yield() catch {};
    }
    try waitOps(b);
    const both = try tmp.dir.readFileAlloc(io, "dst/F/both.txt", a, .limited(64));
    defer a.free(both);
    try testing.expectEqualStrings("incoming", both);
    const old = try tmp.dir.readFileAlloc(io, "dst/F/old.txt", a, .limited(64));
    defer a.free(old);
    try testing.expectEqualStrings("old", old);
    try testing.expect(!b.canUndo()); // a merge can't be undone

    // Replace: the merged folder goes to the trash whole; only the incoming files remain.
    b.dropDraggedInto(&.{f}, dst, true);
    b.resolveConflict(.replace);
    spins = 0;
    while (spins < 5_000_000) : (spins += 1) {
        _ = b.update();
        if (tmp.dir.access(io, "Trash/files/F/old.txt", .{})) |_| break else |_| {}
        std.Thread.yield() catch {};
    }
    try waitOps(b);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "dst/F/old.txt", .{}));
    try tmp.dir.access(io, "dst/F/new.txt", .{});
    try tmp.dir.access(io, "Trash/files/F/old.txt", .{});
}

test "undo of a copy sends the copy to the trash and leaves the original" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "x" });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.createDirPath(io, "Trash");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const trash_home = try std.fs.path.join(a, &.{ root, "Trash" });
    defer a.free(trash_home);
    const src = try std.fs.path.join(a, &.{ root, "a.txt" });
    defer a.free(src);
    const sub = try std.fs.path.join(a, &.{ root, "sub" });
    defer a.free(sub);

    const b = try Browser.init(a, io, sub, trash_home, root);
    defer b.deinit();
    try waitLoaded(b);

    b.dropDraggedInto(&.{src}, sub, true); // copy into the folder we're viewing
    try waitSettled(b, "a.txt", true);
    try testing.expect(b.canUndo());

    b.undo();
    try waitSettled(b, "a.txt", false); // the copy is gone from sub…
    _ = try tmp.dir.statFile(io, "a.txt", .{}); // …the original is untouched
    _ = try tmp.dir.statFile(io, "Trash/files/a.txt", .{}); // …and the copy is recoverable
}

test "a file created by another program appears without a manual refresh" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "old.txt", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);
    try testing.expect(indexOf(b, "new.txt") == null);

    // Select old.txt, then change the folder behind the browser's back.
    b.sel.click(indexOf(b, "old.txt").?);
    try tmp.dir.writeFile(io, .{ .sub_path = "new.txt", .data = "x" });

    try waitSettled(b, "new.txt", true); // only update() is called — the watch did the rest
    // The reload kept the selection on old.txt (by name, though rows were renumbered).
    try testing.expect(b.sel.isSelected(indexOf(b, "old.txt").?));
    try testing.expect(!b.sel.isSelected(indexOf(b, "new.txt").?));
}

test "renameMany renames in one job and one undo restores every name" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.jpg", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.jpg", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    b.renameMany(&.{ "a.jpg", "b.jpg" }, &.{ "photo_1.jpg", "photo_2.jpg" });
    try waitSettled(b, "photo_2.jpg", true);
    try testing.expect(indexOf(b, "photo_1.jpg") != null and indexOf(b, "a.jpg") == null);

    b.undo();
    try waitSettled(b, "b.jpg", true);
    try testing.expect(indexOf(b, "a.jpg") != null and indexOf(b, "photo_1.jpg") == null);
}

test "subfolder search is opt-in, finds nested matches, and switches off on navigation" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "top-note.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/deeper/note.txt", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    // Default: the quick-search only filters this folder — the nested file isn't found.
    b.setSearch("note");
    try testing.expect(!b.deep);
    try testing.expect(indexOf(b, "top-note.txt") != null);
    try testing.expect(indexOf(b, "sub/deeper/note.txt") == null);

    // Opt in: the walk finds it, listed by its path relative to this folder.
    b.setDeep(true);
    try waitSettled(b, "sub/deeper/note.txt", true);
    try testing.expect(indexOf(b, "top-note.txt") != null);
    try testing.expect(b.deepStatus().?.found == 2);

    // Leaving the folder turns it off again.
    try b.navigate(root);
    try waitLoaded(b);
    try testing.expect(!b.deep and !b.deepActive());
}

test "renameCursor renames the file and undo restores the old name" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);
    try testing.expect(!b.canUndo());

    b.sel.click(indexOf(b, "a.txt").?);
    // Committing the SAME name (e.g. clicking away from a rename without editing) is a
    // no-op: no rename op, nothing to undo.
    b.renameCursor("a.txt");
    try testing.expect(!b.canUndo());
    try testing.expect(indexOf(b, "a.txt") != null);

    b.renameCursor("z.txt");
    try waitSettled(b, "z.txt", true);
    try waitSettled(b, "a.txt", false); // old name gone
    try testing.expect(b.canUndo());

    b.undo();
    try waitSettled(b, "a.txt", true); // undo brings the old name back
    try waitSettled(b, "z.txt", false); // …and the final listing no longer has the new one
}

test "trashSelection removes the file and undo restores it from the trash" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var trashtmp = testing.tmpDir(.{ .iterate = true });
    defer trashtmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "doomed.txt", .data = "bye" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const th = try trashtmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(th);

    const b = try Browser.init(a, io, root, th, root); // real trash_home this time
    defer b.deinit();
    try waitLoaded(b);
    try testing.expect(indexOf(b, "doomed.txt") != null);

    b.sel.click(indexOf(b, "doomed.txt").?);
    b.trashSelection();
    try waitSettled(b, "doomed.txt", false); // trashed → gone from the dir
    try testing.expect(b.canUndo());

    b.undo();
    try waitSettled(b, "doomed.txt", true); // restored from the trash
}

test "deleteSelection(permanent) removes the file for good" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "gone.txt", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);
    try testing.expectEqual(@as(usize, 2), b.count());

    b.sel.click(indexOf(b, "gone.txt").?);
    b.deleteSelection(true);
    try waitSettled(b, "gone.txt", false); // permanently deleted
    try testing.expect(indexOf(b, "keep.txt") != null); // the other file is untouched
    try testing.expectEqual(@as(usize, 1), b.count());
}

test "selectionSize sums the sizes of the selected files" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "xxx" }); // 3 bytes
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "xxxxx" }); // 5 bytes
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    b.selectAll();
    try testing.expectEqual(@as(u64, 8), b.selectionSize()); // both selected → 3+5
    b.sel.click(indexOf(b, "a.txt").?);
    try testing.expectEqual(@as(u64, 3), b.selectionSize()); // just a.txt now
}

test "toggleSearchCI switches quick-search case sensitivity" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "Report.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    b.setSearch("report"); // default is case-insensitive
    try testing.expectEqual(@as(usize, 1), b.count()); // matches "Report.txt"
    b.toggleSearchCI(); // now case-sensitive
    try testing.expectEqual(@as(usize, 0), b.count()); // "report" != "Report.txt"
    b.toggleSearchCI(); // back to insensitive
    try testing.expectEqual(@as(usize, 1), b.count());
}

test "isCut marks only cut rows, and only in cut mode" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);

    const ai = indexOf(b, "a.txt").?;
    const bi = indexOf(b, "b.txt").?;
    try testing.expect(!b.isCut(ai)); // before: nothing on the clipboard
    try testing.expect(!b.isCut(bi));

    b.sel.click(ai);
    b.copySelection();
    try testing.expect(!b.isCut(ai)); // a copy is never drawn faded, even for the copied row

    b.cutSelection();
    try testing.expect(b.isCut(ai)); // ai transitioned false→true (a move → faded)
    try testing.expect(!b.isCut(bi)); // bi is not on the clipboard

    // Cut bi instead: the mark must follow the clipboard, not stick to a row index.
    b.sel.click(bi);
    b.cutSelection();
    try testing.expect(b.isCut(bi)); // bi now transitioned false→true…
    try testing.expect(!b.isCut(ai)); // …and ai is no longer cut (clipboard replaced)
}

test "active chooser filter hides non-matching files but keeps directories" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.png", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "" });
    try tmp.dir.createDirPath(io, "sub");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const b = try Browser.init(a, io, root, root, root);
    defer b.deinit();
    try waitLoaded(b);
    try testing.expectEqual(@as(usize, 3), b.count()); // before: everything shows

    const images = filter.FileFilter{ .name = "Images", .globs = &.{"*.png"} };
    b.setActiveFilter(images);
    try testing.expectEqual(@as(usize, 2), b.count()); // b.txt hidden; a.png + sub remain
    try testing.expect(indexOf(b, "a.png") != null);
    try testing.expect(indexOf(b, "sub") != null); // a directory is never filtered out
    try testing.expect(indexOf(b, "b.txt") == null);

    b.setActiveFilter(null);
    try testing.expectEqual(@as(usize, 3), b.count()); // cleared → all back
}

test "conflicts answered item by item: Keep both for one, Skip for the other" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "dst");
    for ([_][]const u8{ "src/k.txt", "src/s.txt" }) |p| try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "new" });
    for ([_][]const u8{ "dst/k.txt", "dst/s.txt" }) |p| try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "old" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const dst = try std.fs.path.join(a, &.{ root, "dst" });
    defer a.free(dst);
    const k = try std.fs.path.join(a, &.{ root, "src", "k.txt" });
    defer a.free(k);
    const sp = try std.fs.path.join(a, &.{ root, "src", "s.txt" });
    defer a.free(sp);

    const b = try Browser.init(a, io, dst, root, root);
    defer b.deinit();
    try waitLoaded(b);

    b.dropDraggedInto(&.{ k, sp }, dst, true);
    const first = b.conflictInfo().?;
    try testing.expectEqual(@as(usize, 2), first.clashes);
    try testing.expectEqualStrings("k.txt", first.name);
    try testing.expectEqual(@as(u64, 3), first.existing.size);
    b.decideOne(.keep_both);
    const second = b.conflictInfo().?; // still waiting: one answer given, one to go
    try testing.expectEqual(@as(usize, 1), second.step);
    try testing.expectEqualStrings("s.txt", second.name);
    b.decideOne(.skip);
    try testing.expect(b.conflictInfo() == null);

    try waitSettled(b, "k (copy).txt", true);
    try testing.expect(indexOf(b, "s (copy).txt") == null);
    const s_now = try tmp.dir.readFileAlloc(io, "dst/s.txt", a, .limited(64));
    defer a.free(s_now);
    try testing.expectEqualStrings("old", s_now);
}

test "Replace if newer replaces only the items that are newer" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "dst");
    try tmp.dir.createDirPath(io, "Trash");
    try tmp.dir.writeFile(io, .{ .sub_path = "dst/new.txt", .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/new.txt", .data = "fresh" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/old.txt", .data = "stale" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dst/old.txt", .data = "keep" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    // Age dst/new.txt and src/old.txt by an hour so the comparison is unambiguous.
    for ([_][]const u8{ "dst/new.txt", "src/old.txt" }) |rel| {
        const p = try std.fs.path.joinZ(a, &.{ root, rel });
        defer a.free(p);
        const past: i64 = (fsops.brief(p) orelse return error.NoStat).mtime_secs - 3600;
        const times = [2]std.os.linux.timespec{ .{ .sec = past, .nsec = 0 }, .{ .sec = past, .nsec = 0 } };
        _ = std.os.linux.utimensat(std.os.linux.AT.FDCWD, p.ptr, &times, 0);
    }
    const th = try std.fs.path.join(a, &.{ root, "Trash" });
    defer a.free(th);
    const dst = try std.fs.path.join(a, &.{ root, "dst" });
    defer a.free(dst);
    const n = try std.fs.path.join(a, &.{ root, "src", "new.txt" });
    defer a.free(n);
    const o = try std.fs.path.join(a, &.{ root, "src", "old.txt" });
    defer a.free(o);

    const b = try Browser.init(a, io, dst, th, root);
    defer b.deinit();
    try waitLoaded(b);

    b.dropDraggedInto(&.{ n, o }, dst, true);
    b.resolveConflict(.replace_older);
    var spins: usize = 0;
    while (spins < 5_000_000) : (spins += 1) {
        _ = b.update();
        const got = tmp.dir.readFileAlloc(io, "dst/new.txt", a, .limited(64)) catch continue;
        defer a.free(got);
        if (std.mem.eql(u8, got, "fresh") and !b.opsBusy()) break;
        std.Thread.yield() catch {};
    }
    const now_new = try tmp.dir.readFileAlloc(io, "dst/new.txt", a, .limited(64));
    defer a.free(now_new);
    try testing.expectEqualStrings("fresh", now_new);
    const now_old = try tmp.dir.readFileAlloc(io, "dst/old.txt", a, .limited(64));
    defer a.free(now_old);
    try testing.expectEqualStrings("keep", now_old);
}
