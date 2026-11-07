//! Browsing into archives: opening a zip/tar/7z extracts it (in the background, with
//! the usual progress) into a private cache folder, and the browser simply shows that
//! folder — so everything works inside it as in any folder: open, copy out, Quick
//! Look, thumbnails, drag. The Registry remembers which archive each cache folder
//! came from, so the UI can say where you are, Up at the top leaves to the archive's
//! own folder, and an archive opened twice is extracted once.
//!
//! Cache folders live under <cache>/zfd/archives/<pid>/<n>: per process, removed on
//! exit, and folders of processes that no longer run are cleared at startup.
//! Shared by every tab (owned by the shell). Render thread only. GUI-free.

const std = @import("std");
const Dir = std.Io.Dir;

pub const Opened = struct {
    src: []u8, // the archive (absolute; owned)
    root: []u8, // its cache folder (owned)
};

pub const Registry = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    base: []u8, // <cache>/zfd/archives/<pid> (owned)
    opened: std.ArrayList(Opened) = .empty,
    next: u32 = 0,

    /// init prepares the registry under `cache_home` (e.g. ~/.cache) and clears the
    /// cache folders left by ZFD processes that are gone.
    pub fn init(io: std.Io, alloc: std.mem.Allocator, cache_home: []const u8) !Registry {
        const parent = try std.fs.path.join(alloc, &.{ cache_home, "zfd", "archives" });
        defer alloc.free(parent);
        clearStale(io, alloc, parent);
        var pb: [16]u8 = undefined;
        const pid = std.mem.print(&pb, "{d}", .{std.os.linux.getpid()}) catch unreachable;
        return .{ .io = io, .alloc = alloc, .base = try std.fs.path.join(alloc, &.{ parent, pid }) };
    }

    /// deinit removes every cache folder this process made.
    pub fn deinit(self: *Registry) void {
        if (self.opened.items.len > 0) Dir.cwd().deleteTree(self.io, self.base) catch {};
        for (self.opened.items) |o| {
            self.alloc.free(o.src);
            self.alloc.free(o.root);
        }
        self.opened.deinit(self.alloc);
        self.alloc.free(self.base);
    }

    /// rootOf returns the cache folder already holding `src`, if it was opened before.
    pub fn rootOf(self: *const Registry, src: []const u8) ?[]const u8 {
        for (self.opened.items) |o| if (std.mem.eql(u8, o.src, src)) return o.root;
        return null;
    }

    /// add reserves (and creates) a new cache folder for archive `src`; the caller
    /// extracts into it. Returns the folder (owned by the registry).
    pub fn add(self: *Registry, src: []const u8) ![]const u8 {
        var nb: [16]u8 = undefined;
        const n = std.mem.print(&nb, "{d}", .{self.next}) catch unreachable;
        self.next += 1;
        const root = try std.fs.path.join(self.alloc, &.{ self.base, n });
        errdefer self.alloc.free(root);
        try Dir.cwd().createDirPath(self.io, root);
        const s = try self.alloc.dupe(u8, src);
        errdefer self.alloc.free(s);
        try self.opened.append(self.alloc, .{ .src = s, .root = root });
        return root;
    }

    /// containing returns the archive whose cache folder holds `path` (or is it).
    pub fn containing(self: *const Registry, path: []const u8) ?Opened {
        for (self.opened.items) |o| {
            if (std.mem.eql(u8, path, o.root)) return o;
            if (path.len > o.root.len and std.mem.startsWith(u8, path, o.root) and path[o.root.len] == '/') return o;
        }
        return null;
    }

    /// atRoot returns the archive whose cache folder is exactly `path`.
    pub fn atRoot(self: *const Registry, path: []const u8) ?Opened {
        for (self.opened.items) |o| if (std.mem.eql(u8, path, o.root)) return o;
        return null;
    }
};

/// clearStale deletes <parent>/<pid> folders whose process no longer exists.
fn clearStale(io: std.Io, alloc: std.mem.Allocator, parent: []const u8) void {
    var d = Dir.cwd().openDir(io, parent, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        const pid = std.fmt.parseInt(i32, e.name, 10) catch continue;
        // kill(pid, 0): ESRCH = no such process. Anything else (alive, or not ours) stays.
        const rc = std.os.linux.kill(pid, @fromBackingInt(0));
        if (std.os.linux.errno(rc) != .SRCH) continue;
        const p = std.fs.path.join(alloc, &.{ parent, e.name }) catch continue;
        defer alloc.free(p);
        Dir.cwd().deleteTree(io, p) catch {};
    }
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "registry maps cache folders back to their archive" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const cache = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(cache);

    var reg = try Registry.init(io, a, cache);
    defer reg.deinit();
    try testing.expect(reg.rootOf("/x/photos.zip") == null);
    const root = try reg.add("/x/photos.zip");
    try testing.expectEqualStrings(root, reg.rootOf("/x/photos.zip").?);
    try testing.expect(Dir.cwd().statFile(io, root, .{}) != error.FileNotFound);

    const inner = try std.fs.path.join(a, &.{ root, "2025", "beach.jpg" });
    defer a.free(inner);
    try testing.expectEqualStrings("/x/photos.zip", reg.containing(inner).?.src);
    try testing.expect(reg.atRoot(inner) == null);
    try testing.expectEqualStrings("/x/photos.zip", reg.atRoot(root).?.src);
    // A sibling whose name merely starts with the root's isn't inside it.
    const sibling = try a.print("{s}0", .{root});
    defer a.free(sibling);
    try testing.expect(reg.containing(sibling) == null);
}
