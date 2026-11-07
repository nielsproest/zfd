//! DirWatch: the inotify watch on the folder a browser shows, so outside changes
//! reload it. Adding a watch looks the folder up, and on a slow share (rclone, NFS,
//! sshfs) that can take seconds, so it's done on a worker thread, never on the
//! render thread.
//!
//! Watches are added one at a time, by at most one worker: it takes the newest
//! folder asked for, adds its watch, and goes on until nothing is waiting. Two adds
//! in flight at once could race: inotify hands out the same watch id for the same
//! folder, so a stale add taking its watch off could silently kill the current one.
//! A watch whose folder was left before it went in is taken off again.
//!
//! The inotify fd is shared (reference-counted) with the worker, so closing a tab or
//! quitting never waits for a lookup to come back. The worker can outlive the
//! browser that started it, so the shared state lives in page_allocator (never the
//! owner's allocator, which may be gone by then). GUI-free.
//!
//! The folder is read on another thread at the same time, so a change can fall
//! between that read and the watch going in, and never fire. To catch it, the
//! folder's modification time is taken once the watch is in place (`takeAdded`);
//! the browser compares it with the one its listing was read at.

const std = @import("std");
const linux = std.os.linux;
const scan = @import("scan.zig");

const alloc = std.heap.page_allocator;
const no_add = std.math.minInt(i64);

const mask: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
    linux.IN.CLOSE_WRITE | linux.IN.ATTRIB | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
    linux.IN.ONLYDIR | linux.IN.EXCL_UNLINK;

pub const DirWatch = struct {
    shared: ?*Shared = null, // null: no inotify (no auto-refresh; F5 still works)

    const Shared = struct {
        io: std.Io,
        fd: i32,
        mutex: std.Io.Mutex = .init,
        gen: u64 = 0, // (mutex) bumped by each watch(); the newest one wins
        pending: ?[:0]u8 = null, // (mutex) the folder to watch next, for the worker
        working: bool = false, // (mutex) a worker is running
        wd: std.atomic.Value(i32) = .init(-1), // the current folder's watch (-1: none yet)
        refs: std.atomic.Value(u32) = .init(1), // the DirWatch + the worker
        // The folder's mtime when its watch went in (scan.mtimeNs; 0 = unknown), or
        // no_add when that hasn't happened yet or was already taken.
        added: std.atomic.Value(i64) = .init(no_add),

        fn unref(sh: *Shared) void {
            if (sh.refs.fetchSub(1, .acq_rel) != 1) return;
            _ = linux.close(sh.fd);
            alloc.destroy(sh);
        }
    };

    pub fn init(io: std.Io) DirWatch {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (rc > std.math.maxInt(i32)) return .{};
        const sh = alloc.create(Shared) catch {
            _ = linux.close(@intCast(rc));
            return .{};
        };
        sh.* = .{ .io = io, .fd = @intCast(rc) };
        return .{ .shared = sh };
    }

    /// deinit lets go at once; a lookup still in flight finishes on its own.
    pub fn deinit(self: *DirWatch) void {
        const sh = self.shared orelse return;
        sh.mutex.lockUncancelable(sh.io);
        sh.gen += 1; // whatever's being added is stale now
        if (sh.pending) |p| alloc.free(p);
        sh.pending = null;
        sh.mutex.unlock(sh.io);
        sh.unref();
        self.shared = null;
    }

    /// watch switches the watch to `dir` ("" for none). Non-blocking.
    pub fn watch(self: *DirWatch, dir: []const u8) void {
        const sh = self.shared orelse return;
        const path: ?[:0]u8 = if (dir.len == 0) null else alloc.dupeSentinel(u8, dir, 0) catch null;
        sh.mutex.lockUncancelable(sh.io);
        defer sh.mutex.unlock(sh.io);
        sh.gen += 1;
        // The folder left: its changes no longer count (and its watch goes).
        const old = sh.wd.swap(-1, .acq_rel);
        if (old >= 0) _ = linux.inotify_rm_watch(sh.fd, old);
        sh.added.store(no_add, .release);
        if (sh.pending) |p| alloc.free(p); // never got to: superseded
        sh.pending = path;
        if (path == null or sh.working) return; // the running worker picks it up
        sh.working = true;
        _ = sh.refs.fetchAdd(1, .acq_rel);
        const t = std.Thread.spawn(.{}, work, .{sh}) catch {
            sh.working = false;
            _ = sh.refs.fetchSub(1, .acq_rel); // (the DirWatch still holds one: never 0)
            alloc.free(path.?);
            sh.pending = null;
            return;
        };
        t.detach();
    }

    fn work(sh: *Shared) void {
        defer sh.unref();
        while (true) {
            sh.mutex.lockUncancelable(sh.io);
            const path = sh.pending orelse {
                sh.working = false;
                sh.mutex.unlock(sh.io);
                return;
            };
            sh.pending = null;
            const my = sh.gen;
            sh.mutex.unlock(sh.io);
            defer alloc.free(path);

            const rc = linux.inotify_add_watch(sh.fd, path.ptr, mask);
            if (rc > std.math.maxInt(i32)) continue;
            const wd: i32 = @intCast(rc);
            // Taken after the watch is in: any later change fires an event.
            const mtime = scan.mtimeNs(linux.AT.FDCWD, path);
            sh.mutex.lockUncancelable(sh.io);
            if (my == sh.gen) {
                sh.wd.store(wd, .release);
                sh.added.store(mtime, .release);
            } else {
                _ = linux.inotify_rm_watch(sh.fd, wd); // left before it went in
            }
            sh.mutex.unlock(sh.io);
        }
    }

    /// takeAdded returns, once, the folder's modification time from when its watch
    /// went in (0 when it couldn't be read), or null while the watch isn't in yet.
    pub fn takeAdded(self: *DirWatch) ?i64 {
        const sh = self.shared orelse return null;
        const v = sh.added.swap(no_add, .acq_rel);
        return if (v == no_add) null else v;
    }

    /// changed drains the pending events and reports whether any was about the
    /// current folder. Non-blocking (render thread).
    pub fn changed(self: *DirWatch) bool {
        const sh = self.shared orelse return false;
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        var got = false;
        while (true) {
            const rc = linux.read(sh.fd, &buf, buf.len);
            if (rc == 0 or rc > buf.len) break; // EAGAIN (nothing pending) or error
            const cur = sh.wd.load(.acquire);
            var off: usize = 0;
            while (off + @sizeOf(linux.inotify_event) <= rc) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                if (ev.wd == cur or ev.mask & linux.IN.Q_OVERFLOW != 0) got = true;
                off += @sizeOf(linux.inotify_event) + ev.len;
            }
        }
        return got;
    }
};

const testing = std.testing;

fn waitChanged(w: *DirWatch) bool {
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (w.changed()) return true;
        std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

fn waitAdded(w: *DirWatch) ?i64 {
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        if (w.takeAdded()) |mt| return mt;
        std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
    }
    return null;
}

test "a change in the watched folder is seen; one in a folder left isn't" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const a = try std.fs.path.join(testing.allocator, &.{ root, "a" });
    defer testing.allocator.free(a);
    const b = try std.fs.path.join(testing.allocator, &.{ root, "b" });
    defer testing.allocator.free(b);
    var w = DirWatch.init(io);
    defer w.deinit();
    if (w.shared == null) return error.SkipZigTest;
    w.watch(a);
    try testing.expect(waitAdded(&w) != null); // the watch went in on the worker
    try tmp.dir.writeFile(io, .{ .sub_path = "a/x", .data = "1" });
    try testing.expect(waitChanged(&w));
    w.watch(b);
    try testing.expect(waitAdded(&w) != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "a/y", .data = "1" });
    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    try testing.expect(!w.changed());
    try tmp.dir.writeFile(io, .{ .sub_path = "b/z", .data = "1" });
    try testing.expect(waitChanged(&w));
}

test "leaving a folder and coming straight back keeps its watch alive" {
    // The race this guards: two adds of the same folder in flight at once get the
    // same watch id, and the stale one taking its watch off killed the current one.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const a = try std.fs.path.join(testing.allocator, &.{ root, "a" });
    defer testing.allocator.free(a);
    const b = try std.fs.path.join(testing.allocator, &.{ root, "b" });
    defer testing.allocator.free(b);
    var w = DirWatch.init(io);
    defer w.deinit();
    if (w.shared == null) return error.SkipZigTest;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        w.watch(a);
        w.watch(b);
        w.watch(a);
    }
    try testing.expect(waitAdded(&w) != null);
    try tmp.dir.writeFile(io, .{ .sub_path = "a/x", .data = "1" });
    try testing.expect(waitChanged(&w));
}
