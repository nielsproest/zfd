//! The second half of opening a folder. The scanner hands over names and kinds as
//! soon as `readdir` has them (fast, even on a network share); this fills in each
//! entry's details (statx, colour tags, a link's target) with a small pool of workers,
//! the rows on screen first. As GoFileDialog did it: the render thread never touches
//! the disk, it only folds finished results in once per frame, by index.
//!
//! Lifetime: the workers share a heap block with the Filler (reference-counted);
//! `cancel` lets the folder go at once, and the workers drop out between entries.
//! GUI-free; the results are applied by browser.zig.

const std = @import("std");
const scan = @import("scan.zig");

/// Details is what one worker found for entry `idx` (link_target owned, "" if none).
pub const Details = struct {
    idx: u32,
    size: u64 = 0,
    mtime_secs: i64 = 0,
    atime_secs: i64 = 0,
    ctime_secs: i64 = 0,
    btime_secs: i64 = 0,
    mode: u16 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    inode: u64 = 0,
    nlink: u32 = 0,
    tags: @import("tags.zig").Mask = 0,
    link_target: []u8 = &.{},

    /// apply copies the details onto `e` (taking the link target).
    pub fn apply(d: Details, e: *scan.Entry) void {
        e.size = d.size;
        e.mtime_secs = d.mtime_secs;
        e.atime_secs = d.atime_secs;
        e.ctime_secs = d.ctime_secs;
        e.btime_secs = d.btime_secs;
        e.mode = d.mode;
        e.uid = d.uid;
        e.gid = d.gid;
        e.inode = d.inode;
        e.nlink = d.nlink;
        e.tags = d.tags;
        e.pending = false;
        if (d.link_target.len > 0) e.link_target = d.link_target;
    }
};

/// workers is how many look entries up at once: a few, so a network share's round
/// trips overlap, without flooding a local disk.
pub fn defaultWorkers() usize {
    const n = std.Thread.getCpuCount() catch 2;
    return std.math.clamp(n / 2, 2, 6);
}

pub const Filler = struct {
    shared: *Shared,

    const Shared = struct {
        io: std.Io,
        alloc: std.mem.Allocator,
        wake: ?*const fn () void,
        dir: []u8, // owned
        names: [][]u8, // owned copies (the listing's may be freed first)
        kinds: []scan.Kind,
        state: []std.atomic.Value(u8), // 0 to do, 1 taken
        next: std.atomic.Value(usize) = .init(0), // the next index in order
        canceled: std.atomic.Value(bool) = .init(false),
        refs: std.atomic.Value(u32), // the Filler + each worker
        working: std.atomic.Value(u32), // workers still going

        mutex: std.Io.Mutex = .init,
        // --- guarded by mutex ---
        prio: std.ArrayList(u32) = .empty, // rows on screen: looked up first (newest last)
        results: std.ArrayList(Details) = .empty,
        // ------------------------

        fn unref(sh: *Shared) void {
            if (sh.refs.fetchSub(1, .acq_rel) != 1) return;
            const a = sh.alloc;
            for (sh.results.items) |d| if (d.link_target.len > 0) a.free(d.link_target);
            sh.results.deinit(a);
            sh.prio.deinit(a);
            for (sh.names) |n| a.free(n);
            a.free(sh.names);
            a.free(sh.kinds);
            a.free(sh.state);
            a.free(sh.dir);
            a.destroy(sh);
        }
    };

    /// start looks up the details of `entries` (in folder `dir`) with `workers`
    /// threads. `wake` (thread-safe) nudges an idle UI loop when results arrive.
    pub fn start(io: std.Io, alloc: std.mem.Allocator, dir: []const u8, entries: []const scan.Entry, workers: usize, wake: ?*const fn () void) !Filler {
        const n = entries.len;
        const sh = try alloc.create(Shared);
        errdefer alloc.destroy(sh);
        const names = try alloc.alloc([]u8, n);
        var made: usize = 0;
        errdefer {
            for (names[0..made]) |nm| alloc.free(nm);
            alloc.free(names);
        }
        for (entries, 0..) |e, i| {
            names[i] = try alloc.dupe(u8, e.name);
            made += 1;
        }
        const kinds = try alloc.alloc(scan.Kind, n);
        errdefer alloc.free(kinds);
        for (entries, kinds) |e, *k| k.* = e.kind;
        const state = try alloc.alloc(std.atomic.Value(u8), n);
        errdefer alloc.free(state);
        for (state) |*s| s.* = .init(0);
        const d = try alloc.dupe(u8, dir);
        const w: u32 = @intCast(@max(1, @min(workers, @max(n, 1))));
        sh.* = .{ .io = io, .alloc = alloc, .wake = wake, .dir = d, .names = names, .kinds = kinds, .state = state, .refs = .init(1), .working = .init(0) };
        var k: u32 = 0;
        while (k < w) : (k += 1) {
            _ = sh.refs.fetchAdd(1, .acq_rel);
            _ = sh.working.fetchAdd(1, .acq_rel);
            const t = std.Thread.spawn(.{}, work, .{sh}) catch {
                _ = sh.refs.fetchSub(1, .acq_rel);
                _ = sh.working.fetchSub(1, .acq_rel);
                break;
            };
            t.detach();
        }
        return .{ .shared = sh };
    }

    /// stop asks the workers to stop after the entry they're on, keeping hold (cancel
    /// or cancelWait lets go once they have: see stopped).
    pub fn stop(self: Filler) void {
        self.shared.canceled.store(true, .release);
    }

    /// stopped reports whether every worker has finished.
    pub fn stopped(self: Filler) bool {
        return self.shared.working.load(.acquire) == 0;
    }

    /// cancel lets go of the lookups: the workers stop after the entry they're on.
    /// When they're all done already, it waits the moment it takes them to let go, so
    /// the memory is freed now rather than by the last of them a little later.
    pub fn cancel(self: Filler) void {
        self.cancelWait(0);
    }

    /// cancelWait is cancel that also waits up to `ms` for working ones to stop (a
    /// folder closing for good: its tab, or the app), so nothing outlives what it uses.
    /// A share that hangs a lookup isn't waited for past that.
    pub fn cancelWait(self: Filler, ms: u64) void {
        const sh = self.shared;
        sh.canceled.store(true, .release);
        var waited: u64 = 0;
        while (sh.working.load(.acquire) != 0 and waited < ms * 10) : (waited += 1) nap(sh.io, 100);
        // Stopped workers are only a step from letting go.
        if (sh.working.load(.acquire) == 0) {
            var spins: usize = 0;
            while (sh.refs.load(.acquire) > 1 and spins < 10_000) : (spins += 1) nap(sh.io, 10);
        }
        sh.unref();
    }

    /// want moves entry `idx` (a row on screen) to the front of the line.
    pub fn want(self: Filler, idx: usize) void {
        const sh = self.shared;
        if (idx >= sh.state.len or sh.state[idx].load(.acquire) != 0) return;
        sh.mutex.lockUncancelable(sh.io);
        defer sh.mutex.unlock(sh.io);
        if (sh.prio.items.len > 4096) return; // a scroll through thousands: order is fine
        sh.prio.append(sh.alloc, @intCast(idx)) catch {};
    }

    /// take moves up to `max` finished results into `out` (render thread).
    pub fn take(self: Filler, out: *std.ArrayList(Details), max: usize) void {
        const sh = self.shared;
        sh.mutex.lockUncancelable(sh.io);
        defer sh.mutex.unlock(sh.io);
        const n = @min(max, sh.results.items.len);
        if (n == 0) return;
        out.appendSlice(sh.alloc, sh.results.items[0..n]) catch return;
        std.mem.copyForwards(Details, sh.results.items[0 .. sh.results.items.len - n], sh.results.items[n..]);
        sh.results.shrinkRetainingCapacity(sh.results.items.len - n);
    }

    /// finished: every worker is done and every result has been taken.
    pub fn finished(self: Filler) bool {
        const sh = self.shared;
        if (sh.working.load(.acquire) != 0) return false;
        sh.mutex.lockUncancelable(sh.io);
        defer sh.mutex.unlock(sh.io);
        return sh.results.items.len == 0;
    }

    fn nap(io: std.Io, us: i64) void {
        std.Io.sleep(io, .fromMicroseconds(us), .awake) catch {};
    }

    fn work(sh: *Shared) void {
        defer {
            _ = sh.working.fetchSub(1, .acq_rel);
            if (sh.wake) |w| w();
            sh.unref();
        }
        var dir = std.Io.Dir.cwd().openDir(sh.io, sh.dir, .{}) catch return;
        defer dir.close(sh.io);
        var since_wake: usize = 0;
        while (!sh.canceled.load(.acquire)) {
            const idx = nextIndex(sh) orelse break;
            var e = scan.Entry{ .name = sh.names[idx], .kind = sh.kinds[idx] };
            scan.fillDetails(sh.alloc, dir, sh.names[idx], &e);
            const d = Details{
                .idx = @intCast(idx),
                .size = e.size,
                .mtime_secs = e.mtime_secs,
                .atime_secs = e.atime_secs,
                .ctime_secs = e.ctime_secs,
                .btime_secs = e.btime_secs,
                .mode = e.mode,
                .uid = e.uid,
                .gid = e.gid,
                .inode = e.inode,
                .nlink = e.nlink,
                .tags = e.tags,
                .link_target = e.link_target,
            };
            sh.mutex.lockUncancelable(sh.io);
            sh.results.append(sh.alloc, d) catch if (d.link_target.len > 0) sh.alloc.free(d.link_target);
            sh.mutex.unlock(sh.io);
            // Wake the UI now and then, not per entry.
            since_wake += 1;
            if (since_wake >= 256) {
                since_wake = 0;
                if (sh.wake) |w| w();
            }
        }
    }

    /// nextIndex claims the next entry: a row on screen if one's waiting, else the
    /// next in order. Null when there's nothing left.
    fn nextIndex(sh: *Shared) ?usize {
        while (true) {
            sh.mutex.lockUncancelable(sh.io);
            const p = sh.prio.pop();
            sh.mutex.unlock(sh.io);
            const idx = if (p) |i| @as(usize, i) else blk: {
                const i = sh.next.fetchAdd(1, .acq_rel);
                if (i >= sh.state.len) return null;
                break :blk i;
            };
            if (sh.state[idx].cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) return idx;
        }
    }
};

// ---------------------------------------------------------------------------
const testing = std.testing;

test "the filler fills every entry's details" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "12345" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b", .data = "123" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var l = try scan.readDirOpts(io, testing.allocator, root, null, false);
    defer l.deinit(testing.allocator);
    try testing.expect(l.needs_details);
    for (l.entries) |e| try testing.expectEqual(@as(u64, 0), e.size);
    const f = try Filler.start(io, testing.allocator, root, l.entries, 2, null);
    defer f.cancel();
    var got = std.ArrayList(Details).empty;
    defer got.deinit(testing.allocator);
    var spins: usize = 0;
    while (!f.finished() and spins < 100_000) : (spins += 1) f.take(&got, 100);
    f.take(&got, 100);
    try testing.expectEqual(@as(usize, 2), got.items.len);
    for (got.items) |d| d.apply(&l.entries[d.idx]);
    var total: u64 = 0;
    for (l.entries) |e| total += e.size;
    try testing.expectEqual(@as(u64, 8), total);
}
