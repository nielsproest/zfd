//! Per-folder view settings. A folder you change the layout (list, icons, columns,
//! gallery), sorting, grouping or hidden files in remembers them (`always`: its layout
//! is its own); every other folder uses the defaults, and with `browse` ("Folders
//! inside open this way too") the folders below it take its layout. Lines written
//! before every change was remembered have `always` off: those folders kept only
//! their sorting, and their layout still comes from elsewhere. Persisted as one line
//! per folder under ~/.config/zfd/folders:
//!
//!     <column>\t<ascending 0|1>\t<dirs_first 0|1>\t<show_hidden 0|1>\t<mode>\t<path>
//!
//! (<mode>: bits 0–1 the layout (0 list, 1 grid, 2 columns, 3 gallery), bit 2
//! always, bit 3 browse, bits 4–7 the grouping; lines from before it existed have no
//! such field)
//!
//! (path last, so it may contain anything but a newline). Kept in ZFD's config dir,
//! not as .directory files in the folders, so read-only and network folders work.
//! GUI-free; parse/serialize are unit-tested. Render-thread only (no locking).

const std = @import("std");
const scan = @import("scan.zig");
const Dir = std.Io.Dir;

/// View is what's remembered for a folder.
pub const View = struct {
    sort: scan.SortOrder = .{},
    show_hidden: bool = false,
    mode: Mode = .list, // only a folder's own when `always`
    group: scan.GroupBy = .none, // Use Groups: the sections (stored with the mode)
    always: bool = false, // the layout is the folder's own (every folder set since)
    browse: bool = false, // "Folders inside open this way too"

    pub fn eql(a: View, b: View) bool {
        return a.sort.column == b.sort.column and a.sort.ascending == b.sort.ascending and
            a.sort.dirs_first == b.sort.dirs_first and a.show_hidden == b.show_hidden and a.mode == b.mode and
            a.group == b.group and a.always == b.always and a.browse == b.browse;
    }
};

/// Mode is how a folder's items are laid out.
pub const Mode = enum(u8) { list = 0, grid = 1, columns = 2, gallery = 3 };

/// max_entries bounds the file: past it, the oldest-set folders are forgotten.
pub const max_entries: usize = 4000;

pub const FolderPrefs = struct {
    alloc: std.mem.Allocator,
    default: View = .{},
    // Folder path (owned) → its view, in the order they were last set (oldest first).
    paths: std.ArrayList([]u8) = .empty,
    views: std.ArrayList(View) = .empty,
    // Paths changed (set or reset) since load, merged into the file on save so two
    // ZFD windows don't wipe each other's folders. Owned; `null` view = removed.
    changed: std.StringArrayHashMapUnmanaged(?View) = .empty,
    reset_all: bool = false, // "Use this view for all folders": drop every entry on save

    pub fn init(alloc: std.mem.Allocator) FolderPrefs {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *FolderPrefs) void {
        for (self.paths.items) |p| self.alloc.free(p);
        self.paths.deinit(self.alloc);
        self.views.deinit(self.alloc);
        for (self.changed.keys()) |k| self.alloc.free(k);
        self.changed.deinit(self.alloc);
    }

    /// lookup returns the remembered view for `path`, or null to use the default.
    pub fn lookup(self: *const FolderPrefs, path: []const u8) ?View {
        const i = self.indexOf(path) orelse return null;
        return self.views.items[i];
    }

    /// viewFor is the view `path` should open with (its layout: see modeFor).
    pub fn viewFor(self: *const FolderPrefs, path: []const u8) View {
        return self.lookup(path) orelse self.default;
    }

    /// modeFor is the layout `path` insists on: its own "Always open in", else that of
    /// the nearest enclosing folder with "Browse in"; null = the window's carries on.
    pub fn modeFor(self: *const FolderPrefs, path: []const u8) ?Mode {
        if (self.lookup(path)) |v| if (v.always) return v.mode;
        return self.inheritedMode(path);
    }

    /// inheritedMode is the layout of the nearest folder above `path` whose folders
    /// inside open its way, or null.
    fn inheritedMode(self: *const FolderPrefs, path: []const u8) ?Mode {
        var p = path;
        while (std.fs.path.dirname(p)) |up| : (p = up) {
            if (self.lookup(up)) |v| if (v.always and v.browse) return v.mode;
        }
        return null;
    }

    /// set remembers `v` for `path`. Setting the default view forgets the entry
    /// instead, so folders keep following the default when it later changes (unless
    /// a folder above would then hand it another layout).
    pub fn set(self: *FolderPrefs, path: []const u8, v: View) void {
        var plain = v;
        plain.always = false;
        if (!v.browse and plain.eql(self.default) and self.inheritedMode(path) == null) return self.reset(path);
        if (self.indexOf(path)) |i| {
            const p = self.paths.orderedRemove(i);
            _ = self.views.orderedRemove(i);
            self.appendOwned(p, v);
        } else {
            const p = self.alloc.dupe(u8, path) catch return;
            self.appendOwned(p, v);
        }
        self.noteChange(path, v);
    }

    /// reset forgets `path`'s view; it follows the default again.
    pub fn reset(self: *FolderPrefs, path: []const u8) void {
        if (self.indexOf(path)) |i| {
            self.alloc.free(self.paths.orderedRemove(i));
            _ = self.views.orderedRemove(i);
        }
        self.noteChange(path, null);
    }

    /// useForAll makes `v` the default and forgets every folder's own view.
    pub fn useForAll(self: *FolderPrefs, v: View) void {
        self.default = v;
        for (self.paths.items) |p| self.alloc.free(p);
        self.paths.clearRetainingCapacity();
        self.views.clearRetainingCapacity();
        for (self.changed.keys()) |k| self.alloc.free(k);
        self.changed.clearRetainingCapacity();
        self.reset_all = true;
    }

    fn appendOwned(self: *FolderPrefs, p: []u8, v: View) void {
        self.paths.append(self.alloc, p) catch return self.alloc.free(p);
        self.views.append(self.alloc, v) catch {
            _ = self.paths.pop();
            return self.alloc.free(p);
        };
        while (self.paths.items.len > max_entries) {
            self.alloc.free(self.paths.orderedRemove(0));
            _ = self.views.orderedRemove(0);
        }
    }

    fn noteChange(self: *FolderPrefs, path: []const u8, v: ?View) void {
        if (self.changed.getPtr(path)) |slot| {
            slot.* = v;
            return;
        }
        const k = self.alloc.dupe(u8, path) catch return;
        self.changed.put(self.alloc, k, v) catch self.alloc.free(k);
    }

    fn indexOf(self: *const FolderPrefs, path: []const u8) ?usize {
        for (self.paths.items, 0..) |p, i| if (std.mem.eql(u8, p, path)) return i;
        return null;
    }

    /// parseInto adds the entries in `content` (the file format above).
    pub fn parseInto(self: *FolderPrefs, content: []const u8) void {
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            const v, const path = parseLine(line) orelse continue;
            if (self.indexOf(path)) |i| {
                self.views.items[i] = v;
                continue;
            }
            const p = self.alloc.dupe(u8, path) catch continue;
            self.appendOwned(p, v);
        }
    }

    /// serialize renders every entry in the file format (owned).
    pub fn serialize(self: *const FolderPrefs, alloc: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);
        for (self.paths.items, self.views.items) |p, v| {
            var line: [32]u8 = undefined;
            const flags = @as(u8, @intFromBool(v.always)) << 2 | @as(u8, @intFromBool(v.browse)) << 3;
            try out.appendSlice(alloc, std.mem.print(&line, "{d}\t{d}\t{d}\t{d}\t{d}\t", .{
                @backingInt(v.sort.column), @intFromBool(v.sort.ascending), @intFromBool(v.sort.dirs_first), @intFromBool(v.show_hidden), @as(u8, @backingInt(v.mode)) | flags | @as(u8, @backingInt(v.group)) << 4,
            }) catch unreachable);
            try out.appendSlice(alloc, p);
            try out.append(alloc, '\n');
        }
        return out.toOwnedSlice(alloc);
    }

    /// dirty reports changes not saved yet.
    pub fn dirty(self: *const FolderPrefs) bool {
        return self.changed.count() > 0 or self.reset_all;
    }

    /// takeChanges moves the changes not saved yet into a new FolderPrefs (heap; the
    /// caller saves and frees it, off the render thread), leaving none here.
    pub fn takeChanges(self: *FolderPrefs) !*FolderPrefs {
        const out = try self.alloc.create(FolderPrefs);
        out.* = FolderPrefs.init(self.alloc);
        out.changed = self.changed;
        out.reset_all = self.reset_all;
        self.changed = .empty;
        self.reset_all = false;
        return out;
    }

    /// reloadFrom replaces the entries with those in `content` (the folders file as
    /// another window left it). Only when nothing is waiting to be saved here.
    pub fn reloadFrom(self: *FolderPrefs, content: []const u8) void {
        if (self.dirty()) return;
        for (self.paths.items) |p| self.alloc.free(p);
        self.paths.clearRetainingCapacity();
        self.views.clearRetainingCapacity();
        self.parseInto(content);
    }

    /// reload replaces the entries with the file's (another window changed it). Only
    /// when nothing is waiting to be saved here.
    pub fn reload(self: *FolderPrefs, io: std.Io, path: []const u8) void {
        if (self.dirty()) return;
        for (self.paths.items) |p| self.alloc.free(p);
        self.paths.clearRetainingCapacity();
        self.views.clearRetainingCapacity();
        self.load(io, path);
    }

    /// load reads `path` (missing file = no entries).
    pub fn load(self: *FolderPrefs, io: std.Io, path: []const u8) void {
        const content = Dir.cwd().readFileAlloc(io, path, self.alloc, .limited(4 << 20)) catch return;
        defer self.alloc.free(content);
        self.parseInto(content);
    }

    /// save merges this session's changes into the file as it is now on disk (another
    /// window may have written it meanwhile) and writes it back. Best-effort.
    pub fn save(self: *FolderPrefs, io: std.Io, path: []const u8) void {
        if (self.changed.count() == 0 and !self.reset_all) return;
        var merged = FolderPrefs.init(self.alloc);
        defer merged.deinit();
        if (!self.reset_all) merged.load(io, path);
        var it = self.changed.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.*) |v| {
                if (merged.indexOf(kv.key_ptr.*)) |i| {
                    self.alloc.free(merged.paths.orderedRemove(i));
                    _ = merged.views.orderedRemove(i);
                }
                const p = self.alloc.dupe(u8, kv.key_ptr.*) catch continue;
                merged.appendOwned(p, v);
            } else if (merged.indexOf(kv.key_ptr.*)) |i| {
                self.alloc.free(merged.paths.orderedRemove(i));
                _ = merged.views.orderedRemove(i);
            }
        }
        const text = merged.serialize(self.alloc) catch return;
        defer self.alloc.free(text);
        if (std.fs.path.dirname(path)) |d| Dir.cwd().createDirPath(io, d) catch {};
        Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch return;
        for (self.changed.keys()) |k| self.alloc.free(k);
        self.changed.clearRetainingCapacity();
        self.reset_all = false;
    }
};

fn parseLine(line: []const u8) ?struct { View, []const u8 } {
    var it = std.mem.splitScalar(u8, line, '\t');
    const col_s = it.next() orelse return null;
    const asc_s = it.next() orelse return null;
    const dirs_s = it.next() orelse return null;
    const hid_s = it.next() orelse return null;
    var path = it.rest();
    // The mode field came later: a line without it has the path here already.
    // The mode byte's high nibble is the grouping (added later still; 0 = none).
    var mode: Mode = .list;
    var group: scan.GroupBy = .none;
    var always = false;
    var browse = false;
    if (path.len > 0 and path[0] != '/' and !std.mem.startsWith(u8, path, "recent:")) {
        const tab = std.mem.indexOfScalar(u8, path, '\t') orelse return null;
        const m = std.fmt.parseInt(u8, path[0..tab], 10) catch return null;
        mode = @fromBackingInt(@intCast(m & 0x3));
        always = m & 0x4 != 0;
        browse = m & 0x8 != 0;
        group = if (m >> 4 <= @backingInt(scan.GroupBy.tags)) @fromBackingInt(@intCast(m >> 4)) else .none;
        path = path[tab + 1 ..];
    }
    if (path.len == 0 or path[0] != '/' and !std.mem.startsWith(u8, path, "recent:")) return null;
    const col = std.fmt.parseInt(u8, col_s, 10) catch return null;
    if (col >= @typeInfo(scan.SortColumn).@"enum".field_names.len) return null;
    return .{ .{
        .sort = .{ .column = @fromBackingInt(@intCast(col)), .ascending = eql1(asc_s), .dirs_first = eql1(dirs_s) },
        .show_hidden = eql1(hid_s),
        .mode = mode,
        .group = group,
        .always = always,
        .browse = always and browse,
    }, path };
}

fn eql1(s: []const u8) bool {
    return std.mem.eql(u8, s, "1");
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "folder views round-trip and fall back to the default" {
    var fp = FolderPrefs.init(testing.allocator);
    defer fp.deinit();
    const by_date: View = .{ .sort = .{ .column = .date, .ascending = false } };
    fp.set("/home/me/Downloads", by_date);
    fp.set("/srv/a\tb", .{ .show_hidden = true }); // a tab in the path survives (path is last)
    const grouped: View = .{ .mode = .grid, .group = .date };
    fp.set("/pics", grouped);
    try testing.expect(fp.viewFor("/home/me/Downloads").eql(by_date));
    try testing.expect(fp.viewFor("/elsewhere").eql(.{}));

    const text = try fp.serialize(testing.allocator);
    defer testing.allocator.free(text);
    var back = FolderPrefs.init(testing.allocator);
    defer back.deinit();
    back.parseInto(text);
    try testing.expect(back.viewFor("/home/me/Downloads").eql(by_date));
    try testing.expect(back.viewFor("/srv/a\tb").show_hidden);
    try testing.expect(back.viewFor("/pics").eql(grouped));
}

test "setting the default view forgets the folder; useForAll forgets all" {
    var fp = FolderPrefs.init(testing.allocator);
    defer fp.deinit();
    fp.set("/x", .{ .show_hidden = true });
    try testing.expect(fp.lookup("/x") != null);
    fp.set("/x", .{}); // back to the default → no entry
    try testing.expect(fp.lookup("/x") == null);
    fp.set("/y", .{ .show_hidden = true });
    const by_size: View = .{ .sort = .{ .column = .size } };
    fp.useForAll(by_size);
    try testing.expect(fp.lookup("/y") == null);
    try testing.expect(fp.viewFor("/y").eql(by_size));
}

test "parseLine rejects malformed lines" {
    try testing.expect(parseLine("") == null);
    try testing.expect(parseLine("3\t1\t1\t0\trelative/path") == null);
    try testing.expect(parseLine("99\t1\t1\t0\t/x") == null);
    try testing.expect(parseLine("3\t0\t1\t0\t/x") != null); // a line from before <mode>
    const v, const p = parseLine("3\t0\t1\t0\t1\t/x").?;
    try testing.expectEqual(Mode.grid, v.mode);
    try testing.expectEqualStrings("/x", p);
}

test "a folder's own layout, and the folders inside one that browses" {
    var fp = FolderPrefs.init(testing.allocator);
    defer fp.deinit();
    fp.set("/a", .{ .sort = .{ .column = .size } }); // an old line: sorting only
    try testing.expectEqual(@as(?Mode, null), fp.modeFor("/a"));
    fp.set("/pics", .{ .mode = .grid, .always = true });
    try testing.expectEqual(@as(?Mode, .grid), fp.modeFor("/pics"));
    try testing.expectEqual(@as(?Mode, null), fp.modeFor("/pics/2026")); // just the folder
    fp.set("/pics", .{ .mode = .gallery, .always = true, .browse = true });
    try testing.expectEqual(@as(?Mode, .gallery), fp.modeFor("/pics/2026/oct"));
    fp.set("/pics/2026", .{ .mode = .list, .always = true }); // the nearer folder wins
    try testing.expectEqual(@as(?Mode, .list), fp.modeFor("/pics/2026"));
    fp.set("/b", .{ .always = true }); // the default view: forgotten
    try testing.expect(fp.lookup("/b") == null);

    const text = try fp.serialize(testing.allocator);
    defer testing.allocator.free(text);
    var back = FolderPrefs.init(testing.allocator);
    defer back.deinit();
    back.parseInto(text);
    try testing.expect(back.viewFor("/pics").eql(.{ .mode = .gallery, .always = true, .browse = true }));
    try testing.expectEqual(@as(?Mode, .gallery), back.modeFor("/pics/x"));
    try testing.expectEqual(@as(?Mode, .list), back.modeFor("/pics/2026")); // kept, though it's the default's layout
}
