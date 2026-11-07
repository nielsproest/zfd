//! Devices: the live list of block volumes (blockdev.zig) plus mount / unmount / eject,
//! all off the render thread. One worker thread:
//!   • re-lists volumes (lsblk) whenever /proc/partitions or the mount table changes:
//!     hotplug and mounts made elsewhere show up within about a second, and an idle
//!     system costs one small file read per second, never a process spawn;
//!   • runs queued actions through `udisksctl`, which talks to udisks over D-Bus and
//!     lets polkit decide (removable media mount without a password; an internal disk
//!     raises the desktop's auth prompt). No root, no D-Bus linking here.
//!   • while the Network page is open (`browseNetwork`), looks for servers on the
//!     local network every 15 seconds (avahi-browse; netbrowse.zig).
//! The UI reads snapshots (`snapshot`) and results (`takeEvent`). GUI-free.
//!
//! Heap-pinned (the worker holds `self`): create with `create`, free with `destroy`.

const std = @import("std");
const blockdev = @import("blockdev.zig");
const fstab = @import("fstab.zig");
const rclone = @import("rclone.zig");
const netbrowse = @import("netbrowse.zig");
const readProcFile = @import("mounts.zig").readProcFile;

pub const Volume = blockdev.Volume;

pub const Event = union(enum) {
    /// A mount finished. `open`: the user clicked an unmounted volume and expects to
    /// land in it; otherwise (menu "Mount") just refresh.
    mounted: struct { path: []u8, mountpoint: []u8, open: bool },
    unmounted: struct { mountpoint: []u8 }, // tabs inside it should leave
    failed: struct { msg: []u8 }, // udisksctl's own error text, first line

    pub fn deinit(e: Event, alloc: std.mem.Allocator) void {
        switch (e) {
            .mounted => |m| {
                alloc.free(m.path);
                alloc.free(m.mountpoint);
            },
            .unmounted => |u| alloc.free(u.mountpoint),
            .failed => |f| alloc.free(f.msg),
        }
    }
};

const Request = union(enum) {
    mount: struct { path: []u8, open: bool },
    unmount: struct { path: []u8, mountpoint: []u8, lock: []u8 }, // lock: LUKS container to re-lock ("" = none)
    eject: struct { drive: []u8 }, // unmount + lock everything on the drive, then power it off
    mount_target: struct { target: []u8, user_ok: bool, open: bool }, // an fstab entry, by mount point
    rclone_mount: struct { name: []u8, open: bool }, // mount an rclone remote under net_base
    rclone_unmount: struct { mountpoint: []u8 },
    rclone_remove: struct { name: []u8, mountpoint: []u8 }, // disconnect (mountpoint "" = isn't) and forget a remote
    unlock: struct { path: []u8, pass: []u8, open: bool }, // LUKS container + passphrase

    fn deinit(r: Request, alloc: std.mem.Allocator) void {
        switch (r) {
            .mount => |m| alloc.free(m.path),
            .unmount => |u| {
                alloc.free(u.path);
                alloc.free(u.mountpoint);
                alloc.free(u.lock);
            },
            .eject => |e| alloc.free(e.drive),
            .mount_target => |m| alloc.free(m.target),
            .rclone_mount => |m| alloc.free(m.name),
            .rclone_unmount => |u| alloc.free(u.mountpoint),
            .rclone_remove => |u| {
                alloc.free(u.name);
                alloc.free(u.mountpoint);
            },
            .unlock => |u| {
                alloc.free(u.path);
                std.crypto.secureZero(u8, u.pass); // don't leave the passphrase in freed memory
                alloc.free(u.pass);
            },
        }
    }
};

pub const Devices = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    // --- guarded by mutex ---
    vols: []Volume = &.{},
    fstab_entries: []fstab.Entry = &.{}, // fstab mounts not mounted right now
    remotes: []rclone.Remote = &.{}, // configured rclone remotes
    remote_mounted: []bool = &.{}, // parallel to remotes: mounted under net_base now
    net_base: []u8 = &.{}, // where remotes are mounted (owned; set via setNetBase)
    rclone_conf: ?[]u8 = null, // rclone's config file (worker only; watched for changes)
    no_rclone: bool = false, // rclone isn't installed (worker only)
    want_network: bool = false, // the Network page is showing: look for servers
    servers: []netbrowse.Server = &.{}, // what the last look found
    network_state: NetworkState = .idle,
    gen: u64 = 0, // bumped whenever vols changes
    busy: ?[]u8 = null, // device path an action is running on (owned), for a spinner
    requests: std.ArrayList(Request) = .empty,
    events: std.ArrayList(Event) = .empty,
    shutdown: bool = false,
    // -------------------------
    child_pid: std.atomic.Value(i32) = .init(0), // running udisksctl, killed on shutdown
    worker: ?std.Thread = null,
    /// Called from the worker after it publishes something, so an idle UI loop wakes
    /// up (the shell passes glfwPostEmptyEvent, which is thread-safe). Optional.
    wake: ?*const fn () void = null,

    pub fn create(io: std.Io, alloc: std.mem.Allocator, wake: ?*const fn () void) !*Devices {
        const self = try alloc.create(Devices);
        self.* = .{ .io = io, .alloc = alloc, .wake = wake };
        self.worker = std.Thread.spawn(.{}, workerLoop, .{self}) catch |e| {
            alloc.destroy(self);
            return e;
        };
        return self;
    }

    pub const NetworkState = enum { idle, looking, ready, no_avahi };

    pub fn destroy(self: *Devices) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.mutex.unlock(self.io);
        // A udisksctl may be sitting on a polkit password prompt: don't let that hold
        // the app's exit hostage.
        const pid = self.child_pid.load(.acquire);
        if (pid > 0) _ = std.os.linux.kill(pid, .TERM);
        if (self.worker) |w| w.join();
        blockdev.free(self.alloc, self.vols);
        fstab.free(self.alloc, self.fstab_entries);
        rclone.freeRemotes(self.alloc, self.remotes);
        netbrowse.freeSlice(self.alloc, self.servers);
        if (self.remote_mounted.len > 0) self.alloc.free(self.remote_mounted);
        if (self.net_base.len > 0) self.alloc.free(self.net_base);
        if (self.rclone_conf) |p| self.alloc.free(p);
        if (self.busy) |b| self.alloc.free(b);
        for (self.requests.items) |r| r.deinit(self.alloc);
        self.requests.deinit(self.alloc);
        for (self.events.items) |e| e.deinit(self.alloc);
        self.events.deinit(self.alloc);
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    // ---- UI side --------------------------------------------------------------

    /// generation changes whenever the volume list does; compare to know when to
    /// re-take a snapshot.
    pub fn generation(self: *Devices) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.gen;
    }

    /// snapshot returns an owned copy of the current volumes (free with blockdev.free).
    pub fn snapshot(self: *Devices, alloc: std.mem.Allocator) []Volume {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return dupVolumes(alloc, self.vols) catch &.{};
    }

    /// fstabSnapshot returns an owned copy of the unmounted fstab entries (free with
    /// fstab.free).
    pub fn fstabSnapshot(self: *Devices, alloc: std.mem.Allocator) []fstab.Entry {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return fstab.dup(alloc, self.fstab_entries) catch &.{};
    }

    /// mountTarget mounts the fstab entry for mount point `target`: plain `mount` when
    /// the entry lets users mount it, else through pkexec (the desktop's password
    /// prompt). The result arrives as a .mounted event that opens the folder.
    pub fn mountTarget(self: *Devices, target: []const u8, user_ok: bool, open: bool) void {
        const t = self.alloc.dupe(u8, target) catch return;
        self.push(.{ .mount_target = .{ .target = t, .user_ok = user_ok, .open = open } });
    }

    /// setNetBase sets the folder rclone remotes are mounted under (call once, early).
    pub fn setNetBase(self: *Devices, base: []const u8) void {
        const dup = self.alloc.dupe(u8, base) catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.net_base.len > 0) self.alloc.free(self.net_base);
        self.net_base = dup;
    }

    /// browseNetwork starts (or stops) looking for servers on the local network; the
    /// Network page keeps it on while it shows.
    pub fn browseNetwork(self: *Devices, on: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.want_network = on;
    }

    /// serversSnapshot copies what the last look found (free with netbrowse.freeSlice),
    /// and how the looking goes.
    pub fn serversSnapshot(self: *Devices, alloc: std.mem.Allocator) struct { servers: []netbrowse.Server, state: NetworkState } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const out = alloc.alloc(netbrowse.Server, self.servers.len) catch return .{ .servers = &.{}, .state = self.network_state };
        var n: usize = 0;
        for (self.servers) |sv| {
            const name = alloc.dupe(u8, sv.name) catch break;
            const host = alloc.dupe(u8, sv.host) catch {
                alloc.free(name);
                break;
            };
            out[n] = .{ .name = name, .kind = sv.kind, .host = host, .port = sv.port, .secure = sv.secure };
            n += 1;
        }
        return .{ .servers = out[0..n], .state = self.network_state };
    }

    /// RemoteView is one rclone remote for the sidebar (owned copy; see remotesSnapshot).
    pub const RemoteView = struct { name: []u8, kind: []u8, mounted: bool, mountpoint: []u8 };

    /// remotesSnapshot copies the remotes with their mount state (free with freeRemoteViews).
    pub fn remotesSnapshot(self: *Devices, alloc: std.mem.Allocator) []RemoteView {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const out = alloc.alloc(RemoteView, self.remotes.len) catch return &.{};
        var n: usize = 0;
        for (self.remotes, 0..) |r, i| {
            const mp = rclone.mountpoint(alloc, self.net_base, r.name) catch break;
            const name = alloc.dupe(u8, r.name) catch {
                alloc.free(mp);
                break;
            };
            const kind = alloc.dupe(u8, r.kind) catch {
                alloc.free(mp);
                alloc.free(name);
                break;
            };
            out[n] = .{ .name = name, .kind = kind, .mounted = i < self.remote_mounted.len and self.remote_mounted[i], .mountpoint = mp };
            n += 1;
        }
        return out[0..n];
    }

    pub fn freeRemoteViews(alloc: std.mem.Allocator, rs: []RemoteView) void {
        for (rs) |r| {
            alloc.free(r.name);
            alloc.free(r.kind);
            alloc.free(r.mountpoint);
        }
        if (rs.len > 0) alloc.free(rs.ptr[0..rs.len]);
    }

    /// mountRemote mounts rclone remote `name` (then opens it when `open`).
    pub fn mountRemote(self: *Devices, name: []const u8, open: bool) void {
        const n = self.alloc.dupe(u8, name) catch return;
        self.push(.{ .rclone_mount = .{ .name = n, .open = open } });
    }

    pub fn unmountRemote(self: *Devices, mp: []const u8) void {
        const m = self.alloc.dupe(u8, mp) catch return;
        self.push(.{ .rclone_unmount = .{ .mountpoint = m } });
    }

    /// removeRemote disconnects rclone remote `name` (mounted at `mountpoint`, "" if it
    /// isn't) and deletes it from rclone's config. The files on the server stay.
    pub fn removeRemote(self: *Devices, name: []const u8, mountpoint: []const u8) void {
        const n = self.alloc.dupe(u8, name) catch return;
        const m = self.alloc.dupe(u8, mountpoint) catch return self.alloc.free(n);
        self.push(.{ .rclone_remove = .{ .name = n, .mountpoint = m } });
    }

    /// isBusy reports whether an action is running on `path`.
    pub fn isBusy(self: *Devices, path: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const b = self.busy orelse return false;
        return std.mem.eql(u8, b, path);
    }

    /// takeEvent pops the oldest finished action (caller deinits it), or null.
    pub fn takeEvent(self: *Devices) ?Event {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    pub fn mount(self: *Devices, path: []const u8, open: bool) void {
        const p = self.alloc.dupe(u8, path) catch return;
        self.push(.{ .mount = .{ .path = p, .open = open } });
    }

    /// unmount unmounts `path`; `lock` names its LUKS container to lock afterwards
    /// ("" for an ordinary volume), so an unlocked drive doesn't stay open.
    pub fn unmount(self: *Devices, path: []const u8, mountpoint: []const u8, lock: []const u8) void {
        const p = self.alloc.dupe(u8, path) catch return;
        const m = self.alloc.dupe(u8, mountpoint) catch {
            self.alloc.free(p);
            return;
        };
        const l = self.alloc.dupe(u8, lock) catch {
            self.alloc.free(p);
            self.alloc.free(m);
            return;
        };
        self.push(.{ .unmount = .{ .path = p, .mountpoint = m, .lock = l } });
    }

    /// unlock opens a LUKS container with `pass` and mounts what's inside (opening it
    /// in the view when `open`). The passphrase is copied; the caller should wipe its own.
    pub fn unlock(self: *Devices, path: []const u8, pass: []const u8, open: bool) void {
        const p = self.alloc.dupe(u8, path) catch return;
        const k = self.alloc.dupe(u8, pass) catch {
            self.alloc.free(p);
            return;
        };
        self.push(.{ .unlock = .{ .path = p, .pass = k, .open = open } });
    }

    pub fn eject(self: *Devices, drive: []const u8) void {
        const d = self.alloc.dupe(u8, drive) catch return;
        self.push(.{ .eject = .{ .drive = d } });
    }

    fn push(self: *Devices, r: Request) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.requests.append(self.alloc, r) catch r.deinit(self.alloc);
    }

    // ---- worker ---------------------------------------------------------------

    fn workerLoop(self: *Devices) void {
        var last_sig: u64 = 0;
        var tick: u32 = 0;
        var net_tick: ?u32 = null; // when the network was last looked at
        while (true) {
            // Take one request, if any.
            self.mutex.lockUncancelable(self.io);
            if (self.shutdown) {
                self.mutex.unlock(self.io);
                return;
            }
            const req: ?Request = if (self.requests.items.len > 0) self.requests.orderedRemove(0) else null;
            self.mutex.unlock(self.io);

            if (req) |r| {
                defer r.deinit(self.alloc);
                self.runRequest(r);
                last_sig = 0; // force a re-list: the action changed mounts
            }

            // Re-list when the system's view of disks or mounts changed. Checked every
            // ~1s (4 × 250ms naps), and right away after an action.
            if (tick % 4 == 0 or req != null) {
                const sig = systemSignature(self.io, self.alloc, self.rclone_conf orelse "");
                if (sig != last_sig) {
                    last_sig = sig;
                    self.relist();
                }
            }
            // The network, while its page shows: at once, then every ~15s.
            self.mutex.lockUncancelable(self.io);
            const want_net = self.want_network and self.network_state != .no_avahi;
            self.mutex.unlock(self.io);
            if (!want_net) {
                net_tick = null;
            } else if (net_tick == null or tick -% net_tick.? >= 60) {
                net_tick = tick;
                self.lookForServers();
            }
            tick +%= 1;
            if (req == null) napMs(250);
        }
    }

    fn relist(self: *Devices) void {
        // Volumes and unmounted fstab entries are published together, in one
        // generation: the UI's first snapshot is its "already there" baseline for
        // new-device notices, so it must never see one list without the other.
        const fs = fstab.read(self.io, self.alloc);
        var vols: ?[]Volume = null;
        if (self.run(&blockdev.lsblk_argv)) |out| {
            defer self.alloc.free(out.text);
            if (out.code == 0) vols = blockdev.parse(self.alloc, out.text) catch null;
        }
        self.mutex.lockUncancelable(self.io);
        const old_fs = self.fstab_entries;
        self.fstab_entries = fs;
        const old_vols: ?[]Volume = if (vols) |v| blk: {
            const o = self.vols;
            self.vols = v;
            break :blk o;
        } else null;
        self.gen +%= 1;
        self.mutex.unlock(self.io);
        fstab.free(self.alloc, old_fs);
        if (old_vols) |o| blockdev.free(self.alloc, o);
        self.listRemotes();
        if (self.wake) |w| w();
    }

    fn runRequest(self: *Devices, r: Request) void {
        switch (r) {
            .mount => |m| {
                self.setBusy(m.path);
                defer self.setBusy(null);
                const out = self.run(&.{ "udisksctl", "mount", "-b", m.path }) orelse
                    return self.fail("Could not run udisksctl (is udisks2 installed?)");
                defer self.alloc.free(out.text);
                if (out.code != 0) return self.fail(out.text);
                const mp = blockdev.parseMountedAt(out.text) orelse return self.fail(out.text);
                const p = self.alloc.dupe(u8, m.path) catch return;
                const mpd = self.alloc.dupe(u8, mp) catch {
                    self.alloc.free(p);
                    return;
                };
                self.emit(.{ .mounted = .{ .path = p, .mountpoint = mpd, .open = m.open } });
            },
            .unmount => |u| {
                self.setBusy(u.path);
                defer self.setBusy(null);
                if (!self.unmountOne(u.path)) return;
                const mp = self.alloc.dupe(u8, u.mountpoint) catch return;
                self.emit(.{ .unmounted = .{ .mountpoint = mp } });
                if (u.lock.len > 0) self.lockOne(u.lock);
            },
            .unlock => |u| {
                self.setBusy(u.path);
                defer self.setBusy(null);
                const out = self.runInput(&.{ "udisksctl", "unlock", "-b", u.path, "--key-file", "/dev/stdin" }, u.pass) orelse
                    return self.fail("Could not run udisksctl (is udisks2 installed?)");
                defer self.alloc.free(out.text);
                if (out.code != 0) return self.fail(out.text);
                const clear = blockdev.parseUnlockedAs(out.text) orelse return self.fail(out.text);
                const mo = self.run(&.{ "udisksctl", "mount", "-b", clear }) orelse return;
                defer self.alloc.free(mo.text);
                if (mo.code != 0) return self.fail(mo.text);
                const mp = blockdev.parseMountedAt(mo.text) orelse return self.fail(mo.text);
                const p = self.alloc.dupe(u8, clear) catch return;
                const mpd = self.alloc.dupe(u8, mp) catch {
                    self.alloc.free(p);
                    return;
                };
                self.emit(.{ .mounted = .{ .path = p, .mountpoint = mpd, .open = u.open } });
            },
            .rclone_mount => |m| self.mountRemoteNow(m.name, m.open),
            .rclone_unmount => |u| {
                self.setBusy(u.mountpoint);
                defer self.setBusy(null);
                const out = self.run(&.{ "fusermount3", "-u", u.mountpoint }) orelse self.run(&.{ "fusermount", "-u", u.mountpoint }) orelse
                    return self.fail("Could not run fusermount");
                defer self.alloc.free(out.text);
                if (out.code != 0) return self.fail(out.text);
                const mp = self.alloc.dupe(u8, u.mountpoint) catch return;
                self.emit(.{ .unmounted = .{ .mountpoint = mp } });
            },
            .rclone_remove => |u| {
                self.setBusy(u.name);
                defer self.setBusy(null);
                if (u.mountpoint.len > 0) {
                    const out = self.run(&.{ "fusermount3", "-u", u.mountpoint }) orelse self.run(&.{ "fusermount", "-u", u.mountpoint }) orelse
                        return self.fail("Could not run fusermount");
                    defer self.alloc.free(out.text);
                    if (out.code != 0) return self.fail(out.text);
                    const mp = self.alloc.dupe(u8, u.mountpoint) catch return;
                    self.emit(.{ .unmounted = .{ .mountpoint = mp } });
                }
                const out = self.run(&.{ "rclone", "config", "delete", u.name }) orelse return self.fail("Could not run rclone");
                defer self.alloc.free(out.text);
                if (out.code != 0) return self.fail(out.text);
            },
            .mount_target => |m| {
                self.setBusy(m.target);
                defer self.setBusy(null);
                const user_argv = [_][]const u8{ "mount", m.target };
                const root_argv = [_][]const u8{ "pkexec", "mount", m.target };
                const out = self.run(if (m.user_ok) &user_argv else &root_argv) orelse
                    return self.fail(if (m.user_ok) "Could not run mount" else "Could not run pkexec (is polkit installed?)");
                defer self.alloc.free(out.text);
                if (out.code != 0) return self.fail(if (out.text.len > 0) out.text else "Mount failed (or the password prompt was canceled)");
                const p = self.alloc.dupe(u8, m.target) catch return;
                const mpd = self.alloc.dupe(u8, m.target) catch {
                    self.alloc.free(p);
                    return;
                };
                self.emit(.{ .mounted = .{ .path = p, .mountpoint = mpd, .open = m.open } });
            },
            .eject => |e| {
                self.setBusy(e.drive);
                defer self.setBusy(null);
                // Unmount every mounted volume on the drive first; power-off refuses
                // while anything is still mounted.
                const vols = self.snapshot(self.alloc);
                defer blockdev.free(self.alloc, vols);
                for (vols) |v| {
                    if (!std.mem.eql(u8, v.drive, e.drive) or !v.mounted()) continue;
                    if (!self.unmountOne(v.path)) return;
                    const mp = self.alloc.dupe(u8, v.mountpoint) catch continue;
                    self.emit(.{ .unmounted = .{ .mountpoint = mp } });
                }
                // Close any unlocked encryption on it too; power-off refuses otherwise.
                for (vols) |v| {
                    if (std.mem.eql(u8, v.drive, e.drive) and v.crypt_parent.len > 0) self.lockOne(v.crypt_parent);
                }
                const out = self.run(&.{ "udisksctl", "power-off", "-b", e.drive }) orelse
                    return self.fail("Could not run udisksctl (is udisks2 installed?)");
                defer self.alloc.free(out.text);
                // Not every drive can be powered off (SD readers, some enclosures). The
                // volumes are already unmounted, so it is safe to pull; say nothing.
            },
        }
    }

    fn mountRemoteNow(self: *Devices, name: []const u8, open: bool) void {
        self.setBusy(name);
        defer self.setBusy(null);
        // One just set up isn't listed yet: list it now, so it's in the sidebar (busy)
        // while it connects, not only once that's done.
        if (!self.knowsRemote(name)) {
            self.listRemotes();
            if (self.wake) |w| w();
        }
        self.mutex.lockUncancelable(self.io);
        const mp = rclone.mountpoint(self.alloc, self.net_base, name) catch {
            self.mutex.unlock(self.io);
            return;
        };
        self.mutex.unlock(self.io);
        defer self.alloc.free(mp);
        std.Io.Dir.cwd().createDirPath(self.io, mp) catch return self.fail("Could not create the mount folder");
        const spec = self.alloc.print("{s}:", .{name}) catch return;
        defer self.alloc.free(spec);
        // --daemon returns once the mount is up (or failed); writes go through rclone's
        // VFS cache so programs that save in place work too.
        const out = self.run(&.{ "rclone", "mount", spec, mp, "--daemon", "--vfs-cache-mode", "writes", "--volname", name }) orelse
            return self.fail("Could not run rclone (is it installed?)");
        defer self.alloc.free(out.text);
        if (out.code != 0) {
            // Through `ssh <host>`, ssh's own complaint says why (rclone only sees it hang up).
            if (std.mem.indexOf(u8, out.text, "version packet") != null) if (self.sshReason(name)) |why| {
                defer self.alloc.free(why);
                return self.failText(why);
            };
            return self.failText(if (out.text.len > 0) rclone.errorText(out.text) else "rclone mount failed");
        }
        const p = self.alloc.dupe(u8, name) catch return;
        const mpd = self.alloc.dupe(u8, mp) catch {
            self.alloc.free(p);
            return;
        };
        self.emit(.{ .mounted = .{ .path = p, .mountpoint = mpd, .open = open } });
    }

    /// sshReason finds out why remote `name`'s ssh command hung up (an SFTP server
    /// set up as `ssh <host>`): it's run once more, never asking (BatchMode), and what
    /// ssh says is put plainly, with what to do. Null for other remotes (owned).
    fn sshReason(self: *Devices, name: []const u8) ?[]u8 {
        const shown = self.run(&.{ "rclone", "config", "show", name }) orelse return null;
        defer self.alloc.free(shown.text);
        const cmd = sshCommand(shown.text) orelse return null;
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.alloc);
        var it = std.mem.tokenizeScalar(u8, cmd, ' ');
        const prog = it.next() orelse return null;
        argv.appendSlice(self.alloc, &.{ prog, "-o", "BatchMode=yes", "-o", "ConnectTimeout=15" }) catch return null;
        while (it.next()) |a| argv.append(self.alloc, a) catch return null;
        argv.appendSlice(self.alloc, &.{ "-s", "sftp" }) catch return null;
        const out = self.run(argv.items) orelse return null;
        defer self.alloc.free(out.text);
        // 127 is the server's "no such program", passed back through ssh: logged in,
        // but sshd's sftp subsystem names a program that isn't there.
        if (out.code == 127) return self.alloc.dupe(u8, no_sftp_server) catch null;
        if (out.code != 0 and firstLine(out.text).len == 0) {
            // Failed without a word (LogLevel QUIET, say): once more, verbose, for the
            // last steps it got to.
            argv.insert(self.alloc, 1, "-v") catch return null;
            const v = self.run(argv.items) orelse return null;
            defer self.alloc.free(v.text);
            const advice = sshAdvice(v.code, v.text);
            if (!std.mem.eql(u8, advice, "ssh failed without saying why.") and !std.mem.eql(u8, advice, firstLine(v.text)))
                return std.mem.replaceOwned(u8, self.alloc, advice, "{cmd}", cmd) catch null;
            return self.alloc.print("\u{201C}{s} -s sftp\u{201D} failed (exit {d}) without saying why. Its last steps:\n{s}", .{ cmd, out.code, lastLines(v.text, 4) }) catch null;
        }
        // What to do, then ssh's own words.
        const advice = sshAdvice(out.code, out.text);
        const said = firstLine(out.text);
        const msg = std.mem.replaceOwned(u8, self.alloc, advice, "{cmd}", cmd) catch return null;
        if (said.len == 0 or std.mem.eql(u8, said, advice)) return msg;
        defer self.alloc.free(msg);
        return self.alloc.print("{s}\n(ssh: {s})", .{ msg, said }) catch null;
    }

    /// configPath asks rclone where its config file is (cached; worker thread).
    fn configPath(self: *Devices) ?[]const u8 {
        if (self.rclone_conf) |p| return p;
        if (self.no_rclone) return null;
        const out = self.run(&.{ "rclone", "config", "file" }) orelse {
            self.no_rclone = true;
            return null;
        };
        defer self.alloc.free(out.text);
        if (out.code != 0) return null;
        // "Configuration file is stored at:\n/home/me/.config/rclone/rclone.conf\n"
        var last: []const u8 = "";
        var it = std.mem.splitScalar(u8, out.text, '\n');
        while (it.next()) |l| {
            const t = std.mem.trim(u8, l, " \t\r");
            if (t.len > 0 and t[0] == '/') last = t;
        }
        if (last.len == 0) return null;
        self.rclone_conf = self.alloc.dupe(u8, last) catch return null;
        return self.rclone_conf;
    }

    /// lookForServers asks avahi what's on the local network (worker thread).
    fn lookForServers(self: *Devices) void {
        self.setNetworkState(.looking);
        const out = self.run(&netbrowse.argv) orelse return self.setNetworkState(.no_avahi);
        defer self.alloc.free(out.text);
        if (out.code != 0) return self.setNetworkState(.no_avahi); // no daemon, or no tool
        // This computer announces itself too; Finder leaves it out.
        var hb: [256]u8 = undefined;
        const own = std.mem.trim(u8, readSmall("/proc/sys/kernel/hostname", &hb), " \n");
        const found = netbrowse.parse(self.alloc, out.text, own) catch return self.setNetworkState(.ready);
        self.mutex.lockUncancelable(self.io);
        const old = self.servers;
        self.servers = found;
        self.network_state = .ready;
        self.mutex.unlock(self.io);
        netbrowse.freeSlice(self.alloc, old);
        if (self.wake) |w| w();
    }

    fn setNetworkState(self: *Devices, st: NetworkState) void {
        self.mutex.lockUncancelable(self.io);
        // "looking" again doesn't hide what the last look found
        if (!(st == .looking and self.network_state == .ready)) self.network_state = st;
        self.mutex.unlock(self.io);
        if (self.wake) |w| w();
    }

    /// listRemotes refreshes the rclone remotes and which are mounted (worker thread).
    fn knowsRemote(self: *Devices, name: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.remotes) |r| if (std.mem.eql(u8, r.name, name)) return true;
        return false;
    }

    fn listRemotes(self: *Devices) void {
        if (self.no_rclone) return;
        _ = self.configPath();
        const out = self.run(&.{ "rclone", "listremotes", "--long" }) orelse {
            self.no_rclone = true;
            return;
        };
        defer self.alloc.free(out.text);
        if (out.code != 0) return;
        const rs = rclone.parseRemotes(self.alloc, out.text) catch return;
        const mounts = readProcFile(self.io, self.alloc, "/proc/self/mounts", 4 << 20) catch &.{};
        defer if (mounts.len > 0) self.alloc.free(mounts);
        const flags = self.alloc.alloc(bool, rs.len) catch {
            rclone.freeRemotes(self.alloc, rs);
            return;
        };
        self.mutex.lockUncancelable(self.io);
        for (rs, 0..) |r, i| {
            const mp = rclone.mountpoint(self.alloc, self.net_base, r.name) catch {
                flags[i] = false;
                continue;
            };
            defer self.alloc.free(mp);
            flags[i] = self.net_base.len > 0 and rclone.isMounted(mounts, mp);
        }
        const old = self.remotes;
        const old_flags = self.remote_mounted;
        self.remotes = rs;
        self.remote_mounted = flags;
        self.gen +%= 1;
        self.mutex.unlock(self.io);
        rclone.freeRemotes(self.alloc, old);
        if (old_flags.len > 0) self.alloc.free(old_flags);
    }

    fn lockOne(self: *Devices, container: []const u8) void {
        const out = self.run(&.{ "udisksctl", "lock", "-b", container }) orelse return;
        defer self.alloc.free(out.text);
        if (out.code != 0) self.fail(out.text);
    }

    fn unmountOne(self: *Devices, path: []const u8) bool {
        const out = self.run(&.{ "udisksctl", "unmount", "-b", path }) orelse {
            self.fail("Could not run udisksctl (is udisks2 installed?)");
            return false;
        };
        defer self.alloc.free(out.text);
        if (out.code != 0) {
            self.fail(out.text);
            return false;
        }
        return true;
    }

    fn setBusy(self: *Devices, path: ?[]const u8) void {
        const dup: ?[]u8 = if (path) |p| (self.alloc.dupe(u8, p) catch null) else null;
        self.mutex.lockUncancelable(self.io);
        const old = self.busy;
        self.busy = dup;
        self.mutex.unlock(self.io);
        if (old) |o| self.alloc.free(o);
        if (self.wake) |w| w();
    }

    fn emit(self: *Devices, e: Event) void {
        self.mutex.lockUncancelable(self.io);
        self.events.append(self.alloc, e) catch e.deinit(self.alloc);
        self.mutex.unlock(self.io);
        if (self.wake) |w| w();
    }

    /// fail reports udisksctl's error: its first meaningful line, minus the GDBus
    /// noise ("GDBus.Error:org.freedesktop.UDisks2.Error.NotAuthorized: …").
    /// failText reports an already-extracted message as is.
    fn failText(self: *Devices, text: []const u8) void {
        const msg = self.alloc.dupe(u8, text) catch return;
        self.emit(.{ .failed = .{ .msg = msg } });
    }

    fn fail(self: *Devices, text: []const u8) void {
        const msg = self.alloc.dupe(u8, errorLine(text)) catch return;
        self.emit(.{ .failed = .{ .msg = msg } });
    }

    const Output = struct { code: u8, text: []u8 };

    /// runInput is run() with `input` on the child's stdin (through a pipe, for the
    /// passphrase, which must never go on the command line or into a file).
    fn runInput(self: *Devices, argv: []const []const u8, input: []const u8) ?Output {
        const linux = std.os.linux;
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return null;
        // The passphrase fits the pipe buffer, so write it all and close before the
        // child starts: it reads it, then sees EOF.
        var off: usize = 0;
        while (off < input.len) {
            const rc = linux.write(fds[1], input.ptr + off, input.len - off);
            if (linux.errno(rc) != .SUCCESS) break;
            off += rc;
        }
        _ = linux.close(fds[1]);
        defer _ = linux.close(fds[0]);
        return self.runStdin(argv, .{ .handle = fds[0], .flags = .{ .nonblocking = false } });
    }

    /// run spawns argv with stdout+stderr captured into an anonymous memfd, recording
    /// the pid so destroy() can stop it. Null if it couldn't be started.
    fn run(self: *Devices, argv: []const []const u8) ?Output {
        return self.runStdin(argv, null);
    }

    fn runStdin(self: *Devices, argv: []const []const u8, stdin: ?std.Io.File) ?Output {
        const linux = std.os.linux;
        const mfd = linux.memfd_create("zfd-dev", linux.MFD.CLOEXEC);
        if (mfd > std.math.maxInt(i32)) return null;
        const fd: i32 = @intCast(mfd);
        defer _ = linux.close(fd);
        const f: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = if (stdin) |in| .{ .file = in } else .ignore,
            .stdout = .{ .file = f },
            .stderr = .{ .file = f },
        }) catch return null;
        self.child_pid.store(child.id orelse 0, .release);
        const term = child.wait(self.io) catch {
            self.child_pid.store(0, .release);
            return null;
        };
        self.child_pid.store(0, .release);
        const code: u8 = switch (term) {
            .exited => |e| e,
            else => 2,
        };
        return .{ .code = code, .text = readAll(self.alloc, fd) };
    }
};

fn readAll(alloc: std.mem.Allocator, fd: i32) []u8 {
    var out = std.ArrayList(u8).empty;
    var buf: [4096]u8 = undefined;
    var off: i64 = 0;
    while (out.items.len < 4 << 20) {
        const rc = std.os.linux.pread(fd, &buf, buf.len, off);
        if (rc == 0 or rc > buf.len) break;
        out.appendSlice(alloc, buf[0..rc]) catch break;
        off += @intCast(rc);
    }
    return out.toOwnedSlice(alloc) catch &.{};
}

/// systemSignature hashes /proc/partitions (hotplug) and /proc/self/mounts (mounts,
/// including ones made by other programs). Equal signature ⇒ nothing to re-list.
fn systemSignature(io: std.Io, alloc: std.mem.Allocator, rclone_conf: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    // rclone's config too: a remote added with `rclone config` shows up on its own.
    for ([_][]const u8{ "/proc/partitions", "/proc/self/mounts", rclone_conf }) |p| {
        if (p.len == 0) continue;
        const content = readProcFile(io, alloc, p, 8 << 20) catch continue;
        defer alloc.free(content);
        h.update(content);
    }
    return h.final();
}

fn napMs(ms: u64) void {
    const ts: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.os.linux.nanosleep(&ts, null);
}

/// errorLine picks the human part of udisksctl's error output.
pub fn errorLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // Without a terminal (always, from a GUI) udisksctl first complains that it
        // can't start its TEXT polkit agent; then carries on and the desktop's own
        // agent asks for the password. That line is noise, never the reason.
        if (std.mem.indexOf(u8, line, "textual authentication agent") != null) continue;
        // "Error mounting /dev/sdb1: GDBus.Error:org.freedesktop.UDisks2.Error.Foo: Real reason"
        if (std.mem.lastIndexOf(u8, line, ": ")) |i| {
            if (std.mem.indexOf(u8, line, "GDBus.Error") != null) line = line[i + 2 ..];
        }
        return line;
    }
    return "Operation failed";
}

fn dupVolumes(alloc: std.mem.Allocator, vols: []const Volume) ![]Volume {
    const out = try alloc.alloc(Volume, vols.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |v| freeVolume(alloc, v);
        alloc.free(out);
    }
    for (vols) |v| {
        out[n] = .{
            .path = try alloc.dupe(u8, v.path),
            .name = try alloc.dupe(u8, v.name),
            .fstype = try alloc.dupe(u8, v.fstype),
            .size = v.size,
            .mountpoint = try alloc.dupe(u8, v.mountpoint),
            .drive = try alloc.dupe(u8, v.drive),
            .removable = v.removable,
            .locked = v.locked,
            .crypt_parent = if (v.crypt_parent.len > 0) try alloc.dupe(u8, v.crypt_parent) else "",
            .uuid = if (v.uuid.len > 0) try alloc.dupe(u8, v.uuid) else "",
        };
        n += 1;
    }
    return out;
}

fn freeVolume(alloc: std.mem.Allocator, v: Volume) void {
    alloc.free(v.path);
    alloc.free(v.name);
    alloc.free(v.fstype);
    alloc.free(v.mountpoint);
    alloc.free(v.drive);
    if (v.crypt_parent.len > 0) alloc.free(v.crypt_parent);
    if (v.uuid.len > 0) alloc.free(v.uuid);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "errorLine strips the GDBus prefix down to the reason" {
    try testing.expectEqualStrings(
        "Not authorized to perform operation",
        errorLine("Error mounting /dev/sdb1: GDBus.Error:org.freedesktop.UDisks2.Error.NotAuthorized: Not authorized to perform operation\n"),
    );
    try testing.expectEqualStrings("Object /dev/sdz is not a mountable filesystem.", errorLine("\nObject /dev/sdz is not a mountable filesystem.\n"));
    try testing.expectEqualStrings("Operation failed", errorLine(""));
    // Real output from a session without a controlling terminal.
    try testing.expectEqualStrings("Not authorized to perform operation", errorLine(
        \\Error creating textual authentication agent: Error opening current controlling terminal for the process (`/dev/tty'): No such device or address (polkit-error-quark, 0)
        \\Error mounting /dev/sdb1: GDBus.Error:org.freedesktop.UDisks2.Error.NotAuthorizedCanObtain: Not authorized to perform operation
        \\
    ));
}

test "Devices lists volumes in the background and shuts down cleanly" {
    // Runs the real lsblk if present; the assertion is only that the worker publishes
    // a generation and destroy() joins without leaking (volumes may legitimately be 0).
    const d = try Devices.create(testing.io, testing.allocator, null);
    var spins: usize = 0;
    while (d.generation() == 0 and spins < 400) : (spins += 1) napMs(10);
    const vols = d.snapshot(testing.allocator);
    blockdev.free(testing.allocator, vols);
    d.destroy();
}

test "runInput hands its input to the child on stdin, byte for byte" {
    const d = try Devices.create(testing.io, testing.allocator, null);
    defer d.destroy();
    const out = d.runInput(&.{"cat"}, "pass phrase\twith tabs") orelse return error.SpawnFailed;
    defer testing.allocator.free(out.text);
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expectEqualStrings("pass phrase\twith tabs", out.text); // no newline added
}

/// readSmall reads a small /proc file into `buf` (empty on failure).
fn readSmall(path: [*:0]const u8, buf: []u8) []const u8 {
    const linux = std.os.linux;
    const rc: isize = @bitCast(linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    if (rc < 0) return buf[0..0];
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n: isize = @bitCast(linux.read(fd, buf.ptr, buf.len));
    return if (n > 0) buf[0..@intCast(n)] else buf[0..0];
}

const no_sftp_server = "ssh logs in, but the server has no SFTP program: its sshd's \u{201C}Subsystem sftp\u{201D} names one that isn't installed (exit 127). On the server, install it (Debian/Ubuntu: openssh-sftp-server) or set \u{201C}Subsystem sftp internal-sftp\u{201D} in /etc/ssh/sshd_config and restart sshd.";

/// sshCommand is the `ssh = …` line of `rclone config show`'s output ("" isn't one).
fn sshCommand(text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, "ssh")) continue;
        const rest = std.mem.trimStart(u8, t[3..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        const cmd = std.mem.trim(u8, rest[1..], " \t");
        return if (cmd.len > 0) cmd else null;
    }
    return null;
}

/// sshAdvice turns what `<ssh command> -s sftp` said (exit `code`, its output) into
/// why it failed and what to do ("{cmd}" stands for the ssh command).
fn sshAdvice(code: u8, text: []const u8) []const u8 {
    const has = struct {
        fn f(t: []const u8, s: []const u8) bool {
            return std.ascii.findIgnoreCase(t, s) != null;
        }
    }.f;
    if (has(text, "host key verification failed") or has(text, "no matching host key") or has(text, "remote host identification has changed"))
        return "ssh doesn't trust this server's key yet (or it changed). Run \u{201C}{cmd}\u{201D} once in a terminal and answer \u{201C}yes\u{201D}, then try again.";
    if (has(text, "permission denied"))
        return "The server refused the login: this needs a key ssh can use without asking (in ~/.ssh/config, or loaded in ssh-agent). A password can't be typed here: for that, Edit\u{2026} the server and type it in with its password.";
    if (has(text, "could not resolve hostname"))
        return "ssh couldn't find that server's address (check HostName in ~/.ssh/config).";
    if (has(text, "connection refused"))
        return "The server refused the connection (is ssh running there, on that port?).";
    if (has(text, "timed out") or has(text, "no route to host") or has(text, "network is unreachable"))
        return "The server didn't answer (is it on, and reachable from here?).";
    if (has(text, "subsystem request failed") or has(text, "sftp"))
        return "ssh logged in, but the server doesn't offer SFTP (its sshd needs the sftp subsystem).";
    if (code == 0)
        return "ssh logs in fine from here, but the SFTP session ended at once. Check the server's sshd (its sftp subsystem), or anything in ~/.ssh/config that runs a command (RemoteCommand) or prints text on login.";
    const t = firstLine(text);
    return if (t.len > 0) t else "ssh failed without saying why.";
}

/// lastLines is the end of `text`: its last `n` lines with something on them.
fn lastLines(text: []const u8, n: usize) []const u8 {
    const t = std.mem.trimEnd(u8, text, " \t\r\n");
    var start = t.len;
    var seen: usize = 0;
    while (start > 0 and seen < n) {
        start = if (std.mem.lastIndexOfScalar(u8, t[0 .. start - 1], '\n')) |i| i + 1 else 0;
        seen += 1;
        if (start == 0) break;
        start -= 1;
    }
    return std.mem.trimStart(u8, t[start..], "\r\n");
}

/// firstLine is the first line of `text` with something on it (trimmed).
fn firstLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len > 0) return t;
    }
    return "";
}

test "sshCommand finds the ssh line" {
    try std.testing.expectEqualStrings("ssh loudy", sshCommand("[x]\ntype = sftp\nhost = loudy\nssh = ssh loudy\n").?);
    try std.testing.expect(sshCommand("[x]\nssh = \nshell_type = unix\n") == null);
    try std.testing.expect(sshCommand("[x]\ntype = sftp\n") == null);
}

test "sshAdvice says why ssh hung up" {
    const t = std.testing;
    try t.expect(std.mem.indexOf(u8, sshAdvice(255, "Host key verification failed.\n"), "{cmd}") != null);
    try t.expect(std.mem.startsWith(u8, sshAdvice(255, "me@nas: Permission denied (publickey).\n"), "The server refused"));
    try t.expect(std.mem.startsWith(u8, sshAdvice(255, "ssh: Could not resolve hostname x: Name or service not known\n"), "ssh couldn't find"));
    try t.expect(std.mem.startsWith(u8, sshAdvice(0, ""), "ssh logs in fine"));
    try t.expectEqualStrings("weird thing", sshAdvice(1, "\n  weird thing\nmore\n"));
    try t.expectEqualStrings("c\nd", lastLines("a\nb\nc\nd\n", 2));
    try t.expectEqualStrings("a\nb", lastLines("a\nb", 5));
}
