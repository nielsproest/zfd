//! ProcWatch: copies made outside ZFD, and downloads in progress, seen through
//! /proc (as the `progress` tool does). Once a second a worker looks at your own
//! processes:
//!   - a copy tool (cp, mv, dd, rsync, tar, …): the file it reads and how far it got
//!     (fdinfo's pos against the file's size) — an outside operation to show;
//!   - when asked (a folder shown has some): which `.part` / `.crdownload` files are
//!     open for writing, i.e. still being downloaded. One nobody has open is left over
//!     from a browser that quit or died.
//! Read-only: nothing here can stop or change those processes. Linux-only, GUI-free.

const std = @import("std");
const linux = std.os.linux;
const mounts = @import("mounts.zig");

/// Outside is a copy running outside ZFD.
pub const Outside = struct {
    pid: i32 = 0,
    tool_buf: [16]u8 = undefined,
    tool_len: u8 = 0,
    name_buf: [256]u8 = undefined, // the file being read (basename)
    name_len: u16 = 0,
    done: u64 = 0,
    total: u64 = 0,

    pub fn tool(o: *const Outside) []const u8 {
        return o.tool_buf[0..o.tool_len];
    }
    pub fn name(o: *const Outside) []const u8 {
        return o.name_buf[0..o.name_len];
    }
    pub fn fraction(o: *const Outside) f32 {
        if (o.total == 0) return 0;
        return @floatCast(@min(@as(f64, @floatFromInt(o.done)) / @as(f64, @floatFromInt(o.total)), 1.0));
    }
};

pub const max_outside = 16;

/// Writer is the process writing a partial download.
pub const Writer = struct {
    pid: i32,
    comm_buf: [16]u8 = undefined,
    comm_len: u8 = 0,

    pub fn comm(w: *const Writer) []const u8 {
        return w.comm_buf[0..w.comm_len];
    }

    /// stoppable: a download program of its own (yt-dlp, wget, …), which can be
    /// stopped without harm — unlike a browser, where only its own Cancel is safe.
    pub fn stoppable(w: *const Writer) bool {
        for ([_][]const u8{ "yt-dlp", "youtube-dl", "wget", "wget2", "curl", "aria2c", "axel", "gallery-dl", "rclone", "lftp" }) |t| {
            if (std.mem.eql(u8, w.comm(), t)) return true;
        }
        return false;
    }

    /// stop asks the download program to quit (SIGTERM).
    pub fn stop(w: *const Writer) void {
        if (w.stoppable()) _ = linux.kill(w.pid, linux.SIG.TERM);
    }
};

const OpenDl = struct { path: []u8, writer: Writer };

const copy_tools = [_][]const u8{ "cp", "mv", "dd", "rsync", "tar", "install", "pv", "cat", "gzip", "xz", "zstd", "bzip2", "7z", "unzip", "scp", "sftp" };

/// isDownloadName reports whether `name` is a browser's partial download.
pub fn isDownloadName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".part") or std.mem.endsWith(u8, name, ".crdownload");
}

pub const ProcWatch = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    thread: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = .init(false),
    want_downloads: std.atomic.Value(bool) = .init(false),
    // --- guarded by mutex ---
    mutex: std.Io.Mutex = .init,
    outside: [max_outside]Outside = undefined,
    outside_n: usize = 0,
    open_dl: std.StringHashMapUnmanaged(Writer) = .empty, // path (owned) → who writes it

    pub fn create(io: std.Io, alloc: std.mem.Allocator) !*ProcWatch {
        const self = try alloc.create(ProcWatch);
        self.* = .{ .io = io, .alloc = alloc };
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |e| {
            alloc.destroy(self);
            return e;
        };
        return self;
    }

    pub fn destroy(self: *ProcWatch) void {
        self.shutdown.store(true, .release);
        if (self.thread) |t| t.join();
        self.clearOpen();
        self.open_dl.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// wantDownloads says whether a folder shown has partial downloads to check.
    pub fn wantDownloads(self: *ProcWatch, on: bool) void {
        self.want_downloads.store(on, .release);
    }

    /// outsideOps copies the outside copies seen last into `out`; returns how many.
    pub fn outsideOps(self: *ProcWatch, out: []Outside) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const n = @min(self.outside_n, out.len);
        @memcpy(out[0..n], self.outside[0..n]);
        return n;
    }

    /// writerOf is the process writing partial download `path`, or null when nothing
    /// has it open (left over).
    pub fn writerOf(self: *ProcWatch, path: []const u8) ?Writer {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.open_dl.get(path);
    }

    fn clearOpen(self: *ProcWatch) void {
        var it = self.open_dl.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.open_dl.clearRetainingCapacity();
    }

    fn run(self: *ProcWatch) void {
        while (!self.shutdown.load(.acquire)) {
            self.scan();
            // A second between looks, in short naps so closing doesn't wait.
            var k: usize = 0;
            while (k < 10 and !self.shutdown.load(.acquire)) : (k += 1) {
                const ts: linux.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
                _ = linux.nanosleep(&ts, null);
            }
        }
    }

    fn scan(self: *ProcWatch) void {
        var found: [max_outside]Outside = undefined;
        var n: usize = 0;
        var dls = std.ArrayList(OpenDl).empty;
        defer {
            for (dls.items) |d| self.alloc.free(d.path);
            dls.deinit(self.alloc);
        }
        const want_dl = self.want_downloads.load(.acquire);
        const uid = linux.getuid();

        var proc = std.Io.Dir.cwd().openDir(self.io, "/proc", .{ .iterate = true }) catch return;
        defer proc.close(self.io);
        var it = proc.iterate();
        while (it.next(self.io) catch null) |e| {
            if (self.shutdown.load(.acquire)) return; // closing: don't finish the pass
            const pid = std.fmt.parseInt(i32, e.name, 10) catch continue;
            if (pid == linux.getpid()) continue;
            var sx: linux.Statx = undefined;
            var pb: [64]u8 = undefined;
            const pdir = std.mem.printSentinel(&pb, "/proc/{d}", .{pid}, 0) catch continue;
            if (@as(isize, @bitCast(linux.statx(linux.AT.FDCWD, pdir.ptr, 0, .{ .UID = true }, &sx))) < 0) continue;
            if (sx.uid != uid) continue; // your own processes only
            var cb: [64]u8 = undefined;
            const comm = readComm(self.io, self.alloc, pid, &cb) orelse continue;
            const is_copy = for (copy_tools) |t| {
                if (std.mem.eql(u8, comm, t)) break true;
            } else false;
            if (!is_copy and !want_dl) continue;
            self.scanFds(pid, comm, is_copy, want_dl, &found, &n, &dls);
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        @memcpy(self.outside[0..n], found[0..n]);
        self.outside_n = n;
        self.clearOpen();
        for (dls.items) |d| {
            const owned = self.alloc.dupe(u8, d.path) catch continue;
            const gop = self.open_dl.getOrPut(self.alloc, owned) catch {
                self.alloc.free(owned);
                continue;
            };
            if (gop.found_existing) self.alloc.free(owned);
            gop.value_ptr.* = d.writer;
        }
    }

    /// scanFds looks at one process's open files: for a copy tool, the biggest
    /// regular file it reads (its source) and how far in it is; with `want_dl`, the
    /// partial downloads it writes.
    fn scanFds(self: *ProcWatch, pid: i32, comm: []const u8, is_copy: bool, want_dl: bool, found: *[max_outside]Outside, n: *usize, dls: *std.ArrayList(OpenDl)) void {
        var db: [64]u8 = undefined;
        const fd_dir = std.mem.print(&db, "/proc/{d}/fd", .{pid}) catch return;
        var d = std.Io.Dir.cwd().openDir(self.io, fd_dir, .{ .iterate = true }) catch return;
        defer d.close(self.io);
        var best: ?Outside = null;
        var it = d.iterate();
        while (it.next(self.io) catch null) |e| {
            if (self.shutdown.load(.acquire)) return;
            const fd = std.fmt.parseInt(u32, e.name, 10) catch continue;
            var lb: [64]u8 = undefined;
            const link = std.mem.printSentinel(&lb, "/proc/{d}/fd/{d}", .{ pid, fd }, 0) catch continue;
            var tb: [std.fs.max_path_bytes]u8 = undefined;
            const rc = linux.readlink(link.ptr, &tb, tb.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) continue;
            const target = tb[0..rc];
            if (target[0] != '/' or std.mem.startsWith(u8, target, "/proc/") or std.mem.startsWith(u8, target, "/dev/") or std.mem.startsWith(u8, target, "/sys/")) continue;
            const writing = want_dl and isDownloadName(target);
            if (!is_copy and !writing) continue;
            const info = readFdInfo(self.io, self.alloc, pid, fd) orelse continue;
            const acc = info.flags & 3; // 0 read, 1 write, 2 both
            if (writing and acc != 0) {
                const p = self.alloc.dupe(u8, target) catch continue;
                var w: Writer = .{ .pid = pid };
                const cl = @min(comm.len, w.comm_buf.len);
                @memcpy(w.comm_buf[0..cl], comm[0..cl]);
                w.comm_len = @intCast(cl);
                dls.append(self.alloc, .{ .path = p, .writer = w }) catch self.alloc.free(p);
            }
            if (!is_copy or acc != 0) continue;
            var sx: linux.Statx = undefined;
            var zb: [std.fs.max_path_bytes + 1]u8 = undefined;
            const tz = std.mem.printSentinel(&zb, "{s}", .{target}, 0) catch continue;
            if (@as(isize, @bitCast(linux.statx(linux.AT.FDCWD, tz.ptr, 0, .{ .SIZE = true, .TYPE = true }, &sx))) < 0) continue;
            if (!linux.S.ISREG(sx.mode) or sx.size == 0) continue;
            if (best == null or sx.size > best.?.total) {
                var o: Outside = .{ .pid = pid, .done = info.pos, .total = sx.size };
                const tl = @min(comm.len, o.tool_buf.len);
                @memcpy(o.tool_buf[0..tl], comm[0..tl]);
                o.tool_len = @intCast(tl);
                const base = std.fs.path.basename(target);
                const nl = @min(base.len, o.name_buf.len);
                @memcpy(o.name_buf[0..nl], base[0..nl]);
                o.name_len = @intCast(nl);
                best = o;
            }
        }
        if (best) |o| if (n.* < found.len) {
            found[n.*] = o;
            n.* += 1;
        };
    }
};

fn readComm(io: std.Io, alloc: std.mem.Allocator, pid: i32, out: []u8) ?[]const u8 {
    var pb: [64]u8 = undefined;
    const p = std.mem.print(&pb, "/proc/{d}/comm", .{pid}) catch return null;
    const text = mounts.readProcFile(io, alloc, p, 64) catch return null;
    defer alloc.free(text);
    const t = std.mem.trimEnd(u8, text, "\n");
    const l = @min(t.len, out.len);
    @memcpy(out[0..l], t[0..l]);
    return out[0..l];
}

const FdInfo = struct { pos: u64, flags: u32 };

fn readFdInfo(io: std.Io, alloc: std.mem.Allocator, pid: i32, fd: u32) ?FdInfo {
    var pb: [64]u8 = undefined;
    const p = std.mem.print(&pb, "/proc/{d}/fdinfo/{d}", .{ pid, fd }) catch return null;
    const text = mounts.readProcFile(io, alloc, p, 4096) catch return null;
    defer alloc.free(text);
    return parseFdInfo(text);
}

/// parseFdInfo reads `pos:` (decimal) and `flags:` (octal) out of a fdinfo file.
pub fn parseFdInfo(text: []const u8) ?FdInfo {
    var pos: ?u64 = null;
    var flags: ?u32 = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.mem.eql(u8, line[0..colon], "pos")) pos = std.fmt.parseInt(u64, v, 10) catch null;
        if (std.mem.eql(u8, line[0..colon], "flags")) flags = std.fmt.parseInt(u32, v, 8) catch null;
    }
    return .{ .pos = pos orelse return null, .flags = flags orelse return null };
}

test "parseFdInfo reads pos and octal flags" {
    const fi = parseFdInfo("pos:\t1048576\nflags:\t0100001\nmnt_id:\t31\nino:\t42\n").?;
    try std.testing.expectEqual(@as(u64, 1048576), fi.pos);
    try std.testing.expectEqual(@as(u32, 1), fi.flags & 3); // written to
    try std.testing.expect(isDownloadName("film.mkv.part"));
    try std.testing.expect(isDownloadName("x.crdownload"));
    try std.testing.expect(!isDownloadName("partial.txt"));
}

test "ProcWatch sees a copy tool part-way through a file" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const size = 4 << 20;
    const data = try a.alloc(u8, size);
    defer a.free(data);
    @memset(data, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "zfd-pw-src", .data = data });
    const p = try tmp.dir.realPathFileAlloc(io, "zfd-pw-src", a);
    defer a.free(p);
    // cat writes into a pipe nobody reads, so it stalls part-way through the file.
    var child = std.process.spawn(io, .{ .argv = &.{ "sh", "-c", "cat \"$0\" | sleep 3", p }, .stdout = .ignore, .stderr = .ignore }) catch return error.SkipZigTest;
    defer child.kill(io);
    var pw = try ProcWatch.create(io, a);
    defer pw.destroy();
    const ts: linux.timespec = .{ .sec = 1, .nsec = 500 * std.time.ns_per_ms };
    _ = linux.nanosleep(&ts, null);
    var buf: [max_outside]Outside = undefined;
    const ops = buf[0..pw.outsideOps(&buf)];
    for (ops) |o| {
        if (!std.mem.eql(u8, o.name(), "zfd-pw-src")) continue;
        try std.testing.expectEqualStrings("cat", o.tool());
        try std.testing.expectEqual(@as(u64, size), o.total);
        try std.testing.expect(o.done > 0 and o.done < size);
        return;
    }
    return error.TestExpectedCopySeen;
}
