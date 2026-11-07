//! Freedesktop XDG base directories, ported from the Go `internal/xdg`. The
//! resolution logic is pure (it takes the relevant env values as arguments and
//! returns a path), so it is unit-tested without mutating the process
//! environment. Thin `*FromEnv` wrappers read the real env and delegate.
//!
//! Callers own the returned slices and must free them with the same allocator.

const std = @import("std");

/// configHome is $XDG_CONFIG_HOME (when set and non-empty), else `home/.config`.
pub fn configHome(alloc: std.mem.Allocator, xdg_config_home: ?[]const u8, home: []const u8) ![]u8 {
    if (nonEmpty(xdg_config_home)) |d| return alloc.dupe(u8, d);
    return std.fs.path.join(alloc, &.{ home, ".config" });
}

/// dataHome is $XDG_DATA_HOME (when set and non-empty), else `home/.local/share`.
pub fn dataHome(alloc: std.mem.Allocator, xdg_data_home: ?[]const u8, home: []const u8) ![]u8 {
    if (nonEmpty(xdg_data_home)) |d| return alloc.dupe(u8, d);
    return std.fs.path.join(alloc, &.{ home, ".local", "share" });
}

/// dataDirs splits $XDG_DATA_DIRS (or the spec default) into entries, dropping
/// empties. Earlier entries take precedence, per the spec. The returned slice and
/// each entry are owned by the caller; free with `freeDirs`.
pub fn dataDirs(alloc: std.mem.Allocator, xdg_data_dirs: ?[]const u8) ![][]u8 {
    const val = nonEmpty(xdg_data_dirs) orelse "/usr/local/share:/usr/share";
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |d| alloc.free(d);
        out.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, val, ':');
    while (it.next()) |d| {
        if (d.len == 0) continue; // skip empty entries (leading/trailing/`::`)
        try out.append(alloc, try alloc.dupe(u8, d));
    }
    return out.toOwnedSlice(alloc);
}

/// freeDirs releases a slice returned by dataDirs.
pub fn freeDirs(alloc: std.mem.Allocator, dirs: [][]u8) void {
    for (dirs) |d| alloc.free(d);
    alloc.free(dirs);
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    if (v) |s| {
        if (s.len > 0) return s;
    }
    return null;
}

// Env values are supplied by the caller (in 0.16 the environment comes from the
// process Init's Environ.Map), so these stay pure functions of their inputs.

// ---------------------------------------------------------------------------
const testing = std.testing;

test "configHome prefers XDG_CONFIG_HOME when set" {
    const a = testing.allocator;
    const got = try configHome(a, "/custom/config", "/home/u");
    defer a.free(got);
    try testing.expectEqualStrings("/custom/config", got);
}

test "configHome falls back to home/.config when unset or empty" {
    const a = testing.allocator;
    const g1 = try configHome(a, null, "/home/u");
    defer a.free(g1);
    try testing.expectEqualStrings("/home/u/.config", g1);
    const g2 = try configHome(a, "", "/home/u"); // empty is treated as unset
    defer a.free(g2);
    try testing.expectEqualStrings("/home/u/.config", g2);
}

test "dataHome falls back to home/.local/share" {
    const a = testing.allocator;
    const g1 = try dataHome(a, null, "/home/u");
    defer a.free(g1);
    try testing.expectEqualStrings("/home/u/.local/share", g1);
    const g2 = try dataHome(a, "/opt/data", "/home/u");
    defer a.free(g2);
    try testing.expectEqualStrings("/opt/data", g2);
}

test "dataDirs default splits into two spec dirs" {
    const a = testing.allocator;
    const dirs = try dataDirs(a, null);
    defer freeDirs(a, dirs);
    try testing.expectEqual(@as(usize, 2), dirs.len);
    try testing.expectEqualStrings("/usr/local/share", dirs[0]);
    try testing.expectEqualStrings("/usr/share", dirs[1]);
}

test "dataDirs drops empty entries and preserves order" {
    const a = testing.allocator;
    const dirs = try dataDirs(a, "/a::/b:/c:");
    defer freeDirs(a, dirs);
    try testing.expectEqual(@as(usize, 3), dirs.len);
    try testing.expectEqualStrings("/a", dirs[0]);
    try testing.expectEqualStrings("/b", dirs[1]);
    try testing.expectEqualStrings("/c", dirs[2]);
}

test "dataDirs of empty string uses the default" {
    const a = testing.allocator;
    const dirs = try dataDirs(a, "");
    defer freeDirs(a, dirs);
    try testing.expectEqual(@as(usize, 2), dirs.len);
}
