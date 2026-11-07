//! A JPEG's EXIF Orientation: how the stored picture is turned (or mirrored) to be
//! shown. Phones store photos as the sensor saw them and set this tag instead of
//! turning the pixels, so a viewer that ignores it shows them sideways. We read it to
//! show pictures right, and rotate a JPEG the way macOS does: by changing the tag (a
//! couple of bytes), never re-encoding the picture. GUI-free; unit-tested.
//!
//! Values (EXIF): 1 as stored, 2 mirrored, 3 turned 180°, 4 flipped, 5 mirrored and
//! turned 270° clockwise, 6 turned 90° clockwise, 7 mirrored and turned 90°, 8 turned
//! 270° clockwise.

const std = @import("std");

/// Where the orientation lives in a JPEG.
const Found = struct {
    value: u8, // 1..8
    at: ?usize, // the value's offset in the file (null: there's no tag)
    big_endian: bool,
    has_exif: bool, // an EXIF block is there (with or without the tag)
};

/// orientation is the JPEG's Orientation (1 when it has none, or isn't a JPEG).
pub fn orientation(data: []const u8) u8 {
    return find(data).value;
}

/// turned reports whether `o` swaps width and height.
pub fn turned(o: u8) bool {
    return o >= 5 and o <= 8;
}

/// rotated is the orientation after turning the picture a quarter turn more.
pub fn rotated(o: u8, clockwise: bool) u8 {
    // Turning the shown picture composes with what the tag already does.
    const cw = [_]u8{ 0, 6, 7, 8, 5, 2, 3, 4, 1 };
    const ccw = [_]u8{ 0, 8, 5, 6, 7, 4, 1, 2, 3 };
    const v = if (o >= 1 and o <= 8) o else 1;
    return if (clockwise) cw[v] else ccw[v];
}

/// withOrientation is the JPEG `data` with its Orientation set to `o` (owned), or
/// error.NoRoom when it has an EXIF block without the tag (adding one means rewriting
/// the block's offsets; the caller falls back to re-encoding). A JPEG without any EXIF
/// gets a small one with just the tag. The picture data itself is never touched.
pub fn withOrientation(alloc: std.mem.Allocator, data: []const u8, o: u8) ![]u8 {
    const f = find(data);
    if (f.at) |at| {
        const out = try alloc.dupe(u8, data);
        if (f.big_endian) {
            out[at] = 0;
            out[at + 1] = o;
        } else {
            out[at] = o;
            out[at + 1] = 0;
        }
        return out;
    }
    if (f.has_exif) return error.NoRoom;
    if (data.len < 2 or data[0] != 0xFF or data[1] != 0xD8) return error.NotJpeg;
    // SOI, then APP1: "Exif\0\0", a little-endian TIFF header, IFD0 with one entry.
    const app1 = [_]u8{
        0xFF, 0xE1, 0x00, 0x22, // marker, length 34
        'E', 'x', 'i', 'f', 0, 0,
        'I', 'I', 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, // TIFF header, IFD0 at 8
        0x01, 0x00, // one entry
        0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, o, 0x00, 0x00, 0x00, // Orientation, SHORT, 1
        0x00, 0x00, 0x00, 0x00, // no next IFD
    };
    const out = try alloc.alloc(u8, data.len + app1.len);
    out[0] = 0xFF;
    out[1] = 0xD8;
    @memcpy(out[2 .. 2 + app1.len], &app1);
    @memcpy(out[2 + app1.len ..], data[2..]);
    return out;
}

fn find(data: []const u8) Found {
    var none = Found{ .value = 1, .at = null, .big_endian = false, .has_exif = false };
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) return none;
    var i: usize = 2;
    while (i + 4 <= data.len) {
        if (data[i] != 0xFF) return none;
        const marker = data[i + 1];
        if (marker == 0xDA or marker == 0xD9) return none; // the picture starts: no EXIF
        const len = @as(usize, data[i + 2]) << 8 | data[i + 3];
        if (len < 2 or i + 2 + len > data.len) return none;
        const seg = data[i + 4 .. i + 2 + len];
        if (marker == 0xE1 and seg.len >= 14 and std.mem.eql(u8, seg[0..6], "Exif\x00\x00")) {
            none.has_exif = true;
            const tiff_at = i + 4 + 6;
            if (tagIn(data[tiff_at .. i + 2 + len])) |t| return .{ .value = t.value, .at = tiff_at + t.at, .big_endian = t.big_endian, .has_exif = true };
            return none;
        }
        i += 2 + len;
    }
    return none;
}

const Tag = struct { value: u8, at: usize, big_endian: bool };

/// tagIn finds Orientation (0x0112) in IFD0 of a TIFF block.
fn tagIn(tiff: []const u8) ?Tag {
    if (tiff.len < 8) return null;
    const be = if (std.mem.eql(u8, tiff[0..2], "MM")) true else if (std.mem.eql(u8, tiff[0..2], "II")) false else return null;
    const ifd = rd32(tiff[4..8], be);
    if (ifd + 2 > tiff.len) return null;
    const n = rd16(tiff[ifd..][0..2], be);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const e = ifd + 2 + k * 12;
        if (e + 12 > tiff.len) return null;
        if (rd16(tiff[e..][0..2], be) != 0x0112) continue;
        const v = rd16(tiff[e + 8 ..][0..2], be);
        if (v < 1 or v > 8) return null;
        return .{ .value = @intCast(v), .at = e + 8, .big_endian = be };
    }
    return null;
}

fn rd16(b: *const [2]u8, be: bool) u16 {
    return std.mem.readInt(u16, b, if (be) .big else .little);
}

fn rd32(b: *const [4]u8, be: bool) u32 {
    return std.mem.readInt(u32, b, if (be) .big else .little);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "rotating composes with the orientation" {
    try testing.expectEqual(@as(u8, 6), rotated(1, true));
    try testing.expectEqual(@as(u8, 3), rotated(6, true));
    try testing.expectEqual(@as(u8, 1), rotated(rotated(rotated(rotated(1, true), true), true), true));
    for (1..9) |o| try testing.expectEqual(@as(u8, @intCast(o)), rotated(rotated(@intCast(o), true), false));
    try testing.expect(turned(6) and !turned(3));
}

test "a JPEG without EXIF gets one; with the tag, only the tag changes" {
    const a = testing.allocator;
    const bare = [_]u8{ 0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x04, 0x01, 0x02, 0xFF, 0xDA, 0x00, 0x02, 0xFF, 0xD9 };
    try testing.expectEqual(@as(u8, 1), orientation(&bare));
    const one = try withOrientation(a, &bare, 6);
    defer a.free(one);
    try testing.expectEqual(@as(u8, 6), orientation(one));
    try testing.expectEqualSlices(u8, bare[2..], one[one.len - (bare.len - 2) ..]); // the picture is untouched
    const two = try withOrientation(a, one, 3);
    defer a.free(two);
    try testing.expectEqual(one.len, two.len);
    try testing.expectEqual(@as(u8, 3), orientation(two));
    try testing.expectEqual(@as(u8, 1), orientation("not a jpeg"));
}
