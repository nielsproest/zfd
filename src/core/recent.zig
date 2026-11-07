//! Recent files: the "Recent" place in the sidebar. A virtual folder listing the
//! files the desktop recorded as recently used — the freedesktop
//! `recently-used.xbel` (GTK, KDE Frameworks, most apps) plus KDE's older
//! `RecentDocuments/*.desktop` links. Only local files that still exist are shown,
//! newest first, capped at `max_items`.
//!
//! The Browser shows the result like a subfolder search: it sits in "/" and each
//! entry's name is its path relative to "/" ("home/me/notes.txt"), so every
//! operation that joins dir + name (open, copy, trash, Properties) just works.
//! Loaded on the scanner thread (it stats every file), never the render thread.
//! GUI-free.

const std = @import("std");
const scan = @import("scan.zig");
const fsops = @import("fsops.zig");
const Dir = std.Io.Dir;

/// uri is the location string for the Recent place (history, tabs, the path bar).
pub const uri = "recent:///";

pub const max_items: usize = 300;

/// isUri reports whether `path` names the Recent place.
pub fn isUri(path: []const u8) bool {
    return std.mem.eql(u8, path, uri) or std.mem.eql(u8, path, "recent:") or std.mem.eql(u8, path, "recent:/");
}

/// Item is one recorded use: an absolute local path and when it was last used
/// (an ISO-8601 stamp; they compare correctly as strings).
const Item = struct { path: []u8, stamp: []const u8 };

/// scan_prefix starts a scanner request for the Recent place; the XDG data home
/// (where recently-used.xbel lives) follows it, since the core can't read the
/// environment itself.
pub const scan_prefix = "recent-scan:";

/// scanRequest builds the scanner request path for data home `data_home` (owned).
pub fn scanRequest(alloc: std.mem.Allocator, data_home: []const u8) ![]u8 {
    return std.mem.concat(alloc, u8, &.{ scan_prefix, data_home });
}

/// dataHomeOf returns the data home of a scanner request, or null if `path` isn't one.
pub fn dataHomeOf(path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, scan_prefix)) return null;
    return path[scan_prefix.len..];
}

/// load lists the recent files recorded under XDG data home `data` as a Listing
/// relative to "/" (see the file comment).
pub fn load(io: std.Io, alloc: std.mem.Allocator, data: []const u8) !scan.Listing {
    var items = std.ArrayList(Item).empty;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    defer items.deinit(alloc);

    const xbel_path = try std.fs.path.join(aa, &.{ data, "recently-used.xbel" });
    if (Dir.cwd().readFileAlloc(io, xbel_path, aa, .limited(16 << 20))) |xml| {
        parseXbel(aa, alloc, xml, &items);
    } else |_| {}
    const kde_dir = try std.fs.path.join(aa, &.{ data, "RecentDocuments" });
    readKdeRecent(io, aa, alloc, kde_dir, &items);

    std.mem.sort(Item, items.items, {}, newerFirst);

    var out = std.ArrayList(scan.Entry).empty;
    errdefer {
        for (out.items) |e| {
            alloc.free(e.name);
            if (e.link_target.len > 0) alloc.free(e.link_target);
        }
        out.deinit(alloc);
    }
    var seen = std.StringHashMap(void).init(aa);
    for (items.items) |it| {
        if (out.items.len >= max_items) break;
        if (seen.contains(it.path)) continue;
        seen.put(it.path, {}) catch continue;
        const b = fsops.brief(it.path) orelse continue; // gone since: don't list it
        const kind: scan.Kind = if (b.is_dir) .dir else .file;
        const entry = scan.entryAt(alloc, Dir.cwd(), it.path, it.path[1..], kind) catch continue;
        out.append(alloc, entry) catch {
            alloc.free(entry.name);
            continue;
        };
    }
    return .{ .entries = try out.toOwnedSlice(alloc) };
}

fn newerFirst(_: void, a: Item, b: Item) bool {
    return std.mem.order(u8, a.stamp, b.stamp) == .gt;
}

/// parseXbel pulls every <bookmark href="file:///…" visited="…"> out of an xbel
/// document. A deliberately small scan (no XML library): the format is flat and
/// machine-written. Paths go in `aa` (arena), the list in `alloc`.
fn parseXbel(aa: std.mem.Allocator, alloc: std.mem.Allocator, xml: []const u8, items: *std.ArrayList(Item)) void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, xml, pos, "<bookmark ")) |start| {
        const end = std.mem.indexOfScalarPos(u8, xml, start, '>') orelse break;
        pos = end;
        const tag = xml[start..end];
        const href = attr(tag, "href") orelse continue;
        const decoded_href = unescapeXml(aa, href) catch continue;
        const path = fsops.fileUriToPath(aa, decoded_href) orelse continue;
        if (path.len < 2 or path[0] != '/') continue;
        const stamp = attr(tag, "visited") orelse attr(tag, "modified") orelse attr(tag, "added") orelse "";
        items.append(alloc, .{ .path = path, .stamp = stamp }) catch {};
    }
}

/// attr returns attribute `name`'s raw (still XML-escaped) value in an opening tag.
fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, tag, pos, name)) |i| {
        pos = i + name.len;
        if (i == 0 or tag[i - 1] != ' ') continue;
        if (pos + 1 >= tag.len or tag[pos] != '=' or tag[pos + 1] != '"') continue;
        const vstart = pos + 2;
        const vend = std.mem.indexOfScalarPos(u8, tag, vstart, '"') orelse return null;
        return tag[vstart..vend];
    }
    return null;
}

/// unescapeXml resolves the five predefined XML entities.
fn unescapeXml(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            const ents = [_]struct { []const u8, u8 }{ .{ "&amp;", '&' }, .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&quot;", '"' }, .{ "&apos;", '\'' } };
            var hit = false;
            for (ents) |en| if (std.mem.startsWith(u8, s[i..], en[0])) {
                out.appendAssumeCapacity(en[1]);
                i += en[0].len;
                hit = true;
                break;
            };
            if (hit) continue;
        }
        out.appendAssumeCapacity(s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// readKdeRecent adds KDE's RecentDocuments/*.desktop links (URL=file:///…). Their
/// own modification time stands in for the use time.
fn readKdeRecent(io: std.Io, aa: std.mem.Allocator, alloc: std.mem.Allocator, dir_path: []const u8, items: *std.ArrayList(Item)) void {
    var d = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (!std.mem.endsWith(u8, e.name, ".desktop")) continue;
        const full = std.fs.path.join(aa, &.{ dir_path, e.name }) catch continue;
        const content = Dir.cwd().readFileAlloc(io, full, aa, .limited(64 << 10)) catch continue;
        var lines = std.mem.splitScalar(u8, content, '\n');
        const url = while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, "URL=")) break line[4..];
            if (std.mem.startsWith(u8, line, "URL[$e]=")) break line[8..];
        } else continue;
        const path = fsops.fileUriToPath(aa, url) orelse continue;
        if (path.len < 2) continue;
        const b = fsops.brief(full) orelse continue;
        items.append(alloc, .{ .path = path, .stamp = isoStamp(aa, b.mtime_secs) }) catch {};
    }
}

/// isoStamp renders epoch seconds as "YYYY-MM-DDTHH:MM:SSZ", comparable with xbel's.
fn isoStamp(alloc: std.mem.Allocator, secs: i64) []const u8 {
    if (secs <= 0) return "";
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return alloc.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch "";
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "parseXbel reads local bookmarks newest-first input and decodes them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<xbel version="1.0">
        \\  <bookmark href="file:///home/me/a%20b.txt" added="2026-01-01T10:00:00Z" modified="2026-01-02T10:00:00Z" visited="2026-01-03T10:00:00Z">
        \\  </bookmark>
        \\  <bookmark href="https://example.org/x" visited="2026-01-04T10:00:00Z"></bookmark>
        \\  <bookmark href="file:///home/me/Tom&amp;Jerry.png" modified="2026-02-01T00:00:00Z"></bookmark>
        \\</xbel>
    ;
    var items = std.ArrayList(Item).empty;
    defer items.deinit(testing.allocator);
    parseXbel(arena.allocator(), testing.allocator, xml, &items);
    try testing.expectEqual(@as(usize, 2), items.items.len);
    try testing.expectEqualStrings("/home/me/a b.txt", items.items[0].path);
    try testing.expectEqualStrings("2026-01-03T10:00:00Z", items.items[0].stamp);
    try testing.expectEqualStrings("/home/me/Tom&Jerry.png", items.items[1].path);
    try testing.expectEqualStrings("2026-02-01T00:00:00Z", items.items[1].stamp);
    std.mem.sort(Item, items.items, {}, newerFirst);
    try testing.expectEqualStrings("/home/me/Tom&Jerry.png", items.items[0].path);
}

test "isUri accepts the Recent spellings only" {
    try testing.expect(isUri("recent:///"));
    try testing.expect(isUri("recent:"));
    try testing.expect(!isUri("/recent"));
}
