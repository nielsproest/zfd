//! Raw X11 for the bits GLFW doesn't do: WM-driven move/resize of our borderless
//! (CSD) window, transient-for parenting, and the XDND drag source. We reach the
//! X11 handles via GLFW's native access. Xlib's macro pollution (None/Bool/Status…)
//! is quarantined to this file's `x` (src/c/x11.h); the rest of the app never sees it.

const std = @import("std");

pub const x = @import("c_x11"); // src/c/x11.h, translated in build.zig

/// Set from ZFD_DEBUG at startup; logs WM move/resize attempts to stderr.
pub var debug: bool = false;

/// _NET_WM_MOVERESIZE directions (EWMH).
pub const Direction = enum(c_long) {
    size_topleft = 0,
    size_top = 1,
    size_topright = 2,
    size_right = 3,
    size_bottomright = 4,
    size_bottom = 5,
    size_bottomleft = 6,
    size_left = 7,
    move = 8,
};

fn display() ?*x.Display {
    return x.glfwGetX11Display();
}

fn window(glfw: ?*anyopaque) x.Window {
    return x.glfwGetX11Window(@ptrCast(glfw));
}

/// nowNs reads a monotonic clock in nanoseconds via the raw Linux syscall (this Zig's
/// std.time has no Timer/Instant, and the app is Linux-only, the same raw-syscall approach
/// main.zig uses for fork/setsid). Used only for coarse drag-out timeouts.
fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// ErrorTrap swallows X errors for a stretch of calls that touch OTHER clients'
/// windows (drop targets, a ZFD window we hand a tab to). Any of those can be destroyed
/// between our query and our request, and Xlib's default handler answers the resulting
/// BadWindow by exiting the whole process.
const ErrorTrap = struct {
    dpy: *x.Display,
    prev: x.XErrorHandler,

    fn begin(dpy: *x.Display) ErrorTrap {
        _ = x.XSync(dpy, 0); // don't swallow errors that belong to earlier requests
        return .{ .dpy = dpy, .prev = x.XSetErrorHandler(ignoreXError) };
    }
    fn end(t: ErrorTrap) void {
        _ = x.XSync(t.dpy, 0); // flush out our requests' errors while still trapped
        _ = x.XSetErrorHandler(t.prev);
    }
};

fn ignoreXError(_: ?*x.Display, _: [*c]x.XErrorEvent) callconv(.c) c_int {
    return 0;
}

/// startMoveResize asks the window manager to move or resize our window from the
/// current pointer position: how a borderless window gets interactive move/resize.
/// A held mouse button is an implicit X pointer grab, so we ungrab first (else the
/// WM won't take over the drag).
pub fn startMoveResize(glfw: ?*anyopaque, dir: Direction) void {
    const dpy = display() orelse return;
    const w = window(glfw);

    var root_ret: x.Window = undefined;
    var child: x.Window = undefined;
    var rx: c_int = 0;
    var ry: c_int = 0;
    var wx: c_int = 0;
    var wy: c_int = 0;
    var mask: c_uint = 0;
    _ = x.XQueryPointer(dpy, w, &root_ret, &child, &rx, &ry, &wx, &wy, &mask);
    _ = x.XUngrabPointer(dpy, x.CurrentTime);

    if (debug) std.debug.print("zfd[wm]: startMoveResize dir={d} root=({d},{d}) win=0x{x}\n", .{ @backingInt(dir), rx, ry, w });

    const atom = x.XInternAtom(dpy, "_NET_WM_MOVERESIZE", 0);
    var ev = std.mem.zeroes(x.XEvent);
    ev.xclient.type = x.ClientMessage;
    ev.xclient.window = w;
    ev.xclient.message_type = atom;
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = rx;
    ev.xclient.data.l[1] = ry;
    ev.xclient.data.l[2] = @backingInt(dir);
    ev.xclient.data.l[3] = 1; // mouse button 1
    ev.xclient.data.l[4] = 0;

    const root = x.XDefaultRootWindow(dpy);
    _ = x.XSendEvent(dpy, root, 0, x.SubstructureRedirectMask | x.SubstructureNotifyMask, &ev);
    _ = x.XFlush(dpy);
}

/// DragOut holds the atoms + negotiated state of one XDND drag-out. Kept as a struct
/// so the pump helpers below don't take a dozen parameters.
const DragOut = struct {
    dpy: *x.Display,
    src: x.Window,
    uri_list: []const u8,
    text_list: []const u8,

    a_sel: x.Atom,
    a_enter: x.Atom,
    a_pos: x.Atom,
    a_status: x.Atom,
    a_leave: x.Atom,
    a_drop: x.Atom,
    a_finished: x.Atom,
    a_action: x.Atom,
    a_uri: x.Atom,
    a_text: x.Atom,
    a_utf8: x.Atom,
    a_targets: x.Atom,
    a_aware: x.Atom,

    target: x.Window = x.None,
    target_ver: c_long = 5,
    accepted: bool = false,
    status_seen: bool = false, // the current target has answered at least once
    // XDND flow control: after a Position, wait for its Status before sending the next;
    // motion in between only updates `pending`. Flooding a Chromium/Electron target
    // (Discord) with Positions makes it re-fetch the data and re-fire its drag overlay
    // for every one of them.
    awaiting_status: bool = false,
    pending: ?struct { x: c_int, y: c_int, t: x.Time } = null,

    /// retarget points the drag at whatever XDND-aware window is under (rx, ry), sending
    /// Leave/Enter across the transition, then a Position to the current target.
    fn retarget(d: *DragOut, rx: c_int, ry: c_int, time: x.Time) void {
        var ver: c_long = 5;
        var newt = findTarget(d.dpy, x.XDefaultRootWindow(d.dpy), d.a_aware, &ver);
        if (newt == d.src) newt = x.None; // never drag-out onto our own window (self-XDND re-entrancy)
        if (newt != d.target) {
            if (d.target != x.None) d.leave();
            d.target = newt;
            d.accepted = false;
            d.status_seen = false;
            d.awaiting_status = false;
            d.pending = null;
            // XDND is version-negotiated: announce min(ours, theirs), or a v3/v4 target
            // (Java/Motif apps, older Qt) rejects the whole drag as being from the future.
            d.target_ver = @min(@as(c_long, 5), ver);
            if (d.target != x.None)
                sendClient(d.dpy, d.target, d.a_enter, @intCast(d.src), (d.target_ver << 24), @intCast(d.a_uri), @intCast(d.a_text), @intCast(d.a_utf8));
        }
        if (d.target == x.None) return;
        if (d.awaiting_status) {
            d.pending = .{ .x = rx, .y = ry, .t = time };
            return;
        }
        d.sendPosition(rx, ry, time);
    }

    fn sendPosition(d: *DragOut, rx: c_int, ry: c_int, time: x.Time) void {
        const packed_xy: c_long = (@as(c_long, rx) << 16) | (ry & 0xffff);
        sendClient(d.dpy, d.target, d.a_pos, @intCast(d.src), 0, packed_xy, @intCast(time), @intCast(d.a_action));
        d.awaiting_status = true;
    }

    /// onStatus records the current target's answer and releases the next queued
    /// Position, if the pointer moved while we were waiting.
    fn onStatus(d: *DragOut, accepted: bool) void {
        d.accepted = accepted;
        d.status_seen = true;
        d.awaiting_status = false;
        if (d.pending) |p| {
            d.pending = null;
            d.sendPosition(p.x, p.y, p.t);
        }
    }

    fn leave(d: *DragOut) void {
        if (d.target == x.None) return;
        sendClient(d.dpy, d.target, d.a_leave, @intCast(d.src), 0, 0, 0, 0);
        d.target = x.None;
        d.accepted = false;
        d.status_seen = false;
        d.awaiting_status = false;
        d.pending = null;
    }

    fn drop(d: *DragOut, time: x.Time) void {
        if (d.target == x.None) return;
        sendClient(d.dpy, d.target, d.a_drop, @intCast(d.src), 0, @intCast(time), 0, 0);
    }

    /// serve answers a target's XConvertSelection. Handles TARGETS (the "what do you
    /// have?" query most toolkits send first; answering None there is why some apps
    /// refused the drop outright) plus the three flavours we advertise.
    fn serve(d: *DragOut, req: *x.XSelectionRequestEvent) void {
        var notify = std.mem.zeroes(x.XEvent);
        notify.xselection.type = x.SelectionNotify;
        notify.xselection.display = req.display;
        notify.xselection.requestor = req.requestor;
        notify.xselection.selection = req.selection;
        notify.xselection.target = req.target;
        notify.xselection.time = req.time;
        notify.xselection.property = req.property;
        // A requestor may send property == None (obsolete clients): reply into the target
        // atom, as ICCCM prescribes.
        if (notify.xselection.property == x.None) notify.xselection.property = req.target;
        const prop = notify.xselection.property;

        if (req.target == d.a_targets) {
            var list = [_]c_long{ @intCast(d.a_targets), @intCast(d.a_uri), @intCast(d.a_text), @intCast(d.a_utf8) };
            _ = x.XChangeProperty(d.dpy, req.requestor, prop, x.XA_ATOM, 32, x.PropModeReplace, @ptrCast(&list), list.len);
        } else if (req.target == d.a_uri) {
            _ = x.XChangeProperty(d.dpy, req.requestor, prop, req.target, 8, x.PropModeReplace, d.uri_list.ptr, @intCast(d.uri_list.len));
        } else if (req.target == d.a_text or req.target == d.a_utf8 or req.target == x.XA_STRING) {
            _ = x.XChangeProperty(d.dpy, req.requestor, prop, req.target, 8, x.PropModeReplace, d.text_list.ptr, @intCast(d.text_list.len));
        } else {
            notify.xselection.property = x.None; // unsupported flavour
        }
        _ = x.XSendEvent(d.dpy, req.requestor, 0, x.NoEventMask, &notify);
        _ = x.XFlush(d.dpy);
    }

    fn sendClient(dpy: *x.Display, target: x.Window, mtype: x.Atom, l0: c_long, l1: c_long, l2: c_long, l3: c_long, l4: c_long) void {
        var ev = std.mem.zeroes(x.XEvent);
        ev.xclient.type = x.ClientMessage;
        ev.xclient.window = target;
        ev.xclient.message_type = mtype;
        ev.xclient.format = 32;
        ev.xclient.data.l[0] = l0;
        ev.xclient.data.l[1] = l1;
        ev.xclient.data.l[2] = l2;
        ev.xclient.data.l[3] = l3;
        ev.xclient.data.l[4] = l4;
        _ = x.XSendEvent(dpy, target, 0, x.NoEventMask, &ev);
        _ = x.XFlush(dpy);
    }
};

/// dragEventPred selects only the events the drag-out loop consumes. Everything else
/// (Expose, ConfigureNotify, FocusIn, the WM's ClientMessages…) stays queued for GLFW
/// to process when the drag ends. The previous loop drained the queue with XNextEvent
/// and discarded whatever it didn't recognise, so a drag-out silently ate the window's
/// resize/focus/close events, and the app came back from a drag confused about its own
/// state, which is where the "stuck after dragging" reports came from.
fn dragEventPred(_: ?*x.Display, ev: [*c]x.XEvent, _: x.XPointer) callconv(.c) c_int {
    return switch (ev.*.type) {
        x.MotionNotify, x.ButtonPress, x.ButtonRelease, x.KeyPress, x.ClientMessage, x.SelectionRequest, x.SelectionClear => 1,
        else => 0,
    };
}

/// startDragOut runs a hand-written XDND *source*: GLFW/ImGui have no drag-source
/// API. It's a modal loop: grab the pointer, follow it to whatever XDND-aware window
/// it's over (sending Enter/Position), and on release send Drop (serving the dragged
/// paths as text/uri-list or plain text) or Leave. Blocks until the drop completes or
/// is abandoned. `uri_list` is CRLF-joined, percent-encoded `file://` URIs;
/// `text_list` is the same paths newline-joined, for targets that want plain text.
pub fn startDragOut(glfw: ?*anyopaque, uri_list: []const u8, text_list: []const u8) void {
    const dpy = display() orelse return;
    const src = window(glfw);
    const root = x.XDefaultRootWindow(dpy);

    // Only a drag whose button is REALLY still down may start. The caller works from
    // ImGui's view of the mouse, which lags the server: right after a drag-out ends
    // (the grab ate the physical release) ImGui can still report a live payload for a
    // frame, and starting again there produced a phantom drag with no button held:
    // the target (Discord) got a fresh XdndEnter it could never see finish, and kept
    // re-offering "Upload file" until the user clicked.
    var p_root: c_int = 0;
    var p_rooty: c_int = 0;
    {
        var rr: x.Window = undefined;
        var ch: x.Window = undefined;
        var wx: c_int = 0;
        var wy: c_int = 0;
        var mask: c_uint = 0;
        if (x.XQueryPointer(dpy, root, &rr, &ch, &p_root, &p_rooty, &wx, &wy, &mask) == 0) return;
        if (mask & x.Button1Mask == 0) return;
    }

    const trap = ErrorTrap.begin(dpy);
    defer trap.end();

    var d = DragOut{
        .dpy = dpy,
        .src = src,
        .uri_list = uri_list,
        .text_list = text_list,
        .a_sel = x.XInternAtom(dpy, "XdndSelection", 0),
        .a_enter = x.XInternAtom(dpy, "XdndEnter", 0),
        .a_pos = x.XInternAtom(dpy, "XdndPosition", 0),
        .a_status = x.XInternAtom(dpy, "XdndStatus", 0),
        .a_leave = x.XInternAtom(dpy, "XdndLeave", 0),
        .a_drop = x.XInternAtom(dpy, "XdndDrop", 0),
        .a_finished = x.XInternAtom(dpy, "XdndFinished", 0),
        .a_action = x.XInternAtom(dpy, "XdndActionCopy", 0),
        .a_uri = x.XInternAtom(dpy, "text/uri-list", 0),
        .a_text = x.XInternAtom(dpy, "text/plain;charset=utf-8", 0),
        .a_utf8 = x.XInternAtom(dpy, "UTF8_STRING", 0),
        .a_targets = x.XInternAtom(dpy, "TARGETS", 0),
        .a_aware = x.XInternAtom(dpy, "XdndAware", 0),
    };

    _ = x.XSetSelectionOwner(dpy, d.a_sel, src, x.CurrentTime);
    if (x.XGetSelectionOwner(dpy, d.a_sel) != src) return; // couldn't own the selection: no data to serve

    // A held button is an implicit grab on OUR window; re-grab on the root so we keep
    // following the pointer over other applications' windows.
    _ = x.XUngrabPointer(dpy, x.CurrentTime);
    const cursor = x.XCreateFontCursor(dpy, 60); // XC_hand2, the conventional drag cursor
    if (x.XGrabPointer(dpy, root, 0, x.PointerMotionMask | x.ButtonReleaseMask | x.ButtonPressMask, x.GrabModeAsync, x.GrabModeAsync, x.None, cursor, x.CurrentTime) != x.GrabSuccess) {
        _ = x.XSetSelectionOwner(dpy, d.a_sel, x.None, x.CurrentTime);
        if (cursor != 0) _ = x.XFreeCursor(dpy, cursor);
        return;
    }
    // Grab the keyboard too, so Escape can cancel the drag. Best-effort: if another
    // client holds it we simply lose the Escape shortcut.
    const kb = x.XGrabKeyboard(dpy, root, 0, x.GrabModeAsync, x.GrabModeAsync, x.CurrentTime) == x.GrabSuccess;
    defer {
        if (kb) _ = x.XUngrabKeyboard(dpy, x.CurrentTime);
        _ = x.XUngrabPointer(dpy, x.CurrentTime);
        if (cursor != 0) _ = x.XFreeCursor(dpy, cursor);
    }
    const esc_code: c_uint = x.XKeysymToKeycode(dpy, x.XK_Escape);

    // Monotonic deadlines. The old loop blocked in XNextEvent with a *poll-style* counter
    // for a timeout, so the counter never advanced while blocked: a target that never
    // sends XdndFinished (Electron/Chromium apps are prone to this) froze the whole
    // single-threaded app. Poll the X connection fd instead and enforce real wall-clock
    // caps, always sending XdndLeave when we bail so the target's drop overlay clears.
    const start_ns = nowNs();
    const fd: i32 = @intCast(x.XConnectionNumber(dpy));
    const abort_ns: u64 = 20 * std.time.ns_per_s; // pre-drop: user can't hold the drag forever
    const finish_ns: u64 = 4 * std.time.ns_per_s; // post-drop: brief wait for data fetch + XdndFinished
    const settle_ns: u64 = 400 * std.time.ns_per_ms; // post-release: give a slow target time to answer

    var dropped = false;
    var drop_at_ns: u64 = 0;
    var release_at_ns: u64 = 0; // set when button 1 came up but the target hasn't answered yet
    var release_time: x.Time = x.CurrentTime;

    // Aim at whatever is already under the pointer: the user may press, leave the window
    // and release without generating a motion event inside the target.
    d.retarget(p_root, p_rooty, x.CurrentTime);

    loop: while (true) {
        var ev: x.XEvent = undefined;
        while (x.XCheckIfEvent(dpy, &ev, dragEventPred, null) != 0) {
            switch (ev.type) {
                x.MotionNotify => {
                    // Once the button is up the target is settled; a stray motion must
                    // not re-aim the drag at a window the user already left.
                    if (dropped or release_at_ns != 0) continue;
                    d.retarget(ev.xmotion.x_root, ev.xmotion.y_root, ev.xmotion.time);
                },
                x.ClientMessage => {
                    if (ev.xclient.message_type == d.a_status) {
                        // Only trust a status from the window we are currently over: a
                        // late reply from the previous target used to flip `accepted` and
                        // make us drop on a window that had already been left.
                        if (d.target != x.None and ev.xclient.data.l[0] == @as(c_long, @intCast(d.target)))
                            d.onStatus((ev.xclient.data.l[1] & 1) != 0);
                    } else if (ev.xclient.message_type == d.a_finished) {
                        break :loop;
                    }
                },
                x.SelectionRequest => d.serve(&ev.xselectionrequest),
                x.SelectionClear => break :loop, // lost the selection: nothing left to hand over
                x.KeyPress => {
                    if (esc_code != 0 and ev.xkey.keycode == esc_code and !dropped) {
                        d.leave();
                        break :loop;
                    }
                },
                x.ButtonRelease => {
                    // Only button 1 ends the drag, and only the first one: a second
                    // release (or a right-click released mid-drag) must not re-drop.
                    if (ev.xbutton.button != 1 or dropped or release_at_ns != 0) continue;
                    release_time = ev.xbutton.time;
                    if (d.target == x.None) break :loop;
                    if (d.status_seen and !d.accepted) {
                        d.leave();
                        break :loop;
                    }
                    if (!d.status_seen) {
                        release_at_ns = nowNs(); // wait below for the target to answer
                        continue;
                    }
                    d.drop(release_time);
                    dropped = true; // keep looping to serve the selection + XdndFinished
                    drop_at_ns = nowNs();
                    _ = x.XUngrabPointer(dpy, x.CurrentTime);
                },
                else => {},
            }
        }

        // Enforce the deadline that matches our phase.
        const now = nowNs();
        if (dropped) {
            if (now -| drop_at_ns >= finish_ns) break :loop; // target went silent post-drop; stop waiting
        } else if (release_at_ns != 0) {
            // Button already up, waiting on a first XdndStatus. Targets that answer
            // asynchronously (GTK apps under load) used to lose the drop entirely,
            // because a release before the first status counted as "not accepted".
            if (d.status_seen or now -| release_at_ns >= settle_ns) {
                if (d.accepted) {
                    d.drop(release_time);
                    dropped = true;
                    drop_at_ns = nowNs();
                    _ = x.XUngrabPointer(dpy, x.CurrentTime);
                    release_at_ns = 0;
                } else {
                    d.leave();
                    break :loop;
                }
            }
        } else if (now -| start_ns >= abort_ns) {
            d.leave();
            break :loop;
        }
        // Idle: sleep on the X fd until an event arrives or the tick elapses (no busy-spin).
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 20) catch {};
    }
    if (x.XGetSelectionOwner(dpy, d.a_sel) == src) _ = x.XSetSelectionOwner(dpy, d.a_sel, x.None, x.CurrentTime);
    _ = x.XFlush(dpy);
}

/// findTarget descends the window tree under the pointer and returns the deepest
/// XdndAware window (the drop target), or None. `ver_out` receives that window's
/// advertised XDND protocol version.
fn findTarget(dpy: *x.Display, root: x.Window, a_aware: x.Atom, ver_out: *c_long) x.Window {
    var w = root;
    var found: x.Window = x.None;
    var depth: usize = 0;
    ver_out.* = 5;
    while (depth < 32) : (depth += 1) {
        var rr: x.Window = undefined;
        var child: x.Window = undefined;
        var rx: c_int = 0;
        var ry: c_int = 0;
        var wx: c_int = 0;
        var wy: c_int = 0;
        var mask: c_uint = 0;
        if (x.XQueryPointer(dpy, w, &rr, &child, &rx, &ry, &wx, &wy, &mask) == 0) break;
        if (awareVersion(dpy, w, a_aware)) |v| {
            found = w;
            ver_out.* = v;
        }
        if (child == x.None) break;
        w = child;
    }
    return found;
}

/// awareVersion returns the XDND protocol version `w` advertises, or null if it isn't
/// a drop target. (XGetWindowProperty reports Success for a missing property too, so
/// the item count is what actually decides.)
fn awareVersion(dpy: *x.Display, w: x.Window, a_aware: x.Atom) ?c_long {
    var actual: x.Atom = undefined;
    var fmt: c_int = 0;
    var n: c_ulong = 0;
    var after: c_ulong = 0;
    var data: [*c]u8 = null;
    if (x.XGetWindowProperty(dpy, w, a_aware, 0, 1, 0, x.XA_ATOM, &actual, &fmt, &n, &after, &data) != x.Success) return null;
    defer if (data != null) {
        _ = x.XFree(data);
    };
    if (n == 0 or data == null) return null;
    const words: [*]const c_long = @ptrCast(@alignCast(data));
    return words[0];
}

// --- tab tear-off between ZFD windows ------------------------------------------
//
// Each standalone window carries a `_ZFD_TABS` marker property. A tab dropped onto a
// marked window is handed over by APPENDING its folder (plus '\n') to that window's
// `_ZFD_ADOPT` property; the change wakes the receiver (GLFW listens for property
// changes on its own window), which takes and deletes the property on its next frame.
// No XDND and no second event loop: just two properties.

fn tabsAtom(dpy: *x.Display) x.Atom {
    return x.XInternAtom(dpy, "_ZFD_TABS", 0);
}
fn adoptAtom(dpy: *x.Display) x.Atom {
    return x.XInternAtom(dpy, "_ZFD_ADOPT", 0);
}

// --- startup notification ----------------------------------------------------
// The freedesktop startup-notification protocol: a launcher broadcasts "new:" with a
// fresh ID stamped with the time of the user's click, and hands the ID to the program
// (DESKTOP_STARTUP_ID). The window manager then lets that program's window take focus,
// since the user asked for it just then. KWin also takes the same ID from a Wayland
// program as its XDG_ACTIVATION_TOKEN (wayland-protocols' X11 interoperation).

var launch_seq: u32 = 0;

/// newStartupId announces a launch and returns its ID (in `buf`), or null without X11.
pub fn newStartupId(glfw: ?*anyopaque, buf: []u8) ?[]const u8 {
    const dpy = display() orelse return null;
    const w = window(glfw);
    if (w == 0) return null;
    const t = serverTime(dpy, w);
    launch_seq += 1;
    const id = std.fmt.bufPrint(buf, "zfd-{d}-{d}_TIME{d}", .{ std.os.linux.getpid(), launch_seq, t }) catch return null;
    var mb: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&mb, "new: ID=\"{s}\" NAME=\"zfd\" SCREEN={d} TIMESTAMP={d}", .{ id, x.XDefaultScreen(dpy), t }) catch return null;
    broadcastStartup(dpy, w, msg);
    return id;
}

/// completeStartup tells the desktop our own launch (`id`, from DESKTOP_STARTUP_ID)
/// is done: the window is up, so its busy cursor and launch feedback can stop.
pub fn completeStartup(glfw: ?*anyopaque, id: []const u8) void {
    const dpy = display() orelse return;
    const w = window(glfw);
    if (w == 0 or id.len == 0 or std.mem.indexOfAny(u8, id, "\"\\") != null) return;
    var mb: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&mb, "remove: ID=\"{s}\"", .{id}) catch return;
    broadcastStartup(dpy, w, msg);
}

/// broadcastStartup sends a startup-notification message to the root window, 20 bytes
/// per ClientMessage (the first _NET_STARTUP_INFO_BEGIN, the rest _NET_STARTUP_INFO),
/// ending with its NUL.
fn broadcastStartup(dpy: *x.Display, w: x.Window, msg: []const u8) void {
    const root = x.XDefaultRootWindow(dpy);
    const a_begin = x.XInternAtom(dpy, "_NET_STARTUP_INFO_BEGIN", 0);
    const a_more = x.XInternAtom(dpy, "_NET_STARTUP_INFO", 0);
    var off: usize = 0;
    while (off <= msg.len) : (off += 20) {
        var ev = std.mem.zeroes(x.XEvent);
        ev.xclient.type = x.ClientMessage;
        ev.xclient.window = w;
        ev.xclient.message_type = if (off == 0) a_begin else a_more;
        ev.xclient.format = 8;
        for (0..20) |k| ev.xclient.data.b[k] = if (off + k < msg.len) @bitCast(msg[off + k]) else 0;
        _ = x.XSendEvent(dpy, root, 0, x.PropertyChangeMask, &ev);
    }
    _ = x.XFlush(dpy);
}

/// serverTime is the X server's time now: touch a property on our window and read the
/// time off the PropertyNotify (GLFW selects those on its windows). Only that one
/// event is taken from the queue.
fn serverTime(dpy: *x.Display, w: x.Window) c_ulong {
    var key = TimeKey{ .w = w, .atom = x.XInternAtom(dpy, "_ZFD_TIMESTAMP", 0) };
    _ = x.XChangeProperty(dpy, w, key.atom, x.XA_STRING, 8, x.PropModeAppend, "", 0);
    var ev: x.XEvent = undefined;
    _ = x.XIfEvent(dpy, &ev, timePred, @ptrCast(&key));
    return ev.xproperty.time;
}

const TimeKey = struct { w: x.Window, atom: x.Atom };

fn timePred(_: ?*x.Display, ev: [*c]x.XEvent, arg: x.XPointer) callconv(.c) c_int {
    const key: *const TimeKey = @ptrCast(@alignCast(arg));
    return @intFromBool(ev.*.type == x.PropertyNotify and ev.*.xproperty.window == key.w and ev.*.xproperty.atom == key.atom);
}

/// markTabWindow flags our window as one that accepts torn-off tabs.
pub fn markTabWindow(glfw: ?*anyopaque) void {
    const dpy = display() orelse return;
    var one: c_long = 1;
    _ = x.XChangeProperty(dpy, window(glfw), tabsAtom(dpy), x.XA_CARDINAL, 32, x.PropModeReplace, @ptrCast(&one), 1);
    _ = x.XFlush(dpy);
}

/// pointerRoot returns the pointer's root-window (screen) position.
pub fn pointerRoot(glfw: ?*anyopaque) ?[2]i32 {
    _ = glfw;
    const dpy = display() orelse return null;
    var rr: x.Window = undefined;
    var ch: x.Window = undefined;
    var rx: c_int = 0;
    var ry: c_int = 0;
    var wx: c_int = 0;
    var wy: c_int = 0;
    var mask: c_uint = 0;
    if (x.XQueryPointer(dpy, x.XDefaultRootWindow(dpy), &rr, &ch, &rx, &ry, &wx, &wy, &mask) == 0) return null;
    return .{ rx, ry };
}

/// zfdWindowUnderPointer returns the OTHER ZFD window under the pointer (the WM frame
/// is descended through), or null.
pub fn zfdWindowUnderPointer(glfw: ?*anyopaque) ?x.Window {
    const dpy = display() orelse return null;
    const self_w = window(glfw);
    const a_tabs = tabsAtom(dpy);
    const trap = ErrorTrap.begin(dpy);
    defer trap.end();
    var w = x.XDefaultRootWindow(dpy);
    var depth: usize = 0;
    while (depth < 32) : (depth += 1) {
        var rr: x.Window = undefined;
        var child: x.Window = undefined;
        var rx: c_int = 0;
        var ry: c_int = 0;
        var wx: c_int = 0;
        var wy: c_int = 0;
        var mask: c_uint = 0;
        if (x.XQueryPointer(dpy, w, &rr, &child, &rx, &ry, &wx, &wy, &mask) == 0) return null;
        if (child == x.None) return null;
        w = child;
        if (hasProp(dpy, w, a_tabs)) return if (w == self_w) null else w;
    }
    return null;
}

fn hasProp(dpy: *x.Display, w: x.Window, prop: x.Atom) bool {
    var actual: x.Atom = undefined;
    var fmt: c_int = 0;
    var n: c_ulong = 0;
    var after: c_ulong = 0;
    var data: [*c]u8 = null;
    if (x.XGetWindowProperty(dpy, w, prop, 0, 1, 0, x.AnyPropertyType, &actual, &fmt, &n, &after, &data) != x.Success) return false;
    if (data != null) _ = x.XFree(data);
    return actual != x.None;
}

/// sendTab hands folder `dir` to the ZFD window `target` as a new tab.
pub fn sendTab(target: x.Window, dir: []const u8) void {
    const dpy = display() orelse return;
    const a = adoptAtom(dpy);
    const utf8 = x.XInternAtom(dpy, "UTF8_STRING", 0);
    const trap = ErrorTrap.begin(dpy);
    defer trap.end();
    _ = x.XChangeProperty(dpy, target, a, utf8, 8, x.PropModeAppend, dir.ptr, @intCast(dir.len));
    _ = x.XChangeProperty(dpy, target, a, utf8, 8, x.PropModeAppend, "\n", 1);
    _ = x.XFlush(dpy);
}

/// takeTabs reads-and-deletes the folders other windows handed us (newline-separated),
/// or null when there are none. Caller frees.
pub fn takeTabs(glfw: ?*anyopaque, alloc: std.mem.Allocator) ?[]u8 {
    const dpy = display() orelse return null;
    var actual: x.Atom = undefined;
    var fmt: c_int = 0;
    var n: c_ulong = 0;
    var after: c_ulong = 0;
    var data: [*c]u8 = null;
    if (x.XGetWindowProperty(dpy, window(glfw), adoptAtom(dpy), 0, 1 << 16, 1, x.AnyPropertyType, &actual, &fmt, &n, &after, &data) != x.Success) return null;
    defer if (data != null) {
        _ = x.XFree(data);
    };
    if (actual == x.None or fmt != 8 or n == 0 or data == null) return null;
    return alloc.dupe(u8, data[0..@intCast(n)]) catch null;
}

fn mergeAtom(dpy: *x.Display) x.Atom {
    return x.XInternAtom(dpy, "_ZFD_MERGE", 0);
}

/// requestMerge asks every other ZFD window to hand its tabs to ours and close
/// (Window > Merge All Windows). Each one reads the request with takeMerge. Returns
/// how many were asked.
pub fn requestMerge(glfw: ?*anyopaque) usize {
    const dpy = display() orelse return 0;
    const self_w = window(glfw);
    const trap = ErrorTrap.begin(dpy);
    defer trap.end();
    var found: [64]x.Window = undefined;
    const n = findMarked(dpy, x.XDefaultRootWindow(dpy), tabsAtom(dpy), 0, &found, 0);
    var asked: usize = 0;
    for (found[0..n]) |w| {
        if (w == self_w) continue;
        var target: c_long = @intCast(self_w);
        _ = x.XChangeProperty(dpy, w, mergeAtom(dpy), x.XA_WINDOW, 32, x.PropModeReplace, @ptrCast(&target), 1);
        asked += 1;
    }
    _ = x.XFlush(dpy);
    return asked;
}

/// findMarked collects the windows below `w` that carry `prop` (a ZFD window sits
/// under the root or one window-manager frame deep), appending from out[n..].
fn findMarked(dpy: *x.Display, w: x.Window, prop: x.Atom, depth: usize, out: *[64]x.Window, n: usize) usize {
    var count = n;
    var rr: x.Window = undefined;
    var parent: x.Window = undefined;
    var kids: [*c]x.Window = null;
    var nk: c_uint = 0;
    if (x.XQueryTree(dpy, w, &rr, &parent, &kids, &nk) == 0) return count;
    defer if (kids != null) {
        _ = x.XFree(kids);
    };
    for (0..nk) |i| {
        if (count == out.len) break;
        const k = kids[i];
        if (hasProp(dpy, k, prop)) {
            out[count] = k;
            count += 1;
        } else if (depth < 2) {
            count = findMarked(dpy, k, prop, depth + 1, out, count);
        }
    }
    return count;
}

/// takeMerge reads-and-deletes a merge request: the window our tabs should go to.
pub fn takeMerge(glfw: ?*anyopaque) ?x.Window {
    const dpy = display() orelse return null;
    var actual: x.Atom = undefined;
    var fmt: c_int = 0;
    var n: c_ulong = 0;
    var after: c_ulong = 0;
    var data: [*c]u8 = null;
    if (x.XGetWindowProperty(dpy, window(glfw), mergeAtom(dpy), 0, 1, 1, x.XA_WINDOW, &actual, &fmt, &n, &after, &data) != x.Success) return null;
    defer if (data != null) {
        _ = x.XFree(data);
    };
    if (actual == x.None or fmt != 32 or n == 0 or data == null) return null;
    const v: *const c_long = @ptrCast(@alignCast(data));
    return @intCast(v.*);
}

/// ChildFocus is how a window ImGui opened outside the main one may take focus.
pub const ChildFocus = enum {
    normal, // a dragged-out panel that can be focused like any window
    not_on_map, // focusable, but not activated when it appears
    popup, // a menu or popup: never focused (its keys come through the main window)
    tooltip, // a tooltip: never focused
};

/// makeChildWindow marks `child` (an unmapped GLFW window ImGui opened outside the main
/// one) as belonging to `parent`: a panel is transient for it, so the window manager keeps it
/// above, minimizes and restores it with the main window, and no taskbar, pager or
/// Alt+Tab entry of its own. A window that mustn't take focus says so before it's
/// mapped: the WM activating it would raise `parent` along with it.
pub fn makeChildWindow(child: ?*anyopaque, parent: ?*anyopaque, focus: ChildFocus) void {
    const dpy = display() orelse return;
    const w = window(child);
    // No background for the X server to paint: on each resize step it filled what
    // the window grew by with it before ZFD drew there, which blinked.
    _ = x.XSetWindowBackgroundPixmap(dpy, w, x.None);
    if (focus == .popup or focus == .tooltip) {
        // Override-redirect, like any toolkit's tooltips and menus: the window manager
        // leaves it alone entirely. Managed, it was stacked with the window it belongs
        // to, and KWin raised that one each time a tooltip appeared, so pointing at a
        // ZFD window behind another brought it forward. It shows above everything,
        // and ImGui places it itself.
        var attrs: x.XSetWindowAttributes = std.mem.zeroes(x.XSetWindowAttributes);
        attrs.override_redirect = 1;
        _ = x.XChangeWindowAttributes(dpy, w, x.CWOverrideRedirect, &attrs);
    } else if (parent != null) _ = x.XSetTransientForHint(dpy, w, window(parent));
    if (focus != .normal) {
        // EWMH: a user time of 0 means "don't activate this window when it's mapped".
        const zero: c_long = 0;
        _ = x.XChangeProperty(dpy, w, x.XInternAtom(dpy, "_NET_WM_USER_TIME", 0), x.XA_CARDINAL, 32, x.PropModeReplace, @ptrCast(&zero), 1);
    }
    if (focus == .popup or focus == .tooltip) {
        // ICCCM: it never takes keyboard focus. And its type, which a WM never
        // activates (KWin keeps them above their window, too).
        if (x.XAllocWMHints()) |hints| {
            hints.*.flags = x.InputHint;
            hints.*.input = 0;
            _ = x.XSetWMHints(dpy, w, hints);
            _ = x.XFree(hints);
        }
        const tname = if (focus == .tooltip) "_NET_WM_WINDOW_TYPE_TOOLTIP" else "_NET_WM_WINDOW_TYPE_POPUP_MENU";
        var wtype: c_long = @intCast(x.XInternAtom(dpy, tname, 0));
        _ = x.XChangeProperty(dpy, w, x.XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", 0), x.XA_ATOM, 32, x.PropModeReplace, @ptrCast(&wtype), 1);
    } else {
        // A panel dragged out of the main window (Quick Look, Progress): a utility
        // window, a palette of the main one. Window managers animate a normal window
        // appearing and going (KWin scales it), and one of these comes and goes each
        // time it crosses the main window's edge, so it seemed to shrink and grow.
        var wtype: c_long = @intCast(x.XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_UTILITY", 0));
        _ = x.XChangeProperty(dpy, w, x.XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", 0), x.XA_ATOM, 32, x.PropModeReplace, @ptrCast(&wtype), 1);
    }
    var states = [_]c_long{
        @intCast(x.XInternAtom(dpy, "_NET_WM_STATE_SKIP_TASKBAR", 0)),
        @intCast(x.XInternAtom(dpy, "_NET_WM_STATE_SKIP_PAGER", 0)),
        @intCast(x.XInternAtom(dpy, "_KDE_NET_WM_STATE_SKIP_SWITCHER", 0)),
    };
    _ = x.XChangeProperty(dpy, w, x.XInternAtom(dpy, "_NET_WM_STATE", 0), x.XA_ATOM, 32, x.PropModeReplace, @ptrCast(&states), states.len);
    _ = x.XFlush(dpy);
}

/// setDialogParent marks our (still unmapped) window as a dialog that stays above the
/// app that asked for it: transient-for + modal over `parent_xid` when we have one,
/// else keep-above, since there's no window to tie it to. Either way it stays out of
/// the taskbar, pager and Alt+Tab: it belongs to the parent app, which the switcher
/// still shows; activating that brings the dialog up with it. Call before mapping:
/// the WM only reads the initial _NET_WM_STATE at map time.
pub fn setDialogParent(glfw: ?*anyopaque, parent_xid: ?c_ulong) void {
    const dpy = display() orelse return;
    const w = window(glfw);
    const wtype = x.XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", 0);
    var dialog: c_long = @intCast(x.XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DIALOG", 0));
    _ = x.XChangeProperty(dpy, w, wtype, x.XA_ATOM, 32, x.PropModeReplace, @ptrCast(&dialog), 1);

    var states: [4]c_long = undefined;
    if (parent_xid) |p| {
        _ = x.XSetTransientForHint(dpy, w, p);
        states[0] = @intCast(x.XInternAtom(dpy, "_NET_WM_STATE_MODAL", 0));
    } else {
        states[0] = @intCast(x.XInternAtom(dpy, "_NET_WM_STATE_ABOVE", 0));
    }
    states[1] = @intCast(x.XInternAtom(dpy, "_NET_WM_STATE_SKIP_TASKBAR", 0));
    states[2] = @intCast(x.XInternAtom(dpy, "_NET_WM_STATE_SKIP_PAGER", 0));
    states[3] = @intCast(x.XInternAtom(dpy, "_KDE_NET_WM_STATE_SKIP_SWITCHER", 0)); // KWin's Alt+Tab
    _ = x.XChangeProperty(dpy, w, x.XInternAtom(dpy, "_NET_WM_STATE", 0), x.XA_ATOM, 32, x.PropModeReplace, @ptrCast(&states), states.len);
    _ = x.XFlush(dpy);
}

// --- resize in step with the WM (_NET_WM_SYNC_REQUEST) ----------------------
// A compositing WM (KWin, Mutter) paces an interactive resize to the client's drawing
// when the client advertises _NET_WM_SYNC_REQUEST and a sync counter: before each
// resize step it sends a request carrying a value, and waits until the client, having
// drawn a frame at the new size, sets its counter to it. Without that the WM resizes
// as fast as the pointer moves and the content trails behind (the "slow" resize). GLFW
// doesn't take part, and drops client messages it doesn't know (even while it waits
// for events), so the request is caught where Xlib decodes events (XESetWireToEvent),
// whoever is reading the queue.

const WireProc = ?*const fn (?*x.Display, ?*x.XEvent, ?*anyopaque) callconv(.c) c_int;
extern fn XESetWireToEvent(dpy: *x.Display, event_number: c_int, proc: WireProc) WireProc;

var sync_counter: x.XSyncCounter = 0;
var sync_window: x.Window = 0;
var sync_atom: x.Atom = 0;
var protocols_atom: x.Atom = 0;
var prev_wire: WireProc = null;
var prev_wire_configure: WireProc = null;
var sync_owed: ?x.XSyncValue = null; // the value to set once a frame at the new size is drawn
var sync_configured = false; // the resize the request announced has arrived
var sync_frames: u8 = 0; // frames drawn since the request (a request needn't bring a resize)

/// enableResizeSync advertises resize sync for the window. Call before it's mapped:
/// the WM looks for the counter when it takes the window on.
pub fn enableResizeSync(glfw: ?*anyopaque) void {
    const dpy = display() orelse return;
    const w = window(glfw);
    var ev_base: c_int = 0;
    var err_base: c_int = 0;
    var major: c_int = 0;
    var minor: c_int = 0;
    if (x.XSyncQueryExtension(dpy, &ev_base, &err_base) == 0 or x.XSyncInitialize(dpy, &major, &minor) == 0) return;
    var zero: x.XSyncValue = undefined;
    x.XSyncIntsToValue(&zero, 0, 0);
    sync_counter = x.XSyncCreateCounter(dpy, zero);
    sync_window = w;
    sync_atom = x.XInternAtom(dpy, "_NET_WM_SYNC_REQUEST", 0);
    protocols_atom = x.XInternAtom(dpy, "WM_PROTOCOLS", 0);
    var counter: c_long = @intCast(sync_counter);
    _ = x.XChangeProperty(dpy, w, x.XInternAtom(dpy, "_NET_WM_SYNC_REQUEST_COUNTER", 0), x.XA_CARDINAL, 32, x.PropModeReplace, @ptrCast(&counter), 1);
    // Add the protocol to the ones GLFW set (WM_DELETE_WINDOW, _NET_WM_PING).
    var list: [16]x.Atom = undefined;
    var n: usize = 0;
    var have: [*c]x.Atom = null;
    var have_n: c_int = 0;
    if (x.XGetWMProtocols(dpy, w, &have, &have_n) != 0) {
        for (0..@min(@as(usize, @intCast(have_n)), list.len - 1)) |i| {
            list[n] = have[i];
            n += 1;
        }
        _ = x.XFree(have);
    }
    list[n] = sync_atom;
    n += 1;
    _ = x.XSetWMProtocols(dpy, w, &list, @intCast(n));
    prev_wire = XESetWireToEvent(dpy, x.ClientMessage, onWireClientMessage);
    prev_wire_configure = XESetWireToEvent(dpy, x.ConfigureNotify, onWireConfigure);
    // No server-painted background: on a resize the new area waits for our frame
    // instead of flashing black first.
    _ = x.XSetWindowBackgroundPixmap(dpy, w, x.None);
    _ = x.XFlush(dpy);
}

/// onWireClientMessage decodes a ClientMessage as Xlib would, noting a sync request.
fn onWireClientMessage(dpy: ?*x.Display, re: ?*x.XEvent, wire: ?*anyopaque) callconv(.c) c_int {
    const keep = if (prev_wire) |p| p(dpy, re, wire) else 0;
    const e = re orelse return keep;
    const cm = e.xclient;
    if (keep != 0 and cm.window == sync_window and cm.message_type == protocols_atom and
        @as(x.Atom, @intCast(cm.data.l[0])) == sync_atom)
    {
        var v: x.XSyncValue = undefined;
        x.XSyncIntsToValue(&v, @truncate(@as(c_ulong, @bitCast(cm.data.l[2]))), @truncate(cm.data.l[3]));
        sync_owed = v;
        sync_configured = false;
        sync_frames = 0;
    }
    return keep;
}

/// onWireConfigure notes the resize that follows a sync request.
fn onWireConfigure(dpy: ?*x.Display, re: ?*x.XEvent, wire: ?*anyopaque) callconv(.c) c_int {
    const keep = if (prev_wire_configure) |p| p(dpy, re, wire) else 0;
    if (keep != 0 and sync_owed != null) if (re) |e| {
        if (e.xconfigure.window == sync_window) sync_configured = true;
    };
    return keep;
}

/// ackResizeSync tells the WM that the frame for its last resize step is on screen
/// (call after swapping buffers). Only once that frame was drawn at the new size
/// (after the resize arrived) or, for a request that brought none, a few frames on.
pub fn ackResizeSync() void {
    const v = sync_owed orelse return;
    sync_frames +|= 1;
    if (!sync_configured and sync_frames < 4) return;
    const dpy = display() orelse return;
    sync_owed = null;
    _ = x.XSyncSetCounter(dpy, sync_counter, v);
    _ = x.XFlush(dpy);
}

/// resizeSyncPending: the WM is waiting on a frame (keep drawing).
pub fn resizeSyncPending() bool {
    return sync_owed != null;
}
