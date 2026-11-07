//! Setting up rclone locations through a private `rclone rcd`: rclone's remote
//! control, on a Unix socket in the runtime dir (only this user can reach it), running
//! while "Connect to Server" is open. It lists every backend rclone has with its
//! settings (`config/providers`), creates a location (`config/create`) and walks
//! rclone's own setup questions (`config/update`, continuing from a state): a browser
//! sign-in, which drive, and so on. Passwords travel in the request body, never on a
//! command line, and rclone stores them obscured.
//!
//! Mounting doesn't go through it: a mount made by rcd ends when rcd does, so remotes
//! are still mounted with `rclone mount --daemon` (devices.zig), each on its own.
//!
//! Each request runs on its own thread (a sign-in can take minutes); the UI polls
//! `take`. GUI-free; the parsing lives in rclone.zig.

const std = @import("std");
const fsops = @import("fsops.zig");

pub const Setup = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    sock_path: []u8, // owned
    wake: ?*const fn () void = null,
    home: []const u8 = "", // whose ~/.ssh/config to read (borrowed; "" = don't)
    edit_name: []const u8 = "", // a location being edited: its settings come with the providers (borrowed)

    mutex: std.Io.Mutex = .init,
    // --- guarded by mutex ---
    providers: ?[]u8 = null, // config/providers' reply, once loaded (owned)
    ssh_hosts: [][]u8 = &.{}, // ~/.ssh/config's hosts, read with the providers (owned)
    known_hosts: bool = false, // ~/.ssh/known_hosts is there (checked with them too)
    saved: ?[]u8 = null, // edit_name's settings (config/get's JSON object), once loaded (owned)
    reply: ?Reply = null, // the last create/update/delete's outcome, not yet taken
    busy: bool = false, // a request is running
    // -------------------------
    child: ?std.process.Child = null, // the rcd (worker threads only, one at a time)
    thread: ?std.Thread = null,

    /// Reply is how a request went: rclone's JSON answer, or an error message.
    pub const Reply = union(enum) {
        json: []u8,
        failed: []u8,

        pub fn deinit(r: Reply, alloc: std.mem.Allocator) void {
            switch (r) {
                inline else => |t| alloc.free(t),
            }
        }
    };

    /// create prepares a setup whose rcd will listen in `dir` (started on first use).
    pub fn create(io: std.Io, alloc: std.mem.Allocator, dir: []const u8, wake: ?*const fn () void) !*Setup {
        const s = try alloc.create(Setup);
        errdefer alloc.destroy(s);
        const sock = try alloc.print("{s}/zfd-rc-{d}.sock", .{ dir, std.os.linux.getpid() });
        if (sock.len > std.Io.net.UnixAddress.max_len) {
            alloc.free(sock);
            return error.NameTooLong;
        }
        s.* = .{ .io = io, .alloc = alloc, .sock_path = sock, .wake = wake };
        reapOrphans(io, alloc, dir);
        return s;
    }

    /// destroy stops rcd (ending a request still running) and frees everything.
    pub fn destroy(self: *Setup) void {
        self.stopRcd();
        if (self.thread) |t| t.join();
        self.stopRcd(); // in case the request started it meanwhile
        if (self.providers) |p| self.alloc.free(p);
        if (self.saved) |p| {
            std.crypto.secureZero(u8, p); // (passwords, obscured)
            self.alloc.free(p);
        }
        @import("sshconfig.zig").freeHosts(self.alloc, self.ssh_hosts);
        if (self.reply) |r| r.deinit(self.alloc);
        self.alloc.free(self.sock_path);
        self.alloc.destroy(self);
    }

    pub fn isBusy(self: *Setup) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.busy;
    }

    /// providersJson is config/providers' reply once loaded (borrowed; stays until
    /// destroy).
    pub fn providersJson(self: *Setup) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.providers;
    }

    /// sshHosts is the host names in ~/.ssh/config (borrowed; set once, with the
    /// providers).
    pub fn sshHosts(self: *Setup) []const []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.ssh_hosts;
    }

    /// savedJson is the edited location's settings once loaded (borrowed; stays until
    /// destroy).
    pub fn savedJson(self: *Setup) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.saved;
    }

    /// hasKnownHosts: ~/.ssh/known_hosts exists (so SFTP can check host keys with it).
    pub fn hasKnownHosts(self: *Setup) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.known_hosts;
    }

    /// take hands over the last request's outcome (caller frees with deinit).
    pub fn take(self: *Setup) ?Reply {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const r = self.reply;
        self.reply = null;
        return r;
    }

    /// loadProviders fetches the backend list (once).
    pub fn loadProviders(self: *Setup) void {
        if (self.providersJson() != null) return;
        self.start("config/providers", "{}", .providers);
    }

    /// begin creates location `name` of backend `typ` with `params` (a JSON object of
    /// the settings filled in) and starts rclone's questions.
    pub fn begin(self: *Setup, name: []const u8, typ: []const u8, params_json: []const u8) void {
        const body = self.alloc.print("{{\"name\":{f},\"type\":{f},\"parameters\":{s},\"opt\":{{\"nonInteractive\":true,\"obscure\":true}}}}", .{
            std.json.fmt(name, .{}), std.json.fmt(typ, .{}), params_json,
        }) catch return self.failNow("Out of memory");
        defer self.alloc.free(body);
        self.start("config/create", body, .reply);
    }

    /// update changes location `name`'s settings to `params` (a JSON object of the
    /// changed ones) and starts rclone's questions, as begin does.
    pub fn update(self: *Setup, name: []const u8, params_json: []const u8) void {
        const body = self.alloc.print("{{\"name\":{f},\"parameters\":{s},\"opt\":{{\"nonInteractive\":true,\"obscure\":true}}}}", .{
            std.json.fmt(name, .{}), params_json,
        }) catch return self.failNow("Out of memory");
        defer {
            std.crypto.secureZero(u8, body);
            self.alloc.free(body);
        }
        self.start("config/update", body, .reply);
    }

    /// answer gives rclone the answer `result` to the question it asked at `state`.
    pub fn answer(self: *Setup, name: []const u8, state: []const u8, result: []const u8) void {
        const body = self.alloc.print("{{\"name\":{f},\"parameters\":{{}},\"opt\":{{\"nonInteractive\":true,\"obscure\":true,\"continue\":true,\"state\":{f},\"result\":{f}}}}}", .{
            std.json.fmt(name, .{}), std.json.fmt(state, .{}), std.json.fmt(result, .{}),
        }) catch return self.failNow("Out of memory");
        defer {
            std.crypto.secureZero(u8, body); // the answer may be a password
            self.alloc.free(body);
        }
        self.start("config/update", body, .reply);
    }

    /// remove deletes location `name` (a setup given up half-way).
    pub fn remove(self: *Setup, name: []const u8) void {
        const body = self.alloc.print("{{\"name\":{f}}}", .{std.json.fmt(name, .{})}) catch return;
        defer self.alloc.free(body);
        self.start("config/delete", body, .ignore);
    }

    const Into = enum { providers, reply, ignore };

    fn start(self: *Setup, method: []const u8, body: []const u8, into: Into) void {
        if (self.thread) |t| {
            t.join(); // the last one is done (the UI waits for !busy)
            self.thread = null;
        }
        const m = self.alloc.dupe(u8, method) catch return self.failNow("Out of memory");
        const b = self.alloc.dupe(u8, body) catch {
            self.alloc.free(m);
            return self.failNow("Out of memory");
        };
        self.setBusy(true);
        self.thread = std.Thread.spawn(.{}, run, .{ self, m, b, into }) catch {
            self.alloc.free(m);
            self.alloc.free(b);
            self.setBusy(false);
            return self.failNow("Could not start a thread");
        };
    }

    fn run(self: *Setup, method: []u8, body: []u8, into: Into) void {
        defer {
            self.alloc.free(method);
            std.crypto.secureZero(u8, body);
            self.alloc.free(body);
            self.setBusy(false);
            if (self.wake) |w| w();
        }
        const out = self.call(method, body) catch |e| {
            if (into != .ignore) self.publish(.{ .failed = self.alloc.dupe(u8, switch (e) {
                error.NoRclone => "Could not run rclone (is it installed?)",
                else => "rclone stopped answering",
            }) catch return });
            return;
        };
        switch (into) {
            .ignore => self.alloc.free(out.body),
            .providers => if (out.ok) {
                // The SSH config's hosts too (SFTP offers them), off the render thread.
                const hs: [][]u8 = if (self.home.len > 0) @import("sshconfig.zig").hosts(self.io, self.alloc, self.home) else &.{};
                const kh = self.home.len > 0 and knownHostsThere(self.io, self.home);
                // The location being edited: its settings, on this same thread.
                const saved: ?[]u8 = if (self.edit_name.len > 0) blk: {
                    var nb: [256]u8 = undefined;
                    const req = std.mem.print(&nb, "{{\"name\":{f}}}", .{std.json.fmt(self.edit_name, .{})}) catch break :blk null;
                    const got = self.call("config/get", req) catch break :blk null;
                    if (!got.ok) {
                        self.alloc.free(got.body);
                        break :blk null;
                    }
                    break :blk got.body;
                } else null;
                self.mutex.lockUncancelable(self.io);
                self.known_hosts = kh;
                if (saved) |sv| {
                    if (self.saved) |old| self.alloc.free(old);
                    self.saved = sv;
                }
                if (self.ssh_hosts.len == 0) self.ssh_hosts = hs else @import("sshconfig.zig").freeHosts(self.alloc, hs);
                defer self.mutex.unlock(self.io);
                if (self.providers) |p| self.alloc.free(p);
                self.providers = out.body;
            } else self.publishError(out.body),
            .reply => if (out.ok) self.publish(.{ .json = out.body }) else self.publishError(out.body),
        }
    }

    fn knownHostsThere(io: std.Io, home: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.mem.print(&buf, "{s}/.ssh/known_hosts", .{home}) catch return false;
        _ = std.Io.Dir.cwd().statFile(io, p, .{}) catch return false;
        return true;
    }

    fn publishError(self: *Setup, body: []u8) void {
        defer self.alloc.free(body);
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const msg = @import("rclone.zig").rcError(arena.allocator(), body);
        self.publish(.{ .failed = self.alloc.dupe(u8, if (msg.len > 0) msg else "rclone refused") catch return });
    }

    fn publish(self: *Setup, r: Reply) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.reply) |old| old.deinit(self.alloc);
        self.reply = r;
    }

    fn failNow(self: *Setup, msg: []const u8) void {
        self.publish(.{ .failed = self.alloc.dupe(u8, msg) catch return });
    }

    fn setBusy(self: *Setup, on: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.busy = on;
    }

    const Out = struct { ok: bool, body: []u8 };

    /// call POSTs `body` to rc method `method` (starting rcd if it isn't running).
    fn call(self: *Setup, method: []const u8, body: []const u8) !Out {
        const stream = try self.connect();
        defer stream.close(self.io);
        var wbuf: [1024]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        // HTTP/1.0: the reply comes whole, not chunked, and the connection closes after.
        try w.interface.print("POST /{s} HTTP/1.0\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{ method, body.len });
        try w.interface.writeAll(body);
        try w.interface.flush();
        var rbuf: [16 * 1024]u8 = undefined;
        var r = stream.reader(self.io, &rbuf);
        const all = try r.interface.allocRemaining(self.alloc, .limited(16 << 20));
        defer self.alloc.free(all);
        const split = std.mem.indexOf(u8, all, "\r\n\r\n") orelse return error.BadReply;
        const status = all[0 .. std.mem.indexOfScalar(u8, all, '\r') orelse split];
        const ok = std.mem.indexOf(u8, status, " 200 ") != null;
        return .{ .ok = ok, .body = try self.alloc.dupe(u8, all[split + 4 ..]) };
    }

    /// connect opens the socket, starting rcd first if nothing's listening.
    fn connect(self: *Setup) !std.Io.net.Stream {
        const ua = try std.Io.net.UnixAddress.init(self.sock_path);
        if (ua.connect(self.io)) |s| return s else |_| {}
        try self.startRcd();
        // It takes a moment to listen.
        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            if (ua.connect(self.io)) |s| return s else |_| {}
            if (self.child == null) return error.NoRclone;
            std.Io.sleep(self.io, .fromMilliseconds(50), .awake) catch {};
        }
        return error.NoRclone;
    }

    fn startRcd(self: *Setup) !void {
        self.stopRcd();
        std.Io.Dir.cwd().deleteFile(self.io, self.sock_path) catch {};
        const addr = try self.alloc.print("unix://{s}", .{self.sock_path});
        defer self.alloc.free(addr);
        // No login: the socket is in the user's own runtime dir, which nobody else can
        // enter. The environment is ours (rclone's config file, its password command).
        self.child = std.process.spawn(self.io, .{
            .argv = &.{ "rclone", "rcd", "--rc-addr", addr, "--rc-no-auth" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .environ_map = fsops.launch_env,
        }) catch return error.NoRclone;
    }

    /// reapOrphans stops the rcds of zfd windows that are gone (killed while Connect
    /// to Server was open, so they couldn't stop theirs): each socket is named after
    /// its window's pid, and its rcd is found by the socket on its command line.
    fn reapOrphans(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) void {
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (!std.mem.startsWith(u8, e.name, "zfd-rc-") or !std.mem.endsWith(u8, e.name, ".sock")) continue;
            const pid = std.fmt.parseInt(i32, e.name["zfd-rc-".len .. e.name.len - ".sock".len], 10) catch continue;
            var qb: [32]u8 = undefined;
            const alive = std.Io.Dir.cwd().statFile(io, std.mem.print(&qb, "/proc/{d}", .{pid}) catch continue, .{});
            if (alive) |_| continue else |_| {} // that window is still here
            var pb: [std.fs.max_path_bytes]u8 = undefined;
            const sock = std.mem.print(&pb, "unix://{s}/{s}", .{ dir_path, e.name }) catch continue;
            killRcdFor(io, alloc, sock);
            dir.deleteFile(io, e.name) catch {};
        }
    }

    /// killRcdFor stops the `rclone rcd` listening on `addr` (its --rc-addr).
    fn killRcdFor(io: std.Io, alloc: std.mem.Allocator, addr: []const u8) void {
        var proc = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return;
        defer proc.close(io);
        var it = proc.iterate();
        while (it.next(io) catch null) |e| {
            const pid = std.fmt.parseInt(i32, e.name, 10) catch continue;
            var pb: [64]u8 = undefined;
            const p = std.mem.print(&pb, "{d}/cmdline", .{pid}) catch continue;
            // (/proc files say they're empty, so read until the end, not to a size.)
            const f = proc.openFile(io, p, .{}) catch continue;
            defer f.close(io);
            var rb: [512]u8 = undefined;
            var r = f.readerStreaming(io, &rb);
            const cmd = r.interface.allocRemaining(alloc, .limited(4096)) catch continue;
            defer alloc.free(cmd);
            // rclone\0rcd\0--rc-addr\0unix://…\0
            if (std.mem.indexOf(u8, cmd, "rcd\x00--rc-addr\x00") == null) continue;
            var args = std.mem.splitScalar(u8, cmd, 0);
            while (args.next()) |a| if (std.mem.eql(u8, a, addr)) {
                _ = std.os.linux.kill(pid, .KILL);
                break;
            };
        }
    }

    fn stopRcd(self: *Setup) void {
        if (self.child) |*ch| {
            // SIGKILL: on SIGTERM rclone first waits for what it's doing, and a browser
            // sign-in waits for the browser.
            if (ch.id) |pid| _ = std.os.linux.kill(pid, .KILL);
            ch.kill(self.io); // (reaps it)
            self.child = null;
            std.Io.Dir.cwd().deleteFile(self.io, self.sock_path) catch {};
        }
    }
};
