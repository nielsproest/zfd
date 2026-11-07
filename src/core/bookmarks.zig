//! Bookmarks that remember *what* a place is, not just its path, so they work even
//! when the place isn't there yet: a folder on a USB stick (found again by its
//! filesystem UUID, mounted on click), on an rclone remote (connected on click), or
//! an ordinary path. Stored one per line in ~/.config/zfd/bookmarks:
//!
//!     <location>\t<label>
//!
//! where <location> is an absolute path, `rclone:<remote>:<subpath>`,
//! `dev:<uuid>:<subpath>` or a saved search `search:<0|1>:<folder>\x1f<query>` (1 =
//! subfolders too), and the label is optional (older files hold bare paths,
//! which load unchanged). GUI-free; unit-tested.

const std = @import("std");

pub const Bookmark = struct {
    loc: []u8, // owned
    label: []u8, // owned; "" = derive from the location

    pub fn deinit(self: Bookmark, alloc: std.mem.Allocator) void {
        alloc.free(self.loc);
        alloc.free(self.label);
    }

    /// target decodes the location.
    pub fn target(self: Bookmark) Target {
        return parseLoc(self.loc);
    }

    /// displayName is the label, or a name derived from the location.
    pub fn displayName(self: Bookmark) []const u8 {
        if (self.label.len > 0) return self.label;
        return switch (self.target()) {
            .path => |p| if (std.fs.path.basename(p).len > 0) std.fs.path.basename(p) else p,
            .remote => |r| if (r.sub.len > 0) std.fs.path.basename(r.sub) else r.name,
            .device => |d| if (d.sub.len > 0) std.fs.path.basename(d.sub) else d.uuid,
            .search => |q| q.query,
        };
    }
};

pub const Target = union(enum) {
    path: []const u8,
    remote: struct { name: []const u8, sub: []const u8 }, // sub: "" or "a/b" (no leading '/')
    device: struct { uuid: []const u8, sub: []const u8 },
    search: struct { dir: []const u8, query: []const u8, deep: bool },
};

pub fn parseLoc(loc: []const u8) Target {
    if (std.mem.startsWith(u8, loc, "rclone:")) {
        const rest = loc["rclone:".len..];
        const c = std.mem.indexOfScalar(u8, rest, ':') orelse return .{ .remote = .{ .name = rest, .sub = "" } };
        return .{ .remote = .{ .name = rest[0..c], .sub = std.mem.trim(u8, rest[c + 1 ..], "/") } };
    }
    if (std.mem.startsWith(u8, loc, "dev:")) {
        const rest = loc["dev:".len..];
        const c = std.mem.indexOfScalar(u8, rest, ':') orelse return .{ .device = .{ .uuid = rest, .sub = "" } };
        return .{ .device = .{ .uuid = rest[0..c], .sub = std.mem.trim(u8, rest[c + 1 ..], "/") } };
    }
    if (std.mem.startsWith(u8, loc, "search:") and loc.len > "search:0:".len) {
        const rest = loc["search:0:".len..];
        const sep = std.mem.indexOfScalar(u8, rest, 0x1f) orelse rest.len;
        return .{ .search = .{ .dir = rest[0..sep], .query = if (sep < rest.len) rest[sep + 1 ..] else "", .deep = loc["search:".len] == '1' } };
    }
    return .{ .path = loc };
}

/// searchLoc builds a saved search's location (owned).
pub fn searchLoc(alloc: std.mem.Allocator, dir: []const u8, query: []const u8, deep: bool) ![]u8 {
    if (std.mem.indexOfAny(u8, query, "\t\n\x1f") != null or std.mem.indexOfAny(u8, dir, "\t\n\x1f") != null) return error.BadValue;
    return alloc.print("search:{d}:{s}\x1f{s}", .{ @intFromBool(deep), dir, query });
}

test "saved searches round-trip" {
    const loc = try searchLoc(testing.allocator, "/home/me", "kind:image cat", true);
    defer testing.allocator.free(loc);
    const t = parseLoc(loc).search;
    try testing.expectEqualStrings("/home/me", t.dir);
    try testing.expectEqualStrings("kind:image cat", t.query);
    try testing.expect(t.deep);
}

/// remoteLoc / deviceLoc build locations (owned).
pub fn remoteLoc(alloc: std.mem.Allocator, name: []const u8, sub: []const u8) ![]u8 {
    return alloc.print("rclone:{s}:{s}", .{ name, std.mem.trim(u8, sub, "/") });
}
pub fn deviceLoc(alloc: std.mem.Allocator, uuid: []const u8, sub: []const u8) ![]u8 {
    return alloc.print("dev:{s}:{s}", .{ uuid, std.mem.trim(u8, sub, "/") });
}

/// parseFile reads the bookmarks file content.
pub fn parseFile(alloc: std.mem.Allocator, content: []const u8) !std.ArrayList(Bookmark) {
    var out = std.ArrayList(Bookmark).empty;
    errdefer {
        for (out.items) |b| b.deinit(alloc);
        out.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t');
        const loc = std.mem.trim(u8, if (tab) |t| line[0..t] else line, " \t");
        if (loc.len == 0) continue;
        const label = if (tab) |t| std.mem.trim(u8, line[t + 1 ..], " \t") else "";
        const l = try alloc.dupe(u8, loc);
        errdefer alloc.free(l);
        try out.append(alloc, .{ .loc = l, .label = try alloc.dupe(u8, label) });
    }
    return out;
}

/// format renders the list in the file format (owned).
pub fn format(alloc: std.mem.Allocator, list: []const Bookmark) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (list) |b| {
        try out.appendSlice(alloc, b.loc);
        if (b.label.len > 0) {
            try out.append(alloc, '\t');
            try out.appendSlice(alloc, b.label);
        }
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "bookmark locations decode" {
    const p = parseLoc("/home/me/Music");
    try testing.expectEqualStrings("/home/me/Music", p.path);
    const r = parseLoc("rclone:nas:/photos/2025/");
    try testing.expectEqualStrings("nas", r.remote.name);
    try testing.expectEqualStrings("photos/2025", r.remote.sub);
    const d = parseLoc("dev:1234-ABCD:");
    try testing.expectEqualStrings("1234-ABCD", d.device.uuid);
    try testing.expectEqualStrings("", d.device.sub);
}

test "bookmark files round-trip and read the old bare-path format" {
    const a = testing.allocator;
    var list = try parseFile(a, "/home/me/Music\nrclone:nas:photos\tHoliday pics\n\n");
    defer {
        for (list.items) |b| b.deinit(a);
        list.deinit(a);
    }
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("Music", list.items[0].displayName());
    try testing.expectEqualStrings("Holiday pics", list.items[1].displayName());
    const text = try format(a, list.items);
    defer a.free(text);
    try testing.expectEqualStrings("/home/me/Music\nrclone:nas:photos\tHoliday pics\n", text);
}
