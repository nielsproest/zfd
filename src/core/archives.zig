//! Temporary copies of files taken out of archives. Archives are browsed in place
//! (arcfs.zig) and never unpacked to look inside, but a file you open in its app,
//! drag into another app, or preview with an outside tool (a PDF, a video) has to
//! be a real file: just that one is extracted, into a fresh folder here.
//!
//! The folders live under <cache>/zfd/opened/<pid>/<n>: per process, removed on
//! exit, and those of processes that no longer run are cleared at startup.
//! Shared by every tab (owned by the shell). GUI-free.

const std = @import("std");
const Dir = std.Io.Dir;
const arcfs = @import("arcfs.zig");
const Progress = @import("progress.zig").Progress;

pub const TempFiles = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    base: []u8, // <cache>/zfd/opened/<pid> (owned)
    next: std.atomic.Value(u32) = .init(0),

    /// init prepares the folder under `cache_home` (e.g. ~/.cache) and clears what
    /// ZFD processes that are gone left behind.
    pub fn init(io: std.Io, alloc: std.mem.Allocator, cache_home: []const u8) !TempFiles {
        const parent = try std.fs.path.join(alloc, &.{ cache_home, "zfd", "opened" });
        defer alloc.free(parent);
        clearStale(io, alloc, parent);
        // Archives used to be unpacked whole under zfd/archives: clear those too.
        const old = try std.fs.path.join(alloc, &.{ cache_home, "zfd", "archives" });
        defer alloc.free(old);
        clearStale(io, alloc, old);
        var pb: [16]u8 = undefined;
        const pid = std.mem.print(&pb, "{d}", .{std.os.linux.getpid()}) catch unreachable;
        return .{ .io = io, .alloc = alloc, .base = try std.fs.path.join(alloc, &.{ parent, pid }) };
    }

    /// deinit removes every folder this process made.
    pub fn deinit(self: *TempFiles) void {
        if (self.next.load(.acquire) > 0) Dir.cwd().deleteTree(self.io, self.base) catch {};
        self.alloc.free(self.base);
    }

    /// newDir makes a fresh, empty folder for one file (owned by the caller to free;
    /// the folder itself goes at exit). Any thread.
    pub fn newDir(self: *TempFiles, alloc: std.mem.Allocator) ![]u8 {
        const n = self.next.fetchAdd(1, .acq_rel);
        var nb: [16]u8 = undefined;
        const ns = std.mem.print(&nb, "{d}", .{n}) catch unreachable;
        const dir = try std.fs.path.join(alloc, &.{ self.base, ns });
        errdefer alloc.free(dir);
        try Dir.cwd().createDirPath(self.io, dir);
        return dir;
    }

    /// takeOut extracts the one entry `path` points to inside an archive into a fresh
    /// folder here, and returns where it landed (owned by the caller). Blocks while
    /// it extracts: worker threads (or the drag loop, which holds the UI anyway).
    pub fn takeOut(self: *TempFiles, alloc: std.mem.Allocator, path: []const u8, prog: ?*Progress) ![]u8 {
        const dir = try self.newDir(alloc);
        defer alloc.free(dir);
        try arcfs.extract(&.{path}, dir, prog);
        return std.fs.path.join(alloc, &.{ dir, std.fs.path.basename(path) });
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

test "temporary folders are fresh, and gone with the process's own" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const cache = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(cache);

    var t = try TempFiles.init(io, a, cache);
    const d1 = try t.newDir(a);
    defer a.free(d1);
    const d2 = try t.newDir(a);
    defer a.free(d2);
    try testing.expect(!std.mem.eql(u8, d1, d2));
    _ = try Dir.cwd().statFile(io, d1, .{});
    t.deinit();
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, d1, .{}));
}
