//! The file clipboard: a set of absolute paths plus whether they were copied or
//! cut (Ctrl+C / Ctrl+X). Paste consults `mode` to decide copy vs move. Pure
//! state; the actual copy/move runs off-thread via the op-runner. GUI-free and
//! tested.

const std = @import("std");

pub const Mode = enum { none, copy, cut };

pub const Clipboard = struct {
    paths: std.ArrayList([]u8) = .empty, // owned absolute paths
    mode: Mode = .none,

    pub fn deinit(self: *Clipboard, alloc: std.mem.Allocator) void {
        self.clearPaths(alloc);
        self.paths.deinit(alloc);
    }

    /// set replaces the clipboard contents with owned copies of `paths`.
    pub fn set(self: *Clipboard, alloc: std.mem.Allocator, paths: []const []const u8, mode: Mode) !void {
        self.clearPaths(alloc);
        for (paths) |p| try self.paths.append(alloc, try alloc.dupe(u8, p));
        self.mode = if (paths.len == 0) .none else mode;
    }

    /// setOwned replaces the clipboard, TAKING OWNERSHIP of `paths` (its strings and
    /// the outer slice) rather than copying, for callers that already hold owned paths
    /// (e.g. Browser.selectedPaths), so cut/copy doesn't dupe them a second time.
    pub fn setOwned(self: *Clipboard, alloc: std.mem.Allocator, paths: [][]u8, mode: Mode) !void {
        self.clearPaths(alloc);
        var i: usize = 0;
        errdefer { // append OOM: strings not yet moved in are ours to free, plus the slice
            for (paths[i..]) |p| alloc.free(p);
            alloc.free(paths);
        }
        while (i < paths.len) : (i += 1) try self.paths.append(alloc, paths[i]);
        self.mode = if (paths.len == 0) .none else mode;
        alloc.free(paths); // strings now owned by self.paths; the outer slice is consumed
    }

    pub fn clear(self: *Clipboard, alloc: std.mem.Allocator) void {
        self.clearPaths(alloc);
    }

    pub fn isEmpty(self: *const Clipboard) bool {
        return self.paths.items.len == 0;
    }

    pub fn isCut(self: *const Clipboard) bool {
        return self.mode == .cut;
    }

    pub fn list(self: *const Clipboard) []const []u8 {
        return self.paths.items;
    }

    fn clearPaths(self: *Clipboard, alloc: std.mem.Allocator) void {
        for (self.paths.items) |p| alloc.free(p);
        self.paths.clearRetainingCapacity();
        self.mode = .none;
    }
};

// ---------------------------------------------------------------------------
const testing = std.testing;

test "clipboard copy then cut, list and clear" {
    const a = testing.allocator;
    var cb = Clipboard{};
    defer cb.deinit(a);

    try testing.expect(cb.isEmpty());
    try cb.set(a, &.{ "/a/one", "/a/two" }, .copy);
    try testing.expectEqual(@as(usize, 2), cb.list().len);
    try testing.expect(!cb.isCut());
    try testing.expectEqualStrings("/a/one", cb.list()[0]);

    try cb.set(a, &.{"/b/x"}, .cut); // replaces
    try testing.expectEqual(@as(usize, 1), cb.list().len);
    try testing.expect(cb.isCut());

    cb.clear(a);
    try testing.expect(cb.isEmpty());
    try testing.expectEqual(Mode.none, cb.mode);
}

test "clipboard set of empty list stays none" {
    const a = testing.allocator;
    var cb = Clipboard{};
    defer cb.deinit(a);
    try cb.set(a, &.{}, .copy);
    try testing.expect(cb.isEmpty());
    try testing.expectEqual(Mode.none, cb.mode);
}

test "clipboard setOwned takes ownership (no re-dupe, no leak/double-free)" {
    const a = testing.allocator;
    var cb = Clipboard{};
    defer cb.deinit(a); // the testing allocator flags any leak or double-free here

    try testing.expect(cb.isEmpty()); // before
    const paths = try a.alloc([]u8, 2);
    paths[0] = try a.dupe(u8, "/x/one");
    paths[1] = try a.dupe(u8, "/x/two");
    try cb.setOwned(a, paths, .cut); // moves the owned strings in

    try testing.expectEqual(@as(usize, 2), cb.list().len); // after
    try testing.expect(cb.isCut());
    try testing.expectEqualStrings("/x/two", cb.list()[1]);
}
