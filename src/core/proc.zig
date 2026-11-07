//! Subprocess helpers, kept out of fsops (which is filesystem-name + trash logic).
//! Two flavors: detached *launchers* that spawn a GUI program on a reaper thread so the
//! render thread never blocks and no zombie is left (xdg-open, a terminal), and
//! `capture`, which runs a CLI tool to completion and returns its stdout (fc-match,
//! kreadconfig/gsettings, the `--pick` subprocess). GUI-free (goal 2); we shell out
//! rather than link a toolkit (goal 5). Pure I/O glue — no unit tests.

const std = @import("std");
const Dir = std.Io.Dir;

// --- detached launchers ------------------------------------------------------
// Each runs on a detached reaper thread that spawns the child and waits, so the
// render thread never blocks and no zombie is left behind. The child (xdg-open, a
// terminal) may outlive us; the thread just idles in wait().

/// openWith opens a path in its default application via xdg-open.
pub fn openWith(io: std.Io, alloc: std.mem.Allocator, path: []const u8) void {
    launch(io, alloc, &.{ "xdg-open", path }, null);
}

/// openTerminal opens a terminal emulator with its working directory set to dir. It
/// resolves *which* terminal from the user's actual preference (see terminalThread),
/// not a hardcoded beauty contest — the fixed list is only the last-resort fallback.
pub fn openTerminal(io: std.Io, alloc: std.mem.Allocator, dir: []const u8) void {
    const d = alloc.dupe(u8, dir) catch return;
    const t = std.Thread.spawn(.{}, terminalThread, .{ io, alloc, d }) catch {
        alloc.free(d);
        return;
    };
    t.detach();
}

/// terminalThread resolves the terminal to launch from the best available source and
/// runs the first that works. There's no registry that enumerates "all terminals"
/// (even freedesktop's answer, xdg-terminal-exec, falls back to a built-in list), so a
/// hardcoded probe is unavoidable — but it belongs *last*. Everything above it honors
/// a declared preference: $TERMINAL, the desktop's configured default, then the
/// standard launcher. First success wins (each hides when its tool is absent).
fn terminalThread(io: std.Io, alloc: std.mem.Allocator, dir: []u8) void {
    defer alloc.free(dir);

    // 1. $TERMINAL — the user's explicit choice, honored by many CLI tools.
    if (getEnv("TERMINAL")) |t| {
        if (spawnTerm(io, alloc, t, dir)) return;
    }
    // 2. The running desktop's configured default terminal (KDE/GNOME).
    if (deDefaultTerminal(io, alloc)) |t| {
        defer alloc.free(t);
        if (spawnTerm(io, alloc, t, dir)) return;
    }
    // 3. xdg-terminal-exec — the freedesktop standard launcher (a proposal, but the
    //    correct DE-agnostic entry point wherever it's installed).
    if (spawnTerm(io, alloc, "xdg-terminal-exec", dir)) return;
    // 4. Debian/Ubuntu's alternatives symlink.
    if (spawnTerm(io, alloc, "x-terminal-emulator", dir)) return;
    // 5. Last resort: probe well-known emulators (first on PATH wins).
    const candidates = [_][]const u8{ "konsole", "gnome-terminal", "foot", "alacritty", "kitty", "wezterm", "ghostty", "xfce4-terminal", "xterm" };
    for (candidates) |t| {
        if (spawnTerm(io, alloc, t, dir)) return;
    }
}

/// deDefaultTerminal asks the running desktop for its configured terminal (owned), or
/// null: KDE keeps it in kdeglobals (kreadconfig6/5 General/TerminalApplication), GNOME
/// in gsettings. We pick by $XDG_CURRENT_DESKTOP and try both when it's unset/unknown.
fn deDefaultTerminal(io: std.Io, alloc: std.mem.Allocator) ?[]u8 {
    const de = getEnv("XDG_CURRENT_DESKTOP") orelse "";
    const kde = std.ascii.findIgnoreCase(de, "KDE") != null or std.ascii.findIgnoreCase(de, "plasma") != null;
    const gnome = std.ascii.findIgnoreCase(de, "GNOME") != null;
    const unknown = !kde and !gnome;
    if (kde or unknown) {
        if (captureLine(io, alloc, &.{ "kreadconfig6", "--group", "General", "--key", "TerminalApplication" })) |t| return t;
        if (captureLine(io, alloc, &.{ "kreadconfig5", "--group", "General", "--key", "TerminalApplication" })) |t| return t;
    }
    if (gnome or unknown) {
        if (captureLine(io, alloc, &.{ "gsettings", "get", "org.gnome.desktop.default-applications.terminal", "exec" })) |t| return t;
    }
    return null;
}

/// spawnTerm launches a resolved terminal `spec` (which may carry arguments) with its
/// working directory set to `dir` — terminals inherit that cwd, so no per-emulator
/// "--working-directory" flag is needed. Returns true if it spawned; then we wait out
/// its lifetime on this detached reaper thread (no zombie). False if not on PATH.
fn spawnTerm(io: std.Io, alloc: std.mem.Allocator, spec: []const u8, dir: []const u8) bool {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    var it = std.mem.tokenizeScalar(u8, spec, ' '); // "gnome-terminal --" → ["gnome-terminal","--"]
    while (it.next()) |tok| argv.append(alloc, tok) catch return false;
    if (argv.items.len == 0) return false;
    var child = std.process.spawn(io, .{ .argv = argv.items, .cwd = .{ .path = dir } }) catch return false;
    _ = child.wait(io) catch {};
    return true;
}

/// getEnv reads an environment variable by scanning the process environment (neither
/// std.posix.getenv nor std.process.getEnvVarOwned is available in this std; libc is
/// linked, so std.c.environ is). Returns a borrow of the environment.
fn getEnv(name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const s = std.mem.sliceTo(entry, 0);
        if (s.len > name.len and s[name.len] == '=' and std.mem.eql(u8, s[0..name.len], name)) {
            return s[name.len + 1 ..];
        }
    }
    return null;
}

/// launch spawns argv (optionally in cwd) on a detached reaper thread.
pub fn launch(io: std.Io, alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) void {
    const owned = dupArgv(alloc, argv) catch return;
    const cwd_owned: ?[]u8 = if (cwd) |d| (alloc.dupe(u8, d) catch {
        freeArgv(alloc, owned);
        return;
    }) else null;
    const t = std.Thread.spawn(.{}, launchThread, .{ io, alloc, owned, cwd_owned }) catch {
        freeArgv(alloc, owned);
        if (cwd_owned) |co| alloc.free(co);
        return;
    };
    t.detach();
}

fn launchThread(io: std.Io, alloc: std.mem.Allocator, argv: [][]u8, cwd: ?[]u8) void {
    defer freeArgv(alloc, argv);
    defer if (cwd) |co| alloc.free(co);
    const cwd_opt: std.process.Child.Cwd = if (cwd) |co| .{ .path = co } else .inherit;
    var child = std.process.spawn(io, .{ .argv = argv, .cwd = cwd_opt }) catch return;
    _ = child.wait(io) catch {};
}

fn dupArgv(alloc: std.mem.Allocator, argv: []const []const u8) ![][]u8 {
    const out = try alloc.alloc([]u8, argv.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |a| alloc.free(a);
        alloc.free(out);
    }
    for (argv) |a| {
        out[n] = try alloc.dupe(u8, a);
        n += 1;
    }
    return out;
}

fn freeArgv(alloc: std.mem.Allocator, argv: [][]u8) void {
    for (argv) |a| alloc.free(a);
    alloc.free(argv);
}

// --- capture -----------------------------------------------------------------

/// Captured is one completed subprocess: its exit `code` plus captured stdout (`out`,
/// owned by the caller — free it).
pub const Captured = struct { code: u8, out: []u8 };

var cap_counter: std.atomic.Value(u32) = .init(0);

/// capture runs argv to completion and returns its exit code + stdout (owned). stdout
/// goes through a unique temp file (no pipe plumbing); null if the spawn/wait/read
/// fails. This is the one place the "spawn a CLI tool and read its output" pattern
/// lives — shared by the font lookup, the terminal-setting query, and the `--pick`
/// subprocess. Runs on whatever thread calls it (never the render thread).
pub fn capture(io: std.Io, alloc: std.mem.Allocator, argv: []const []const u8) ?Captured {
    const n = cap_counter.fetchAdd(1, .monotonic);
    var pbuf: [64]u8 = undefined;
    const tmp = std.mem.print(&pbuf, "/tmp/zfd-cap-{d}-{d}", .{ std.os.linux.getpid(), n }) catch return null;
    const cwd = Dir.cwd();
    const f = cwd.createFile(io, tmp, .{}) catch return null;
    var child = std.process.spawn(io, .{ .argv = argv, .stdout = .{ .file = f } }) catch {
        f.close(io);
        cwd.deleteFile(io, tmp) catch {};
        return null;
    };
    const term = child.wait(io) catch {
        f.close(io);
        cwd.deleteFile(io, tmp) catch {};
        return null;
    };
    f.close(io);
    defer cwd.deleteFile(io, tmp) catch {};
    const out = cwd.readFileAlloc(io, tmp, alloc, .limited(1 << 20)) catch return null;
    const code: u8 = switch (term) {
        .exited => |e| e,
        else => 2,
    };
    return .{ .code = code, .out = out };
}

/// captureLine returns argv's stdout first non-empty line, trimmed and unquoted
/// (gsettings prints 'gnome-terminal'), owned — or null. For single-value queries.
fn captureLine(io: std.Io, alloc: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    const cap = capture(io, alloc, argv) orelse return null;
    defer alloc.free(cap.out);
    var line: []const u8 = cap.out;
    if (std.mem.indexOfScalar(u8, cap.out, '\n')) |nl| line = cap.out[0..nl];
    line = std.mem.trim(u8, line, " \t\r\n'\"");
    if (line.len == 0) return null;
    return alloc.dupe(u8, line) catch null;
}
