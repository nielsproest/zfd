//! Shell-style glob matching for the quick-search box, ported from the Go
//! GoFileDialog `internal/ui/glob.go`. The Go version translated a glob into a
//! regex and let `regexp` run it; Zig's std has no regex, so we match directly:
//! simpler, allocation-free, and faster. Semantics are kept identical so the Go
//! test cases carry over as a conformance suite (see the tests below).
//!
//! Metacharacters: `*` matches any run of bytes including none, and it DOES cross
//! `/`, so a recursive search matches at any depth; `?` matches any single byte;
//! `[...]` is a character class (`[!...]` or `[^...]` negates, `a-z` is a range).
//! Everything else is literal. A match is anchored (whole string), per shell rules.
//!
//! NOTE: matching is byte-wise, not codepoint-wise. `?` therefore matches one
//! *byte*, not one UTF-8 rune (the Go version matched runes). This is faithful for
//! ASCII globs (which is every realistic quick-filter pattern) and keeps the hot
//! path branch-light. Codepoint-aware `?` is a deliberate future refinement.

const std = @import("std");

/// match reports whether `name` matches the shell glob `pattern` in full. When
/// `ci` is set the comparison is ASCII case-insensitive.
pub fn match(pattern: []const u8, name: []const u8, ci: bool) bool {
    // Iterative two-pointer wildcard match with `*` backtracking: O(len(pattern) *
    // len(name)) worst case, no recursion, no allocation. `star_p` remembers the
    // pattern index just after the most recent `*` so we can retry it against a
    // longer span of `name` when a later literal fails.
    var p: usize = 0;
    var s: usize = 0;
    var star_p: ?usize = null;
    var star_s: usize = 0;

    while (s < name.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            star_s = s;
            p += 1;
        } else if (p < pattern.len) {
            if (matchOne(pattern, p, name[s], ci)) |next_p| {
                p = next_p;
                s += 1;
            } else if (star_p) |sp| {
                p = sp + 1;
                star_s += 1;
                s = star_s;
            } else {
                return false;
            }
        } else if (star_p) |sp| {
            p = sp + 1;
            star_s += 1;
            s = star_s;
        } else {
            return false;
        }
    }
    // `name` exhausted: any remaining pattern must be all `*` to match.
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// quickMatch is the quick-search box rule: a pattern with NO glob metacharacter
/// (`*`, `?`, `[`) is treated as a substring ("report" matches anywhere in the
/// name), which is what people expect from a quick filter; anything with a
/// metacharacter is a full-name glob ("*.pdf" matches "a.pdf", not "a.pdfx").
pub fn quickMatch(pattern: []const u8, name: []const u8, ci: bool) bool {
    if (std.mem.indexOfAny(u8, pattern, "*?[") == null) {
        return containsFold(name, pattern, ci);
    }
    return match(pattern, name, ci);
}

/// matchOne tries to match the single byte `ch` against the pattern token that
/// starts at `pattern[p]` (a literal, `?`, or a `[...]` class). On success it
/// returns the pattern index just past the token; on mismatch it returns null.
fn matchOne(pattern: []const u8, p: usize, ch: u8, ci: bool) ?usize {
    switch (pattern[p]) {
        '?' => return p + 1,
        '[' => {
            if (classExtent(pattern, p)) |end| {
                return if (classMatches(pattern[p + 1 .. end - 1], ch, ci)) end else null;
            }
            // Unterminated class: treat '[' as a literal (matches the Go fallback).
            return if (eqFold(pattern[p], ch, ci)) p + 1 else null;
        },
        else => return if (eqFold(pattern[p], ch, ci)) p + 1 else null,
    }
}

/// classExtent returns the index just past the closing `]` of the class that
/// starts at `pattern[start]` (`== '['`), or null if the class is unterminated. A
/// `]` immediately after `[`, `[!`, or `[^` is a literal member, not the close.
fn classExtent(pattern: []const u8, start: usize) ?usize {
    var i = start + 1;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) i += 1;
    if (i < pattern.len and pattern[i] == ']') i += 1; // literal ']' member
    while (i < pattern.len and pattern[i] != ']') i += 1;
    if (i >= pattern.len) return null; // no closing ']'
    return i + 1;
}

/// classMatches reports whether `ch` is a member of the class body `body` (the
/// bytes strictly between `[` and `]`). A leading `!` or `^` negates. `a-z` is an
/// inclusive range; a `-` at either end is a literal.
fn classMatches(body: []const u8, ch: u8, ci: bool) bool {
    var b = body;
    var negate = false;
    if (b.len > 0 and (b[0] == '!' or b[0] == '^')) {
        negate = true;
        b = b[1..];
    }
    var hit = false;
    var i: usize = 0;
    while (i < b.len) {
        // A range is `x-y` where `-` is neither first nor last in the remaining body.
        if (i + 2 < b.len and b[i + 1] == '-' and b[i + 2] != ']') {
            if (inRangeFold(b[i], b[i + 2], ch, ci)) hit = true;
            i += 3;
        } else {
            if (eqFold(b[i], ch, ci)) hit = true;
            i += 1;
        }
    }
    return hit != negate;
}

/// containsFold reports whether `needle` occurs in `haystack`, ASCII
/// case-insensitively when `ci` is set. An empty needle always matches.
fn containsFold(haystack: []const u8, needle: []const u8, ci: bool) bool {
    if (!ci) return std.mem.indexOf(u8, haystack, needle) != null;
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and eqFold(haystack[i + j], needle[j], true)) j += 1;
        if (j == needle.len) return true;
    }
    return false;
}

inline fn eqFold(a: u8, b: u8, ci: bool) bool {
    if (!ci) return a == b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

inline fn inRangeFold(lo: u8, hi: u8, ch: u8, ci: bool) bool {
    if (!ci) return lo <= ch and ch <= hi;
    const c = std.ascii.toLower(ch);
    // Fold both range ends too, so [A-Z] with ci also spans a-z.
    const l = std.ascii.toLower(lo);
    const h = std.ascii.toLower(hi);
    return (l <= c and c <= h) or (lo <= ch and ch <= hi);
}

// ---------------------------------------------------------------------------
// Tests. These mirror the Go glob_test.go cases and add edge coverage; they are
// the conformance suite the eventual raw-core rewrite must also pass.
// ---------------------------------------------------------------------------
const testing = std.testing;

test "literal match is exact and anchored" {
    try testing.expect(match("report", "report", false));
    try testing.expect(!match("report", "reports", false));
    try testing.expect(!match("report", "areport", false));
    try testing.expect(!match("v2.0", "v2X0", false)); // '.' is literal, not regex
    try testing.expect(match("v2.0", "v2.0", false));
}

test "star matches any run including empty and crosses slashes" {
    try testing.expect(match("*.pdf", "a.pdf", false));
    try testing.expect(!match("*.pdf", "a.pdfx", false));
    try testing.expect(match("*", "anything/at/all", false));
    try testing.expect(match("*.go", "deep/nested/main.go", false)); // '*' crosses '/'
    try testing.expect(match("a*b", "ab", false)); // empty run
    try testing.expect(match("a*b", "axxxb", false));
    try testing.expect(match("**", "", false));
    try testing.expect(match("", "", false));
    try testing.expect(!match("", "x", false));
}

test "question matches exactly one byte" {
    try testing.expect(match("a?c", "abc", false));
    try testing.expect(!match("a?c", "ac", false));
    try testing.expect(!match("a?c", "abbc", false));
}

test "character classes and ranges" {
    try testing.expect(match("[abc]", "b", false));
    try testing.expect(!match("[abc]", "d", false));
    try testing.expect(match("file[0-9].txt", "file7.txt", false));
    try testing.expect(!match("file[0-9].txt", "fileA.txt", false));
    try testing.expect(match("[a-z]*", "hello", false));
}

test "negated classes" {
    try testing.expect(match("[!0-9]", "a", false));
    try testing.expect(!match("[!0-9]", "5", false));
    try testing.expect(match("[^abc]", "d", false));
    try testing.expect(!match("[^abc]", "a", false));
}

test "unterminated class falls back to literal bracket" {
    try testing.expect(match("[abc", "[abc", false));
    try testing.expect(!match("[abc", "a", false));
}

test "case-insensitive matching" {
    try testing.expect(match("*.PDF", "report.pdf", true));
    try testing.expect(match("[a-z]", "H", true));
    try testing.expect(!match("[a-z]", "H", false));
    try testing.expect(match("Report", "REPORT", true));
}

test "quickMatch: bare word is substring, metachar is full glob" {
    try testing.expect(quickMatch("report", "annual_report_2024.pdf", false));
    try testing.expect(quickMatch("report", "report", false));
    try testing.expect(!quickMatch("report", "summary.pdf", false));
    try testing.expect(quickMatch("*.pdf", "a.pdf", false)); // metachar => full glob
    try testing.expect(!quickMatch("*.pdf", "a.pdf.bak", false));
    try testing.expect(quickMatch("REPORT", "my_report.txt", true)); // ci substring
    try testing.expect(!quickMatch("report", "my_REPORT.txt", false)); // cs substring
}

test "quickMatch: empty pattern matches everything (substring path)" {
    try testing.expect(quickMatch("", "anything", false));
    try testing.expect(quickMatch("", "", false));
}
