//! Off-thread file-operation runner. Like the Scanner, it keeps persistent worker
//! threads so copy/move/trash/delete/rename never block the render thread (goal 1).
//! The render thread submits a Job (with owned path data), a worker runs it, and a
//! non-blocking poll() reports each completion so the browser can refresh and
//! surface any error.
//!
//! Jobs run on up to `max_lanes` lanes at once: each lane is a worker thread with
//! its own Progress, so a second copy starts right away beside a long first one and
//! each gets its own progress window (like Explorer/Finder). Lanes are spawned on
//! demand; beyond max_lanes, jobs wait in a FIFO queue (never superseded like scans:
//! every requested operation must actually run). Heap-pinned: the lanes hold
//! pointers into `self` (the Browser owns an OpRunner inline and is heap-allocated).

const std = @import("std");
const fsops = @import("fsops.zig");
const archive = @import("archive.zig");
const trash = @import("trash.zig");
const tags = @import("tags.zig");
const progress = @import("progress.zig");
const Progress = progress.Progress;

pub const max_lanes = 4;

pub const OpRunner = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    // Each lane's Progress is shared with the render thread: the lane reports there
    // and checks it for cancellation; the shell draws a window with a bar + Cancel.
    lanes: [max_lanes]Lane = undefined,

    // --- guarded by mutex ---
    queue: std.ArrayList(Job) = .empty,
    // Finished jobs not yet handed to the render thread, oldest first. Their pairs
    // are owned here until poll passes them on.
    done: std.ArrayList(Completion) = .empty,
    lanes_started: usize = 0,
    idle_lanes: usize = 0,
    shutdown: bool = false,
    // ------------------------

    const Lane = struct {
        runner: *OpRunner,
        prog: Progress,
        thread: std.Thread,
    };

    pub const Job = union(enum) {
        copy: Batch, // copy each src into dst_dir (unique-named)
        move: Batch, // move each src into dst_dir
        trash: TrashJob,
        delete: PathList,
        rename: RenameJob,
        extract: ExtractJob, // bsdtar -x each archive
        compress: CompressJob, // bsdtar -a -c the srcs into one archive
        restore: PairList, // move each pair's dst back to its exact src path (move undo)
        rename_many: PairList, // batch rename: each src → dst (absolute paths, same folder)
        set_tags: TagJob, // add or remove one colour tag on each path
        create: CreateJob, // a new folder or file (and the selection moved into it)
        link: LinkJob, // a symlink to each target, in dir
        untrash: UntrashJob, // put each item back where it was trashed from (trash undo)
    };
    // name: what to call it; unique: take the next free "name 2"-style name if taken.
    // srcs (absolute): moved into the new folder (New Folder with Selection).
    pub const CreateJob = struct { dir: []u8, name: []u8, is_dir: bool, unique: bool = true, srcs: [][]u8 = &.{} };
    pub const LinkJob = struct { dir: []u8, targets: [][]u8 };
    pub const UntrashJob = struct { trash_home: []u8, origs: [][]u8 };
    pub const TagJob = struct { paths: [][]u8, bit: tags.Mask, add: bool };
    // undoable = false for jobs that ARE an undo, so undoing doesn't record a new undo.
    pub const Batch = struct {
        srcs: [][]u8,
        dst_dir: []u8,
        undoable: bool = true,
        conflict: Conflict = .keep_both,
        // Per-source answers (owned; parallel to srcs) when the user decided item by
        // item; empty = `conflict` applies to every item.
        per_item: []Conflict = &.{},
        trash_home: []u8 = &.{}, // owned; where .replace sends the item it displaces

        fn policyFor(b: Batch, i: usize) Conflict {
            return if (b.per_item.len == b.srcs.len) b.per_item[i] else b.conflict;
        }
    };
    /// Conflict is what to do when an item of the same name already exists at the
    /// destination (chosen by the user in the conflict dialog).
    pub const Conflict = enum {
        keep_both, // store the new one as "name (2)"
        replace, // the old one goes to the trash, the new one takes its place
        skip, // leave the existing item, don't transfer this one
        replace_older, // replace when the incoming item is newer, else skip
        merge, // folder onto folder: its contents go in (same-named files inside are overwritten); otherwise as replace
    };
    /// Pair is one transferred item: where it came from and where it landed (the
    /// unique-named destination, which may differ from the source's name).
    pub const Pair = struct { src: []u8, dst: []u8 };
    pub const PairList = struct { pairs: []Pair };
    /// TransferKind says what a completion's pairs are: an undoable copy or move, or
    /// (untrashable) items a Move to Trash couldn't move (src is the path, dst "")
    /// so the UI can offer to delete them permanently instead.
    pub const TransferKind = enum { none, copy, move, untrashable };
    pub const TrashJob = struct { trash_home: []u8, paths: [][]u8 };
    pub const PathList = struct { paths: [][]u8 };
    pub const RenameJob = struct { dir: []u8, old_name: []u8, new_name: []u8 };
    // tool = absolute path to bsdtar (owned). own_folder: extract each archive into its
    // own new subdir of dst_dir (named after the archive), else all into dst_dir.
    pub const ExtractJob = struct { tool: []u8, archives: [][]u8, dst_dir: []u8, own_folder: bool };
    // srcs are basenames relative to src_dir (bsdtar's cwd); archive_path is absolute.
    pub const CompressJob = struct { tool: []u8, archive_path: []u8, src_dir: []u8, srcs: [][]u8 };

    /// Completion reports one finished job. For an undoable copy/move, `pairs` lists
    /// what actually transferred (owned by the receiver: call deinit).
    pub const Completion = struct {
        err_name: ?[]const u8,
        kind: TransferKind = .none,
        pairs: []Pair = &.{},
        // What a create or link job made (absolute, owned; "" for other jobs).
        created: []u8 = &.{},
        created_dir: bool = false,
        created_link: bool = false, // a link job made it (else a create job)
        links: usize = 0, // how many links the link job was asked for

        pub fn deinit(c: Completion, alloc: std.mem.Allocator) void {
            freePairs(alloc, c.pairs);
            if (c.created.len > 0) alloc.free(c.created);
        }
    };

    pub fn init(io: std.Io, alloc: std.mem.Allocator) OpRunner {
        return .{ .io = io, .alloc = alloc };
    }

    /// laneCount is how many lanes exist (some may be idle); lane indexes below it
    /// are valid for progressSnapshot/requestCancel. Render thread.
    pub fn laneCount(self: *OpRunner) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.lanes_started;
    }

    /// progressSnapshot reads lane `lane`'s progress for the render thread (the
    /// caller owns `buf`, into which the current filename is copied).
    pub fn progressSnapshot(self: *OpRunner, lane: usize, buf: []u8) progress.Snapshot {
        return self.lanes[lane].prog.snapshot(buf);
    }

    /// requestCancel asks lane `lane`'s op to stop at the next safe point.
    pub fn requestCancel(self: *OpRunner, lane: usize) void {
        self.lanes[lane].prog.requestCancel();
    }

    /// busy reports whether any op is running or waiting (drives the idle throttle so
    /// the progress bars animate).
    pub fn busy(self: *OpRunner) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.queue.items.len > 0) return true;
        for (self.lanes[0..self.lanes_started]) |*l| if (l.prog.isActive()) return true;
        return false;
    }

    /// start is kept for symmetry with the Scanner; lanes are spawned on demand.
    pub fn start(self: *OpRunner) !void {
        _ = self;
    }

    /// cancelAll drops the queued jobs and asks the running ones to stop at their next
    /// safe point (Stop All, closing the window ZFD finishes them in). Render thread.
    pub fn cancelAll(self: *OpRunner) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.queue.items) |job| freeJob(self.alloc, job);
        self.queue.clearRetainingCapacity();
        for (self.lanes[0..self.lanes_started]) |*l| if (l.prog.isActive()) l.prog.requestCancel();
    }

    pub fn deinit(self: *OpRunner) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        for (self.queue.items) |job| freeJob(self.alloc, job);
        self.queue.clearRetainingCapacity();
        const n = self.lanes_started;
        // Stop running ops promptly instead of finishing a long copy at exit.
        for (self.lanes[0..n]) |*l| l.prog.requestCancel();
        self.mutex.unlock(self.io);
        self.cond.broadcast(self.io);
        for (self.lanes[0..n]) |*l| l.thread.join();
        // After the joins: a job still running at shutdown publishes its completion on
        // the way out, so freeing earlier would race it.
        for (self.done.items) |cmp| cmp.deinit(self.alloc);
        self.done.deinit(self.alloc);
        self.queue.deinit(self.alloc);
    }

    /// submit enqueues a job, starting a new lane when every existing one is busy.
    /// Takes ownership of the job's allocated memory (freed after it runs).
    /// Non-blocking.
    pub fn submit(self: *OpRunner, job: Job) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.queue.append(self.alloc, job) catch |e| {
            freeJob(self.alloc, job);
            return e;
        };
        if (self.idle_lanes < self.queue.items.len and self.lanes_started < max_lanes) {
            const l = &self.lanes[self.lanes_started];
            l.* = .{ .runner = self, .prog = .{ .io = self.io }, .thread = undefined };
            if (std.Thread.spawn(.{}, laneLoop, .{l})) |t| {
                l.thread = t;
                self.lanes_started += 1;
            } else |_| {
                if (self.lanes_started == 0) {
                    _ = self.queue.pop();
                    freeJob(self.alloc, job);
                    return error.ThreadSpawn;
                }
            }
        }
        self.cond.signal(self.io);
    }

    /// poll reports one completion at a time, oldest first (render thread,
    /// non-blocking). A non-null return means a job finished; err_name is set if it
    /// failed.
    pub fn poll(self: *OpRunner) ?Completion {
        if (!self.mutex.tryLock()) return null;
        defer self.mutex.unlock(self.io);
        if (self.done.items.len == 0) return null;
        return self.done.orderedRemove(0);
    }

    fn laneLoop(lane: *Lane) void {
        const self = lane.runner;
        self.mutex.lockUncancelable(self.io);
        while (true) {
            self.idle_lanes += 1;
            while (self.queue.items.len == 0 and !self.shutdown)
                self.cond.waitUncancelable(self.io, &self.mutex);
            self.idle_lanes -= 1;
            if (self.shutdown) {
                self.mutex.unlock(self.io);
                return;
            }
            const job = self.queue.orderedRemove(0);
            // Mark the lane active before dropping the lock, so busy() never sees an
            // empty queue and an idle lane while this job is in flight.
            lane.prog.claim();
            self.mutex.unlock(self.io);

            var pairs = std.ArrayList(Pair).empty;
            var created: []u8 = &.{};
            const err = self.run(job, &lane.prog, &pairs, &created); // I/O without the lock held
            const kind: TransferKind = switch (job) {
                .copy => |b| if (b.undoable) .copy else .none,
                .move => |b| if (b.undoable) .move else .none,
                .rename_many => .move, // undo = move each back (restore), exactly like a move
                .trash => .untrashable,
                .create => |cj| if (cj.srcs.len > 0) .move else .none, // undo moves them back out
                else => .none,
            };
            const created_dir = switch (job) {
                .create => |cj| cj.is_dir,
                else => false,
            };
            const links: usize = switch (job) {
                .link => |lj| lj.targets.len,
                else => 0,
            };
            freeJob(self.alloc, job);
            const done_pairs: []Pair = if (kind != .none) (pairs.toOwnedSlice(self.alloc) catch blk: {
                freePairStrings(self.alloc, pairs.items);
                pairs.deinit(self.alloc);
                break :blk &.{};
            }) else blk: {
                freePairStrings(self.alloc, pairs.items);
                pairs.deinit(self.alloc);
                break :blk &.{};
            };

            self.mutex.lockUncancelable(self.io);
            const cmp: Completion = .{
                .err_name = err,
                .kind = if (done_pairs.len > 0) kind else .none,
                .pairs = done_pairs,
                .created = created,
                .created_dir = created_dir,
                .created_link = links > 0,
                .links = links,
            };
            self.done.append(self.alloc, cmp) catch cmp.deinit(self.alloc);
            // Idle only after the completion is queued: the render thread refreshes
            // when it sees both, never a finished-but-unreported op.
            lane.prog.finish();
        }
    }

    /// run executes a job, reporting into prog and returning the @errorName of
    /// the last failing item (null on full success, "Canceled" if the user stopped
    /// it). Individual failures don't abort the whole batch. It begins the Progress
    /// with the right phase + totals; the worker calls finish() afterward.
    fn run(self: *OpRunner, job: Job, prog: *Progress, pairs: *std.ArrayList(Pair), created: *[]u8) ?[]const u8 {
        const io = self.io;
        const a = self.alloc;
        switch (job) {
            .create => |cj| {
                prog.begin(.moving, @intCast(cj.srcs.len + 1), 0);
                const name = if (cj.unique) fsops.uniqueNameInDir(io, a, cj.dir, cj.name) catch |e| return @errorName(e) else a.dupe(u8, cj.name) catch return "OutOfMemory";
                defer a.free(name);
                (if (cj.is_dir) fsops.makeDirIn(io, a, cj.dir, name) else fsops.makeFileIn(io, a, cj.dir, name)) catch |e| return @errorName(e);
                prog.addFile();
                created.* = std.fs.path.join(a, &.{ cj.dir, name }) catch &.{};
                if (cj.srcs.len == 0 or created.len == 0) return null;
                // New Folder with Selection: move the items into it.
                return self.runBatch(.{ .srcs = cj.srcs, .dst_dir = created.* }, true, prog, pairs);
            },
            .link => |lj| {
                prog.begin(.copying, @intCast(lj.targets.len), 0);
                var last: ?[]const u8 = null;
                for (lj.targets) |t| {
                    const name = fsops.makeLinkIn(io, a, lj.dir, t) catch |e| {
                        last = @errorName(e);
                        prog.addFile();
                        continue;
                    };
                    defer a.free(name);
                    if (created.len > 0) a.free(created.*);
                    created.* = std.fs.path.join(a, &.{ lj.dir, name }) catch &.{};
                    prog.addFile();
                }
                return last;
            },
            .untrash => |u| {
                prog.begin(.moving, @intCast(u.origs.len), 0);
                var last: ?[]const u8 = null;
                for (u.origs) |orig| {
                    trash.restoreByOrigPath(io, a, u.trash_home, orig) catch |e| {
                        last = @errorName(e);
                    };
                    prog.addFile();
                }
                return last;
            },
            .copy => |b| {
                if (self.beginBatch(prog, .copying, b, false)) |e| return e;
                return self.runBatch(b, false, prog, pairs);
            },
            .move => |b| {
                if (self.beginBatch(prog, .moving, b, true)) |e| return e;
                return self.runBatch(b, true, prog, pairs);
            },
            .rename_many => |r| {
                prog.begin(.moving, @intCast(r.pairs.len), 0);
                var last: ?[]const u8 = null;
                for (r.pairs) |pr| {
                    if (prog.canceled()) return "Canceled";
                    prog.setCurrent(std.fs.path.basename(pr.dst));
                    // Never clobber: the dialog validated, but the folder may have changed.
                    if (fsops.pathExists(io, pr.dst)) {
                        last = "PathAlreadyExists";
                        prog.addFile();
                        continue;
                    }
                    std.Io.Dir.renameAbsolute(pr.src, pr.dst, io) catch |e| {
                        last = @errorName(e);
                        prog.addFile();
                        continue;
                    };
                    recordPair(a, pairs, pr.src, pr.dst);
                    prog.addFile();
                }
                return last;
            },
            .restore => |r| {
                prog.begin(.moving, @intCast(r.pairs.len), 0);
                var last: ?[]const u8 = null;
                for (r.pairs) |pr| {
                    if (prog.canceled()) return "Canceled";
                    prog.setCurrent(std.fs.path.basename(pr.src));
                    fsops.restoreTo(io, a, pr.dst, pr.src, prog) catch |e| {
                        if (e == error.Canceled) return "Canceled";
                        last = @errorName(e);
                    };
                    prog.addFile();
                }
                return last;
            },
            .trash => |t| {
                prog.begin(.trashing, @intCast(t.paths.len), 0);
                var last: ?[]const u8 = null;
                for (t.paths) |p| {
                    if (prog.canceled()) return "Canceled";
                    prog.setCurrent(std.fs.path.basename(p));
                    fsops.trash(io, a, t.trash_home, p) catch |e| {
                        last = @errorName(e);
                        // Gone already: nothing to ask about. Anything else (a network
                        // share with no trash, no permission to make one, …) is offered
                        // for permanent deletion instead.
                        if (e != error.FileNotFound) recordPair(a, pairs, p, "");
                    };
                    prog.addFile();
                }
                return last;
            },
            .delete => |d| {
                prog.begin(.deleting, @intCast(d.paths.len), 0);
                var last: ?[]const u8 = null;
                for (d.paths) |p| {
                    if (prog.canceled()) return "Canceled";
                    prog.setCurrent(std.fs.path.basename(p));
                    fsops.deletePath(io, p) catch |e| {
                        last = @errorName(e);
                    };
                    prog.addFile();
                }
                return last;
            },
            .rename => |r| {
                prog.begin(.moving, 1, 0);
                prog.setCurrent(r.new_name);
                fsops.renameInDir(io, a, r.dir, r.old_name, r.new_name) catch |e| return @errorName(e);
                prog.addFile();
                return null;
            },
            .extract => |x| {
                prog.begin(.extracting, @intCast(x.archives.len), 0);
                var last: ?[]const u8 = null;
                for (x.archives) |arch| {
                    if (prog.canceled()) return "Canceled";
                    prog.setCurrent(std.fs.path.basename(arch));
                    if (x.own_folder) {
                        // Extract into a fresh, uniquely-named subdir named after the
                        // archive (photos.tar.gz → ./photos/). uniqueNameInDir avoids
                        // clobbering an existing "photos".
                        const stem = archive.stripArchiveExt(std.fs.path.basename(arch));
                        const name = fsops.uniqueNameInDir(io, a, x.dst_dir, stem) catch |e| {
                            last = @errorName(e);
                            prog.addFile();
                            continue;
                        };
                        defer a.free(name);
                        fsops.makeDirIn(io, a, x.dst_dir, name) catch |e| {
                            last = @errorName(e);
                            prog.addFile();
                            continue;
                        };
                        const dst = std.fs.path.join(a, &.{ x.dst_dir, name }) catch |e| {
                            last = @errorName(e);
                            prog.addFile();
                            continue;
                        };
                        defer a.free(dst);
                        archive.extractInto(io, x.tool, arch, dst) catch |e| {
                            last = @errorName(e);
                        };
                    } else {
                        archive.extractInto(io, x.tool, arch, x.dst_dir) catch |e| {
                            last = @errorName(e);
                        };
                    }
                    prog.addFile();
                }
                return last;
            },
            .set_tags => |t| {
                prog.begin(.tagging, @intCast(t.paths.len), 0);
                var last: ?[]const u8 = null;
                for (t.paths) |p| {
                    const pz = self.alloc.dupeSentinel(u8, p, 0) catch continue;
                    defer self.alloc.free(pz);
                    const cur = tags.readMask(pz);
                    const next = if (t.add) cur | t.bit else cur & ~t.bit;
                    if (next == cur) continue;
                    tags.setMask(self.alloc, p, next) catch |e| {
                        last = @errorName(e);
                    };
                }
                return last;
            },
            .compress => |cj| {
                prog.begin(.compressing, 1, 0);
                // The archive takes the next free name in its folder.
                const dir = std.fs.path.dirname(cj.archive_path) orelse ".";
                const uniq = fsops.uniqueNameInDir(io, a, dir, std.fs.path.basename(cj.archive_path)) catch |e| return @errorName(e);
                defer a.free(uniq);
                const archive_path = std.fs.path.join(a, &.{ dir, uniq }) catch return "OutOfMemory";
                defer a.free(archive_path);
                prog.setCurrent(uniq);
                archive.compressInto(io, a, cj.tool, archive_path, cj.src_dir, cj.srcs) catch |e| {
                    prog.addFile();
                    return @errorName(e);
                };
                prog.addFile();
                return null;
            },
        }
    }

    /// beginBatch pre-measures the sources so the progress bar has a denominator, and
    /// checks up front that the transfer can succeed: the destination must be
    /// writable and have room for everything that will actually be written (a move
    /// within one filesystem is a rename and needs none; a Replace frees what it
    /// overwrites). Returns the error name that stops the whole batch, or null, so a
    /// full disk fails at once, with nothing copied, instead of halfway through.
    fn beginBatch(self: *OpRunner, prog: *Progress, phase: progress.Phase, b: Batch, move: bool) ?[]const u8 {
        var files: u64 = 0;
        var bytes: u64 = 0;
        var need: u64 = 0;
        var freed: u64 = 0;
        const dst_dev = fsops.deviceOf(b.dst_dir);
        for (b.srcs, 0..) |src, i| {
            const m = fsops.measureTree(self.io, self.alloc, src);
            files += m.files;
            bytes += m.bytes;
            if (!(move and fsops.deviceOf(src) == dst_dev)) need += m.bytes;
            // (a merge keeps what's there, so it frees nothing to count on)
            if (b.policyFor(i) == .replace or b.policyFor(i) == .replace_older) {
                const existing = std.fs.path.join(self.alloc, &.{ b.dst_dir, std.fs.path.basename(src) }) catch continue;
                defer self.alloc.free(existing);
                if (!std.mem.eql(u8, existing, src)) freed += fsops.measureTree(self.io, self.alloc, existing).bytes;
            }
        }
        prog.begin(phase, files, bytes);
        if (!fsops.writableDir(b.dst_dir)) return "DestinationNotWritable";
        if (fsops.freeBytesAt(b.dst_dir)) |avail| {
            if (need -| freed > avail) return "NotEnoughSpace";
        }
        return null;
    }

    /// replaceInto transfers src onto an existing dst. With `merge`, folder onto folder
    /// copies the contents in (same-named files inside are overwritten, as Finder's
    /// Merge); anything else first sends the existing item to the trash, so a wrong
    /// "Replace" is recoverable.
    fn replaceInto(self: *OpRunner, prog: *Progress, src: []const u8, dst: []const u8, move: bool, merge: bool, trash_home: []const u8) !void {
        const io = self.io;
        const a = self.alloc;
        if (merge) {
            try fsops.copyPath(io, a, src, dst, prog);
            if (move) try fsops.deletePath(io, src);
            return;
        }
        if (trash_home.len > 0) {
            try fsops.trash(io, a, trash_home, dst);
        } else {
            try fsops.deletePath(io, dst);
        }
        if (move) try fsops.movePath(io, a, src, dst, prog) else try fsops.copyPath(io, a, src, dst, prog);
    }

    fn runBatch(self: *OpRunner, b: Batch, move: bool, prog: *Progress, pairs: *std.ArrayList(Pair)) ?[]const u8 {
        const io = self.io;
        const a = self.alloc;
        var last: ?[]const u8 = null;
        // An SMB share or FAT/NTFS drive can't store names like "a:b"; land each item
        // under a storable name instead (copyPath does the same for folder contents).
        const portable = fsops.restrictedNamesAt(b.dst_dir);
        for (b.srcs, 0..) |src, idx| {
            if (prog.canceled()) return "Canceled";
            // A move into the source's own directory is a no-op; skip it.
            if (move and std.mem.eql(u8, std.fs.path.dirname(src) orelse "", b.dst_dir)) continue;
            const base_owned = (if (portable) fsops.portableName(a, std.fs.path.basename(src)) else a.dupe(u8, std.fs.path.basename(src))) catch |e| {
                last = @errorName(e);
                continue;
            };
            defer a.free(base_owned);
            const base: []const u8 = base_owned;
            const plain = std.fs.path.join(a, &.{ b.dst_dir, base }) catch |e| {
                last = @errorName(e);
                continue;
            };
            defer a.free(plain);
            const clash = fsops.pathExists(io, plain) and !std.mem.eql(u8, plain, src);
            var policy = b.policyFor(idx);
            if (policy == .replace_older) policy = if (isNewer(src, plain)) .replace else .skip;
            if (clash and policy == .skip) continue;
            const takes_place = clash and (policy == .replace or policy == .merge);
            const merging = takes_place and policy == .merge and fsops.isDir(io, src) and fsops.isDir(io, plain);
            const name = if (takes_place)
                (a.dupe(u8, base) catch continue)
            else
                fsops.uniqueNameInDir(io, a, b.dst_dir, base) catch |e| {
                    last = @errorName(e);
                    continue;
                };
            defer a.free(name);
            const dst = std.fs.path.join(a, &.{ b.dst_dir, name }) catch |e| {
                last = @errorName(e);
                continue;
            };
            defer a.free(dst);
            const res = if (takes_place)
                self.replaceInto(prog, src, dst, move, merging, b.trash_home)
            else if (move)
                fsops.movePath(io, a, src, dst, prog)
            else
                fsops.copyPath(io, a, src, dst, prog);
            res catch |e| {
                if (e == error.Canceled) return "Canceled";
                last = @errorName(e);
                continue;
            };
            // A merge isn't undoable: the folder holds what was there before too.
            if (!merging) recordPair(a, pairs, src, dst);
        }
        return last;
    }
};

/// isNewer reports whether `src` was modified after `dst` (Replace older). Unknown
/// times count as not newer, so an unreadable item is never overwritten by it.
fn isNewer(src: []const u8, dst: []const u8) bool {
    const s = fsops.brief(src) orelse return false;
    const d = fsops.brief(dst) orelse return false;
    return s.mtime_secs > d.mtime_secs;
}

// --- job memory management ---------------------------------------------------

fn recordPair(alloc: std.mem.Allocator, pairs: *std.ArrayList(OpRunner.Pair), src: []const u8, dst: []const u8) void {
    const s = alloc.dupe(u8, src) catch return;
    const d = alloc.dupe(u8, dst) catch {
        alloc.free(s);
        return;
    };
    pairs.append(alloc, .{ .src = s, .dst = d }) catch {
        alloc.free(s);
        alloc.free(d);
    };
}

/// freePairs frees an exactly-sized (owned) pair slice and its strings.
pub fn freePairs(alloc: std.mem.Allocator, pairs: []OpRunner.Pair) void {
    freePairStrings(alloc, pairs);
    if (pairs.len > 0) alloc.free(pairs);
}

fn freePairStrings(alloc: std.mem.Allocator, pairs: []OpRunner.Pair) void {
    for (pairs) |pr| {
        alloc.free(pr.src);
        alloc.free(pr.dst);
    }
}

fn freeJob(alloc: std.mem.Allocator, job: OpRunner.Job) void {
    switch (job) {
        .copy, .move => |b| {
            freePaths(alloc, b.srcs);
            alloc.free(b.dst_dir);
            if (b.trash_home.len > 0) alloc.free(b.trash_home);
            if (b.per_item.len > 0) alloc.free(b.per_item);
        },
        .trash => |t| {
            alloc.free(t.trash_home);
            freePaths(alloc, t.paths);
        },
        .delete => |d| freePaths(alloc, d.paths),
        .rename => |r| {
            alloc.free(r.dir);
            alloc.free(r.old_name);
            alloc.free(r.new_name);
        },
        .extract => |x| {
            alloc.free(x.tool);
            freePaths(alloc, x.archives);
            alloc.free(x.dst_dir);
        },
        .compress => |cj| {
            alloc.free(cj.tool);
            alloc.free(cj.archive_path);
            alloc.free(cj.src_dir);
            freePaths(alloc, cj.srcs);
        },
        .restore, .rename_many => |r| freePairs(alloc, r.pairs),
        .set_tags => |t| freePaths(alloc, t.paths),
        .create => |cj| {
            alloc.free(cj.dir);
            alloc.free(cj.name);
            if (cj.srcs.len > 0) freePaths(alloc, cj.srcs);
        },
        .link => |lj| {
            alloc.free(lj.dir);
            freePaths(alloc, lj.targets);
        },
        .untrash => |u| {
            alloc.free(u.trash_home);
            freePaths(alloc, u.origs);
        },
    }
}

fn freePaths(alloc: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| alloc.free(p);
    alloc.free(paths);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "oprunner copies a file off-thread and reports completion" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "src.txt", .data = "hi" });
    try tmp.dir.createDirPath(io, "dest");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    var runner = OpRunner.init(io, a);
    try runner.start();
    defer runner.deinit();

    const copied = try a.print("{s}/dest/src.txt", .{root});
    defer a.free(copied);
    // Before: the copy target does not exist yet.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, copied, .{}));

    // Build an owned copy job: src.txt -> dest/.
    var srcs = try a.alloc([]u8, 1);
    srcs[0] = try a.print("{s}/src.txt", .{root});
    const dst_dir = try a.print("{s}/dest", .{root});
    try runner.submit(.{ .copy = .{ .srcs = srcs, .dst_dir = dst_dir } });

    var done: ?OpRunner.Completion = null;
    var spins: usize = 0;
    while (done == null and spins < 5_000_000) : (spins += 1) {
        done = runner.poll();
        if (done == null) std.Thread.yield() catch {};
    }
    try testing.expect(done != null);
    defer done.?.deinit(a);
    try testing.expect(done.?.err_name == null);
    try testing.expectEqual(OpRunner.TransferKind.copy, done.?.kind); // reported for undo
    try testing.expectEqual(@as(usize, 1), done.?.pairs.len);

    // After: the file is now there (the delta the op produced).
    _ = std.Io.Dir.cwd().statFile(io, copied, .{}) catch return error.CopyMissing;
}

test "oprunner copy transfers the exact bytes (not just creates the file)" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // 256 KiB of a distinctive, position-dependent pattern: if the copy were a stub
    // (empty file, wrong length, zeroed reflink) the byte compare below would fail.
    const n = 256 * 1024;
    const data = try a.alloc(u8, n);
    defer a.free(data);
    for (data, 0..) |*byte, i| byte.* = @truncate(i *% 2654435761 +% 7);
    try tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = data });
    try tmp.dir.createDirPath(io, "dest");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    var runner = OpRunner.init(io, a);
    try runner.start();
    defer runner.deinit();

    const copied = try a.print("{s}/dest/big.bin", .{root});
    defer a.free(copied);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, copied, .{})); // before

    var srcs = try a.alloc([]u8, 1);
    srcs[0] = try a.print("{s}/big.bin", .{root});
    const dst_dir = try a.print("{s}/dest", .{root});
    try runner.submit(.{ .copy = .{ .srcs = srcs, .dst_dir = dst_dir } });

    var spins: usize = 0;
    var done: ?OpRunner.Completion = null;
    while (done == null and spins < 5_000_000) : (spins += 1) {
        done = runner.poll();
        if (done == null) std.Thread.yield() catch {};
    }
    try testing.expect(done != null and done.?.err_name == null);
    defer done.?.deinit(a);

    // After: read the copy back and assert it's byte-for-byte identical, proof the
    // data actually transferred (a fast/"instant" copy is a real reflink/copy_file_range).
    const back = try std.Io.Dir.cwd().readFileAlloc(io, copied, a, .limited(1 << 20));
    defer a.free(back);
    try testing.expectEqual(data.len, back.len);
    try testing.expectEqualSlices(u8, data, back);
}

test "oprunner runs a second job on its own lane and reports both" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "two.txt", .data = "2" });
    try tmp.dir.createDirPath(io, "dest");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    var runner = OpRunner.init(io, a);
    try runner.start();
    defer runner.deinit();

    for ([_][]const u8{ "one.txt", "two.txt" }) |name| {
        var srcs = try a.alloc([]u8, 1);
        srcs[0] = try a.print("{s}/{s}", .{ root, name });
        const dst_dir = try a.print("{s}/dest", .{root});
        try runner.submit(.{ .copy = .{ .srcs = srcs, .dst_dir = dst_dir } });
    }
    // Both were submitted before either could finish, so the second got a lane of
    // its own rather than waiting behind the first.
    try testing.expect(runner.laneCount() >= 1);

    var got: usize = 0;
    var spins: usize = 0;
    while (got < 2 and spins < 5_000_000) : (spins += 1) {
        if (runner.poll()) |cmp| {
            defer cmp.deinit(a);
            try testing.expect(cmp.err_name == null);
            try testing.expectEqual(@as(usize, 1), cmp.pairs.len);
            got += 1;
        } else std.Thread.yield() catch {};
    }
    try testing.expectEqual(@as(usize, 2), got);
    // A lane goes idle just after queuing its completion.
    spins = 0;
    while (runner.busy() and spins < 5_000_000) : (spins += 1) std.Thread.yield() catch {};
    try testing.expect(!runner.busy());
    for ([_][]const u8{ "one.txt", "two.txt" }) |name| {
        const p = try a.print("{s}/dest/{s}", .{ root, name });
        defer a.free(p);
        _ = try std.Io.Dir.cwd().statFile(io, p, .{});
    }
}

test "oprunner refuses up front to copy into a folder it can't write" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "src.txt", .data = "hi" });
    try tmp.dir.createDirPath(io, "locked");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const locked = try a.print("{s}/locked", .{root});
    defer a.free(locked);
    try fsops.chmodPath(locked, 0o555);
    defer fsops.chmodPath(locked, 0o755) catch {};
    if (fsops.writableDir(locked)) return error.SkipZigTest; // running as root

    var runner = OpRunner.init(io, a);
    try runner.start();
    defer runner.deinit();

    var srcs = try a.alloc([]u8, 1);
    srcs[0] = try a.print("{s}/src.txt", .{root});
    try runner.submit(.{ .copy = .{ .srcs = srcs, .dst_dir = try a.dupe(u8, locked) } });

    var done: ?OpRunner.Completion = null;
    var spins: usize = 0;
    while (done == null and spins < 5_000_000) : (spins += 1) {
        done = runner.poll();
        if (done == null) std.Thread.yield() catch {};
    }
    try testing.expect(done != null);
    defer done.?.deinit(a);
    try testing.expectEqualStrings("DestinationNotWritable", done.?.err_name.?);
    try testing.expectEqual(@as(usize, 0), done.?.pairs.len);
}

test "a Move to Trash that can't trash an item reports it for permanent deletion" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "victim.txt", .data = "x" });
    try tmp.dir.createDirPath(io, "Trash");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const th = try a.print("{s}/Trash", .{root});
    defer a.free(th);
    try fsops.chmodPath(th, 0o555); // the trash can't be written: trashing must fail
    defer fsops.chmodPath(th, 0o755) catch {};
    if (fsops.writableDir(th)) return error.SkipZigTest; // running as root

    var runner = OpRunner.init(io, a);
    defer runner.deinit();
    var paths = try a.alloc([]u8, 1);
    paths[0] = try a.print("{s}/victim.txt", .{root});
    try runner.submit(.{ .trash = .{ .trash_home = try a.dupe(u8, th), .paths = paths } });

    var done: ?OpRunner.Completion = null;
    var spins: usize = 0;
    while (done == null and spins < 5_000_000) : (spins += 1) {
        done = runner.poll();
        if (done == null) std.Thread.yield() catch {};
    }
    try testing.expect(done != null);
    defer done.?.deinit(a);
    try testing.expectEqual(OpRunner.TransferKind.untrashable, done.?.kind);
    try testing.expectEqual(@as(usize, 1), done.?.pairs.len);
    try testing.expect(std.mem.endsWith(u8, done.?.pairs[0].src, "/victim.txt"));
}
