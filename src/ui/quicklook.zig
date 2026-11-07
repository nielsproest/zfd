//! Previews of the item under the cursor, for Quick Look (Space: a window of its
//! own), the Preview pane right of the files, and the gallery view. Images decode
//! with stb_image (preview_img.c); a PDF's first page comes from pdftoppm and a
//! video's frame from ffmpeg when those are installed; text shows its beginning; a
//! folder shows its item count. It follows the cursor, so the arrow keys step
//! through files while it's open.
//!
//! Loading happens on one worker thread (a newer request supersedes an older one,
//! like the Scanner); the render thread only uploads the decoded pixels to a texture.

const std = @import("std");
const cimgui = @import("cimgui.zig");
const c = cimgui.c;
const core = @import("core");
const icons = @import("views/icons.zig");
const theme = @import("theme.zig");

extern fn zfd_image_load_mem(buf: [*]const u8, len: c_int, max_dim: c_int, w: *c_int, h: *c_int) ?[*]u8;
extern fn zfd_image_free(px: [*]u8) void;
extern fn zfd_texture_upload(px: [*]const u8, w: c_int, h: c_int) c_uint;
extern fn zfd_texture_free(tex: c_uint) void;

const max_dim = 2048; // longest side of a decoded preview

/// temp_files is where an entry of an archive that an outside tool must read (a PDF,
/// a video) is taken out to (set by the shell; null: no such previews).
pub var temp_files: ?*core.archives.TempFiles = null;
/// ffprobe is FFmpeg's, for a picture's, video's or recording's details (More Info;
/// set by the shell; null: not installed, the header's dimensions only).
pub var ffprobe: ?[]const u8 = null;
const image_max = 256 << 20; // biggest picture inside an archive read for a preview
const text_limit = 64 * 1024; // bytes of a text file shown

const Content = union(enum) {
    // w, h: as decoded (shrunk to max_dim); full_w, full_h: the picture's own size,
    // upright (0: unknown, e.g. a frame of a video).
    image: struct { px: [*]u8, w: c_int, h: c_int, full_w: c_int = 0, full_h: c_int = 0 },
    text: []u8,
    message: []u8,
    folder: []u8, // "N items" then the first names, one per line

    fn deinit(self: Content, alloc: std.mem.Allocator) void {
        switch (self) {
            .image => |im| zfd_image_free(im.px),
            .text, .message, .folder => |t| alloc.free(t),
        }
    }
};

/// Loader is the worker side: request(path) → poll() returns the content for the
/// newest request. Heap-pinned; create/destroy.
pub const Loader = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    req: ?[]u8 = null, // guarded: pending path (owned)
    req_gen: u64 = 0,
    ready: ?Content = null,
    ready_info: ?[]u8 = null, // its More Info ("Label\tValue" lines; owned)
    ready_listing: ?core.scan.Listing = null, // a folder's items, for the folder view (owned)
    ready_gen: u64 = 0,
    shutdown: bool = false,
    thread: ?std.Thread = null,

    pub fn create(io: std.Io, alloc: std.mem.Allocator) !*Loader {
        const self = try alloc.create(Loader);
        self.* = .{ .io = io, .alloc = alloc };
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |e| {
            alloc.destroy(self);
            return e;
        };
        return self;
    }

    pub fn destroy(self: *Loader) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);
        if (self.thread) |t| t.join();
        if (self.req) |r| self.alloc.free(r);
        if (self.ready) |r| r.deinit(self.alloc);
        if (self.ready_info) |t| self.alloc.free(t);
        if (self.ready_listing) |l| l.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// request asks for a preview of `path`, superseding any earlier request.
    pub fn request(self: *Loader, path: []const u8) u64 {
        const dup = self.alloc.dupe(u8, path) catch return 0;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.req) |old| self.alloc.free(old);
        self.req = dup;
        self.req_gen += 1;
        self.cond.signal(self.io);
        return self.req_gen;
    }

    /// poll hands over the finished content for request `gen`, if it's ready.
    /// poll hands over the finished content for request `gen`, if it's ready, and its
    /// More Info into `info` (owned; null if none).
    fn poll(self: *Loader, gen: u64, info: *?[]u8, listing: *?core.scan.Listing) ?Content {
        if (!self.mutex.tryLock()) return null;
        defer self.mutex.unlock(self.io);
        const r = self.ready orelse return null;
        if (self.ready_gen != gen) return null;
        self.ready = null;
        info.* = self.ready_info;
        self.ready_info = null;
        listing.* = self.ready_listing;
        self.ready_listing = null;
        return r;
    }

    fn run(self: *Loader) void {
        self.mutex.lockUncancelable(self.io);
        while (true) {
            while (self.req == null and !self.shutdown) self.cond.waitUncancelable(self.io, &self.mutex);
            if (self.shutdown) break;
            const path = self.req.?;
            self.req = null;
            const gen = self.req_gen;
            self.mutex.unlock(self.io);

            const content = load(self.io, self.alloc, path);
            // Its details (a file ffprobe reads, so not one inside an archive).
            const info: ?[]u8 = if (ffprobe) |fp| (if (core.mediainfo.isMedia(std.fs.path.basename(path)) and !core.arcfs.isArchived(path)) core.mediainfo.probe(self.io, self.alloc, fp, path) else null) else null;
            // A folder's items with their details, for Quick Look's folder view (a
            // folder inside an archive too).
            const listing: ?core.scan.Listing = if (content == .folder) (core.arcfs.readAny(self.io, self.alloc, path, null, true) catch null) else null;
            self.alloc.free(path);

            self.mutex.lockUncancelable(self.io);
            if (self.ready) |old| old.deinit(self.alloc);
            if (self.ready_info) |old| self.alloc.free(old);
            if (self.ready_listing) |old| old.deinit(self.alloc);
            self.ready = content;
            self.ready_info = info;
            self.ready_listing = listing;
            self.ready_gen = gen;
            c.glfwPostEmptyEvent(); // wake an idle UI loop
        }
        self.mutex.unlock(self.io);
    }
};

/// load builds the preview for `path` (worker thread).
fn load(io: std.Io, alloc: std.mem.Allocator, path: []const u8) Content {
    if (core.arcfs.isArchived(path)) return loadArchived(io, alloc, path);
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return message(alloc, "Can't read this item", .{});
    if (st.kind == .directory) return folderSummary(io, alloc, path);

    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const pz = std.mem.printSentinel(&zbuf, "{s}", .{path}, 0) catch return message(alloc, "Path too long", .{});
    const ext = extLower(path);

    if (isAny(ext, &.{ "png", "jpg", "jpeg", "gif", "bmp", "tga", "psd", "pnm", "ppm", "pgm", "pic" })) {
        var w: c_int = 0;
        var h: c_int = 0;
        const image = @import("image.zig");
        if (image.load(io, pz.ptr, max_dim, &w, &h)) |px| {
            var fw: c_int = 0;
            var fh: c_int = 0;
            _ = image.zfd_image_size(pz.ptr, &fw, &fh);
            if (core.exif.turned(image.orientationOf(io, path))) std.mem.swap(c_int, &fw, &fh);
            return .{ .image = .{ .px = px, .w = w, .h = h, .full_w = fw, .full_h = fh } };
        }
    }
    if (std.mem.eql(u8, ext, "pdf")) {
        if (renderVia(io, alloc, &.{ "pdftoppm", "-png", "-f", "1", "-l", "1", "-singlefile", "-scale-to", "1600", path })) |im| return im;
    }
    if (isAny(ext, &.{ "mp4", "mkv", "webm", "avi", "mov", "m4v", "wmv", "flv", "webp", "tiff", "tif", "heic", "avif" })) {
        // A frame a few seconds in (past black intros); still images decode as-is.
        const video = !isAny(ext, &.{ "webp", "tiff", "tif", "heic", "avif" });
        const seek: []const u8 = if (video) "3" else "0";
        if (renderVia(io, alloc, &.{ "ffmpeg", "-v", "error", "-ss", seek, "-i", path, "-frames:v", "1", "-vf", "scale='min(1600,iw)':-2", "-f", "image2pipe", "-vcodec", "png", "-" })) |im| return im;
        if (video) {
            if (renderVia(io, alloc, &.{ "ffmpeg", "-v", "error", "-i", path, "-frames:v", "1", "-vf", "scale='min(1600,iw)':-2", "-f", "image2pipe", "-vcodec", "png", "-" })) |im| return im;
        }
    }
    if (core.arcfs.opensAsFolder(std.fs.path.basename(path))) {
        if (archivedFolder(io, alloc, path)) |f| return f; // (its contents, read in place)
    }
    if (textPreview(io, alloc, path)) |t| return .{ .text = t };

    var sb: [24]u8 = undefined;
    return message(alloc, "No preview available\n\n{s}", .{core.scan.humanizeSize(&sb, st.size)});
}

/// loadArchived previews an entry inside an archive, read in place: a folder lists
/// its contents, a picture or text comes straight from the archive into memory, and
/// a PDF or video (which only an outside tool reads) is taken out first, alone.
fn loadArchived(io: std.Io, alloc: std.mem.Allocator, path: []const u8) Content {
    const inf = core.arcfs.info(io, path) catch return message(alloc, "Can't read this item", .{});
    if (inf.kind == .dir) return archivedFolder(io, alloc, path) orelse message(alloc, "Folder", .{});
    const ext = extLower(path);
    if (isAny(ext, &.{ "png", "jpg", "jpeg", "gif", "bmp", "tga", "psd", "pnm", "ppm", "pgm", "pic" })) {
        if (core.arcfs.read(alloc, path, image_max)) |data| {
            defer alloc.free(data);
            var w: c_int = 0;
            var h: c_int = 0;
            if (zfd_image_load_mem(data.ptr, @intCast(data.len), max_dim, &w, &h)) |px| {
                var fw: c_int = 0;
                var fh: c_int = 0;
                _ = @import("image.zig").zfd_image_size_mem(data.ptr, @intCast(data.len), &fw, &fh);
                return .{ .image = .{ .px = px, .w = w, .h = h, .full_w = fw, .full_h = fh } };
            }
        } else |_| {}
    }
    const outside = std.mem.eql(u8, ext, "pdf") or
        isAny(ext, &.{ "mp4", "mkv", "webm", "avi", "mov", "m4v", "wmv", "flv", "webp", "tiff", "tif", "heic", "avif" });
    if (outside) if (temp_files) |tf| {
        if (tf.takeOut(alloc, path, null)) |out| {
            defer alloc.free(out);
            return load(io, alloc, out);
        } else |_| {}
    };
    if (core.arcfs.readStart(alloc, path, text_limit)) |t| {
        if (t.len > 0 and std.mem.indexOfScalar(u8, t, 0) == null) return .{ .text = t };
        alloc.free(t);
    } else |_| {}
    var sb: [24]u8 = undefined;
    return message(alloc, "No preview available\n\n{s}", .{core.scan.humanizeSize(&sb, inf.size)});
}

/// archivedFolder previews a folder inside an archive (or an archive's top level):
/// how many items, and the first names, folders first. Null if it can't be read.
fn archivedFolder(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?Content {
    const got = core.arcfs.names(io, alloc, path, 400) catch return null;
    defer {
        for (got.list) |n| alloc.free(n);
        alloc.free(got.list);
    }
    return summary(alloc, got.list, got.total, false);
}

fn message(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Content {
    return .{ .message = alloc.print(fmt, args) catch &.{} };
}

/// folderSummary previews a folder: how many items it holds, and the first names
/// (folders first, then A–Z; hidden ones left out), like an archive's listing.
fn folderSummary(io: std.Io, alloc: std.mem.Allocator, path: []const u8) Content {
    var d = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return message(alloc, "Folder\n\nCan't open it", .{});
    defer d.close(io);
    const limit = 100_000;
    const keep = 400; // names gathered to sort; the first `shown` are listed
    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var n: usize = 0;
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        n += 1;
        if (n >= limit) break;
        if (names.items.len >= keep or (e.name.len > 0 and e.name[0] == '.')) continue;
        const nm = alloc.print("{s}{s}", .{ e.name, if (e.kind == .directory) "/" else "" }) catch continue;
        names.append(alloc, nm) catch alloc.free(nm);
    }
    return summary(alloc, names.items, n, n >= limit);
}

/// summary is a folder's preview text: how many items (`more`: at least that
/// many), then the first names, folders (named with a '/') first, then A-Z.
fn summary(alloc: std.mem.Allocator, names: [][]u8, n: usize, more: bool) Content {
    const shown = 40;
    const Ctx = struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            const ad = std.mem.endsWith(u8, a, "/");
            const bd = std.mem.endsWith(u8, b, "/");
            if (ad != bd) return ad;
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    };
    std.mem.sort([]u8, names, {}, Ctx.less);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    out.print(alloc, "{d}{s} item{s}", .{ n, if (more) "+" else "", if (n == 1) "" else "s" }) catch {};
    for (names[0..@min(shown, names.len)]) |nm| {
        out.append(alloc, '\n') catch break;
        out.appendSlice(alloc, nm) catch break;
    }
    if (n > shown and names.len > 0) out.appendSlice(alloc, "\n\u{2026}") catch {};
    return .{ .folder = out.toOwnedSlice(alloc) catch return message(alloc, "Folder", .{}) };
}

/// textPreview returns the beginning of `path` if it looks like text (no NUL bytes
/// in what was read), else null.
fn textPreview(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const buf = alloc.alloc(u8, text_limit) catch return null;
    var n: usize = 0;
    while (n < buf.len) {
        const rc = std.os.linux.read(f.handle, buf.ptr + n, buf.len - n);
        if (std.os.linux.errno(rc) != .SUCCESS or rc == 0) break;
        n += rc;
    }
    if (n == 0 or std.mem.indexOfScalar(u8, buf[0..n], 0) != null) {
        alloc.free(buf);
        return null;
    }
    return alloc.realloc(buf, n) catch buf[0..n];
}

/// runCapture runs argv and returns its stdout (up to `max` bytes; owned), or null
/// when it can't run or fails.
fn runCapture(io: std.Io, alloc: std.mem.Allocator, argv: []const []const u8, max: usize) ?[]u8 {
    const linux = std.os.linux;
    const mfd = linux.memfd_create("zfd-ql", linux.MFD.CLOEXEC);
    if (mfd > std.math.maxInt(i32)) return null;
    const fd: i32 = @intCast(mfd);
    defer _ = linux.close(fd);
    const out: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .{ .file = out }, .stderr = .ignore }) catch return null;
    const term = child.wait(io) catch return null;
    switch (term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    var data = std.ArrayList(u8).empty;
    errdefer data.deinit(alloc);
    var buf: [64 * 1024]u8 = undefined;
    var off: i64 = 0;
    while (data.items.len < max) {
        const rc = linux.pread(fd, &buf, @min(buf.len, max - data.items.len), off);
        if (rc == 0 or rc > buf.len) break;
        data.appendSlice(alloc, buf[0..rc]) catch return null;
        off += @intCast(rc);
    }
    return data.toOwnedSlice(alloc) catch null;
}

/// renderVia runs a converter that writes a PNG to stdout and decodes it; null when
/// the tool is missing or fails.
fn renderVia(io: std.Io, alloc: std.mem.Allocator, argv: []const []const u8) ?Content {
    const data = runCapture(io, alloc, argv, 64 << 20) orelse return null;
    defer alloc.free(data);
    if (data.len == 0) return null;
    var w: c_int = 0;
    var h: c_int = 0;
    const px = zfd_image_load_mem(data.ptr, @intCast(data.len), max_dim, &w, &h) orelse return null;
    return .{ .image = .{ .px = px, .w = w, .h = h } };
}

fn extLower(path: []const u8) []const u8 {
    const S = struct {
        threadlocal var buf: [16]u8 = undefined;
    };
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    if (dot == 0) return "";
    const e = base[dot + 1 ..];
    if (e.len == 0 or e.len > S.buf.len) return "";
    for (e, 0..) |ch, i| S.buf[i] = std.ascii.toLower(ch);
    return S.buf[0..e.len];
}

fn isAny(ext: []const u8, set: []const []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, ext, s)) return true;
    return false;
}

/// View is the render-thread side: the open flag, what's shown, and the texture.
/// Zoom is a picture's zoom in one place that shows it (Quick Look's window has
/// its own; the Preview pane and the gallery show it fitted): how far past fitting
/// it (1 = fitted; scrolling over it), and how far it's dragged off centre. Back to
/// fitted for each new picture. It used to live in the View, which the Preview pane
/// draws too: drawn twice a frame, the pane's much tighter limit pulled a picture
/// dragged in Quick Look back toward the middle.
pub const Zoom = struct {
    zoom: f32 = 1,
    pan: [2]f32 = .{ 0, 0 },
    tex: c_uint = 0, // the picture this is for
};

/// PeekFilter is which of a folder's items Quick Look's folder view lists.
pub const PeekFilter = enum { all, folders, images, docs, media, other };

fn extIs(name: []const u8, set: []const []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const e = name[dot + 1 ..];
    if (e.len == 0 or e.len > 8) return false;
    var lb: [8]u8 = undefined;
    const low = std.ascii.lowerString(&lb, e);
    for (set) |x| if (std.mem.eql(u8, low, x)) return true;
    return false;
}

/// categoryOf is the folder view's kind for an item (by extension).
fn categoryOf(e: core.scan.Entry) PeekFilter {
    if (e.isDir()) return .folders;
    if (extIs(e.name, &.{ "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "heif", "avif", "tif", "tiff", "svg", "ico", "psd", "jxl", "raw", "cr2", "nef", "dng", "arw", "tga", "exr" })) return .images;
    if (extIs(e.name, &.{ "mp4", "mkv", "webm", "avi", "mov", "m4v", "wmv", "flv", "mpg", "mpeg", "mp3", "flac", "ogg", "opus", "m4a", "aac", "wav", "wma", "aiff" })) return .media;
    if (extIs(e.name, &.{ "pdf", "txt", "md", "doc", "docx", "odt", "rtf", "xls", "xlsx", "ods", "ppt", "pptx", "odp", "epub", "csv", "tex", "pages", "numbers", "key" })) return .docs;
    return .other; // (archives, programs, anything else)
}

/// stampOf is what update watches an entry by: its modification time and size.
pub fn stampOf(e: core.scan.Entry) u64 {
    return @as(u64, @bitCast(e.mtime_secs)) *% 1_000_003 +% e.size;
}

pub const View = struct {
    loader: ?*Loader = null,
    path: std.ArrayList(u8) = .empty, // what the window shows (or is loading)
    gen: u64 = 0,
    loading: bool = false,
    tex: c_uint = 0,
    tex_w: f32 = 0,
    tex_h: f32 = 0,
    // The picture's own size (not the shrunk texture's), for Dimensions (0: unknown).
    img_w: c_int = 0,
    img_h: c_int = 0,
    info: ?[]u8 = null, // More Info, "Label\tValue" lines (owned)
    stamp: u64 = 0, // the shown item's modification time and size: a change reloads it
    open_request: bool = false, // a double-click on a fitted picture: show it in Quick Look
    // A folder's items, for Quick Look's folder view (owned), and that view's state:
    // which kinds it shows, its order (dirs first, A-Z) and the item picked, whose
    // own preview (a View of its own) is shown beside the list.
    listing: ?core.scan.Listing = null,
    peek_filter: PeekFilter = .all,
    peek_order: std.ArrayList(usize) = .empty,
    peek_sel: usize = 0, // into peek_order
    peek_inner: ?*View = null,
    peek_enter: [std.fs.max_path_bytes]u8 = undefined, // a subfolder to go into (Enter.path)
    peek_want: [256]u8 = undefined, // the item to pick once the folder's in (back from it)
    peek_want_len: usize = 0,
    dims_buf: [64]u8 = undefined, // More Info when there's only the header's size
    text: ?[]u8 = null, // text or message being shown (owned)
    is_message: bool = false,
    is_folder: bool = false, // text is a folderSummary: drawn with a folder icon

    pub fn deinit(self: *View, alloc: std.mem.Allocator) void {
        self.clear(alloc);
        self.peek_order.deinit(alloc);
        if (self.peek_inner) |v| {
            v.deinit(alloc);
            alloc.destroy(v);
        }
        self.path.deinit(alloc);
        if (self.loader) |l| l.destroy();
    }

    fn clear(self: *View, alloc: std.mem.Allocator) void {
        if (self.tex != 0) zfd_texture_free(self.tex);
        self.tex = 0;
        self.img_w = 0;
        self.img_h = 0;
        if (self.info) |t| alloc.free(t);
        self.info = null;
        if (self.listing) |l| l.deinit(alloc);
        self.listing = null;
        self.peek_order.clearRetainingCapacity();
        self.peek_sel = 0;
        if (self.text) |t| alloc.free(t);
        self.text = null;
    }

    /// pickWhenIn has the folder view pick item `name` once the folder it's about to
    /// show is in (coming back out of that item).
    pub fn pickWhenIn(self: *View, name: []const u8) void {
        if (name.len > self.peek_want.len) return;
        @memcpy(self.peek_want[0..name.len], name);
        self.peek_want_len = name.len;
    }

    /// isFolderView reports whether a folder's items are in, for Quick Look's folder
    /// view (drawFolderView) instead of the summary.
    pub fn isFolderView(self: *const View) bool {
        return !self.loading and self.is_folder and self.listing != null;
    }

    /// sortPeek lists the folder's items the view shows: those of its filter,
    /// folders first, then by name (hidden ones left out), keeping the pick on the
    /// same item when it's still there.
    fn sortPeek(self: *View, alloc: std.mem.Allocator) void {
        const l = self.listing orelse return;
        const was: ?[]const u8 = if (self.peek_sel < self.peek_order.items.len and self.peek_order.items[self.peek_sel] < l.entries.len) l.entries[self.peek_order.items[self.peek_sel]].name else null;
        self.peek_order.clearRetainingCapacity();
        for (l.entries, 0..) |e, i| {
            if (e.name.len > 0 and e.name[0] == '.') continue;
            if (self.peek_filter != .all and categoryOf(e) != self.peek_filter) continue;
            self.peek_order.append(alloc, i) catch break;
        }
        const Ctx = struct {
            es: []core.scan.Entry,
            fn less(cx: @This(), a: usize, b: usize) bool {
                const ea = cx.es[a];
                const eb = cx.es[b];
                if (ea.isDir() != eb.isDir()) return ea.isDir();
                return std.ascii.lessThanIgnoreCase(ea.name, eb.name);
            }
        };
        std.mem.sort(usize, self.peek_order.items, Ctx{ .es = l.entries }, Ctx.less);
        self.peek_sel = 0;
        if (self.peek_want_len > 0) {
            const want = self.peek_want[0..self.peek_want_len];
            self.peek_want_len = 0;
            for (self.peek_order.items, 0..) |ix, k| if (std.mem.eql(u8, l.entries[ix].name, want)) {
                self.peek_sel = k;
                return;
            };
        }
        if (was) |w| for (self.peek_order.items, 0..) |ix, k| if (std.mem.eql(u8, l.entries[ix].name, w)) {
            self.peek_sel = k;
            break;
        };
    }

    /// drawFolderView is Quick Look's view of a folder: its name, size and counts on
    /// top; tabs that pick which kinds it lists (all, folders, pictures, documents,
    /// media, other); the list on the left, Name and Date Modified; and the item picked in
    /// it previewed on the right, its name and size, kind and date under it. A
    /// double-click on an item goes there (returned for the caller to navigate).
    pub fn drawFolderView(self: *View, io: std.Io, alloc: std.mem.Allocator, size: c.ImVec2_c, b: *core.browser.Browser) ?Enter {
        const l = self.listing orelse return null;
        var enter: ?Enter = null;
        const fs = c.igGetFontSize();
        const pal = theme.p();
        const dl = c.igGetWindowDrawList();
        const p0 = c.igGetCursorScreenPos();
        const now = std.Io.Clock.real.now(io).toSeconds();

        // The header: the folder's icon, its name, its size and what it holds.
        const icon = @round(fs * 3);
        icons.draw(dl, .{ .name = @constCast("folder"), .kind = .dir }, p0.x, p0.y, icon, false);
        var files: usize = 0;
        var dirs: usize = 0;
        var bytes: u64 = 0;
        for (l.entries) |e| {
            if (e.name.len > 0 and e.name[0] == '.') continue;
            if (e.isDir()) dirs += 1 else {
                files += 1;
                bytes += e.size;
            }
        }
        c.igSetCursorScreenPos(cimgui.vec2(p0.x + icon + fs * 0.7, p0.y + fs * 0.15));
        cimgui.pushFontTimes(1.45);
        cimgui.textUnformatted(std.fs.path.basename(self.path.items));
        c.igPopFont();
        c.igSetCursorScreenPos(cimgui.vec2(p0.x + icon + fs * 0.7, c.igGetCursorScreenPos().y));
        var sb: [32]u8 = undefined;
        var hb: [128]u8 = undefined;
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
        cimgui.textUnformatted(std.mem.print(&hb, "{s} \u{00B7} {d} folder{s}, {d} file{s}", .{
            core.scan.humanizeSize(&sb, bytes), dirs, if (dirs == 1) "" else "s", files, if (files == 1) "" else "s",
        }) catch "");
        c.igPopStyleColor(1);

        // The tabs: one rounded strip, the picked one filled in the accent colour.
        const tabs_y = p0.y + icon + fs * 0.8;
        const tab_h = @round(fs * 1.7);
        const names = [_][]const u8{ "All", "Folders", "Images", "Docs", "Media", "Other" };
        var tw: f32 = 0;
        for (names) |n| tw += c.igCalcTextSize(n.ptr, n.ptr + n.len, false, -1).x + fs * 1.6;
        c.ImDrawList_AddRectFilled(dl, cimgui.vec2(p0.x, tabs_y), cimgui.vec2(p0.x + tw, tabs_y + tab_h), c.igGetColorU32_Vec4(pal.row_alt), @round(tab_h * 0.3), 0);
        var tx = p0.x;
        for (names, 0..) |n, i| {
            const w = c.igCalcTextSize(n.ptr, n.ptr + n.len, false, -1).x + fs * 1.6;
            c.igSetCursorScreenPos(cimgui.vec2(tx, tabs_y));
            c.igPushID_Int(@intCast(i));
            if (c.igInvisibleButton("##peektab", cimgui.vec2(w, tab_h), 0)) {
                self.peek_filter = @enumFromInt(i);
                self.sortPeek(alloc);
            }
            const on = @intFromEnum(self.peek_filter) == i;
            const hov = c.igIsItemHovered(0);
            c.igPopID();
            if (on) c.ImDrawList_AddRectFilled(dl, cimgui.vec2(tx + 2, tabs_y + 2), cimgui.vec2(tx + w - 2, tabs_y + tab_h - 2), c.igGetColorU32_Vec4(pal.accent), @round(tab_h * 0.25), 0) else if (hov) c.ImDrawList_AddRectFilled(dl, cimgui.vec2(tx + 2, tabs_y + 2), cimgui.vec2(tx + w - 2, tabs_y + tab_h - 2), c.igGetColorU32_Col(c.ImGuiCol_ButtonHovered, 1), @round(tab_h * 0.25), 0);
            const col = if (on) c.igGetColorU32_Vec4(cimgui.vec4(1, 1, 1, 1)) else c.igGetColorU32_Col(c.ImGuiCol_Text, 1);
            c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(tx + fs * 0.8, tabs_y + (tab_h - c.igGetTextLineHeight()) * 0.5), col, n.ptr, n.ptr + n.len);
            tx += w;
        }

        // The list (left) and the picked item (right).
        const body_y = tabs_y + tab_h + fs * 0.8;
        const body_h = @max(p0.y + size.y - body_y, fs * 4);
        const list_w = @round(size.x * 0.55);
        const gap = fs * 0.8;
        c.igSetCursorScreenPos(cimgui.vec2(p0.x, body_y));
        const tflags = c.ImGuiTableFlags_RowBg | c.ImGuiTableFlags_ScrollY | c.ImGuiTableFlags_BordersInnerV;
        if (c.igBeginTable("##peeklist", 2, tflags, cimgui.vec2(list_w, body_h), 0)) {
            c.igTableSetupScrollFreeze(0, 1);
            c.igTableSetupColumn("Name", c.ImGuiTableColumnFlags_WidthStretch, 0.62, 0);
            c.igTableSetupColumn("Date Modified", c.ImGuiTableColumnFlags_WidthStretch, 0.38, 0);
            c.igTableHeadersRow();
            const line = c.igGetTextLineHeight();
            for (self.peek_order.items, 0..) |ix, k| {
                const e = l.entries[ix];
                c.igTableNextRow(0, 0);
                _ = c.igTableSetColumnIndex(0);
                c.igPushID_Int(@intCast(k));
                const picked = k == self.peek_sel;
                if (c.igSelectable_Bool("##peekrow", picked, c.ImGuiSelectableFlags_SpanAllColumns | c.ImGuiSelectableFlags_AllowDoubleClick, cimgui.vec2(0, 0))) {
                    self.peek_sel = k;
                    // A double-click goes there in the main window: into a folder;
                    // a file, shown picked in this one.
                    if (c.igIsMouseDoubleClicked_Nil(0)) {
                        if (e.isDir()) {
                            if (std.fmt.bufPrint(&self.peek_enter, "{s}/{s}", .{ if (std.mem.eql(u8, self.path.items, "/")) "" else self.path.items, e.name })) |sub|
                                enter = .{ .path = sub }
                            else |_| {}
                        } else enter = .{ .path = self.path.items, .select = e.name };
                    }
                }
                c.igPopID();
                c.igSameLine(0, 0);
                const ip = c.igGetCursorScreenPos();
                icons.draw(c.igGetWindowDrawList(), e, ip.x, ip.y, line, false);
                c.igSetCursorScreenPos(cimgui.vec2(ip.x + line + fs * 0.4, ip.y));
                cimgui.textUnformatted(e.name);
                _ = c.igTableSetColumnIndex(1);
                var db: [32]u8 = undefined;
                c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
                cimgui.textUnformatted(if (e.mtime_secs > 0) core.scan.formatDateFriendly(&db, e.mtime_secs, now) else "");
                c.igPopStyleColor(1);
            }
            c.igEndTable();
        }
        if (self.peek_order.items.len == 0) {
            const t = "Nothing here";
            const t_w = c.igCalcTextSize(t, null, false, -1).x;
            c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(p0.x + (list_w - t_w) * 0.5, body_y + body_h * 0.4), c.igGetColorU32_Vec4(theme.dim()), t, null);
        }

        // The picked item: its own preview in a card, then its name and details.
        const rx = p0.x + list_w + gap;
        const rw = @max(size.x - list_w - gap, fs * 4);
        const meta_h = c.igGetTextLineHeightWithSpacing() * 2.6;
        const card_h = @max(body_h - meta_h, fs * 4);
        c.ImDrawList_AddRectFilled(dl, cimgui.vec2(rx, body_y), cimgui.vec2(rx + rw, body_y + card_h), c.igGetColorU32_Vec4(pal.row_alt), 10, 0);
        if (self.peek_sel < self.peek_order.items.len) {
            const e = l.entries[self.peek_order.items[self.peek_sel]];
            if (self.peek_inner == null) {
                if (alloc.create(View)) |v| {
                    v.* = .{};
                    self.peek_inner = v;
                } else |_| {}
            }
            var pb: [std.fs.max_path_bytes]u8 = undefined;
            const item = std.fmt.bufPrint(&pb, "{s}/{s}", .{ if (std.mem.eql(u8, self.path.items, "/")) "" else self.path.items, e.name }) catch "";
            if (self.peek_inner) |inner| {
                inner.update(io, alloc, if (item.len > 0) item else null, stampOf(e));
                const pad = fs * 0.6;
                c.igSetCursorScreenPos(cimgui.vec2(rx + pad, body_y + pad));
                _ = inner.drawPreview(cimgui.vec2(rw - pad * 2, card_h - pad * 2), null);
            }
            c.igSetCursorScreenPos(cimgui.vec2(rx, body_y + card_h + fs * 0.5));
            c.igPushTextWrapPos(rx + rw);
            cimgui.pushFontTimes(1.15);
            cimgui.textUnformatted(e.name);
            c.igPopFont();
            var kb: [64]u8 = undefined;
            var zb: [32]u8 = undefined;
            var tb: [32]u8 = undefined;
            var mb: [160]u8 = undefined;
            const kind = b.typeLabel(e, &kb);
            const date = if (e.mtime_secs > 0) core.scan.formatDateFriendly(&tb, e.mtime_secs, now) else "";
            const meta = if (e.isDir())
                std.mem.print(&mb, "{s} \u{00B7} {s}", .{ kind, date }) catch kind
            else
                std.mem.print(&mb, "{s} \u{00B7} {s} \u{00B7} {s}", .{ core.scan.humanizeSize(&zb, e.size), kind, date }) catch kind;
            c.igSetCursorScreenPos(cimgui.vec2(rx, c.igGetCursorScreenPos().y)); // (each line starts at the window's left)
            c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
            cimgui.textUnformatted(meta);
            c.igPopStyleColor(1);
            c.igPopTextWrapPos();
        }
        return enter;
    }

    /// takeOpenRequest reports, once, a double-click on the picture shown fitted (the
    /// Preview pane's, the gallery's): show it in Quick Look.
    pub fn takeOpenRequest(self: *View) bool {
        const r = self.open_request;
        self.open_request = false;
        return r;
    }

    /// moreInfo is the technical details of what `path` shows, once loaded:
    /// "Label\tValue" lines (borrowed until the next update), or null for none.
    /// Without ffprobe, a picture's dimensions from its header.
    pub fn moreInfo(self: *View, path: []const u8) ?[]const u8 {
        if (self.loading or !std.mem.eql(u8, path, self.path.items)) return null;
        if (self.info) |t| return t;
        const d = self.dimensions(path) orelse return null;
        return std.fmt.bufPrint(&self.dims_buf, "Dimensions\t{d} \u{00D7} {d}", .{ d[0], d[1] }) catch null;
    }

    /// dimensions is the size of the picture `path` shows, once it has loaded
    /// (null: not a picture, unknown, or another item's).
    pub fn dimensions(self: *const View, path: []const u8) ?[2]c_int {
        if (self.loading or self.tex == 0 or self.img_w <= 0 or self.img_h <= 0) return null;
        if (!std.mem.eql(u8, path, self.path.items)) return null;
        return .{ self.img_w, self.img_h };
    }

    /// update points the preview at `path` (the cursor's item; null = nothing) and
    /// picks up a finished load. Call every frame while open. `stamp` (stampOf) is
    /// the item's modification time and size: when it changes, the item is read
    /// again (a picture rotated in place, a file rewritten).
    pub fn update(self: *View, io: std.Io, alloc: std.mem.Allocator, path: ?[]const u8, stamp: u64) void {
        const p = path orelse "";
        if (!std.mem.eql(u8, p, self.path.items) or stamp != self.stamp) {
            self.stamp = stamp;
            self.path.clearRetainingCapacity();
            self.path.appendSlice(alloc, p) catch {};
            if (p.len > 0) {
                if (self.loader == null) self.loader = Loader.create(io, alloc) catch null;
                if (self.loader) |l| {
                    self.gen = l.request(p);
                    self.loading = true;
                }
            }
        }
        var info: ?[]u8 = null;
        var listing: ?core.scan.Listing = null;
        if (self.loading) if (self.loader) |l| if (l.poll(self.gen, &info, &listing)) |content| {
            self.loading = false;
            self.clear(alloc);
            self.info = info;
            self.listing = listing;
            self.sortPeek(alloc);
            switch (content) {
                .image => |im| {
                    self.tex = zfd_texture_upload(im.px, im.w, im.h);
                    self.tex_w = @floatFromInt(im.w);
                    self.tex_h = @floatFromInt(im.h);
                    self.img_w = im.full_w;
                    self.img_h = im.full_h;
                    zfd_image_free(im.px);
                },
                .text => |t| {
                    self.text = t;
                    self.is_message = false;
                    self.is_folder = false;
                },
                .message => |t| {
                    self.text = t;
                    self.is_message = true;
                    self.is_folder = false;
                },
                .folder => |t| {
                    self.text = t;
                    self.is_message = false;
                    self.is_folder = true;
                },
            }
        };
    }

    /// Enter is what a click in a folder's preview asks for: go into the folder
    /// (path), with item `select` picked if one was clicked. Slices borrow the view
    /// until its next update.
    pub const Enter = struct { path: []const u8, select: ?[]const u8 = null };

    /// drawPreview fills a `size` box at the cursor with the preview: the picture
    /// centred, the text scrolling, or the message centred. A folder's preview can be
    /// clicked into (returned for the caller to navigate).
    pub fn drawPreview(self: *View, size: c.ImVec2_c, zoom: ?*Zoom) ?Enter {
        var enter: ?Enter = null;
        _ = c.igBeginChild_Str("##qlpreview", size, 0, if (self.text != null and !self.is_message) 0 else c.ImGuiWindowFlags_NoScrollbar);
        defer c.igEndChild();
        if (self.path.items.len == 0) {
            centeredText("Nothing selected");
        } else if (self.loading and self.tex == 0 and self.text == null) {
            centeredText("Loading\u{2026}");
        } else if (self.tex != 0) {
            self.drawImage(zoom);
        } else if (self.text) |t| {
            if (self.is_folder) {
                if (drawFolder(t)) |hit| enter = .{ .path = self.path.items, .select = if (hit.len > 0) hit else null };
            } else if (self.is_message) {
                centeredText(t);
            } else {
                // Text wraps at the edge, like Quick Look's (no sideways scrolling).
                c.igPushTextWrapPos(0);
                cimgui.textUnformatted(t);
                c.igPopTextWrapPos();
            }
        }
        return enter;
    }

    /// zoom_max is how far a picture zooms in past fitting it.
    const zoom_max = 16;

    fn drawImage(self: *View, zoom: ?*Zoom) void {
        var fitted: Zoom = .{ .tex = self.tex };
        const z = zoom orelse &fitted;
        if (z.tex != self.tex) z.* = .{ .tex = self.tex }; // a new picture: fitted
        const avail = c.igGetContentRegionAvail();
        const origin = c.igGetCursorScreenPos();
        _ = c.igInvisibleButton("##qlimage", avail, 0); // (the area: hover and drag)
        // Fitted, it's never upscaled past 1:1; zoomed, it grows from there.
        const fit = @min(@min(avail.x / self.tex_w, avail.y / self.tex_h), 1.0);
        if (zoom == null and c.igIsItemHovered(0) and c.igIsMouseDoubleClicked_Nil(0)) self.open_request = true;
        if (zoom != null and c.igIsItemHovered(0)) {
            const ctrl = c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl);
            // Scrolling zooms (a picture has nothing to scroll; Ctrl too, as in the
            // list). It's ours: nothing else scrolls with it.
            c.igSetKeyOwner(c.ImGuiKey_MouseWheelY, c.igGetID_Str("##qlzoom"), 0);
            const wheel = cimgui.zfd_mouse_wheel();
            if (wheel != 0) {
                // Zoom toward the pointer: the spot under it stays under it.
                const old = z.zoom;
                z.zoom = std.math.clamp(old * std.math.pow(f32, 1.1, wheel), 1, zoom_max);
                const m = c.igGetMousePos();
                const cx = origin.x + avail.x * 0.5 + z.pan[0];
                const cy = origin.y + avail.y * 0.5 + z.pan[1];
                const k = z.zoom / old;
                z.pan[0] += (m.x - cx) * (1 - k);
                z.pan[1] += (m.y - cy) * (1 - k);
            }
            if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_0, false)) z.zoom = 1;
            if (z.zoom > 1 and c.igIsMouseDoubleClicked_Nil(0)) z.zoom = 1;
        }
        if (z.zoom > 1 and c.igIsItemActive()) {
            const d = c.igGetMouseDragDelta(0, 0);
            c.igResetMouseDragDelta(0);
            z.pan[0] += d.x;
            z.pan[1] += d.y;
            c.igSetMouseCursor(c.ImGuiMouseCursor_ResizeAll);
        }
        const w = self.tex_w * fit * z.zoom;
        const h = self.tex_h * fit * z.zoom;
        // How far it may go off centre: up to half off screen. Bigger than the
        // window, until its edge reaches the window's middle; smaller, until its own
        // middle reaches the window's edge. (Exactly "covers the window" pinned a
        // smaller one to the middle and stopped a drag dead at the edge.) Fitted,
        // it's centred.
        if (z.zoom <= 1) z.pan = .{ 0, 0 };
        const px = @max(w, avail.x) * 0.5;
        const py = @max(h, avail.y) * 0.5;
        z.pan[0] = std.math.clamp(z.pan[0], -px, px);
        z.pan[1] = std.math.clamp(z.pan[1], -py, py);
        const x0 = origin.x + (avail.x - w) * 0.5 + z.pan[0];
        const y0 = origin.y + (avail.y - h) * 0.5 + z.pan[1];
        const ref: c.ImTextureRef_c = .{ ._TexData = null, ._TexID = self.tex };
        c.ImDrawList_AddImage(c.igGetWindowDrawList(), ref, cimgui.vec2(x0, y0), cimgui.vec2(x0 + w, y0 + h), cimgui.vec2(0, 0), cimgui.vec2(1, 1), 0xFFFFFFFF);
    }


};

/// drawFolder is a folder's preview: a big folder icon, the item count under it,
/// then the first names. Double-clicking the icon returns "" (go into the folder);
/// clicking a name returns it (go in with it picked).
fn drawFolder(t: []const u8) ?[]const u8 {
    var hit: ?[]const u8 = null;
    const fs = c.igGetFontSize();
    const avail = c.igGetContentRegionAvail();
    const icon = @min(avail.x * 0.45, fs * 7);
    const cur = c.igGetCursorScreenPos();
    const ix = cur.x + (avail.x - icon) * 0.5;
    c.igSetCursorScreenPos(cimgui.vec2(ix, cur.y + fs * 0.5));
    _ = c.igInvisibleButton("##qlfolder", cimgui.vec2(icon, icon), 0);
    if (c.igIsItemHovered(0)) {
        c.igSetTooltip("Double-click to open");
        if (c.igIsMouseDoubleClicked_Nil(0)) hit = "";
    }
    icons.draw(c.igGetWindowDrawList(), .{ .name = @constCast("folder"), .kind = .dir }, ix, cur.y + fs * 0.5, icon, false);
    c.igSetCursorScreenPos(cimgui.vec2(cur.x, cur.y + icon + fs * 1.5));
    const nl = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    const count = t[0..nl];
    const tw = c.igCalcTextSize(count.ptr, count.ptr + count.len, false, -1).x;
    c.igSetCursorPosX(c.igGetCursorPosX() + @max((avail.x - tw) * 0.5, 0));
    cimgui.textUnformatted(count);
    if (nl >= t.len) return hit;
    c.igSpacing();
    var it = std.mem.splitScalar(u8, t[nl + 1 ..], '\n');
    var k: c_int = 0;
    while (it.next()) |line| : (k += 1) {
        if (std.mem.eql(u8, line, "\u{2026}")) {
            cimgui.textUnformatted(line);
            continue;
        }
        c.igPushID_Int(k);
        var lb: [300]u8 = undefined;
        const label = std.mem.printSentinel(&lb, "{s}", .{line}, 0) catch "";
        if (c.igSelectable_Bool(label.ptr, false, 0, cimgui.vec2(0, 0))) hit = std.mem.trimEnd(u8, line, "/");
        c.igPopID();
    }
    return hit;
}

fn centeredText(t: []const u8) void {
    const avail = c.igGetContentRegionAvail();
    var it = std.mem.splitScalar(u8, t, '\n');
    var lines: f32 = 0;
    while (it.next()) |_| lines += 1;
    const cur = c.igGetCursorPos();
    c.igSetCursorPosY(cur.y + @max((avail.y - lines * c.igGetTextLineHeightWithSpacing()) * 0.5, 0));
    it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |line| {
        const tw = c.igCalcTextSize(line.ptr, line.ptr + line.len, false, -1).x;
        c.igSetCursorPosX(cur.x + @max((avail.x - tw) * 0.5, 0));
        cimgui.textUnformatted(line);
    }
}
