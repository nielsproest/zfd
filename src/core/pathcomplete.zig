//! Path-bar autocompletion: given the text being typed in the address bar, find the
//! subdirectory that extends the trailing leaf: Explorer's inline suggestion. The
//! split/candidate logic is pure and unit-tested; `completeName` does the one readdir.
//!
//! Case-*sensitive* on purpose: the target filesystem is (Linux), so "Doc" completing
//! to "documents" would produce a path that doesn't exist. "Doc" completes "Documents";
//! "doc" does not. That mirrors shell tab-completion, which desktop users expect here.

const std = @import("std");
const Dir = std.Io.Dir;

pub const Split = struct { dir: []const u8, leaf: []const u8 };

/// splitLeaf divides a path into its directory part (up to and including the last '/')
/// and the trailing leaf being typed:
///   "/home/nil/Doc" → { "/home/nil/", "Doc" }
///   "/"             → { "/", "" }
///   "foo"           → { "", "foo" }   (no slash: not an absolute path, caller rejects)
pub fn splitLeaf(typed: []const u8) Split {
    if (std.mem.lastIndexOfScalar(u8, typed, '/')) |i| {
        return .{ .dir = typed[0 .. i + 1], .leaf = typed[i + 1 ..] };
    }
    return .{ .dir = "", .leaf = typed };
}

/// isCandidate reports whether `name` is a real completion of `leaf`: a strict,
/// case-sensitive prefix extension (longer than what's typed, so it adds something).
pub fn isCandidate(name: []const u8, leaf: []const u8) bool {
    return name.len > leaf.len and std.mem.startsWith(u8, name, leaf);
}

/// completeName scans `dir_path` for the alphabetically-first directory entry that
/// `isCandidate` of `leaf`, and returns its name (owned by `alloc`), or null when the
/// leaf is empty, the directory can't be read, or nothing matches. Alphabetical-first
/// makes the suggestion deterministic (readdir order isn't). Symlinks are included
/// since they commonly point at directories; a bad guess just fails to navigate.
pub fn completeName(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8, leaf: []const u8) ?[]u8 {
    if (leaf.len == 0) return null;
    var dir = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    return completeNameFrom(io, alloc, dir, leaf);
}

/// completeNameFrom is the primitive `completeName` wraps: the seam tests drive with a
/// temp-dir handle. NAME_MAX is 255, so a 256-byte "best so far" buffer never truncates.
pub fn completeNameFrom(io: std.Io, alloc: std.mem.Allocator, dir: Dir, leaf: []const u8) ?[]u8 {
    if (leaf.len == 0) return null;
    var best: [256]u8 = undefined;
    var best_len: usize = 0;
    var it = dir.iterate();
    while (true) {
        const next = it.next(io) catch break;
        const e = next orelse break;
        if (e.kind != .directory and e.kind != .sym_link) continue;
        if (!isCandidate(e.name, leaf)) continue;
        if (e.name.len > best.len) continue; // pathological (won't happen: NAME_MAX 255)
        if (best_len == 0 or std.mem.lessThan(u8, e.name, best[0..best_len])) {
            @memcpy(best[0..e.name.len], e.name);
            best_len = e.name.len;
        }
    }
    if (best_len == 0) return null;
    return alloc.dupe(u8, best[0..best_len]) catch null;
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "splitLeaf splits at the last slash" {
    const a = splitLeaf("/home/nil/Doc");
    try testing.expectEqualStrings("/home/nil/", a.dir);
    try testing.expectEqualStrings("Doc", a.leaf);

    const r = splitLeaf("/");
    try testing.expectEqualStrings("/", r.dir);
    try testing.expectEqualStrings("", r.leaf);

    const n = splitLeaf("foo");
    try testing.expectEqualStrings("", n.dir);
    try testing.expectEqualStrings("foo", n.leaf);

    const t = splitLeaf("/home/nil/");
    try testing.expectEqualStrings("/home/nil/", t.dir);
    try testing.expectEqualStrings("", t.leaf);
}

test "isCandidate: strict, case-sensitive prefix extension" {
    try testing.expect(isCandidate("Documents", "Doc"));
    try testing.expect(isCandidate("Documents", "")); // len>0 and startsWith "", but caller gates empty leaf
    try testing.expect(!isCandidate("Doc", "Doc")); // equal → nothing added
    try testing.expect(!isCandidate("documents", "Doc")); // case-sensitive
    try testing.expect(!isCandidate("Downloads", "Doc"));
}

test "completeNameFrom picks the alphabetically-first matching directory" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "Downloads");
    try tmp.dir.createDirPath(io, "Documents");
    try tmp.dir.createDirPath(io, "Desktop");
    try tmp.dir.createDirPath(io, "Music");
    try tmp.dir.writeFile(io, .{ .sub_path = "Docfile", .data = "x" }); // a file → ignored

    // "Doc" → Documents (Desktop doesn't match the "Doc" prefix; Docfile is a file).
    const m = completeNameFrom(io, a, tmp.dir, "Doc") orelse return error.NoMatch;
    defer a.free(m);
    try testing.expectEqualStrings("Documents", m);

    // "De" → Desktop; alphabetical-first among {Desktop} (Downloads doesn't match "De").
    const m2 = completeNameFrom(io, a, tmp.dir, "De") orelse return error.NoMatch;
    defer a.free(m2);
    try testing.expectEqualStrings("Desktop", m2);

    // No match, and empty leaf never matches.
    try testing.expect(completeNameFrom(io, a, tmp.dir, "Zzz") == null);
    try testing.expect(completeNameFrom(io, a, tmp.dir, "") == null);
}
