//! File-type filters for the chooser dialog. A portal FileChooser is expected to
//! honor the `filters` option (an app asks for "PDF files (*.pdf)", "Images", …), so
//! this turns filter *specs* into globs and matches names against them. Two producers
//! feed it: the portal service (MIME/glob patterns from the D-Bus request → globs via
//! `mimeToGlobs`) and the `--pick --filter "Name|*.png *.jpg"` CLI (via
//! `parseFilterSpec`). Pure and unit-tested; the dialog applies the active one to the
//! view the same way the quick-search glob is applied.

const std = @import("std");
const glob = @import("glob.zig");

/// FileFilter is a named set of globs, e.g. {"Images", ["*.png","*.jpg"]}. The
/// `globs` may be borrowed (static, as from `mimeToGlobs`) or owned (as from
/// `parseFilterSpec`); use `deinit` only on an owned one.
pub const FileFilter = struct {
    name: []const u8,
    globs: []const []const u8,

    /// matches reports whether name matches any glob, case-insensitively. An empty
    /// glob list matches everything.
    pub fn matches(self: FileFilter, name: []const u8) bool {
        if (self.globs.len == 0) return true;
        for (self.globs) |g| {
            if (glob.match(g, name, true)) return true;
        }
        return false;
    }

    /// primaryExt returns the filter's representative extension (".png" for
    /// {"Images", ["*.png", ...]}) as a slice into the matching glob, or null when
    /// there's no single concrete extension ("*", "*.*"); callers then leave a
    /// save name's extension alone. Case is preserved from the glob.
    pub fn primaryExt(self: FileFilter) ?[]const u8 {
        for (self.globs) |g| {
            if (globExt(g)) |e| return e;
        }
        return null;
    }

    /// deinit frees an owned FileFilter (one returned by parseFilterSpec).
    pub fn deinit(self: FileFilter, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        for (self.globs) |g| alloc.free(g);
        alloc.free(self.globs);
    }
};

/// globExt extracts ".ext" from a simple "*.ext" glob, rejecting "*", "*.*", and
/// any pattern with extra glob metacharacters.
fn globExt(g: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, g, "*.")) return null;
    const e = g[1..]; // drop the '*', keep ".ext"
    if (std.mem.eql(u8, e, ".") or std.mem.indexOfAny(u8, e, "*?[") != null) return null;
    return e;
}

/// parseFilterSpec parses a human-friendly filter spec ("Name | *.png *.jpg",
/// "Go source:*.go,*.mod", or bare "*.txt,*.md") into an owned FileFilter. Name and
/// patterns are split on '|' or ':'; patterns on commas and/or whitespace. Returns
/// null for an empty spec or one with no patterns. Free the result with `deinit`.
pub fn parseFilterSpec(alloc: std.mem.Allocator, spec: []const u8) !?FileFilter {
    const trimmed = std.mem.trim(u8, spec, " \t\r\n");
    if (trimmed.len == 0) return null;

    var name_part: []const u8 = "";
    var glob_part = trimmed;
    if (std.mem.indexOfAny(u8, trimmed, "|:")) |i| {
        name_part = std.mem.trim(u8, trimmed[0..i], " \t\r\n");
        glob_part = trimmed[i + 1 ..];
    }

    var globs = std.ArrayList([]const u8).empty;
    errdefer {
        for (globs.items) |g| alloc.free(g);
        globs.deinit(alloc);
    }
    var it = std.mem.tokenizeAny(u8, glob_part, ", \t\r\n");
    while (it.next()) |tok| try globs.append(alloc, try alloc.dupe(u8, tok));
    if (globs.items.len == 0) {
        globs.deinit(alloc);
        return null;
    }

    // No name given → label the filter with the patterns themselves.
    const name = if (name_part.len == 0)
        try std.mem.join(alloc, " ", globs.items)
    else
        try alloc.dupe(u8, name_part);

    return FileFilter{ .name = name, .globs = try globs.toOwnedSlice(alloc) };
}

/// mimeToGlobs maps a portal MIME-type filter to file globs (best effort: we don't
/// read the shared MIME database). Unknown types map to "*" so we never hide files the
/// app expected to be selectable. The returned slices are static.
pub fn mimeToGlobs(mime: []const u8) []const []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, mime, "image/png")) return &.{"*.png"};
    if (eq(u8, mime, "image/jpeg")) return &.{ "*.jpg", "*.jpeg" };
    if (eq(u8, mime, "image/gif")) return &.{"*.gif"};
    if (eq(u8, mime, "image/svg+xml")) return &.{"*.svg"};
    if (eq(u8, mime, "application/pdf")) return &.{"*.pdf"};
    if (eq(u8, mime, "text/plain")) return &.{"*.txt"};

    if (std.mem.startsWith(u8, mime, "image/"))
        return &.{ "*.png", "*.jpg", "*.jpeg", "*.gif", "*.bmp", "*.webp", "*.svg" };
    if (std.mem.startsWith(u8, mime, "video/"))
        return &.{ "*.mp4", "*.mkv", "*.webm", "*.avi", "*.mov" };
    if (std.mem.startsWith(u8, mime, "audio/"))
        return &.{ "*.mp3", "*.flac", "*.ogg", "*.wav", "*.m4a" };
    if (std.mem.startsWith(u8, mime, "text/"))
        return &.{ "*.txt", "*.md", "*.log", "*.csv" };

    return &.{"*"};
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "FileFilter.matches is case-insensitive; empty list matches all" {
    const f = FileFilter{ .name = "Images", .globs = &.{ "*.png", "*.JPG" } };
    try testing.expect(f.matches("photo.png"));
    try testing.expect(f.matches("PHOTO.PNG"));
    try testing.expect(f.matches("pic.jpg"));
    try testing.expect(!f.matches("notes.txt"));
    const all = FileFilter{ .name = "All", .globs = &.{} };
    try testing.expect(all.matches("anything.xyz"));
}

test "FileFilter.primaryExt picks the first concrete extension" {
    const f = FileFilter{ .name = "Images", .globs = &.{ "*", "*.png", "*.jpg" } };
    try testing.expectEqualStrings(".png", f.primaryExt().?);
    const none = FileFilter{ .name = "Any", .globs = &.{ "*", "*.*" } };
    try testing.expect(none.primaryExt() == null);
}

test "parseFilterSpec: name/pattern separators and defaults" {
    const a = testing.allocator;
    const named = (try parseFilterSpec(a, "Images | *.png *.jpg")).?;
    defer named.deinit(a);
    try testing.expectEqualStrings("Images", named.name);
    try testing.expectEqual(@as(usize, 2), named.globs.len);
    try testing.expectEqualStrings("*.png", named.globs[0]);

    // No name → labelled by its patterns; commas + colon separator.
    const bare = (try parseFilterSpec(a, "*.txt,*.md")).?;
    defer bare.deinit(a);
    try testing.expectEqualStrings("*.txt *.md", bare.name);
    try testing.expectEqual(@as(usize, 2), bare.globs.len);
}

test "parseFilterSpec: empty / no-pattern specs return null" {
    const a = testing.allocator;
    try testing.expect((try parseFilterSpec(a, "   ")) == null);
    try testing.expect((try parseFilterSpec(a, "Name |   ")) == null);
}

test "mimeToGlobs: exact, unknown→*, and prefix fallback" {
    const png = mimeToGlobs("image/png");
    try testing.expectEqual(@as(usize, 1), png.len);
    try testing.expectEqualStrings("*.png", png[0]);

    const unknown = mimeToGlobs("application/x-unknown");
    try testing.expectEqual(@as(usize, 1), unknown.len);
    try testing.expectEqualStrings("*", unknown[0]);

    var has_mp3 = false;
    for (mimeToGlobs("audio/mpeg")) |g| {
        if (std.mem.eql(u8, g, "*.mp3")) has_mp3 = true;
    }
    try testing.expect(has_mp3);
}
