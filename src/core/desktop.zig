//! Freedesktop `.desktop` application entries, for the "Open with…" picker. We scan
//! the standard applications dirs, parse Name/Exec, and build an argv (expanding the
//! Exec field codes) to launch an app on a file. Pure parsing/argv logic is
//! unit-tested; the scan + spawn do I/O. No GLib/GIO linking: this is ZFD's answer
//! to Go's internal/desktop (goal 5: shell out / read files, don't link a toolkit).

const std = @import("std");
const fsops = @import("fsops.zig");
const Dir = std.Io.Dir;

pub const App = struct {
    name: []u8, // display name (owned)
    exec: []u8, // raw Exec= line (owned)
    id: []u8, // .desktop filename, e.g. "firefox.desktop" (owned; for set-default)
    mimes: []u8 = &.{}, // raw MimeType= value, ';'-separated (owned)

    /// handles reports whether the app declares `mime` (or its "type/*" family) in
    /// MimeType=; the Open-with picker lists those first as recommended.
    pub fn handles(self: App, mime: []const u8) bool {
        if (mime.len == 0) return false;
        const slash = std.mem.indexOfScalar(u8, mime, '/') orelse mime.len;
        var it = std.mem.tokenizeScalar(u8, self.mimes, ';');
        while (it.next()) |m| {
            if (std.ascii.eqlIgnoreCase(m, mime)) return true;
            if (std.mem.endsWith(u8, m, "/*") and m.len - 1 == slash + 1 and
                std.ascii.eqlIgnoreCase(m[0..slash], mime[0..slash])) return true;
        }
        return false;
    }
};

/// Entry is the parsed-out fields of one `.desktop` file (borrowed from `content`).
const Entry = struct { name: []const u8, exec: []const u8, mimes: []const u8 = "" };

/// parseEntry extracts the [Desktop Entry] Name/Exec, or null if it isn't a visible
/// Application (Type!=Application, NoDisplay/Hidden true, or no Exec/Name).
pub fn parseEntry(content: []const u8) ?Entry {
    var in_section = false;
    var name: []const u8 = "";
    var exec: []const u8 = "";
    var mimes: []const u8 = "";
    var is_app = false;
    var hidden = false;

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_section = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const val = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "Name")) { // plain Name=, not Name[locale]=
            name = val;
        } else if (std.mem.eql(u8, key, "Exec")) {
            exec = val;
        } else if (std.mem.eql(u8, key, "MimeType")) {
            mimes = val;
        } else if (std.mem.eql(u8, key, "Type")) {
            is_app = std.mem.eql(u8, val, "Application");
        } else if (std.mem.eql(u8, key, "NoDisplay") or std.mem.eql(u8, key, "Hidden")) {
            if (std.mem.eql(u8, val, "true")) hidden = true;
        }
    }
    if (!is_app or hidden or name.len == 0 or exec.len == 0) return null;
    return .{ .name = name, .exec = exec, .mimes = mimes };
}

/// buildArgv turns an Exec= line into an argv, expanding field codes: %f/%F/%u/%U
/// become `path`; other %-codes are dropped. If none appeared and `path` is
/// non-empty, the path is appended. Caller owns the result (free with freeArgv).
pub fn buildArgv(alloc: std.mem.Allocator, exec: []const u8, path: []const u8) ![][]u8 {
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |a| alloc.free(a);
        out.deinit(alloc);
    }
    var used_path = false;
    var it = std.mem.tokenizeScalar(u8, exec, ' ');
    while (it.next()) |tok| {
        if (tok.len == 2 and tok[0] == '%') {
            switch (tok[1]) {
                'f', 'F', 'u', 'U' => {
                    if (path.len > 0) {
                        try out.append(alloc, try alloc.dupe(u8, path));
                        used_path = true;
                    }
                },
                else => {}, // drop %i/%c/%k/… and %%
            }
            continue;
        }
        try out.append(alloc, try alloc.dupe(u8, tok));
    }
    if (!used_path and path.len > 0) try out.append(alloc, try alloc.dupe(u8, path));
    return out.toOwnedSlice(alloc);
}

pub fn freeArgv(alloc: std.mem.Allocator, argv: [][]u8) void {
    for (argv) |a| alloc.free(a);
    alloc.free(argv);
}

/// launch runs `exec` (a .desktop Exec line) on `path`, detached.
pub fn launch(io: std.Io, alloc: std.mem.Allocator, exec: []const u8, path: []const u8) void {
    const argv = buildArgv(alloc, exec, path) catch return;
    defer freeArgv(alloc, argv);
    fsops.launch(io, alloc, argv, null);
}

/// appDirs returns the directories we scan for `.desktop` applications, most-preferred
/// first (user, system, local). This is the ONE definition of "which apps we consider",
/// shared with mimeinfo so the Open-with picker and the "Opens with"/Type columns agree.
/// Deliberately NOT $XDG_DATA_DIRS-derived: that would pull in flatpak/snap export dirs,
/// which we don't surface. Owned: free each element and the slice.
pub fn appDirs(alloc: std.mem.Allocator, home: []const u8) ![][]const u8 {
    var dirs = std.ArrayList([]const u8).empty;
    errdefer {
        for (dirs.items) |d| alloc.free(d);
        dirs.deinit(alloc);
    }
    try dirs.append(alloc, try std.fs.path.join(alloc, &.{ home, ".local", "share", "applications" }));
    try dirs.append(alloc, try alloc.dupe(u8, "/usr/share/applications"));
    try dirs.append(alloc, try alloc.dupe(u8, "/usr/local/share/applications"));
    return dirs.toOwnedSlice(alloc);
}

/// listApps scans the application dirs and returns the visible apps sorted by name.
/// Caller frees with freeApps. Best-effort: unreadable dirs/files skipped.
pub fn listApps(io: std.Io, alloc: std.mem.Allocator, home: []const u8) []const App {
    var apps = std.ArrayList(App).empty;
    var seen = std.ArrayList([]u8).empty; // .desktop basenames already added (dedup)
    defer {
        for (seen.items) |s| alloc.free(s);
        seen.deinit(alloc);
    }

    const dirs = appDirs(alloc, home) catch return apps.toOwnedSlice(alloc) catch &.{};
    defer {
        for (dirs) |d| alloc.free(d);
        alloc.free(dirs);
    }
    for (dirs) |dir_path| scanDir(io, alloc, dir_path, &apps, &seen);
    std.mem.sort(App, apps.items, {}, byName);
    return apps.toOwnedSlice(alloc) catch &.{};
}

fn scanDir(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8, apps: *std.ArrayList(App), seen: *std.ArrayList([]u8)) void {
    var d = Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (!std.mem.endsWith(u8, e.name, ".desktop")) continue;
        if (contains(seen.items, e.name)) continue; // earlier dir wins (user overrides system)
        const full = std.fs.path.join(alloc, &.{ dir_path, e.name }) catch continue;
        defer alloc.free(full);
        const content = Dir.cwd().readFileAlloc(io, full, alloc, .limited(1 << 18)) catch continue;
        defer alloc.free(content);
        const key = alloc.dupe(u8, e.name) catch continue;
        seen.append(alloc, key) catch alloc.free(key);
        const entry = parseEntry(content) orelse continue;
        const app = App{
            .name = alloc.dupe(u8, entry.name) catch continue,
            .exec = alloc.dupe(u8, entry.exec) catch continue,
            .id = alloc.dupe(u8, e.name) catch continue,
            .mimes = alloc.dupe(u8, entry.mimes) catch continue,
        };
        apps.append(alloc, app) catch {
            alloc.free(app.name);
            alloc.free(app.exec);
            alloc.free(app.id);
            alloc.free(app.mimes);
        };
    }
}

pub fn freeApps(alloc: std.mem.Allocator, apps: []const App) void {
    for (apps) |a| {
        alloc.free(a.name);
        alloc.free(a.exec);
        alloc.free(a.id);
        alloc.free(a.mimes);
    }
    alloc.free(apps);
}

fn contains(list: []const []u8, s: []const u8) bool {
    for (list) |e| {
        if (std.mem.eql(u8, e, s)) return true;
    }
    return false;
}

fn byName(_: void, a: App, b: App) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "parseEntry extracts Name/Exec and skips non-apps/hidden" {
    const ok = parseEntry("[Desktop Entry]\nType=Application\nName=Firefox\nExec=firefox %u\n").?;
    try testing.expectEqualStrings("Firefox", ok.name);
    try testing.expectEqualStrings("firefox %u", ok.exec);

    try testing.expect(parseEntry("[Desktop Entry]\nType=Application\nName=X\nExec=x\nNoDisplay=true\n") == null);
    try testing.expect(parseEntry("[Desktop Entry]\nType=Link\nName=X\nExec=x\n") == null); // not an app
    try testing.expect(parseEntry("[Other]\nName=X\nExec=x\n") == null); // wrong section
}

test "buildArgv expands field codes and appends the path when absent" {
    const a = testing.allocator;

    const with_code = try buildArgv(a, "gimp %U", "/tmp/pic.png");
    defer freeArgv(a, with_code);
    try testing.expectEqual(@as(usize, 2), with_code.len);
    try testing.expectEqualStrings("gimp", with_code[0]);
    try testing.expectEqualStrings("/tmp/pic.png", with_code[1]); // %U → path

    // No field code → path appended; stray %-codes dropped.
    const no_code = try buildArgv(a, "mpv %i", "/tmp/v.mkv");
    defer freeArgv(a, no_code);
    try testing.expectEqual(@as(usize, 2), no_code.len);
    try testing.expectEqualStrings("mpv", no_code[0]);
    try testing.expectEqualStrings("/tmp/v.mkv", no_code[1]);
}

test "App.handles matches exact MIME types and type/* families" {
    var app = App{ .name = @constCast("Viewer"), .exec = @constCast("v %f"), .id = @constCast("v.desktop"), .mimes = @constCast("image/png;text/*;") };
    try std.testing.expect(app.handles("image/png"));
    try std.testing.expect(app.handles("IMAGE/PNG"));
    try std.testing.expect(app.handles("text/x-zig"));
    try std.testing.expect(!app.handles("image/jpeg"));
    try std.testing.expect(!app.handles("textual/x"));
    try std.testing.expect(!app.handles(""));
    app.mimes = @constCast("");
    try std.testing.expect(!app.handles("image/png"));
}
