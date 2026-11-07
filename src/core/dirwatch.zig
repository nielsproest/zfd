//! DirWatch: the inotify watch on the folder a browser shows, so outside changes
//! reload it. Adding a watch looks the folder up, and on a slow share (rclone, NFS,
//! sshfs) that can take seconds, so it's done on a short-lived thread, never on the
//! render thread. Newer folders supersede older ones by generation: a watch whose
//! folder has been left before it was added is taken off again. The inotify fd is
//! shared (reference-counted) with those threads, so closing a tab or quitting never
//! waits for a lookup to come back. GUI-free.

const std = @import("std");
const linux = std.os.linux;

const mask: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
    linux.IN.CLOSE_WRITE | linux.IN.ATTRIB | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
    linux.IN.ONLYDIR | linux.IN.EXCL_UNLINK;

pub const DirWatch = struct {
    shared: ?*Shared = null, // null: no inotify (no auto-refresh; F5 still works)

    const Shared = struct {
        io: std.Io,
        alloc: std.mem.Allocator,
        fd: i32,
        mutex: std.Io.Mutex = .init,
        gen: u64 = 0, // (mutex) bumped by each watch(); the newest one wins
        wd: std.atomic.Value(i32) = .init(-1), // the current folder's watch (-1: none yet)
        refs: std.atomic.Value(u32) = .init(1), // the DirWatch + each adding thread

        fn unref(sh: *Shared) void {
            if (sh.refs.fetchSub(1, .acq_rel) != 1) return;
            _ = linux.close(sh.fd);
            sh.alloc.destroy(sh);
        }
    };

    pub fn init(io: std.Io, alloc: std.mem.Allocator) DirWatch {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (rc > std.math.maxInt(i32)) return .{};
        const sh = alloc.create(Shared) catch {
            _ = linux.close(@intCast(rc));
            return .{};
        };
        sh.* = .{ .io = io, .alloc = alloc, .fd = @intCast(rc) };
        return .{ .shared = sh };
    }

    /// deinit lets go at once; a lookup still in flight finishes on its own.
    pub fn deinit(self: *DirWatch) void {
        const sh = self.shared orelse return;
        sh.mutex.lockUncancelable(sh.io);
        sh.gen += 1; // whatever's being added is stale now
        sh.mutex.unlock(sh.io);
        sh.unref();
        self.shared = null;
    }

    /// watch switches the watch to `dir` ("" for none). Non-blocking.
    pub fn watch(self: *DirWatch, dir: []const u8) void {
        const sh = self.shared orelse return;
        sh.mutex.lockUncancelable(sh.io);
        sh.gen += 1;
        const my = sh.gen;
        // The folder left: its changes no longer count (and its watch goes).
        const old = sh.wd.swap(-1, .acq_rel);
        if (old >= 0) _ = linux.inotify_rm_watch(sh.fd, old);
        sh.mutex.unlock(sh.io);
        if (dir.len == 0) return;
        const path = sh.alloc.dupeSentinel(u8, dir, 0) catch return;
        _ = sh.refs.fetchAdd(1, .acq_rel);
        const t = std.Thread.spawn(.{}, add, .{ sh, path, my }) catch {
            sh.alloc.free(path);
            sh.unref();
            return;
        };
        t.detach();
    }

    fn add(sh: *Shared, path: [:0]u8, my: u64) void {
        defer sh.unref();
        defer sh.alloc.free(path);
        const rc = linux.inotify_add_watch(sh.fd, path.ptr, mask);
        if (rc > std.math.maxInt(i32)) return;
        const wd: i32 = @intCast(rc);
        sh.mutex.lockUncancelable(sh.io);
        defer sh.mutex.unlock(sh.io);
        if (my == sh.gen) {
            sh.wd.store(wd, .release);
        } else if (wd != sh.wd.load(.acquire)) {
            _ = linux.inotify_rm_watch(sh.fd, wd); // left before it was added
        }
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
    var w = DirWatch.init(io, testing.allocator);
    defer w.deinit();
    if (w.shared == null) return error.SkipZigTest;
    w.watch(a);
    // The watch is added on its own thread: wait for it.
    var i: usize = 0;
    while (w.shared.?.wd.load(.acquire) < 0 and i < 200) : (i += 1) std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    try tmp.dir.writeFile(io, .{ .sub_path = "a/x", .data = "1" });
    try testing.expect(waitChanged(&w));
    w.watch(b);
    i = 0;
    while (w.shared.?.wd.load(.acquire) < 0 and i < 200) : (i += 1) std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    try tmp.dir.writeFile(io, .{ .sub_path = "a/y", .data = "1" });
    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
    try testing.expect(!w.changed());
    try tmp.dir.writeFile(io, .{ .sub_path = "b/z", .data = "1" });
    try testing.expect(waitChanged(&w));
}
