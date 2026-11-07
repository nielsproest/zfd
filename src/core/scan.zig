//! Directory listing model, ported from GoFileDialog (the `entry` model in
//! internal/ui/explorer.go + HumanizeSize in internal/scan). `readDir` uses the
//! directory's d_type only — no per-file `stat` — so listing a huge folder is one
//! cheap syscall pass, the fast path the Go version relies on. This blocking read
//! is meant to run on a worker thread (goal 1: never on the render thread); the
//! threading wrapper lives in the platform layer, keeping this piece pure and
//! testable against a real temp directory.

const std = @import("std");
const tags = @import("tags.zig");
const Dir = std.Io.Dir;

pub const Kind = enum { file, dir, symlink, other };

/// Entry is one directory child. `name` is owned by the containing Listing. Kind
/// comes from readdir's d_type; `size`/`mtime_secs` come from a follow-symlink stat
/// (0 when the stat failed, e.g. a broken symlink). All of this is gathered on the
/// worker thread, never the render thread (goal 1).
pub const Entry = struct {
    name: []u8,
    kind: Kind,
    size: u64 = 0, // bytes; meaningful for files (dirs display "—")
    mtime_secs: i64 = 0, // modification time, seconds since the Unix epoch (0 = unknown)
    // Extra metadata from statx (for the optional columns + Properties). All from the
    // one stat the scanner already does, so no extra render-thread I/O (goal 1).
    atime_secs: i64 = 0, // last access
    ctime_secs: i64 = 0, // last status change
    btime_secs: i64 = 0, // creation/birth (0 if the filesystem has none)
    mode: u16 = 0, // file type + permission bits
    uid: u32 = 0,
    gid: u32 = 0,
    inode: u64 = 0,
    nlink: u32 = 0,
    link_target: []u8 = &.{}, // symlink target (owned; empty for non-links)
    tags: tags.Mask = 0, // tag bits (tags.Tag) from the user.xdg.tags xattr
    pending: bool = false, // listed by name only: the fields above are still to come

    pub fn isDir(self: Entry) bool {
        return self.kind == .dir;
    }
};

/// Listing owns the entry slice and every entry name. Free it with `deinit`.
pub const Listing = struct {
    entries: []Entry,
    // Space on the filesystem holding the folder (0/0 = unknown, e.g. /proc).
    free_bytes: u64 = 0,
    total_bytes: u64 = 0,
    // Names and kinds only so far: the details (sizes, dates, tags) are still to come
    // (details.zig fills them in off the render thread).
    needs_details: bool = false,

    pub fn deinit(self: Listing, alloc: std.mem.Allocator) void {
        for (self.entries) |e| {
            alloc.free(e.name);
            if (e.link_target.len > 0) alloc.free(e.link_target);
        }
        alloc.free(self.entries);
    }
};

/// readDir lists `path`. Hidden entries (dotfiles) are included; "." and ".." are
/// not (iterate already omits them). The caller owns the Listing. `io` is Zig
/// 0.16's I/O handle — the app passes the one from its worker thread, so this
/// blocking read stays off the render thread (goal 1).
pub fn readDir(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !Listing {
    return readDirStoppable(io, alloc, path, null);
}

/// readDirStoppable is readDir that gives up with error.Canceled once `stop` turns
/// true (checked between entries): the scanner's way to abandon a big or slow folder
/// you've already left, instead of making the next one wait for it.
pub fn readDirStoppable(io: std.Io, alloc: std.mem.Allocator, path: []const u8, stop: ?*const bool) !Listing {
    return readDirOpts(io, alloc, path, stop, true);
}

/// readDirOpts is readDirStoppable that can leave out the details (`details` false):
/// names and kinds only, which readdir gives without a stat per entry. The scanner
/// lists that way so a folder shows at once; details.zig fills the rest in.
pub fn readDirOpts(io: std.Io, alloc: std.mem.Allocator, path: []const u8, stop: ?*const bool, details: bool) !Listing {
    var dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var l = try readDirWith(io, alloc, dir, stop, details);
    // Free space rides along with the listing: it's measured here, on the scanner
    // thread, because statfs on a stalled network mount blocks just like readdir does.
    if (fsSpace(dir.handle)) |sp| {
        l.free_bytes = sp[0];
        l.total_bytes = sp[1];
    }
    return l;
}

/// Linux x86_64 `struct statfs` (the kernel ABI; std has no wrapper).
pub const StatFs = extern struct {
    f_type: isize,
    f_bsize: isize,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: isize,
    f_frsize: isize,
    f_flags: isize,
    f_spare: [4]isize,
};

/// fsSpace returns {available-to-us bytes, total bytes} for the filesystem holding
/// the open fd, or null (pseudo filesystems report 0 blocks).
fn fsSpace(fd: std.posix.fd_t) ?[2]u64 {
    var st: StatFs = undefined;
    const rc = std.os.linux.syscall2(.fstatfs, @as(usize, @bitCast(@as(isize, fd))), @intFromPtr(&st));
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    const unit: u64 = @intCast(if (st.f_frsize > 0) st.f_frsize else st.f_bsize);
    if (st.f_blocks == 0 or unit == 0) return null;
    return .{ st.f_bavail * unit, st.f_blocks * unit };
}

/// readDirFrom lists an already-open iterable directory — the primitive `readDir`
/// wraps, and the seam tests use so they can point at a temp dir handle.
pub fn readDirFrom(io: std.Io, alloc: std.mem.Allocator, dir: Dir, stop: ?*const bool) !Listing {
    return readDirWith(io, alloc, dir, stop, true);
}

fn readDirWith(io: std.Io, alloc: std.mem.Allocator, dir: Dir, stop: ?*const bool, details: bool) !Listing {
    var list = std.ArrayList(Entry).empty;
    errdefer {
        for (list.items) |e| alloc.free(e.name);
        list.deinit(alloc);
    }
    var it = dir.iterate();
    while (true) {
        // Resilient iteration: a single entry the mount can't decode — e.g. a non-UTF-8
        // name on an NFS/SMB share makes getdents return EILSEQ/EINVAL, which Zig
        // surfaces as error.BadPathName — must NOT blank the whole directory. Stop at the
        // bad entry and return what we gathered so far rather than propagating the error.
        if (stop) |st| if (list.items.len % 256 == 0 and @atomicLoad(bool, st, .acquire)) return error.Canceled;
        const next = it.next(io) catch break;
        const e = next orelse break;
        const kind: Kind = switch (e.kind) {
            .directory => .dir,
            .file => .file,
            .sym_link => .symlink,
            else => .other,
        };
        // One statx per entry (off the render thread, goal 1) for size/times/mode/
        // owner — feeds the optional columns + Properties. A failure (e.g. a broken
        // symlink) just leaves the metadata at 0 rather than dropping the entry.
        var entry = Entry{ .name = try alloc.dupe(u8, e.name), .kind = kind, .pending = !details };
        errdefer alloc.free(entry.name);
        if (details) fillDetails(alloc, dir, e.name, &entry);
        try list.append(alloc, entry);
    }
    return .{ .entries = try list.toOwnedSlice(alloc), .needs_details = !details };
}

/// fillDetails looks up `name`'s details in the open `dir`: one statx, its tags, and
/// a link's target (owned). Best-effort: what fails stays 0.
pub fn fillDetails(alloc: std.mem.Allocator, dir: Dir, name: []const u8, entry: *Entry) void {
    fillStat(dir.handle, name, entry);
    fillTags(dir.handle, name, entry);
    if (entry.kind == .symlink) entry.link_target = readLinkAt(alloc, dir.handle, name);
}

/// FilesSize is what directFilesSize found: the bytes and count of the regular files
/// directly in a folder; `partial` when it stopped at the entry limit.
pub const FilesSize = struct { bytes: u64 = 0, files: u32 = 0, items: u32 = 0, partial: bool = false }; // items: everything not hidden, folders too

/// directFilesSize adds up the files directly inside `path` — never descending into
/// subfolders (a recursive total of a 1 TB tree would mean walking all of it), and
/// stopping after `limit` entries. Symlinks aren't followed. Off the render thread.
pub fn directFilesSize(io: std.Io, path: []const u8, limit: usize) FilesSize {
    var out: FilesSize = .{};
    var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return out;
    defer dir.close(io);
    var it = dir.iterate();
    var seen: usize = 0;
    while (true) {
        const e = (it.next(io) catch break) orelse break;
        seen += 1;
        if (seen > limit) {
            out.partial = true;
            break;
        }
        if (e.name.len > 0 and e.name[0] != '.') out.items += 1;
        if (e.kind != .file) continue;
        var nbuf: [512]u8 = undefined;
        const name_z = std.mem.printSentinel(&nbuf, "{s}", .{e.name}, 0) catch continue;
        var sx: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(dir.handle, name_z.ptr, std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .SIZE = true }, &sx);
        if (@as(isize, @bitCast(rc)) < 0) continue;
        out.bytes += sx.size;
        out.files += 1;
    }
    return out;
}

test "directFilesSize counts only the files directly inside" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "12345" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b", .data = "123" });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/deep", .data = "1234567890" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const got = directFilesSize(io, root, 100);
    try testing.expectEqual(@as(u64, 8), got.bytes);
    try testing.expectEqual(@as(u32, 2), got.files);
    try testing.expect(!got.partial);
    try testing.expect(directFilesSize(io, root, 1).partial);
}

/// entryAt builds one Entry for `name_in_dir` inside the open `dir`, recording it
/// under `display_name` (owned copy) — e.g. a subfolder search shows "sub/x.txt".
pub fn entryAt(alloc: std.mem.Allocator, dir: Dir, name_in_dir: []const u8, display_name: []const u8, kind: Kind) !Entry {
    var entry = Entry{ .name = try alloc.dupe(u8, display_name), .kind = kind };
    fillStat(dir.handle, name_in_dir, &entry);
    fillTags(dir.handle, name_in_dir, &entry);
    if (kind == .symlink) entry.link_target = readLinkAt(alloc, dir.handle, name_in_dir);
    return entry;
}

/// fillTags reads the entry's colour tags (one lgetxattr, through the open directory
/// via /proc so it costs no path walk). Filesystems without xattrs just leave 0.
fn fillTags(dirfd: std.posix.fd_t, name: []const u8, entry: *Entry) void {
    var pbuf: [600]u8 = undefined;
    const p = if (dirfd == std.posix.AT.FDCWD or (name.len > 0 and name[0] == '/'))
        std.mem.printSentinel(&pbuf, "{s}", .{name}, 0) catch return
    else
        std.mem.printSentinel(&pbuf, "/proc/self/fd/{d}/{s}", .{ dirfd, name }, 0) catch return;
    entry.tags = tags.readMask(p);
}

/// fillStat does one statx (following symlinks) for the entry's size/times/mode/
/// owner. Best-effort — on failure the fields stay 0.
fn fillStat(dirfd: std.posix.fd_t, name: []const u8, entry: *Entry) void {
    var nbuf: [512]u8 = undefined;
    const name_z = std.mem.printSentinel(&nbuf, "{s}", .{name}, 0) catch return;
    var sx: std.os.linux.Statx = undefined;
    const mask = std.os.linux.STATX{
        .TYPE = true,
        .MODE = true,
        .NLINK = true,
        .UID = true,
        .GID = true,
        .ATIME = true,
        .MTIME = true,
        .CTIME = true,
        .INO = true,
        .SIZE = true,
        .BTIME = true,
    };
    const rc = std.os.linux.statx(dirfd, name_z.ptr, 0, mask, &sx);
    if (@as(isize, @bitCast(rc)) < 0) return; // -errno on failure; 0 on success
    entry.size = sx.size;
    entry.mtime_secs = sx.mtime.sec;
    entry.atime_secs = sx.atime.sec;
    entry.ctime_secs = sx.ctime.sec;
    entry.btime_secs = if (sx.mask.BTIME) sx.btime.sec else 0;
    entry.mode = sx.mode;
    entry.uid = sx.uid;
    entry.gid = sx.gid;
    entry.inode = sx.ino;
    entry.nlink = sx.nlink;
}

/// readLinkAt returns a symlink's target (owned, empty on failure). Off-thread.
fn readLinkAt(alloc: std.mem.Allocator, dirfd: std.posix.fd_t, name: []const u8) []u8 {
    var nbuf: [512]u8 = undefined;
    const name_z = std.mem.printSentinel(&nbuf, "{s}", .{name}, 0) catch return &.{};
    var target: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.readlinkat(dirfd, name_z.ptr, &target, target.len);
    const n = @as(isize, @bitCast(rc));
    if (n < 0) return &.{}; // -errno on failure; else bytes written (not NUL-terminated)
    return alloc.dupe(u8, target[0..@intCast(n)]) catch &.{};
}

/// formatMode renders "drwxr-xr-x"-style permissions into buf (10 chars).
pub fn formatMode(buf: *[10]u8, mode: u16) []const u8 {
    const S = std.posix.S;
    buf[0] = switch (mode & S.IFMT) {
        S.IFDIR => 'd',
        S.IFLNK => 'l',
        S.IFCHR => 'c',
        S.IFBLK => 'b',
        S.IFIFO => 'p',
        S.IFSOCK => 's',
        else => '-',
    };
    const glyph = "rwxrwxrwx";
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        const on = (mode & (@as(u16, 0o400) >> @as(u4, @intCast(i)))) != 0;
        buf[i + 1] = if (on) glyph[i] else '-';
    }
    return buf[0..10];
}

// Owner/group names are looked up via libc getpwuid/getgrgid, but that can be slow
// (NSS: LDAP/AD). A tiny direct-mapped, allocator-free cache keeps the opt-in Owner/
// Group columns from re-resolving every row every frame. Render-thread only.
const NameCache = struct {
    const N = 64;
    ids: [N]u32 = @splat(std.math.maxInt(u32)),
    valid: [N]bool = @splat(false),
    names: [N][32]u8 = undefined,
    lens: [N]u8 = @splat(0),

    fn get(self: *NameCache, id: u32, resolve: *const fn (u32) ?[*:0]const u8) []const u8 {
        const slot = id % N;
        if (self.valid[slot] and self.ids[slot] == id) return self.names[slot][0..self.lens[slot]];
        var numbuf: [32]u8 = undefined;
        const name = if (resolve(id)) |nm| std.mem.span(nm) else (std.mem.print(&numbuf, "{d}", .{id}) catch "?");
        const n = @min(name.len, 32);
        @memcpy(self.names[slot][0..n], name[0..n]);
        self.lens[slot] = @intCast(n);
        self.ids[slot] = id;
        self.valid[slot] = true;
        return self.names[slot][0..n];
    }
};

var owner_cache: NameCache = .{};
var group_cache: NameCache = .{};

fn pwName(uid: u32) ?[*:0]const u8 {
    return if (std.c.getpwuid(uid)) |pw| pw.name else null;
}
fn grName(gid: u32) ?[*:0]const u8 {
    return if (std.c.getgrgid(gid)) |gr| gr.name else null;
}

/// ownerName / groupName resolve uid/gid to names (numeric fallback), cached. The
/// result points into the cache — render it before the next same-slot lookup.
pub fn ownerName(uid: u32) []const u8 {
    return owner_cache.get(uid, pwName);
}
pub fn groupName(gid: u32) []const u8 {
    return group_cache.get(gid, grName);
}

pub const SortColumn = enum { name, size, date, type, created, accessed, changed, perms, owner, group, link, opens };

/// SortOrder picks the column and direction. Directories always sort before files
/// regardless (the familiar file-manager grouping, goal 6); equal keys tie-break by
/// case-insensitive name ascending for a stable order.
pub const SortOrder = struct {
    column: SortColumn = .name,
    ascending: bool = true,
    dirs_first: bool = true, // group directories before files (toggleable in Options)
};

/// sortByName is the default ordering (dirs first, name A–Z).
pub fn sortByName(entries: []Entry) void {
    sortEntries(entries, .{});
}

/// sortEntries orders an entry slice in place per `order`.
pub fn sortEntries(entries: []Entry, order: SortOrder) void {
    std.mem.sort(Entry, entries, order, lessBy);
}

/// sortView orders an array of indices into `entries` (used for the browser's
/// filtered view, leaving the underlying listing untouched).
pub fn sortView(indices: []usize, entries: []const Entry, order: SortOrder) void {
    const Ctx = struct {
        entries: []const Entry,
        order: SortOrder,
        fn less(ctx: @This(), ia: usize, ib: usize) bool {
            return lessBy(ctx.order, ctx.entries[ia], ctx.entries[ib]);
        }
    };
    std.mem.sort(usize, indices, Ctx{ .entries = entries, .order = order }, Ctx.less);
}

fn lessBy(order: SortOrder, a: Entry, b: Entry) bool {
    if (order.dirs_first and a.isDir() != b.isDir()) return a.isDir(); // directories grouped first
    var primary = switch (order.column) {
        .name => nameOrder(a.name, b.name),
        .size => std.math.order(a.size, b.size),
        .date => std.math.order(a.mtime_secs, b.mtime_secs),
        .type => std.math.order(@backingInt(category(a)), @backingInt(category(b))),
        .created => std.math.order(a.btime_secs, b.btime_secs),
        .accessed => std.math.order(a.atime_secs, b.atime_secs),
        .changed => std.math.order(a.ctime_secs, b.ctime_secs),
        .perms => std.math.order(a.mode, b.mode),
        .owner => std.math.order(a.uid, b.uid),
        .group => std.math.order(a.gid, b.gid),
        .link => nameOrder(a.link_target, b.link_target),
        .opens => extOrder(a.name, b.name),
    };
    if (!order.ascending) primary = primary.invert();
    if (primary != .eq) return primary == .lt;
    return nameOrder(a.name, b.name) == .lt; // stable tie-break: name ascending
}

/// extOrder compares the lowercased extensions (for the "Opens with" column, which
/// resolves per-app; same extension ≈ same app, so this groups them without MIME I/O).
fn extOrder(a: []const u8, b: []const u8) std.math.Order {
    var ba: [16]u8 = undefined;
    var bb: [16]u8 = undefined;
    return nameOrder(lowerExt(a, &ba), lowerExt(b, &bb));
}

fn nameOrder(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca != cb) return if (ca < cb) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

/// humanizeSize formats a byte count as "N B" / "N.N KB" … into `buf` (32 bytes is
/// always enough) and returns the used slice. Ported byte-for-byte from Go's
/// HumanizeSize (1024-base, one decimal, K/M/G/… suffixes).
pub fn humanizeSize(buf: []u8, n: u64) []const u8 {
    const unit: u64 = 1024;
    if (n < unit) return std.mem.print(buf, "{d} B", .{n}) catch buf[0..0];
    var div: u64 = unit;
    var exp: usize = 0;
    var v = n / unit;
    while (v >= unit) : (v /= unit) {
        div *= unit;
        exp += 1;
    }
    const suffixes = "KMGTPEZYRQ";
    const value = @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(div));
    return std.mem.print(buf, "{d:.1} {c}B", .{ value, suffixes[exp] }) catch buf[0..0];
}

pub const Category = enum { folder, link, image, video, audio, text, pdf, archive, source, library, other };

/// GroupBy is how a view splits its items into sections (Finder's Use Groups).
pub const GroupBy = enum(u8) { none = 0, kind = 1, date = 2, size = 3, tags = 4 };

/// groupKey is the section `e` falls in under `by`; sections show in key order.
/// `today` is the local day number (localSecs(now) / 86400) for date groups.
pub fn groupKey(by: GroupBy, e: Entry, today: i64) u8 {
    return switch (by) {
        .none => 0,
        .kind => switch (category(e)) {
            .folder => 0,
            .image => 1,
            .video => 2,
            .audio => 3,
            .pdf, .text => 4,
            .source => 5,
            .archive => 6,
            .library => 7,
            .link => 8,
            .other => 9,
        },
        .date => blk: {
            if (e.mtime_secs <= 0) break :blk 6;
            const days = today - @divFloor(localSecs(e.mtime_secs), 86400);
            break :blk if (days <= 0) 0 else if (days == 1) 1 else if (days < 7) 2 else if (days < 30) 3 else if (days < 365) 4 else 5;
        },
        .size => if (e.isDir()) 0 else if (e.size >= 1 << 30) 1 else if (e.size >= 100 << 20) 2 else if (e.size >= 1 << 20) 3 else if (e.size >= 100 << 10) 4 else if (e.size > 0) 5 else 6,
        .tags => if (e.tags == 0) tags.max_tags else @ctz(e.tags),
    };
}

/// groupLabel is the heading of section `key` under `by`.
pub fn groupLabel(by: GroupBy, key: u8) []const u8 {
    return switch (by) {
        .none => "",
        .kind => switch (key) {
            0 => "Folders",
            1 => "Images",
            2 => "Movies",
            3 => "Music",
            4 => "Documents",
            5 => "Source Code",
            6 => "Archives",
            7 => "Libraries",
            8 => "Links",
            else => "Other",
        },
        .date => switch (key) {
            0 => "Today",
            1 => "Yesterday",
            2 => "Previous 7 Days",
            3 => "Previous 30 Days",
            4 => "Earlier This Year",
            5 => "Older",
            else => "Unknown Date",
        },
        .size => switch (key) {
            0 => "Folders",
            1 => "Huge (1 GB or more)",
            2 => "Large (100 MB to 1 GB)",
            3 => "Medium (1 to 100 MB)",
            4 => "Small (100 KB to 1 MB)",
            5 => "Tiny (under 100 KB)",
            else => "Empty",
        },
        .tags => if (key < tags.list().len) tags.list()[key].name() else "No Tags",
    };
}

/// groupView orders sorted `indices` into sections, keeping the sort within each
/// (a stable sort on the section key).
pub fn groupView(indices: []usize, entries: []const Entry, by: GroupBy, today: i64) void {
    if (by == .none) return;
    const Ctx = struct {
        entries: []const Entry,
        by: GroupBy,
        today: i64,
        fn less(ctx: @This(), ia: usize, ib: usize) bool {
            return groupKey(ctx.by, ctx.entries[ia], ctx.today) < groupKey(ctx.by, ctx.entries[ib], ctx.today);
        }
    };
    std.sort.block(usize, indices, Ctx{ .entries = entries, .by = by, .today = today }, Ctx.less);
}

test "groupView keeps the sort inside each section" {
    var es = [_]Entry{
        .{ .name = @constCast("b.png"), .kind = .file },
        .{ .name = @constCast("dir"), .kind = .dir },
        .{ .name = @constCast("a.png"), .kind = .file },
        .{ .name = @constCast("c.txt"), .kind = .file },
    };
    var idx = [_]usize{ 2, 0, 3, 1 }; // a.png, b.png, c.txt, dir — sorted by name
    groupView(&idx, &es, .kind, 0);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0, 3 }, &idx);
    try testing.expectEqualStrings("Images", groupLabel(.kind, groupKey(.kind, es[2], 0)));
}

/// category classifies an entry for the Type column and row colors (by extension).
pub fn category(e: Entry) Category {
    if (e.isDir()) return .folder;
    if (e.kind == .symlink) return .link;
    var buf: [16]u8 = undefined;
    const ext = lowerExt(e.name, &buf);
    if (ext.len == 0) return .other;
    if (inSet(ext, &.{ "png", "jpg", "jpeg", "gif", "bmp", "webp", "svg", "ico", "tiff" })) return .image;
    if (inSet(ext, &.{ "mp4", "mkv", "webm", "avi", "mov", "flv", "wmv", "m4v" })) return .video;
    if (inSet(ext, &.{ "mp3", "flac", "ogg", "wav", "m4a", "opus", "aac" })) return .audio;
    if (inSet(ext, &.{ "txt", "md", "log", "csv", "ini", "conf", "json", "xml", "yaml", "yml", "toml" })) return .text;
    if (inSet(ext, &.{"pdf"})) return .pdf;
    if (inSet(ext, &.{ "zip", "tar", "gz", "xz", "bz2", "7z", "rar", "zst" })) return .archive;
    if (inSet(ext, &.{ "go", "zig", "c", "h", "cpp", "cc", "hpp", "rs", "py", "js", "ts", "sh", "lua", "java", "rb" })) return .source;
    if (inSet(ext, &.{ "so", "o", "a", "dll", "dylib" })) return .library;
    return .other;
}

/// typeName is the friendly label for the Type column.
pub fn typeName(e: Entry) []const u8 {
    return switch (category(e)) {
        .folder => "Folder",
        .link => "Link",
        .image => "Image",
        .video => "Video",
        .audio => "Audio",
        .text => "Text",
        .pdf => "PDF",
        .archive => "Archive",
        .source => "Source",
        .library => "Library",
        .other => "File",
    };
}

/// extLabel names a file of no known type by its extension, first letter upper-case
/// ("clip.funscript" → "Funscript"), into `out`; "" when it has none.
pub fn extLabel(name: []const u8, out: []u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return ""; // a dotfile, not an extension
    const e = name[dot + 1 ..];
    if (e.len == 0 or e.len > out.len) return "";
    @memcpy(out[0..e.len], e);
    out[0] = std.ascii.toUpper(out[0]);
    return out[0..e.len];
}

test "extLabel capitalises the extension" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Funscript", extLabel("DOOM 2025.05.15.funscript", &b));
    try std.testing.expectEqualStrings("", extLabel(".bashrc", &b));
    try std.testing.expectEqualStrings("", extLabel("Makefile", &b));
}

fn lowerExt(name: []const u8, buf: []u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return ""; // leading-dot dotfile → no extension
    const e = name[dot + 1 ..];
    if (e.len == 0 or e.len > buf.len) return "";
    for (e, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..e.len];
}

fn inSet(ext: []const u8, set: []const []const u8) bool {
    for (set) |s| {
        if (std.mem.eql(u8, ext, s)) return true;
    }
    return false;
}

/// formatDate renders an epoch-seconds mtime as "YYYY-MM-DD HH:MM" into `buf` (a
/// 20-byte buffer is enough) and returns the slice. Empty for a zero/negative
/// (unknown) time. UTC for now — local-time conversion is a later refinement,
/// matching the Go project's `formatDate` layout otherwise.
/// utc_offset gives the local UTC offset in seconds in effect at a Unix time
/// (daylight saving included). The core has no C library, so the UI installs one
/// (localtime_r) at startup; until then, and in tests, times read as UTC.
pub var utc_offset: ?*const fn (secs: i64) i64 = null;

/// localSecs shifts a Unix time by the local UTC offset at that moment, so day/hour
/// arithmetic on it reads as local time.
pub fn localSecs(secs: i64) i64 {
    const f = utc_offset orelse return secs;
    return secs + f(secs);
}

pub fn formatDate(buf: []u8, mtime_secs: i64) []const u8 {
    if (mtime_secs <= 0) return buf[0..0];
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(localSecs(mtime_secs), 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.mem.print(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        @as(u16, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
    }) catch buf[0..0];
}

/// formatDateFriendly is Finder's date: "Today at 13:09", "Yesterday at 17:26", else
/// "7 Jul 2026 at 23:11" — local time, judged against `now_secs` (also Unix seconds).
pub fn formatDateFriendly(buf: []u8, secs: i64, now_secs: i64) []const u8 {
    if (secs <= 0) return buf[0..0];
    const local = @max(localSecs(secs), 0);
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(local) };
    const ds = es.getDaySeconds();
    const day = @divFloor(local, std.time.s_per_day);
    const today = @divFloor(@max(localSecs(now_secs), 0), std.time.s_per_day);
    const hm = .{ ds.getHoursIntoDay(), ds.getMinutesIntoHour() };
    if (day == today) return std.mem.print(buf, "Today at {d:0>2}:{d:0>2}", hm) catch buf[0..0];
    if (day == today - 1) return std.mem.print(buf, "Yesterday at {d:0>2}:{d:0>2}", hm) catch buf[0..0];
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.mem.print(buf, "{d} {s} {d} at {d:0>2}:{d:0>2}", .{
        @as(u16, md.day_index) + 1, months[md.month.numeric() - 1], yd.year, hm[0], hm[1],
    }) catch buf[0..0];
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "readDir reports the free space of the folder's filesystem" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(root);
    const l = try readDir(testing.io, a, root);
    defer l.deinit(a);
    try testing.expect(l.total_bytes > 0); // a real filesystem backs the temp dir
    try testing.expect(l.free_bytes <= l.total_bytes);
}

test "formatMode renders permission strings" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("drwxr-xr-x", formatMode(&buf, 0o40755));
    try testing.expectEqualStrings("-rw-r--r--", formatMode(&buf, 0o100644));
    try testing.expectEqualStrings("lrwxrwxrwx", formatMode(&buf, 0o120777));
}

test "typeName classifies by kind and extension" {
    try testing.expectEqualStrings("Folder", typeName(.{ .name = @constCast("d"), .kind = .dir }));
    try testing.expectEqualStrings("Image", typeName(.{ .name = @constCast("a.PNG"), .kind = .file })); // case-insensitive
    try testing.expectEqualStrings("Source", typeName(.{ .name = @constCast("main.zig"), .kind = .file }));
    try testing.expectEqualStrings("Archive", typeName(.{ .name = @constCast("x.tar.gz"), .kind = .file }));
    try testing.expectEqualStrings("File", typeName(.{ .name = @constCast("README"), .kind = .file }));
    try testing.expectEqualStrings("Link", typeName(.{ .name = @constCast("l"), .kind = .symlink }));
}

test "formatDate renders UTC YYYY-MM-DD HH:MM" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("", formatDate(&buf, 0));
    try testing.expectEqualStrings("2000-01-01 00:00", formatDate(&buf, 946684800)); // 2000-01-01T00:00Z
    try testing.expectEqualStrings("2021-01-01 00:00", formatDate(&buf, 1609459200)); // 2021-01-01T00:00Z
}

test "humanizeSize matches the Go formatting" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0 B", humanizeSize(&buf, 0));
    try testing.expectEqualStrings("1023 B", humanizeSize(&buf, 1023));
    try testing.expectEqualStrings("1.0 KB", humanizeSize(&buf, 1024));
    try testing.expectEqualStrings("1.5 KB", humanizeSize(&buf, 1536));
    try testing.expectEqualStrings("1.0 MB", humanizeSize(&buf, 1024 * 1024));
    try testing.expectEqualStrings("1.0 GB", humanizeSize(&buf, 1024 * 1024 * 1024));
}

test "readDirFrom gives up when told to stop" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "x.txt", .data = "" });
    var stop = true;
    try testing.expectError(error.Canceled, readDirFrom(io, a, tmp.dir, &stop));
    stop = false;
    const listing = try readDirFrom(io, a, tmp.dir, &stop);
    defer listing.deinit(a);
    try testing.expectEqual(@as(usize, 1), listing.entries.len);
}

test "readDir lists children and sortByName puts dirs first" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "banana.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Apple.txt", .data = "" });
    try tmp.dir.createDirPath(io, "zeta");
    try tmp.dir.createDirPath(io, "Alpha");

    const listing = try readDirFrom(io, a, tmp.dir, null);
    defer listing.deinit(a);

    try testing.expectEqual(@as(usize, 4), listing.entries.len);
    sortByName(listing.entries);

    // Directories first (case-insensitive), then files (case-insensitive).
    try testing.expectEqualStrings("Alpha", listing.entries[0].name);
    try testing.expect(listing.entries[0].isDir());
    try testing.expectEqualStrings("zeta", listing.entries[1].name);
    try testing.expect(listing.entries[1].isDir());
    try testing.expectEqualStrings("Apple.txt", listing.entries[2].name);
    try testing.expect(!listing.entries[2].isDir());
    try testing.expectEqualStrings("banana.txt", listing.entries[3].name);
}

test "readDir errors on a missing directory" {
    const a = testing.allocator;
    try testing.expectError(error.FileNotFound, readDir(testing.io, a, "/no/such/dir/zfd-test"));
}

test "sortView orders by column/direction with dirs first" {
    // b(dir), a(dir), big.txt(file,300B,t=2), small.txt(file,100B,t=9)
    var entries = [_]Entry{
        .{ .name = @constCast("small.txt"), .kind = .file, .size = 100, .mtime_secs = 9 },
        .{ .name = @constCast("b"), .kind = .dir },
        .{ .name = @constCast("big.txt"), .kind = .file, .size = 300, .mtime_secs = 2 },
        .{ .name = @constCast("a"), .kind = .dir },
    };
    var view = [_]usize{ 0, 1, 2, 3 };

    // Name ascending: dirs first (a, b), then files by name (big, small).
    sortView(&view, &entries, .{ .column = .name, .ascending = true });
    try testing.expectEqualStrings("a", entries[view[0]].name);
    try testing.expectEqualStrings("b", entries[view[1]].name);
    try testing.expectEqualStrings("big.txt", entries[view[2]].name);
    try testing.expectEqualStrings("small.txt", entries[view[3]].name);

    // Size descending: dirs still first, then files largest-first (big, small).
    sortView(&view, &entries, .{ .column = .size, .ascending = false });
    try testing.expect(entries[view[0]].isDir() and entries[view[1]].isDir());
    try testing.expectEqualStrings("big.txt", entries[view[2]].name);
    try testing.expectEqualStrings("small.txt", entries[view[3]].name);

    // Date ascending among files: big (t=2) before small (t=9).
    sortView(&view, &entries, .{ .column = .date, .ascending = true });
    try testing.expectEqualStrings("big.txt", entries[view[2]].name);
    try testing.expectEqualStrings("small.txt", entries[view[3]].name);
}

test "formatDateFriendly says today and yesterday" {
    var buf: [40]u8 = undefined;
    const now: i64 = 1_792_059_360; // 2026-10-15 10:16 UTC (no offset hook in tests)
    try testing.expectEqualStrings("Today at 10:13", formatDateFriendly(&buf, now - 3 * 60, now));
    try testing.expectEqualStrings("Yesterday at 10:16", formatDateFriendly(&buf, now - std.time.s_per_day, now));
    try testing.expectEqualStrings("7 Jul 2026 at 23:11", formatDateFriendly(&buf, 1_783_465_860, now));
    try testing.expectEqualStrings("", formatDateFriendly(&buf, 0, now));
}
