//! Search queries: the words typed in the search box, plus Finder-style filters:
//! `kind:image` (images, movies, music, documents, pdf, archives, folders, code),
//! `tag:red` (a colour tag), and the search bar's rules: `modified:` / `created:` with
//! `<7d` (within the last 7 days; h, d, w, m, y), `>7d` (longer ago), `<2026-01-31`
//! (before that day) or `>2026-01-31` (after it), and `size:>10MB` / `size:<500KB`.
//! What's left is the name pattern (glob.quickMatch: a bare word is a substring, *
//! and ? make a full glob). Pure; unit-tested.

const std = @import("std");
const scan = @import("scan.zig");
const glob = @import("glob.zig");
const tags = @import("tags.zig");

pub const Kind = enum { folder, image, video, audio, document, pdf, archive, code };

pub const Query = struct {
    text: []const u8 = "", // the name pattern (into the caller's buffer)
    // Text to find inside the files, typed after a '$' ("*.md$TODO"); "" for none
    // (into the caller's buffer). A '\$' is a '$' of the name or the text itself.
    content: []const u8 = "",
    kind: ?Kind = null,
    tag: tags.Mask = 0, // a tag's bit; 0 = any
    modified: Range = .{}, // seconds since the epoch
    created: Range = .{},
    size: Range = .{}, // bytes (files only)

    /// matchesDetails tests what needs the entry's stat: its tags, dates and size.
    pub fn matchesDetails(q: Query, e: scan.Entry) bool {
        if (!q.matchesTags(e.tags)) return false;
        if (!q.modified.has(e.mtime_secs)) return false;
        if (q.created.any() and (e.btime_secs == 0 or !q.created.has(e.btime_secs))) return false;
        if (q.size.any() and (e.isDir() or !q.size.has(@intCast(@min(e.size, std.math.maxInt(i64)))))) return false;
        return true;
    }

    /// matchesName reports whether a name of kind `k` passes the pattern and the kind
    /// filter (the tag needs the file's xattr; see matchesTags).
    pub fn matchesName(q: Query, name: []const u8, k: scan.Kind, ci: bool) bool {
        if (q.text.len > 0 and !glob.quickMatch(q.text, name, ci)) return false;
        if (q.kind) |want| {
            const e: scan.Entry = .{ .name = @constCast(name), .kind = k };
            if (!kindIs(want, scan.category(e))) return false;
        }
        return true;
    }

    pub fn matchesTags(q: Query, mask: tags.Mask) bool {
        return q.tag == 0 or mask & q.tag != 0;
    }

    /// matches is the whole test for a listed entry.
    pub fn matches(q: Query, e: scan.Entry, ci: bool) bool {
        return q.matchesName(std.fs.path.basename(e.name), e.kind, ci) and q.matchesDetails(e);
    }

    pub fn isEmpty(q: Query) bool {
        return q.text.len == 0 and q.kind == null and q.tag == 0 and !q.modified.any() and !q.created.any() and !q.size.any();
    }
};

/// Range is an inclusive lower and exclusive upper bound ("any" when both are open).
pub const Range = struct {
    min: i64 = std.math.minInt(i64),
    max: i64 = std.math.maxInt(i64),

    pub fn any(r: Range) bool {
        return r.min != std.math.minInt(i64) or r.max != std.math.maxInt(i64);
    }

    pub fn has(r: Range, v: i64) bool {
        return v >= r.min and v < r.max;
    }
};

/// Rule is one of the search bar's rules, as its query word says it.
pub const Rule = struct {
    what: What,
    op: Op,
    value: []const u8, // "7d", "2026-01-31", "10MB" (into the word)

    pub const What = enum { modified, created, size };
    pub const Op = enum {
        within, // < with a span: within the last …
        older, // > with a span: more than … ago
        before, // < with a date
        after, // > with a date
        bigger, // size >
        smaller, // size <
    };

    /// ofWord reads a rule word (`modified:<7d`, `size:>10MB`), or null.
    pub fn ofWord(word: []const u8) ?Rule {
        inline for (.{ .modified, .created, .size }) |w| {
            const prefix = @tagName(w) ++ ":";
            if (word.len > prefix.len + 1 and std.ascii.startsWithIgnoreCase(word, prefix)) {
                const rest = word[prefix.len..];
                const lt = rest[0] == '<';
                if (!lt and rest[0] != '>') return null;
                const v = rest[1..];
                const op: Op = if (w == .size) (if (lt) .smaller else .bigger) else if (isDate(v)) (if (lt) .before else .after) else (if (lt) .within else .older);
                return .{ .what = w, .op = op, .value = v };
            }
        }
        return null;
    }

    /// write renders the rule as its query word into `buf`.
    pub fn write(r: Rule, buf: []u8) []const u8 {
        const lt = switch (r.op) {
            .within, .before, .smaller => true,
            else => false,
        };
        return std.fmt.bufPrint(buf, "{s}:{c}{s}", .{ @tagName(r.what), @as(u8, if (lt) '<' else '>'), r.value }) catch "";
    }
};

fn isDate(v: []const u8) bool {
    return v.len == 10 and v[4] == '-' and v[7] == '-';
}

fn kindIs(want: Kind, cat: scan.Category) bool {
    return switch (want) {
        .folder => cat == .folder,
        .image => cat == .image,
        .video => cat == .video,
        .audio => cat == .audio,
        .document => cat == .text or cat == .pdf,
        .pdf => cat == .pdf,
        .archive => cat == .archive,
        .code => cat == .source,
    };
}

/// parse splits `raw` into filters and the name pattern, which is written into `buf`
/// (the other words, space-joined). An unknown `kind:`/`tag:` value stays as text.
pub fn parse(raw: []const u8, buf: []u8) Query {
    return parseAt(raw, buf, nowSecs());
}

/// parseAt is parse with "now" given (the rules' relative dates count back from it).
pub fn parseAt(raw_all: []const u8, buf: []u8, now: i64) Query {
    var q: Query = .{};
    // "name$text": the name part, and what to find inside the files.
    const cut = contentSplit(raw_all);
    const raw = raw_all[0..cut];
    var n: usize = 0;
    if (cut < raw_all.len) {
        // The text goes at the end of buf, unescaped; the name's words before it.
        const text = std.mem.trim(u8, raw_all[cut + 1 ..], " ");
        var tmp: [256]u8 = undefined;
        const un = unescape(&tmp, text);
        if (un.len > 0 and un.len < buf.len / 2) {
            const at = buf.len - un.len;
            @memcpy(buf[at..], un);
            q.content = buf[at..];
        }
    }
    const name_cap = buf.len - q.content.len;
    var it = std.mem.tokenizeScalar(u8, raw, ' ');
    while (it.next()) |word| {
        if (filterValue(word, "kind:")) |v| if (kindNamed(v)) |k| {
            q.kind = k;
            continue;
        };
        if (filterValue(word, "tag:")) |v| if (tagNamed(v)) |bit| {
            q.tag = bit;
            continue;
        };
        if (Rule.ofWord(word)) |r| if (applyRule(&q, r, now)) continue;
        if (n > 0 and n < name_cap) {
            buf[n] = ' ';
            n += 1;
        }
        var wb: [256]u8 = undefined;
        const w = unescape(&wb, word);
        const take = @min(w.len, name_cap - n);
        @memcpy(buf[n..][0..take], w[0..take]);
        n += take;
    }
    q.text = buf[0..n];
    return q;
}

/// contentSplit is where the first unescaped '$' is (the name ends, the text to
/// find inside the files begins), or raw.len when there's none.
pub fn contentSplit(raw: []const u8) usize {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len and raw[i + 1] == '$') {
            i += 1; // an escaped one: part of the name
            continue;
        }
        if (raw[i] == '$') return i;
    }
    return raw.len;
}

/// hasContent reports whether a query finds text inside files ("…$text").
pub fn hasContent(raw: []const u8) bool {
    const cut = contentSplit(raw);
    return cut < raw.len and std.mem.trim(u8, raw[cut + 1 ..], " ").len > 0;
}

fn unescape(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == '$') i += 1;
        buf[n] = s[i];
        n += 1;
    }
    return buf[0..n];
}

/// indexOfCase finds `needle` in `hay`, ignoring ASCII case when `ci`.
pub fn indexOfCase(hay: []const u8, needle: []const u8, ci: bool) ?usize {
    if (!ci) return std.mem.indexOf(u8, hay, needle);
    if (needle.len == 0) return 0;
    if (hay.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// applyRule narrows `q` by rule `r`; false when its value doesn't read (then the word
/// stays in the name pattern, like an unknown kind:).
fn applyRule(q: *Query, r: Rule, now: i64) bool {
    switch (r.what) {
        .size => {
            const n = parseSize(r.value) orelse return false;
            if (r.op == .bigger) q.size.min = n + 1 else q.size.max = n;
        },
        .modified, .created => {
            const range = if (r.what == .modified) &q.modified else &q.created;
            switch (r.op) {
                .within => range.min = now - (parseSpan(r.value) orelse return false),
                .older => range.max = now - (parseSpan(r.value) orelse return false),
                .before => range.max = parseDate(r.value) orelse return false,
                .after => range.min = (parseDate(r.value) orelse return false) + 86400, // after that day
                else => return false,
            }
        },
    }
    return true;
}

/// parseSpan reads "7d", "2w", "3m", "1y", "12h" as seconds.
pub fn parseSpan(v: []const u8) ?i64 {
    if (v.len < 2) return null;
    const n = std.fmt.parseInt(i64, v[0 .. v.len - 1], 10) catch return null;
    const unit: i64 = switch (std.ascii.toLower(v[v.len - 1])) {
        'h' => 3600,
        'd' => 86400,
        'w' => 7 * 86400,
        'm' => 30 * 86400,
        'y' => 365 * 86400,
        else => return null,
    };
    return n * unit;
}

/// parseSize reads "10MB", "500KB", "2GB", "100" (bytes; units of 1000, as Finder).
pub fn parseSize(v: []const u8) ?i64 {
    var end: usize = 0;
    while (end < v.len and (std.ascii.isDigit(v[end]) or v[end] == '.')) end += 1;
    if (end == 0) return null;
    const n = std.fmt.parseFloat(f64, v[0..end]) catch return null;
    const unit = v[end..];
    const mul: f64 = if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "B")) 1 else if (std.ascii.eqlIgnoreCase(unit, "KB") or std.ascii.eqlIgnoreCase(unit, "K")) 1e3 else if (std.ascii.eqlIgnoreCase(unit, "MB") or std.ascii.eqlIgnoreCase(unit, "M")) 1e6 else if (std.ascii.eqlIgnoreCase(unit, "GB") or std.ascii.eqlIgnoreCase(unit, "G")) 1e9 else if (std.ascii.eqlIgnoreCase(unit, "TB") or std.ascii.eqlIgnoreCase(unit, "T")) 1e12 else return null;
    return @intFromFloat(n * mul);
}

/// parseDate reads "2026-01-31" as that day's start (UTC), in seconds.
pub fn parseDate(v: []const u8) ?i64 {
    if (!isDate(v)) return null;
    const y = std.fmt.parseInt(i64, v[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, v[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, v[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31) return null;
    // Days from the civil date (Howard Hinnant's algorithm).
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return (era * 146097 + doe - 719468) * 86400;
}

/// nowSecs is the time now (Linux; this module stays libc-free).
pub fn nowSecs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

fn filterValue(word: []const u8, prefix: []const u8) ?[]const u8 {
    if (word.len <= prefix.len or !std.ascii.startsWithIgnoreCase(word, prefix)) return null;
    return word[prefix.len..];
}

/// kindNamed is the kind a `kind:` word names ("image", "movies", …), if any.
pub fn kindNamed(v: []const u8) ?Kind {
    const names = [_]struct { []const u8, Kind }{
        .{ "folder", .folder },     .{ "folders", .folder },     .{ "image", .image },      .{ "images", .image },
        .{ "picture", .image },     .{ "photo", .image },        .{ "video", .video },      .{ "videos", .video },
        .{ "movie", .video },       .{ "movies", .video },       .{ "audio", .audio },      .{ "music", .audio },
        .{ "document", .document }, .{ "documents", .document }, .{ "text", .document },    .{ "doc", .document },
        .{ "pdf", .pdf },           .{ "archive", .archive },    .{ "archives", .archive }, .{ "zip", .archive },
        .{ "code", .code },         .{ "source", .code },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(v, n[0])) return n[1];
    return null;
}

fn tagNamed(v: []const u8) ?tags.Mask {
    return if (tags.lookup(v)) |t| t.bit() else null;
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "parse pulls out kind: and tag: and keeps the rest as the pattern" {
    var buf: [64]u8 = undefined;
    const q = parse("kind:image  holiday tag:Red beach", &buf);
    try testing.expectEqual(Kind.image, q.kind.?);
    try testing.expectEqual(tags.list()[0].bit(), q.tag);
    try testing.expectEqualStrings("holiday beach", q.text);
    var b2: [16]u8 = undefined;
    try testing.expectEqualStrings("kind:nonsense", parse("kind:nonsense", &b2).text);
}

test "matches by kind, pattern and tag" {
    var buf: [64]u8 = undefined;
    const q = parse("kind:image cat", &buf);
    try testing.expect(q.matchesName("my cat.png", .file, true));
    try testing.expect(!q.matchesName("cat.txt", .file, true));
    try testing.expect(!q.matchesName("dog.jpg", .file, true));
    const t = parse("tag:blue", &buf);
    try testing.expect(t.matchesTags(tags.list()[4].bit()));
    try testing.expect(!t.matchesTags(0));
}

test "rules narrow by date and size" {
    var buf: [64]u8 = undefined;
    const now: i64 = 1_800_000_000;
    const q = parseAt("report modified:<7d size:>10MB", &buf, now);
    try testing.expectEqualStrings("report", q.text);
    const recent_big: scan.Entry = .{ .name = @constCast("report.pdf"), .kind = .file, .mtime_secs = now - 86400, .size = 20_000_000 };
    try testing.expect(q.matches(recent_big, true));
    var old = recent_big;
    old.mtime_secs = now - 30 * 86400;
    try testing.expect(!q.matches(old, true));
    var small = recent_big;
    small.size = 5_000_000;
    try testing.expect(!q.matches(small, true));

    try testing.expectEqual(@as(?i64, 0), parseDate("1970-01-01"));
    try testing.expectEqual(@as(?i64, 1_767_139_200), parseDate("2025-12-31"));
    const d = parseAt("modified:>2025-12-31", &buf, now);
    try testing.expect(d.modified.has(1_767_139_200 + 86400) and !d.modified.has(1_767_139_200 + 3600));
    try testing.expectEqualStrings("modified:nope", parseAt("modified:nope", &buf, now).text); // unread: stays text
    try testing.expectEqual(@as(?i64, 1500), parseSize("1.5KB"));

    const r = Rule.ofWord("created:<2w").?;
    try testing.expectEqual(Rule.Op.within, r.op);
    var wb: [32]u8 = undefined;
    try testing.expectEqualStrings("created:<2w", r.write(&wb));
    try testing.expectEqual(Rule.Op.before, Rule.ofWord("modified:<2026-01-01").?.op);
}

test "a $ splits the name from the text to find inside the files" {
    var buf: [512]u8 = undefined;
    const q = parseAt("*.md$TODO list", &buf, 0);
    try std.testing.expectEqualStrings("*.md", q.text);
    try std.testing.expectEqualStrings("TODO list", q.content);
    var b2: [512]u8 = undefined;
    const only = parseAt("$budget", &b2, 0);
    try std.testing.expectEqualStrings("", only.text);
    try std.testing.expectEqualStrings("budget", only.content);
    var b3: [512]u8 = undefined;
    const lit = parseAt("\\$RECYCLE", &b3, 0);
    try std.testing.expectEqualStrings("$RECYCLE", lit.text);
    try std.testing.expectEqualStrings("", lit.content);
    var b4: [512]u8 = undefined;
    const filt = parseAt("kind:document report$budget", &b4, 0);
    try std.testing.expectEqual(Kind.document, filt.kind.?);
    try std.testing.expectEqualStrings("report", filt.text);
    try std.testing.expectEqualStrings("budget", filt.content);
    try std.testing.expect(hasContent("x$y"));
    try std.testing.expect(!hasContent("x$ "));
    try std.testing.expect(!hasContent("\\$x"));
    try std.testing.expectEqual(@as(?usize, 4), indexOfCase("say TODO now", "todo", true));
    try std.testing.expect(indexOfCase("say TODO now", "todo", false) == null);
}
