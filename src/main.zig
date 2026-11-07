//! ZFD entry point. One binary runs three ways: the standalone tabbed browser
//! (default), `--pick` (a one-shot chooser that prints the chosen paths — with
//! `--save`/`--multiple`/`--directory`/`--name`/`--folder` modifiers), and
//! `--service` (the xdg-desktop-portal FileChooser backend, not yet implemented).
//!
//! Zig 0.16 "Juicy Main": args + allocators + Io arrive in `init`.

const std = @import("std");
const core = @import("core");
const gui = @import("ui/gui.zig");
const shell = @import("ui/shell.zig");
const portal = @import("portal/service.zig");

const Parsed = struct {
    mode: enum { standalone, pick, service, info } = .standalone,
    save: bool = false,
    multiple: bool = false,
    directory: bool = false,
    name: []const u8 = "",
    folder: []const u8 = "",
    parent: []const u8 = "",
    title: []const u8 = "",
    accept: []const u8 = "", // the accept button's label (portal accept_label)
    detach: bool = false, // force the double-fork even without a TTY (used by --service to launch a reveal)
    pos: ?[2]i32 = null, // --pos X,Y: initial window position (a torn-off tab's new window)
    filters: [32][]const u8 = undefined, // repeatable --filter specs (argv-borrowed, capped)
    n_filters: usize = 0,
    current_filter: []const u8 = "",
};

pub fn main(init: std.process.Init) !void {
    const p = parseArgs(init.minimal.args);
    const gpa = init.gpa;
    const home = init.environ_map.get("HOME") orelse "/";
    // Not in a terminal (the desktop, the portal): what zfd says goes to its log file.
    if (!(std.Io.File.stderr().isTty(init.io) catch false)) logToFile(init.io, init.environ_map, home, p.mode);

    // The portal service is a long-lived daemon that spawns its own `--pick`
    // subprocesses (each of which persists prefs on its own). It must NOT load/save the
    // shared settings itself: it would hold a stale snapshot for its whole lifetime and
    // clobber newer prefs on shutdown. So it runs on its own, outside the load/save.
    if (p.mode == .service) return portal.run(init.io, init.gpa);
    core.fsops.launch_env = init.environ_map; // what the programs we open start from

    const trash_home = try resolveTrashHome(gpa, init.environ_map, home);
    defer gpa.free(trash_home);
    const settings_path = try resolveSettingsPath(gpa, init.environ_map, home);
    defer gpa.free(settings_path);
    var settings = core.config.load(init.io, gpa, settings_path);

    // Run the chosen GUI mode, then persist prefs once — regardless of mode. `--pick`
    // needs a specific exit code (0 = chosen, 1 = cancelled), applied only AFTER the
    // save, since std.process.exit would skip anything after it.
    // CSD (our own borderless titlebar) is on by default for BOTH the standalone browser
    // and the Save/Open chooser; ZFD_NO_CSD=1 keeps native window decorations (escape
    // hatch, matching GoFileDialog).
    const csd = init.environ_map.get("ZFD_NO_CSD") == null;
    var exit_code: ?u8 = null;
    switch (p.mode) {
        .standalone => {
            const debug = init.environ_map.get("ZFD_DEBUG") != null;
            // When launched from a terminal (`zfd .`, `xdg-open .`), detach so the shell
            // prompt returns instead of blocking on the window. Only when stdout is a TTY
            // — a desktop/.desktop launch isn't, and shouldn't be re-parented out of its
            // systemd scope. Skipped under ZFD_DEBUG (keep the terminal for logs) and
            // ZFD_NO_FORK. Safe here: still single-threaded (worker threads + the X11/GLFW
            // connection are created later in gui.run).
            // An explicit --detach always forks, even under ZFD_DEBUG: its callers (the
            // portal's reveal, a torn-off tab) wait for the launcher to exit.
            if (p.detach or (!debug and init.environ_map.get("ZFD_NO_FORK") == null and stdoutIsTty(init.io))) {
                daemonize();
                logToFile(init.io, init.environ_map, home, p.mode); // the terminal is left behind
            }
            // A positional path argument overrides the reopen-last/home start folder. A
            // FILE path opens its parent folder with the file selected ("show in folder").
            const tgt = if (p.folder.len > 0) resolveCliTarget(gpa, init.io, p.folder) else CliTarget{};
            defer tgt.deinit(gpa);
            try gui.run(gpa, init.io, trash_home, home, tgt.dir, tgt.name, p.pos, csd, debug, &settings);
        },
        .pick => {
            const start = if (p.folder.len > 0) p.folder else home;
            const cfg = shell.PickConfig{
                .save = p.save,
                .multiple = p.multiple,
                .directory = p.directory,
                .name = p.name,
                .parent = p.parent,
                .filters = p.filters[0..p.n_filters],
                .current_filter = p.current_filter,
                .title = p.title,
                .accept = p.accept,
            };
            exit_code = try gui.runPick(gpa, init.io, trash_home, home, start, cfg, csd, &settings);
        },
        .info => {
            if (p.detach) daemonize();
            const path = resolveCliDir(gpa, p.folder) orelse return;
            defer gpa.free(path);
            const dir = std.fs.path.dirname(path) orelse return; // the root has no Get Info here
            // Settings are read for the look (theme, zoom) but never written: a Get Info
            // window must not overwrite the browser's.
            return gui.runInfo(gpa, init.io, trash_home, home, dir, std.fs.path.basename(path), p.pos, csd, settings);
        },
        .service => unreachable, // handled above
    }
    core.config.save(init.io, gpa, settings_path, settings);
    if (exit_code) |code| std.process.exit(code);
}

/// daemonize detaches from the launching terminal (double-fork + setsid) so `zfd <dir>`
/// / `xdg-open .` returns the shell prompt immediately rather than blocking on the
/// window, and so a `--service`-launched reveal (`--detach`) outlives the D-Bus call that
/// spawned it. Called only in standalone mode, before any worker thread or the X11/GLFW
/// connection exists, so it forks a single-threaded process. If fork is unavailable we
/// just stay in the foreground.
/// stdoutIsTty reports whether stdout is a terminal — our proxy for "launched from a
/// shell" vs. from the desktop. (Not via std.posix.tcgetattr: its termios is smaller
/// than glibc's, which writes past it and trips the stack protector.)
fn stdoutIsTty(io: std.Io) bool {
    return std.Io.File.stdout().isTty(io) catch false;
}

/// logToFile sends zfd's messages (warnings, a crash's report) to
/// $XDG_STATE_HOME/zfd/zfd.log (~/.local/state/zfd/zfd.log), each start marked. Past
/// 1 MB it's moved to zfd.log.old first, so it never grows without end.
fn logToFile(io: std.Io, env: *const std.process.Environ.Map, home: []const u8, mode: anytype) void {
    var db: [std.fs.max_path_bytes]u8 = undefined;
    const dir = if (env.get("XDG_STATE_HOME")) |x| (std.mem.print(&db, "{s}/zfd", .{x}) catch return) else (std.mem.print(&db, "{s}/.local/state/zfd", .{home}) catch return);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch return;
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.mem.printSentinel(&pb, "{s}/zfd.log", .{dir}, 0) catch return;
    const size = if (cwd.statFile(io, path, .{})) |st| st.size else |_| 0;
    if (size > 1 << 20) {
        var ob: [std.fs.max_path_bytes]u8 = undefined;
        const old = std.mem.print(&ob, "{s}.old", .{path}) catch return;
        cwd.rename(path, cwd, old, io) catch {};
    }
    const linux = std.os.linux;
    const rc: isize = @bitCast(linux.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600));
    if (rc < 0) return;
    const fd: i32 = @intCast(rc);
    _ = linux.dup2(fd, 2); // (the copy on 2 stays open for the programs zfd starts)
    _ = linux.close(fd);
    var tb: [32]u8 = undefined;
    var hb: [128]u8 = undefined;
    const when = core.scan.formatDate(&tb, std.Io.Clock.real.now(io).toSeconds());
    const head = std.mem.print(&hb, "--- zfd {s} started {s} UTC (pid {d})\n", .{ @tagName(mode), when, linux.getpid() }) catch return;
    _ = linux.write(2, head.ptr, head.len);
}

fn daemonize() void {
    // fork()/setsid()/getcwd() aren't wrapped in std.posix here, so go through the raw
    // Linux syscalls (zfd is Linux-only). fork returns the child pid in the parent, 0 in
    // the child, or a negative errno on failure.
    const rc1: isize = @bitCast(std.os.linux.fork());
    if (rc1 < 0) return; // fork failed → stay in the foreground
    if (rc1 > 0) std.process.exit(0); // original parent → shell prompt
    _ = std.os.linux.setsid(); // new session; drop the controlling terminal
    const rc2: isize = @bitCast(std.os.linux.fork());
    if (rc2 < 0) return;
    if (rc2 > 0) std.process.exit(0); // second fork so we can't reacquire a terminal
}

/// CliTarget is a resolved command-line path: the directory to open, and (for a file
/// path) the entry within it to select + reveal. Both owned; freed via deinit.
const CliTarget = struct {
    dir: ?[]u8 = null,
    name: ?[]u8 = null,
    fn deinit(self: CliTarget, gpa: std.mem.Allocator) void {
        if (self.dir) |d| gpa.free(d);
        if (self.name) |n| gpa.free(n);
    }
};

/// resolveCliTarget turns a command-line path argument into a directory to open (and,
/// for a file, the entry to reveal in it). A directory opens directly; a file opens its
/// parent folder with the file selected ("show in folder"). Strips a `file://` scheme
/// and resolves a relative path (like `.`) against the current directory.
fn resolveCliTarget(gpa: std.mem.Allocator, io: std.Io, arg: []const u8) CliTarget {
    if (core.recent.isUri(arg)) return .{ .dir = gpa.dupe(u8, core.recent.uri) catch return .{} };
    const resolved = resolveCliDir(gpa, arg) orelse return .{};
    if (isDir(io, resolved)) return .{ .dir = resolved }; // a directory → open it directly
    // A file (or a path that isn't an openable directory): open its parent and select it.
    const parent = std.fs.path.dirname(resolved) orelse return .{ .dir = resolved };
    const dir = gpa.dupe(u8, parent) catch return .{ .dir = resolved };
    const name = gpa.dupe(u8, std.fs.path.basename(resolved)) catch {
        gpa.free(dir);
        return .{ .dir = resolved };
    };
    gpa.free(resolved);
    return .{ .dir = dir, .name = name };
}

/// resolveCliDir resolves a path argument to an absolute path: strips a `file://` scheme
/// and resolves a relative path against the cwd. Null if it can't. Owned.
fn resolveCliDir(gpa: std.mem.Allocator, arg: []const u8) ?[]u8 {
    var path = arg;
    if (std.mem.startsWith(u8, path, "file://")) path = path["file://".len..];
    if (path.len == 0) return null;
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path) catch null;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc: isize = @bitCast(std.os.linux.getcwd(&cwd_buf, cwd_buf.len));
    if (rc < 0) return null;
    const cwd = std.mem.sliceTo(&cwd_buf, 0); // syscall NUL-terminates
    return std.fs.path.resolve(gpa, &.{ cwd, path }) catch null;
}

/// isDir reports whether `path` is an openable directory.
fn isDir(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// resolveTrashHome returns $XDG_DATA_HOME/Trash (or ~/.local/share/Trash). Owned.
fn resolveTrashHome(gpa: std.mem.Allocator, env: *std.process.Environ.Map, home: []const u8) ![]u8 {
    const data_home = try core.xdg.dataHome(gpa, env.get("XDG_DATA_HOME"), home);
    defer gpa.free(data_home);
    return std.fs.path.join(gpa, &.{ data_home, "Trash" });
}

/// resolveSettingsPath returns $XDG_CONFIG_HOME/zfd/settings (or ~/.config/…). Owned.
fn resolveSettingsPath(gpa: std.mem.Allocator, env: *std.process.Environ.Map, home: []const u8) ![]u8 {
    const cfg = try core.xdg.configHome(gpa, env.get("XDG_CONFIG_HOME"), home);
    defer gpa.free(cfg);
    return std.fs.path.join(gpa, &.{ cfg, "zfd", "settings" });
}

/// parseArgs reads the run mode + chooser options from argv. Any chooser flag
/// implies `--pick`. `--service` wins.
fn parseArgs(args: std.process.Args) Parsed {
    var p = Parsed{};
    var pick = false;
    var it = args.iterate();
    _ = it.next(); // argv0
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--service")) {
            p.mode = .service;
            return p;
        } else if (std.mem.eql(u8, arg, "--pick")) {
            pick = true;
        } else if (std.mem.eql(u8, arg, "--save")) {
            p.save = true;
            pick = true;
        } else if (std.mem.eql(u8, arg, "--multiple")) {
            p.multiple = true;
            pick = true;
        } else if (std.mem.eql(u8, arg, "--directory")) {
            p.directory = true;
            pick = true;
        } else if (std.mem.eql(u8, arg, "--name")) {
            p.name = it.next() orelse "";
            pick = true;
        } else if (std.mem.eql(u8, arg, "--folder")) {
            p.folder = it.next() orelse "";
            pick = true;
        } else if (std.mem.eql(u8, arg, "--parent")) {
            p.parent = it.next() orelse "";
            pick = true;
        } else if (std.mem.eql(u8, arg, "--filter")) {
            const spec = it.next() orelse "";
            if (spec.len > 0 and p.n_filters < p.filters.len) {
                p.filters[p.n_filters] = spec;
                p.n_filters += 1;
            }
            pick = true;
        } else if (std.mem.eql(u8, arg, "--current-filter")) {
            p.current_filter = it.next() orelse "";
            pick = true;
        } else if (std.mem.eql(u8, arg, "--select") or std.mem.eql(u8, arg, "-R")) {
            // "Show in folder" / reveal: file managers are invoked as `<fm> --select
            // <file>` for this (e.g. MEGAsync uses `dolphin --select`/`nautilus
            // --select`). Take the path as the thing to open — resolveCliTarget turns a
            // file into "open its parent folder + select it". Standalone, not --pick.
            if (it.next()) |path| {
                if (p.folder.len == 0) p.folder = path;
            }
        } else if (std.mem.eql(u8, arg, "--get-info")) {
            // A Get Info window for one item (the browser opens these; own process).
            p.folder = it.next() orelse "";
            p.mode = .info;
            return p; // nothing else applies to it
        } else if (std.mem.eql(u8, arg, "--pos")) {
            p.pos = parsePos(it.next() orelse ""); // standalone modifier
        } else if (std.mem.eql(u8, arg, "--detach")) {
            p.detach = true; // standalone modifier (does NOT imply --pick)
        } else if (std.mem.eql(u8, arg, "--title")) {
            p.title = it.next() orelse "";
            pick = true;
        } else if (std.mem.eql(u8, arg, "--accept")) {
            p.accept = it.next() orelse "";
            pick = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // A positional path (e.g. `zfd .` or the .desktop's `Exec=zfd %F`) — the
            // folder to open in the standalone browser. First one wins; it does NOT
            // imply --pick. In --pick mode an explicit --folder still takes precedence.
            if (p.folder.len == 0) p.folder = arg;
        }
    }
    if (pick) p.mode = .pick;
    return p;
}

/// parsePos reads "X,Y" (screen pixels, may be negative on multi-monitor setups).
fn parsePos(s: []const u8) ?[2]i32 {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse return null;
    const px = std.fmt.parseInt(i32, s[0..comma], 10) catch return null;
    const py = std.fmt.parseInt(i32, s[comma + 1 ..], 10) catch return null;
    return .{ px, py };
}

test "parsePos" {
    try std.testing.expectEqual(@as(?[2]i32, .{ 10, -20 }), parsePos("10,-20"));
    try std.testing.expectEqual(@as(?[2]i32, null), parsePos("10"));
    try std.testing.expectEqual(@as(?[2]i32, null), parsePos("a,b"));
}

test "core is linked and usable from the executable module" {
    try std.testing.expect(core.glob.quickMatch("*.pdf", "report.pdf", false));
    try std.testing.expect(!core.glob.quickMatch("*.pdf", "report.txt", false));
}

test {
    _ = portal; // the portal service's own tests
}
