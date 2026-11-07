//! Decoding a picture for display (thumbnails, Quick Look): stb_image through
//! preview_img.c, then turned upright by its EXIF orientation, as a phone photo
//! expects (core/exif.zig reads the tag).

const std = @import("std");
const core = @import("core");

extern fn zfd_image_load(path: [*:0]const u8, max_dim: c_int, w: *c_int, h: *c_int) ?[*]u8;
extern fn zfd_image_orient(px: [*]u8, w: c_int, h: c_int, o: c_int, ow: *c_int, oh: *c_int) [*]u8;
pub extern fn zfd_image_size(path: [*:0]const u8, w: *c_int, h: *c_int) c_int;
pub extern fn zfd_image_free(px: [*]u8) void;

/// load decodes `path` (shrunk to `max_dim` on its longest side) and turns it
/// upright; null when stb_image can't read it.
pub fn load(io: std.Io, path: [*:0]const u8, max_dim: c_int, w: *c_int, h: *c_int) ?[*]u8 {
    const px = zfd_image_load(path, max_dim, w, h) orelse return null;
    const o = orientationOf(io, std.mem.span(path));
    if (o <= 1) return px;
    var nw: c_int = 0;
    var nh: c_int = 0;
    const out = zfd_image_orient(px, w.*, h.*, o, &nw, &nh);
    w.* = nw;
    h.* = nh;
    return out;
}

/// orientationOf reads a JPEG's orientation from its first 128 KB (EXIF sits at the
/// start); 1 for anything else.
pub fn orientationOf(io: std.Io, path: []const u8) u8 {
    const ext = std.fs.path.extension(path);
    if (!std.ascii.eqlIgnoreCase(ext, ".jpg") and !std.ascii.eqlIgnoreCase(ext, ".jpeg")) return 1;
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return 1;
    defer f.close(io);
    var buf: [128 * 1024]u8 = undefined;
    var r = f.reader(io, &.{});
    const n = r.interface.readSliceShort(&buf) catch return 1;
    return core.exif.orientation(buf[0..n]);
}
