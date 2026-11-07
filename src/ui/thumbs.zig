//! Thumbnails for the grid view: image files decoded small (stb_image, see
//! preview_img.c) on a worker thread and kept as GL textures, keyed by path + mtime so
//! an edited image refreshes. Requests are served newest-first (what's on screen now
//! beats what scrolled past), the queue is bounded, and the cache evicts the least
//! recently drawn textures past `max_cached`. Render-thread API except the worker.

const std = @import("std");
const core = @import("core");
const c = @import("cimgui.zig").c;

const image = @import("image.zig");
const zfd_image_free = image.zfd_image_free;
extern fn zfd_texture_upload(px: [*]const u8, w: c_int, h: c_int) c_uint;
extern fn zfd_texture_free(tex: c_uint) void;

pub const thumb_px = 256; // decoded size (longest side): sharp up to a 2x-zoomed grid
const max_cached = 600;
const max_queue = 256;
const uploads_per_frame = 8; // spread GL uploads so scrolling a photo folder stays smooth
const max_file_bytes = 80 << 20; // don't decode giant files just for a thumbnail

pub const Thumb = struct { tex: c_uint, w: f32, h: f32, full_w: u32 = 0, full_h: u32 = 0 }; // full_*: the image's own size

const Slot = struct {
    state: enum { pending, ready, failed },
    thumb: Thumb = .{ .tex = 0, .w = 0, .h = 0 },
    used: u64 = 0, // frame it was last drawn
};

const Done = struct { key: []u8, px: ?[*]u8, w: c_int, h: c_int, full_w: c_int = 0, full_h: c_int = 0 };

pub const Cache = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    slots: std.StringHashMapUnmanaged(Slot) = .empty, // key (owned) → slot; render thread
    frame: u64 = 0,
    // --- shared with the worker, guarded by mutex ---
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.ArrayList([]u8) = .empty, // keys to decode (owned), newest last
    done: std.ArrayList(Done) = .empty,
    shutdown: bool = false,
    threads: [max_workers]?std.Thread = @splat(null),

    /// max_workers caps the pool (Settings > Advanced picks up to this many).
    pub const max_workers = 8;

    /// create starts the cache with `workers` decoding threads (at least one).
    pub fn create(io: std.Io, alloc: std.mem.Allocator, workers: usize) !*Cache {
        const self = try alloc.create(Cache);
        self.* = .{ .io = io, .alloc = alloc };
        const n = std.math.clamp(workers, 1, max_workers);
        for (self.threads[0..n], 0..) |*t, i| {
            t.* = std.Thread.spawn(.{}, run, .{self}) catch |e| {
                if (i == 0) {
                    alloc.destroy(self);
                    return e;
                }
                break; // fewer than asked: still works
            };
        }
        return self;
    }

    pub fn destroy(self: *Cache) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.mutex.unlock(self.io);
        self.cond.broadcast(self.io);
        for (self.threads) |th| if (th) |t| t.join();
        for (self.queue.items) |k| self.alloc.free(k);
        self.queue.deinit(self.alloc);
        for (self.done.items) |d| {
            self.alloc.free(d.key);
            if (d.px) |px| zfd_image_free(px);
        }
        self.done.deinit(self.alloc);
        var it = self.slots.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.state == .ready) zfd_texture_free(kv.value_ptr.thumb.tex);
            self.alloc.free(kv.key_ptr.*);
        }
        self.slots.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// wants reports whether `e` is a file we make thumbnails for.
    pub fn wants(e: core.scan.Entry) bool {
        if (e.isDir() or e.size == 0 or e.size > max_file_bytes) return false;
        const name = e.name;
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
        var buf: [8]u8 = undefined;
        const ext = name[dot + 1 ..];
        if (ext.len == 0 or ext.len > buf.len) return false;
        for (ext, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        const l = buf[0..ext.len];
        for ([_][]const u8{ "png", "jpg", "jpeg", "gif", "bmp", "tga", "psd", "pnm", "ppm", "pgm" }) |x| {
            if (std.mem.eql(u8, l, x)) return true;
        }
        return false;
    }

    /// get returns the thumbnail for `path` (modified at `mtime`) if ready; otherwise
    /// queues it (once) and returns null. Call only for entries `wants` accepts.
    pub fn get(self: *Cache, path: []const u8, mtime: i64) ?Thumb {
        var kb: [std.fs.max_path_bytes + 24]u8 = undefined;
        const key = std.mem.print(&kb, "{d}\x00{s}", .{ mtime, path }) catch return null;
        if (self.slots.getPtr(key)) |slot| {
            slot.used = self.frame;
            return if (slot.state == .ready) slot.thumb else null;
        }
        const owned = self.alloc.dupe(u8, key) catch return null;
        self.slots.put(self.alloc, owned, .{ .state = .pending, .used = self.frame }) catch {
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
            // Scrolled far past these: forget the oldest requests (they'll be asked
            // for again if they come back into view).
            const old = self.queue.orderedRemove(0);
            if (self.slots.fetchRemove(old)) |kv| self.alloc.free(kv.key);
            self.alloc.free(old);
        }
        self.cond.signal(self.io);
        return null;
    }

    /// pump uploads finished decodes and evicts stale textures. Call once per frame.
    pub fn pump(self: *Cache) void {
        self.frame +%= 1;
        var n: usize = 0;
        while (n < uploads_per_frame) : (n += 1) {
            self.mutex.lockUncancelable(self.io);
            const d: ?Done = if (self.done.items.len > 0) self.done.orderedRemove(0) else null;
            self.mutex.unlock(self.io);
            const done = d orelse break;
            defer self.alloc.free(done.key);
            const slot = self.slots.getPtr(done.key) orelse {
                if (done.px) |px| zfd_image_free(px);
                continue;
            };
            if (done.px) |px| {
                slot.thumb = .{ .tex = zfd_texture_upload(px, done.w, done.h), .w = @floatFromInt(done.w), .h = @floatFromInt(done.h), .full_w = @intCast(@max(done.full_w, 0)), .full_h = @intCast(@max(done.full_h, 0)) };
                slot.state = .ready;
                zfd_image_free(px);
            } else slot.state = .failed;
        }
        if (self.slots.count() > max_cached) self.evict();
    }

    /// busy reports whether thumbnails are still on their way (keeps frames coming).
    pub fn busy(self: *Cache) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.queue.items.len > 0 or self.done.items.len > 0;
    }

    fn evict(self: *Cache) void {
        // Drop ready/failed slots not drawn in the last few seconds, oldest first,
        // until back under the cap. Pending ones stay (the worker will report them).
        while (self.slots.count() > max_cached) {
            var oldest: ?[]const u8 = null;
            var oldest_used: u64 = std.math.maxInt(u64);
            var it = self.slots.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.state == .pending) continue;
                if (kv.value_ptr.used < oldest_used) {
                    oldest_used = kv.value_ptr.used;
                    oldest = kv.key_ptr.*;
                }
            }
            const k = oldest orelse return;
            if (self.frame -% oldest_used < 120) return; // everything is in recent use
            const kv = self.slots.fetchRemove(k).?;
            if (kv.value.state == .ready) zfd_texture_free(kv.value.thumb.tex);
            self.alloc.free(kv.key);
        }
    }

    fn run(self: *Cache) void {
        self.mutex.lockUncancelable(self.io);
        while (true) {
            while (self.queue.items.len == 0 and !self.shutdown) self.cond.waitUncancelable(self.io, &self.mutex);
            if (self.shutdown) break;
            const key = self.queue.pop().?; // newest first
            self.mutex.unlock(self.io);

            const sep = std.mem.indexOfScalar(u8, key, 0) orelse 0;
            var w: c_int = 0;
            var h: c_int = 0;
            var zb: [std.fs.max_path_bytes + 1]u8 = undefined;
            var fw: c_int = 0;
            var fh: c_int = 0;
            const px: ?[*]u8 = if (std.mem.printSentinel(&zb, "{s}", .{key[sep + 1 ..]}, 0)) |pz| blk: {
                _ = image.zfd_image_size(pz.ptr, &fw, &fh); // (the thumbnail is shrunk)
                if (core.exif.turned(image.orientationOf(self.io, pz))) std.mem.swap(c_int, &fw, &fh); // shown upright
                break :blk image.load(self.io, pz.ptr, thumb_px, &w, &h);
            } else |_| null;

            self.mutex.lockUncancelable(self.io);
            self.done.append(self.alloc, .{ .key = key, .px = px, .w = w, .h = h, .full_w = fw, .full_h = fh }) catch {
                self.alloc.free(key);
                if (px) |p| zfd_image_free(p);
            };
            c.glfwPostEmptyEvent();
        }
        self.mutex.unlock(self.io);
    }
};
