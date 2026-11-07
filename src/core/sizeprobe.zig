//! SizeProbe totals a folder (files, subfolders, bytes) on a background thread for
//! the Properties dialog, publishing running counts so the dialog can show them
//! climbing. Cancelable, and safe to abandon: the dialog may close long before a big
//! tree is done, so the probe and the dialog share it by reference count and whoever
//! lets go last frees it. Symlinks are counted but never followed (no cycles, and a
//! link to / shouldn't make a folder look like the whole disk). GUI-free.

const std = @import("std");

pub const SizeProbe = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    path: []u8,
    files: std.atomic.Value(u64) = .init(0),
    dirs: std.atomic.Value(u64) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u8) = .init(2), // the caller + the worker

    /// start begins totaling `path`. The caller must call release() exactly once.
    pub fn start(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !*SizeProbe {
        const self = try alloc.create(SizeProbe);
        errdefer alloc.destroy(self);
        self.* = .{ .io = io, .alloc = alloc, .path = try alloc.dupe(u8, path) };
        errdefer alloc.free(self.path);
        const t = try std.Thread.spawn(.{}, run, .{self});
        t.detach();
        return self;
    }

    /// release lets go of the probe (stopping it if it's still walking).
    pub fn release(self: *SizeProbe) void {
        self.cancel.store(true, .release);
        self.unref();
    }

    pub const Totals = struct { files: u64, dirs: u64, bytes: u64, done: bool };

    pub fn totals(self: *const SizeProbe) Totals {
        return .{
            .files = self.files.load(.monotonic),
            .dirs = self.dirs.load(.monotonic),
            .bytes = self.bytes.load(.monotonic),
            .done = self.done.load(.acquire),
        };
    }

    fn unref(self: *SizeProbe) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const alloc = self.alloc;
        alloc.free(self.path);
        alloc.destroy(self);
    }

    fn run(self: *SizeProbe) void {
        defer self.unref();
        defer self.done.store(true, .release);
        // Iterative walk: an explicit stack of owned paths, so a very deep tree can't
        // overflow the thread stack.
        var stack = std.ArrayList([]u8).empty;
        defer {
            for (stack.items) |p| self.alloc.free(p);
            stack.deinit(self.alloc);
        }
        const root = self.alloc.dupe(u8, self.path) catch return;
        stack.append(self.alloc, root) catch return self.alloc.free(root);
        while (stack.pop()) |dir_path| {
            defer self.alloc.free(dir_path);
            if (self.cancel.load(.acquire)) return;
            var d = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch continue;
            defer d.close(self.io);
            var it = d.iterate();
            while (it.next(self.io) catch null) |e| {
                if (self.cancel.load(.acquire)) return;
                switch (e.kind) {
                    .directory => {
                        _ = self.dirs.fetchAdd(1, .monotonic);
                        const child = std.fs.path.join(self.alloc, &.{ dir_path, e.name }) catch continue;
                        stack.append(self.alloc, child) catch self.alloc.free(child);
                    },
                    else => {
                        _ = self.files.fetchAdd(1, .monotonic);
                        const st = d.statFile(self.io, e.name, .{ .follow_symlinks = false }) catch continue;
                        _ = self.bytes.fetchAdd(st.size, .monotonic);
                    },
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
const testing = std.testing;

test "SizeProbe totals a tree in the background" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "x/y");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "12345" });
    try tmp.dir.writeFile(io, .{ .sub_path = "x/b.txt", .data = "12" });
    try tmp.dir.writeFile(io, .{ .sub_path = "x/y/c.txt", .data = "1" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const p = try SizeProbe.start(io, a, root);
    defer p.release();
    var spins: usize = 0;
    while (!p.totals().done and spins < 5_000_000) : (spins += 1) std.Thread.yield() catch {};
    const t = p.totals();
    try testing.expect(t.done);
    try testing.expectEqual(@as(u64, 3), t.files);
    try testing.expectEqual(@as(u64, 2), t.dirs); // x and x/y
    try testing.expectEqual(@as(u64, 8), t.bytes);
}

test "SizeProbe can be released before it finishes" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(root);
    const p = try SizeProbe.start(testing.io, a, root);
    p.release(); // the worker frees it when it notices; the allocator checks for leaks
    var spins: usize = 0;
    while (spins < 200_000) : (spins += 1) std.Thread.yield() catch {};
}
