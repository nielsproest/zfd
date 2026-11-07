//! arcfs: archives browsed in place, like folders (zip, tar.*, 7z, rar, iso, cpio,
//! and the zip-based documents and packages), read with libarchive. Nothing is
//! extracted to look inside: an archive's index (its entries' names, kinds, sizes
//! and dates) is read once and kept, and a folder inside it is listed from that.
//! Only what you act on is unpacked: one entry read into memory for a preview or a
//! thumbnail, or the entries you copy out extracted where you put them.
//!
//! A path inside an archive is the archive's own path plus the path within it:
//! "/home/me/pics.zip/2025/beach.jpg". `split` recognises one by the names in it
//! (no I/O, so the render thread can ask); the worker-thread calls check that the
//! archive part really is a file, so a real folder named "x.zip" stays a folder.
//!
//! Thread-safe: the index cache is shared by the scanner, preview and thumbnail
//! threads. GUI-free.

const std = @import("std");
const c = @import("c_archive");
const scan = @import("scan.zig");
const archive = @import("archive.zig");
const Progress = @import("progress.zig").Progress;

// POSIX file-type bits (libarchive's AE_IF* macros don't translate).
const ifmt: u32 = 0o170000;
const ifdir: u32 = 0o040000;
const ifreg: u32 = 0o100000;
const iflnk: u32 = 0o120000;

/// Split is a path inside an archive: the archive, and the path within it ("" for
/// its top level, never with a leading or trailing '/'). Both borrow the path.
pub const Split = struct { src: []const u8, inner: []const u8 };

/// opensAsFolder reports whether a file named `name` is browsed into like a folder.
pub fn opensAsFolder(name: []const u8) bool {
    return archive.isArchive(name) or archive.isPackage(name);
}

/// split finds the archive `path` goes into, by name only: its first component
/// (after the first) that names an archive. "/d/a.zip" → {"/d/a.zip", ""};
/// "/d/a.zip/x/y" → {"/d/a.zip", "x/y"}; "/d/x" → null.
pub fn split(path: []const u8) ?Split {
    if (path.len < 2 or path[0] != '/') return null;
    var start: usize = 1;
    while (start < path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, start, '/') orelse path.len;
        if (end > start and opensAsFolder(path[start..end])) {
            const inner = std.mem.trim(u8, path[end..], "/");
            return .{ .src = path[0..end], .inner = inner };
        }
        start = end + 1;
    }
    return null;
}

// --- the index -------------------------------------------------------------------

const Item = struct {
    path: []const u8, // within the archive, normalized (see norm)
    kind: scan.Kind,
    size: u64,
    mtime: i64,
    mode: u16,
    link: []const u8, // symlink target ("" for none)
};

const Index = struct {
    arena: std.heap.ArenaAllocator,
    src: []const u8,
    src_mtime: i64,
    src_size: u64,
    items: []Item,
    raw: bool, // a single compressed stream (photo.png.gz): one entry, its name made up
};

const cache_max = 8; // archives whose index is kept (the most recently used)
var cache_mutex: std.Io.Mutex = .init;
var cache: [cache_max]?*Index = @splat(null);
var cache_tick: [cache_max]u64 = @splat(0);
var cache_clock: u64 = 0;

/// norm turns an entry's stored name into its path within the archive: no "./" or
/// '/' in front, no '/' after. Null for a name that can't be shown safely (empty, or
/// with a ".." in it).
fn norm(raw: []const u8) ?[]const u8 {
    var p = raw;
    while (true) {
        if (std.mem.startsWith(u8, p, "./")) p = p[2..] else if (p.len > 0 and p[0] == '/') p = p[1..] else break;
    }
    p = std.mem.trimEnd(u8, p, "/");
    if (p.len == 0 or std.mem.eql(u8, p, ".")) return null;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return null;
    return p;
}

fn parentOf(p: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse return "";
    return p[0..slash];
}

const FileStat = struct { dir: bool, file: bool, size: u64, mtime: i64 };

fn statPath(path: []const u8) ?FileStat {
    const linux = std.os.linux;
    var zb: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{path}, 0) catch return null;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z.ptr, 0, .{ .TYPE = true, .SIZE = true, .MTIME = true }, &st)) != .SUCCESS) return null;
    const t: u32 = st.mode & ifmt;
    return .{ .dir = t == ifdir, .file = t == ifreg, .size = st.size, .mtime = st.mtime.sec * std.time.ns_per_s + st.mtime.nsec };
}

/// openRead opens `src` for reading with every format and filter libarchive has
/// (and the raw format last: a lone compressed stream).
fn openRead(src: []const u8) !*c.struct_archive {
    var zb: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{src}, 0) catch return error.NameTooLong;
    const a = c.archive_read_new() orelse return error.OutOfMemory;
    _ = c.archive_read_support_filter_all(a);
    _ = c.archive_read_support_format_all(a);
    _ = c.archive_read_support_format_raw(a);
    if (c.archive_read_open_filename(a, z.ptr, 64 * 1024) != c.ARCHIVE_OK) {
        _ = c.archive_read_free(a);
        return error.NotAnArchive;
    }
    return a;
}

fn entryName(e: ?*c.struct_archive_entry) []const u8 {
    const p = c.archive_entry_pathname_utf8(e) orelse c.archive_entry_pathname(e) orelse return "";
    return std.mem.sliceTo(p, 0);
}

/// rawName is the made-up name of a lone compressed stream's one entry: the archive's
/// name without the compression ("photo.png.gz" → "photo.png").
fn rawName(src: []const u8) []const u8 {
    const base = std.fs.path.basename(src);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return if (dot == 0) base else base[0..dot];
}

fn buildIndex(gpa: std.mem.Allocator, src: []const u8, st: FileStat) !*Index {
    const a = try openRead(src);
    defer _ = c.archive_read_free(a);
    const idx = try gpa.create(Index);
    idx.* = .{ .arena = .init(gpa), .src = "", .src_mtime = st.mtime, .src_size = st.size, .items = &.{}, .raw = false };
    errdefer {
        idx.arena.deinit();
        gpa.destroy(idx);
    }
    const ar = idx.arena.allocator();
    idx.src = try ar.dupe(u8, src);
    var items = std.ArrayList(Item).empty;
    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();
    var entry: ?*c.struct_archive_entry = null;
    while (true) {
        const rc = c.archive_read_next_header(a, &entry);
        if (rc == c.ARCHIVE_EOF) break;
        if (rc < c.ARCHIVE_WARN) {
            if (items.items.len == 0) return error.NotAnArchive;
            break; // a damaged tail: show what was readable
        }
        idx.raw = c.archive_format(a) == c.ARCHIVE_FORMAT_RAW;
        const name = if (idx.raw) rawName(src) else (norm(entryName(entry)) orelse continue);
        if (seen.contains(name)) continue; // a later copy of the same path (tar appends)
        const mode: u32 = @intCast(c.archive_entry_mode(entry));
        const kind: scan.Kind = switch (mode & ifmt) {
            ifdir => .dir,
            ifreg => .file,
            iflnk => .symlink,
            0 => if (std.mem.endsWith(u8, entryName(entry), "/")) .dir else .file,
            else => .other,
        };
        const path = try ar.dupe(u8, name);
        const link = if (kind == .symlink) (if (c.archive_entry_symlink(entry)) |l| try ar.dupe(u8, std.mem.sliceTo(l, 0)) else "") else "";
        const size: i64 = if (c.archive_entry_size_is_set(entry) != 0) c.archive_entry_size(entry) else 0;
        try items.append(ar, .{
            .path = path,
            .kind = kind,
            .size = @intCast(@max(size, 0)),
            .mtime = c.archive_entry_mtime(entry),
            .mode = @truncate(mode),
            .link = link,
        });
        try seen.put(path, {});
        if (idx.raw) break; // one stream, one entry
    }
    // Folders only implied by their contents' paths ("a/b/c.txt" with no "a/" entry).
    var i: usize = 0;
    const listed = items.items.len;
    while (i < listed) : (i += 1) {
        var p = parentOf(items.items[i].path);
        while (p.len > 0 and !seen.contains(p)) : (p = parentOf(p)) {
            try items.append(ar, .{ .path = p, .kind = .dir, .size = 0, .mtime = 0, .mode = @intCast(ifdir | 0o755), .link = "" });
            try seen.put(p, {});
        }
    }
    idx.items = try items.toOwnedSlice(ar);
    return idx;
}

/// withIndex runs `f(ctx, index)` on `src`'s index (read now if it isn't kept or the
/// archive changed since), under the cache lock. Worker threads only (it reads).
fn Payload(comptime f: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?).error_union.payload;
}

fn withIndex(io: std.Io, gpa: std.mem.Allocator, src: []const u8, st: FileStat, ctx: anytype, comptime f: anytype) !Payload(f) {
    cache_mutex.lockUncancelable(io);
    var found: ?usize = null;
    for (cache, 0..) |slot, i| if (slot) |idx| {
        if (std.mem.eql(u8, idx.src, src) and idx.src_mtime == st.mtime and idx.src_size == st.size) found = i;
    };
    if (found == null) {
        cache_mutex.unlock(io);
        // Read without the lock: a big tar.gz takes a while, and others shouldn't wait.
        const built = try buildIndex(std.heap.page_allocator, src, st);
        cache_mutex.lockUncancelable(io);
        var slot: usize = 0;
        for (cache, 0..) |s, i| {
            if (s) |idx| if (std.mem.eql(u8, idx.src, src)) {
                slot = i; // an older index of this archive: replace it
                break;
            };
            if (s == null or cache_tick[i] < cache_tick[slot]) slot = i;
        }
        if (cache[slot]) |old| {
            old.arena.deinit();
            std.heap.page_allocator.destroy(old);
        }
        cache[slot] = built;
        found = slot;
    }
    defer cache_mutex.unlock(io);
    cache_clock += 1;
    cache_tick[found.?] = cache_clock;
    return try f(ctx, gpa, cache[found.?].?);
}

fn archiveStat(src: []const u8) !FileStat {
    const st = statPath(src) orelse return error.FileNotFound;
    if (!st.file) return error.NotAnArchive; // (a folder named like one: the caller lists it)
    return st;
}

// --- listing ---------------------------------------------------------------------

/// readAny lists `path`: from its archive's index when it's inside one, else as a
/// folder on disk (scan.readDirOpts, with `stop` and `details` as there). A real
/// folder that only looks like an archive is read as a folder. Worker threads.
pub fn readAny(io: std.Io, alloc: std.mem.Allocator, path: []const u8, stop: ?*const bool, details: bool) !scan.Listing {
    if (split(path) != null) {
        if (list(io, alloc, path)) |l| return l else |e| if (e != error.NotAnArchive) return e;
    }
    return scan.readDirOpts(io, alloc, path, stop, details);
}

/// list lists the folder `path` points to inside an archive (worker thread).
/// error.NotAnArchive: the archive part isn't a file (list `path` as a folder).
pub fn list(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !scan.Listing {
    const sp = split(path) orelse return error.NotAnArchive;
    const st = try archiveStat(sp.src);
    return withIndex(io, alloc, sp.src, st, sp.inner, listIn);
}

fn listIn(inner: []const u8, alloc: std.mem.Allocator, idx: *Index) !scan.Listing {
    if (inner.len > 0) {
        const it = find(idx, inner) orelse return error.FileNotFound;
        if (it.kind != .dir) return error.NotDir;
    }
    var out = std.ArrayList(scan.Entry).empty;
    errdefer {
        for (out.items) |e| {
            alloc.free(e.name);
            if (e.link_target.len > 0) alloc.free(e.link_target);
        }
        out.deinit(alloc);
    }
    for (idx.items) |it| {
        if (!std.mem.eql(u8, parentOf(it.path), inner)) continue;
        const name = try alloc.dupe(u8, std.fs.path.basename(it.path));
        errdefer alloc.free(name);
        try out.append(alloc, .{
            .name = name,
            .kind = it.kind,
            .size = if (it.kind == .dir) 0 else it.size,
            .mtime_secs = it.mtime,
            .mode = it.mode,
            .link_target = if (it.link.len > 0) try alloc.dupe(u8, it.link) else &.{},
        });
    }
    return .{ .entries = try out.toOwnedSlice(alloc), .needs_details = false, .in_archive = true };
}

fn find(idx: *const Index, inner: []const u8) ?Item {
    for (idx.items) |it| if (std.mem.eql(u8, it.path, inner)) return it;
    return null;
}

/// Info is an entry's details, from the index.
pub const Info = struct { kind: scan.Kind, size: u64, mtime: i64, mode: u16 };

/// info returns the details of the entry `path` points to (worker thread). The
/// archive's top level is a folder.
pub fn info(io: std.Io, path: []const u8) !Info {
    const sp = split(path) orelse return error.NotAnArchive;
    const st = try archiveStat(sp.src);
    if (sp.inner.len == 0) return .{ .kind = .dir, .size = st.size, .mtime = @divTrunc(st.mtime, std.time.ns_per_s), .mode = @intCast(ifdir | 0o755) };
    return withIndex(io, std.heap.page_allocator, sp.src, st, sp.inner, infoIn);
}

fn infoIn(inner: []const u8, _: std.mem.Allocator, idx: *Index) !Info {
    const it = find(idx, inner) orelse return error.FileNotFound;
    return .{ .kind = it.kind, .size = it.size, .mtime = it.mtime, .mode = it.mode };
}

/// names returns the paths (within the archive, "/"-joined) of everything under the
/// folder `path` points to, folders marked with a trailing '/', at most `max`
/// (worker thread). For previews.
pub const Names = struct { list: [][]u8, total: usize };

pub fn names(io: std.Io, alloc: std.mem.Allocator, path: []const u8, max: usize) !Names {
    const sp = split(path) orelse return error.NotAnArchive;
    const st = try archiveStat(sp.src);
    const Ctx = struct { inner: []const u8, max: usize };
    return withIndex(io, alloc, sp.src, st, Ctx{ .inner = sp.inner, .max = max }, struct {
        fn f(cx: Ctx, a: std.mem.Allocator, idx: *Index) !Names {
            var out = std.ArrayList([]u8).empty;
            errdefer {
                for (out.items) |n| a.free(n);
                out.deinit(a);
            }
            var total: usize = 0;
            for (idx.items) |it| {
                if (!std.mem.eql(u8, parentOf(it.path), cx.inner)) continue;
                total += 1;
                if (out.items.len >= cx.max) continue;
                try out.append(a, try a.print("{s}{s}", .{ std.fs.path.basename(it.path), if (it.kind == .dir) "/" else "" }));
            }
            return .{ .list = try out.toOwnedSlice(a), .total = total };
        }
    }.f);
}

// --- reading and extracting ------------------------------------------------------

/// read returns the contents of the file `path` points to inside an archive, read
/// into memory (worker thread). error.FileTooBig past `max` bytes.
pub fn read(alloc: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return readUpTo(alloc, path, max, false);
}

/// readStart returns the first `max` bytes (or all, if fewer) of the file `path`
/// points to inside an archive (worker thread). For previews of text.
pub fn readStart(alloc: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return readUpTo(alloc, path, max, true);
}

fn readUpTo(alloc: std.mem.Allocator, path: []const u8, max: usize, cut: bool) ![]u8 {
    const sp = split(path) orelse return error.NotAnArchive;
    _ = try archiveStat(sp.src);
    const a = try openRead(sp.src);
    defer _ = c.archive_read_free(a);
    var entry: ?*c.struct_archive_entry = null;
    while (true) {
        const rc = c.archive_read_next_header(a, &entry);
        if (rc == c.ARCHIVE_EOF) return error.FileNotFound;
        if (rc < c.ARCHIVE_WARN) return error.ReadFailed;
        const raw = c.archive_format(a) == c.ARCHIVE_FORMAT_RAW;
        const name = if (raw) rawName(sp.src) else (norm(entryName(entry)) orelse continue);
        if (!std.mem.eql(u8, name, sp.inner)) continue;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = c.archive_read_data(a, &buf, buf.len);
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            const got: usize = @intCast(n);
            if (out.items.len + got > max) {
                if (!cut) return error.FileTooBig;
                try out.appendSlice(alloc, buf[0 .. max - out.items.len]);
                break;
            }
            try out.appendSlice(alloc, buf[0..got]);
        }
        return out.toOwnedSlice(alloc);
    }
}

/// extract unpacks the entries `paths` point to (all inside the same archive; a
/// folder with everything under it) into the folder `dst`, each under its own name:
/// "pics.zip/2025" lands as "<dst>/2025/…" (worker thread). Absolute names and ".."
/// are dropped, and nothing is written through a symlink. `prog`, when given,
/// counts the files and bytes written, and its Cancel ends it (error.Canceled).
pub fn extract(paths: []const []const u8, dst: []const u8, prog: ?*Progress) !void {
    if (paths.len == 0) return;
    const first = split(paths[0]) orelse return error.NotAnArchive;
    _ = try archiveStat(first.src);
    const a = try openRead(first.src);
    defer _ = c.archive_read_free(a);
    const w = c.archive_write_disk_new() orelse return error.OutOfMemory;
    defer _ = c.archive_write_free(w);
    // The names written are dst + an entry name that norm already cleared of a
    // leading '/' and of ".." (so not NOABSOLUTEPATHS: dst itself is absolute);
    // libarchive still refuses ".." and writing through a symlink on top.
    _ = c.archive_write_disk_set_options(w, c.ARCHIVE_EXTRACT_TIME | c.ARCHIVE_EXTRACT_SECURE_NODOTDOT |
        c.ARCHIVE_EXTRACT_SECURE_SYMLINKS);

    var entry: ?*c.struct_archive_entry = null;
    var wrote = false;
    while (true) {
        if (prog) |p| if (p.canceled()) return error.Canceled;
        const rc = c.archive_read_next_header(a, &entry);
        if (rc == c.ARCHIVE_EOF) break;
        if (rc < c.ARCHIVE_WARN) return error.ReadFailed;
        const raw = c.archive_format(a) == c.ARCHIVE_FORMAT_RAW;
        const name = if (raw) rawName(first.src) else (norm(entryName(entry)) orelse continue);
        // Which chosen entry this is (or is under), and its name in `dst`.
        var out_rel: ?[]const u8 = null;
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        for (paths) |p| {
            const sp = split(p) orelse continue;
            const under = std.mem.eql(u8, name, sp.inner) or (sp.inner.len == 0) or
                (std.mem.startsWith(u8, name, sp.inner) and name.len > sp.inner.len and name[sp.inner.len] == '/');
            if (!under) continue;
            const keep = if (sp.inner.len == 0) name else name[parentOf(sp.inner).len + @intFromBool(parentOf(sp.inner).len > 0) ..];
            out_rel = std.fmt.bufPrint(&rel_buf, "{s}", .{keep}) catch continue;
            break;
        }
        const rel = out_rel orelse continue;
        var full_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const full = std.fmt.bufPrintSentinel(&full_buf, "{s}/{s}", .{ dst, rel }, 0) catch return error.NameTooLong;
        c.archive_entry_set_pathname(entry, full.ptr);
        // A hard link names another entry: inside dst too, or not at all.
        if (c.archive_entry_hardlink(entry)) |hl| {
            const target = norm(std.mem.sliceTo(hl, 0)) orelse "";
            var hb: [std.fs.max_path_bytes + 1]u8 = undefined;
            const h = std.fmt.bufPrintSentinel(&hb, "{s}/{s}", .{ dst, target }, 0) catch return error.NameTooLong;
            c.archive_entry_set_hardlink(entry, h.ptr);
        }
        if (prog) |p| p.setCurrent(std.fs.path.basename(name));
        if (c.archive_write_header(w, entry) < c.ARCHIVE_WARN) return error.WriteFailed;
        while (true) {
            if (prog) |p| if (p.canceled()) return error.Canceled;
            var block: ?*const anyopaque = null;
            var size: usize = 0;
            var off: i64 = 0;
            const r = c.archive_read_data_block(a, &block, &size, &off);
            if (r == c.ARCHIVE_EOF) break;
            if (r < c.ARCHIVE_WARN) return error.ReadFailed;
            if (c.archive_write_data_block(w, block, size, off) < 0) return error.WriteFailed;
            if (prog) |p| p.addBytes(size);
        }
        if (c.archive_write_finish_entry(w) < c.ARCHIVE_WARN) return error.WriteFailed;
        if (prog) |p| p.addFile();
        wrote = true;
    }
    if (!wrote) return error.FileNotFound;
}

/// Measure is how much is under an entry: files (a folder counts its files) and
/// bytes.
pub const Measure = struct { files: u64 = 0, bytes: u64 = 0 };

/// measure totals what extracting the entry `path` points to writes (worker thread).
pub fn measure(io: std.Io, path: []const u8) Measure {
    const sp = split(path) orelse return .{};
    const st = archiveStat(sp.src) catch return .{};
    return withIndex(io, std.heap.page_allocator, sp.src, st, sp.inner, struct {
        fn f(inner: []const u8, _: std.mem.Allocator, idx: *Index) !Measure {
            var m: Measure = .{};
            for (idx.items) |it| {
                const under = inner.len == 0 or std.mem.eql(u8, it.path, inner) or
                    (std.mem.startsWith(u8, it.path, inner) and it.path.len > inner.len and it.path[inner.len] == '/');
                if (!under or it.kind == .dir) continue;
                m.files += 1;
                m.bytes += it.size;
            }
            return m;
        }
    }.f) catch .{};
}

/// isArchived reports whether `path` is inside an archive rather than on disk: it
/// goes into one by name, and there's no such file or folder (worker thread).
pub fn isArchived(path: []const u8) bool {
    const sp = split(path) orelse return false;
    if (sp.inner.len == 0) return false; // the archive file itself
    return statPath(path) == null and (statPath(sp.src) orelse return false).file;
}

/// sameArchive reports whether every one of `paths` is inside the same archive.
pub fn sameArchive(paths: []const []const u8) bool {
    if (paths.len == 0) return false;
    const first = split(paths[0]) orelse return false;
    for (paths[1..]) |p| {
        const sp = split(p) orelse return false;
        if (!std.mem.eql(u8, sp.src, first.src)) return false;
    }
    return true;
}

// --- tests -----------------------------------------------------------------------

const testing = std.testing;

test "split finds the archive a path goes into, by name" {
    const s = split("/d/a.zip/x/y").?;
    try testing.expectEqualStrings("/d/a.zip", s.src);
    try testing.expectEqualStrings("x/y", s.inner);
    const top = split("/d/pics.tar.gz/").?;
    try testing.expectEqualStrings("/d/pics.tar.gz", top.src);
    try testing.expectEqualStrings("", top.inner);
    try testing.expect(split("/d/x/y") == null);
    try testing.expect(split("relative/a.zip") == null);
}

test "norm keeps safe names and drops the rest" {
    try testing.expectEqualStrings("a/b", norm("./a/b/").?);
    try testing.expectEqualStrings("a", norm("/a").?);
    try testing.expect(norm("../etc/passwd") == null);
    try testing.expect(norm("a/../../b") == null);
    try testing.expect(norm("./") == null);
}

/// writeZip makes a small zip at `path` (with libarchive's writer): a.txt, sub/b.txt
/// and an implied folder deep/er/c.txt.
fn writeZip(path: [:0]const u8) !void {
    const a = c.archive_write_new() orelse return error.OutOfMemory;
    defer _ = c.archive_write_free(a);
    _ = c.archive_write_set_format_zip(a);
    if (c.archive_write_open_filename(a, path.ptr) != c.ARCHIVE_OK) return error.WriteFailed;
    const files = [_]struct { name: [:0]const u8, data: []const u8 }{
        .{ .name = "a.txt", .data = "alpha" },
        .{ .name = "sub/b.txt", .data = "bravo!" },
        .{ .name = "deep/er/c.txt", .data = "c" },
    };
    for (files) |f| {
        const e = c.archive_entry_new() orelse return error.OutOfMemory;
        defer c.archive_entry_free(e);
        c.archive_entry_set_pathname(e, f.name.ptr);
        c.archive_entry_set_size(e, @intCast(f.data.len));
        c.archive_entry_set_filetype(e, ifreg);
        c.archive_entry_set_perm(e, 0o644);
        _ = c.archive_write_header(a, e);
        _ = c.archive_write_data(a, f.data.ptr, f.data.len);
    }
    _ = c.archive_write_close(a);
}

test "an archive lists, reads and extracts without being unpacked" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const zip = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/t.zip", .{root}, 0);
    defer testing.allocator.free(zip);
    try writeZip(zip);

    // The top level: a.txt, sub/, deep/ (implied by deep/er/c.txt).
    var top = try list(io, testing.allocator, zip);
    defer top.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), top.entries.len);
    try testing.expect(top.in_archive);
    var saw_deep = false;
    for (top.entries) |e| if (std.mem.eql(u8, e.name, "deep")) {
        saw_deep = true;
        try testing.expect(e.isDir());
    };
    try testing.expect(saw_deep);

    const sub_path = try std.fmt.allocPrint(testing.allocator, "{s}/sub", .{zip});
    defer testing.allocator.free(sub_path);
    var sub = try list(io, testing.allocator, sub_path);
    defer sub.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), sub.entries.len);
    try testing.expectEqualStrings("b.txt", sub.entries[0].name);
    try testing.expectEqual(@as(u64, 6), sub.entries[0].size);

    const b_path = try std.fmt.allocPrint(testing.allocator, "{s}/sub/b.txt", .{zip});
    defer testing.allocator.free(b_path);
    const data = try read(testing.allocator, b_path, 1024);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("bravo!", data);
    try testing.expectError(error.NotDir, list(io, testing.allocator, b_path));

    // Extracting "sub" lands it as <dst>/sub/b.txt, nothing else.
    try tmp.dir.createDirPath(io, "out");
    const out = try std.fmt.allocPrint(testing.allocator, "{s}/out", .{root});
    defer testing.allocator.free(out);
    try extract(&.{sub_path}, out, null);
    const got = try tmp.dir.readFileAlloc(io, "out/sub/b.txt", testing.allocator, .limited(64));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("bravo!", got);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "out/a.txt", .{}));

    // Nothing was ever written next to the archive.
    var it = tmp.dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try testing.expectEqual(@as(usize, 2), n); // t.zip and out
}
