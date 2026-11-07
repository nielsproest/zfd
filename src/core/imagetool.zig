//! Finder's Quick Actions on pictures: rotate them a quarter turn, convert them to
//! another format. A JPEG is rotated as macOS does it, by its EXIF orientation tag
//! (exif.zig), so the picture is never re-encoded; the rest is done with ffmpeg, the
//! one tool Quick Look already uses for what stb_image can't read (the actions show
//! only when it's installed). Work runs on a detached thread per action; the folder's
//! watcher brings the results in. GUI-free.

const std = @import("std");
const fsops = @import("fsops.zig");
const exif = @import("exif.zig");

/// isImage: a picture ffmpeg reads and writes.
pub fn isImage(name: []const u8) bool {
    const exts = [_][]const u8{ "png", "jpg", "jpeg", "webp", "bmp", "gif", "tif", "tiff", "tga" };
    const ext = extOf(name);
    for (exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

fn extOf(name: []const u8) []const u8 {
    const base = std.fs.path.basename(name);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    return base[dot + 1 ..];
}

/// Action is one Quick Action.
pub const Action = union(enum) {
    rotate: bool, // true = clockwise (right)
    convert: Format,
};

pub const Format = enum {
    jpeg,
    png,
    webp,

    pub fn ext(f: Format) []const u8 {
        return switch (f) {
            .jpeg => "jpg",
            .png => "png",
            .webp => "webp",
        };
    }
};

/// run does `action` on `paths` (absolute; copied) in the background, with ffmpeg at
/// `ffmpeg`.
pub fn run(io: std.Io, alloc: std.mem.Allocator, ffmpeg: []const u8, action: Action, paths: []const []const u8) void {
    const owned = alloc.alloc([]u8, paths.len) catch return;
    var n: usize = 0;
    for (paths) |p| {
        owned[n] = alloc.dupe(u8, p) catch break;
        n += 1;
    }
    const tool = alloc.dupe(u8, ffmpeg) catch {
        for (owned[0..n]) |p| alloc.free(p);
        alloc.free(owned);
        return;
    };
    const th = std.Thread.spawn(.{}, work, .{ io, alloc, tool, action, owned[0..n], owned }) catch {
        for (owned[0..n]) |p| alloc.free(p);
        alloc.free(owned);
        alloc.free(tool);
        return;
    };
    th.detach();
}

fn work(io: std.Io, alloc: std.mem.Allocator, ffmpeg: []u8, action: Action, paths: [][]u8, owned: [][]u8) void {
    defer {
        for (paths) |p| alloc.free(p);
        alloc.free(owned);
        alloc.free(ffmpeg);
    }
    for (paths) |p| switch (action) {
        .rotate => |cw| rotate(io, alloc, ffmpeg, p, cw),
        .convert => |f| convert(io, alloc, ffmpeg, p, f),
    };
}

/// rotate turns one picture a quarter turn in place: written beside it, then moved
/// over it, so a failure leaves the original alone.
fn rotate(io: std.Io, alloc: std.mem.Allocator, ffmpeg: []const u8, path: []const u8, cw: bool) void {
    const dir = std.fs.path.dirname(path) orelse return;
    const base = std.fs.path.basename(path);
    // Same extension, so ffmpeg writes the same format; hidden while it's written.
    const tmp = alloc.print("{s}/.{s}.zfd-rotate.{s}", .{ dir, base, extOf(base) }) catch return;
    defer alloc.free(tmp);
    const cwd = std.Io.Dir.cwd();
    if (std.ascii.eqlIgnoreCase(extOf(base), "jpg") or std.ascii.eqlIgnoreCase(extOf(base), "jpeg")) {
        if (rotateTag(io, alloc, path, tmp, cw)) return;
    }
    const ok = exec(io, &.{ ffmpeg, "-y", "-loglevel", "error", "-i", path, "-vf", if (cw) "transpose=1" else "transpose=2", "-frames:v", "1", "-update", "1", "-q:v", "2", tmp });
    if (ok) cwd.rename(tmp, cwd, path, io) catch {} else cwd.deleteFile(io, tmp) catch {};
}

/// rotateTag turns a JPEG by its orientation tag (written beside it, then moved over
/// it); false when it can't (no room for the tag), so ffmpeg does it instead.
fn rotateTag(io: std.Io, alloc: std.mem.Allocator, path: []const u8, tmp: []const u8, cw: bool) bool {
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, alloc, .limited(512 << 20)) catch return false;
    defer alloc.free(data);
    const out = exif.withOrientation(alloc, data, exif.rotated(exif.orientation(data), cw)) catch return false;
    defer alloc.free(out);
    cwd.writeFile(io, .{ .sub_path = tmp, .data = out }) catch return false;
    cwd.rename(tmp, cwd, path, io) catch {
        cwd.deleteFile(io, tmp) catch {};
        return false;
    };
    return true;
}

/// convert writes the picture as `f` next to it ("name.webp", or "name (copy).webp"
/// when that's taken).
fn convert(io: std.Io, alloc: std.mem.Allocator, ffmpeg: []const u8, path: []const u8, f: Format) void {
    const dir = std.fs.path.dirname(path) orelse return;
    const base = std.fs.path.basename(path);
    const stem = base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
    var nb: [512]u8 = undefined;
    const want = std.mem.print(&nb, "{s}.{s}", .{ stem, f.ext() }) catch return;
    const name = fsops.uniqueNameInDir(io, alloc, dir, want) catch return;
    defer alloc.free(name);
    const out = std.fs.path.join(alloc, &.{ dir, name }) catch return;
    defer alloc.free(out);
    _ = exec(io, &.{ ffmpeg, "-n", "-loglevel", "error", "-i", path, "-frames:v", "1", "-update", "1", "-q:v", "2", out });
}

fn exec(io: std.Io, argv: []const []const u8) bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

const testing = std.testing;

test "isImage goes by extension" {
    try testing.expect(isImage("/a/b.PNG") and isImage("x.jpeg") and !isImage("x.txt") and !isImage("noext"));
}
