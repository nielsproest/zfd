//! Off-thread recursive disk-usage scanner for the treemap. Like the Scanner, one
//! worker thread walks the tree so the render thread never does. It publishes
//! results *incrementally* — an immutable Snapshot after every batch of children —
//! so the treemap fills in and shows a progress bar (done/total) as sizes stream in
//! (matching the Go version), instead of appearing all at once. Newer requests
//! supersede older ones by generation.

const std = @import("std");
const Dir = std.Io.Dir;

pub const Item = struct {
    name: []u8, // owned by the Snapshot
    size: u64,
    is_dir: bool,
};

/// Snapshot is an immutable point-in-time view: the children with the sizes known
/// so far, plus progress. `done == total` means the scan is complete.
pub const Snapshot = struct {
    items: []Item,
    done: usize,
    total: usize,
};

pub const Usage = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    req_path: ?[]u8 = null,
    req_gen: u64 = 0,
    pending: ?Snapshot = null, // latest published, awaiting poll (freed if superseded)
    shutdown: bool = false,
    canceled: bool = false, // user asked to stop the current scan (Cancel button)
    // Lock-free mirror of `shutdown`, checked inside the deep recursive dirSize walk so
    // deinit()'s join returns promptly instead of waiting out a huge subtree (closing a
    // tab mid-treemap used to hang).
    abort: std.atomic.Value(bool) = .init(false),
    worker: ?std.Thread = null,

    pub fn init(io: std.Io, alloc: std.mem.Allocator) Usage {
        return .{ .io = io, .alloc = alloc };
    }

    pub fn start(self: *Usage) !void {
        self.worker = try std.Thread.spawn(.{}, workerLoop, .{self});
    }

    pub fn deinit(self: *Usage) void {
        self.abort.store(true, .monotonic); // bail out of any in-flight dirSize walk
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        if (self.req_path) |p| {
            self.alloc.free(p);
            self.req_path = null;
        }
        if (self.pending) |s| freeSnapshot(self.alloc, s);
        self.pending = null;
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);
        if (self.worker) |w| w.join();
    }

    /// request queues a recursive-usage scan of `path`, superseding any pending one.
    pub fn request(self: *Usage, path: []const u8) !void {
        const dup = try self.alloc.dupe(u8, path);
        self.mutex.lockUncancelable(self.io);
        if (self.req_path) |old| self.alloc.free(old);
        if (self.pending) |s| freeSnapshot(self.alloc, s); // drop stale unpolled snapshot
        self.pending = null;
        self.req_path = dup;
        self.req_gen += 1;
        self.canceled = false; // a fresh scan is not pre-canceled
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);
    }

    /// requestCancel stops the in-flight scan at the next safe point (the treemap's
    /// Cancel button). Partial results already published stay visible.
    pub fn requestCancel(self: *Usage) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.canceled = true;
    }

    /// poll returns the newest Snapshot (render thread, non-blocking); the caller
    /// takes ownership and frees it with `freeSnapshot`.
    pub fn poll(self: *Usage) ?Snapshot {
        if (!self.mutex.tryLock()) return null;
        defer self.mutex.unlock(self.io);
        const s = self.pending;
        self.pending = null;
        return s;
    }

    fn aborted(self: *Usage, gen: u64) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.shutdown or self.req_gen != gen or self.canceled;
    }

    fn workerLoop(self: *Usage) void {
        self.mutex.lockUncancelable(self.io);
        while (true) {
            while (self.req_path == null and !self.shutdown)
                self.cond.waitUncancelable(self.io, &self.mutex);
            if (self.shutdown) {
                self.mutex.unlock(self.io);
                return;
            }
            const path = self.req_path.?;
            self.req_path = null;
            const gen = self.req_gen;
            self.mutex.unlock(self.io);

            self.compute(path, gen);
            self.alloc.free(path);
            self.mutex.lockUncancelable(self.io); // re-hold for the next wait iteration
        }
    }

    fn compute(self: *Usage, path: []const u8, gen: u64) void {
        const io = self.io;
        const a = self.alloc;

        // Enumerate immediate children (names known up front → total is exact).
        const own = enumerate(io, a, path) catch return;
        defer freeItems(a, own);
        const total = own.len;
        const interval = @max(@as(usize, 1), total / 256); // ~256 progress updates max

        self.publish(gen, own, 0, total);
        for (own, 0..) |*it, i| {
            if (self.aborted(gen)) return;
            const child = std.fs.path.join(a, &.{ path, it.name }) catch continue;
            defer a.free(child);
            it.size = if (it.is_dir) dirSize(io, a, child, &self.abort) else fileSize(io, child);
            if ((i + 1) % interval == 0) self.publish(gen, own, i + 1, total);
        }
        if (!self.aborted(gen)) self.publish(gen, own, total, total);
    }

    /// publish copies the worker's current items into an immutable Snapshot and
    /// hands it to the render thread (dropping any unpolled prior one).
    fn publish(self: *Usage, gen: u64, own: []const Item, done: usize, total: usize) void {
        const copy = dupItems(self.alloc, own) catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.req_gen != gen or self.shutdown) {
            freeItems(self.alloc, copy);
            return;
        }
        if (self.pending) |s| freeSnapshot(self.alloc, s); // unpolled → free before overwrite
        self.pending = .{ .items = copy, .done = done, .total = total };
    }
};

fn enumerate(io: std.Io, a: std.mem.Allocator, path: []const u8) ![]Item {
    var dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var list = std.ArrayList(Item).empty;
    errdefer freeItems(a, list.toOwnedSlice(a) catch &.{});
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        try list.append(a, .{ .name = try a.dupe(u8, e.name), .size = 0, .is_dir = e.kind == .directory });
    }
    return list.toOwnedSlice(a);
}

fn fileSize(io: std.Io, path: []const u8) u64 {
    const st = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return 0;
    return st.size;
}

/// dirSize sums the sizes of all regular files under `path`, recursively (symlinks
/// not followed → no cycles). Deep trees recurse; a stack guard is a refinement.
fn dirSize(io: std.Io, alloc: std.mem.Allocator, path: []const u8, abort: *std.atomic.Value(bool)) u64 {
    var total: u64 = 0;
    var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (abort.load(.monotonic)) return total; // shutdown → stop walking immediately
        const child = std.fs.path.join(alloc, &.{ path, e.name }) catch continue;
        defer alloc.free(child);
        switch (e.kind) {
            .directory => total += dirSize(io, alloc, child, abort),
            .sym_link => {},
            else => total += fileSize(io, child),
        }
    }
    return total;
}

fn dupItems(a: std.mem.Allocator, src: []const Item) ![]Item {
    const out = try a.alloc(Item, src.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |it| a.free(it.name);
        a.free(out);
    }
    for (src) |it| {
        out[n] = .{ .name = try a.dupe(u8, it.name), .size = it.size, .is_dir = it.is_dir };
        n += 1;
    }
    return out;
}

fn freeItems(a: std.mem.Allocator, items: []Item) void {
    for (items) |it| a.free(it.name);
    a.free(items);
}

pub fn freeSnapshot(a: std.mem.Allocator, s: Snapshot) void {
    freeItems(a, s.items);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "usage streams snapshots and finishes with correct recursive sizes" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/a", .data = "12345" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b", .data = "12345" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top", .data = "123" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    var u = Usage.init(io, a);
    try u.start();
    defer u.deinit();
    try u.request(root);

    // Poll until a snapshot reports done == total (the final one).
    var final: ?Snapshot = null;
    var spins: usize = 0;
    while (spins < 5_000_000) : (spins += 1) {
        if (u.poll()) |s| {
            if (final) |prev| freeSnapshot(a, prev);
            final = s;
            if (s.done == s.total and s.total > 0) break;
        } else std.Thread.yield() catch {};
    }
    try testing.expect(final != null);
    defer freeSnapshot(a, final.?);
    try testing.expectEqual(@as(usize, 2), final.?.total);
    try testing.expectEqual(@as(usize, 2), final.?.done);
    for (final.?.items) |it| {
        if (std.mem.eql(u8, it.name, "sub")) try testing.expectEqual(@as(u64, 10), it.size);
        if (std.mem.eql(u8, it.name, "top")) try testing.expectEqual(@as(u64, 3), it.size);
    }
}
