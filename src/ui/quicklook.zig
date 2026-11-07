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

extern fn zfd_image_load_mem(buf: [*]const u8, len: c_int, max_dim: c_int, w: *c_int, h: *c_int) ?[*]u8;
extern fn zfd_image_free(px: [*]u8) void;
extern fn zfd_texture_upload(px: [*]const u8, w: c_int, h: c_int) c_uint;
extern fn zfd_texture_free(tex: c_uint) void;

const max_dim = 2048; // longest side of a decoded preview
const text_limit = 64 * 1024; // bytes of a text file shown

const Content = union(enum) {
    image: struct { px: [*]u8, w: c_int, h: c_int },
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
    fn poll(self: *Loader, gen: u64) ?Content {
        if (!self.mutex.tryLock()) return null;
        defer self.mutex.unlock(self.io);
        const r = self.ready orelse return null;
        if (self.ready_gen != gen) return null;
        self.ready = null;
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
            self.alloc.free(path);

            self.mutex.lockUncancelable(self.io);
            if (self.ready) |old| old.deinit(self.alloc);
            self.ready = content;
            self.ready_gen = gen;
            c.glfwPostEmptyEvent(); // wake an idle UI loop
        }
        self.mutex.unlock(self.io);
    }
};

/// load builds the preview for `path` (worker thread).
fn load(io: std.Io, alloc: std.mem.Allocator, path: []const u8) Content {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return message(alloc, "Can't read this item", .{});
    if (st.kind == .directory) return folderSummary(io, alloc, path);

    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const pz = std.mem.printSentinel(&zbuf, "{s}", .{path}, 0) catch return message(alloc, "Path too long", .{});
    const ext = extLower(path);

    if (isAny(ext, &.{ "png", "jpg", "jpeg", "gif", "bmp", "tga", "psd", "pnm", "ppm", "pgm", "pic" })) {
        var w: c_int = 0;
        var h: c_int = 0;
        if (@import("image.zig").load(io, pz.ptr, max_dim, &w, &h)) |px| return .{ .image = .{ .px = px, .w = w, .h = h } };
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
    if (core.archive.isArchive(path)) {
        if (archiveListing(io, alloc, path)) |t| return .{ .text = t };
    }
    if (textPreview(io, alloc, path)) |t| return .{ .text = t };

    var sb: [24]u8 = undefined;
    return message(alloc, "No preview available\n\n{s}", .{core.scan.humanizeSize(&sb, st.size)});
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
    const shown = 40;
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
    const Ctx = struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            const ad = std.mem.endsWith(u8, a, "/");
            const bd = std.mem.endsWith(u8, b, "/");
            if (ad != bd) return ad;
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    };
    std.mem.sort([]u8, names.items, {}, Ctx.less);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    out.print(alloc, "{d}{s} item{s}", .{ n, if (n >= limit) "+" else "", if (n == 1) "" else "s" }) catch {};
    for (names.items[0..@min(shown, names.items.len)]) |nm| {
        out.append(alloc, '\n') catch break;
        out.appendSlice(alloc, nm) catch break;
    }
    if (n > shown and names.items.len > 0) out.appendSlice(alloc, "\n\u{2026}") catch {};
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

/// archiveListing previews an archive as its contents: how many entries, then the
/// first few hundred paths (`bsdtar -tf`, which reads zip, tar.*, 7z, rar, iso, …).
/// Null when bsdtar is missing or can't read it.
fn archiveListing(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const out = runCapture(io, alloc, &.{ "bsdtar", "-tf", path }, 4 << 20) orelse return null;
    defer alloc.free(out);
    const shown_max = 400;
    var lines: usize = 0;
    var cut: usize = out.len;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    var pos: usize = 0;
    while (it.next()) |line| {
        lines += 1;
        if (lines == shown_max) cut = pos + line.len;
        pos += line.len + 1;
    }
    if (lines == 0) return null;
    const more = if (lines > shown_max) lines - shown_max else 0;
    return alloc.print("{d} item{s} inside{s}\n\n{s}{s}", .{
        lines,                                        if (lines == 1) "" else "s",
        if (out.len >= 4 << 20) " (or more)" else "", out[0..@min(cut, out.len)],
        if (more > 0) "\n\u{2026}" else "",
    }) catch null;
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
pub const View = struct {
    loader: ?*Loader = null,
    path: std.ArrayList(u8) = .empty, // what the window shows (or is loading)
    gen: u64 = 0,
    loading: bool = false,
    tex: c_uint = 0,
    tex_w: f32 = 0,
    tex_h: f32 = 0,
    text: ?[]u8 = null, // text or message being shown (owned)
    is_message: bool = false,
    is_folder: bool = false, // text is a folderSummary: drawn with a folder icon

    pub fn deinit(self: *View, alloc: std.mem.Allocator) void {
        self.clear(alloc);
        self.path.deinit(alloc);
        if (self.loader) |l| l.destroy();
    }

    fn clear(self: *View, alloc: std.mem.Allocator) void {
        if (self.tex != 0) zfd_texture_free(self.tex);
        self.tex = 0;
        if (self.text) |t| alloc.free(t);
        self.text = null;
    }

    /// update points the preview at `path` (the cursor's item; null = nothing) and
    /// picks up a finished load. Call every frame while open.
    pub fn update(self: *View, io: std.Io, alloc: std.mem.Allocator, path: ?[]const u8) void {
        const p = path orelse "";
        if (!std.mem.eql(u8, p, self.path.items)) {
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
        if (self.loading) if (self.loader) |l| if (l.poll(self.gen)) |content| {
            self.loading = false;
            self.clear(alloc);
            switch (content) {
                .image => |im| {
                    self.tex = zfd_texture_upload(im.px, im.w, im.h);
                    self.tex_w = @floatFromInt(im.w);
                    self.tex_h = @floatFromInt(im.h);
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
    pub fn drawPreview(self: *View, size: c.ImVec2_c) ?Enter {
        var enter: ?Enter = null;
        _ = c.igBeginChild_Str("##qlpreview", size, 0, if (self.text != null and !self.is_message) 0 else c.ImGuiWindowFlags_NoScrollbar);
        defer c.igEndChild();
        if (self.path.items.len == 0) {
            centeredText("Nothing selected");
        } else if (self.loading and self.tex == 0 and self.text == null) {
            centeredText("Loading\u{2026}");
        } else if (self.tex != 0) {
            self.drawImage();
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

    fn drawImage(self: *View) void {
        const avail = c.igGetContentRegionAvail();
        const scale = @min(@min(avail.x / self.tex_w, avail.y / self.tex_h), 1.0); // never upscale past 1:1
        const w = self.tex_w * scale;
        const h = self.tex_h * scale;
        const cur = c.igGetCursorPos();
        c.igSetCursorPos(cimgui.vec2(cur.x + @max((avail.x - w) * 0.5, 0), cur.y + @max((avail.y - h) * 0.5, 0)));
        const ref: c.ImTextureRef_c = .{ ._TexData = null, ._TexID = self.tex };
        c.igImage(ref, cimgui.vec2(w, h), cimgui.vec2(0, 0), cimgui.vec2(1, 1));
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
