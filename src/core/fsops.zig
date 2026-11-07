//! Filesystem name helpers + the actual file operations, ported from the Go
//! `internal/fsops`. The pure, allocation-light part (extension handling and
//! collision-free naming) is unit-tested against the Go originals; below it are the
//! real move/copy/delete/trash syscalls (run on the op-runner's worker thread, never
//! the render thread) and the detached launchers for xdg-open / a terminal.

const std = @import("std");
const Progress = @import("progress.zig").Progress;
const StatFs = @import("scan.zig").StatFs;
const tags = @import("tags.zig");
const comments = @import("comments.zig");
const Dir = std.Io.Dir;

/// ext is the extension of a base name: the suffix from its final dot (".gz" for
/// "a.tar.gz"), matching Go's filepath.Ext. No dot → empty. A leading-dot dotfile
/// (".bashrc") counts wholly as the extension, per filepath.Ext. Assumes a base
/// name (no path separators).
pub fn ext(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |d| return name[d..];
    return name[name.len..];
}

/// withExt replaces name's extension with new_ext (e.g. ".png"). An empty name or
/// new_ext is returned unchanged (as an owned dupe). Caller frees.
pub fn withExt(alloc: std.mem.Allocator, name: []const u8, new_ext: []const u8) ![]u8 {
    if (name.len == 0 or new_ext.len == 0) return alloc.dupe(u8, name);
    const e = ext(name);
    const base = name[0 .. name.len - e.len];
    return alloc.print("{s}{s}", .{ base, new_ext });
}

/// uniqueName returns a name not colliding with any entry in `existing`, inserting
/// " (copy)", " (copy 2)", … before the extension as needed. Pure: the caller
/// supplies the directory's current names (the filesystem wrapper reads them). The
/// result is owned by the caller.
pub fn uniqueName(alloc: std.mem.Allocator, existing: []const []const u8, name: []const u8) ![]u8 {
    if (!contains(existing, name)) return alloc.dupe(u8, name);
    const e = ext(name);
    const base = name[0 .. name.len - e.len];
    var i: usize = 1;
    while (true) : (i += 1) {
        const cand = if (i == 1)
            try alloc.print("{s} (copy){s}", .{ base, e })
        else
            try alloc.print("{s} (copy {d}){s}", .{ base, i, e });
        if (!contains(existing, cand)) return cand;
        alloc.free(cand);
    }
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |e| {
        if (std.mem.eql(u8, e, s)) return true;
    }
    return false;
}

// --- filesystem operations ---------------------------------------------------
// These do real I/O (via the 0.16 std.Io.Dir API) and are meant to run on the
// op-runner's worker thread, never the render thread (goal 1). All paths are
// absolute. Tested against temp directories.

/// Measure is the size of a tree (recursive): a file count and total bytes, used to
/// prime a Progress before a copy so the bar has a denominator.
pub const Measure = struct { files: u64 = 0, bytes: u64 = 0 };

/// measureTree walks src and sums regular-file count and bytes. Best-effort: entries
/// it can't stat are skipped (they'll surface as errors during the actual copy).
pub fn measureTree(io: std.Io, alloc: std.mem.Allocator, src: []const u8) Measure {
    const cwd = Dir.cwd();
    const st = cwd.statFile(io, src, .{}) catch return .{};
    if (st.kind != .directory) return .{ .files = 1, .bytes = st.size };
    var m = Measure{};
    var d = cwd.openDir(io, src, .{ .iterate = true }) catch return m;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        const child = std.fs.path.join(alloc, &.{ src, e.name }) catch continue;
        defer alloc.free(child);
        const cm = measureTree(io, alloc, child);
        m.files += cm.files;
        m.bytes += cm.bytes;
    }
    return m;
}

/// copyPath recursively copies src to dst, reporting into `prog` (per file) and
/// honoring cancellation between entries; returns error.Canceled if asked to stop.
/// Directories are recreated and their contents copied; symlinks are followed (a
/// cyclic symlink would loop; a guard is a later refinement). dst's parent must
/// exist. `prog` may be null (no progress/cancel, e.g. tests).
pub fn copyPath(io: std.Io, alloc: std.mem.Allocator, src: []const u8, dst: []const u8, prog: ?*Progress) !void {
    const portable = restrictedNamesAt(std.fs.path.dirname(dst) orelse "/");
    return copyTree(io, alloc, src, dst, prog, portable);
}

/// copyTree is copyPath's recursion. With `portable` set (the destination is an SMB
/// share or a FAT/NTFS/exFAT drive) each child is written under portableName, since
/// those filesystems refuse names like "a:b", and the kernel reports that refusal as
/// "file not found", which used to fail the whole item with a baffling error.
fn copyTree(io: std.Io, alloc: std.mem.Allocator, src: []const u8, dst: []const u8, prog: ?*Progress, portable: bool) !void {
    if (prog) |p| {
        if (p.canceled()) return error.Canceled;
    }
    const cwd = Dir.cwd();
    const st = try cwd.statFile(io, src, .{}); // follow symlinks
    if (st.kind == .directory) {
        try cwd.createDirPath(io, dst);
        var d = try cwd.openDir(io, src, .{ .iterate = true });
        defer d.close(io);
        var it = d.iterate();
        while (try it.next(io)) |e| {
            const child_src = try std.fs.path.join(alloc, &.{ src, e.name });
            defer alloc.free(child_src);
            const child_name = if (portable) try portableName(alloc, e.name) else try alloc.dupe(u8, e.name);
            defer alloc.free(child_name);
            const child_dst = try std.fs.path.join(alloc, &.{ dst, child_name });
            defer alloc.free(child_dst);
            try copyTree(io, alloc, child_src, child_dst, prog, portable);
        }
    } else if (st.kind == .file) {
        if (prog) |p| p.setCurrent(std.fs.path.basename(src));
        try copyFileChunked(io, alloc, src, dst, st.permissions, prog, copy_chunk);
        copyTags(alloc, src, dst);
        if (prog) |p| p.addFile();
    } else {
        // Not a regular file (FIFO, device node…): no byte stream worth chunking.
        if (prog) |p| p.setCurrent(std.fs.path.basename(src));
        try cwd.copyFile(src, cwd, dst, io, .{});
        if (prog) |p| p.addFile();
    }
}

/// copyTags carries the tags (user.xdg.tags) and the comment (user.xdg.comment) over
/// to a copy, as Finder does. Best-effort: a destination without xattr support just
/// loses them.
fn copyTags(alloc: std.mem.Allocator, src: []const u8, dst: []const u8) void {
    const sz = alloc.dupeSentinel(u8, src, 0) catch return;
    defer alloc.free(sz);
    const dz = alloc.dupeSentinel(u8, dst, 0) catch return;
    defer alloc.free(dz);
    for ([_][:0]const u8{ tags.attr_name, comments.attr_name }) |name| {
        var buf: [4096]u8 = undefined;
        const rc = std.os.linux.lgetxattr(sz.ptr, name, &buf, buf.len);
        if (std.os.linux.errno(rc) != .SUCCESS or rc == 0) continue;
        _ = std.os.linux.lsetxattr(dz.ptr, name, &buf, rc, 0);
    }
}

/// Bytes moved per copy step. Small enough that Cancel answers within a fraction of a
/// second on a slow disk and the byte bar moves smoothly; large enough that the extra
/// syscalls cost nothing next to the I/O.
const copy_chunk: usize = 8 << 20;

/// copyFileChunked copies one regular file in `chunk`-sized steps, reporting bytes and
/// checking for cancellation between steps, so a multi-GB file can be stopped
/// mid-copy instead of Cancel waiting for the whole file. Uses copy_file_range (in-
/// kernel, and server-side on NFS/CIFS when supported), falling back to read/write
/// where the kernel refuses (cross-filesystem on old kernels, some FUSE mounts).
/// The partial destination is deleted on cancel or error, so a stopped copy never
/// leaves a truncated file that looks complete.
fn copyFileChunked(io: std.Io, alloc: std.mem.Allocator, src: []const u8, dst: []const u8, perms: std.Io.File.Permissions, prog: ?*Progress, chunk: usize) !void {
    const linux = std.os.linux;
    const cwd = Dir.cwd();
    var in = try cwd.openFile(io, src, .{});
    defer in.close(io);
    var out = try cwd.createFile(io, dst, .{ .permissions = perms });
    var ok = false;
    defer {
        out.close(io);
        if (!ok) cwd.deleteFile(io, dst) catch {};
    }

    var use_cfr = true;
    var buf: []u8 = &.{};
    defer if (buf.len > 0) alloc.free(buf);
    while (true) {
        if (prog) |p| {
            if (p.canceled()) return error.Canceled;
        }
        var n: usize = 0;
        if (use_cfr) {
            const rc = linux.copy_file_range(in.handle, null, out.handle, null, chunk, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => n = rc,
                // Kernel/filesystem can't do it here: finish with plain read/write. The
                // file offsets already advanced by any earlier chunks carry over.
                .XDEV, .NOSYS, .INVAL, .OPNOTSUPP, .PERM => {
                    use_cfr = false;
                    continue;
                },
                .NOSPC => return error.NoSpaceLeft,
                .DQUOT => return error.DiskQuota,
                .IO => return error.InputOutput,
                else => return error.Unexpected,
            }
        } else {
            if (buf.len == 0) buf = try alloc.alloc(u8, @min(chunk, 1 << 20));
            const rc = linux.read(in.handle, buf.ptr, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => n = rc,
                .INTR => continue,
                .IO => return error.InputOutput,
                else => return error.Unexpected,
            }
            var off: usize = 0;
            while (off < n) {
                const wc = linux.write(out.handle, buf.ptr + off, n - off);
                switch (linux.errno(wc)) {
                    .SUCCESS => off += wc,
                    .INTR => {},
                    .NOSPC => return error.NoSpaceLeft,
                    .DQUOT => return error.DiskQuota,
                    .IO => return error.InputOutput,
                    else => return error.Unexpected,
                }
            }
        }
        if (n == 0) break; // EOF
        if (prog) |p| p.addBytes(n);
    }
    ok = true;
}

/// movePath moves src to dst, falling back to copy+delete across filesystems.
pub fn movePath(io: std.Io, alloc: std.mem.Allocator, src: []const u8, dst: []const u8, prog: ?*Progress) !void {
    Dir.renameAbsolute(src, dst, io) catch |err| switch (err) {
        error.CrossDevice => { // EXDEV: fall back to copy + delete
            try copyPath(io, alloc, src, dst, prog);
            try deletePath(io, src);
        },
        else => return err,
    };
}

/// chmodPath sets `path`'s permission bits (the low 12: rwx for owner/group/other plus
/// setuid/setgid/sticky). Doesn't follow a trailing symlink's target differently than
/// chmod(1) would; i.e. it does follow it, as chmod does.
pub fn chmodPath(path: []const u8, mode: u32) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = std.os.linux.fchmodat(std.os.linux.AT.FDCWD, @ptrCast(&buf), @intCast(mode & 0o7777));
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        .PERM, .ACCES => return error.AccessDenied,
        .ROFS => return error.ReadOnlyFileSystem,
        .NOENT => return error.FileNotFound,
        else => return error.Unexpected,
    }
}

/// shortcutName is a link's name as Windows Explorer names a shortcut, the
/// extension kept last so it still opens as its kind: "doc.txt" → "doc - Shortcut.txt",
/// a folder "Photos" → "Photos - Shortcut".
pub fn shortcutName(alloc: std.mem.Allocator, base: []const u8, is_dir: bool) ![]u8 {
    const dot = if (is_dir) null else std.mem.lastIndexOfScalar(u8, base, '.');
    if (dot) |d| if (d > 0) return alloc.print("{s} - Shortcut{s}", .{ base[0..d], base[d..] });
    return alloc.print("{s} - Shortcut", .{base});
}

/// makeLinkIn makes a shortcut to `target` (absolute) in `dir`, named as Windows
/// Explorer would (shortcutName; made unique if taken), and returns the name used
/// (owned). A symlink; where the filesystem has none (an SMB share, FAT), a
/// freedesktop link file, "<name> - Shortcut.desktop", which file managers (ZFD,
/// Dolphin) open as the item it points to.
pub fn makeLinkIn(io: std.Io, alloc: std.mem.Allocator, dir: []const u8, target: []const u8) ![]u8 {
    const base = std.fs.path.basename(target);
    const is_dir = isDir(io, target);
    const want = try shortcutName(alloc, base, is_dir);
    defer alloc.free(want);
    const name = try uniqueNameInDir(io, alloc, dir, want);
    errdefer alloc.free(name);
    const link = try std.fs.path.join(alloc, &.{ dir, name });
    defer alloc.free(link);
    if (Dir.cwd().symLink(io, target, link, .{ .is_directory = is_dir })) |_| return name else |_| {}
    // No symlinks here: a link file instead.
    alloc.free(name);
    const dwant = try alloc.print("{s} - Shortcut.desktop", .{base});
    defer alloc.free(dwant);
    const dname = try uniqueNameInDir(io, alloc, dir, dwant);
    errdefer alloc.free(dname);
    const url = try percentEncodePath(alloc, target);
    defer alloc.free(url);
    const body = try alloc.print("[Desktop Entry]\nType=Link\nName={s} - Shortcut\nURL=file://{s}\nIcon={s}\n", .{ base, url, if (is_dir) "folder" else "text-x-generic" });
    defer alloc.free(body);
    const dpath = try std.fs.path.join(alloc, &.{ dir, dname });
    defer alloc.free(dpath);
    try Dir.cwd().writeFile(io, .{ .sub_path = dpath, .data = body, .flags = .{ .exclusive = true } });
    return dname;
}

/// linkFileTarget returns where a freedesktop link file (a shortcut: Type=Link,
/// URL=file://…) at `path` points (owned), or null if it isn't one. Reads the file
/// (a few hundred bytes).
pub fn linkFileTarget(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (!std.mem.endsWith(u8, path, ".desktop")) return null;
    const data = Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024)) catch return null;
    defer alloc.free(data);
    var is_link = false;
    var url: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.eql(u8, line, "Type=Link")) is_link = true;
        if (std.mem.startsWith(u8, line, "URL=")) url = line[4..];
    }
    const u = url orelse return null;
    if (!is_link or !std.mem.startsWith(u8, u, "file://")) return null;
    return percentDecode(alloc, u["file://".len..]) catch null;
}

/// restoreTo moves `from` back to the exact path `to`: the undo of a move, which must
/// give the item its ORIGINAL name back (a move into a folder that already had that
/// name stored it as "name (2)"). If something has since taken `to`, the item gets a
/// fresh unique name beside it rather than clobbering the newcomer.
pub fn restoreTo(io: std.Io, alloc: std.mem.Allocator, from: []const u8, to: []const u8, prog: ?*Progress) !void {
    const dir = std.fs.path.dirname(to) orelse return error.BadPathName;
    if (!exists(io, to)) return movePath(io, alloc, from, to, prog);
    const name = try uniqueNameInDir(io, alloc, dir, std.fs.path.basename(to));
    defer alloc.free(name);
    const alt = try std.fs.path.join(alloc, &.{ dir, name });
    defer alloc.free(alt);
    return movePath(io, alloc, from, alt, prog);
}

/// deletePath removes a file or directory tree (permanent; callers should prefer
/// trashToHome for user-facing deletes).
pub fn deletePath(io: std.Io, path: []const u8) !void {
    try Dir.cwd().deleteTree(io, path);
}

/// renameInDir renames old_name to new_name within dir (both plain base names).
pub fn renameInDir(io: std.Io, alloc: std.mem.Allocator, dir: []const u8, old_name: []const u8, new_name: []const u8) !void {
    const from = try std.fs.path.join(alloc, &.{ dir, old_name });
    defer alloc.free(from);
    const to = try std.fs.path.join(alloc, &.{ dir, new_name });
    defer alloc.free(to);
    try Dir.renameAbsolute(from, to, io);
}

/// TrashLoc names the trash directory a path should go to, plus the top dir its
/// recorded Path is relative to. `topdir` is "" for the home trash (Path absolute) or
/// the filesystem's mount point for a top-dir trash (Path relative to it). Both slices
/// are owned; free with `deinit`.
pub const TrashLoc = struct {
    dir: []u8, // …/Trash, …/.Trash-$uid, or …/.Trash/$uid
    topdir: []u8, // "" (home) or the mount point (top-dir trash)

    pub fn deinit(self: TrashLoc, alloc: std.mem.Allocator) void {
        alloc.free(self.dir);
        alloc.free(self.topdir);
    }
    pub fn isTopDir(self: TrashLoc) bool {
        return self.topdir.len > 0;
    }
};

/// resolveTrashDir decides where `path` should be trashed: the home trash when `path`
/// is on the same filesystem as `trash_home`, else the per-filesystem top-dir trash:
/// `$topdir/.Trash/$uid` when `$topdir/.Trash` is a sticky, non-symlink directory (the
/// admin-provided shared can, per the spec), else the per-user `$topdir/.Trash-$uid`.
/// It's the single source of truth shared by trashing and by undo/restore, so both
/// agree on the directory with no extra bookkeeping.
pub fn resolveTrashDir(alloc: std.mem.Allocator, trash_home: []const u8, path: []const u8) !TrashLoc {
    if (deviceOf(path) == deviceOf(trash_home)) {
        return .{ .dir = try alloc.dupe(u8, trash_home), .topdir = try alloc.dupe(u8, "") };
    }
    const topdir = try mountPointOf(alloc, path);
    errdefer alloc.free(topdir);
    return .{ .dir = try topDirTrashDir(alloc, topdir), .topdir = topdir };
}

/// trash moves an absolute path to its XDG trash: the home trash, or the
/// per-filesystem top-dir trash when it's on another mount (native `.Trash-$uid`
/// support, replacing the old cross-device failure). Writes the companion .trashinfo
/// first per the spec; the recorded Path is absolute for the home trash and relative
/// to the top dir for a top-dir trash, so the can stays valid if the volume is
/// remounted elsewhere. The caller resolves trash_home from XDG_DATA_HOME.
pub fn trash(io: std.Io, alloc: std.mem.Allocator, trash_home: []const u8, path: []const u8) !void {
    const loc = try resolveTrashDir(alloc, trash_home, path);
    defer loc.deinit(alloc);
    const orig = if (loc.isTopDir()) relativeTo(loc.topdir, path) else path;
    try putInTrash(io, alloc, loc.dir, path, orig);
}

/// putInTrash moves `path` into `trash_dir`/files/<uniq> and writes the companion
/// info/<uniq>.trashinfo whose `Path=` is `orig` (percent-encoded per spec). Both dirs
/// are created if missing. `path` and `trash_dir` are on the same filesystem by
/// construction (resolveTrashDir guarantees it), so the rename never hits EXDEV.
fn putInTrash(io: std.Io, alloc: std.mem.Allocator, trash_dir: []const u8, path: []const u8, orig: []const u8) !void {
    const cwd = Dir.cwd();
    const files_dir = try std.fs.path.join(alloc, &.{ trash_dir, "files" });
    defer alloc.free(files_dir);
    const info_dir = try std.fs.path.join(alloc, &.{ trash_dir, "info" });
    defer alloc.free(info_dir);
    try cwd.createDirPath(io, files_dir);
    try cwd.createDirPath(io, info_dir);

    // A trash name not already taken in files/.
    const base = std.fs.path.basename(path);
    const existing = try readDirNames(io, alloc, files_dir);
    defer freeNames(alloc, existing);
    const name = try uniqueName(alloc, existing, base);
    defer alloc.free(name);

    // Write the .trashinfo BEFORE moving the file (spec ordering), Path percent-encoded.
    const info_path = try alloc.print("{s}/{s}.trashinfo", .{ info_dir, name });
    defer alloc.free(info_path);
    const encoded = try percentEncodePath(alloc, orig);
    defer alloc.free(encoded);
    // TODO: add `DeletionDate=<ISO-8601>` once the wall-clock API is wired.
    const info = try alloc.print("[Trash Info]\nPath={s}\n", .{encoded});
    defer alloc.free(info);
    try cwd.writeFile(io, .{ .sub_path = info_path, .data = info });

    const dest = try std.fs.path.join(alloc, &.{ files_dir, name });
    defer alloc.free(dest);
    try Dir.renameAbsolute(path, dest, io);
}

/// deviceOf returns a filesystem id (major<<32 | minor) for `path`, or of its nearest
/// existing ancestor when `path` itself doesn't exist yet (e.g. an already-trashed
/// original, for undo). 0 if nothing along the chain stats.
pub fn deviceOf(path: []const u8) u64 {
    var p = path;
    while (p.len > 0) {
        if (statxDev(p)) |dev| return dev;
        const parent = std.fs.path.dirname(p) orelse return 0;
        if (std.mem.eql(u8, parent, p)) return 0;
        p = parent;
    }
    return 0;
}

fn statxDev(path: []const u8) ?u64 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.mem.printSentinel(&buf, "{s}", .{path}, 0) catch return null;
    var sx: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, path_z.ptr, std.os.linux.AT.SYMLINK_NOFOLLOW, std.os.linux.STATX{}, &sx);
    if (@as(isize, @bitCast(rc)) < 0) return null;
    return (@as(u64, sx.dev_major) << 32) | sx.dev_minor;
}

/// mountPointOf returns the top directory (mount point) of the filesystem `path` is
/// on: the highest ancestor still on the same device as `path`. Owned result.
fn mountPointOf(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const dev = deviceOf(path);
    var cur = try alloc.dupe(u8, path);
    errdefer alloc.free(cur);
    while (std.fs.path.dirname(cur)) |parent| {
        if (parent.len == 0 or std.mem.eql(u8, parent, cur)) break;
        if (deviceOf(parent) != dev) break; // parent is on another fs → cur is the mount point
        const next = try alloc.dupe(u8, parent);
        alloc.free(cur);
        cur = next;
    }
    return cur;
}

/// topDirTrashDir builds the per-filesystem trash directory for mount point `topdir`
/// (see resolveTrashDir for the .Trash/$uid vs .Trash-$uid rule). Owned result.
fn topDirTrashDir(alloc: std.mem.Allocator, topdir: []const u8) ![]u8 {
    const uid = std.os.linux.getuid();
    const admin = try alloc.print("{s}/.Trash", .{topdir});
    defer alloc.free(admin);
    if (stickyDir(admin)) return alloc.print("{s}/{d}", .{ admin, uid });
    return alloc.print("{s}/.Trash-{d}", .{ topdir, uid });
}

/// stickyDir reports whether `path` is a directory (not a symlink) with the sticky bit
/// set: the spec's precondition for using the admin's `$topdir/.Trash/$uid`.
fn stickyDir(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.mem.printSentinel(&buf, "{s}", .{path}, 0) catch return false;
    var sx: std.os.linux.Statx = undefined;
    const mask = std.os.linux.STATX{ .TYPE = true, .MODE = true };
    const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, path_z.ptr, std.os.linux.AT.SYMLINK_NOFOLLOW, mask, &sx);
    if (@as(isize, @bitCast(rc)) < 0) return false;
    const S = std.os.linux.S;
    return (sx.mode & S.IFMT) == S.IFDIR and (sx.mode & S.ISVTX) != 0;
}

/// relativeTo strips a "$topdir/" prefix from an absolute path, yielding a path
/// relative to the top dir (the spec's top-dir trashinfo encoding). Falls back to the
/// absolute path (also spec-valid) when `path` isn't under `topdir`.
fn relativeTo(topdir: []const u8, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, topdir) and path.len > topdir.len) {
        var rel = path[topdir.len..];
        while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        if (rel.len > 0) return rel;
    }
    return path;
}

/// percentEncodePath %-encodes a path for a .trashinfo `Path=` value (RFC 3986),
/// keeping the unreserved set and '/' literal (as gvfs does) so the path stays legible.
pub fn percentEncodePath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (path) |ch| {
        switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' => try out.append(alloc, ch),
            else => {
                try out.append(alloc, '%');
                try out.append(alloc, hex[ch >> 4]);
                try out.append(alloc, hex[ch & 0x0F]);
            },
        }
    }
    return out.toOwnedSlice(alloc);
}

/// fileUriToPath turns a `file://[authority]/path` URI (percent-encoded), or a bare
/// absolute path, into a filesystem path (owned). The inverse of the `file://` +
/// percentEncodePath pairing. Null for anything that isn't an absolute local path
/// (remote scheme, relative path). Used by the FileManager1 reveal interface.
pub fn fileUriToPath(alloc: std.mem.Allocator, uri: []const u8) ?[]u8 {
    var s = uri;
    if (std.mem.startsWith(u8, s, "file:")) {
        s = s["file:".len..];
        if (std.mem.startsWith(u8, s, "//")) { // file://[authority]/path
            s = s[2..];
            const slash = std.mem.indexOfScalar(u8, s, '/') orelse return null;
            s = s[slash..]; // drop an authority such as "localhost"
        }
        if (s.len == 0 or s[0] != '/') return null;
        return percentDecode(alloc, s) catch null;
    }
    if (s.len > 0 and s[0] == '/') return alloc.dupe(u8, s) catch null; // already a plain path
    return null;
}

/// decodeDroppedPath un-escapes a path handed to us by a drop from another app.
///
/// A dropped `text/uri-list` carries percent-encoded URIs, and the toolkit that hands
/// them over may or may not have decoded them already: GLFW's X11 backend strips the
/// `file://` prefix but leaves the escapes in place, so "My%20Photos/a%20b.png" arrives
/// as a path that resolves to nothing and the copy silently fails. Decoding
/// unconditionally isn't safe either: a real filename may contain a literal '%', and
/// "100%25.png" would then be mangled into a different (possibly existing) file.
///
/// So decode only when it demonstrably helps: the raw path doesn't resolve and the
/// decoded one does. Anything else is returned unchanged. Result is owned.
pub fn decodeDroppedPath(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, path, '%') == null) return alloc.dupe(u8, path);
    const decoded = try percentDecode(alloc, path);
    errdefer alloc.free(decoded);
    if (std.mem.eql(u8, decoded, path)) {
        alloc.free(decoded);
        return alloc.dupe(u8, path);
    }
    if (!exists(io, path) and exists(io, decoded)) return decoded;
    alloc.free(decoded);
    return alloc.dupe(u8, path);
}

/// exists reports whether an absolute path resolves (follows symlinks).
/// pathExists reports whether anything (file, folder, dangling-or-not symlink) is at
/// `path`, using lstat semantics, so a broken symlink still counts as "taken".
pub fn pathExists(io: std.Io, path: []const u8) bool {
    _ = Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// isDir reports whether `path` resolves to a directory.
pub fn isDir(io: std.Io, path: []const u8) bool {
    const st = Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// percentDecode expands %XX escapes back to raw bytes (inverse of percentEncodePath).
fn percentDecode(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                try out.append(alloc, hi.? * 16 + lo.?);
                i += 3;
                continue;
            }
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn hexVal(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

/// readDirNames returns the (owned) entry names of dir_path. Small helper for
/// trash's unique-naming; the browser uses core/scan for real listings.
fn readDirNames(io: std.Io, alloc: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
    var d = try Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer d.close(io);
    var list = std.ArrayList([]u8).empty;
    errdefer {
        for (list.items) |n| alloc.free(n);
        list.deinit(alloc);
    }
    var it = d.iterate();
    while (try it.next(io)) |e| try list.append(alloc, try alloc.dupe(u8, e.name));
    return list.toOwnedSlice(alloc);
}

fn freeNames(alloc: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| alloc.free(n);
    alloc.free(names);
}

/// invalidNameReason validates a single file/dir NAME (one path leaf; the caller
/// trims surrounding whitespace first). Returns a short, user-facing reason to reject
/// it, or null when it's fine. It flags only what is illegal on EVERY filesystem: an
/// empty name, the reserved "." / "..", a '/' (the path separator, which a leaf can
/// never contain), or an embedded NUL, so we never refuse a name that ext4/btrfs would
/// happily accept. Characters that are illegal only on FAT/NTFS/exFAT (\ : * ? " < > |,
/// trailing dots/spaces) are deliberately NOT rejected here; on the rare mount that
/// forbids them the syscall's own error surfaces (op_err, or the requesting app's write).
/// The point is to catch the SILENT-misbehave cases before they happen: '/' turns a
/// rename into a move-into-subdir (or FileNotFound), and ".."/"." escape or self-target
/// the folder. Used by the Save dialog and inline rename.
pub fn invalidNameReason(name: []const u8) ?[:0]const u8 {
    if (name.len == 0) return "Name can't be empty";
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return "\".\" and \"..\" are reserved names";
    if (std.mem.indexOfScalar(u8, name, '/') != null) return "Name can't contain a slash (/)";
    if (std.mem.indexOfScalar(u8, name, 0) != null) return "Name can't contain a null byte";
    return null;
}

/// Characters SMB shares and FAT/NTFS/exFAT drives can't store in a name.
const windows_reserved = "\\:*?\"<>|";

/// portableName returns `name` (owned) made storable on a Windows-semantics
/// filesystem: each reserved character or control byte becomes '_', a trailing dot or
/// space (silently stripped or refused there) becomes '_', and a reserved DOS device
/// name ("CON", "nul.txt", "COM1") gets a '_' after its stem. Names that are already
/// fine come back unchanged.
pub fn portableName(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, name.len + 1);
    errdefer out.deinit(alloc);
    for (name) |ch| {
        const bad = ch < 0x20 or std.mem.indexOfScalar(u8, windows_reserved, ch) != null;
        out.appendAssumeCapacity(if (bad) '_' else ch);
    }
    var i = out.items.len;
    while (i > 0 and (out.items[i - 1] == '.' or out.items[i - 1] == ' ')) : (i -= 1) out.items[i - 1] = '_';
    const stem_len = std.mem.indexOfScalar(u8, out.items, '.') orelse out.items.len;
    if (isDosDevice(out.items[0..stem_len])) out.insertAssumeCapacity(stem_len, '_');
    return out.toOwnedSlice(alloc);
}

fn isDosDevice(stem: []const u8) bool {
    const fixed = [_][]const u8{ "CON", "PRN", "AUX", "NUL" };
    for (fixed) |d| if (std.ascii.eqlIgnoreCase(stem, d)) return true;
    if (stem.len == 4 and (std.ascii.startsWithIgnoreCase(stem, "COM") or std.ascii.startsWithIgnoreCase(stem, "LPT")))
        return stem[3] >= '1' and stem[3] <= '9';
    return false;
}

/// restrictedNamesAt reports whether the filesystem holding `dir` uses Windows name
/// rules: a CIFS/SMB mount (Samba, Windows shares) or a FAT, exFAT or NTFS drive.
/// FUSE mounts (ntfs-3g, rclone) all share one magic and can't be told apart, so
/// they're treated as permissive.
pub fn restrictedNamesAt(dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (dir.len >= buf.len) return false;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    var st: StatFs = undefined;
    const rc = std.os.linux.syscall2(.statfs, @intFromPtr(&buf), @intFromPtr(&st));
    if (std.os.linux.errno(rc) != .SUCCESS) return false;
    const magic: u32 = @truncate(@as(usize, @bitCast(st.f_type)));
    return switch (magic) {
        0xFF534D42, // CIFS
        0xFE534D42, // SMB2/3
        0x517B, // SMB (smbfs)
        0x4d44, // FAT (msdos/vfat)
        0x2011BAB0, // exFAT
        0x5346544e, // NTFS (legacy driver)
        0x7366746e, // NTFS3
        => true,
        else => false,
    };
}

/// Brief is the little a conflict prompt shows about an item.
pub const Brief = struct { size: u64 = 0, mtime_secs: i64 = 0, is_dir: bool = false };

/// brief stats `path` (following symlinks); null if it can't be read.
pub fn brief(path: []const u8) ?Brief {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const linux = std.os.linux;
    var sx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, @ptrCast(&buf), 0, linux.STATX{ .TYPE = true, .MODE = true, .MTIME = true, .SIZE = true }, &sx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ .size = sx.size, .mtime_secs = sx.mtime.sec, .is_dir = (sx.mode & linux.S.IFMT) == linux.S.IFDIR };
}

/// freeBytesAt is the space available to us on the filesystem holding `dir`, or
/// null when it can't be told (statfs failed, or a pseudo filesystem that reports no
/// blocks; some FUSE mounts do, and must not be treated as full).
pub fn freeBytesAt(dir: []const u8) ?u64 {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (dir.len >= buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    var st: StatFs = undefined;
    const rc = std.os.linux.syscall2(.statfs, @intFromPtr(&buf), @intFromPtr(&st));
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    const unit: u64 = @intCast(if (st.f_frsize > 0) st.f_frsize else st.f_bsize);
    if (st.f_blocks == 0 or unit == 0) return null;
    return st.f_bavail * unit;
}

/// writableDir reports whether we may create entries in `dir` (access W_OK|X_OK).
pub fn writableDir(dir: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (dir.len >= buf.len) return true; // can't tell; let the copy itself decide
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    const linux = std.os.linux;
    const rc = linux.faccessat(linux.AT.FDCWD, @ptrCast(&buf), linux.W_OK | linux.X_OK, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => true,
        .ACCES, .ROFS, .PERM => false,
        else => true,
    };
}

/// errorMessage turns an op's @errorName into words for the status bar. Unknown
/// names pass through unchanged.
pub fn errorMessage(err_name: []const u8) []const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "FileNotFound", "not found, or the name isn't allowed on that drive" },
        .{ "AccessDenied", "permission denied" },
        .{ "PermissionDenied", "permission denied" },
        .{ "NoSpaceLeft", "the destination is full" },
        .{ "NotEnoughSpace", "not enough free space at the destination; nothing was copied" },
        .{ "DestinationNotWritable", "you can't write to the destination folder; nothing was copied" },
        .{ "DiskQuota", "disk quota exceeded" },
        .{ "ReadOnlyFileSystem", "the destination is read-only" },
        .{ "PathAlreadyExists", "an item with that name already exists" },
        .{ "NameTooLong", "the name is too long" },
        .{ "BadPathName", "the name isn't allowed on that drive" },
        .{ "InputOutput", "a read or write error occurred" },
        .{ "NotDir", "part of the path isn't a folder" },
        .{ "Canceled", "canceled" },
        .{ "TagsNotSupported", "this drive can't store tags" },
        .{ "CrossDevice", "this drive has no Trash ZFD can use" },
        .{ "RenameAcrossMountPoints", "this drive has no Trash ZFD can use" },
    };
    for (map) |m| if (std.mem.eql(u8, err_name, m[0])) return m[1];
    return err_name;
}

/// uniqueNameInDir is the filesystem wrapper over uniqueName: it reads dir's
/// current entries and returns a name not colliding with them. If the directory
/// can't be read, it falls back to `name` unchanged. Caller owns the result.
pub fn uniqueNameInDir(io: std.Io, alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const existing = readDirNames(io, alloc, dir) catch return alloc.dupe(u8, name);
    defer freeNames(alloc, existing);
    return uniqueName(alloc, existing, name);
}

/// makeDirIn creates an empty directory `name` inside `dir`.
pub fn makeDirIn(io: std.Io, alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !void {
    const p = try std.fs.path.join(alloc, &.{ dir, name });
    defer alloc.free(p);
    try Dir.cwd().createDirPath(io, p);
}

/// makeFileIn creates an empty file `name` inside `dir`.
pub fn makeFileIn(io: std.Io, alloc: std.mem.Allocator, dir: []const u8, name: []const u8) !void {
    const p = try std.fs.path.join(alloc, &.{ dir, name });
    defer alloc.free(p);
    try Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "" });
}

// --- launching external programs (never linked; shelled out) -----------------
// Each launch runs on a detached reaper thread that spawns the child and waits,
// so the render thread never blocks and no zombie is left behind. The child
// (xdg-open, a terminal) may outlive us; the thread just idles in wait().

/// findOnPath is the full path of program `name` on $PATH (owned), or null.
pub fn findOnPath(io: std.Io, alloc: std.mem.Allocator, name: []const u8) ?[]u8 {
    const path = getEnv("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fs.path.join(alloc, &.{ dir, name }) catch continue;
        if (Dir.cwd().statFile(io, full, .{})) |_| return full else |_| alloc.free(full);
    }
    return null;
}

/// openWith opens a path in its default application via xdg-open.
pub fn openWith(io: std.Io, alloc: std.mem.Allocator, path: []const u8) void {
    launch(io, alloc, &.{ "xdg-open", path }, null);
}

/// launch_env is the environment launched programs start from (main sets it to our
/// own); null leaves them ours as it was at startup.
pub var launch_env: ?*const std.process.Environ.Map = null;

/// startup_id, set by the UI, makes a fresh launch ID (an X11 startup notification,
/// stamped with the time of the click that asked for it) in `buf`. It lets the window
/// manager give the launched program's window focus, as the user just asked for it.
/// Called on the thread calling launch/openTerminal (the UI thread).
pub var startup_id: ?*const fn (buf: []u8) ?[]const u8 = null;

/// takeStartupId is a fresh launch ID (owned), or null.
fn takeStartupId(alloc: std.mem.Allocator) ?[]u8 {
    const f = startup_id orelse return null;
    var buf: [128]u8 = undefined;
    const id = f(&buf) orelse return null;
    return alloc.dupe(u8, id) catch null;
}

/// childEnv is the environment for a launched program: ours, carrying the launch's own
/// ID as both DESKTOP_STARTUP_ID (X11) and XDG_ACTIVATION_TOKEN (Wayland), and never
/// the one we were started with: that one is spent, and a program handed it gets
/// refused focus. Null (inherit) when there's no base environment.
fn childEnv(alloc: std.mem.Allocator, id: ?[]const u8) ?std.process.Environ.Map {
    const base = launch_env orelse return null;
    var m = base.clone(alloc) catch return null;
    _ = m.swapRemove("DESKTOP_STARTUP_ID");
    _ = m.swapRemove("XDG_ACTIVATION_TOKEN");
    if (id) |t| {
        m.put("DESKTOP_STARTUP_ID", t) catch {};
        m.put("XDG_ACTIVATION_TOKEN", t) catch {};
    }
    return m;
}

/// openTerminal opens a terminal emulator with its working directory set to dir. It
/// resolves *which* terminal from the user's actual preference (see terminalThread),
/// not a hardcoded beauty contest: the fixed list is only the last-resort fallback.
pub fn openTerminal(io: std.Io, alloc: std.mem.Allocator, dir: []const u8) void {
    const d = alloc.dupe(u8, dir) catch return;
    const id = takeStartupId(alloc);
    const t = std.Thread.spawn(.{}, terminalThread, .{ io, alloc, d, id }) catch {
        alloc.free(d);
        if (id) |s| alloc.free(s);
        return;
    };
    t.detach();
}

/// terminalThread resolves the terminal to launch from the best available source and
/// runs the first that works. There's no registry that enumerates "all terminals"
/// (even freedesktop's answer, xdg-terminal-exec, falls back to a built-in list), so a
/// hardcoded probe is unavoidable, but it belongs *last*. Everything above it honors
/// a declared preference: $TERMINAL, the desktop's configured default, then the
/// standard launcher. First success wins (each hides when its tool is absent).
fn terminalThread(io: std.Io, alloc: std.mem.Allocator, dir: []u8, id: ?[]u8) void {
    defer alloc.free(dir);
    defer if (id) |s| alloc.free(s);
    var env = childEnv(alloc, id);
    defer if (env) |*m| m.deinit();
    const envp: ?*const std.process.Environ.Map = if (env) |*m| m else null;

    // 1. $TERMINAL: the user's explicit choice, honored by many CLI tools.
    if (getEnv("TERMINAL")) |t| {
        if (spawnTerm(io, alloc, t, dir, envp)) return;
    }
    // 2. The running desktop's configured default terminal (KDE/GNOME).
    if (deDefaultTerminal(io, alloc)) |t| {
        defer alloc.free(t);
        if (spawnTerm(io, alloc, t, dir, envp)) return;
    }
    // 3. xdg-terminal-exec: the freedesktop standard launcher (a proposal, but the
    //    correct DE-agnostic entry point wherever it's installed).
    if (spawnTerm(io, alloc, "xdg-terminal-exec", dir, envp)) return;
    // 4. Debian/Ubuntu's alternatives symlink.
    if (spawnTerm(io, alloc, "x-terminal-emulator", dir, envp)) return;
    // 5. Last resort: probe well-known emulators (first on PATH wins).
    const candidates = [_][]const u8{ "konsole", "gnome-terminal", "foot", "alacritty", "kitty", "wezterm", "ghostty", "xfce4-terminal", "xterm" };
    for (candidates) |t| {
        if (spawnTerm(io, alloc, t, dir, envp)) return;
    }
}

/// deDefaultTerminal asks the running desktop for its configured terminal (owned), or
/// null: KDE keeps it in kdeglobals (kreadconfig6/5 General/TerminalApplication), GNOME
/// in gsettings. We pick by $XDG_CURRENT_DESKTOP and try both when it's unset/unknown.
fn deDefaultTerminal(io: std.Io, alloc: std.mem.Allocator) ?[]u8 {
    const de = getEnv("XDG_CURRENT_DESKTOP") orelse "";
    const kde = std.ascii.findIgnoreCase(de, "KDE") != null or std.ascii.findIgnoreCase(de, "plasma") != null;
    const gnome = std.ascii.findIgnoreCase(de, "GNOME") != null;
    const unknown = !kde and !gnome;
    if (kde or unknown) {
        if (captureLine(io, alloc, &.{ "kreadconfig6", "--group", "General", "--key", "TerminalApplication" })) |t| return t;
        if (captureLine(io, alloc, &.{ "kreadconfig5", "--group", "General", "--key", "TerminalApplication" })) |t| return t;
    }
    if (gnome or unknown) {
        if (captureLine(io, alloc, &.{ "gsettings", "get", "org.gnome.desktop.default-applications.terminal", "exec" })) |t| return t;
    }
    return null;
}

/// spawnTerm launches a resolved terminal `spec` (which may carry arguments) with its
/// working directory set to `dir`; terminals inherit that cwd, so no per-emulator
/// "--working-directory" flag is needed. Returns true if it spawned; then we wait out
/// its lifetime on this detached reaper thread (no zombie). False if not on PATH.
fn spawnTerm(io: std.Io, alloc: std.mem.Allocator, spec: []const u8, dir: []const u8, env: ?*const std.process.Environ.Map) bool {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    var it = std.mem.tokenizeScalar(u8, spec, ' '); // "gnome-terminal --" → ["gnome-terminal","--"]
    while (it.next()) |tok| argv.append(alloc, tok) catch return false;
    if (argv.items.len == 0) return false;
    var child = std.process.spawn(io, .{ .argv = argv.items, .cwd = .{ .path = dir }, .environ_map = env }) catch return false;
    _ = child.wait(io) catch {};
    return true;
}

/// captureLine spawns argv, returning its stdout's first non-empty line, trimmed and
/// unquoted (gsettings prints 'gnome-terminal'), owned, or null on any failure. Used
/// to query a desktop's terminal setting; runs on the detached terminal thread.
fn captureLine(io: std.Io, alloc: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    var pbuf: [64]u8 = undefined;
    const tmp = std.mem.print(&pbuf, "/tmp/zfd-term-{d}", .{std.os.linux.getpid()}) catch return null;
    const f = Dir.cwd().createFile(io, tmp, .{}) catch return null;
    var child = std.process.spawn(io, .{ .argv = argv, .stdout = .{ .file = f } }) catch {
        f.close(io);
        Dir.cwd().deleteFile(io, tmp) catch {};
        return null;
    };
    _ = child.wait(io) catch {};
    f.close(io);
    defer Dir.cwd().deleteFile(io, tmp) catch {};
    const content = Dir.cwd().readFileAlloc(io, tmp, alloc, .limited(4096)) catch return null;
    defer alloc.free(content);
    var line: []const u8 = content;
    if (std.mem.indexOfScalar(u8, content, '\n')) |nl| line = content[0..nl];
    line = std.mem.trim(u8, line, " \t\r\n'\"");
    if (line.len == 0) return null;
    return alloc.dupe(u8, line) catch null;
}

/// getEnv reads an environment variable by scanning the process environment (neither
/// std.posix.getenv nor std.process.getEnvVarOwned is available in this std; libc is
/// linked, so std.c.environ is). Returns a borrow of the environment.
fn getEnv(name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const s = std.mem.sliceTo(entry, 0);
        if (s.len > name.len and s[name.len] == '=' and std.mem.eql(u8, s[0..name.len], name)) {
            return s[name.len + 1 ..];
        }
    }
    return null;
}

/// launch spawns argv (optionally in cwd) on a detached reaper thread.
pub fn launch(io: std.Io, alloc: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) void {
    const owned = dupArgv(alloc, argv) catch return;
    const cwd_owned: ?[]u8 = if (cwd) |d| (alloc.dupe(u8, d) catch {
        freeArgv(alloc, owned);
        return;
    }) else null;
    const id = takeStartupId(alloc);
    const t = std.Thread.spawn(.{}, launchThread, .{ io, alloc, owned, cwd_owned, id }) catch {
        freeArgv(alloc, owned);
        if (cwd_owned) |co| alloc.free(co);
        if (id) |s| alloc.free(s);
        return;
    };
    t.detach();
}

fn launchThread(io: std.Io, alloc: std.mem.Allocator, argv: [][]u8, cwd: ?[]u8, id: ?[]u8) void {
    defer freeArgv(alloc, argv);
    defer if (cwd) |co| alloc.free(co);
    defer if (id) |s| alloc.free(s);
    var env = childEnv(alloc, id);
    defer if (env) |*m| m.deinit();
    const cwd_opt: std.process.Child.Cwd = if (cwd) |co| .{ .path = co } else .inherit;
    var child = std.process.spawn(io, .{ .argv = argv, .cwd = cwd_opt, .environ_map = if (env) |*m| m else null }) catch return;
    _ = child.wait(io) catch {};
}

fn dupArgv(alloc: std.mem.Allocator, argv: []const []const u8) ![][]u8 {
    const out = try alloc.alloc([]u8, argv.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |a| alloc.free(a);
        alloc.free(out);
    }
    for (argv) |a| {
        out[n] = try alloc.dupe(u8, a);
        n += 1;
    }
    return out;
}

fn freeArgv(alloc: std.mem.Allocator, argv: [][]u8) void {
    for (argv) |a| alloc.free(a);
    alloc.free(argv);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "invalidNameReason flags only universally-illegal names" {
    // Valid: ordinary names, spaces, leading dot, and chars illegal only on FAT/NTFS.
    try testing.expect(invalidNameReason("report.txt") == null);
    try testing.expect(invalidNameReason("My Folder") == null);
    try testing.expect(invalidNameReason(".hidden") == null);
    try testing.expect(invalidNameReason("weird:name*?.txt") == null); // legal on ext4/btrfs
    // Invalid: empty, the reserved dir entries, a slash, an embedded NUL.
    try testing.expect(invalidNameReason("") != null);
    try testing.expect(invalidNameReason(".") != null);
    try testing.expect(invalidNameReason("..") != null);
    try testing.expect(invalidNameReason("a/b") != null);
    try testing.expect(invalidNameReason("x\x00y") != null);
    // "..." is a legal name (only exactly "." and ".." are reserved).
    try testing.expect(invalidNameReason("...") == null);
}

test "ext and withExt" {
    try testing.expectEqualStrings(".gz", ext("a.tar.gz"));
    try testing.expectEqualStrings("", ext("noext"));
    try testing.expectEqualStrings(".bashrc", ext(".bashrc"));
    const a = testing.allocator;
    const swapped = try withExt(a, "report.txt", ".png");
    defer a.free(swapped);
    try testing.expectEqualStrings("report.png", swapped);
    const added = try withExt(a, "report", ".png");
    defer a.free(added);
    try testing.expectEqualStrings("report.png", added);
}

test "uniqueName inserts (copy) suffixes before the extension" {
    const a = testing.allocator;
    // No collision → the name itself.
    {
        const got = try uniqueName(a, &.{}, "a.txt");
        defer a.free(got);
        try testing.expectEqualStrings("a.txt", got);
    }
    // First and second collisions.
    {
        const got = try uniqueName(a, &.{"a.txt"}, "a.txt");
        defer a.free(got);
        try testing.expectEqualStrings("a (copy).txt", got);
    }
    {
        const got = try uniqueName(a, &.{ "a.txt", "a (copy).txt" }, "a.txt");
        defer a.free(got);
        try testing.expectEqualStrings("a (copy 2).txt", got);
    }
    // No extension.
    {
        const got = try uniqueName(a, &.{"d"}, "d");
        defer a.free(got);
        try testing.expectEqualStrings("d (copy)", got);
    }
}

test "decodeDroppedPath un-escapes only when that is what makes the path resolve" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "my photo.png", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "100%25.png", .data = "" }); // a literal '%25' in the name
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    // Escaped form of an existing file → decoded (this is what GLFW hands us).
    {
        const enc = try a.print("{s}/my%20photo.png", .{root});
        defer a.free(enc);
        const got = try decodeDroppedPath(io, a, enc);
        defer a.free(got);
        try testing.expect(std.mem.endsWith(u8, got, "/my photo.png"));
    }
    // The raw path already resolves (a real '%' in the name) → left alone, or the
    // file would be "decoded" into a name that isn't the one that was dropped.
    {
        const raw = try a.print("{s}/100%25.png", .{root});
        defer a.free(raw);
        const got = try decodeDroppedPath(io, a, raw);
        defer a.free(got);
        try testing.expectEqualStrings(raw, got);
    }
    // Nothing resolves either way → unchanged rather than silently rewritten.
    {
        const missing = try a.print("{s}/gone%20away.png", .{root});
        defer a.free(missing);
        const got = try decodeDroppedPath(io, a, missing);
        defer a.free(got);
        try testing.expectEqualStrings(missing, got);
    }
}

test "copyPath copies a file and a directory tree" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.txt", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/b.txt", .data = "world" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const src = try std.fs.path.join(a, &.{ root, "src" });
    defer a.free(src);
    const dst = try std.fs.path.join(a, &.{ root, "dst" });
    defer a.free(dst);
    const nested = try std.fs.path.join(a, &.{ root, "dst", "sub", "b.txt" });
    defer a.free(nested);

    try testing.expect(!exists(io, dst)); // before: no copy yet
    try copyPath(io, a, src, dst, null);
    try testing.expect(exists(io, nested)); // after: tree copied through
    try testing.expect(exists(io, src)); // and the original still there
}

test "copyFileChunked copies the exact bytes across many chunks and reports them" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const n = 100 * 1024 + 123; // not a multiple of the chunk: exercises the tail
    const data = try a.alloc(u8, n);
    defer a.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 31 +% 5);
    try tmp.dir.writeFile(io, .{ .sub_path = "src.bin", .data = data });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const src = try std.fs.path.join(a, &.{ root, "src.bin" });
    defer a.free(src);
    const dst = try std.fs.path.join(a, &.{ root, "dst.bin" });
    defer a.free(dst);

    var prog = Progress{ .io = io };
    prog.begin(.copying, 1, n);
    const st = try Dir.cwd().statFile(io, src, .{});
    try copyFileChunked(io, a, src, dst, st.permissions, &prog, 4096);

    const back = try Dir.cwd().readFileAlloc(io, dst, a, .limited(1 << 20));
    defer a.free(back);
    try testing.expectEqualSlices(u8, data, back);
    var nb: [8]u8 = undefined;
    try testing.expectEqual(@as(u64, n), prog.snapshot(&nb).bytes_done);
}

test "copyFileChunked stops on cancel and leaves no partial file behind" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "src.bin", .data = &@as([10000]u8, @splat('x')) });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const src = try std.fs.path.join(a, &.{ root, "src.bin" });
    defer a.free(src);
    const dst = try std.fs.path.join(a, &.{ root, "dst.bin" });
    defer a.free(dst);

    var prog = Progress{ .io = io };
    prog.begin(.copying, 1, 10000);
    prog.requestCancel();
    const st = try Dir.cwd().statFile(io, src, .{});
    try testing.expectError(error.Canceled, copyFileChunked(io, a, src, dst, st.permissions, &prog, 1024));
    try testing.expect(!exists(io, dst)); // the partial copy was removed
}

test "chmodPath changes the permission bits" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const f = try std.fs.path.join(a, &.{ root, "f" });
    defer a.free(f);
    try chmodPath(f, 0o640);
    const st = try Dir.cwd().statFile(io, f, .{});
    try testing.expectEqual(@as(u32, 0o640), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
}

test "makeLinkIn makes a uniquely named symlink to the target" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "doc.txt", .data = "hi" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const target = try std.fs.path.join(a, &.{ root, "doc.txt" });
    defer a.free(target);
    const n1 = try makeLinkIn(io, a, root, target);
    defer a.free(n1);
    const n2 = try makeLinkIn(io, a, root, target);
    defer a.free(n2);
    try testing.expectEqualStrings("doc - Shortcut.txt", n1);
    try testing.expect(!std.mem.eql(u8, n1, n2)); // the second didn't clobber the first
    const back = try tmp.dir.readFileAlloc(io, "doc - Shortcut.txt", a, .limited(16));
    defer a.free(back);
    try testing.expectEqualStrings("hi", back); // it resolves to the target
}

test "shortcuts are named as Windows Explorer names them, extension last" {
    const a = testing.allocator;
    const f = try shortcutName(a, "doc.txt", false);
    defer a.free(f);
    try testing.expectEqualStrings("doc - Shortcut.txt", f);
    const d = try shortcutName(a, "My.Photos", true);
    defer a.free(d);
    try testing.expectEqualStrings("My.Photos - Shortcut", d);
    const h = try shortcutName(a, ".bashrc", false);
    defer a.free(h);
    try testing.expectEqualStrings(".bashrc - Shortcut", h);
}

test "a link file points where it says" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "x - Shortcut.desktop", .data = "[Desktop Entry]\nType=Link\nName=x\nURL=file:///home/me/My%20Docs/x.txt\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.desktop", .data = "[Desktop Entry]\nType=Application\nExec=foo\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const p1 = try std.fs.path.join(a, &.{ root, "x - Shortcut.desktop" });
    defer a.free(p1);
    const t = linkFileTarget(io, a, p1).?;
    defer a.free(t);
    try testing.expectEqualStrings("/home/me/My Docs/x.txt", t);
    const p2 = try std.fs.path.join(a, &.{ root, "app.desktop" });
    defer a.free(p2);
    try testing.expect(linkFileTarget(io, a, p2) == null); // an app, not a link
}

test "measureTree counts files and bytes recursively" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello" }); // 5
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.txt", .data = "hi" }); // 2
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const m = measureTree(io, a, root);
    try testing.expectEqual(@as(u64, 2), m.files);
    try testing.expectEqual(@as(u64, 7), m.bytes);
}

test "movePath relocates within the same filesystem" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const src = try std.fs.path.join(a, &.{ root, "f.txt" });
    defer a.free(src);
    const dst = try std.fs.path.join(a, &.{ root, "moved.txt" });
    defer a.free(dst);

    try testing.expect(exists(io, src) and !exists(io, dst)); // before
    try movePath(io, a, src, dst, null);
    try testing.expect(exists(io, dst) and !exists(io, src)); // after: swapped
}

test "deletePath removes a tree; renameInDir renames" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "d/inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "d/inner/x", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "old.txt", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    const oldp = try std.fs.path.join(a, &.{ root, "old.txt" });
    defer a.free(oldp);
    const newp = try std.fs.path.join(a, &.{ root, "new.txt" });
    defer a.free(newp);
    try testing.expect(exists(io, oldp) and !exists(io, newp)); // before
    try renameInDir(io, a, root, "old.txt", "new.txt");
    try testing.expect(!exists(io, oldp) and exists(io, newp)); // after: renamed

    const tree = try std.fs.path.join(a, &.{ root, "d" });
    defer a.free(tree);
    try testing.expect(exists(io, tree)); // before
    try deletePath(io, tree);
    try testing.expect(!exists(io, tree)); // after: gone
}

test "trash moves a file into the home trash's files/ and writes info/" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "junk.txt", .data = "" });
    try tmp.dir.createDirPath(io, "Trash");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const trash_home = try std.fs.path.join(a, &.{ root, "Trash" });
    defer a.free(trash_home);
    const victim = try std.fs.path.join(a, &.{ root, "junk.txt" });
    defer a.free(victim);
    const trashed = try std.fs.path.join(a, &.{ trash_home, "files", "junk.txt" });
    defer a.free(trashed);
    const info = try std.fs.path.join(a, &.{ trash_home, "info", "junk.txt.trashinfo" });
    defer a.free(info);

    // victim and trash_home share a filesystem (both under the temp dir) → home trash.
    try testing.expect(exists(io, victim) and !exists(io, trashed)); // before
    try trash(io, a, trash_home, victim);
    try testing.expect(!exists(io, victim)); // after: moved out of the way
    try testing.expect(exists(io, trashed)); // into trash/files
    try testing.expect(exists(io, info)); // with its .trashinfo
}

test "percentEncodePath encodes reserved bytes and keeps slashes literal" {
    const a = testing.allocator;
    const enc = try percentEncodePath(a, "/home/u/My Docs/a+b%.txt");
    defer a.free(enc);
    try testing.expectEqualStrings("/home/u/My%20Docs/a%2Bb%25.txt", enc);
}

test "fileUriToPath decodes file:// URIs, strips authority, rejects non-local" {
    const a = testing.allocator;

    const p1 = fileUriToPath(a, "file:///home/u/My%20Docs/a%2Bb%25.txt").?;
    defer a.free(p1);
    try testing.expectEqualStrings("/home/u/My Docs/a+b%.txt", p1); // round-trips percentEncodePath

    const p2 = fileUriToPath(a, "file://localhost/mnt/x/vid.mp4").?; // authority dropped
    defer a.free(p2);
    try testing.expectEqualStrings("/mnt/x/vid.mp4", p2);

    const p3 = fileUriToPath(a, "/plain/abs/path").?; // bare absolute path passes through
    defer a.free(p3);
    try testing.expectEqualStrings("/plain/abs/path", p3);

    try testing.expect(fileUriToPath(a, "http://example.com/x") == null); // remote scheme
    try testing.expect(fileUriToPath(a, "relative/path") == null); // not absolute
}

test "relativeTo strips the top-dir prefix, else falls back to absolute" {
    try testing.expectEqualStrings("sub/a.txt", relativeTo("/mnt/usb", "/mnt/usb/sub/a.txt"));
    try testing.expectEqualStrings("a.txt", relativeTo("/mnt/usb", "/mnt/usb/a.txt"));
    try testing.expectEqualStrings("/other/a.txt", relativeTo("/mnt/usb", "/other/a.txt")); // not under topdir
}

test "topDirTrashDir uses .Trash/$uid for a sticky .Trash, else .Trash-$uid" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const top = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(top);
    const uid = std.os.linux.getuid();

    // Before: no $top/.Trash → per-user $top/.Trash-$uid.
    {
        const dir = try topDirTrashDir(a, top);
        defer a.free(dir);
        const want = try a.print("{s}/.Trash-{d}", .{ top, uid });
        defer a.free(want);
        try testing.expectEqualStrings(want, dir);
    }

    // After: a sticky $top/.Trash exists → the admin's shared $top/.Trash/$uid.
    try tmp.dir.createDirPath(io, ".Trash");
    const admin = try a.print("{s}/.Trash", .{top});
    defer a.free(admin);
    var cbuf: [std.fs.max_path_bytes]u8 = undefined;
    const admin_z = try std.mem.printSentinel(&cbuf, "{s}", .{admin}, 0);
    _ = std.os.linux.chmod(admin_z.ptr, 0o1777); // dir + sticky bit
    {
        const dir = try topDirTrashDir(a, top);
        defer a.free(dir);
        const want = try a.print("{s}/.Trash/{d}", .{ top, uid });
        defer a.free(want);
        try testing.expectEqualStrings(want, dir);
    }
}

test "portableName replaces characters Windows filesystems refuse" {
    const a = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "plain.txt", "plain.txt" },
        .{ "a:b*c?.txt", "a_b_c_.txt" },
        .{ "say \"hi\" <now>|", "say _hi_ _now__" },
        .{ "trailing. ", "trailing__" },
        .{ "con", "con_" },
        .{ "NUL.tar.gz", "NUL_.tar.gz" },
        .{ "com1.txt", "com1_.txt" },
        .{ "COM0", "COM0" },
        .{ "console", "console" },
        .{ "back\\slash", "back_slash" },
    };
    for (cases) |cs| {
        const got = try portableName(a, cs[0]);
        defer a.free(got);
        try testing.expectEqualStrings(cs[1], got);
    }
}
