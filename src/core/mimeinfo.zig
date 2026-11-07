//! MIME resolution for the "Opens with" column and friendlier type names, ported
//! from Go's internal/desktop/openswith.go. Pure file reads of the freedesktop shared
//! databases, no GLib/GIO linking (goal 5):
//!   extension → MIME  (from $datadir/mime/globs)
//!   MIME → default .desktop id  (from mimeapps.list, then mimeinfo.cache)
//!   id → app Name  (parsing the .desktop, via desktop.zig)
//! Loaded once, lazily, into a process-global cache (render-thread only, so no lock);
//! the whole thing is arena-backed, freed at exit by `deinit`.

const std = @import("std");
const desktop = @import("desktop.zig");
const xdg = @import("xdg.zig");
const Dir = std.Io.Dir;

const Db = struct {
    arena: std.heap.ArenaAllocator,
    ext_to_mime: std.StringHashMapUnmanaged([]const u8) = .empty,
    mime_to_id: std.StringHashMapUnmanaged([]const u8) = .empty,
    id_to_name: std.StringHashMapUnmanaged([]const u8) = .empty,
    app_dirs: [][]const u8 = &.{},
    io: std.Io,
};

var g_db: ?Db = null;

fn ensure(io: std.Io, gpa: std.mem.Allocator, home: []const u8) *Db {
    if (g_db == null) g_db = load(io, gpa, home);
    return &g_db.?;
}

/// deinit frees the cache (at exit, so the leak check stays quiet); the next lookup
/// would load it again.
pub fn deinit() void {
    if (g_db) |*db| db.arena.deinit();
    g_db = null;
}

fn load(io: std.Io, gpa: std.mem.Allocator, home: []const u8) Db {
    var db = Db{ .arena = std.heap.ArenaAllocator.init(gpa), .io = io };
    const a = db.arena.allocator();

    const data_dirs = xdg.dataDirs(a, null) catch &.{};
    const user_data = std.fs.path.join(a, &.{ home, ".local", "share" }) catch home;

    // ext → mime from each data dir's mime/globs (first definition wins).
    var all_dirs = std.ArrayList([]const u8).empty;
    all_dirs.append(a, user_data) catch {};
    for (data_dirs) |d| all_dirs.append(a, d) catch {};
    for (all_dirs.items) |d| {
        const globs = std.fs.path.join(a, &.{ d, "mime", "globs" }) catch continue;
        const content = Dir.cwd().readFileAlloc(io, globs, a, .limited(1 << 20)) catch continue;
        parseGlobs(a, &db, content);
    }

    // application dirs (for mimeinfo.cache + id→Name): the SAME set as the Open-with
    // picker (desktop.appDirs), so both agree on which apps exist (no flatpak/snap).
    db.app_dirs = desktop.appDirs(a, home) catch &.{};

    // mime → id: user + system mimeapps.list [Default Applications] first.
    const cfg = xdg.configHome(a, null, home) catch home;
    const user_mimeapps = std.fs.path.join(a, &.{ cfg, "mimeapps.list" }) catch "";
    for ([_][]const u8{ user_mimeapps, "/etc/xdg/mimeapps.list" }) |p| {
        if (p.len == 0) continue;
        const content = Dir.cwd().readFileAlloc(io, p, a, .limited(1 << 20)) catch continue;
        mergeAssoc(a, &db, content, "Default Applications");
    }
    // Fallback: mimeinfo.cache [MIME Cache] in each app dir.
    for (db.app_dirs) |d| {
        const cache = std.fs.path.join(a, &.{ d, "mimeinfo.cache" }) catch continue;
        const content = Dir.cwd().readFileAlloc(io, cache, a, .limited(1 << 20)) catch continue;
        mergeAssoc(a, &db, content, "MIME Cache");
    }
    return db;
}

fn parseGlobs(a: std.mem.Allocator, db: *Db, content: []const u8) void {
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const mime = line[0..colon];
        const glob = line[colon + 1 ..];
        if (!std.mem.startsWith(u8, glob, "*.")) continue;
        const ext = glob[1..]; // ".png"
        if (db.ext_to_mime.contains(ext)) continue;
        const k = a.dupe(u8, ext) catch continue;
        const v = a.dupe(u8, mime) catch continue;
        db.ext_to_mime.put(a, k, v) catch {};
    }
}

fn mergeAssoc(a: std.mem.Allocator, db: *Db, content: []const u8, group: []const u8) void {
    var in = false;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in = std.mem.eql(u8, line[1 .. line.len - 1], group);
            continue;
        }
        if (!in) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const mime = line[0..eq];
        if (db.mime_to_id.contains(mime)) continue;
        var ids = std.mem.tokenizeScalar(u8, line[eq + 1 ..], ';');
        const first = ids.next() orelse continue;
        if (first.len == 0) continue;
        const k = a.dupe(u8, mime) catch continue;
        const v = a.dupe(u8, first) catch continue;
        db.mime_to_id.put(a, k, v) catch {};
    }
}

fn appName(db: *Db, id: []const u8) []const u8 {
    if (db.id_to_name.get(id)) |n| return n;
    const a = db.arena.allocator();
    var name: []const u8 = "";
    for (db.app_dirs) |d| {
        const path = std.fs.path.join(a, &.{ d, id }) catch continue;
        const content = Dir.cwd().readFileAlloc(db.io, path, a, .limited(1 << 18)) catch continue;
        if (desktop.parseEntry(content)) |e| name = a.dupe(u8, e.name) catch "";
        break;
    }
    const k = a.dupe(u8, id) catch return name;
    db.id_to_name.put(a, k, name) catch {};
    return name;
}

fn lowerExt(name: []const u8, buf: []u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return "";
    const e = name[dot..]; // includes the dot, e.g. ".PNG"
    if (e.len > buf.len) return "";
    for (e, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..e.len];
}

/// mimeType returns the MIME type for a filename (by extension), or "".
pub fn mimeType(io: std.Io, gpa: std.mem.Allocator, home: []const u8, name: []const u8) []const u8 {
    var buf: [32]u8 = undefined;
    const ext = lowerExt(name, &buf);
    if (ext.len == 0) return "";
    const db = ensure(io, gpa, home);
    return db.ext_to_mime.get(ext) orelse "";
}

/// opensWith returns the display Name of the default app for `name`, or "".
pub fn opensWith(io: std.Io, gpa: std.mem.Allocator, home: []const u8, name: []const u8) []const u8 {
    var buf: [32]u8 = undefined;
    const ext = lowerExt(name, &buf);
    if (ext.len == 0) return "";
    const db = ensure(io, gpa, home);
    const mime = db.ext_to_mime.get(ext) orelse return "";
    const id = db.mime_to_id.get(mime) orelse return "";
    return appName(db, id);
}

/// typeName returns a friendly type label from the MIME type (e.g. "PNG image"), or
/// "" when the extension isn't in the MIME database (caller falls back).
pub fn typeName(io: std.Io, gpa: std.mem.Allocator, home: []const u8, name: []const u8, out: []u8) []const u8 {
    var buf: [32]u8 = undefined;
    const ext = lowerExt(name, &buf);
    if (ext.len == 0) return "";
    const db = ensure(io, gpa, home);
    const mime = db.ext_to_mime.get(ext) orelse return "";
    return prettyMime(mime, out);
}

/// prettyMime turns a MIME type into a label into `out`: curated names first, else a
/// generic "<SUBTYPE> <media>" form (image/x-canon-cr2 → "CR2 image").
pub fn prettyMime(mime: []const u8, out: []u8) []const u8 {
    const curated = [_]struct { m: []const u8, n: []const u8 }{
        .{ .m = "text/plain", .n = "Plain text" },       .{ .m = "application/pdf", .n = "PDF document" },
        .{ .m = "application/zip", .n = "Zip archive" }, .{ .m = "application/json", .n = "JSON" },
        .{ .m = "application/xml", .n = "XML" },         .{ .m = "image/png", .n = "PNG image" },
        .{ .m = "image/jpeg", .n = "JPEG image" },       .{ .m = "image/gif", .n = "GIF image" },
        .{ .m = "image/svg+xml", .n = "SVG image" },     .{ .m = "audio/mpeg", .n = "MP3 audio" },
        .{ .m = "video/mp4", .n = "MP4 video" },         .{ .m = "application/x-shellscript", .n = "Shell script" },
    };
    for (curated) |c| {
        if (std.mem.eql(u8, mime, c.m)) return c.n;
    }
    const slash = std.mem.indexOfScalar(u8, mime, '/') orelse return copyInto(out, mime);
    const media = mime[0..slash];
    var sub = mime[slash + 1 ..];
    if (std.mem.startsWith(u8, sub, "x-")) sub = sub[2..];
    if (std.mem.startsWith(u8, sub, "vnd.")) sub = sub[4..];
    if (std.mem.indexOfScalar(u8, sub, '+')) |i| sub = sub[0..i];
    if (std.mem.lastIndexOfScalar(u8, sub, '.')) |i| sub = sub[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, sub, '-')) |i| sub = sub[i + 1 ..];

    const suffix: []const u8 = if (std.mem.eql(u8, media, "image") or std.mem.eql(u8, media, "audio") or
        std.mem.eql(u8, media, "video") or std.mem.eql(u8, media, "font"))
        media
    else if (std.mem.eql(u8, media, "text")) "text" else if (std.mem.eql(u8, media, "application")) "file" else return copyInto(out, mime);

    var cbuf: [64]u8 = undefined;
    const cased = casing(sub, &cbuf); // separate buffer: mem.print reads it while writing `out`
    return std.mem.print(out, "{s} {s}", .{ cased, suffix }) catch copyInto(out, mime);
}

/// casing upper-cases short acronym-like subtypes (PNG, JSON), Title-cases longer.
fn casing(s: []const u8, buf: []u8) []const u8 {
    const n = @min(s.len, buf.len);
    if (s.len <= 5) {
        for (s[0..n], 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    } else {
        buf[0] = std.ascii.toUpper(s[0]);
        for (s[1..n], 1..) |ch, i| buf[i] = std.ascii.toLower(ch);
    }
    return buf[0..n];
}

fn copyInto(out: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, out.len);
    @memcpy(out[0..n], s[0..n]);
    return out[0..n];
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "prettyMime: curated and generic forms" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("PNG image", prettyMime("image/png", &buf));
    try testing.expectEqualStrings("PDF document", prettyMime("application/pdf", &buf));
    // generic: strip x-/vendor, take the tail, pick the media suffix
    try testing.expectEqualStrings("CR2 image", prettyMime("image/x-canon-cr2", &buf));
}
