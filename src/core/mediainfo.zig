//! mediainfo: the technical details of a picture, video or recording, for Get Info
//! and the Preview pane's More Info: the format, each stream's codec, dimensions,
//! pixel format and bit depth, colour (space, transfer, primaries: HDR called out),
//! frame rate, duration, bit rates, audio channels and rate. Read with ffprobe
//! (FFmpeg's, an optional dependency, as for video previews); without it there's
//! none. Run on a worker thread: ffprobe reads the file. GUI-free.

const std = @import("std");
const proc = @import("proc.zig");

const media_exts = [_][]const u8{
    // pictures
    "png",  "jpg", "jpeg", "gif", "bmp",  "tif",  "tiff", "webp", "heic", "heif",
    "avif", "jxl", "tga",  "psd", "exr",  "hdr",  "ico",  "jp2",  "dds",  "pnm",
    "ppm",  "pgm", "qoi",
    // video
     "mp4", "mkv",  "webm", "avi",  "mov",  "m4v",  "wmv",
    "flv",  "mpg", "mpeg", "ts",  "m2ts", "3gp",  "ogv",
    // audio
     "mp3",  "flac", "ogg",
    "opus", "m4a", "aac",  "wav", "wma",  "alac", "aiff", "aif",
};

/// isMedia reports whether `name` looks like a picture, video or recording (by
/// extension): the files worth asking ffprobe about.
pub fn isMedia(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    if (ext.len == 0 or ext.len > 8) return false;
    var lb: [8]u8 = undefined;
    const low = std.ascii.lowerString(&lb, ext);
    for (media_exts) |e| if (std.mem.eql(u8, low, e)) return true;
    return false;
}

const entries = "format=format_long_name,duration,bit_rate:" ++
    "stream=codec_type,codec_name,codec_long_name,profile,width,height,pix_fmt," ++
    "bits_per_raw_sample,color_range,color_space,color_transfer,color_primaries," ++
    "r_frame_rate,sample_rate,channels,channel_layout,bit_rate";

/// probe returns `path`'s details as "Label\tValue" lines (owned), or null when
/// ffprobe (`ffprobe`, its path) can't read it. Blocks while ffprobe reads.
pub fn probe(io: std.Io, alloc: std.mem.Allocator, ffprobe: []const u8, path: []const u8) ?[]u8 {
    const cap = proc.capture(io, alloc, &.{ ffprobe, "-v", "error", "-show_entries", entries, "-of", "flat", path }) orelse return null;
    defer alloc.free(cap.out);
    if (cap.code != 0) return null;
    return summarize(alloc, cap.out) catch null;
}

// --- reading ffprobe's flat output -------------------------------------------------

const Fields = struct {
    // format.*
    format: []const u8 = "",
    duration: []const u8 = "",
    bit_rate: []const u8 = "",
    // streams.stream.N.*, at most this many
    streams: [8]Stream = @splat(.{}),
    n: usize = 0,
};

const Stream = struct {
    codec_type: []const u8 = "",
    codec_name: []const u8 = "",
    codec_long_name: []const u8 = "",
    profile: []const u8 = "",
    width: []const u8 = "",
    height: []const u8 = "",
    pix_fmt: []const u8 = "",
    bits: []const u8 = "",
    color_range: []const u8 = "",
    color_space: []const u8 = "",
    color_transfer: []const u8 = "",
    color_primaries: []const u8 = "",
    frame_rate: []const u8 = "",
    sample_rate: []const u8 = "",
    channels: []const u8 = "",
    channel_layout: []const u8 = "",
    bit_rate: []const u8 = "",
};

/// value is a field's value: unquoted, and "" for ffprobe's "unknown"s.
fn value(raw: []const u8) []const u8 {
    const v = std.mem.trim(u8, raw, "\" \r");
    if (std.mem.eql(u8, v, "N/A") or std.mem.eql(u8, v, "unknown") or std.mem.eql(u8, v, "0/0")) return "";
    return v;
}

fn parse(out: []const u8) Fields {
    var f: Fields = .{};
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const v = value(line[eq + 1 ..]);
        if (std.mem.startsWith(u8, key, "format.")) {
            const k = key["format.".len..];
            if (std.mem.eql(u8, k, "format_long_name")) f.format = v else if (std.mem.eql(u8, k, "duration")) f.duration = v else if (std.mem.eql(u8, k, "bit_rate")) f.bit_rate = v;
            continue;
        }
        if (!std.mem.startsWith(u8, key, "streams.stream.")) continue;
        const rest = key["streams.stream.".len..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse continue;
        const i = std.fmt.parseInt(usize, rest[0..dot], 10) catch continue;
        if (i >= f.streams.len) continue;
        f.n = @max(f.n, i + 1);
        const s = &f.streams[i];
        const k = rest[dot + 1 ..];
        inline for (.{
            .{ "codec_type", "codec_type" },           .{ "codec_name", "codec_name" },
            .{ "codec_long_name", "codec_long_name" }, .{ "profile", "profile" },
            .{ "width", "width" },                     .{ "height", "height" },
            .{ "pix_fmt", "pix_fmt" },                 .{ "bits_per_raw_sample", "bits" },
            .{ "color_range", "color_range" },         .{ "color_space", "color_space" },
            .{ "color_transfer", "color_transfer" },   .{ "color_primaries", "color_primaries" },
            .{ "r_frame_rate", "frame_rate" },         .{ "sample_rate", "sample_rate" },
            .{ "channels", "channels" },               .{ "channel_layout", "channel_layout" },
            .{ "bit_rate", "bit_rate" },
        }) |m| {
            if (std.mem.eql(u8, k, m[0])) @field(s, m[1]) = v;
        }
    }
    return f;
}

// --- making it readable ----------------------------------------------------------

/// bitDepth is the bits per colour channel a pixel format carries (yuv420p10le →
/// "10-bit", rgba64be → "16-bit", rgbaf32 → "32-bit float"); `raw` (ffprobe's
/// bits_per_raw_sample) wins when it's given.
pub fn bitDepth(buf: []u8, pix_fmt: []const u8, raw: []const u8) []const u8 {
    if (std.fmt.parseInt(u8, raw, 10)) |b| {
        if (b > 0) return std.fmt.bufPrint(buf, "{d}-bit", .{b}) catch "";
    } else |_| {}
    if (pix_fmt.len == 0) return "";
    if (std.mem.indexOf(u8, pix_fmt, "f32") != null) return "32-bit float";
    if (std.mem.indexOf(u8, pix_fmt, "f16") != null) return "16-bit float";
    // 48/64 bits a pixel over 3/4 channels: 16 a channel.
    for ([_][]const u8{ "48", "64" }) |w| if (std.mem.indexOf(u8, pix_fmt, w) != null) return "16-bit";
    // "…p10le", "gray12", "ya16": the digits after the layout name.
    var i: usize = 0;
    while (i < pix_fmt.len) : (i += 1) {
        if (!std.ascii.isDigit(pix_fmt[i])) continue;
        var j = i;
        while (j < pix_fmt.len and std.ascii.isDigit(pix_fmt[j])) j += 1;
        const n = std.fmt.parseInt(u8, pix_fmt[i..j], 10) catch 0;
        // (yuv420/422/444 are chroma subsampling, not depth: skip those)
        const sub = std.mem.startsWith(u8, pix_fmt[0..i], "yuv") or std.mem.startsWith(u8, pix_fmt[0..i], "yuva") or std.mem.startsWith(u8, pix_fmt[0..i], "yuvj");
        if (!(sub and (n == 420 or n == 422 or n == 444 or n == 411 or n == 440 or n == 410))) {
            if (n == 24 or n == 32 or n == 8) return "8-bit"; // rgb24, rgba32, pal8
            if (n >= 9 and n <= 16) return std.fmt.bufPrint(buf, "{d}-bit", .{n}) catch "";
        }
        i = j;
    }
    return "8-bit";
}

/// transferName is a transfer function as people know it (HDR first).
fn transferName(t: []const u8) []const u8 {
    if (std.mem.eql(u8, t, "smpte2084")) return "PQ (HDR10)";
    if (std.mem.eql(u8, t, "arib-std-b67")) return "HLG (HDR)";
    if (std.mem.eql(u8, t, "iec61966-2-1")) return "sRGB";
    if (std.mem.eql(u8, t, "bt709") or std.mem.eql(u8, t, "bt1361e")) return "BT.709";
    if (std.mem.eql(u8, t, "linear")) return "Linear";
    return t;
}

/// shortName drops what a codec's or format's long name spells out in brackets:
/// "PNG (Portable Network Graphics) image" → "PNG image", "AAC (Advanced Audio
/// Coding)" → "AAC". (Short enough for a row.)
pub fn shortName(buf: []u8, long: []const u8) []const u8 {
    var n: usize = 0;
    var depth: usize = 0;
    for (long) |ch| {
        if (ch == '(') depth += 1;
        if (depth == 0) {
            if (n >= buf.len) break;
            // no double space where a bracket was
            if (!(ch == ' ' and n > 0 and buf[n - 1] == ' ')) {
                buf[n] = ch;
                n += 1;
            }
        }
        if (ch == ')' and depth > 0) depth -= 1;
    }
    return std.mem.trim(u8, buf[0..n], " ");
}

fn colourName(p: []const u8) []const u8 {
    if (std.mem.eql(u8, p, "gbr") or std.mem.eql(u8, p, "rgb")) return "RGB";
    if (std.mem.eql(u8, p, "bt709")) return "BT.709";
    if (std.mem.eql(u8, p, "bt2020") or std.mem.eql(u8, p, "bt2020nc") or std.mem.eql(u8, p, "bt2020c")) return "BT.2020";
    if (std.mem.eql(u8, p, "smpte432")) return "Display P3";
    if (std.mem.eql(u8, p, "bt470bg") or std.mem.eql(u8, p, "smpte170m")) return "BT.601";
    return p;
}

/// duration formats seconds as h:mm:ss (or m:ss, or "4.2 s" under a minute).
pub fn duration(buf: []u8, secs_text: []const u8) []const u8 {
    const secs = std.fmt.parseFloat(f64, secs_text) catch return "";
    if (secs <= 0) return "";
    if (secs < 60) return std.fmt.bufPrint(buf, "{d:.1} s", .{secs}) catch "";
    const t: u64 = @intFromFloat(@round(secs));
    if (t >= 3600) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ t / 3600, t / 60 % 60, t % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ t / 60, t % 60 }) catch "";
}

/// bitRate formats bits a second ("12.3 Mb/s", "320 kb/s").
pub fn bitRate(buf: []u8, bps_text: []const u8) []const u8 {
    const bps = std.fmt.parseFloat(f64, bps_text) catch return "";
    if (bps <= 0) return "";
    if (bps >= 1_000_000) return std.fmt.bufPrint(buf, "{d:.1} Mb/s", .{bps / 1_000_000}) catch "";
    return std.fmt.bufPrint(buf, "{d:.0} kb/s", .{bps / 1000}) catch "";
}

/// frameRate formats ffprobe's ratio ("24000/1001" → "23.976 fps", "25/1" → "25 fps").
pub fn frameRate(buf: []u8, ratio: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, ratio, '/') orelse return "";
    const n = std.fmt.parseFloat(f64, ratio[0..slash]) catch return "";
    const d = std.fmt.parseFloat(f64, ratio[slash + 1 ..]) catch return "";
    if (d == 0 or n == 0) return "";
    const fps = n / d;
    if (@abs(fps - @round(fps)) < 0.001) return std.fmt.bufPrint(buf, "{d:.0} fps", .{fps}) catch "";
    return std.fmt.bufPrint(buf, "{d:.3} fps", .{fps}) catch "";
}

fn row(out: *std.ArrayList(u8), alloc: std.mem.Allocator, label: []const u8, v: []const u8) !void {
    if (v.len == 0) return;
    try out.print(alloc, "{s}\t{s}\n", .{ label, v });
}

/// summarize turns ffprobe's flat output into "Label\tValue" lines.
pub fn summarize(alloc: std.mem.Allocator, out: []const u8) ![]u8 {
    const f = parse(out);
    var o = std.ArrayList(u8).empty;
    errdefer o.deinit(alloc);
    // A lone picture: one video stream, read as an image "sequence" (ffprobe gives a
    // JPEG a duration of a frame), or no duration at all. Its codec is its format.
    const still = f.n == 1 and std.mem.eql(u8, f.streams[0].codec_type, "video") and
        (f.duration.len == 0 or std.mem.endsWith(u8, f.format, "sequence"));
    var nm: [128]u8 = undefined;
    try row(&o, alloc, "Format", if (still) shortName(&nm, f.streams[0].codec_long_name) else f.format);
    var b1: [48]u8 = undefined;
    if (!still) try row(&o, alloc, "Duration", duration(&b1, f.duration));
    if (!still) try row(&o, alloc, "Bit rate", bitRate(&b1, f.bit_rate));
    var videos: usize = 0;
    var audios: usize = 0;
    var subs: usize = 0;
    for (f.streams[0..f.n]) |s| {
        if (std.mem.eql(u8, s.codec_type, "video")) {
            videos += 1;
            if (videos > 1) continue; // (a cover picture, a second angle: the first one)
            var cb: [160]u8 = undefined;
            var vn: [128]u8 = undefined;
            const vname = shortName(&vn, s.codec_long_name);
            if (!still) try row(&o, alloc, "Video", if (s.profile.len > 0) (std.fmt.bufPrint(&cb, "{s} ({s})", .{ vname, s.profile }) catch vname) else vname);
            var db: [48]u8 = undefined;
            if (s.width.len > 0 and s.height.len > 0) try row(&o, alloc, "Dimensions", std.fmt.bufPrint(&db, "{s} \u{00D7} {s}", .{ s.width, s.height }) catch "");
            try row(&o, alloc, "Pixel format", s.pix_fmt);
            var bb: [24]u8 = undefined;
            try row(&o, alloc, "Bit depth", bitDepth(&bb, s.pix_fmt, s.bits));
            try row(&o, alloc, "Colour", colourName(if (s.color_primaries.len > 0) s.color_primaries else s.color_space));
            try row(&o, alloc, "Transfer", transferName(s.color_transfer));
            try row(&o, alloc, "Range", if (std.mem.eql(u8, s.color_range, "pc")) "Full" else if (std.mem.eql(u8, s.color_range, "tv")) "Limited" else "");
            var fb: [24]u8 = undefined;
            if (!still) try row(&o, alloc, "Frame rate", frameRate(&fb, s.frame_rate));
            var vb: [24]u8 = undefined;
            if (!still) try row(&o, alloc, "Video bit rate", bitRate(&vb, s.bit_rate));
        } else if (std.mem.eql(u8, s.codec_type, "audio")) {
            audios += 1;
            if (audios > 1) continue;
            const layout = if (s.channel_layout.len > 0) s.channel_layout else s.channels;
            var rate: [24]u8 = undefined;
            const khz = if (std.fmt.parseFloat(f64, s.sample_rate)) |hz| (std.fmt.bufPrint(&rate, "{d:.1} kHz", .{hz / 1000}) catch "") else |_| "";
            var ab: [200]u8 = undefined;
            var an: [128]u8 = undefined;
            const name = if (s.codec_long_name.len > 0) shortName(&an, s.codec_long_name) else s.codec_name;
            try row(&o, alloc, "Audio", std.fmt.bufPrint(&ab, "{s}{s}{s}{s}{s}", .{ name, if (layout.len > 0) ", " else "", layout, if (khz.len > 0) ", " else "", khz }) catch name);
            var abr: [24]u8 = undefined;
            try row(&o, alloc, "Audio bit rate", bitRate(&abr, s.bit_rate));
        } else if (std.mem.eql(u8, s.codec_type, "subtitle")) subs += 1;
    }
    var nb: [24]u8 = undefined;
    if (audios > 1) try row(&o, alloc, "Audio tracks", std.fmt.bufPrint(&nb, "{d}", .{audios}) catch "");
    if (subs > 0) try row(&o, alloc, "Subtitles", std.fmt.bufPrint(&nb, "{d}", .{subs}) catch "");
    if (o.items.len > 0 and o.items[o.items.len - 1] == '\n') _ = o.pop();
    return o.toOwnedSlice(alloc);
}

// --- tests -----------------------------------------------------------------------

const testing = std.testing;

test "bit depth from the pixel format" {
    var b: [24]u8 = undefined;
    try testing.expectEqualStrings("10-bit", bitDepth(&b, "yuv420p10le", ""));
    try testing.expectEqualStrings("8-bit", bitDepth(&b, "yuv420p", ""));
    try testing.expectEqualStrings("8-bit", bitDepth(&b, "rgb24", ""));
    try testing.expectEqualStrings("8-bit", bitDepth(&b, "rgba", ""));
    try testing.expectEqualStrings("16-bit", bitDepth(&b, "rgba64be", ""));
    try testing.expectEqualStrings("16-bit", bitDepth(&b, "gray16le", ""));
    try testing.expectEqualStrings("12-bit", bitDepth(&b, "yuv444p12le", ""));
    try testing.expectEqualStrings("32-bit float", bitDepth(&b, "gbrapf32le", ""));
    try testing.expectEqualStrings("12-bit", bitDepth(&b, "yuvj420p", "12"));
}

test "durations, bit rates and frame rates read as people say them" {
    var b: [48]u8 = undefined;
    try testing.expectEqualStrings("1:02:03", duration(&b, "3723.4"));
    try testing.expectEqualStrings("3:05", duration(&b, "185.2"));
    try testing.expectEqualStrings("4.2 s", duration(&b, "4.2"));
    try testing.expectEqualStrings("12.3 Mb/s", bitRate(&b, "12345678"));
    try testing.expectEqualStrings("320 kb/s", bitRate(&b, "320000"));
    try testing.expectEqualStrings("23.976 fps", frameRate(&b, "24000/1001"));
    try testing.expectEqualStrings("25 fps", frameRate(&b, "25/1"));
}

test "an HDR video and a picture summarize" {
    const video =
        \\streams.stream.0.codec_long_name="H.265 / HEVC (High Efficiency Video Coding)"
        \\streams.stream.0.profile="Main 10"
        \\streams.stream.0.codec_type="video"
        \\streams.stream.0.width=3840
        \\streams.stream.0.height=2160
        \\streams.stream.0.pix_fmt="yuv420p10le"
        \\streams.stream.0.color_range="tv"
        \\streams.stream.0.color_space="bt2020nc"
        \\streams.stream.0.color_transfer="smpte2084"
        \\streams.stream.0.color_primaries="bt2020"
        \\streams.stream.0.r_frame_rate="24000/1001"
        \\streams.stream.0.bits_per_raw_sample="N/A"
        \\streams.stream.1.codec_long_name="AAC (Advanced Audio Coding)"
        \\streams.stream.1.codec_type="audio"
        \\streams.stream.1.sample_rate="48000"
        \\streams.stream.1.channels=2
        \\streams.stream.1.channel_layout="stereo"
        \\format.format_long_name="QuickTime / MOV"
        \\format.duration="185.200000"
        \\format.bit_rate="15000000"
    ;
    const v = try summarize(testing.allocator, video);
    defer testing.allocator.free(v);
    try testing.expect(std.mem.indexOf(u8, v, "Format\tQuickTime / MOV") != null);
    try testing.expect(std.mem.indexOf(u8, v, "Video\tH.265 / HEVC (Main 10)") != null);
    try testing.expect(std.mem.indexOf(u8, v, "Dimensions\t3840 \u{00D7} 2160") != null);
    try testing.expect(std.mem.indexOf(u8, v, "Bit depth\t10-bit") != null);
    try testing.expect(std.mem.indexOf(u8, v, "Transfer\tPQ (HDR10)") != null);
    try testing.expect(std.mem.indexOf(u8, v, "Colour\tBT.2020") != null);
    try testing.expect(std.mem.indexOf(u8, v, "Frame rate\t23.976 fps") != null);
    try testing.expect(std.mem.indexOf(u8, v, "Audio\tAAC, stereo, 48.0 kHz") != null);
    try testing.expect(std.mem.indexOf(u8, v, "Duration\t3:05") != null);

    const picture =
        \\streams.stream.0.codec_long_name="PNG (Portable Network Graphics) image"
        \\streams.stream.0.codec_type="video"
        \\streams.stream.0.width=640
        \\streams.stream.0.height=480
        \\streams.stream.0.pix_fmt="rgb24"
        \\streams.stream.0.r_frame_rate="25/1"
        \\format.format_long_name="piped png sequence"
        \\format.duration="N/A"
    ;
    const p = try summarize(testing.allocator, picture);
    defer testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "Format\tPNG image") != null);
    try testing.expect(std.mem.indexOf(u8, p, "Bit depth\t8-bit") != null);
    try testing.expect(std.mem.indexOf(u8, p, "Frame rate") == null); // (a picture has none)
}

test "a JPEG, which ffprobe reads as a one-frame sequence, is a picture" {
    const jpeg =
        \\streams.stream.0.codec_long_name="Motion JPEG"
        \\streams.stream.0.codec_type="video"
        \\streams.stream.0.width=1024
        \\streams.stream.0.height=768
        \\streams.stream.0.pix_fmt="yuvj444p"
        \\format.format_long_name="image2 sequence"
        \\format.duration="0.040000"
        \\format.bit_rate="6100000"
    ;
    const j = try summarize(testing.allocator, jpeg);
    defer testing.allocator.free(j);
    try testing.expect(std.mem.indexOf(u8, j, "Format\tMotion JPEG") != null);
    try testing.expect(std.mem.indexOf(u8, j, "Duration") == null);
    try testing.expect(std.mem.indexOf(u8, j, "Bit rate") == null);
    try testing.expect(std.mem.indexOf(u8, j, "Dimensions\t1024 \u{00D7} 768") != null);
}

test "media files by extension" {
    try testing.expect(isMedia("a.JPG"));
    try testing.expect(isMedia("clip.mkv"));
    try testing.expect(isMedia("song.flac"));
    try testing.expect(!isMedia("notes.txt"));
    try testing.expect(!isMedia("noext"));
}
