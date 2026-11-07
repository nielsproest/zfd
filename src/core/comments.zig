//! File comments (Finder's Get Info "Comments"), stored the freedesktop way in the
//! `user.xdg.comment` extended attribute, which Dolphin shows too, and which travels
//! with a copy made with xattrs. GUI-free.

const std = @import("std");
const linux = std.os.linux;

pub const attr_name = "user.xdg.comment";

/// read is `path`'s comment, into `buf` ("" when there's none or no xattr support).
/// Doesn't follow a final symlink.
pub fn read(path: [:0]const u8, buf: []u8) []const u8 {
    const rc = linux.lgetxattr(path.ptr, attr_name, buf.ptr, buf.len);
    if (linux.errno(rc) != .SUCCESS) return "";
    return buf[0..rc];
}

/// write sets `path`'s comment; an empty one removes it.
pub fn write(alloc: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    const pz = try alloc.dupeSentinel(u8, path, 0);
    defer alloc.free(pz);
    const rc = if (text.len == 0)
        linux.lremovexattr(pz.ptr, attr_name)
    else
        linux.lsetxattr(pz.ptr, attr_name, text.ptr, text.len, 0);
    switch (linux.errno(rc)) {
        .SUCCESS, .NODATA => {},
        .OPNOTSUPP => return error.CommentsNotSupported,
        .ACCES, .PERM => return error.AccessDenied,
        .NOSPC, .DQUOT, .@"2BIG", .RANGE => return error.NoSpaceLeft,
        else => return error.Unexpected,
    }
}

test "write and read a comment (when the filesystem supports xattrs)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "x" });
    const p = try tmp.dir.realPathFileAlloc(io, "f", a);
    defer a.free(p);
    write(a, p, "from the trip") catch |e| switch (e) {
        error.CommentsNotSupported => return error.SkipZigTest,
        else => return e,
    };
    const pz = try a.dupeSentinel(u8, p, 0);
    defer a.free(pz);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("from the trip", read(pz, &buf));
    try write(a, p, "");
    try std.testing.expectEqualStrings("", read(pz, &buf));
}
