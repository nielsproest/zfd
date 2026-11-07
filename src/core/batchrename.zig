//! Batch rename: the naming rules for renaming many items at once (Dolphin's / Thunar's
//! "rename N items"). Pure — the dialog previews with these functions and the op-runner
//! applies the result — so every rule is unit-tested.
//!
//! Two modes:
//!   • Pattern — `#` is the item's number (a run of `#` sets the zero-padding: `###` →
//!     001, 002…), `*` is the original name without its extension. The original
//!     extension is kept unless the pattern names one itself ("photo_#" on "a.jpg" →
//!     "photo_1.jpg"; "doc_#.txt" → "doc_1.txt").
//!   • Find/replace — every occurrence of `find` in the name becomes `replace`.

const std = @import("std");

pub const Mode = enum { pattern, replace };

/// newName computes item `index` (0-based) of the batch's new name. Caller owns it.
pub fn newName(alloc: std.mem.Allocator, mode: Mode, a: []const u8, b: []const u8, name: []const u8, index: usize) ![]u8 {
    return switch (mode) {
        .pattern => applyPattern(alloc, a, name, index),
        .replace => if (a.len == 0) alloc.dupe(u8, name) else std.mem.replaceOwned(u8, alloc, name, a, b),
    };
}

fn applyPattern(alloc: std.mem.Allocator, pattern: []const u8, name: []const u8, index: usize) ![]u8 {
    const ext = extOf(name);
    const stem = name[0 .. name.len - ext.len];
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < pattern.len) {
        const ch = pattern[i];
        if (ch == '#') {
            var width: usize = 0;
            while (i < pattern.len and pattern[i] == '#') : (i += 1) width += 1;
            var nb: [24]u8 = undefined;
            const num = std.mem.print(&nb, "{d}", .{index + 1}) catch unreachable;
            if (num.len < width) try out.appendNTimes(alloc, '0', width - num.len);
            try out.appendSlice(alloc, num);
            continue;
        }
        if (ch == '*') try out.appendSlice(alloc, stem) else try out.append(alloc, ch);
        i += 1;
    }
    // Keep the original extension unless the pattern supplied one.
    if (extOf(pattern).len == 0) try out.appendSlice(alloc, ext);
    return out.toOwnedSlice(alloc);
}

/// extOf returns ".ext" (including the dot) or "" — a leading dot (".bashrc") is a
/// name, not an extension.
fn extOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return "";
    return name[dot..];
}

pub const Problem = enum { none, empty, invalid, duplicate, exists, unchanged };

/// check validates one proposed name against the batch: `names` are all the new
/// names, `olds` the current names in the same order, `taken` reports whether a name
/// already exists in the folder. An existing name is refused even if another item in
/// the batch is about to vacate it: the renames run one after another, so a swap
/// (a→b, b→a) would collide halfway through.
pub fn check(new: []const u8, i: usize, names: []const []const u8, olds: []const []const u8, taken: *const fn (ctx: *anyopaque, name: []const u8) bool, ctx: *anyopaque) Problem {
    if (new.len == 0) return .empty;
    if (std.mem.eql(u8, new, ".") or std.mem.eql(u8, new, "..") or std.mem.indexOfScalar(u8, new, '/') != null or std.mem.indexOfScalar(u8, new, 0) != null)
        return .invalid;
    for (names, 0..) |other, j| {
        if (j != i and std.mem.eql(u8, other, new)) return .duplicate;
    }
    if (std.mem.eql(u8, new, olds[i])) return .unchanged;
    if (taken(ctx, new)) return .exists;
    return .none;
}

// ---------------------------------------------------------------------------
const testing = std.testing;

fn expectName(expected: []const u8, mode: Mode, a: []const u8, b: []const u8, name: []const u8, index: usize) !void {
    const got = try newName(testing.allocator, mode, a, b, name, index);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "pattern numbering, padding and extension handling" {
    try expectName("photo_1.jpg", .pattern, "photo_#", "", "IMG_0042.jpg", 0);
    try expectName("photo_007.jpg", .pattern, "photo_###", "", "x.jpg", 6);
    try expectName("holiday-IMG_0042-2.jpg", .pattern, "holiday-*-#", "", "IMG_0042.jpg", 1);
    try expectName("doc_3.txt", .pattern, "doc_#.txt", "", "notes.md", 2); // pattern names its own ext
    try expectName("1234", .pattern, "#", "", "noext", 1233);
    try expectName("x.tar", .pattern, "x.tar", "", "a.gz", 0); // the pattern named an ext: it wins
    try expectName("cfg_1", .pattern, "cfg_#", "", ".bashrc", 0); // a dotfile has no ext
}

test "find/replace replaces every occurrence, empty find is a no-op" {
    try expectName("vacation 1 vacation", .replace, "holiday", "vacation", "holiday 1 holiday", 0);
    try expectName("same.txt", .replace, "", "x", "same.txt", 0);
    try expectName("a.txt", .replace, "a.txt.bak", "z", "a.txt", 0); // no match → unchanged
}

fn neverTaken(_: *anyopaque, _: []const u8) bool {
    return false;
}
fn takenFoo(_: *anyopaque, n: []const u8) bool {
    return std.mem.eql(u8, n, "foo");
}

test "check flags empty, invalid, duplicate, unchanged and existing names" {
    var dummy: u8 = 0;
    const olds = [_][]const u8{ "a", "b", "c" };
    const names = [_][]const u8{ "x", "x", "c" };
    try testing.expectEqual(Problem.duplicate, check("x", 0, &names, &olds, neverTaken, &dummy));
    try testing.expectEqual(Problem.unchanged, check("c", 2, &names, &olds, neverTaken, &dummy));
    const n2 = [_][]const u8{ "", "a/b", "foo" };
    try testing.expectEqual(Problem.empty, check("", 0, &n2, &olds, neverTaken, &dummy));
    try testing.expectEqual(Problem.invalid, check("a/b", 1, &n2, &olds, neverTaken, &dummy));
    try testing.expectEqual(Problem.exists, check("foo", 2, &n2, &olds, takenFoo, &dummy));
    const ok = [_][]const u8{ "p1", "p2", "p3" };
    try testing.expectEqual(Problem.none, check("p2", 1, &ok, &olds, neverTaken, &dummy));
}
