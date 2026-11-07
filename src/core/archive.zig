//! Archive support: extract/compress via `bsdtar` (libarchive). We shell out rather
//! than link libarchive — same philosophy as the terminal/xdg-open features (an
//! optional CLI tool, feature hides when absent). bsdtar is one tool that reads zip,
//! 7z, tar.*, rar, cpio, iso, … and writes zip/7z/tar.* by inferring the format from
//! the output extension (`-a`). On Arch it's always present (libarchive is a pacman
//! dependency), but we still probe PATH so the menu can hide elsewhere.
//!
//! The pure helpers (isArchive/stripArchiveExt/fileStem) are unit-tested; the two
//! spawners run on the OpRunner worker thread (never the render thread).

const std = @import("std");

/// formats offered by the "Add to archive" submenu. `-a` makes bsdtar pick the format
/// + compression filter from the extension, so this table is just (ext, label) pairs.
pub const Format = struct { ext: []const u8, label: [:0]const u8 };
pub const formats = [_]Format{
    .{ .ext = ".zip", .label = "zip" }, // universal (Windows/macOS/Linux open it natively)
    .{ .ext = ".7z", .label = "7z" }, // best ratio; libarchive writes 7z
    .{ .ext = ".tar.gz", .label = "tar.gz" },
    .{ .ext = ".tar.xz", .label = "tar.xz" },
    .{ .ext = ".tar.zst", .label = "tar.zst" }, // fast, modern
};

// Extensions we treat as extractable archives (lowercased; matched case-insensitively).
// The compound tar.* forms are handled by stripArchiveExt, but the single suffixes here
// are what isArchive keys off — a bare ".gz"/".xz"/".zst" is a valid single-file stream
// bsdtar can unpack too.
const exts = [_][]const u8{
    ".zip",  ".7z",   ".rar", ".tar",  ".tgz", ".tbz", ".tbz2",
    ".txz",  ".tzst", ".gz",  ".bz2",  ".xz",  ".zst", ".lz",
    ".lzma", ".lz4",  ".lzo", ".cpio", ".iso", ".cab", ".ar",
    ".z",
};

/// endsWithCI reports whether `name` ends with `suffix`, ASCII case-insensitively.
fn endsWithCI(name: []const u8, suffix: []const u8) bool {
    if (suffix.len > name.len) return false;
    const tail = name[name.len - suffix.len ..];
    for (tail, suffix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

/// isArchive reports whether `name` looks like an archive bsdtar can extract, by
/// extension. Extension-based (not content-sniffing) on purpose: the menu decides
/// synchronously per frame, and a wrong guess only means bsdtar fails cleanly.
pub fn isArchive(name: []const u8) bool {
    for (exts) |e| {
        if (endsWithCI(name, e)) return true;
    }
    return false;
}

/// stripArchiveExt returns `name` with its archive extension removed — the natural
/// name for an "extract to <folder>". Handles the compound tar forms:
///   photos.tar.gz → photos,  data.tar → data,  book.zip → book,  notes.txt → notes.txt
pub fn stripArchiveExt(name: []const u8) []const u8 {
    var base = name;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    if (dot == 0) return base; // leading-dot dotfile, no extension
    for (exts) |e| {
        if (endsWithCI(base, e)) {
            base = base[0 .. base.len - e.len];
            break;
        }
    }
    if (endsWithCI(base, ".tar")) base = base[0 .. base.len - ".tar".len]; // .tar.gz etc.
    return base;
}

/// fileStem strips only the final extension — the name a new archive takes when you
/// "Add to archive" a single file (photo.png → photo). A directory keeps its full name
/// (handled by the caller), so this is file-only.
pub fn fileStem(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return if (dot == 0) name else name[0..dot];
}

/// getEnv borrows an environment variable via std.c.environ — neither std.posix.getenv
/// nor std.process.getEnvVarOwned exists in this std, but libc is linked (same approach
/// as fsops.getEnv).
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

/// findTool probes PATH for `bsdtar` and returns its absolute path (owned by the
/// caller), or null if it isn't installed — which hides the whole archive menu.
pub fn findTool(io: std.Io, alloc: std.mem.Allocator) ?[]u8 {
    const path = getEnv("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fs.path.join(alloc, &.{ dir, "bsdtar" }) catch continue;
        if (std.Io.Dir.cwd().statFile(io, full, .{})) |_| {
            return full;
        } else |_| {
            alloc.free(full);
        }
    }
    return null;
}

/// extractInto runs `bsdtar -x -f <archive> -C <dst_dir>`; dst_dir must already exist.
/// With `unsquashfs` as the tool it unpacks a squashfs image instead (an AppImage's,
/// past its program, or a snap). Returns error.ArchiveFailed on a non-zero exit
/// (bad/partial archive, no space, …).
pub fn extractInto(io: std.Io, tool: []const u8, archive_path: []const u8, dst_dir: []const u8) !void {
    if (std.mem.eql(u8, std.fs.path.basename(tool), "unsquashfs")) {
        var ob: [24]u8 = undefined;
        const off = std.mem.print(&ob, "{d}", .{try squashOffset(io, archive_path)}) catch return error.ArchiveFailed;
        const argv = [_][]const u8{ tool, "-f", "-no-xattrs", "-o", off, "-d", dst_dir, archive_path };
        return runTool(io, &argv, null);
    }
    const argv = [_][]const u8{ tool, "-x", "-f", archive_path, "-C", dst_dir };
    try runTool(io, &argv, null);
}

/// isPackage reports a file that's an archive inside but opens in its own app (a
/// document, an e-book, a software package): Show Contents browses it, a double-click
/// still opens it. bsdtar reads them all (zip, ar, rpm).
pub fn isPackage(name: []const u8) bool {
    const pkgs = [_][]const u8{
        ".epub", ".docx", ".xlsx", ".pptx", ".odt",  ".ods",  ".odp",  ".odg",
        ".jar",  ".war",  ".apk",  ".aab",  ".xpi",  ".whl",  ".nupkg", ".vsix",
        ".cbz",  ".deb",  ".rpm",  ".ipa",  ".kra",  ".ora",  ".3mf",
    };
    for (pkgs) |e| if (endsWithCI(name, e)) return true;
    return false;
}

/// isSquashImage reports an AppImage or a snap: a squashfs image (unsquashfs reads it).
pub fn isSquashImage(name: []const u8) bool {
    return endsWithCI(name, ".appimage") or endsWithCI(name, ".snap");
}

/// squashOffset is where the squashfs image starts in `path`: 0 for a snap, and for
/// an AppImage the end of its ELF program, worked out from the ELF header (the
/// section headers come last), so the AppImage itself is never run.
pub fn squashOffset(io: std.Io, path: []const u8) !u64 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.ArchiveFailed;
    defer f.close(io);
    var hdr: [64]u8 = undefined;
    var r = f.reader(io, &.{});
    const n = r.interface.readSliceShort(&hdr) catch return error.ArchiveFailed;
    return elfEnd(hdr[0..n]) orelse 0;
}

/// elfEnd is the end of an ELF file from its header (null if it isn't ELF).
fn elfEnd(h: []const u8) ?u64 {
    if (h.len < 52 or !std.mem.eql(u8, h[0..4], "\x7fELF")) return null;
    const le = h[5] == 1;
    const e: std.builtin.Endian = if (le) .little else .big;
    if (h[4] == 2) { // 64-bit
        if (h.len < 64) return null;
        const shoff = std.mem.readInt(u64, h[0x28..0x30], e);
        const shentsize = std.mem.readInt(u16, h[0x3A..0x3C], e);
        const shnum = std.mem.readInt(u16, h[0x3C..0x3E], e);
        return shoff + @as(u64, shentsize) * shnum;
    }
    const shoff = std.mem.readInt(u32, h[0x20..0x24], e);
    const shentsize = std.mem.readInt(u16, h[0x2E..0x30], e);
    const shnum = std.mem.readInt(u16, h[0x30..0x32], e);
    return @as(u64, shoff) + @as(u64, shentsize) * shnum;
}

test "elfEnd finds where an AppImage's image starts" {
    var h: [64]u8 = @splat(0);
    @memcpy(h[0..4], "\x7fELF");
    h[4] = 2; // 64-bit
    h[5] = 1; // little-endian
    std.mem.writeInt(u64, h[0x28..0x30], 1000, .little);
    std.mem.writeInt(u16, h[0x3A..0x3C], 64, .little);
    std.mem.writeInt(u16, h[0x3C..0x3E], 3, .little);
    try std.testing.expectEqual(@as(?u64, 1192), elfEnd(&h));
    try std.testing.expectEqual(@as(?u64, null), elfEnd("hsqs and the rest of a snap ......................................"));
    try std.testing.expect(isPackage("Book.EPUB") and isPackage("x.deb") and !isPackage("x.zip"));
    try std.testing.expect(isSquashImage("Krita-5.AppImage") and isSquashImage("core.snap"));
}

/// compressInto runs `bsdtar -a -c -f <archive_path> <srcs...>` with cwd=src_dir, so the
/// archive stores clean relative names (not absolute paths). `-a` picks format +
/// compression from archive_path's extension.
pub fn compressInto(
    io: std.Io,
    alloc: std.mem.Allocator,
    tool: []const u8,
    archive_path: []const u8,
    src_dir: []const u8,
    srcs: []const []const u8,
) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, tool);
    try argv.append(alloc, "-a");
    try argv.append(alloc, "-c");
    try argv.append(alloc, "-f");
    try argv.append(alloc, archive_path);
    for (srcs) |s| try argv.append(alloc, s);
    try runTool(io, argv.items, src_dir);
}

/// runTool spawns argv (optionally in cwd), waits, and maps a non-zero/abnormal exit to
/// error.ArchiveFailed. Inherits stdio — bsdtar's diagnostics go to the parent's stderr.
fn runTool(io: std.Io, argv: []const []const u8, cwd: ?[]const u8) !void {
    const cwd_opt: std.process.Child.Cwd = if (cwd) |d| .{ .path = d } else .inherit;
    var child = std.process.spawn(io, .{ .argv = argv, .cwd = cwd_opt }) catch return error.ArchiveFailed;
    const term = child.wait(io) catch return error.ArchiveFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.ArchiveFailed,
        else => return error.ArchiveFailed,
    }
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "isArchive by extension, case-insensitive" {
    try testing.expect(isArchive("foo.zip"));
    try testing.expect(isArchive("foo.tar.gz"));
    try testing.expect(isArchive("FOO.ZIP"));
    try testing.expect(isArchive("a.7z"));
    try testing.expect(isArchive("linux.tar.zst"));
    try testing.expect(!isArchive("notes.txt"));
    try testing.expect(!isArchive("archive")); // no extension
    try testing.expect(!isArchive("image.png"));
}

test "stripArchiveExt handles compound and simple extensions" {
    try testing.expectEqualStrings("photos", stripArchiveExt("photos.tar.gz"));
    try testing.expectEqualStrings("data", stripArchiveExt("data.tar"));
    try testing.expectEqualStrings("book", stripArchiveExt("book.zip"));
    try testing.expectEqualStrings("linux", stripArchiveExt("linux.tar.zst"));
    try testing.expectEqualStrings("notes.txt", stripArchiveExt("notes.txt")); // untouched
    try testing.expectEqualStrings(".bashrc", stripArchiveExt(".bashrc")); // dotfile untouched
}

test "fileStem strips only the last extension" {
    try testing.expectEqualStrings("photo", fileStem("photo.png"));
    try testing.expectEqualStrings("archive.tar", fileStem("archive.tar.gz"));
    try testing.expectEqualStrings("README", fileStem("README"));
    try testing.expectEqualStrings(".bashrc", fileStem(".bashrc"));
}
