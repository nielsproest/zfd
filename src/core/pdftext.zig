//! pdftext: what poppler's tools tell about a PDF, read: the words on each page and
//! where they sit (`pdftotext -bbox`), and its table of contents (`pdftohtml -xml`,
//! its <outline>). Plus what a reader does with them: find text, pick the word under
//! the pointer, and the text of a selection. Pure; unit-tested.

const std = @import("std");
const query = @import("query.zig");

/// Word is one word on a page: its box, in fractions of the page (0..1, from the top
/// left, upright), and where its text is in the page's `joined`.
pub const Word = struct { x0: f32, y0: f32, x1: f32, y1: f32, start: u32, len: u32 };

/// Page is a page's words, in reading order, and their texts joined by spaces (what
/// find searches).
pub const Page = struct { words: []Word = &.{}, joined: []const u8 = "" };

pub const Text = struct {
    arena: std.heap.ArenaAllocator,
    pages: []Page,

    pub fn destroy(self: *Text, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// Pos is a word in the document: its page and its index there.
pub const Pos = struct {
    page: u32,
    word: u32,
    pub fn before(a: Pos, b: Pos) bool {
        return a.page < b.page or (a.page == b.page and a.word < b.word);
    }
};

/// parseWords reads pdftotext -bbox's output (owned; destroy it).
pub fn parseWords(gpa: std.mem.Allocator, out: []const u8) !*Text {
    const self = try gpa.create(Text);
    self.* = .{ .arena = .init(gpa), .pages = &.{} };
    errdefer self.destroy(gpa);
    const a = self.arena.allocator();
    var pages = std.ArrayList(Page).empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, out, i, "<page ")) |ps| {
        const tag_end = std.mem.indexOfScalarPos(u8, out, ps, '>') orelse break;
        const tag = out[ps..tag_end];
        const pw = attr(tag, "width") orelse 1;
        const ph = attr(tag, "height") orelse 1;
        const page_end = std.mem.indexOfPos(u8, out, tag_end, "</page>") orelse out.len;
        var words = std.ArrayList(Word).empty;
        var joined = std.ArrayList(u8).empty;
        var j = tag_end;
        while (std.mem.indexOfPos(u8, out[0..page_end], j, "<word ")) |ws| {
            const wt_end = std.mem.indexOfScalarPos(u8, out, ws, '>') orelse break;
            const wt = out[ws..wt_end];
            const close = std.mem.indexOfPos(u8, out, wt_end, "</word>") orelse break;
            if (joined.items.len > 0) try joined.append(a, ' ');
            const start = joined.items.len;
            try decode(a, &joined, out[wt_end + 1 .. close]);
            try words.append(a, .{
                .x0 = (attr(wt, "xMin") orelse 0) / pw,
                .y0 = (attr(wt, "yMin") orelse 0) / ph,
                .x1 = (attr(wt, "xMax") orelse 0) / pw,
                .y1 = (attr(wt, "yMax") orelse 0) / ph,
                .start = @intCast(start),
                .len = @intCast(joined.items.len - start),
            });
            j = close + 7;
        }
        try pages.append(a, .{ .words = words.items, .joined = joined.items });
        i = page_end;
    }
    self.pages = pages.items;
    return self;
}

fn attr(tag: []const u8, comptime name: []const u8) ?f32 {
    const key = " " ++ name ++ "=\"";
    const at = std.mem.indexOf(u8, tag, key) orelse return null;
    const v0 = at + key.len;
    const v1 = std.mem.indexOfScalarPos(u8, tag, v0, '"') orelse return null;
    return std.fmt.parseFloat(f32, tag[v0..v1]) catch null;
}

/// decode appends `s` with its XML entities turned back into text.
fn decode(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') if (std.mem.indexOfScalarPos(u8, s, i, ';')) |semi| if (semi - i <= 10) {
            const e = s[i + 1 .. semi];
            const ch: ?u21 = if (std.mem.eql(u8, e, "amp")) '&' else if (std.mem.eql(u8, e, "lt")) '<' else if (std.mem.eql(u8, e, "gt")) '>' else if (std.mem.eql(u8, e, "quot")) '"' else if (std.mem.eql(u8, e, "apos")) '\'' else if (e.len > 1 and e[0] == '#')
                (if (e[1] == 'x' or e[1] == 'X') std.fmt.parseInt(u21, e[2..], 16) catch null else std.fmt.parseInt(u21, e[1..], 10) catch null)
            else
                null;
            if (ch) |cp| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                try out.appendSlice(a, buf[0..n]);
                i = semi + 1;
                continue;
            }
        };
        try out.append(a, s[i]);
        i += 1;
    }
}

/// Entry is a line of the table of contents: how deep, which page (from 0), its title.
pub const Entry = struct { depth: u8, page: u32, title: []const u8 };

/// parseOutline reads the <outline> of pdftohtml -xml's output (into `a`); empty if
/// the PDF has none.
pub fn parseOutline(a: std.mem.Allocator, out: []const u8) ![]Entry {
    var list = std.ArrayList(Entry).empty;
    const first = std.mem.indexOf(u8, out, "<outline>") orelse return &.{};
    var depth: i32 = 0;
    var i = first;
    while (i < out.len) {
        if (std.mem.startsWith(u8, out[i..], "<outline>")) {
            depth += 1;
            i += 9;
        } else if (std.mem.startsWith(u8, out[i..], "</outline>")) {
            depth -= 1;
            i += 10;
            if (depth <= 0) break;
        } else if (std.mem.startsWith(u8, out[i..], "<item")) {
            const te = std.mem.indexOfScalarPos(u8, out, i, '>') orelse break;
            const close = std.mem.indexOfPos(u8, out, te, "</item>") orelse break;
            const page = attr(out[i..te], "page");
            if (page) |p| if (p >= 1) {
                var t = std.ArrayList(u8).empty;
                try decode(a, &t, std.mem.trim(u8, out[te + 1 .. close], " \n\r\t"));
                try list.append(a, .{ .depth = @intCast(std.math.clamp(depth - 1, 0, 8)), .page = @intFromFloat(p - 1), .title = t.items });
            };
            i = close + 7;
        } else i += 1;
    }
    return list.items;
}

/// Hit is a match of find: on `page`, the bytes start..end of its `joined`.
pub const Hit = struct { page: u32, start: u32, end: u32 };

/// findAll finds every `q` in the document, page by page (at most `max`).
pub fn findAll(gpa: std.mem.Allocator, t: *const Text, q: []const u8, ci: bool, max: usize) ![]Hit {
    var hits = std.ArrayList(Hit).empty;
    errdefer hits.deinit(gpa);
    if (q.len == 0) return hits.toOwnedSlice(gpa);
    for (t.pages, 0..) |p, pi| {
        var at: usize = 0;
        while (at < p.joined.len) {
            const off = query.indexOfCase(p.joined[at..], q, ci) orelse break;
            const s = at + off;
            try hits.append(gpa, .{ .page = @intCast(pi), .start = @intCast(s), .end = @intCast(s + q.len) });
            if (hits.items.len >= max) return hits.toOwnedSlice(gpa);
            at = s + q.len;
        }
    }
    return hits.toOwnedSlice(gpa);
}

/// wordsOf is the words a stretch of a page's `joined` covers: [first, end).
pub fn wordsOf(p: Page, start: u32, end: u32) struct { first: u32, end: u32 } {
    var first: u32 = @intCast(p.words.len);
    var last: u32 = 0;
    for (p.words, 0..) |w, i| {
        if (w.start < end and w.start + w.len > start) {
            first = @min(first, @as(u32, @intCast(i)));
            last = @intCast(i + 1);
        }
    }
    return .{ .first = first, .end = @max(first, last) };
}

/// wordAt is the word nearest the point (fractions of the page), if the page has any.
pub fn wordAt(p: Page, fx: f32, fy: f32) ?u32 {
    var best: ?u32 = null;
    var best_d: f32 = std.math.floatMax(f32);
    for (p.words, 0..) |w, i| {
        const dx = if (fx < w.x0) w.x0 - fx else if (fx > w.x1) fx - w.x1 else 0;
        const dy = if (fy < w.y0) w.y0 - fy else if (fy > w.y1) fy - w.y1 else 0;
        const d = dx * dx + dy * dy * 4; // (a line away counts for more than a word away)
        if (d < best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }
    return best;
}

/// selected reports whether the word at `p` lies between `a` and `b` (either order).
pub fn selected(a: Pos, b: Pos, p: Pos) bool {
    const lo = if (b.before(a)) b else a;
    const hi = if (b.before(a)) a else b;
    return !p.before(lo) and !hi.before(p);
}

/// textOf is the text from word `a` to word `b` (either order): lines broken where the
/// page's lines break, pages by a blank line (owned).
pub fn textOf(gpa: std.mem.Allocator, t: *const Text, a: Pos, b: Pos) ![]u8 {
    const lo = if (b.before(a)) b else a;
    const hi = if (b.before(a)) a else b;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    var pg = lo.page;
    while (pg <= hi.page and pg < t.pages.len) : (pg += 1) {
        const p = t.pages[pg];
        if (p.words.len == 0) continue;
        const from: usize = if (pg == lo.page) lo.word else 0;
        const to: usize = if (pg == hi.page) @min(hi.word + 1, p.words.len) else p.words.len;
        if (out.items.len > 0) try out.appendSlice(gpa, "\n\n");
        var prev: ?Word = null;
        for (p.words[@min(from, p.words.len)..to]) |w| {
            if (prev) |q| {
                const new_line = w.y0 >= q.y1 - (q.y1 - q.y0) * 0.3 or w.x0 < q.x0;
                try out.append(gpa, if (new_line) '\n' else ' ');
            }
            try out.appendSlice(gpa, p.joined[w.start .. w.start + w.len]);
            prev = w;
        }
    }
    return out.toOwnedSlice(gpa);
}

// --- tests -------------------------------------------------------------------------

const testing = std.testing;

const sample =
    \\<doc>
    \\  <page width="100.0" height="200.0">
    \\    <word xMin="10" yMin="20" xMax="30" yMax="30">Hello</word>
    \\    <word xMin="35" yMin="20" xMax="60" yMax="30">big</word>
    \\    <word xMin="10" yMin="40" xMax="40" yMax="50">world&amp;co</word>
    \\  </page>
    \\  <page width="100.0" height="200.0">
    \\    <word xMin="10" yMin="20" xMax="30" yMax="30">hello</word>
    \\  </page>
    \\</doc>
;

test "parseWords: words, boxes as fractions, entities, pages" {
    const t = try parseWords(testing.allocator, sample);
    defer t.destroy(testing.allocator);
    try testing.expectEqual(@as(usize, 2), t.pages.len);
    try testing.expectEqualStrings("Hello big world&co", t.pages[0].joined);
    try testing.expectApproxEqAbs(@as(f32, 0.1), t.pages[0].words[0].x0, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.1), t.pages[0].words[0].y0, 0.001);
}

test "findAll, wordsOf, wordAt, textOf" {
    const t = try parseWords(testing.allocator, sample);
    defer t.destroy(testing.allocator);
    const hits = try findAll(testing.allocator, t, "hello", true, 100);
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqual(@as(u32, 1), hits[1].page);
    const two = try findAll(testing.allocator, t, "big world", true, 100);
    defer testing.allocator.free(two);
    const ws = wordsOf(t.pages[0], two[0].start, two[0].end);
    try testing.expectEqual(@as(u32, 1), ws.first);
    try testing.expectEqual(@as(u32, 3), ws.end);
    try testing.expectEqual(@as(?u32, 2), wordAt(t.pages[0], 0.2, 0.23));
    const txt = try textOf(testing.allocator, t, .{ .page = 1, .word = 0 }, .{ .page = 0, .word = 1 });
    defer testing.allocator.free(txt);
    try testing.expectEqualStrings("big\nworld&co\n\nhello", txt);
}

test "parseOutline: nested entries, their depth and page" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const xml =
        \\<pdf2xml><page number="1"></page>
        \\<outline>
        \\<item page="3">Intro</item>
        \\<outline>
        \\<item page="4">What &amp; why</item>
        \\</outline>
        \\<item page="9">Next</item>
        \\</outline>
        \\</pdf2xml>
    ;
    const es = try parseOutline(arena.allocator(), xml);
    try testing.expectEqual(@as(usize, 3), es.len);
    try testing.expectEqual(@as(u8, 1), es[1].depth);
    try testing.expectEqualStrings("What & why", es[1].title);
    try testing.expectEqual(@as(u32, 8), es[2].page);
}
