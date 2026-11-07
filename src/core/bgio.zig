//! The UI's own small disk work, off the render thread: writing its config files
//! (favourites, tags, recent folders, folder views), noticing another window changed
//! one, checking whether paths are there (is a favourite gone, is a dropped path a
//! folder), and the Trash window's listing, emptying, restoring and deleting. One worker takes jobs in order; the render thread asks and picks answers up
//! on a later frame, as for everything else that touches the disk. GUI-free.

const std = @import("std");
const FolderPrefs = @import("folderprefs.zig").FolderPrefs;
const trash = @import("trash.zig");

/// TrashAction is what the Trash window asked for; each is followed by a fresh listing.
pub const TrashAction = enum { list, empty, restore, remove };

/// Kind is what a probe found at a path.
pub const Kind = enum(u8) { missing, file, dir };

pub const Answer = union(enum) {
    probe: struct { id: u32, kinds: []Kind }, // in the order asked (owned)
    changed: struct { id: u32, mtime: i96, data: []u8 }, // a file's new content (owned)
    trash: []trash.Item, // the trash's contents after the last trash job (owned)

    pub fn deinit(a: Answer, alloc: std.mem.Allocator) void {
        switch (a) {
            .probe => |p| alloc.free(p.kinds),
            .changed => |c| alloc.free(c.data),
            .trash => |items| trash.free(alloc, items),
        }
    }
};

const Job = union(enum) {
    write: struct { path: []u8, data: []u8 },
    save_views: struct { path: []u8, prefs: *FolderPrefs },
    probe: struct { id: u32, paths: [][]u8 },
    if_changed: struct { id: u32, path: []u8, mtime: i96 },
    trash: struct { action: TrashAction, home: []u8, mounts: [][]u8, item: ?trash.Item },

    fn deinit(j: Job, alloc: std.mem.Allocator) void {
        switch (j) {
            .write => |w| {
                alloc.free(w.path);
                alloc.free(w.data);
            },
            .save_views => |s| {
                alloc.free(s.path);
                s.prefs.deinit();
                alloc.destroy(s.prefs);
            },
            .probe => |p| {
                for (p.paths) |x| alloc.free(x);
                alloc.free(p.paths);
            },
            .if_changed => |c| alloc.free(c.path),
            .trash => |t| {
                alloc.free(t.home);
                for (t.mounts) |m| alloc.free(m);
                alloc.free(t.mounts);
                if (t.item) |it| {
                    alloc.free(it.name);
                    alloc.free(it.orig_path);
                    alloc.free(it.trash_dir);
                }
            },
        }
    }
};

pub const Bg = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    wake: ?*const fn () void,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    // --- guarded by mutex ---
    jobs: std.ArrayList(Job) = .empty,
    answers: std.ArrayList(Answer) = .empty,
    shutdown: bool = false,
    // ------------------------
    thread: ?std.Thread = null,

    pub fn create(io: std.Io, alloc: std.mem.Allocator, wake: ?*const fn () void) !*Bg {
        const self = try alloc.create(Bg);
        self.* = .{ .io = io, .alloc = alloc, .wake = wake };
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |e| {
            alloc.destroy(self);
            return e;
        };
        return self;
    }

    /// destroy finishes the jobs already asked for (config writes must land), then stops.
    pub fn destroy(self: *Bg) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);
        if (self.thread) |t| t.join();
        for (self.jobs.items) |j| j.deinit(self.alloc);
        self.jobs.deinit(self.alloc);
        for (self.answers.items) |a| a.deinit(self.alloc);
        self.answers.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// write replaces file `path` with `data` (its folder made if need be).
    pub fn write(self: *Bg, path: []const u8, data: []const u8) void {
        const p = self.alloc.dupe(u8, path) catch return;
        const d = self.alloc.dupe(u8, data) catch return self.alloc.free(p);
        self.push(.{ .write = .{ .path = p, .data = d } });
    }

    /// saveViews merges `prefs` (taken: its changes only) into the folders file.
    pub fn saveViews(self: *Bg, path: []const u8, prefs: *FolderPrefs) void {
        const p = self.alloc.dupe(u8, path) catch {
            prefs.deinit();
            self.alloc.destroy(prefs);
            return;
        };
        self.push(.{ .save_views = .{ .path = p, .prefs = prefs } });
    }

    /// probe asks what's at each of `paths`; the answer comes back under `id`.
    pub fn probe(self: *Bg, id: u32, paths: []const []const u8) void {
        const list = self.alloc.alloc([]u8, paths.len) catch return;
        var n: usize = 0;
        for (paths) |p| {
            list[n] = self.alloc.dupe(u8, p) catch break;
            n += 1;
        }
        self.push(.{ .probe = .{ .id = id, .paths = list[0..n] } });
    }

    /// ifChanged reads `path` back (under `id`) when its mtime isn't `mtime` any more.
    pub fn ifChanged(self: *Bg, id: u32, path: []const u8, mtime: i96) void {
        const p = self.alloc.dupe(u8, path) catch return;
        self.push(.{ .if_changed = .{ .id = id, .path = p, .mtime = mtime } });
    }

    /// trashJob does `action` (to `item` for restore/remove; copied) in the trash at
    /// `home` and those on `mounts`, then lists them all (answered as .trash).
    pub fn trashJob(self: *Bg, action: TrashAction, home: []const u8, mounts: []const []const u8, item: ?trash.Item) void {
        const a = self.alloc;
        const h = a.dupe(u8, home) catch return;
        const ms = a.alloc([]u8, mounts.len) catch return a.free(h);
        var n: usize = 0;
        for (mounts) |m| {
            ms[n] = a.dupe(u8, m) catch break;
            n += 1;
        }
        const it: ?trash.Item = if (item) |x| .{
            .name = a.dupe(u8, x.name) catch return,
            .orig_path = a.dupe(u8, x.orig_path) catch return,
            .trash_dir = a.dupe(u8, x.trash_dir) catch return,
        } else null;
        self.push(.{ .trash = .{ .action = action, .home = h, .mounts = ms[0..n], .item = it } });
    }

    /// take hands over the next answer (render thread; caller deinits it).
    pub fn take(self: *Bg) ?Answer {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.answers.items.len == 0) return null;
        return self.answers.orderedRemove(0);
    }

    fn push(self: *Bg, j: Job) void {
        self.mutex.lockUncancelable(self.io);
        self.jobs.append(self.alloc, j) catch {
            self.mutex.unlock(self.io);
            return j.deinit(self.alloc);
        };
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);
    }

    fn answer(self: *Bg, a: Answer) void {
        self.mutex.lockUncancelable(self.io);
        self.answers.append(self.alloc, a) catch a.deinit(self.alloc);
        self.mutex.unlock(self.io);
        if (self.wake) |w| w();
    }

    fn run(self: *Bg) void {
        const cwd = std.Io.Dir.cwd();
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.jobs.items.len == 0 and !self.shutdown) self.cond.waitUncancelable(self.io, &self.mutex);
            if (self.jobs.items.len == 0) {
                self.mutex.unlock(self.io);
                return; // shut down, nothing left to write
            }
            const j = self.jobs.orderedRemove(0);
            self.mutex.unlock(self.io);
            defer j.deinit(self.alloc);
            switch (j) {
                .write => |w| {
                    if (std.fs.path.dirname(w.path)) |d| cwd.createDirPath(self.io, d) catch {};
                    cwd.writeFile(self.io, .{ .sub_path = w.path, .data = w.data }) catch {};
                },
                .save_views => |s| s.prefs.save(self.io, s.path),
                .probe => |p| {
                    const kinds = self.alloc.alloc(Kind, p.paths.len) catch continue;
                    for (p.paths, kinds) |path, *k| {
                        const st = cwd.statFile(self.io, path, .{}) catch {
                            k.* = .missing;
                            continue;
                        };
                        k.* = if (st.kind == .directory) .dir else .file;
                    }
                    self.answer(.{ .probe = .{ .id = p.id, .kinds = kinds } });
                },
                .trash => |t| {
                    const mounts: []const []const u8 = t.mounts;
                    switch (t.action) {
                        .list => {},
                        .empty => trash.empty(self.io, self.alloc, t.home, mounts),
                        .restore => if (t.item) |it| trash.restore(self.io, self.alloc, it) catch {},
                        .remove => if (t.item) |it| trash.remove(self.io, self.alloc, it) catch {},
                    }
                    self.answer(.{ .trash = trash.listAll(self.io, self.alloc, t.home, mounts) });
                },
                .if_changed => |c| {
                    const st = cwd.statFile(self.io, c.path, .{}) catch continue;
                    if (st.mtime.nanoseconds == c.mtime) continue;
                    const data = cwd.readFileAlloc(self.io, c.path, self.alloc, .limited(4 << 20)) catch continue;
                    self.answer(.{ .changed = .{ .id = c.id, .mtime = st.mtime.nanoseconds, .data = data } });
                },
            }
        }
    }
};
