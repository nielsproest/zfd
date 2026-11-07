//! Fitting text into a width the way Finder does: a name too long for its space
//! keeps its beginning and its end — "Video by haa…mjIFtv].mp4" — so the extension
//! and any trailing number stay readable. Measuring is the caller's (a font), passed
//! as any value with `fn width(self, []const u8) f32`; the tests use a fixed pitch.

const std = @import("std");

pub const ellipsis = "\u{2026}";

/// middle returns `text` if it fits in `max_w`, else as much of its start and end
/// as fits around an ellipsis, written into `buf`. Cuts fall on UTF-8 boundaries;
/// the end gets the extra character when the split is uneven.
pub fn middle(buf: []u8, text: []const u8, max_w: f32, measure: anytype) []const u8 {
    if (measure.width(text) <= max_w) return text;
    // Character boundaries (byte offsets), so the search works in characters.
    var bounds: [1025]u16 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < bounds.len - 1) : (n += 1) {
        bounds[n] = @intCast(i);
        i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i = @min(i, text.len);
    }
    if (i < text.len) return end(buf, text, max_w, measure); // too long to split evenly
    bounds[n] = @intCast(text.len);

    // Binary search the most characters kept (k) whose elided form fits.
    var lo: usize = 0;
    var hi: usize = n - 1;
    while (lo <= hi) {
        const k = lo + (hi - lo) / 2;
        const s = compose(buf, text, bounds[0 .. n + 1], k);
        if (measure.width(s) <= max_w) {
            lo = k + 1;
        } else {
            if (k == 0) break;
            hi = k - 1;
        }
    }
    return compose(buf, text, bounds[0 .. n + 1], lo -| 1);
}

/// compose writes the first ⌊k/2⌋ and last ⌈k/2⌉ characters around an ellipsis.
fn compose(buf: []u8, text: []const u8, bounds: []const u16, k: usize) []const u8 {
    const n = bounds.len - 1;
    const head = bounds[k / 2];
    const tail = bounds[n - (k - k / 2)];
    const need = head + ellipsis.len + (text.len - tail);
    if (need > buf.len) return text[0..head];
    @memcpy(buf[0..head], text[0..head]);
    @memcpy(buf[head..][0..ellipsis.len], ellipsis);
    @memcpy(buf[head + ellipsis.len ..][0 .. text.len - tail], text[tail..]);
    return buf[0..need];
}

/// end keeps the start of `text` and ends it with an ellipsis (for labels where the
/// end matters less, and as middle's fallback for huge strings).
pub fn end(buf: []u8, text: []const u8, max_w: f32, measure: anytype) []const u8 {
    if (measure.width(text) <= max_w) return text;
    var keep = text.len;
    while (keep > 0) {
        keep -= 1;
        while (keep > 0 and (text[keep] & 0xC0) == 0x80) keep -= 1;
        if (keep + ellipsis.len > buf.len) continue;
        @memcpy(buf[0..keep], text[0..keep]);
        @memcpy(buf[keep..][0..ellipsis.len], ellipsis);
        const s = buf[0 .. keep + ellipsis.len];
        if (measure.width(s) <= max_w) return s;
    }
    return ellipsis;
}

// ---------------------------------------------------------------------------
const testing = std.testing;

/// Every character (and the ellipsis) is 1 unit wide.
const Mono = struct {
    fn width(_: Mono, s: []const u8) f32 {
        return @floatFromInt(std.unicode.utf8CountCodepoints(s) catch s.len);
    }
};

test "middle keeps the start and the end" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("short.txt", middle(&buf, "short.txt", 20, Mono{}));
    // 11 units: 5 from the start, 5 from the end, 1 for the ellipsis.
    try testing.expectEqualStrings("Video\u{2026}].mp4", middle(&buf, "Video by haaXmjIFtv].mp4", 11, Mono{}));
    // Uneven split: the end gets the extra character.
    try testing.expectEqualStrings("Vide\u{2026}].mp4", middle(&buf, "Video by haaXmjIFtv].mp4", 10, Mono{}));
    try testing.expectEqualStrings("\u{2026}", middle(&buf, "abcdef", 1, Mono{}));
}

test "middle cuts between characters, not bytes" {
    var buf: [64]u8 = undefined;
    const s = middle(&buf, "æøåæøåæøå.txt", 7, Mono{});
    try testing.expect(std.unicode.utf8ValidateSlice(s));
    try testing.expectEqualStrings("æøå\u{2026}txt", s);
}

test "end keeps the start" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Unix Ex\u{2026}", end(&buf, "Unix Executable File", 8, Mono{}));
    try testing.expectEqualStrings("fits", end(&buf, "fits", 4, Mono{}));
}
