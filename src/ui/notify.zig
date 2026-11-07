//! Desktop notifications over D-Bus (org.freedesktop.Notifications), with one
//! clickable action, e.g. "USB stick connected [Open]". Talks to the session bus with
//! sd-bus (already linked for the portal), so it needs no notify-send/libnotify.
//!
//! Each notification gets a short-lived detached thread: it sends Notify, then waits
//! (up to `wait_s`) for the user to click the action or dismiss it. A click is parked
//! here as the notification's `key` until the UI thread takes it (`takeAction`).
//! Only one ZFD process per session notifies (`primary`), so several open windows
//! don't each pop the same notification.

const std = @import("std");
const sd = @import("c_sdbus");

const wait_s = 120;

pub const Notifier = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    clicked: ?[]u8 = null, // guarded: key of the last clicked notification (owned)
    wake: ?*const fn () void = null,
    refs: std.atomic.Value(u32) = .init(1), // UI + one per live notification thread

    pub fn create(io: std.Io, alloc: std.mem.Allocator, wake: ?*const fn () void) !*Notifier {
        const self = try alloc.create(Notifier);
        self.* = .{ .alloc = alloc, .io = io, .wake = wake };
        return self;
    }

    /// release drops the UI's reference; threads still waiting finish on their own.
    pub fn release(self: *Notifier) void {
        self.unref();
    }

    fn unref(self: *Notifier) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.clicked) |k| self.alloc.free(k);
        self.alloc.destroy(self);
    }

    /// send shows a notification with an `action_label` button (empty = none);
    /// clicking it (or the notification body) later hands `key` to takeAction.
    pub fn send(self: *Notifier, summary: []const u8, body: []const u8, icon: []const u8, action_label: []const u8, key: []const u8) void {
        const job = Job.create(self, summary, body, icon, action_label, key) catch return;
        _ = self.refs.fetchAdd(1, .acq_rel);
        const t = std.Thread.spawn(.{}, Job.run, .{job}) catch {
            job.destroy();
            self.unref();
            return;
        };
        t.detach();
    }

    /// takeAction returns the key of a notification the user clicked (owned), or null.
    pub fn takeAction(self: *Notifier) ?[]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const k = self.clicked;
        self.clicked = null;
        return k;
    }

    fn setClicked(self: *Notifier, key: []const u8) void {
        const dup = self.alloc.dupe(u8, key) catch return;
        self.mutex.lockUncancelable(self.io);
        if (self.clicked) |old| self.alloc.free(old);
        self.clicked = dup;
        self.mutex.unlock(self.io);
        if (self.wake) |w| w();
    }
};

const Job = struct {
    n: *Notifier,
    summary: [:0]u8,
    body: [:0]u8,
    icon: [:0]u8,
    action: [:0]u8,
    key: []u8,
    id: u32 = 0,
    done: bool = false,

    fn create(n: *Notifier, summary: []const u8, body: []const u8, icon: []const u8, action: []const u8, key: []const u8) !*Job {
        const a = n.alloc;
        const j = try a.create(Job);
        errdefer a.destroy(j);
        j.* = .{
            .n = n,
            .summary = try a.dupeSentinel(u8, summary, 0),
            .body = try a.dupeSentinel(u8, body, 0),
            .icon = try a.dupeSentinel(u8, icon, 0),
            .action = try a.dupeSentinel(u8, action, 0),
            .key = try a.dupe(u8, key),
        };
        return j;
    }

    fn destroy(j: *Job) void {
        const a = j.n.alloc;
        a.free(j.summary);
        a.free(j.body);
        a.free(j.icon);
        a.free(j.action);
        a.free(j.key);
        a.destroy(j);
    }

    fn run(j: *Job) void {
        const n = j.n;
        defer {
            j.destroy();
            n.unref();
        }
        var bus: ?*sd.sd_bus = null;
        if (sd.sd_bus_open_user(&bus) < 0) return;
        defer _ = sd.sd_bus_flush_close_unref(bus);

        // Listen before sending, so a very quick click can't slip past.
        var slot: ?*sd.sd_bus_slot = null;
        if (sd.sd_bus_match_signal(bus, &slot, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", null, onSignal, j) < 0) return;
        defer _ = sd.sd_bus_slot_unref(slot);

        var err: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
        defer sd.sd_bus_error_free(&err);
        var reply: ?*sd.sd_bus_message = null;
        const has_action = j.action.len > 0;
        // Notify(app_name, replaces_id, app_icon, summary, body, actions, hints, timeout)
        const rc = if (has_action)
            sd.sd_bus_call_method(bus, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", &err, &reply, "susssasa{sv}i", "ZFD", @as(u32, 0), j.icon.ptr, j.summary.ptr, j.body.ptr, @as(c_int, 4), "default", j.action.ptr, "open", j.action.ptr, @as(c_int, 0), @as(i32, -1))
        else
            sd.sd_bus_call_method(bus, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", &err, &reply, "susssasa{sv}i", "ZFD", @as(u32, 0), j.icon.ptr, j.summary.ptr, j.body.ptr, @as(c_int, 0), @as(c_int, 0), @as(i32, -1));
        if (rc < 0) return;
        defer _ = sd.sd_bus_message_unref(reply);
        if (sd.sd_bus_message_read(reply, "u", &j.id) < 0) return;
        if (!has_action) return;

        var waited_us: u64 = 0;
        const step_us: u64 = 500 * std.time.us_per_ms;
        while (!j.done and waited_us < wait_s * std.time.us_per_s) {
            const r = sd.sd_bus_process(bus, null);
            if (r < 0) return;
            if (r > 0) continue;
            if (sd.sd_bus_wait(bus, step_us) < 0) return;
            waited_us += step_us;
        }
    }

    fn onSignal(m: ?*sd.sd_bus_message, userdata: ?*anyopaque, _: ?*sd.sd_bus_error) callconv(.c) c_int {
        const j: *Job = @ptrCast(@alignCast(userdata orelse return 0));
        const member = std.mem.span(sd.sd_bus_message_get_member(m) orelse return 0);
        var id: u32 = 0;
        if (std.mem.eql(u8, member, "ActionInvoked")) {
            var action: [*c]const u8 = null;
            if (sd.sd_bus_message_read(m, "us", &id, &action) < 0 or id != j.id) return 0;
            j.n.setClicked(j.key);
            j.done = true;
        } else if (std.mem.eql(u8, member, "NotificationClosed")) {
            if (sd.sd_bus_message_read(m, "u", &id) < 0 or id != j.id) return 0;
            j.done = true;
        }
        return 0;
    }
};

/// primary reports whether this process should send desktop notifications: the first
/// ZFD of the session takes an exclusive lock in the runtime dir and keeps it until it
/// exits. Others still show their in-app banner.
pub fn primary(runtime_dir: []const u8) bool {
    if (runtime_dir.len == 0) return true;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.mem.printSentinel(&buf, "{s}/zfd-notify.lock", .{runtime_dir}, 0) catch return true;
    const linux = std.os.linux;
    const fd = linux.open(p.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(fd) != .SUCCESS) return true;
    const lock_ex_nb: usize = 2 | 4; // LOCK_EX | LOCK_NB
    const rc = linux.syscall2(.flock, fd, lock_ex_nb);
    if (linux.errno(rc) != .SUCCESS) {
        _ = linux.close(@intCast(fd));
        return false;
    }
    return true; // fd intentionally kept open: the lock lives as long as we do
}

// ---------------------------------------------------------------------------
// Needs a session bus with a notification server, so it only runs when asked:
// ZFD_NOTIFY_TEST=1 under a bus whose server clicks the action (see the commit).
test "a clicked notification action reaches takeAction" {
    if (std.c.getenv("ZFD_NOTIFY_TEST") == null) return error.SkipZigTest;
    const n = try Notifier.create(std.testing.io, std.testing.allocator, null);
    defer n.release();
    n.send("USB stick connected", "vfat  \u{00B7}  8 GB", "drive-removable-media", "Mount and Open", "/dev/sdz1");
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        if (n.takeAction()) |k| {
            defer std.testing.allocator.free(k);
            try std.testing.expectEqualStrings("/dev/sdz1", k);
            return;
        }
        _ = std.os.linux.nanosleep(&.{ .sec = 0, .nsec = 100 * std.time.ns_per_ms }, null);
    }
    return error.NoClick;
}
