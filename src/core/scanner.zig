//! Off-thread directory scanner: the heart of goal 1 (never read the disk on the
//! render thread). Mirrors the Go project's reload pattern: a background worker
//! does the blocking `readDir` + sort, hands the finished Listing back through a
//! mutex-guarded slot, and the render thread folds it in per frame via a
//! NON-BLOCKING `poll()`. Newer navigations supersede older in-flight reads by
//! generation, so a slow directory can't deliver a stale listing after you've
//! moved on.
//!
//! One persistent worker thread (spawned by `start`). Teardown has two flavors:
//! `deinit` JOINS the worker (synchronous; used by tests + tab close), while
//! `orphan` DETACHES it (used at process exit) so pressing Save mid-load never
//! freezes waiting for a slow read to return. The worker/render rendezvous lives
//! in a heap-allocated, reference-counted `Shared` block that outlives the Browser
//! when orphaned. Uses Zig 0.16's `Io.Mutex`/`Io.Condition`.

const std = @import("std");
const scan = @import("scan.zig");
const recent = @import("recent.zig");
const arcfs = @import("arcfs.zig");

pub const Scanner = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    shared: ?*Shared = null, // heap control block; outlives us when orphaned
    worker: ?std.Thread = null, // render-thread-only handle (join in deinit, detach in orphan)
    consumed_gen: u64 = 0, // render-thread only: last gen we handed out

    /// Shared is the worker⇄render rendezvous. It lives on the heap, SEPARATE from the
    /// Browser-embedded Scanner, so `orphan` can detach the worker and let the Browser be
    /// freed immediately while a slow in-flight read finishes on its own. Reference-counted
    /// (Scanner + worker each hold one); the last holder out frees it. `alloc`/`io` must
    /// outlive the worker; they're process-lifetime in this app.
    const Shared = struct {
        io: std.Io,
        alloc: std.mem.Allocator,
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init, // worker sleeps here until a request arrives

        // --- guarded by mutex ---
        req_path: ?[]u8 = null, // latest pending request (owned), null = none waiting
        req_gen: u64 = 0, // bumped on every request; identifies the newest
        ready: ?scan.Listing = null, // completed listing awaiting pickup (owned)
        ready_err: ?anyerror = null,
        ready_gen: u64 = 0, // gen the ready slot belongs to
        refs: u8 = 0, // holders still alive (Scanner + worker)
        // ------------------------

        // `shutdown` is set under the mutex (to order against the cond-wait) but ALSO read
        // lock-free in the retry-nap loop, so every access goes through @atomic*.
        shutdown: bool = false,
        // Set (atomically) when a newer request or teardown makes the read in progress
        // pointless; the read checks it between entries and gives up.
        abandon: bool = false,
    };

    pub const Result = union(enum) { listing: scan.Listing, err: anyerror };

    pub fn init(io: std.Io, alloc: std.mem.Allocator) Scanner {
        return .{ .io = io, .alloc = alloc };
    }

    /// start allocates the shared block and spawns the worker. Call once, before any
    /// request. refs = 2: this Scanner plus the worker.
    pub fn start(self: *Scanner) !void {
        const sh = try self.alloc.create(Shared);
        sh.* = .{ .io = self.io, .alloc = self.alloc, .refs = 2 };
        self.worker = std.Thread.spawn(.{}, workerLoop, .{sh}) catch |e| {
            self.alloc.destroy(sh);
            return e;
        };
        self.shared = sh;
    }

    /// deinit stops the worker, JOINS it, and frees the shared block. Synchronous: it
    /// blocks until the worker's current read returns. Used by tests and tab close. For a
    /// slow in-flight read at process exit, prefer `orphan` so the UI doesn't freeze.
    pub fn deinit(self: *Scanner) void {
        const sh = self.shared orelse return;
        signalShutdown(sh);
        if (self.worker) |w| w.join(); // worker released its ref on exit
        self.worker = null;
        release(sh); // last ref → frees the block
        self.shared = null;
    }

    /// orphan stops the worker but DETACHES it (no join), so teardown never blocks on an
    /// in-flight slow directory read. The detached worker sees `shutdown`, drops its result,
    /// and frees the shared block (last ref out). Safe because the block is heap-allocated
    /// and refcounted, so the Browser embedding this Scanner may be freed immediately after.
    /// Idempotent, and a following `deinit` becomes a no-op.
    pub fn orphan(self: *Scanner) void {
        const sh = self.shared orelse return;
        signalShutdown(sh);
        if (self.worker) |w| w.detach();
        self.worker = null;
        release(sh); // drop our ref; the worker frees the block when it exits
        self.shared = null;
    }

    /// signalShutdown flags teardown and wakes an idle worker. Taken under the mutex so a
    /// worker about to cond-wait can't miss it (lost-wakeup guard).
    fn signalShutdown(sh: *Shared) void {
        sh.mutex.lockUncancelable(sh.io);
        @atomicStore(bool, &sh.shutdown, true, .release);
        @atomicStore(bool, &sh.abandon, true, .release);
        if (sh.req_path) |p| {
            sh.alloc.free(p);
            sh.req_path = null;
        }
        sh.mutex.unlock(sh.io);
        sh.cond.signal(sh.io);
    }

    /// release drops one reference; the last holder frees the block and any un-picked-up
    /// result. Called by the render thread (deinit/orphan) and the worker on exit.
    fn release(sh: *Shared) void {
        sh.mutex.lockUncancelable(sh.io);
        sh.refs -= 1;
        const last = sh.refs == 0;
        if (last) {
            if (sh.ready) |l| l.deinit(sh.alloc);
            if (sh.req_path) |p| sh.alloc.free(p);
        }
        sh.mutex.unlock(sh.io);
        if (last) sh.alloc.destroy(sh);
    }

    /// request queues a directory to scan (render thread), superseding any pending
    /// or in-flight one. Non-blocking: just hands the path to the worker.
    pub fn request(self: *Scanner, path: []const u8) !void {
        const sh = self.shared orelse return;
        const dup = try self.alloc.dupe(u8, path);
        sh.mutex.lockUncancelable(sh.io);
        if (sh.req_path) |old| sh.alloc.free(old); // an unstarted request is stale now
        sh.req_path = dup;
        sh.req_gen += 1;
        @atomicStore(bool, &sh.abandon, true, .release); // the one being read is stale
        sh.mutex.unlock(sh.io);
        sh.cond.signal(sh.io);
    }

    /// poll returns a freshly-completed result at most once per completion,
    /// transferring ownership of the Listing to the caller. NON-BLOCKING: if the
    /// worker momentarily holds the lock, it returns null and we retry next frame.
    pub fn poll(self: *Scanner) ?Result {
        const sh = self.shared orelse return null;
        if (!sh.mutex.tryLock()) return null;
        defer sh.mutex.unlock(sh.io);
        if (sh.ready_gen == self.consumed_gen) return null; // nothing new
        self.consumed_gen = sh.ready_gen;
        if (sh.ready) |l| {
            sh.ready = null;
            return .{ .listing = l };
        }
        if (sh.ready_err) |e| {
            sh.ready_err = null;
            return .{ .err = e };
        }
        return null;
    }

    fn workerLoop(sh: *Shared) void {
        sh.mutex.lockUncancelable(sh.io);
        while (true) {
            while (sh.req_path == null and !@atomicLoad(bool, &sh.shutdown, .acquire))
                sh.cond.waitUncancelable(sh.io, &sh.mutex);
            if (@atomicLoad(bool, &sh.shutdown, .acquire)) {
                sh.mutex.unlock(sh.io);
                break;
            }
            const path = sh.req_path.?;
            sh.req_path = null;
            @atomicStore(bool, &sh.abandon, false, .release);
            const gen = sh.req_gen;
            sh.mutex.unlock(sh.io);

            // Blocking read happens WITHOUT the lock held (off the render thread).
            // The browser filters + sorts into its view; we deliver raw entries.
            //
            // NFS intermittently fails a directory open/read with a transient
            // EINVAL/EILSEQ (surfaced by Zig as error.BadPathName) for a directory that
            // is perfectly valid; re-issuing the read a moment later succeeds (which is
            // why manually leaving and re-entering the folder worked). Retry with an
            // exponential backoff (capped) so even a transient that lingers for the better
            // part of a second never reaches the user. This runs off the render thread and
            // a superseding navigation drops the result, so the extra latency is free.
            // Permanent errors (not-found, denied, not-a-dir, …) break out immediately.
            // The Recent place is a virtual folder with its own loader.
            // Names and kinds only: the folder shows at once, the details follow (details.zig).
            // Inside an archive (arcfs): listed from its index, nothing unpacked.
            var res = if (recent.dataHomeOf(path)) |data| recent.load(sh.io, sh.alloc, data) else arcfs.readAny(sh.io, sh.alloc, path, &sh.abandon, false);
            var attempt: u6 = 0;
            while (attempt < 6) : (attempt += 1) {
                if (res) |_| break else |e| switch (e) {
                    error.BadPathName => {}, // the transient NFS symptom → retry
                    else => break, // permanent (not-found, denied, not-a-dir, …)
                }
                // Bail out of the backoff immediately on teardown so an orphaned worker
                // exits fast instead of napping through the remaining ~1s of retries.
                if (@atomicLoad(bool, &sh.shutdown, .acquire)) break;
                // 20, 40, 80, 160, 320, 400 (capped) ms → ~1.0s total across 6 tries.
                napMs(@min(@as(u64, 20) << attempt, 400));
                res = scan.readDirOpts(sh.io, sh.alloc, path, &sh.abandon, false);
            }
            sh.alloc.free(path);

            sh.mutex.lockUncancelable(sh.io);
            if (@atomicLoad(bool, &sh.shutdown, .acquire)) {
                // Torn down while we were reading → drop the result and exit; nobody will
                // pick it up, and `release` (below) would double-free a slot we still hold.
                if (res) |l| l.deinit(sh.alloc) else |_| {}
                sh.mutex.unlock(sh.io);
                break;
            }
            if (gen == sh.req_gen) { // still the newest → publish
                if (sh.ready) |old| old.deinit(sh.alloc);
                sh.ready = null;
                sh.ready_err = null;
                if (res) |l| {
                    sh.ready = l;
                } else |e| {
                    sh.ready_err = e;
                }
                sh.ready_gen = gen;
            } else { // superseded while we were reading → drop it, loop for the newer
                if (res) |l| l.deinit(sh.alloc) else |_| {}
            }
            // Keep the lock held across the loop-back: the inner cond-wait at the top
            // requires it (unlocking here would leave waitUncancelable with an unlocked
            // mutex → panic). The break paths above unlock explicitly before leaving.
        }
        release(sh); // worker's ref; frees the block if the Scanner already orphaned/deinited
    }
};

/// napMs sleeps for `ms` milliseconds via raw nanosleep; the worker thread has no
/// render deadline, so a short backoff between retries of a transient read is free.
fn napMs(ms: u64) void {
    const ts = std.os.linux.timespec{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = std.os.linux.nanosleep(&ts, null);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "scanner reads a directory off-thread and delivers it via poll" {
    const a = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "" });
    try tmp.dir.createDirPath(io, "adir");
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);

    var s = Scanner.init(io, a);
    try s.start();
    defer s.deinit(); // joins the worker before `s` leaves scope

    try s.request(path);

    // Spin the non-blocking poll like the render loop would, bounded so a bug
    // fails the test instead of hanging.
    var result: ?Scanner.Result = null;
    var spins: usize = 0;
    while (result == null and spins < 100_000) : (spins += 1) {
        result = s.poll();
        if (result == null) std.Thread.yield() catch {};
    }

    try testing.expect(result != null);
    switch (result.?) {
        .listing => |l| {
            defer l.deinit(a);
            try testing.expectEqual(@as(usize, 2), l.entries.len);
            // Order is not asserted here: the worker delivers raw entries; the
            // browser filters + sorts. Just check both children arrived.
            var saw_dir = false;
            var saw_file = false;
            for (l.entries) |e| {
                if (std.mem.eql(u8, e.name, "adir") and e.isDir()) saw_dir = true;
                if (std.mem.eql(u8, e.name, "b.txt") and !e.isDir()) saw_file = true;
            }
            try testing.expect(saw_dir and saw_file);
        },
        .err => |e| {
            std.debug.print("unexpected scan error: {s}\n", .{@errorName(e)});
            return error.UnexpectedScanError;
        },
    }
}

test "orphan tears down without leaking even with a request in flight" {
    const a = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "x.txt", .data = "" });
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);

    var s = Scanner.init(io, a);
    try s.start();
    try s.request(path);
    // Detach immediately; the worker may still be mid-read. orphan must not block, and
    // the detached worker must free the shared block (last ref) so the testing allocator
    // reports no leak. We can't join a detached thread, so give it a moment to finish and
    // release; the refcount guarantees exactly one free regardless of who wins the race.
    s.orphan();
    var spins: usize = 0;
    while (spins < 200_000) : (spins += 1) std.Thread.yield() catch {};
}
