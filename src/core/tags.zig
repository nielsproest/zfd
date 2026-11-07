//! Tags (Finder's) stored the freedesktop way: a comma-separated list in the
//! `user.xdg.tags` extended attribute, which Dolphin/Baloo read too, and which travels
//! with the file when it's copied with xattrs. You start with the seven Finder colours
//! (which can be renamed) and can add your own, up to 16; tag names on a file that
//! aren't yours are kept untouched when tags change.
//! GUI-free; parse/format are unit-tested, read/write do the syscalls.

const std = @import("std");
const linux = std.os.linux;

pub const attr_name = "user.xdg.tags";

/// Color is a tag's dot colour: Finder's seven, or none (a grey ring).
pub const Color = enum(u3) {
    red,
    orange,
    yellow,
    green,
    blue,
    purple,
    gray,
    none,

    /// name is the colour's own tag name (the seven default tags).
    pub fn name(c: Color) []const u8 {
        return switch (c) {
            .red => "Red",
            .orange => "Orange",
            .yellow => "Yellow",
            .green => "Green",
            .blue => "Blue",
            .purple => "Purple",
            .gray => "Gray",
            .none => "",
        };
    }

    /// rgb is the dot colour (0xRRGGBB).
    pub fn rgb(c: Color) u32 {
        return switch (c) {
            .red => 0xFF5F57,
            .orange => 0xFFA33A,
            .yellow => 0xFFD93B,
            .green => 0x4CD964,
            .blue => 0x3D9BFF,
            .purple => 0xB86BE0,
            .gray => 0x9A9A9F,
            .none => 0xC8C8CC,
        };
    }
};

pub const colors = [_]Color{ .red, .orange, .yellow, .green, .blue, .purple, .gray, .none };

/// Mask holds one bit per tag (Tag.idx).
pub const Mask = u16;
pub const max_tags = 16;

/// Tag is one of the tags you have (Settings > Tags): the first seven start as the
/// colour tags, which can be renamed; more can be added, with a colour or none.
pub const Tag = struct {
    idx: u4,

    pub fn name(t: Tag) []const u8 {
        return table.names[t.idx][0..table.lens[t.idx]];
    }
    pub fn color(t: Tag) Color {
        return table.colors[t.idx];
    }
    pub fn rgb(t: Tag) u32 {
        return t.color().rgb();
    }
    pub fn bit(t: Tag) Mask {
        return @as(Mask, 1) << t.idx;
    }
};

const name_max = 48;

/// Table is the tag list. One global, edited only from Settings on the UI thread;
/// the scanners read it to recognise tag names.
const Table = struct {
    names: [max_tags][name_max]u8 = undefined,
    lens: [max_tags]u8 = @splat(0),
    colors: [max_tags]Color = @splat(.none),
    count: u5 = 0,
};

var table: Table = defaults();
var tag_list: [max_tags]Tag = blk: {
    var l: [max_tags]Tag = undefined;
    for (&l, 0..) |*t, i| t.* = .{ .idx = @intCast(i) };
    break :blk l;
};

fn defaults() Table {
    var t: Table = .{};
    for (colors[0..7], 0..) |c, i| {
        const n = c.name();
        @memcpy(t.names[i][0..n.len], n);
        t.lens[i] = @intCast(n.len);
        t.colors[i] = c;
    }
    t.count = 7;
    return t;
}

/// list is the tags, in order.
pub fn list() []const Tag {
    return tag_list[0..table.count];
}

/// rename gives tag `idx` a new name (trimmed; commas and newlines can't be in a tag).
pub fn rename(idx: usize, new_name: []const u8) void {
    const n = std.mem.trim(u8, new_name, " \t");
    if (idx >= table.count or n.len == 0 or n.len > name_max or std.mem.indexOfAny(u8, n, ",\n\t") != null) return;
    @memcpy(table.names[idx][0..n.len], n);
    table.lens[idx] = @intCast(n.len);
}

pub fn setColor(idx: usize, c: Color) void {
    if (idx < table.count) table.colors[idx] = c;
}

/// add appends a tag; false when the list is full or the name is unusable.
pub fn add(new_name: []const u8, c: Color) bool {
    if (table.count >= max_tags) return false;
    const i = table.count;
    table.lens[i] = 0;
    table.count += 1;
    rename(i, new_name);
    if (table.lens[i] == 0) {
        table.count -= 1;
        return false;
    }
    table.colors[i] = c;
    return true;
}

/// remove drops tag `idx` (one you added; the first seven stay). Later tags move up a
/// slot, so masks taken before this are stale until the folder reloads.
pub fn remove(idx: usize) void {
    if (idx < 7 or idx >= table.count) return;
    var i = idx;
    while (i + 1 < table.count) : (i += 1) {
        table.names[i] = table.names[i + 1];
        table.lens[i] = table.lens[i + 1];
        table.colors[i] = table.colors[i + 1];
    }
    table.count -= 1;
}

/// parseTable loads the tag list from its file (`name\tcolour` per line, colour 0-7);
/// an empty or missing file keeps the defaults.
pub fn parseTable(text: []const u8) void {
    var t: Table = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (t.count >= max_tags) break;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const n = std.mem.trim(u8, line[0..tab], " ");
        const ci = std.fmt.parseInt(u3, std.mem.trim(u8, line[tab + 1 ..], " \r"), 10) catch continue;
        if (n.len == 0 or n.len > name_max or std.mem.indexOfScalar(u8, n, ',') != null) continue;
        @memcpy(t.names[t.count][0..n.len], n);
        t.lens[t.count] = @intCast(n.len);
        t.colors[t.count] = @fromBackingInt(@intCast(ci));
        t.count += 1;
    }
    if (t.count < 7) return; // a broken file: keep what we have
    table = t;
}

/// formatTable is the tag list as its file (owned).
pub fn formatTable(alloc: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (list()) |t| {
        try out.appendSlice(alloc, t.name());
        try out.append(alloc, '\t');
        try out.append(alloc, '0' + @as(u8, @backingInt(t.color())));
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// resetTable restores the seven colour tags (tests use it too).
pub fn resetTable() void {
    table = defaults();
}

/// lookup is the tag a word names: a tag's current name, or — for the first seven —
/// its colour's original name, so files tagged before a rename still count. "Grey"
/// is gray.
pub fn lookup(word: []const u8) ?Tag {
    for (list()) |t| if (std.ascii.eqlIgnoreCase(word, t.name())) return t;
    for (colors[0..7], 0..) |c, i| {
        if (i < table.count and std.ascii.eqlIgnoreCase(word, c.name())) return tag_list[i];
    }
    if (table.count > 6 and std.ascii.eqlIgnoreCase(word, "Grey")) return tag_list[6];
    return null;
}

/// maskOf returns the tag bits named in a tag list ("Red,work,Blue" → red|blue).
/// Matching is case-insensitive; names that aren't tags of ours are left alone.
pub fn maskOf(tag_text: []const u8) Mask {
    var m: Mask = 0;
    var it = std.mem.splitScalar(u8, tag_text, ',');
    while (it.next()) |raw| {
        if (lookup(std.mem.trim(u8, raw, " \t"))) |t| m |= t.bit();
    }
    return m;
}

/// withMask rewrites tag list `tag_text` so our tags are exactly `mask`, keeping every
/// other tag in place. Owned result ("" = no tags left).
pub fn withMask(alloc: std.mem.Allocator, tag_text: []const u8, mask: Mask) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, tag_text, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t");
        if (t.len == 0 or lookup(t) != null) continue; // ours are re-added below
        if (out.items.len > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, t);
    }
    for (list()) |t| {
        if (mask & t.bit() == 0) continue;
        if (out.items.len > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, t.name());
    }
    return out.toOwnedSlice(alloc);
}

/// readList reads `path`'s tag attribute into `buf` ("" when it has none or the
/// filesystem has no xattrs). Doesn't follow a final symlink.
pub fn readList(path: [:0]const u8, buf: []u8) []const u8 {
    const rc = linux.lgetxattr(path.ptr, attr_name, buf.ptr, buf.len);
    if (linux.errno(rc) != .SUCCESS) return "";
    return buf[0..rc];
}

/// readMask is the tag bits on `path` (0 if none).
pub fn readMask(path: [:0]const u8) Mask {
    var buf: [512]u8 = undefined;
    return maskOf(readList(path, &buf));
}

/// setMask makes `path`'s tags of ours exactly `mask`, keeping its other tags.
pub fn setMask(alloc: std.mem.Allocator, path: []const u8, mask: Mask) !void {
    const pz = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(pz);
    var buf: [4096]u8 = undefined;
    const text = try withMask(alloc, readList(pz, &buf), mask);
    defer alloc.free(text);
    const rc = if (text.len == 0)
        linux.lremovexattr(pz.ptr, attr_name)
    else
        linux.lsetxattr(pz.ptr, attr_name, text.ptr, text.len, 0);
    switch (linux.errno(rc)) {
        .SUCCESS, .NODATA => {},
        .OPNOTSUPP => return error.TagsNotSupported,
        .ACCES, .PERM => return error.AccessDenied,
        .NOSPC, .DQUOT => return error.NoSpaceLeft,
        else => return error.Unexpected,
    }
}

// ---------------------------------------------------------------------------
const testing = std.testing;

fn colorTag(c: Color) Tag {
    return .{ .idx = @backingInt(c) };
}

test "maskOf picks our tags out of a tag list" {
    resetTable();
    try testing.expectEqual(colorTag(.red).bit() | colorTag(.blue).bit(), maskOf("Red, work,blue"));
    try testing.expectEqual(colorTag(.gray).bit(), maskOf("Grey"));
    try testing.expectEqual(@as(Mask, 0), maskOf(""));
    try testing.expectEqual(@as(Mask, 0), maskOf("Redish"));
}

test "renamed and added tags, and the table file" {
    defer resetTable();
    resetTable();
    rename(0, "Important");
    try testing.expect(add("Work", .none));
    try testing.expectEqual(@as(Mask, 1 | 1 << 7), maskOf("Important,work"));
    try testing.expectEqual(@as(Mask, 1), maskOf("Red")); // tagged before the rename
    const text = try formatTable(testing.allocator);
    defer testing.allocator.free(text);
    resetTable();
    parseTable(text);
    try testing.expectEqualStrings("Important", list()[0].name());
    try testing.expectEqualStrings("Work", list()[7].name());
    try testing.expectEqual(Color.none, list()[7].color());
}

test "withMask keeps other tags and replaces ours" {
    resetTable();
    const a = testing.allocator;
    const got = try withMask(a, "Red,project x,Blue", colorTag(.green).bit());
    defer a.free(got);
    try testing.expectEqualStrings("project x,Green", got);
    const none = try withMask(a, "Red", 0);
    defer a.free(none);
    try testing.expectEqualStrings("", none);
}

test "setMask writes the attribute (when the filesystem supports xattrs)" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, "f", a);
    defer a.free(root);
    resetTable();
    setMask(a, root, colorTag(.red).bit() | colorTag(.purple).bit()) catch |e| switch (e) {
        error.TagsNotSupported => return error.SkipZigTest,
        else => return e,
    };
    const pz = try a.dupeSentinel(u8, root, 0);
    defer a.free(pz);
    try testing.expectEqual(colorTag(.red).bit() | colorTag(.purple).bit(), readMask(pz));
    try setMask(a, root, 0);
    try testing.expectEqual(@as(Mask, 0), readMask(pz));
}
