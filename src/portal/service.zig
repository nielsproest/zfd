//! The xdg-desktop-portal FileChooser D-Bus backend (`zfd --service`), ported from
//! GoFileDialog's `internal/portal`. Implements org.freedesktop.impl.portal
//! .FileChooser (OpenFile / SaveFile / SaveFiles) via sd-bus. Each call spawns a
//! one-shot `zfd --pick` subprocess (so the service half links no GUI), reads the
//! chosen paths from its stdout, and maps them back to `file://` uris.
//!
//! Requests are ASYNCHRONOUS: the method call is answered when its picker exits, and
//! the bus loop keeps running meanwhile. Each request also exports the portal's
//! org.freedesktop.impl.portal.Request object at its handle path, whose Close kills
//! the picker. xdg-desktop-portal calls Close when the requesting app disappears. The
//! old synchronous loop blocked inside wait() for the dialog, so a killed app left an
//! orphaned picker holding the whole daemon hostage until someone killed it.
//!
//! The same daemon also serves org.freedesktop.FileManager1 (ShowFolders / ShowItems /
//! ShowItemProperties), the standard "reveal a file in its folder" D-Bus API used by
//! browsers, editors, etc. Each call launches a detached `zfd [--select] <path>` window.
//! That name is requested best-effort: if another file manager (Dolphin, Nautilus, …)
//! already owns it we simply don't provide it, and the FileChooser half is unaffected.
//! There's no FileManager1 .service file on purpose: a second D-Bus activation would
//! start a rival daemon that can't take the (fatal) portal name; instead reveal works
//! whenever this daemon is already running (the portal keeps it alive).
//!
//! Uses sd_bus_add_object with a raw message callback (no vtable macros; those
//! don't survive translate-c). NEEDS a session bus + a real portal round-trip to
//! verify; built and structured but not runtime-tested here.

const std = @import("std");
const core = @import("core");

pub const sd = @import("c_sdbus"); // src/c/sdbus.h, translated in build.zig

const bus_name = "org.freedesktop.impl.portal.desktop.zfd";
const bus_path = "/org/freedesktop/portal/desktop";

// org.freedesktop.FileManager1: the standard "reveal in folder" interface.
const fm_name = "org.freedesktop.FileManager1";
const fm_path = "/org/freedesktop/FileManager1";

// Portal response codes: 0 success, 1 user cancelled, 2 failed.
const response_ok: u32 = 0;
const response_cancelled: u32 = 1;
const response_error: u32 = 2;

var g_io: std.Io = undefined;
var g_gpa: std.mem.Allocator = undefined;

const Mode = enum { open, save, directory };

const Options = struct {
    multiple: bool = false,
    directory: bool = false,
    name: []const u8 = "",
    folder: []const u8 = "",
    accept: []const u8 = "",
    title: []const u8 = "", // the dialog title the requesting app asked for
    parent: []const u8 = "", // parent_window handle, e.g. "x11:1a00007"
    files: [][]const u8 = &.{}, // for SaveFiles
    filters: []const []const u8 = &.{}, // "Name|*.png *.jpg" specs for --filter
    current_filter: []const u8 = "", // name of the filter to preselect
};

/// zfd_sdbus_available: libsystemd could be opened (src/c/sdbus_dl.c).
extern fn zfd_sdbus_available() bool;

pub fn run(io: std.Io, gpa: std.mem.Allocator) !void {
    g_io = io;
    g_gpa = gpa;

    var bus: ?*sd.sd_bus = null;
    if (!zfd_sdbus_available()) {
        std.debug.print("zfd --service talks D-Bus through libsystemd, which isn't installed (systemd-libs)\n", .{});
        return error.NoLibsystemd;
    }
    if (sd.sd_bus_open_user(&bus) < 0) return error.BusConnect;
    defer _ = sd.sd_bus_flush_close_unref(bus);

    var slot: ?*sd.sd_bus_slot = null;
    if (sd.sd_bus_add_object(bus, &slot, bus_path, methodHandler, null) < 0) return error.AddObject;

    if (sd.sd_bus_request_name(bus, bus_name, 0) < 0) return error.RequestName;

    // Also serve org.freedesktop.FileManager1 (reveal-in-folder). Best-effort: another
    // file manager may already own the name, in which case we just don't provide it;
    // the FileChooser backend above must still work.
    var fm_slot: ?*sd.sd_bus_slot = null;
    _ = sd.sd_bus_add_object(bus, &fm_slot, fm_path, fileManagerHandler, null);
    _ = sd.sd_bus_request_name(bus, fm_name, 0);

    while (true) {
        const r = sd.sd_bus_process(bus, null);
        if (r < 0) return error.Process;
        if (r > 0) continue; // handled a message; check for more
        reapPickers();
        // After a package upgrade, step aside while no dialog is open: give up the bus
        // names (so the next request D-Bus-activates the new binary), answer anything
        // already queued to us, and exit.
        if (g_pending.items.len == 0 and exeReplaced()) {
            _ = sd.sd_bus_release_name(bus, bus_name);
            _ = sd.sd_bus_release_name(bus, fm_name);
            while (sd.sd_bus_process(bus, null) > 0) {}
            if (g_pending.items.len == 0) return;
        }
        // Wake periodically to reap finished pickers (their exit is not a bus event)
        // and, when idle, now and then to notice an upgrade.
        const timeout_us: u64 = if (g_pending.items.len > 0) 100 * std.time.us_per_ms else 30 * std.time.us_per_s;
        if (sd.sd_bus_wait(bus, timeout_us) < 0) return error.Wait;
    }
}

const deleted_suffix = " (deleted)";

/// exeReplaced reports whether our binary was replaced or removed on disk (a package
/// upgrade): the kernel then shows /proc/self/exe as "<path> (deleted)".
fn exeReplaced() bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.readlink("/proc/self/exe", &buf, buf.len);
    if (std.os.linux.errno(rc) != .SUCCESS) return false;
    return std.mem.endsWith(u8, buf[0..rc], deleted_suffix);
}

fn methodHandler(m: ?*sd.sd_bus_message, userdata: ?*anyopaque, ret_error: ?*sd.sd_bus_error) callconv(.c) c_int {
    _ = userdata;
    _ = ret_error;
    const member = sd.sd_bus_message_get_member(m) orelse return 0;
    const name = std.mem.span(member);
    if (std.mem.eql(u8, name, "OpenFile")) return handleChooser(m, .open);
    if (std.mem.eql(u8, name, "SaveFile")) return handleChooser(m, .save);
    if (std.mem.eql(u8, name, "SaveFiles")) return handleSaveFiles(m);
    return 0; // not one of ours → let sd-bus reply "unknown method"
}

const ShowKind = enum { select, folder };

/// fileManagerHandler dispatches org.freedesktop.FileManager1 calls. All three methods
/// take (as URIs, s StartupId) and return void; StartupId is ignored.
fn fileManagerHandler(m: ?*sd.sd_bus_message, userdata: ?*anyopaque, ret_error: ?*sd.sd_bus_error) callconv(.c) c_int {
    _ = userdata;
    _ = ret_error;
    const member = sd.sd_bus_message_get_member(m) orelse return 0;
    const name = std.mem.span(member);
    // ShowItems + ShowItemProperties reveal the file (open its parent, select it);
    // ShowFolders opens each folder directly. We don't have a properties-only view, so
    // ShowItemProperties just reveals, which is better than ignoring it.
    if (std.mem.eql(u8, name, "ShowItems")) return handleShow(m, .select);
    if (std.mem.eql(u8, name, "ShowItemProperties")) return handleShow(m, .select);
    if (std.mem.eql(u8, name, "ShowFolders")) return handleShow(m, .folder);
    return 0; // unknown member → sd-bus replies "unknown method"
}

/// handleShow reads the URI array and launches a detached reveal window per URI.
fn handleShow(m: ?*sd.sd_bus_message, kind: ShowKind) c_int {
    var arena = std.heap.ArenaAllocator.init(g_gpa);
    defer arena.deinit();
    const a = arena.allocator();

    if (sd.sd_bus_message_enter_container(m, 'a', "s") < 0) return emptyReply(m);
    while (true) {
        var uc: [*c]const u8 = undefined;
        if (sd.sd_bus_message_read(m, "s", &uc) <= 0) break; // 0 = end of array, <0 = error
        if (uc == null) continue;
        const path = core.fsops.fileUriToPath(a, std.mem.span(uc)) orelse continue;
        launchReveal(a, path, kind);
    }
    _ = sd.sd_bus_message_exit_container(m);
    return emptyReply(m);
}

/// launchReveal spawns a detached `zfd [--select] <path>` GUI. `--detach` makes it
/// double-fork, so our direct child exits at once (we reap it immediately) while the
/// window it spawned lives on independently of this daemon.
fn launchReveal(a: std.mem.Allocator, path: []const u8, kind: ShowKind) void {
    const self_exe = std.process.executablePathAlloc(g_io, a) catch return;
    var argv = std.ArrayList([]const u8).empty;
    argv.append(a, self_exe) catch return;
    argv.append(a, "--detach") catch return;
    if (kind == .select) argv.append(a, "--select") catch return; // reveal: open parent, select file
    argv.append(a, path) catch return;
    var child = std.process.spawn(g_io, .{ .argv = argv.items }) catch return;
    _ = child.wait(g_io) catch {}; // the --detach child re-forks and exits immediately
}

/// emptyReply sends the empty method_return for a void FileManager1 method.
fn emptyReply(m: ?*sd.sd_bus_message) c_int {
    var r: ?*sd.sd_bus_message = null;
    if (sd.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    defer _ = sd.sd_bus_message_unref(r);
    if (sd.sd_bus_send(null, r, null) < 0) return -1;
    return 1; // handled
}

/// Pending is one in-flight chooser request: the (ref'd) method call we still owe a
/// reply, the Request object exported at its handle, and the picker subprocess whose
/// stdout lands in an anonymous memfd (requests run concurrently, so no shared file).
const Pending = struct {
    arena: std.heap.ArenaAllocator,
    call: ?*sd.sd_bus_message,
    slot: ?*sd.sd_bus_slot = null,
    pid: std.posix.pid_t,
    out_fd: i32,
    save_files: []const []const u8 = &.{}, // SaveFiles: names to place in the chosen dir
    is_save_files: bool = false,
    closed: bool = false, // Request.Close arrived: the picker was told to go away
};

var g_pending: std.ArrayList(*Pending) = .empty;

fn handleChooser(m: ?*sd.sd_bus_message, mode: Mode) c_int {
    return startRequest(m, mode, false);
}

/// SaveFiles: pick a directory, then place each requested file name in it.
fn handleSaveFiles(m: ?*sd.sd_bus_message) c_int {
    return startRequest(m, .directory, true);
}

/// startRequest parses the call, spawns the picker and registers the request; the
/// reply is sent later by reapPickers (or immediately, on a spawn failure).
fn startRequest(m: ?*sd.sd_bus_message, mode: Mode, save_files: bool) c_int {
    const p = g_gpa.create(Pending) catch return -1;
    p.* = .{ .arena = std.heap.ArenaAllocator.init(g_gpa), .call = null, .pid = 0, .out_fd = -1 };
    const a = p.arena.allocator();
    const hdr = readHeaderAndOptions(m, a) orelse {
        p.arena.deinit();
        g_gpa.destroy(p);
        return -1;
    };
    const opts = hdr.opts;
    const eff_mode: Mode = if (save_files) .directory else if (mode == .save) .save else if (opts.directory) .directory else .open;
    // In zfd's log: what was asked (an app that "just fails" can then be told apart).
    std.debug.print("portal: {s} request {s}: multiple={} directory={} folder=\"{s}\" parent=\"{s}\" filters={d}\n", .{
        @tagName(eff_mode), hdr.handle, opts.multiple, opts.directory, opts.folder, opts.parent, opts.filters.len,
    });
    p.is_save_files = save_files;
    p.save_files = opts.files;

    spawnPick(p, eff_mode, opts) catch {
        const rc = reply(m, response_error, &.{});
        if (p.out_fd >= 0) _ = std.os.linux.close(p.out_fd);
        p.arena.deinit();
        g_gpa.destroy(p);
        return rc;
    };
    p.call = sd.sd_bus_message_ref(m);
    // Export the Request object so the frontend can cancel us. Best-effort: without it
    // the dialog still works, it just can't be closed remotely.
    if (hdr.handle.len > 0) {
        const hz = a.dupeSentinel(u8, hdr.handle, 0) catch null;
        if (hz) |h| _ = sd.sd_bus_add_object(sd.sd_bus_message_get_bus(m), &p.slot, h.ptr, requestHandler, p);
    }
    g_pending.append(g_gpa, p) catch {
        // Can't track it: wait synchronously rather than leak the call unanswered.
        var status: i32 = 0;
        _ = std.os.linux.waitpid(p.pid, &status, 0);
        finish(p, @bitCast(status));
        return 1;
    };
    return 1; // reply deferred
}

/// requestHandler serves org.freedesktop.impl.portal.Request.Close for one pending
/// request: end the user interaction (kill the picker). The method-call reply for the
/// original request is still sent when the picker is reaped; the frontend drops it.
fn requestHandler(m: ?*sd.sd_bus_message, userdata: ?*anyopaque, ret_error: ?*sd.sd_bus_error) callconv(.c) c_int {
    _ = ret_error;
    const p: *Pending = @ptrCast(@alignCast(userdata orelse return 0));
    const member = sd.sd_bus_message_get_member(m) orelse return 0;
    if (!std.mem.eql(u8, std.mem.span(member), "Close")) return 0;
    if (!p.closed) {
        p.closed = true;
        _ = std.os.linux.kill(p.pid, .TERM);
    }
    return emptyReply(m);
}

/// reapPickers answers every request whose picker has exited. Non-blocking.
fn reapPickers() void {
    var i: usize = 0;
    while (i < g_pending.items.len) {
        const p = g_pending.items[i];
        var status: i32 = 0;
        const rc = std.os.linux.waitpid(p.pid, &status, std.os.linux.W.NOHANG);
        if (rc == @as(usize, @intCast(p.pid))) {
            _ = g_pending.swapRemove(i);
            finish(p, @bitCast(status));
            continue;
        }
        i += 1;
    }
}

/// finish replies to the request from the picker's exit status + output and frees it.
fn finish(p: *Pending, status: u32) void {
    defer {
        if (p.slot) |sl| _ = sd.sd_bus_slot_unref(sl);
        if (p.call) |cl| _ = sd.sd_bus_message_unref(cl);
        if (p.out_fd >= 0) _ = std.os.linux.close(p.out_fd);
        p.arena.deinit();
        g_gpa.destroy(p);
    }
    const a = p.arena.allocator();
    const W = std.os.linux.W;
    const code: u8 = if (p.closed) 1 else if (W.IFEXITED(status)) @intCast(W.EXITSTATUS(status)) else 2;
    const content = readFd(a, p.out_fd);
    var paths = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, content, "\n"), '\n');
    while (it.next()) |line| {
        if (line.len > 0) paths.append(a, line) catch {};
    }

    if (code == 1) {
        logReply("cancelled", code, 0);
        _ = reply(p.call, response_cancelled, &.{});
        return;
    }
    if (code != 0) {
        logReply("failed", code, 0);
        _ = reply(p.call, response_error, &.{});
        return;
    }
    var uris = std.ArrayList([]const u8).empty;
    if (p.is_save_files) {
        if (paths.items.len == 0) {
            _ = reply(p.call, response_cancelled, &.{});
            return;
        }
        const dir = paths.items[0];
        for (p.save_files) |f| {
            const joined = std.fs.path.join(a, &.{ dir, std.fs.path.basename(f) }) catch continue;
            uris.append(a, pathToUri(a, joined) catch continue) catch {};
        }
        if (uris.items.len == 0) {
            _ = reply(p.call, response_cancelled, &.{});
            return;
        }
    } else {
        for (paths.items) |path| uris.append(a, pathToUri(a, path) catch continue) catch {};
    }
    logReply("ok", code, uris.items.len);
    for (uris.items) |u| std.debug.print("portal:   {s}\n", .{u});
    _ = reply(p.call, response_ok, uris.items);
}

fn logReply(what: []const u8, code: u8, n: usize) void {
    std.debug.print("portal: picker exited {d}: answered {s}, {d} item(s)\n", .{ code, what, n });
}

/// readFd reads the whole memfd (from offset 0: the child's writes advanced only its
/// own shared offset, so pread sidesteps it). Capped at 1 MiB.
fn readFd(a: std.mem.Allocator, fd: i32) []const u8 {
    if (fd < 0) return "";
    var out = std.ArrayList(u8).empty;
    var buf: [4096]u8 = undefined;
    var off: i64 = 0;
    while (out.items.len < 1 << 20) {
        const rc = std.os.linux.pread(fd, &buf, buf.len, off);
        if (rc == 0 or rc > buf.len) break; // EOF or -errno
        out.appendSlice(a, buf[0..rc]) catch break;
        off += @intCast(rc);
    }
    return out.items;
}

const Header = struct { handle: []const u8, opts: Options };

/// readHeaderAndOptions reads the common (o s s s a{sv}) request arguments.
fn readHeaderAndOptions(m: ?*sd.sd_bus_message, a: std.mem.Allocator) ?Header {
    var handle: [*c]const u8 = undefined;
    var app_id: [*c]const u8 = undefined;
    var parent: [*c]const u8 = undefined;
    var title: [*c]const u8 = undefined;
    if (sd.sd_bus_message_read(m, "osss", &handle, &app_id, &parent, &title) < 0) return null;

    var opts = Options{};
    const handle_s: []const u8 = if (handle != null) a.dupe(u8, std.mem.span(handle)) catch "" else "";
    if (parent != null) opts.parent = a.dupe(u8, std.mem.span(parent)) catch "";
    if (title != null) opts.title = a.dupe(u8, std.mem.span(title)) catch "";
    if (sd.sd_bus_message_enter_container(m, 'a', "{sv}") < 0) return .{ .handle = handle_s, .opts = opts };
    while (sd.sd_bus_message_enter_container(m, 'e', "sv") > 0) {
        var key: [*c]const u8 = undefined;
        _ = sd.sd_bus_message_read(m, "s", &key);
        const k = std.mem.span(key);
        if (std.mem.eql(u8, k, "multiple")) {
            opts.multiple = readBool(m);
        } else if (std.mem.eql(u8, k, "directory")) {
            opts.directory = readBool(m);
        } else if (std.mem.eql(u8, k, "current_name")) {
            opts.name = readStr(m, a);
        } else if (std.mem.eql(u8, k, "accept_label")) {
            opts.accept = readStr(m, a);
        } else if (std.mem.eql(u8, k, "current_folder")) {
            opts.folder = readAy(m, a);
        } else if (std.mem.eql(u8, k, "files")) {
            opts.files = readFileList(m, a);
        } else if (std.mem.eql(u8, k, "filters")) {
            opts.filters = readFilters(m, a);
        } else if (std.mem.eql(u8, k, "current_filter")) {
            opts.current_filter = readCurrentFilter(m, a);
        } else {
            _ = sd.sd_bus_message_skip(m, "v");
        }
        _ = sd.sd_bus_message_exit_container(m); // dict entry
    }
    _ = sd.sd_bus_message_exit_container(m); // a{sv}
    return .{ .handle = handle_s, .opts = opts };
}

fn readBool(m: ?*sd.sd_bus_message) bool {
    var v: c_int = 0;
    _ = sd.sd_bus_message_read(m, "v", "b", &v);
    return v != 0;
}

fn readStr(m: ?*sd.sd_bus_message, a: std.mem.Allocator) []const u8 {
    var s: [*c]const u8 = undefined;
    _ = sd.sd_bus_message_read(m, "v", "s", &s);
    if (s == null) return "";
    return a.dupe(u8, std.mem.span(s)) catch "";
}

/// readAy reads a variant of "ay" (a NUL-terminated byte-array path).
fn readAy(m: ?*sd.sd_bus_message, a: std.mem.Allocator) []const u8 {
    if (sd.sd_bus_message_enter_container(m, 'v', "ay") < 0) return "";
    var data: ?*const anyopaque = null;
    var len: usize = 0;
    _ = sd.sd_bus_message_read_array(m, 'y', &data, &len);
    var out: []const u8 = "";
    if (data) |d| {
        var bytes = @as([*]const u8, @ptrCast(d))[0..len];
        while (bytes.len > 0 and bytes[bytes.len - 1] == 0) bytes = bytes[0 .. bytes.len - 1];
        out = a.dupe(u8, bytes) catch "";
    }
    _ = sd.sd_bus_message_exit_container(m);
    return out;
}

/// readFileList reads a variant of "a(ay)": the SaveFiles requested names.
fn readFileList(m: ?*sd.sd_bus_message, a: std.mem.Allocator) [][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    if (sd.sd_bus_message_enter_container(m, 'v', "a(ay)") < 0) return &.{};
    if (sd.sd_bus_message_enter_container(m, 'a', "(ay)") < 0) return &.{};
    while (sd.sd_bus_message_enter_container(m, 'r', "ay") > 0) {
        var data: ?*const anyopaque = null;
        var len: usize = 0;
        _ = sd.sd_bus_message_read_array(m, 'y', &data, &len);
        if (data) |d| {
            var bytes = @as([*]const u8, @ptrCast(d))[0..len];
            while (bytes.len > 0 and bytes[bytes.len - 1] == 0) bytes = bytes[0 .. bytes.len - 1];
            list.append(a, a.dupe(u8, bytes) catch "") catch {};
        }
        _ = sd.sd_bus_message_exit_container(m); // struct
    }
    _ = sd.sd_bus_message_exit_container(m); // array
    _ = sd.sd_bus_message_exit_container(m); // variant
    return list.toOwnedSlice(a) catch &.{};
}

/// readFilters reads the FileChooser `filters` option, a variant of `a(sa(us))`:
/// each filter is a name plus a list of (type, pattern) where type 0 = glob and
/// type 1 = MIME. We flatten each to a "Name|glob1 glob2 …" spec (converting MIME
/// patterns to globs) for `--pick --filter`.
fn readFilters(m: ?*sd.sd_bus_message, a: std.mem.Allocator) []const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    if (sd.sd_bus_message_enter_container(m, 'v', "a(sa(us))") < 0) return &.{};
    if (sd.sd_bus_message_enter_container(m, 'a', "(sa(us))") < 0) return &.{};
    while (sd.sd_bus_message_enter_container(m, 'r', "sa(us)") > 0) {
        if (readOneFilter(m, a)) |spec| list.append(a, spec) catch {};
        _ = sd.sd_bus_message_exit_container(m); // struct
    }
    _ = sd.sd_bus_message_exit_container(m); // array
    _ = sd.sd_bus_message_exit_container(m); // variant
    return list.toOwnedSlice(a) catch &.{};
}

/// readOneFilter reads one `sa(us)` filter (the message is already inside its struct)
/// into a "Name|pat1 pat2 …" spec, mapping MIME patterns (type 1) through mimeToGlobs.
fn readOneFilter(m: ?*sd.sd_bus_message, a: std.mem.Allocator) ?[]const u8 {
    var name_c: [*c]const u8 = undefined;
    if (sd.sd_bus_message_read(m, "s", &name_c) < 0) return null;
    var buf = std.ArrayList(u8).empty;
    buf.appendSlice(a, if (name_c != null) std.mem.span(name_c) else "") catch return null;
    buf.append(a, '|') catch return null;
    if (sd.sd_bus_message_enter_container(m, 'a', "(us)") < 0) return buf.toOwnedSlice(a) catch null;
    while (sd.sd_bus_message_enter_container(m, 'r', "us") > 0) {
        var typ: c_uint = 0;
        var pat_c: [*c]const u8 = undefined;
        _ = sd.sd_bus_message_read(m, "us", &typ, &pat_c);
        const pat = if (pat_c != null) std.mem.span(pat_c) else "";
        if (typ == 1) {
            for (core.filter.mimeToGlobs(pat)) |g| {
                buf.appendSlice(a, g) catch {};
                buf.append(a, ' ') catch {};
            }
        } else {
            buf.appendSlice(a, pat) catch {};
            buf.append(a, ' ') catch {};
        }
        _ = sd.sd_bus_message_exit_container(m); // (us) struct
    }
    _ = sd.sd_bus_message_exit_container(m); // a(us)
    return buf.toOwnedSlice(a) catch null;
}

/// readCurrentFilter reads the `current_filter` option (a variant of `(sa(us))`) and
/// returns just its name (owned); we only need it to preselect the matching filter.
fn readCurrentFilter(m: ?*sd.sd_bus_message, a: std.mem.Allocator) []const u8 {
    if (sd.sd_bus_message_enter_container(m, 'v', "(sa(us))") < 0) return "";
    if (sd.sd_bus_message_enter_container(m, 'r', "sa(us)") < 0) {
        _ = sd.sd_bus_message_exit_container(m);
        return "";
    }
    var name_c: [*c]const u8 = undefined;
    _ = sd.sd_bus_message_read(m, "s", &name_c);
    const name = if (name_c != null) a.dupe(u8, std.mem.span(name_c)) catch "" else "";
    _ = sd.sd_bus_message_skip(m, "a(us)"); // patterns not needed
    _ = sd.sd_bus_message_exit_container(m); // struct
    _ = sd.sd_bus_message_exit_container(m); // variant
    return name;
}

/// spawnPick starts `zfd --pick …` for request `p` without waiting for it; the exit
/// code (0 chosen, 1 cancelled, other = error) and stdout are collected by reapPickers.
fn spawnPick(p: *Pending, mode: Mode, opts: Options) !void {
    const a = p.arena.allocator();
    // An upgraded binary shows as "<path> (deleted)"; run the new one at <path>.
    var self_exe: []const u8 = try std.process.executablePathAlloc(g_io, a);
    if (std.mem.endsWith(u8, self_exe, deleted_suffix)) self_exe = self_exe[0 .. self_exe.len - deleted_suffix.len];

    var argv = std.ArrayList([]const u8).empty;
    try argv.append(a, self_exe);
    try argv.append(a, "--pick");
    switch (mode) {
        .save => try argv.append(a, "--save"),
        .directory => try argv.append(a, "--directory"),
        .open => {},
    }
    if (opts.multiple) try argv.append(a, "--multiple");
    if (opts.name.len > 0) {
        try argv.append(a, "--name");
        try argv.append(a, opts.name);
    }
    if (opts.folder.len > 0) {
        try argv.append(a, "--folder");
        try argv.append(a, opts.folder);
    }
    if (opts.parent.len > 0) {
        try argv.append(a, "--parent");
        try argv.append(a, opts.parent);
    }
    if (opts.title.len > 0) {
        try argv.append(a, "--title");
        try argv.append(a, opts.title);
    }
    const label = try withoutMnemonic(a, opts.accept);
    if (label.len > 0) {
        try argv.append(a, "--accept");
        try argv.append(a, label);
    }
    for (opts.filters) |spec| {
        try argv.append(a, "--filter");
        try argv.append(a, spec);
    }
    if (opts.current_filter.len > 0) {
        try argv.append(a, "--current-filter");
        try argv.append(a, opts.current_filter);
    }

    // stdout → an anonymous memfd: concurrent requests each get their own, and nothing
    // is left behind in /tmp if we die mid-request.
    const mfd = std.os.linux.memfd_create("zfd-pick", std.os.linux.MFD.CLOEXEC);
    if (mfd > std.math.maxInt(i32)) return error.MemfdFailed;
    p.out_fd = @intCast(mfd);
    const out_file: std.Io.File = .{ .handle = p.out_fd, .flags = .{ .nonblocking = false } };
    const child = std.process.spawn(g_io, .{ .argv = argv.items, .stdout = .{ .file = out_file } }) catch return error.SpawnFailed;
    p.pid = child.id orelse return error.SpawnFailed; // reaped by reapPickers (waitpid), not child.wait
}

/// withoutMnemonic drops an accept label's keyboard-shortcut mark: GTK's "_Add"
/// ("__" is a literal underscore) and the "&Add" some apps send.
fn withoutMnemonic(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if ((s[i] == '_' or s[i] == '&') and i + 1 < s.len) {
            if (s[i + 1] == s[i]) {
                try out.append(a, s[i]);
                i += 1;
                continue;
            }
            if (std.ascii.isAlphanumeric(s[i + 1])) continue; // the mark
        }
        try out.append(a, s[i]);
    }
    return out.items;
}

test "withoutMnemonic drops the shortcut mark" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Add", try withoutMnemonic(a, "_Add"));
    try std.testing.expectEqualStrings("Add", try withoutMnemonic(a, "&Add"));
    try std.testing.expectEqualStrings("Save_as", try withoutMnemonic(a, "Save__as"));
    try std.testing.expectEqualStrings("Open", try withoutMnemonic(a, "Open"));
    try std.testing.expectEqualStrings("Save & Close", try withoutMnemonic(a, "Save & Close"));
}

/// reply sends the (u a{sv}) portal response: response code plus, on success, the
/// `uris` string array in the results dict.
fn reply(m: ?*sd.sd_bus_message, response: u32, uris: []const []const u8) c_int {
    var r: ?*sd.sd_bus_message = null;
    if (sd.sd_bus_message_new_method_return(m, &r) < 0) return -1;
    defer _ = sd.sd_bus_message_unref(r);

    _ = sd.sd_bus_message_append(r, "u", response);
    _ = sd.sd_bus_message_open_container(r, 'a', "{sv}");
    if (response == response_ok and uris.len > 0) {
        _ = sd.sd_bus_message_open_container(r, 'e', "sv");
        _ = sd.sd_bus_message_append(r, "s", "uris");
        _ = sd.sd_bus_message_open_container(r, 'v', "as");
        _ = sd.sd_bus_message_open_container(r, 'a', "s");
        for (uris) |u| {
            var buf: [4200]u8 = undefined;
            const z = std.mem.printSentinel(&buf, "{s}", .{u}, 0) catch continue;
            _ = sd.sd_bus_message_append(r, "s", z.ptr);
        }
        _ = sd.sd_bus_message_close_container(r); // as
        _ = sd.sd_bus_message_close_container(r); // v
        _ = sd.sd_bus_message_close_container(r); // dict entry
    }
    _ = sd.sd_bus_message_close_container(r); // a{sv}

    if (sd.sd_bus_send(null, r, null) < 0) return -1;
    return 1; // handled
}

/// pathToUri turns an absolute path into a percent-safe file:// URI. The encoding is
/// the same RFC-3986 unreserved-set rule as the trashinfo Path (kept slash literal),
/// so we reuse fsops.percentEncodePath rather than a second copy of it here.
fn pathToUri(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    const enc = try core.fsops.percentEncodePath(a, path);
    defer a.free(enc);
    return std.mem.concat(a, u8, &.{ "file://", enc });
}
