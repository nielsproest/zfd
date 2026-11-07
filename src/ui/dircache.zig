//! DirCache: listings of folders other than the browser's own — the column view's
//! ancestor and preview columns. One worker thread reads them (scan.readDir, never on
//! the render thread); the UI asks with `get`, which returns what's cached (possibly a
//! few seconds old, re-read in the background) or null while the first read runs.
//! Small and bounded: the least recently used listings are dropped past `max_dirs`.

const std = @import("std");
const core = @import("core");
const scan = core.scan;
const c = @import("cimgui.zig").c;

const max_dirs = 24;
pub const gets_per_frame = 16;
const refresh_ns = 3 * std.time.ns_per_s; // re-read a shown listing this often

pub const Dir = struct {
    listing: ?scan.Listing = null, // null until read (or if unreadable)
    failed: bool = false,
    loaded_ns: u64 = 0,
    used: u64 = 0, // frame last asked for
    pending: bool = false,
    // Sorted/filtered view of listing.entries (indices), for `order` + `hidden`.
    view: std.ArrayList(usize) = .empty,
    view_order: scan.SortOrder = .{},
    view_hidden: bool = false,
    view_valid: bool = false,

    /// sorted returns the entries' indices sorted by `order`, dotfiles dropped unless
    /// `hidden` (recomputed only when those or the listing change).
    pub fn sorted(self: *Dir, alloc: std.mem.Allocator, order: scan.SortOrder, hidden: bool) []const usize {
        const l = self.listing orelse return &.{};
        const same = self.view_valid and self.view_hidden == hidden and self.view_order.column == order.column and
            self.view_order.ascending == order.ascending and self.view_order.dirs_first == order.dirs_first;
        if (!same) {
            self.view.clearRetainingCapacity();
            for (l.entries, 0..) |e, i| {
                if (!hidden and e.name.len > 0 and e.name[0] == '.') continue;
                self.view.append(alloc, i) catch break;
            }
            scan.sortView(self.view.items, l.entries, order);
            self.view_order = order;
            self.view_hidden = hidden;
            self.view_valid = true;
        }
        return self.view.items;
    }

    fn deinit(self: *Dir, alloc: std.mem.Allocator) void {
        if (self.listing) |l| l.deinit(alloc);
        self.view.deinit(alloc);
    }
};

const Done = struct { path: []u8, result: anyerror!scan.Listing };

pub const DirCache = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    dirs: std.StringHashMapUnmanaged(Dir) = .empty, // render thread
    frame: u64 = 0,
    // --- shared, guarded by mutex ---
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.ArrayList([]u8) = .empty,
    done: std.ArrayList(Done) = .empty,
    shutdown: bool = false,
    thread: ?std.Thread = null,

    pub fn create(io: std.Io, alloc: std.mem.Allocator) !*DirCache {
        const self = try alloc.create(DirCache);
        self.* = .{ .io = io, .alloc = alloc };
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |e| {
            alloc.destroy(self);
            return e;
        };
        return self;
    }

    pub fn destroy(self: *DirCache) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);
        if (self.thread) |t| t.join();
        for (self.queue.items) |p| self.alloc.free(p);
        self.queue.deinit(self.alloc);
        for (self.done.items) |d| {
            self.alloc.free(d.path);
            if (d.result) |l| l.deinit(self.alloc) else |_| {}
        }
        self.done.deinit(self.alloc);
        var it = self.dirs.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.deinit(self.alloc);
            self.alloc.free(kv.key_ptr.*);
        }
        self.dirs.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// get returns the cached folder `path` (requesting a read if it's new or stale).
    /// The pointer is valid until the next pump: pump reserves room for
    /// `gets_per_frame` new folders, so adding them can't move earlier results.
    pub fn get(self: *DirCache, path: []const u8) ?*Dir {
        const now = monoNs();
        if (self.dirs.get(path) == null and self.dirs.available == 0) return null; // reserve used up
        if (self.dirs.getPtr(path)) |d| {
            d.used = self.frame;
            if (!d.pending and now -| d.loaded_ns > refresh_ns) self.request(path, d);
            return d;
        }
        const key = self.alloc.dupe(u8, path) catch return null;
        self.dirs.put(self.alloc, key, .{ .used = self.frame }) catch {
            self.alloc.free(key);
            return null;
        };
        const d = self.dirs.getPtr(key).?;
        self.request(path, d);
        return d;
    }

    fn request(self: *DirCache, path: []const u8, d: *Dir) void {
        const p = self.alloc.dupe(u8, path) catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.queue.append(self.alloc, p) catch {
            self.alloc.free(p);
            return;
        };
        d.pending = true;
        self.cond.signal(self.io);
    }

    /// pump folds in finished reads and drops unused listings. Once per frame.
    pub fn pump(self: *DirCache) void {
        self.frame +%= 1;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const d: ?Done = if (self.done.items.len > 0) self.done.orderedRemove(0) else null;
            self.mutex.unlock(self.io);
            const done = d orelse break;
            defer self.alloc.free(done.path);
            const slot = self.dirs.getPtr(done.path) orelse {
                if (done.result) |l| l.deinit(self.alloc) else |_| {}
                continue;
            };
            slot.pending = false;
            slot.loaded_ns = monoNs();
            if (done.result) |l| {
                if (slot.listing) |old| old.deinit(self.alloc);
                slot.listing = l;
                slot.failed = false;
                slot.view_valid = false;
            } else |_| slot.failed = true;
        }
        while (self.dirs.count() > max_dirs) {
            var oldest: ?[]const u8 = null;
            var oldest_used: u64 = std.math.maxInt(u64);
            var it = self.dirs.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.pending) continue;
                if (kv.value_ptr.used < oldest_used) {
                    oldest_used = kv.value_ptr.used;
                    oldest = kv.key_ptr.*;
                }
            }
            const k = oldest orelse break;
            if (oldest_used == self.frame) break; // all in use this frame
            var kv = self.dirs.fetchRemove(k).?;
            kv.value.deinit(self.alloc);
            self.alloc.free(kv.key);
        }
        self.dirs.ensureUnusedCapacity(self.alloc, gets_per_frame) catch {};
    }

    fn run(self: *DirCache) void {
        self.mutex.lockUncancelable(self.io);
        while (true) {
            while (self.queue.items.len == 0 and !self.shutdown) self.cond.waitUncancelable(self.io, &self.mutex);
            if (self.shutdown) break;
            const path = self.queue.pop().?; // newest first
            self.mutex.unlock(self.io);
            const result = scan.readDir(self.io, self.alloc, path);
            self.mutex.lockUncancelable(self.io);
            self.done.append(self.alloc, .{ .path = path, .result = result }) catch {
                self.alloc.free(path);
                if (result) |l| l.deinit(self.alloc) else |_| {}
            };
            c.glfwPostEmptyEvent();
        }
        self.mutex.unlock(self.io);
    }
};

fn monoNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
