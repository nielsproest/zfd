//! Freedesktop trash listing + restore/remove, for the "Open trashcan" view. A trash
//! directory is <trash>/{files,info}; each files/<name> has an info/<name>.trashinfo
//! recording the original Path (URL-encoded per spec). We list them, restore a file to
//! its original location, or delete it permanently. Besides the home trash we sweep the
//! per-filesystem top-dir trashes ($mnt/.Trash/$uid and $mnt/.Trash-$uid) on mounted
//! volumes, resolving their spec-relative Paths against the mount point (see fsops.trash
//! for the writing side). Path decoding is pure and unit-tested; the operations do I/O.

const std = @import("std");
const fsops = @import("fsops.zig");
const Dir = std.Io.Dir;

pub const Item = struct {
    name: []u8, // basename under files/ (owned)
    orig_path: []u8, // decoded, absolute original path (owned)
    trash_dir: []u8, // the trash dir this item lives in (owned): home or a top-dir trash
    deleted: i64 = 0, // when it was trashed (DeletionDate; Unix seconds; 0 = unknown)
};

/// list returns the home-trash contents (name + original path). Empty if the trash
/// doesn't exist. Caller frees with `free`. Use `listAll` to also sweep the per-
/// filesystem top-dir trashes on mounted volumes.
pub fn list(io: std.Io, alloc: std.mem.Allocator, trash_home: []const u8) []Item {
    var items = std.ArrayList(Item).empty;
    appendDir(io, alloc, trash_home, "", &items);
    std.mem.sort(Item, items.items, {}, byName);
    return items.toOwnedSlice(alloc) catch &.{};
}

/// listAll returns the home trash plus the per-filesystem top-dir trashes found on the
/// given external mountpoints ($mnt/.Trash/$uid and $mnt/.Trash-$uid, per the spec).
/// Caller frees with `free`.
pub fn listAll(io: std.Io, alloc: std.mem.Allocator, trash_home: []const u8, mountpoints: []const []const u8) []Item {
    var items = std.ArrayList(Item).empty;
    appendDir(io, alloc, trash_home, "", &items);
    const uid = std.os.linux.getuid();
    for (mountpoints) |mnt| {
        if (alloc.print("{s}/.Trash/{d}", .{ mnt, uid })) |shared| {
            defer alloc.free(shared);
            appendDir(io, alloc, shared, mnt, &items);
        } else |_| {}
        if (alloc.print("{s}/.Trash-{d}", .{ mnt, uid })) |personal| {
            defer alloc.free(personal);
            appendDir(io, alloc, personal, mnt, &items);
        } else |_| {}
    }
    std.mem.sort(Item, items.items, {}, byName);
    return items.toOwnedSlice(alloc) catch &.{};
}

/// appendDir appends the items of one trash directory. `topdir` is "" for the home
/// trash (Path stored absolute) or the mount point for a top-dir trash (relative Path
/// values resolve against it). Best-effort: an unreadable dir or entry is skipped.
fn appendDir(io: std.Io, alloc: std.mem.Allocator, trash_dir: []const u8, topdir: []const u8, items: *std.ArrayList(Item)) void {
    const files_dir = std.fs.path.join(alloc, &.{ trash_dir, "files" }) catch return;
    defer alloc.free(files_dir);
    var d = Dir.cwd().openDir(io, files_dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        var deleted: i64 = 0;
        const orig = readOrigPath(io, alloc, trash_dir, topdir, e.name, &deleted) catch alloc.dupe(u8, "") catch continue;
        const name = alloc.dupe(u8, e.name) catch {
            alloc.free(orig);
            continue;
        };
        const dir = alloc.dupe(u8, trash_dir) catch {
            alloc.free(orig);
            alloc.free(name);
            continue;
        };
        items.append(alloc, .{ .name = name, .orig_path = orig, .trash_dir = dir, .deleted = deleted }) catch {
            alloc.free(orig);
            alloc.free(name);
            alloc.free(dir);
        };
    }
}

fn byName(_: void, a: Item, b: Item) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// readOrigPath reads + decodes the original Path from name's .trashinfo. For a top-dir
/// trash (topdir non-empty) a relative Path is resolved against the top dir, so callers
/// always get an absolute path.
fn readOrigPath(io: std.Io, alloc: std.mem.Allocator, trash_dir: []const u8, topdir: []const u8, name: []const u8, deleted: *i64) ![]u8 {
    const info_path = try alloc.print("{s}/info/{s}.trashinfo", .{ trash_dir, name });
    defer alloc.free(info_path);
    const content = try Dir.cwd().readFileAlloc(io, info_path, alloc, .limited(1 << 16));
    defer alloc.free(content);
    deleted.* = parseInfoDate(content);
    const encoded = parseInfoPath(content) orelse return error.NoPath;
    const decoded = try urlDecode(alloc, encoded);
    if (topdir.len > 0 and decoded.len > 0 and decoded[0] != '/') {
        defer alloc.free(decoded);
        return alloc.print("{s}/{s}", .{ topdir, decoded }); // relative → absolute
    }
    return decoded;
}

/// restore moves an item's files/<name> back to its recorded original path, then
/// deletes the .trashinfo. Fails if the destination already exists.
pub fn restore(io: std.Io, alloc: std.mem.Allocator, item: Item) !void {
    if (item.orig_path.len == 0) return error.NoPath;
    const src = try alloc.print("{s}/files/{s}", .{ item.trash_dir, item.name });
    defer alloc.free(src);
    try Dir.renameAbsolute(src, item.orig_path, io);
    deleteInfo(io, alloc, item.trash_dir, item.name);
}

/// restoreByOrigPath restores the trashed item whose recorded original path matches
/// `orig_path` (for undo of a trash). It recomputes which trash directory the path was
/// sent to (home or a top-dir trash) with the same resolver trashing used, so undo
/// works across filesystems without extra bookkeeping. Errors if no such item exists.
pub fn restoreByOrigPath(io: std.Io, alloc: std.mem.Allocator, trash_home: []const u8, orig_path: []const u8) !void {
    const loc = try fsops.resolveTrashDir(alloc, trash_home, orig_path);
    defer loc.deinit(alloc);
    var buf = std.ArrayList(Item).empty;
    appendDir(io, alloc, loc.dir, loc.topdir, &buf);
    const items: []Item = buf.toOwnedSlice(alloc) catch &.{};
    defer free(alloc, items);
    for (items) |item| {
        if (std.mem.eql(u8, item.orig_path, orig_path)) return restore(io, alloc, item);
    }
    return error.NotFound;
}

/// remove permanently deletes an item's files/<name> and its .trashinfo.
pub fn remove(io: std.Io, alloc: std.mem.Allocator, item: Item) !void {
    const src = try alloc.print("{s}/files/{s}", .{ item.trash_dir, item.name });
    defer alloc.free(src);
    try Dir.cwd().deleteTree(io, src);
    deleteInfo(io, alloc, item.trash_dir, item.name);
}

/// empty permanently deletes every item in the home trash and the top-dir trashes on
/// `mountpoints`.
pub fn empty(io: std.Io, alloc: std.mem.Allocator, trash_home: []const u8, mountpoints: []const []const u8) void {
    const items = listAll(io, alloc, trash_home, mountpoints);
    defer free(alloc, items);
    for (items) |item| remove(io, alloc, item) catch {};
}

fn deleteInfo(io: std.Io, alloc: std.mem.Allocator, trash_dir: []const u8, name: []const u8) void {
    const info_path = alloc.print("{s}/info/{s}.trashinfo", .{ trash_dir, name }) catch return;
    defer alloc.free(info_path);
    Dir.cwd().deleteFile(io, info_path) catch {};
}

pub fn free(alloc: std.mem.Allocator, items: []Item) void {
    for (items) |item| {
        alloc.free(item.name);
        alloc.free(item.orig_path);
        alloc.free(item.trash_dir);
    }
    alloc.free(items);
}

/// parseInfoPath returns the (still URL-encoded) Path= value from a .trashinfo body.
pub fn parseInfoPath(content: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "Path=")) return line[5..];
    }
    return null;
}

/// Tm is libc's struct tm, for mktime.
const Tm = extern struct {
    sec: c_int = 0,
    min: c_int = 0,
    hour: c_int = 0,
    mday: c_int = 0,
    mon: c_int = 0,
    year: c_int = 0,
    wday: c_int = 0,
    yday: c_int = 0,
    isdst: c_int = -1, // (work it out)
    gmtoff: c_long = 0,
    zone: ?[*:0]const u8 = null,
};
extern "c" fn mktime(tm: *Tm) i64;

/// parseInfoDate reads a .trashinfo's DeletionDate ("2026-11-07T23:41:05", local
/// time, as the spec has it) as Unix seconds, or 0 when there's none.
pub fn parseInfoDate(content: []const u8) i64 {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "DeletionDate=")) continue;
        const v = line["DeletionDate=".len..];
        if (v.len < 19 or v[4] != '-' or v[7] != '-' or v[10] != 'T' or v[13] != ':' or v[16] != ':') return 0;
        const num = struct {
            fn f(t: []const u8) c_int {
                return std.fmt.parseInt(c_int, t, 10) catch -1;
            }
        }.f;
        var tm: Tm = .{ .year = num(v[0..4]) - 1900, .mon = num(v[5..7]) - 1, .mday = num(v[8..10]), .hour = num(v[11..13]), .min = num(v[14..16]), .sec = num(v[17..19]) };
        if (tm.mon < 0 or tm.mday < 1 or tm.hour < 0 or tm.min < 0 or tm.sec < 0) return 0;
        const t = mktime(&tm);
        return if (t < 0) 0 else t;
    }
    return 0;
}

/// urlDecode expands %XX escapes (per the trashinfo Path encoding). Owned result.
pub fn urlDecode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                try out.append(alloc, hi.? * 16 + lo.?);
                i += 3;
                continue;
            }
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn hexVal(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "parseInfoPath + urlDecode recover the original path" {
    const a = testing.allocator;
    const body = "[Trash Info]\nPath=/home/u/My%20Docs/a.txt\nDeletionDate=2026-01-01T00:00:00\n";
    const enc = parseInfoPath(body).?;
    try testing.expectEqualStrings("/home/u/My%20Docs/a.txt", enc);
    const dec = try urlDecode(a, enc);
    defer a.free(dec);
    try testing.expectEqualStrings("/home/u/My Docs/a.txt", dec);
}

test "list then restore round-trips a trashed file back to its origin" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    // Build a home-trash with one item (files/ + info/).
    try tmp.dir.createDirPath(io, "Trash/files");
    try tmp.dir.createDirPath(io, "Trash/info");
    try tmp.dir.writeFile(io, .{ .sub_path = "Trash/files/gone.txt", .data = "data" });
    const info = try a.print("[Trash Info]\nPath={s}/restored.txt\n", .{root});
    defer a.free(info);
    try tmp.dir.writeFile(io, .{ .sub_path = "Trash/info/gone.txt.trashinfo", .data = info });

    const trash_home = try a.print("{s}/Trash", .{root});
    defer a.free(trash_home);
    const restored = try a.print("{s}/restored.txt", .{root});
    defer a.free(restored);

    // Before: the item is listed, and its restore target does not exist.
    const items = list(io, a, trash_home);
    defer free(a, items);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("gone.txt", items[0].name);
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, restored, .{}));

    // After: restore puts the file back and empties the trash listing.
    try restore(io, a, items[0]);
    _ = Dir.cwd().statFile(io, restored, .{}) catch return error.NotRestored;
    const after = list(io, a, trash_home);
    defer free(a, after);
    try testing.expectEqual(@as(usize, 0), after.len);
}

test "top-dir trash: a relative Path resolves against the mount point, and restores" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const top = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(top);

    // A per-user top-dir trash "$top/.Trash-1000" holding "gone.txt" whose original was
    // "$top/sub/gone.txt", recorded RELATIVE ("sub/gone.txt") as the spec wants.
    try tmp.dir.createDirPath(io, ".Trash-1000/files");
    try tmp.dir.createDirPath(io, ".Trash-1000/info");
    try tmp.dir.writeFile(io, .{ .sub_path = ".Trash-1000/files/gone.txt", .data = "data" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".Trash-1000/info/gone.txt.trashinfo", .data = "[Trash Info]\nPath=sub/gone.txt\n" });
    try tmp.dir.createDirPath(io, "sub"); // the restore target dir must exist

    const trash_dir = try a.print("{s}/.Trash-1000", .{top});
    defer a.free(trash_dir);
    const restored = try a.print("{s}/sub/gone.txt", .{top});
    defer a.free(restored);

    // Before: listing with topdir=$top resolves the relative Path to an absolute one,
    // and nothing sits at the restore target yet.
    var buf = std.ArrayList(Item).empty;
    appendDir(io, a, trash_dir, top, &buf);
    const items: []Item = buf.toOwnedSlice(a) catch &.{};
    defer free(a, items);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings(restored, items[0].orig_path); // relative → absolute
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, restored, .{}));

    // After: restore puts it back at the resolved absolute location.
    try restore(io, a, items[0]);
    _ = Dir.cwd().statFile(io, restored, .{}) catch return error.NotRestored;
}

test "parseInfoDate reads the deletion date, in local time" {
    const a = parseInfoDate("[Trash Info]\nPath=/x\nDeletionDate=2026-11-07T23:41:05\n");
    const b = parseInfoDate("[Trash Info]\nDeletionDate=2026-11-07T23:42:05\nPath=/x\n");
    try std.testing.expect(a > 0);
    try std.testing.expectEqual(@as(i64, 60), b - a);
    try std.testing.expectEqual(@as(i64, 0), parseInfoDate("[Trash Info]\nPath=/x\n"));
    try std.testing.expectEqual(@as(i64, 0), parseInfoDate("DeletionDate=yesterday\n"));
}
