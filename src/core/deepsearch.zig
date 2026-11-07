//! DeepSearch: the OPT-IN "search subfolders" mode. The normal quick-search only
//! filters the folder already listed (instant, no I/O); this walks the whole tree
//! below it on a background thread, so it only runs while the user has asked for it.
//! Matches stream into a result list the Browser shows as a listing whose names are
//! paths relative to the searched folder ("sub/dir/file.txt").
//!
//! Cancelable and safe to abandon (refcounted like SizeProbe: a new query or leaving
//! the folder just releases the old walk). Symlinked folders are not followed (no
//! cycles), hidden entries are skipped unless shown, and results are capped so a
//! query like "e" in / can't eat the machine. GUI-free.

const std = @import("std");
const scan = @import("scan.zig");
const query_mod = @import("query.zig");

pub const max_results: usize = 5000;

pub const DeepSearch = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    root: []u8,
    query: []u8,
    ci: bool,
    show_hidden: bool,
    mutex: std.Io.Mutex = .init,
    results: std.ArrayList(scan.Entry) = .empty, // guarded by mutex
    dirs: std.atomic.Value(u64) = .init(0), // folders searched so far
    done: std.atomic.Value(bool) = .init(false),
    capped: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u8) = .init(2), // caller + worker

    /// start begins searching below `root` for names matching `query` (the same glob
    /// rules as the quick-search). The caller must call release() exactly once.
    pub fn start(io: std.Io, alloc: std.mem.Allocator, root: []const u8, query: []const u8, ci: bool, show_hidden: bool) !*DeepSearch {
        const self = try alloc.create(DeepSearch);
        errdefer alloc.destroy(self);
        const r = try alloc.dupe(u8, root);
        errdefer alloc.free(r);
        const q = try alloc.dupe(u8, query);
        errdefer alloc.free(q);
        self.* = .{ .io = io, .alloc = alloc, .root = r, .query = q, .ci = ci, .show_hidden = show_hidden };
        const t = try std.Thread.spawn(.{}, run, .{self});
        t.detach();
        return self;
    }

    /// stop asks the walk to end early, keeping what it found.
    pub fn stop(self: *DeepSearch) void {
        self.cancel.store(true, .release);
    }

    pub fn release(self: *DeepSearch) void {
        self.cancel.store(true, .release);
        self.unref();
    }

    pub fn isDone(self: *const DeepSearch) bool {
        return self.done.load(.acquire);
    }
    pub fn dirsSearched(self: *const DeepSearch) u64 {
        return self.dirs.load(.monotonic);
    }
    pub fn wasCapped(self: *const DeepSearch) bool {
        return self.capped.load(.monotonic);
    }

    pub fn count(self: *DeepSearch) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.results.items.len;
    }

    /// snapshot copies the results found so far into a Listing (caller owns it).
    pub fn snapshot(self: *DeepSearch, alloc: std.mem.Allocator) !scan.Listing {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const out = try alloc.alloc(scan.Entry, self.results.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |e| freeEntry(alloc, e);
            alloc.free(out);
        }
        for (self.results.items) |e| {
            var d = e;
            d.name = try alloc.dupe(u8, e.name);
            d.link_target = if (e.link_target.len > 0) (alloc.dupe(u8, e.link_target) catch &.{}) else &.{};
            out[n] = d;
            n += 1;
        }
        return .{ .entries = out };
    }

    fn unref(self: *DeepSearch) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const alloc = self.alloc;
        for (self.results.items) |e| freeEntry(alloc, e);
        self.results.deinit(alloc);
        alloc.free(self.root);
        alloc.free(self.query);
        alloc.destroy(self);
    }

    fn run(self: *DeepSearch) void {
        defer self.unref();
        defer self.done.store(true, .release);
        // Breadth-first: nearby matches (the ones people usually want) show up first,
        // before the walk disappears into some deep build or cache tree.
        var queue = std.ArrayList([]u8).empty; // relative dir paths; "" = the root
        var head: usize = 0;
        defer {
            for (queue.items[head..]) |p| self.alloc.free(p);
            queue.deinit(self.alloc);
        }
        var qbuf: [512]u8 = undefined;
        const q = query_mod.parse(self.query, &qbuf); // kind: / tag: / rules + the name pattern
        const first = self.alloc.dupe(u8, "") catch return;
        queue.append(self.alloc, first) catch return self.alloc.free(first);
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        while (head < queue.items.len) {
            const rel = queue.items[head];
            head += 1;
            defer self.alloc.free(rel);
            if (self.cancel.load(.acquire)) return;
            const abs = if (rel.len == 0) self.root else (std.mem.print(&pbuf, "{s}/{s}", .{ if (std.mem.eql(u8, self.root, "/")) "" else self.root, rel }) catch continue);
            var d = std.Io.Dir.cwd().openDir(self.io, abs, .{ .iterate = true }) catch continue;
            defer d.close(self.io);
            _ = self.dirs.fetchAdd(1, .monotonic);
            var it = d.iterate();
            while (true) {
                const next = it.next(self.io) catch break; // an undecodable entry ends this dir, not the search
                const e = next orelse break;
                if (self.cancel.load(.acquire)) return;
                if (!self.show_hidden and e.name.len > 0 and e.name[0] == '.') continue;
                var nbuf: [std.fs.max_path_bytes]u8 = undefined;
                const rel_name = if (rel.len == 0) e.name else (std.mem.print(&nbuf, "{s}/{s}", .{ rel, e.name }) catch continue);
                const kind: scan.Kind = switch (e.kind) {
                    .directory => .dir,
                    .file => .file,
                    .sym_link => .symlink,
                    else => .other,
                };
                if (q.matchesName(e.name, kind, self.ci)) match: {
                    const entry = scan.entryAt(self.alloc, d, e.name, rel_name, kind) catch break :match;
                    if (!q.matchesDetails(entry)) {
                        freeEntry(self.alloc, entry);
                        break :match;
                    }
                    self.mutex.lockUncancelable(self.io);
                    const full = self.results.items.len >= max_results;
                    if (!full) self.results.append(self.alloc, entry) catch freeEntry(self.alloc, entry);
                    self.mutex.unlock(self.io);
                    if (full) {
                        freeEntry(self.alloc, entry);
                        self.capped.store(true, .monotonic);
                        return;
                    }
                }
                if (kind == .dir) {
                    const child = self.alloc.dupe(u8, rel_name) catch continue;
                    queue.append(self.alloc, child) catch self.alloc.free(child);
                }
            }
        }
    }
};

fn freeEntry(alloc: std.mem.Allocator, e: scan.Entry) void {
    alloc.free(e.name);
    if (e.link_target.len > 0) alloc.free(e.link_target);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

fn waitDone(s: *DeepSearch) void {
    var spins: usize = 0;
    while (!s.isDone() and spins < 5_000_000) : (spins += 1) std.Thread.yield() catch {};
}

test "DeepSearch finds matches in subfolders, with relative names, skipping hidden" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs/2024");
    try tmp.dir.createDirPath(io, ".cache");
    try tmp.dir.writeFile(io, .{ .sub_path = "report.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/2024/report-final.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/other.md", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".cache/report.tmp", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const s = try DeepSearch.start(io, a, root, "report", true, false);
    defer s.release();
    waitDone(s);
    const l = try s.snapshot(a);
    defer l.deinit(a);
    try testing.expectEqual(@as(usize, 2), l.entries.len); // the .cache one is hidden
    var saw_nested = false;
    for (l.entries) |e| {
        if (std.mem.eql(u8, e.name, "docs/2024/report-final.txt")) saw_nested = true;
    }
    try testing.expect(saw_nested);
    try testing.expect(s.dirsSearched() >= 3); // root, docs, docs/2024
}

test "DeepSearch can be released mid-walk" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(root);
    const s = try DeepSearch.start(testing.io, a, root, "x", true, false);
    s.release();
    var spins: usize = 0;
    while (spins < 200_000) : (spins += 1) std.Thread.yield() catch {};
}
