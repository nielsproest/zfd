//! Folder sizes for the list view (View > Show Folder Sizes): the total of the files
//! directly inside each folder, measured on a worker thread. Never recursive: a
//! subfolder's contents don't count, so a 1 TB tree costs one directory listing, not a
//! walk of all of it (Finder leans on Spotlight's index for its recursive sizes; we
//! have none). Keyed by path + the folder's mtime, so adding or removing a file
//! refreshes it. Render-thread API except the worker.

const std = @import("std");
const core = @import("core");
const c = @import("cimgui.zig").c;

const max_cached = 4000;
const max_queue = 512;
const entry_limit = 50_000; // stop counting a huge folder here (shown as "N+")

pub const Size = core.scan.FilesSize;

const Slot = struct { ready: bool = false, size: Size = .{} };

const Done = struct { key: []u8, size: Size };

pub const Cache = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    slots: std.StringHashMapUnmanaged(Slot) = .empty, // key (owned) → slot; render thread
    // --- shared with the worker, guarded by mutex ---
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.ArrayList([]u8) = .empty, // keys to measure (owned), newest last
    done: std.ArrayList(Done) = .empty,
    shutdown: bool = false,
    thread: ?std.Thread = null,

    pub fn create(io: std.Io, alloc: std.mem.Allocator) !*Cache {
        const self = try alloc.create(Cache);
        self.* = .{ .io = io, .alloc = alloc };
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |e| {
            alloc.destroy(self);
            return e;
        };
        return self;
    }

    pub fn destroy(self: *Cache) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);
        if (self.thread) |t| t.join();
        for (self.queue.items) |k| self.alloc.free(k);
        self.queue.deinit(self.alloc);
        for (self.done.items) |d| self.alloc.free(d.key);
        self.done.deinit(self.alloc);
        var it = self.slots.iterator();
        while (it.next()) |kv| self.alloc.free(kv.key_ptr.*);
        self.slots.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// get returns the size of folder `path` (modified at `mtime`) once measured;
    /// otherwise queues it (once) and returns null.
    pub fn get(self: *Cache, path: []const u8, mtime: i64) ?Size {
        var kb: [std.fs.max_path_bytes + 24]u8 = undefined;
        const key = std.mem.print(&kb, "{d}\x00{s}", .{ mtime, path }) catch return null;
        if (self.slots.get(key)) |slot| return if (slot.ready) slot.size else null;
        if (self.slots.count() >= max_cached) self.dropReady();
        const owned = self.alloc.dupe(u8, key) catch return null;
        self.slots.put(self.alloc, owned, .{}) catch {
            self.alloc.free(owned);
            return null;
        };
        const q = self.alloc.dupe(u8, key) catch return null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.queue.append(self.alloc, q) catch {
            self.alloc.free(q);
            return null;
        };
        if (self.queue.items.len > max_queue) {
            // Scrolled far past these: forget the oldest (asked for again if seen).
            const old = self.queue.orderedRemove(0);
            if (self.slots.fetchRemove(old)) |kv| self.alloc.free(kv.key);
            self.alloc.free(old);
        }
        self.cond.signal(self.io);
        return null;
    }

    /// pump takes in finished measurements. Call once per frame.
    pub fn pump(self: *Cache) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.done.items) |d| {
            if (self.slots.getPtr(d.key)) |slot| slot.* = .{ .ready = true, .size = d.size };
            self.alloc.free(d.key);
        }
        self.done.clearRetainingCapacity();
    }

    /// busy reports whether sizes are still on their way (keeps frames coming).
    pub fn busy(self: *Cache) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.queue.items.len > 0 or self.done.items.len > 0;
    }

    /// dropReady forgets every finished size (they're cheap to measure again);
    /// pending ones stay, since the worker will report them.
    fn dropReady(self: *Cache) void {
        var stale = std.ArrayList([]const u8).empty;
        defer stale.deinit(self.alloc);
        var it = self.slots.iterator();
        while (it.next()) |kv| if (kv.value_ptr.ready) stale.append(self.alloc, kv.key_ptr.*) catch break;
        for (stale.items) |k| if (self.slots.fetchRemove(k)) |kv| self.alloc.free(kv.key);
    }

    fn run(self: *Cache) void {
        self.mutex.lockUncancelable(self.io);
        while (true) {
            while (self.queue.items.len == 0 and !self.shutdown) self.cond.waitUncancelable(self.io, &self.mutex);
            if (self.shutdown) break;
            const key = self.queue.pop().?; // newest first: what's on screen now
            self.mutex.unlock(self.io);

            const sep = std.mem.indexOfScalar(u8, key, 0) orelse 0;
            const size = core.scan.directFilesSize(self.io, key[sep + 1 ..], entry_limit);

            self.mutex.lockUncancelable(self.io);
            self.done.append(self.alloc, .{ .key = key, .size = size }) catch self.alloc.free(key);
            c.glfwPostEmptyEvent();
        }
        self.mutex.unlock(self.io);
    }
};
