//! markdown: a light reading of Markdown for Quick Look: blocks (headings, lists,
//! quotes, fenced code, rules, paragraphs) and the inline marks that matter for
//! reading (strong, emphasis, code, links, images), turned into styled runs a view
//! lays out. Not a full CommonMark: tables and HTML stay as their text. Pure.

const std = @import("std");

pub const Block = struct {
    kind: Kind,
    level: u8 = 0, // a heading's 1-6; a list item's indent (in steps)
    number: u32 = 0, // an ordered item's number (0: a bullet)
    text: []const u8, // its text (code: the lines, joined by '\n'); borrows the source
};

pub const Kind = enum { heading, paragraph, item, quote, code, rule, blank };

/// blocks reads `src` into blocks (owned slice; the texts borrow `src`, except a
/// paragraph's or quote's joined lines, which go into `arena`).
pub fn blocks(arena: std.mem.Allocator, src: []const u8) ![]Block {
    var out = std.ArrayList(Block).empty;
    var lines = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(arena, std.mem.trimEnd(u8, l, "\r"));
    var i: usize = 0;
    while (i < lines.items.len) {
        const raw = lines.items[i];
        const line = std.mem.trimStart(u8, raw, " ");
        const indent = raw.len - line.len;
        if (line.len == 0) {
            try out.append(arena, .{ .kind = .blank, .text = "" });
            i += 1;
            continue;
        }
        // ``` fenced code ``` (or ~~~)
        if (std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~")) {
            const fence = line[0..3];
            var body = std.ArrayList(u8).empty;
            i += 1;
            while (i < lines.items.len and !std.mem.startsWith(u8, std.mem.trimStart(u8, lines.items[i], " "), fence)) : (i += 1) {
                if (body.items.len > 0) try body.append(arena, '\n');
                try body.appendSlice(arena, lines.items[i]);
            }
            i += 1; // (the closing fence)
            try out.append(arena, .{ .kind = .code, .text = body.items });
            continue;
        }
        // # Heading
        if (line[0] == '#') {
            var n: u8 = 0;
            while (n < line.len and line[n] == '#') n += 1;
            if (n <= 6 and (n == line.len or line[n] == ' ')) {
                try out.append(arena, .{ .kind = .heading, .level = n, .text = std.mem.trim(u8, std.mem.trimEnd(u8, line[n..], "#"), " ") });
                i += 1;
                continue;
            }
        }
        // --- *** ___ (a rule; a "---" under text is a heading's underline instead)
        if (isRule(line)) {
            if (out.items.len > 0 and out.items[out.items.len - 1].kind == .paragraph and line[0] != '*') {
                out.items[out.items.len - 1].kind = .heading;
                out.items[out.items.len - 1].level = if (line[0] == '=') 1 else 2;
            } else try out.append(arena, .{ .kind = .rule, .text = "" });
            i += 1;
            continue;
        }
        if (line.len >= 2 and line[0] == '=' and std.mem.trim(u8, line, "=").len == 0) {
            if (out.items.len > 0 and out.items[out.items.len - 1].kind == .paragraph) {
                out.items[out.items.len - 1].kind = .heading;
                out.items[out.items.len - 1].level = 1;
            }
            i += 1;
            continue;
        }
        // > quote (its lines joined)
        if (line[0] == '>') {
            var q = std.ArrayList(u8).empty;
            while (i < lines.items.len) : (i += 1) {
                const l = std.mem.trimStart(u8, lines.items[i], " ");
                if (l.len == 0 or l[0] != '>') break;
                if (q.items.len > 0) try q.append(arena, ' ');
                try q.appendSlice(arena, std.mem.trimStart(u8, l[1..], " "));
            }
            try out.append(arena, .{ .kind = .quote, .text = q.items });
            continue;
        }
        // - * + bullets, 1. numbers
        if (listMark(line)) |m| {
            // The item's text, and the lines that carry it on (until a blank or a new block).
            var t = std.ArrayList(u8).empty;
            try t.appendSlice(arena, line[m.len..]);
            i += 1;
            while (i < lines.items.len) : (i += 1) {
                const l = std.mem.trim(u8, lines.items[i], " ");
                if (l.len == 0 or l[0] == '#' or l[0] == '>' or std.mem.startsWith(u8, l, "```") or std.mem.startsWith(u8, l, "~~~") or listMark(l) != null or isRule(l)) break;
                try t.append(arena, ' ');
                try t.appendSlice(arena, l);
            }
            try out.append(arena, .{ .kind = .item, .level = @intCast(@min(indent / 2, 6)), .number = m.number, .text = t.items });
            continue;
        }
        // A paragraph: lines until a blank or another block starts.
        var p = std.ArrayList(u8).empty;
        while (i < lines.items.len) : (i += 1) {
            const l = std.mem.trim(u8, lines.items[i], " ");
            if (l.len == 0 or l[0] == '#' or l[0] == '>' or std.mem.startsWith(u8, l, "```") or std.mem.startsWith(u8, l, "~~~") or listMark(l) != null) break;
            if (isRule(l) or (l[0] == '=' and std.mem.trim(u8, l, "=").len == 0)) break;
            if (p.items.len > 0) try p.append(arena, ' ');
            try p.appendSlice(arena, l);
        }
        try out.append(arena, .{ .kind = .paragraph, .text = p.items });
    }
    return out.toOwnedSlice(arena);
}

fn isRule(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " ");
    if (t.len < 3) return false;
    const ch = t[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    var n: usize = 0;
    for (t) |x| {
        if (x == ch) n += 1 else if (x != ' ') return false;
    }
    return n >= 3;
}

fn listMark(line: []const u8) ?struct { len: usize, number: u32 } {
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') return .{ .len = 2, .number = 0 };
    var n: usize = 0;
    while (n < line.len and n < 9 and std.ascii.isDigit(line[n])) n += 1;
    if (n > 0 and n + 1 < line.len and (line[n] == '.' or line[n] == ')') and line[n + 1] == ' ')
        return .{ .len = n + 2, .number = std.fmt.parseInt(u32, line[0..n], 10) catch 1 };
    return null;
}

// --- inline ------------------------------------------------------------------------

pub const Style = enum { plain, strong, em, code, link, image };

/// Run is a stretch of a block's text in one style (the marks taken out).
pub const Run = struct { style: Style, text: []const u8 };

/// runs splits a block's text into styled runs: **strong**, *em* / _em_, `code`,
/// [link](url) (its text), ![image](url) (its alt). Texts borrow `text`.
pub fn runs(arena: std.mem.Allocator, text: []const u8) ![]Run {
    var out = std.ArrayList(Run).empty;
    var plain_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        var got: ?struct { run: Run, next: usize } = null;
        if (ch == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |e| got = .{ .run = .{ .style = .code, .text = text[i + 1 .. e] }, .next = e + 1 };
        } else if ((ch == '*' or ch == '_') and i + 1 < text.len and text[i + 1] == ch) {
            const mark = text[i .. i + 2];
            if (std.mem.indexOfPos(u8, text, i + 2, mark)) |e| if (e > i + 2) {
                got = .{ .run = .{ .style = .strong, .text = text[i + 2 .. e] }, .next = e + 2 };
            };
        } else if ((ch == '*' or ch == '_') and i + 1 < text.len and text[i + 1] != ' ') {
            // (an '_' inside a word, snake_case, isn't emphasis)
            const in_word = ch == '_' and i > 0 and std.ascii.isAlphanumeric(text[i - 1]);
            if (!in_word) if (std.mem.indexOfScalarPos(u8, text, i + 1, ch)) |e| if (e > i + 1 and text[e - 1] != ' ') {
                got = .{ .run = .{ .style = .em, .text = text[i + 1 .. e] }, .next = e + 1 };
            };
        } else if (ch == '[' or (ch == '!' and i + 1 < text.len and text[i + 1] == '[')) {
            const open = if (ch == '!') i + 1 else i;
            if (std.mem.indexOfScalarPos(u8, text, open + 1, ']')) |close| {
                if (close + 1 < text.len and text[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close + 2, ')')) |paren| {
                        got = .{ .run = .{ .style = if (ch == '!') .image else .link, .text = text[open + 1 .. close] }, .next = paren + 1 };
                    }
                }
            }
        }
        if (got) |g| {
            if (i > plain_start) try out.append(arena, .{ .style = .plain, .text = text[plain_start..i] });
            try out.append(arena, g.run);
            i = g.next;
            plain_start = i;
        } else i += 1;
    }
    if (plain_start < text.len) try out.append(arena, .{ .style = .plain, .text = text[plain_start..] });
    return out.toOwnedSlice(arena);
}

/// isMarkdown reports whether a file named `name` is Markdown.
pub fn isMarkdown(name: []const u8) bool {
    const exts = [_][]const u8{ ".md", ".markdown", ".mdown", ".mkd" };
    for (exts) |e| if (name.len > e.len and std.ascii.endsWithIgnoreCase(name, e)) return true;
    return false;
}

// --- tests -------------------------------------------------------------------------

const testing = std.testing;

test "blocks: headings, lists, quotes, code, rules, paragraphs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src =
        \\# Title
        \\Some text
        \\goes on.
        \\
        \\- one
        \\  - nested
        \\2. two
        \\> quoted
        \\> more
        \\```zig
        \\const x = 1;
        \\```
        \\---
        \\Sub
        \\===
    ;
    const bs = try blocks(arena.allocator(), src);
    try testing.expectEqual(Kind.heading, bs[0].kind);
    try testing.expectEqualStrings("Title", bs[0].text);
    try testing.expectEqualStrings("Some text goes on.", bs[1].text);
    try testing.expectEqual(Kind.item, bs[3].kind);
    try testing.expectEqual(@as(u8, 1), bs[4].level); // nested
    try testing.expectEqual(@as(u32, 2), bs[5].number);
    try testing.expectEqualStrings("quoted more", bs[6].text);
    try testing.expectEqual(Kind.code, bs[7].kind);
    try testing.expectEqualStrings("const x = 1;", bs[7].text);
    try testing.expectEqual(Kind.rule, bs[8].kind);
    try testing.expectEqual(Kind.heading, bs[9].kind); // the === underline
    try testing.expectEqual(@as(u8, 1), bs[9].level);
}

test "a list item's text carries on over the lines below it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const bs = try blocks(arena.allocator(), "- **Off-thread** a worker\n  reads dirs\n- next");
    try testing.expectEqual(@as(usize, 2), bs.len);
    try testing.expectEqualStrings("**Off-thread** a worker reads dirs", bs[0].text);
}

test "runs: strong, emphasis, code, links, images; snake_case stays" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rs = try runs(arena.allocator(), "A **bold** and *it* `x` [ZFD](https://x) ![pic](p.png) snake_case_name");
    try testing.expectEqual(Style.strong, rs[1].style);
    try testing.expectEqualStrings("bold", rs[1].text);
    try testing.expectEqual(Style.em, rs[3].style);
    try testing.expectEqual(Style.code, rs[5].style);
    try testing.expectEqual(Style.link, rs[7].style);
    try testing.expectEqualStrings("ZFD", rs[7].text);
    try testing.expectEqual(Style.image, rs[9].style);
    try testing.expectEqualStrings(" snake_case_name", rs[10].text);
}
