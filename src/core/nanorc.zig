//! nanorc: syntax colouring for Quick Look's text previews, from the editor nano's
//! syntax files (/usr/share/nano/*.nanorc, when nano is installed): which files a
//! syntax is for (by name, or by their first line), then rules that colour what a
//! regular expression matches, or what lies between a start and an end match
//! (spanning lines). Applied as nano does, a line at a time, later rules over
//! earlier ones. The expressions are POSIX extended ones (with GNU's \< \> \b),
//! matched with libc's regex. Thread-safe; worker threads only (it reads files).
//! GUI-free.

const std = @import("std");

/// Colour is one of nano's: 0 for none (the text's own), else 1-8 (red, green,
/// yellow, blue, magenta, cyan, white, black), plus `bright` for its bright version.
pub const Colour = u8;
pub const bright: Colour = 0x10;

/// Span colours bytes [start, end) of the text.
pub const Span = struct { start: u32, end: u32, colour: Colour };

// --- POSIX regex (glibc) ------------------------------------------------------------

const Regex = extern struct { opaque_bytes: [64]u8 align(8) }; // glibc's regex_t (x86-64)
const Match = extern struct { so: c_int, eo: c_int }; // regmatch_t
extern "c" fn regcomp(re: *Regex, pattern: [*:0]const u8, cflags: c_int) c_int;
extern "c" fn regexec(re: *const Regex, s: [*:0]const u8, nmatch: usize, m: [*]Match, eflags: c_int) c_int;
extern "c" fn regfree(re: *Regex) void;
const REG_EXTENDED = 1;
const REG_ICASE = 2;
const REG_NOTBOL = 1;

fn compile(alloc: std.mem.Allocator, pattern: []const u8, icase: bool) ?*Regex {
    const z = alloc.dupeSentinel(u8, pattern, 0) catch return null;
    defer alloc.free(z);
    const re = alloc.create(Regex) catch return null;
    if (regcomp(re, z.ptr, REG_EXTENDED | (if (icase) @as(c_int, REG_ICASE) else 0)) != 0) {
        alloc.destroy(re);
        return null;
    }
    return re;
}

/// find returns the first match of `re` in line[from..] (as offsets in `line`), or
/// null. `line` must be NUL-terminated just past its end.
fn find(re: *const Regex, line: [:0]const u8, from: usize) ?Match {
    if (from > line.len) return null;
    var m: [1]Match = undefined;
    const flags: c_int = if (from > 0) REG_NOTBOL else 0;
    if (regexec(re, line.ptr + from, 1, &m, flags) != 0) return null;
    if (m[0].so < 0) return null;
    return .{ .so = m[0].so + @as(c_int, @intCast(from)), .eo = m[0].eo + @as(c_int, @intCast(from)) };
}

// --- the syntaxes ------------------------------------------------------------------

const Rule = struct {
    colour: Colour,
    re: ?*Regex = null, // a single expression...
    start: ?*Regex = null, // ...or a region from a start match to an end match
    end: ?*Regex = null,
};

const Syntax = struct {
    name: []const u8,
    path: []const u8, // its file (rules are read on first use)
    files: std.ArrayList(*Regex) = .empty, // which file names it's for
    headers: std.ArrayList(*Regex) = .empty, // ...or first lines
    rules: std.ArrayList(Rule) = .empty,
    loaded: bool = false,
};

const dirs = [_][]const u8{ "/usr/share/nano", "/usr/share/nano/extra", "/usr/share/nano-syntax-highlighting" };

var mutex: std.Io.Mutex = .init;
var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var syntaxes: std.ArrayList(Syntax) = .empty;
var scanned = false;

/// scan reads every syntax file's header (its name, file-name and first-line
/// expressions), once. Under the lock.
fn scan(io: std.Io) void {
    if (scanned) return;
    scanned = true;
    const a = arena_state.allocator();
    for (dirs) |dir| {
        var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch continue;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |e| {
            if (!std.mem.endsWith(u8, e.name, ".nanorc")) continue;
            const path = std.fs.path.join(a, &.{ dir, e.name }) catch continue;
            const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(256 * 1024)) catch continue;
            readFile(a, path, data, false);
        }
    }
}

/// readFile goes through one syntax file: its syntax lines (and header lines) when
/// `rules` is false; the colour rules of the syntax at `path` when true.
fn readFile(a: std.mem.Allocator, path: []const u8, data: []const u8, rules: bool) void {
    var cur: ?*Syntax = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const sp = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const kw = line[0..sp];
        var rest = std.mem.trimStart(u8, line[sp..], " \t");
        if (std.mem.eql(u8, kw, "syntax")) {
            cur = null;
            // syntax NAME ["regex" ...]
            const name_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            const name = std.mem.trim(u8, rest[0..name_end], "\"");
            if (std.mem.eql(u8, name, "default") or std.mem.eql(u8, name, "none")) continue;
            if (rules) {
                for (syntaxes.items) |*s| if (std.mem.eql(u8, s.path, path) and std.mem.eql(u8, s.name, name)) {
                    cur = s;
                    break;
                };
                continue;
            }
            syntaxes.append(a, .{ .name = a.dupe(u8, name) catch continue, .path = path }) catch continue;
            cur = &syntaxes.items[syntaxes.items.len - 1];
            rest = rest[name_end..];
            var qs = Quoted{ .s = rest };
            while (qs.next()) |q| if (compile(a, q, false)) |re| cur.?.files.append(a, re) catch {};
            continue;
        }
        const s = cur orelse continue;
        if (!rules) {
            if (std.mem.eql(u8, kw, "header")) {
                var qs = Quoted{ .s = rest };
                while (qs.next()) |q| if (compile(a, q, false)) |re| s.headers.append(a, re) catch {};
            }
            continue;
        }
        const icase = std.mem.eql(u8, kw, "icolor");
        if (!icase and !std.mem.eql(u8, kw, "color")) continue;
        // color FG[,BG] "regex" ... | color FG start="regex" end="regex"
        const spec_end = std.mem.indexOfAny(u8, rest, " \t") orelse continue;
        const colour = parseColour(rest[0..spec_end]);
        rest = std.mem.trimStart(u8, rest[spec_end..], " \t");
        if (colour == 0) continue; // a background only, or none
        if (std.mem.startsWith(u8, rest, "start=")) {
            var qs = Quoted{ .s = rest["start=".len..] };
            const st = qs.next() orelse continue;
            const after = std.mem.trimStart(u8, qs.s, " \t");
            if (!std.mem.startsWith(u8, after, "end=")) continue;
            var qe = Quoted{ .s = after["end=".len..] };
            const en = qe.next() orelse continue;
            const re_s = compile(a, st, icase) orelse continue;
            const re_e = compile(a, en, icase) orelse continue;
            s.rules.append(a, .{ .colour = colour, .start = re_s, .end = re_e }) catch {};
            continue;
        }
        var qs = Quoted{ .s = rest };
        while (qs.next()) |q| if (compile(a, q, icase)) |re| s.rules.append(a, .{ .colour = colour, .re = re }) catch {};
    }
}

/// Quoted walks a line's "quoted" expressions. Like nano, a quote ends a string only
/// when followed by a space or the end of the line (expressions hold quotes).
const Quoted = struct {
    s: []const u8,
    fn next(q: *Quoted) ?[]const u8 {
        const t = std.mem.trimStart(u8, q.s, " \t");
        if (t.len == 0 or t[0] != '"') return null;
        var i: usize = 1;
        while (i < t.len) : (i += 1) {
            if (t[i] == '"' and (i + 1 == t.len or t[i + 1] == ' ' or t[i + 1] == '\t')) {
                q.s = t[i + 1 ..];
                return t[1..i];
            }
        }
        return null;
    }
};

/// parseColour reads a colour spec's foreground ("brightred", "lightblue,black",
/// "bold,green", "#f80"): 0 when there's none to use.
fn parseColour(spec: []const u8) Colour {
    const fg = spec[0 .. std.mem.indexOfScalar(u8, spec, ',') orelse spec.len];
    var it = std.mem.splitScalar(u8, spec, ',');
    // "bold,green" / "italic,red": the attribute comes first, the colour after it.
    var name = fg;
    if (std.mem.eql(u8, fg, "bold") or std.mem.eql(u8, fg, "italic")) {
        _ = it.next();
        name = it.next() orelse return 0;
    }
    var c: Colour = 0;
    var n = name;
    if (std.mem.startsWith(u8, n, "bright")) {
        c |= bright;
        n = n["bright".len..];
    } else if (std.mem.startsWith(u8, n, "light")) {
        c |= bright;
        n = n["light".len..];
    }
    const names = [_][]const u8{ "red", "green", "yellow", "blue", "magenta", "cyan", "white", "black" };
    for (names, 1..) |nm, i| if (std.mem.eql(u8, n, nm)) return c | @as(Colour, @intCast(i));
    // nano 7's extras and #rgb: the nearest of the eight.
    const near = [_]struct { []const u8, Colour }{
        .{ "orange", 3 | bright }, .{ "pink", 5 | bright }, .{ "purple", 5 },     .{ "lime", 2 | bright },
        .{ "mint", 6 | bright },   .{ "teal", 6 },          .{ "crimson", 1 },    .{ "plum", 5 },
        .{ "lagoon", 4 | bright }, .{ "sky", 4 | bright },  .{ "brown", 3 },      .{ "beet", 1 },
        .{ "ocher", 3 },           .{ "sand", 3 | bright }, .{ "slate", 7 },      .{ "latte", 7 | bright },
        .{ "grey", 7 },            .{ "gray", 7 },          .{ "normal", 0 },
    };
    for (near) |p| if (std.mem.eql(u8, n, p[0])) return p[1];
    if (n.len == 4 and n[0] == '#') return 6; // (an exact #rgb: shown as cyan)
    return 0;
}

/// syntaxFor finds the syntax for the file named `name` (its path will do), or by its
/// first line, and makes sure its rules are read. Under the lock.
fn syntaxFor(io: std.Io, name: []const u8, first_line: []const u8) ?*Syntax {
    scan(io);
    var nb: [std.fs.max_path_bytes + 1]u8 = undefined;
    const zname = std.fmt.bufPrintSentinel(&nb, "{s}", .{name}, 0) catch return null;
    var lb: [512]u8 = undefined;
    const zfirst = std.fmt.bufPrintSentinel(&lb, "{s}", .{first_line[0..@min(first_line.len, lb.len - 1)]}, 0) catch return null;
    var found: ?*Syntax = null;
    outer: for (syntaxes.items) |*s| for (s.files.items) |re| if (find(re, zname, 0) != null) {
        found = s;
        break :outer;
    };
    if (found == null) outer: for (syntaxes.items) |*s| for (s.headers.items) |re| if (find(re, zfirst, 0) != null) {
        found = s;
        break :outer;
    };
    const s = found orelse return null;
    if (!s.loaded) {
        s.loaded = true;
        const a = arena_state.allocator();
        const data = std.Io.Dir.cwd().readFileAlloc(io, s.path, a, .limited(256 * 1024)) catch return s;
        readFile(a, s.path, data, true);
    }
    return s;
}

// --- colouring ---------------------------------------------------------------------

/// highlight colours `text` as nano would the file named `name`: spans of colour,
/// in order (owned by the caller), or null when no syntax is for it.
pub fn highlight(io: std.Io, alloc: std.mem.Allocator, name: []const u8, text: []const u8) ?[]Span {
    mutex.lockUncancelable(io);
    const syn = syntaxFor(io, name, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len]);
    mutex.unlock(io);
    const s = syn orelse return null;
    if (s.rules.items.len == 0) return null;
    // One colour a byte, painted rule by rule (later over earlier), then run-length.
    const paint = alloc.alloc(Colour, text.len) catch return null;
    defer alloc.free(paint);
    @memset(paint, 0);
    var lbuf = std.ArrayList(u8).empty;
    defer lbuf.deinit(alloc);
    for (s.rules.items) |r| {
        var in_region = false;
        var off: usize = 0;
        while (off <= text.len) {
            const nl = std.mem.indexOfScalarPos(u8, text, off, '\n') orelse text.len;
            lbuf.clearRetainingCapacity();
            lbuf.appendSlice(alloc, text[off..nl]) catch return null;
            lbuf.append(alloc, 0) catch return null;
            const line: [:0]const u8 = lbuf.items[0 .. lbuf.items.len - 1 :0];
            if (r.re) |re| {
                var from: usize = 0;
                while (from <= line.len) {
                    const m = find(re, line, from) orelse break;
                    const so: usize = @intCast(m.so);
                    const eo: usize = @intCast(m.eo);
                    @memset(paint[off + so .. off + eo], r.colour);
                    from = if (eo > so) eo else eo + 1; // (an empty match: step on)
                }
            } else {
                var from: usize = 0;
                while (from <= line.len) {
                    if (!in_region) {
                        const m = find(r.start.?, line, from) orelse break;
                        in_region = true;
                        const so: usize = @intCast(m.so);
                        from = @intCast(m.eo);
                        @memset(paint[off + so .. off + from], r.colour);
                        if (m.eo == m.so) from += 1;
                    }
                    if (find(r.end.?, line, from)) |e| {
                        const eo: usize = @intCast(e.eo);
                        @memset(paint[off + from .. off + eo], r.colour);
                        in_region = false;
                        from = if (eo > from) eo else from + 1;
                    } else {
                        // On to the next line, the line break with it.
                        @memset(paint[off + @min(from, line.len) .. @min(off + line.len + 1, text.len)], r.colour);
                        break;
                    }
                }
            }
            off = nl + 1;
        }
    }
    var spans = std.ArrayList(Span).empty;
    errdefer spans.deinit(alloc);
    var i: usize = 0;
    while (i < paint.len) {
        if (paint[i] == 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < paint.len and paint[j] == paint[i]) j += 1;
        spans.append(alloc, .{ .start = @intCast(i), .end = @intCast(j), .colour = paint[i] }) catch return null;
        i = j;
    }
    return spans.toOwnedSlice(alloc) catch null;
}

// --- tests -------------------------------------------------------------------------

const testing = std.testing;

test "colour specs read as nano's" {
    try testing.expectEqual(@as(Colour, 1), parseColour("red"));
    try testing.expectEqual(@as(Colour, 4 | bright), parseColour("brightblue"));
    try testing.expectEqual(@as(Colour, 2 | bright), parseColour("lightgreen,black"));
    try testing.expectEqual(@as(Colour, 3), parseColour("bold,yellow"));
    try testing.expectEqual(@as(Colour, 0), parseColour(",blue")); // a background only
}

test "quoted expressions end only at a quote before a space" {
    var q = Quoted{ .s = " \"a\"b\" \"c\"" };
    try testing.expectEqualStrings("a\"b", q.next().?);
    try testing.expectEqualStrings("c", q.next().?);
    try testing.expect(q.next() == null);
}

test "a syntax colours single matches and regions over lines" {
    const io = testing.io;
    const a = std.heap.page_allocator;
    mutex.lockUncancelable(io);
    scanned = true; // (only this test's syntax, not the system's)
    readFile(arena_state.allocator(), "test.nanorc",
        \\syntax test "\.tst$"
        \\color red "\<if\>"
        \\color brightcyan start="/\*" end="\*/"
    , false);
    readFile(arena_state.allocator(), "test.nanorc",
        \\syntax test "\.tst$"
        \\color red "\<if\>"
        \\color brightcyan start="/\*" end="\*/"
    , true);
    for (syntaxes.items) |*s| if (std.mem.eql(u8, s.name, "test")) {
        s.loaded = true;
    };
    mutex.unlock(io);
    const text = "if x /* a\nb */ if";
    const spans = highlight(io, a, "f.tst", text).?;
    defer a.free(spans);
    // "if" red; the comment cyan across the line break; the last "if" red.
    try testing.expectEqual(@as(Colour, 1), spans[0].colour);
    try testing.expectEqual(@as(u32, 0), spans[0].start);
    try testing.expectEqual(@as(u32, 2), spans[0].end);
    try testing.expectEqual(@as(Colour, 6 | bright), spans[1].colour);
    try testing.expectEqualStrings("/* a\nb */", text[spans[1].start..spans[1].end]);
    try testing.expectEqualStrings("if", text[spans[2].start..spans[2].end]);
    try testing.expect(highlight(io, a, "f.txt", text) == null);
}
