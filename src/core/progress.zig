//! Progress is the shared async abstraction for long file operations: a thread-safe
//! cell an off-thread worker updates (files/bytes done, current item) and honors for
//! cancellation, while the render thread displays a bar and can request a cancel.
//!
//! It's GUI-free and pure (goal 2) — the op-runner owns one, fsops reports into it,
//! the shell draws it. Cancellation is *cooperative*: the worker calls `canceled()`
//! at safe points (between files, between copy chunks) and unwinds with
//! `error.Canceled`. Numeric fields are atomics (a hot path: bytes tick per chunk);
//! only the variable-length current-item name needs a lock.
//!
//! This mirrors GoFileDialog's model: the directory browse cancels implicitly by
//! being superseded (see scanner/usage generation counters); every *other* op runs
//! through this Progress with a visible bar + Cancel button.

const std = @import("std");

pub const Phase = enum(u8) { idle, copying, moving, deleting, trashing, compressing, extracting, tagging };

/// Snapshot is an immutable read of the progress for one frame. `current` points
/// into the caller-supplied buffer passed to `snapshot`.
pub const Snapshot = struct {
    phase: Phase,
    files_done: u64,
    files_total: u64,
    bytes_done: u64,
    bytes_total: u64,
    current: []const u8,
    canceled: bool,
    elapsed_ns: u64 = 0, // since the job was picked up (quick jobs show no window)

    pub fn active(self: Snapshot) bool {
        return self.phase != .idle;
    }

    /// fraction is the best 0..1 completion estimate: bytes when known, else files.
    pub fn fraction(self: Snapshot) f32 {
        if (self.bytes_total > 0) return ratio(self.bytes_done, self.bytes_total);
        if (self.files_total > 0) return ratio(self.files_done, self.files_total);
        return 0;
    }
};

fn ratio(a: u64, b: u64) f32 {
    const f = @as(f32, @floatFromInt(a)) / @as(f32, @floatFromInt(b));
    return @min(@max(f, 0), 1);
}

pub const Progress = struct {
    io: std.Io,
    phase: std.atomic.Value(u8) = .init(@backingInt(Phase.idle)),
    files_done: std.atomic.Value(u64) = .init(0),
    files_total: std.atomic.Value(u64) = .init(0),
    bytes_done: std.atomic.Value(u64) = .init(0),
    bytes_total: std.atomic.Value(u64) = .init(0),
    cancel_flag: std.atomic.Value(bool) = .init(false),
    start_ns: std.atomic.Value(u64) = .init(0),

    // Only the variable-length current-item name needs a lock; the numeric hot path
    // (bytes tick per chunk) is lock-free atomics.
    name_mutex: std.Io.Mutex = .init,
    cur_buf: [512]u8 = undefined,
    cur_len: usize = 0,

    // ---- worker side --------------------------------------------------------

    /// claim marks the progress active for a newly picked-up job and clears any
    /// cancel left from the previous one. Call once per job, before begin.
    pub fn claim(self: *Progress) void {
        self.cancel_flag.store(false, .monotonic);
        self.start_ns.store(monoNs(), .monotonic);
        self.begin(.copying, 0, 0);
    }

    /// begin starts (or re-phases) the operation, resetting its counters. It leaves
    /// the cancel flag alone, so a Cancel that arrives before the job measures its
    /// work still stops it.
    pub fn begin(self: *Progress, phase: Phase, files_total: u64, bytes_total: u64) void {
        self.files_done.store(0, .monotonic);
        self.bytes_done.store(0, .monotonic);
        self.files_total.store(files_total, .monotonic);
        self.bytes_total.store(bytes_total, .monotonic);
        self.setCurrent("");
        self.phase.store(@backingInt(phase), .release);
    }

    pub fn setCurrent(self: *Progress, name: []const u8) void {
        self.name_mutex.lockUncancelable(self.io);
        defer self.name_mutex.unlock(self.io);
        const n = @min(name.len, self.cur_buf.len);
        @memcpy(self.cur_buf[0..n], name[0..n]);
        self.cur_len = n;
    }

    pub fn addBytes(self: *Progress, n: u64) void {
        _ = self.bytes_done.fetchAdd(n, .monotonic);
    }

    pub fn addFile(self: *Progress) void {
        _ = self.files_done.fetchAdd(1, .monotonic);
    }

    /// canceled reports whether a cancel has been requested — the worker checks this
    /// between files and between copy chunks and unwinds with error.Canceled.
    pub fn canceled(self: *Progress) bool {
        return self.cancel_flag.load(.monotonic);
    }

    pub fn finish(self: *Progress) void {
        self.phase.store(@backingInt(Phase.idle), .release);
    }

    // ---- render side --------------------------------------------------------

    pub fn requestCancel(self: *Progress) void {
        self.cancel_flag.store(true, .monotonic);
    }

    pub fn isActive(self: *Progress) bool {
        return self.phase.load(.acquire) != @backingInt(Phase.idle);
    }

    /// snapshot reads the whole state for one frame; `current` points into out_buf.
    pub fn snapshot(self: *Progress, out_buf: []u8) Snapshot {
        var name: []const u8 = "";
        {
            self.name_mutex.lockUncancelable(self.io);
            defer self.name_mutex.unlock(self.io);
            const n = @min(self.cur_len, out_buf.len);
            @memcpy(out_buf[0..n], self.cur_buf[0..n]);
            name = out_buf[0..n];
        }
        return .{
            .phase = @fromBackingInt(@intCast(self.phase.load(.acquire))),
            .files_done = self.files_done.load(.monotonic),
            .files_total = self.files_total.load(.monotonic),
            .bytes_done = self.bytes_done.load(.monotonic),
            .bytes_total = self.bytes_total.load(.monotonic),
            .current = name,
            .canceled = self.cancel_flag.load(.monotonic),
            .elapsed_ns = monoNs() -| self.start_ns.load(.monotonic),
        };
    }
};

fn monoNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "progress reports counters and honors cancel across threads" {
    var p = Progress{ .io = testing.io };
    var buf: [512]u8 = undefined;

    // Before: idle, nothing done.
    const before = p.snapshot(&buf);
    try testing.expect(!before.active());
    try testing.expectEqual(@as(u64, 0), before.bytes_done);

    p.begin(.copying, 2, 100);
    p.setCurrent("file.txt");
    p.addBytes(40);
    p.addFile();

    // After begin+updates: active, partway done, name set (a real delta).
    const mid = p.snapshot(&buf);
    try testing.expect(mid.active());
    try testing.expectEqual(Phase.copying, mid.phase);
    try testing.expectEqual(@as(u64, 40), mid.bytes_done);
    try testing.expectEqual(@as(u64, 1), mid.files_done);
    try testing.expectEqualStrings("file.txt", mid.current);
    try testing.expectApproxEqAbs(@as(f32, 0.4), mid.fraction(), 0.001);

    // Cancellation propagates from the render side to the worker side.
    try testing.expect(!p.canceled());
    p.requestCancel();
    try testing.expect(p.canceled());

    p.finish();
    try testing.expect(!p.snapshot(&buf).active());
}
