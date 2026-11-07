//! The host names in ~/.ssh/config (and the files it Includes), for "Connect to
//! Server": an SFTP location can simply be "ssh <host>", so everything the config sets
//! up (user, port, keys, ProxyJump, …) applies. Only plain names are offered; patterns
//! ("*", "*.lan", "!x") are rules for other hosts, not hosts. GUI-free.

const std = @import("std");
const glob = @import("glob.zig");

/// max_depth is how deep Includes are followed (ssh's own limit is 16; a loop stops).
const max_depth = 8;

/// hosts reads the host names from `home`/.ssh/config, in the order written, each once
/// (owned; free with freeHosts). A missing config is no hosts.
pub fn hosts(io: std.Io, alloc: std.mem.Allocator, home: []const u8) [][]u8 {
    var list = std.ArrayList([]u8).empty;
    const ssh_dir = std.fs.path.join(alloc, &.{ home, ".ssh" }) catch return &.{};
    defer alloc.free(ssh_dir);
    const cfg = std.fs.path.join(alloc, &.{ ssh_dir, "config" }) catch return &.{};
    defer alloc.free(cfg);
    readFile(io, alloc, &list, home, ssh_dir, cfg, 0);
    return list.toOwnedSlice(alloc) catch {
        freeList(alloc, &list);
        return &.{};
    };
}

pub fn freeHosts(alloc: std.mem.Allocator, list: []const []u8) void {
    for (list) |h| alloc.free(h);
    alloc.free(list);
}

fn freeList(alloc: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |h| alloc.free(h);
    list.deinit(alloc);
}

fn readFile(io: std.Io, alloc: std.mem.Allocator, list: *std.ArrayList([]u8), home: []const u8, ssh_dir: []const u8, path: []const u8, depth: usize) void {
    if (depth > max_depth) return;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20)) catch return;
    defer alloc.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const kw = keyword(line) orelse continue;
        if (std.ascii.eqlIgnoreCase(kw.key, "host")) {
            var it = std.mem.tokenizeAny(u8, kw.rest, " \t");
            while (it.next()) |raw| {
                const name = std.mem.trim(u8, raw, "\"");
                if (!plainName(name) or contains(list.items, name)) continue;
                const dup = alloc.dupe(u8, name) catch return;
                list.append(alloc, dup) catch return alloc.free(dup);
            }
        } else if (std.ascii.eqlIgnoreCase(kw.key, "include")) {
            var it = std.mem.tokenizeAny(u8, kw.rest, " \t");
            while (it.next()) |pat| includeFiles(io, alloc, list, home, ssh_dir, std.mem.trim(u8, pat, "\""), depth + 1);
        }
    }
}

/// includeFiles reads the files an Include names: relative ones are in ~/.ssh, "~/"
/// is the home folder, and the last part may be a pattern (config.d/*), read in
/// name order as ssh does.
fn includeFiles(io: std.Io, alloc: std.mem.Allocator, list: *std.ArrayList([]u8), home: []const u8, ssh_dir: []const u8, pat: []const u8, depth: usize) void {
    const full = if (std.mem.startsWith(u8, pat, "~/"))
        std.fs.path.join(alloc, &.{ home, pat[2..] }) catch return
    else if (std.fs.path.isAbsolute(pat))
        alloc.dupe(u8, pat) catch return
    else
        std.fs.path.join(alloc, &.{ ssh_dir, pat }) catch return;
    defer alloc.free(full);
    const base = std.fs.path.basename(full);
    if (std.mem.indexOfAny(u8, base, "*?[") == null) return readFile(io, alloc, list, home, ssh_dir, full, depth);
    const dir_path = std.fs.path.dirname(full) orelse return;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names = std.ArrayList([]u8).empty;
    defer freeList(alloc, &names);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .directory or !glob.match(base, e.name, false)) continue;
        const n = alloc.dupe(u8, e.name) catch break;
        names.append(alloc, n) catch {
            alloc.free(n);
            break;
        };
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for (names.items) |n| {
        const p = std.fs.path.join(alloc, &.{ dir_path, n }) catch return;
        defer alloc.free(p);
        readFile(io, alloc, list, home, ssh_dir, p, depth);
    }
}

const Keyword = struct { key: []const u8, rest: []const u8 };

/// keyword splits a config line into its keyword and the rest ("Host a b",
/// "Host=a"); null for blank lines and comments.
fn keyword(line: []const u8) ?Keyword {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] == '#') return null;
    const end = std.mem.indexOfAny(u8, t, " \t=") orelse return .{ .key = t, .rest = "" };
    const rest = std.mem.trimStart(u8, t[end..], " \t=");
    return .{ .key = t[0..end], .rest = rest };
}

/// plainName: one host, not a pattern or a negation.
fn plainName(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfAny(u8, name, "*?!,") == null;
}

fn contains(list: []const []u8, name: []const u8) bool {
    for (list) |h| if (std.mem.eql(u8, h, name)) return true;
    return false;
}

const testing = std.testing;

test "hosts lists plain names, follows Include, skips patterns" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const a = testing.allocator;
    try tmp.dir.createDirPath(io, ".ssh/config.d");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ssh/config", .data =
        \\# mine
        \\Include config.d/*
        \\Host nas  backup-box
        \\    User me
        \\Host=pi
        \\Host *.lan !secret *
        \\  HostName x
        \\host nas
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = ".ssh/config.d/10-work", .data = "Host work\n  ProxyJump gate\nHost gate\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".ssh/config.d/20-loop", .data = "Include ~/.ssh/config\n" });
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(home);
    const got = hosts(io, a, home);
    defer freeHosts(a, got);
    const want = [_][]const u8{ "work", "gate", "nas", "backup-box", "pi" };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "no config is no hosts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(home);
    const got = hosts(testing.io, testing.allocator, home);
    defer freeHosts(testing.allocator, got);
    try testing.expectEqual(@as(usize, 0), got.len);
}
