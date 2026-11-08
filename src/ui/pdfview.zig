//! PdfDoc: a PDF read in Quick Look: every page, one under the other (or two side by
//! side), scrolled through, with what a decent reader has: a toolbar (zoom, fit the
//! width or the page, two-page spread, the page number to type a page into), a
//! sidebar of the pages' thumbnails and the table of contents, find, and text to
//! select and copy. Page Up / Page Down go a page at a time (Settings), Home / End
//! to either end; wheel steps glide.
//!
//! poppler's tools do the reading (an optional dependency, run, not linked): pdfinfo
//! for the pages' sizes, pdftoppm for a page's picture, pdftohtml for the table of
//! contents, pdftotext for the words and where they sit (read when first wanted:
//! find or a selection). A worker draws only the pages in view, at the width they're
//! shown at (then the sidebar's thumbnails); pages out of view give theirs back.
//! Until the first page has a picture of its own the preview's is shown in its
//! place, so opening one goes straight to its first page.

const std = @import("std");
const cimgui = @import("cimgui.zig");
const c = cimgui.c;
const core = @import("core");
const pdftext = core.pdftext;
const theme = @import("theme.zig");
const anim = @import("anim.zig");
const ql = @import("quicklook.zig");
const x11 = @import("x11.zig");

extern fn zfd_image_load_mem(buf: [*]const u8, len: c_int, max_dim: c_int, w: *c_int, h: *c_int) ?[*]u8;
extern fn zfd_image_free(px: [*]u8) void;
extern fn zfd_texture_upload(px: [*]const u8, w: c_int, h: c_int) c_uint;
extern fn zfd_texture_free(tex: c_uint) void;

/// snap_pages: Page Up / Page Down land on a page's top (else a screen at a time).
/// Settings > General.
pub var snap_pages: bool = true;
/// sidebar_shown: a PDF opens with its sidebar, until it's hidden (remembered).
pub var sidebar_shown: bool = true;

// What the reader's keys took this frame, for the shell's own shortcuts to leave alone.
var keys_frame: c_int = -10;
var has_selection = false;
var find_shown = false;

/// ownsKeys: a PDF is being read (its Ctrl+F, Ctrl+A, Page Up/Down are its own).
pub fn ownsKeys() bool {
    return keys_frame >= c.igGetFrameCount() - 1;
}
/// takesCopy: Ctrl+C copies the PDF's selected text, not the files.
pub fn takesCopy() bool {
    return ownsKeys() and has_selection;
}
/// takesEscape: Escape closes its find bar (or drops its selection) first.
pub fn takesEscape() bool {
    return ownsKeys() and (find_shown or has_selection);
}

const max_pages = 5000;
const max_px = 2560; // widest a page is drawn (an A4 page that wide is ~37 MB)
const keep_around = 3; // pages either side of the view keeping their pictures
const zoom_max = 8;
const zoom_min = 0.1;
const pt_px: f32 = 96.0 / 72.0; // a point at 100%: the page at its real size (96 px an inch)
const bar_zone: f32 = 14; // how near the edge the pointer brings the scrollbar
const glide: f32 = 0.11; // seconds a wheel step or a page key's scroll takes
const wheel_lines: f32 = 8; // lines of text a wheel step scrolls

const Side = enum { none, thumbs, contents };

/// TextJob reads the document's words on a thread of its own (pdftotext can take a
/// while on a long one); refcounted, so closing the PDF doesn't wait for it.
const TextJob = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    path: []u8,
    mutex: std.Io.Mutex = .init,
    result: ?*pdftext.Text = null,
    done: bool = false,
    refs: std.atomic.Value(u8) = .init(2),

    fn run(self: *TextJob) void {
        defer self.unref();
        var text: ?*pdftext.Text = null;
        if (ql.runCapture(self.io, self.alloc, &.{ "pdftotext", "-bbox", "-q", self.path, "-" }, 512 << 20)) |out| {
            defer self.alloc.free(out);
            text = pdftext.parseWords(self.alloc, out) catch null;
        }
        self.mutex.lockUncancelable(self.io);
        self.result = text;
        self.done = true;
        self.mutex.unlock(self.io);
        c.glfwPostEmptyEvent();
    }

    fn unref(self: *TextJob) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.result) |t| t.destroy(self.alloc);
        self.alloc.free(self.path);
        self.alloc.destroy(self);
    }
};

const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

pub const PdfDoc = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    path: []u8,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    // Guarded by mutex:
    sizes: ?[][2]f32 = null, // each page's size in points, upright (from pdfinfo)
    failed: bool = false, // pdfinfo couldn't read it (not installed, encrypted, …)
    outline_arena: std.heap.ArenaAllocator,
    outline: ?[]pdftext.Entry = null, // (null: not read yet)
    want: ?Want = null,
    busy: bool = false,
    ready: ?Ready = null,
    shutdown: bool = false,
    // The UI's own:
    pages: []Pic = &.{},
    thumbs: []Pic = &.{},
    page_size: [][2]f32 = &.{},
    rects: []Rect = &.{}, // each page's place, in the content (layout)
    toc: []pdftext.Entry = &.{},
    // The zoom: 1 is the pages' real size. It stays as it's set, whatever the window
    // does (full screen, in or out, keeps the pages as they were); opening a PDF, and
    // Fit Width, Fit Page and two pages set it to fit.
    zoom: f32 = 1,
    fitted: u8 = 0, // what it was fitted to: 1 the preview's page, 2 the document
    refit: bool = false, // fit the width on the next layout
    rot: u2 = 0, // quarter turns clockwise (the view's: rotate)
    spread: bool = false, // two pages side by side
    side: Side = .none,
    at_centre: u32 = 0, // the page in the middle of the view
    goto: ?Goto = null, // scroll there next frame (when the layout is known)
    shown: bool = false, // drawn with a picture yet (until then: nothing, not white pages)
    touched: f64 = -10, // when it last scrolled (its scrollbars show a while after)
    moved: f64 = -10, // when the pointer last moved over it (the toolbar shows a while)
    last_mouse: c.ImVec2_c = .{ .x = 0, .y = 0 },
    bar_drag: bool = false, // the vertical scrollbar is held
    bar_grab: ?f32 = null, // where on its thumb
    glide_to: ?f32 = null, // where a gliding scroll is headed
    press: c.ImVec2_c = .{ .x = 0, .y = 0 },
    // Text: find and selection.
    text: ?*pdftext.Text = null,
    text_job: ?*TextJob = null,
    text_failed: bool = false,
    find_open: bool = false,
    find_focus: bool = false,
    find_buf: [128]u8 = @splat(0),
    find_done: [128]u8 = @splat(0), // what `hits` are for
    hits: []pdftext.Hit = &.{},
    hit: usize = 0,
    sel_a: ?pdftext.Pos = null,
    sel_b: ?pdftext.Pos = null,
    selecting: bool = false,
    want_select: bool = false, // a Shift+drag began before the words were read
    want_all: bool = false, // Ctrl+A, waiting for the words
    page_edit: bool = false,
    page_buf: [12]u8 = @splat(0),
    thumb_need: ?Want = null, // the sidebar's first thumbnail lacking its picture
    side_follow: u32 = std.math.maxInt(u32), // the page the sidebar last scrolled to

    const Want = struct { page: u32, width: u32, thumb: bool = false };
    const Ready = struct { page: u32, width: u32, thumb: bool, px: ?[*]u8, w: c_int, h: c_int };
    const Pic = struct { tex: c_uint = 0, width: u32 = 0, tried: u32 = 0 };
    // frac: how far down the page; `top`: that point at the view's top (else a third
    // of the way down, for a find match).
    const Goto = struct { page: u32, frac: f32 = 0, top: bool = false, centre: bool = false };

    pub fn create(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !*PdfDoc {
        const self = try alloc.create(PdfDoc);
        errdefer alloc.destroy(self);
        const p = try alloc.dupe(u8, path);
        errdefer alloc.free(p);
        self.* = .{ .io = io, .alloc = alloc, .path = p, .outline_arena = .init(alloc), .side = if (sidebar_shown) .thumbs else .none };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn destroy(self: *PdfDoc) void {
        self.mutex.lockUncancelable(self.io);
        self.shutdown = true;
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);
        if (self.thread) |t| t.join();
        if (self.ready) |r| if (r.px) |px| zfd_image_free(px);
        if (self.sizes) |s| self.alloc.free(s);
        for (self.pages) |pg| if (pg.tex != 0) zfd_texture_free(pg.tex);
        for (self.thumbs) |pg| if (pg.tex != 0) zfd_texture_free(pg.tex);
        self.alloc.free(self.pages);
        self.alloc.free(self.thumbs);
        self.alloc.free(self.page_size);
        self.alloc.free(self.rects);
        self.alloc.free(self.hits);
        if (self.text) |t| t.destroy(self.alloc);
        if (self.text_job) |j| j.unref();
        self.outline_arena.deinit();
        self.alloc.free(self.path);
        self.alloc.destroy(self);
        has_selection = false;
        find_shown = false;
    }

    pub fn isFor(self: *const PdfDoc, path: []const u8) bool {
        return std.mem.eql(u8, self.path, path);
    }

    fn run(self: *PdfDoc) void {
        const sizes = readInfo(self.io, self.alloc, self.path);
        self.mutex.lockUncancelable(self.io);
        if (sizes) |s| self.sizes = s else self.failed = true;
        self.mutex.unlock(self.io);
        c.glfwPostEmptyEvent();
        if (sizes == null) return;
        // The table of contents (pdftohtml writes it whatever pages it's asked for).
        var toc: []pdftext.Entry = &.{};
        if (ql.runCapture(self.io, self.alloc, &.{ "pdftohtml", "-xml", "-stdout", "-i", "-q", "-f", "1", "-l", "1", self.path }, 64 << 20)) |out| {
            defer self.alloc.free(out);
            self.mutex.lockUncancelable(self.io);
            toc = pdftext.parseOutline(self.outline_arena.allocator(), out) catch &.{};
            self.mutex.unlock(self.io);
        }
        self.mutex.lockUncancelable(self.io);
        self.outline = toc;
        while (true) {
            while (self.want == null and !self.shutdown) self.cond.waitUncancelable(self.io, &self.mutex);
            if (self.shutdown) break;
            const w = self.want.?;
            self.want = null;
            self.busy = true;
            self.mutex.unlock(self.io);

            var pb: [16]u8 = undefined;
            var wb: [16]u8 = undefined;
            const pn = std.fmt.bufPrint(&pb, "{d}", .{w.page + 1}) catch "1";
            const wn = std.fmt.bufPrint(&wb, "{d}", .{w.width}) catch "1024";
            var ready: Ready = .{ .page = w.page, .width = w.width, .thumb = w.thumb, .px = null, .w = 0, .h = 0 };
            if (ql.runCapture(self.io, self.alloc, &.{ "pdftoppm", "-f", pn, "-l", pn, "-singlefile", "-scale-to-x", wn, "-scale-to-y", "-1", self.path }, 256 << 20)) |data| {
                defer self.alloc.free(data);
                ready.px = zfd_image_load_mem(data.ptr, @intCast(data.len), 8192, &ready.w, &ready.h);
            }

            self.mutex.lockUncancelable(self.io);
            self.busy = false;
            if (self.ready) |old| if (old.px) |px| zfd_image_free(px);
            self.ready = ready;
            c.glfwPostEmptyEvent();
        }
        self.mutex.unlock(self.io);
    }

    /// sync takes what the workers have finished: the pages' sizes, the table of
    /// contents, a page's picture, the words.
    fn sync(self: *PdfDoc) void {
        if (self.text_job) |j| {
            j.mutex.lockUncancelable(self.io);
            const done = j.done;
            if (done) {
                self.text = j.result;
                j.result = null;
                self.text_failed = self.text == null;
            }
            j.mutex.unlock(self.io);
            if (done) {
                j.unref();
                self.text_job = null;
                self.find_done[0] = 0xff; // (find again, now there's text)
            }
        }
        if (!self.mutex.tryLock()) return;
        defer self.mutex.unlock(self.io);
        if (self.pages.len == 0) if (self.sizes) |s| {
            const a = self.alloc;
            const pages = a.alloc(Pic, s.len) catch return;
            const thumbs = a.alloc(Pic, s.len) catch return a.free(pages);
            const sz = a.dupe([2]f32, s) catch {
                a.free(pages);
                return a.free(thumbs);
            };
            const rects = a.alloc(Rect, s.len) catch {
                a.free(pages);
                a.free(thumbs);
                return a.free(sz);
            };
            @memset(pages, .{});
            @memset(thumbs, .{});
            @memset(rects, .{});
            self.pages = pages;
            self.thumbs = thumbs;
            self.page_size = sz;
            self.rects = rects;
        };
        if (self.toc.len == 0) if (self.outline) |o| {
            self.toc = o;
        };
        const r = self.ready orelse return;
        self.ready = null;
        const list = if (r.thumb) self.thumbs else self.pages;
        if (r.page >= list.len) {
            if (r.px) |px| zfd_image_free(px);
            return;
        }
        const pg = &list[r.page];
        pg.tried = r.width;
        if (r.px) |px| {
            defer zfd_image_free(px);
            if (pg.tex != 0) zfd_texture_free(pg.tex);
            pg.tex = zfd_texture_upload(px, r.w, r.h);
            pg.width = r.width;
        }
    }

    /// ask hands the worker a picture to draw at `width` pixels, if it's free.
    fn ask(self: *PdfDoc, w: Want) bool {
        if (!self.mutex.tryLock()) return false;
        defer self.mutex.unlock(self.io);
        if (self.busy or self.want != null or self.ready != null) return false;
        self.want = w;
        self.cond.signal(self.io);
        return true;
    }

    fn hasFailed(self: *PdfDoc) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.failed;
    }

    /// needText starts reading the words, if that's not done or under way.
    fn needText(self: *PdfDoc) void {
        if (self.text != null or self.text_job != null or self.text_failed) return;
        const j = self.alloc.create(TextJob) catch return;
        const p = self.alloc.dupe(u8, self.path) catch return self.alloc.destroy(j);
        j.* = .{ .io = self.io, .alloc = self.alloc, .path = p };
        const t = std.Thread.spawn(.{}, TextJob.run, .{j}) catch {
            self.alloc.free(p);
            return self.alloc.destroy(j);
        };
        t.detach();
        self.text_job = j;
    }

    /// rotate turns the pages a quarter, right (clockwise) or left, keeping the page
    /// in view (the view only: the file isn't changed).
    pub fn rotate(self: *PdfDoc, right: bool) void {
        self.rot = if (right) self.rot +% 1 else self.rot -% 1;
        self.goto = .{ .page = self.at_centre };
        // The thumbnails turn too: drawn again the other way round.
    }

    // --- layout ------------------------------------------------------------------

    /// layout places every page at the zoom (each its own size, centred in a column
    /// as wide as the widest); the content's size.
    fn layout(self: *PdfDoc, sizes: []const [2]f32, rects: []Rect, margin: f32, gap: f32) [2]f32 {
        const k = self.zoom * pt_px;
        const turned = self.rot % 2 == 1;
        var col: f32 = 1;
        for (sizes) |ps| col = @max(col, (if (turned) ps[1] else ps[0]) * k);
        const per: usize = if (self.spread) 2 else 1;
        const row_w = if (self.spread) col * 2 + gap else col;
        var y = margin;
        var i: usize = 0;
        while (i < sizes.len) {
            const n = @min(per, sizes.len - i);
            var row_h: f32 = 0;
            for (0..n) |j| {
                const ps = sizes[i + j];
                const w = (if (turned) ps[1] else ps[0]) * k;
                const h = (if (turned) ps[0] else ps[1]) * k;
                const x = margin + (if (n == 1 and per == 2) (col + gap) * 0.5 else @as(f32, @floatFromInt(j)) * (col + gap)) + (col - w) * 0.5;
                rects[i + j] = .{ .x = x, .y = y, .w = w, .h = h };
                row_h = @max(row_h, h);
            }
            y += row_h + gap;
            i += n;
        }
        return .{ row_w + margin * 2, y - gap + margin };
    }

    /// rowTop is where the view's top goes to show page `i`'s row from its top.
    fn rowTop(self: *const PdfDoc, rects: []const Rect, i: usize, gap: f32) f32 {
        _ = self;
        return @max(rects[i].y - gap * 0.5, 0);
    }

    /// scrollTo glides (or jumps) the view to `y`.
    fn scrollTo(self: *PdfDoc, y: f32, smooth: bool) void {
        const t = std.math.clamp(y, 0, c.igGetScrollMaxY());
        if (smooth and !anim.reduce_motion) {
            anim.play(c.igGetID_Str("##pdfglide"), c.igGetScrollY(), t, glide, .out_cubic);
            self.glide_to = t;
        } else {
            self.glide_to = null;
            c.igSetScrollY_Float(t);
        }
        self.touched = c.igGetTime();
    }

    /// pageKey is where Page Down (or Up) goes from `cur`: a page's top when snapping
    /// (a screen at a time through a page taller than the view, then its next page's
    /// top exactly, so reading by pages never drifts), else a screen.
    fn pageKey(self: *const PdfDoc, rects: []const Rect, cur: f32, view: f32, down: bool, gap: f32, lh: f32) f32 {
        const step = view - lh * 3;
        if (!snap_pages or rects.len == 0) return if (down) cur + step else cur - step;
        const per: usize = if (self.spread) 2 else 1;
        if (down) {
            var i: usize = 0;
            while (i < rects.len) : (i += per) {
                const t = self.rowTop(rects, i, gap);
                if (t > cur + 1) return if (t - cur > view - lh) cur + step else t;
            }
            return c.igGetScrollMaxY();
        }
        var best: ?f32 = null;
        var i: usize = 0;
        while (i < rects.len) : (i += per) {
            const t = self.rowTop(rects, i, gap);
            if (t < cur - 1) best = t else break;
        }
        const t = best orelse return 0;
        return if (cur - t > view - lh) cur - step else t;
    }

    // --- drawing -------------------------------------------------------------------

    /// draw shows the document in `size`; false when it can't be read this way (the
    /// caller shows its usual preview instead). `pre` is the preview's picture of the
    /// first page (0: none yet), `pre_w`×`pre_h` its size.
    pub fn draw(self: *PdfDoc, size: c.ImVec2_c, pre: c_uint, pre_w: c_int, pre_h: c_int) bool {
        self.sync();
        if (self.pages.len == 0 and self.hasFailed()) return false;
        keys_frame = c.igGetFrameCount();
        has_selection = self.sel_a != null and self.sel_b != null;
        find_shown = self.find_open;

        // Until pdfinfo answers, the preview's first page stands for the document.
        var one_size = [1][2]f32{.{ @floatFromInt(@max(pre_w, 1)), @floatFromInt(@max(pre_h, 1)) }};
        var one_rect = [1]Rect{.{}};
        const known = self.pages.len > 0;
        const sizes: []const [2]f32 = if (known) self.page_size else if (pre != 0) &one_size else &.{};
        const rects: []Rect = if (known) self.rects else &one_rect;
        const first_tex = if (known and self.pages[0].tex != 0) self.pages[0].tex else pre;
        if (!self.shown and first_tex != 0 and sizes.len > 0) self.shown = true;

        const lh = c.igGetTextLineHeight();
        // The sidebar: about a fifth of the width, but its two tabs' labels always fit.
        const fp = c.igGetStyle().*.FramePadding.x;
        const tabs_w = c.igCalcTextSize("Pages", null, false, -1).x + c.igCalcTextSize("Contents", null, false, -1).x + fp * 4 + lh * 1.6;
        // (shown from the start, empty until the pages' sizes come in: the page fitted
        // beside it doesn't then shrink as it appears)
        _ = tabs_w;
        const side_w = self.sideWidth(size.x);
        if (side_w > 0) {
            self.drawSide(cimgui.vec2(side_w, size.y));
            c.igSameLine(0, 0);
        }
        const main = cimgui.vec2(@max(size.x - side_w, 40), size.y);
        // (no padding: the pages keep their own margin, and the surface over the whole
        // view would otherwise reach past the content by it, a few pixels to pan sideways
        // at Fit Width)
        c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, cimgui.vec2(0, 0));
        _ = c.igBeginChild_Str("##qlpdf", main, 0, c.ImGuiWindowFlags_NoScrollWithMouse | c.ImGuiWindowFlags_NoScrollbar);
        c.igPopStyleVar(1);
        defer c.igEndChild();
        if (!self.shown) {
            // Nothing yet: the background (a spinner if it takes a moment), not a
            // white page to be replaced by the real one.
            const wp = c.igGetWindowPos();
            if (c.igGetTime() > 0.15) ql.spinner(c.igGetWindowDrawList(), cimgui.vec2(wp.x + main.x * 0.5, wp.y + main.y * 0.5), lh * 1.1);
            _ = anim.cycle(1);
            return true;
        }

        const wpos = c.igGetWindowPos();
        const wsize = c.igGetWindowSize();
        const avail = c.igGetContentRegionAvail();
        const margin = lh;
        const gap = lh * 0.8;
        const fit_w = @max(avail.x - margin * 2, 40);
        const m = c.igGetMousePos();
        const now = c.igGetTime();
        const in_view = m.x >= wpos.x and m.y >= wpos.y and m.x < wpos.x + wsize.x and m.y < wpos.y + wsize.y;
        if (in_view and (m.x != self.last_mouse.x or m.y != self.last_mouse.y)) self.moved = now;
        self.last_mouse = m;

        // Fitted to the width when it opens (and again when its pages' sizes come in,
        // and on Fit Width / two pages); otherwise the zoom is left as it is.
        const fit_now: u8 = if (known) 2 else 1;
        if (self.fitted != fit_now) {
            self.fitted = fit_now;
            self.refit = true;
        }
        var content = self.layout(sizes, rects, margin, gap);
        if (self.refit) {
            self.refit = false;
            var widest: f32 = 1;
            for (rects[0..sizes.len]) |r| widest = @max(widest, r.w);
            const col = if (self.spread) (fit_w - gap) * 0.5 else fit_w;
            self.zoom = std.math.clamp(self.zoom * col / widest, zoom_min, zoom_max);
            content = self.layout(sizes, rects, margin, gap);
        }
        const o = c.igGetCursorScreenPos();
        const ox = o.x + @max((avail.x - content[0]) * 0.5, 0); // (narrower than the view: centred)
        const scroll_y = c.igGetScrollY();

        // A gliding scroll (wheel steps, page keys) moves on.
        if (self.glide_to != null) {
            if (anim.playing(c.igGetID_Str("##pdfglide"))) |v| c.igSetScrollY_Float(v) else {
                c.igSetScrollY_Float(self.glide_to.?);
                self.glide_to = null;
            }
        }
        if (self.goto) |g| if (g.page < rects.len) {
            const r = rects[g.page];
            const y = if (g.centre) r.y + (r.h - wsize.y) * 0.5 else if (g.top) r.y + r.h * g.frac else if (g.frac > 0) r.y + r.h * g.frac - wsize.y * 0.35 else self.rowTop(rects, g.page, gap);
            self.scrollTo(y, false);
            // (in the middle across, too, if the pages are wider than the view)
            if (g.centre and content[0] > avail.x) c.igSetScrollX_Float(r.x + (r.w - wsize.x) * 0.5);
            self.goto = null;
        };

        // The whole view takes the mouse (so a click never falls through, and a drag
        // never moves the window): a drag moves the pages, Shift+drag selects text,
        // a double-click picks a word. The toolbar and bars drawn later take theirs.
        c.igSetCursorScreenPos(wpos);
        c.igSetNextItemAllowOverlap();
        _ = c.igInvisibleButton("##pdfsurface", wsize, 0);
        const hovered = c.igIsItemHovered(0);
        const shift = c.igIsKeyDown_Nil(c.ImGuiMod_Shift);
        if (c.igIsItemActivated()) {
            self.press = m;
            if (m.x >= wpos.x + wsize.x - bar_zone) {
                self.bar_drag = true;
            } else if (shift or x11.shiftHeld()) {
                self.needText();
                self.selecting = true;
                self.sel_a = self.posAt(rects, ox, o.y, m);
                self.sel_b = self.sel_a;
                self.want_select = self.sel_a == null;
            } else self.selecting = false;
        }
        if (!c.igIsMouseDown_Nil(0)) self.bar_drag = false;
        if (c.igIsItemActive() and !self.bar_drag) {
            if (self.selecting) {
                if (self.want_select and self.text != null) {
                    self.sel_a = self.posAt(rects, ox, o.y, self.press);
                    self.want_select = false;
                }
                if (self.sel_a != null) self.sel_b = self.posAt(rects, ox, o.y, m) orelse self.sel_b;
                // Held past the top or bottom: the view follows.
                if (m.y > wpos.y + wsize.y - lh) c.igSetScrollY_Float(scroll_y + lh * 0.5) else if (m.y < wpos.y + lh) c.igSetScrollY_Float(scroll_y - lh * 0.5);
            } else {
                const d = c.igGetMouseDragDelta(0, 0);
                c.igResetMouseDragDelta(0);
                if (d.x != 0) c.igSetScrollX_Float(c.igGetScrollX() - d.x);
                if (d.y != 0) {
                    self.glide_to = null;
                    c.igSetScrollY_Float(scroll_y - d.y);
                }
                if (d.x != 0 or d.y != 0) self.touched = now;
            }
        }
        if (c.igIsItemDeactivated() and !self.selecting and !self.bar_drag) {
            // A click (not a drag) drops the selection.
            if (@abs(m.x - self.press.x) < 3 and @abs(m.y - self.press.y) < 3) {
                self.sel_a = null;
                self.sel_b = null;
            }
        }
        if (hovered and !shift and c.igIsMouseDoubleClicked_Nil(0)) {
            self.needText();
            if (self.posAt(rects, ox, o.y, m)) |p| {
                self.sel_a = p;
                self.sel_b = p;
            }
        }

        // Scroll moves through the pages (a wheel's steps glide; a touchpad's follow);
        // Ctrl+scroll zooms toward the pointer.
        if (hovered) {
            const wheel = cimgui.zfd_mouse_wheel();
            if (wheel != 0) {
                const ctrl = c.igIsKeyDown_Nil(c.ImGuiKey_LeftCtrl) or c.igIsKeyDown_Nil(c.ImGuiKey_RightCtrl);
                if (ctrl) {
                    self.zoomBy(std.math.pow(f32, 1.1, wheel), m.x - wpos.x, m.y - wpos.y);
                } else if (@abs(wheel) >= 0.99) {
                    self.scrollTo((self.glide_to orelse scroll_y) - wheel * lh * wheel_lines, true);
                } else {
                    self.glide_to = null;
                    c.igSetScrollY_Float(scroll_y - wheel * lh * wheel_lines);
                    self.touched = now;
                }
            }
        }
        self.keys(rects, wsize.y, gap, lh);

        // The pages in view, and what's marked on them.
        const dl = c.igGetWindowDrawList();
        const scale = fbScale();
        const turned = self.rot % 2 == 1;
        var first: ?u32 = null;
        var last: u32 = 0;
        var at_centre: u32 = 0;
        const view_top = wpos.y;
        const view_bot = wpos.y + wsize.y;
        var hit_i: usize = 0;
        for (sizes, 0..) |_, i| {
            const r = rects[i];
            const mn = cimgui.vec2(ox + r.x, o.y + r.y);
            const mx = cimgui.vec2(mn.x + r.w, mn.y + r.h);
            if (mn.y <= (view_top + view_bot) * 0.5) at_centre = @intCast(i);
            if (mx.y < view_top or mn.y > view_bot) continue;
            if (first == null) first = @intCast(i);
            last = @intCast(i);
            c.ImDrawList_AddRectFilled(dl, cimgui.vec2(mn.x + 1, mn.y + 2), cimgui.vec2(mx.x + 1, mx.y + 3), 0x30000000, 0, 0); // (a shadow)
            c.ImDrawList_AddRectFilled(dl, mn, mx, 0xFFFFFFFF, 0, 0);
            const tex = if (known and self.pages[i].tex != 0) self.pages[i].tex else if (i == 0) pre else 0;
            if (tex != 0) quad(dl, tex, mn, mx, self.rot) else ql.spinner(dl, cimgui.vec2((mn.x + mx.x) * 0.5, @min((mn.y + mx.y) * 0.5, mn.y + lh * 6)), lh * 0.9);
            // Find's matches (the current one stronger), the selection.
            if (self.text) |t| if (i < t.pages.len) {
                const pt = t.pages[i];
                while (hit_i < self.hits.len and self.hits[hit_i].page < i) hit_i += 1;
                var k = hit_i;
                while (k < self.hits.len and self.hits[k].page == i) : (k += 1) {
                    const h = self.hits[k];
                    const ws = pdftext.wordsOf(pt, h.start, h.end);
                    const col: u32 = if (k == self.hit) 0x7000A5FF else 0x5000E5FF; // (ABGR: orange, yellow)
                    for (pt.words[ws.first..ws.end]) |w| markWord(dl, w, mn, mx, self.rot, col);
                }
                if (self.sel_a) |a| if (self.sel_b) |b| {
                    const ac = theme.p().accent;
                    const col = c.igGetColorU32_Vec4(cimgui.vec4(ac.x, ac.y, ac.z, 0.35));
                    const lo = if (b.before(a)) b else a;
                    const hi = if (b.before(a)) a else b;
                    if (i >= lo.page and i <= hi.page) {
                        const from: usize = if (i == lo.page) lo.word else 0;
                        const to: usize = if (i == hi.page) @min(hi.word + 1, pt.words.len) else pt.words.len;
                        if (from < to) for (pt.words[from..to]) |w| markWord(dl, w, mn, mx, self.rot, col);
                    }
                };
            };
        }
        self.at_centre = at_centre;
        c.igSetCursorScreenPos(o);
        c.igDummy(cimgui.vec2(content[0], content[1]));

        // Pictures for the pages in view (then the next one), sharper ones as it zooms;
        // when they're all there, the sidebar's thumbnails.
        if (known) if (first) |f| {
            var need: ?Want = null;
            var i = f;
            while (i <= @min(last + 1, @as(u32, @intCast(self.pages.len - 1)))) : (i += 1) {
                const r = rects[i];
                const ps = self.page_size[i];
                const up_w = if (turned) r.w * scale * ps[0] / @max(ps[1], 1) else r.w * scale;
                const want: u32 = @intFromFloat(std.math.clamp(@ceil(up_w / 128) * 128, 256, max_px));
                const pg = self.pages[i];
                if ((pg.tex == 0 or pg.width * 10 < want * 9) and pg.tried != want) {
                    need = .{ .page = i, .width = want };
                    break;
                }
            }
            if (need orelse self.thumb_need) |n| _ = self.ask(n);
            for (self.pages, 0..) |*pg, k| {
                if (pg.tex == 0) continue;
                if (k + keep_around < f or k > last + keep_around) {
                    zfd_texture_free(pg.tex);
                    pg.* = .{};
                }
            }
        };

        self.drawScrollbar(dl, wpos, wsize, m, hovered or self.bar_drag);
        self.drawToolbar(dl, wpos, wsize, in_view, sizes.len, fit_w, gap, rects);
        if (self.find_open) self.drawFind(wpos, wsize, rects);
        // The toolbar, find field and bars float over the pages: what scrolls is the
        // pages alone (a toolbar wider than a narrow view made it pan sideways).
        cimgui.zfd_limit_content(o.x + content[0], o.y + content[1]);
        return true;
    }

    /// sideShown: the sidebar is out.
    pub fn sideShown(self: *const PdfDoc) bool {
        return self.side != .none;
    }

    /// sideWidth is the sidebar's width in a reader `total` wide (0 when it's hidden):
    /// about a fifth of the width, but its two tabs' labels always fit.
    pub fn sideWidth(self: *const PdfDoc, total: f32) f32 {
        return if (self.side == .none) 0 else barWidth(total);
    }

    /// barWidth is the sidebar's width in a reader `total` wide, out or not.
    pub fn barWidth(total: f32) f32 {
        const lh = c.igGetTextLineHeight();
        const fp = c.igGetStyle().*.FramePadding.x;
        const tabs_w = c.igCalcTextSize("Pages", null, false, -1).x + c.igCalcTextSize("Contents", null, false, -1).x + fp * 4 + lh * 1.6;
        return std.math.clamp(total * 0.22, @max(lh * 7, tabs_w), @max(lh * 11, tabs_w));
    }

    /// widthFor is how wide the reader must be for `main` beside the sidebar.
    pub fn widthFor(self: *const PdfDoc, main: f32) f32 {
        var w = main;
        for (0..4) |_| w = main + self.sideWidth(w); // (the sidebar's a share of the whole)
        return @round(w);
    }

    /// zoomBy zooms by `k`, keeping the point (mx, my) of the view where it is.
    fn zoomBy(self: *PdfDoc, k: f32, mx: f32, my: f32) void {
        const old = self.zoom;
        self.zoom = std.math.clamp(old * k, zoom_min, zoom_max);
        const r = self.zoom / old;
        self.glide_to = null;
        c.igSetScrollX_Float((c.igGetScrollX() + mx) * r - mx);
        c.igSetScrollY_Float((c.igGetScrollY() + my) * r - my);
        self.touched = c.igGetTime();
    }

    /// keys: Page Up / Down, Home / End, Ctrl+F, Ctrl+A, Ctrl+C, Escape.
    fn keys(self: *PdfDoc, rects: []const Rect, view: f32, gap: f32, lh: f32) void {
        if (cimgui.zfd_want_text_input()) return;
        const cur = self.glide_to orelse c.igGetScrollY();
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_PageDown, true)) self.scrollTo(self.pageKey(rects, cur, view, true, gap, lh), true);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_PageUp, true)) self.scrollTo(self.pageKey(rects, cur, view, false, gap, lh), true);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Home, false)) self.scrollTo(0, true);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_End, false)) self.scrollTo(c.igGetScrollMaxY(), true);
        const ctrl = c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl);
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_F, false)) {
            self.find_open = true;
            self.find_focus = true;
            self.needText();
        }
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_A, false)) {
            self.needText();
            self.want_all = true; // (now, or when the words have been read)
        }
        if (self.want_all) if (self.text) |t| {
            self.want_all = false;
            if (t.pages.len > 0) {
                var lp: u32 = @intCast(t.pages.len - 1);
                while (lp > 0 and t.pages[lp].words.len == 0) lp -= 1;
                self.sel_a = .{ .page = 0, .word = 0 };
                self.sel_b = .{ .page = lp, .word = @intCast(t.pages[lp].words.len -| 1) };
            }
        };
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_C, false)) self.copy();
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
            if (self.find_open) self.closeFind() else {
                self.sel_a = null;
                self.sel_b = null;
            }
        }
    }

    fn copy(self: *PdfDoc) void {
        const t = self.text orelse return;
        const a = self.sel_a orelse return;
        const b = self.sel_b orelse return;
        const s = pdftext.textOf(self.alloc, t, a, b) catch return;
        defer self.alloc.free(s);
        const z = self.alloc.dupeSentinel(u8, s, 0) catch return;
        defer self.alloc.free(z);
        c.igSetClipboardText(z.ptr);
    }

    /// posAt is the word under (or nearest) the screen point `m`, if the words are read.
    fn posAt(self: *PdfDoc, rects: []const Rect, ox: f32, oy: f32, m: c.ImVec2_c) ?pdftext.Pos {
        const t = self.text orelse return null;
        if (rects.len == 0) return null;
        // The page under the pointer, else the nearest one above or below it.
        var best: usize = 0;
        var best_d: f32 = std.math.floatMax(f32);
        for (rects, 0..) |r, i| {
            const x0 = ox + r.x;
            const y0 = oy + r.y;
            const dx = if (m.x < x0) x0 - m.x else if (m.x > x0 + r.w) m.x - x0 - r.w else 0;
            const dy = if (m.y < y0) y0 - m.y else if (m.y > y0 + r.h) m.y - y0 - r.h else 0;
            const d = dx + dy;
            if (d < best_d) {
                best_d = d;
                best = i;
            }
            if (d == 0) break;
        }
        if (best >= t.pages.len) return null;
        const r = rects[best];
        const dx = std.math.clamp((m.x - ox - r.x) / @max(r.w, 1), 0, 1);
        const dy = std.math.clamp((m.y - oy - r.y) / @max(r.h, 1), 0, 1);
        // Back from the turned view to the page's own.
        const f: [2]f32 = switch (self.rot) {
            0 => .{ dx, dy },
            1 => .{ dy, 1 - dx },
            2 => .{ 1 - dx, 1 - dy },
            3 => .{ 1 - dy, dx },
        };
        const w = pdftext.wordAt(t.pages[best], f[0], f[1]) orelse return null;
        return .{ .page = @intCast(best), .word = w };
    }

    // --- find --------------------------------------------------------------------------

    fn closeFind(self: *PdfDoc) void {
        self.find_open = false;
        self.alloc.free(self.hits);
        self.hits = &.{};
        @memset(&self.find_done, 0);
    }

    /// drawFind is the find bar, top right: the field, how many matches, previous and
    /// next (Enter, Shift+Enter), close (Escape).
    fn drawFind(self: *PdfDoc, wpos: c.ImVec2_c, wsize: c.ImVec2_c, rects: []const Rect) void {
        const lh = c.igGetTextLineHeight();
        const bh = c.igGetFrameHeight();
        const pad = lh * 0.4;
        // The field narrows to fit a narrow view (the sidebar open, a small window).
        const fw = std.math.clamp(wsize.x - lh * 9 - bh * 3, lh * 4, lh * 11);
        const w = fw + lh * 7 + bh * 3;
        const x = @max(wpos.x + wsize.x - w - lh, wpos.x + pad);
        const y = wpos.y + lh * 0.6;
        const dl = c.igGetWindowDrawList();
        const bg = if (theme.p().dark) @as(u32, 0xF0282828) else 0xF0F4F4F4;
        c.ImDrawList_AddRectFilled(dl, cimgui.vec2(x - pad, y - pad), cimgui.vec2(x + w + pad, y + bh + pad), bg, lh * 0.5, 0);
        c.igSetCursorScreenPos(cimgui.vec2(x, y));
        if (self.find_focus) {
            c.igSetKeyboardFocusHere(0);
            self.find_focus = false;
        }
        c.igSetNextItemWidth(fw);
        theme.pushFields();
        const enter = c.igInputTextWithHint("##pdffind", "Find in document", &self.find_buf, self.find_buf.len, c.ImGuiInputTextFlags_EnterReturnsTrue, null, null);
        theme.popFields();
        if (enter) self.find_focus = true; // (Enter leaves the field; it stays for the next)
        const q = std.mem.sliceTo(&self.find_buf, 0);
        // Search again when what's typed changes (or the words have come in).
        if (!std.mem.eql(u8, q, std.mem.sliceTo(&self.find_done, 0))) {
            self.alloc.free(self.hits);
            self.hits = &.{};
            self.hit = 0;
            if (self.text) |t| {
                self.hits = pdftext.findAll(self.alloc, t, q, true, 10000) catch &.{};
                @memset(&self.find_done, 0);
                @memcpy(self.find_done[0..q.len], q);
                // The first match at or after the page in view.
                for (self.hits, 0..) |h, i| if (h.page >= self.at_centre) {
                    self.hit = i;
                    break;
                };
                if (self.hits.len > 0) self.showHit(rects);
            }
        }
        var tb: [48]u8 = undefined;
        const status: [:0]const u8 = if (q.len == 0) "" else if (self.text_job != null) "Reading\u{2026}" else if (self.text_failed) "Can't read its text" else if (self.hits.len == 0) "Not found" else std.mem.printSentinel(&tb, "{d} of {d}", .{ self.hit + 1, self.hits.len }, 0) catch "";
        c.igSameLine(0, lh * 0.5);
        c.igAlignTextToFramePadding();
        c.igTextDisabled("%s", status.ptr);
        c.igSetCursorScreenPos(cimgui.vec2(x + w - bh * 3, y));
        const shift = c.igIsKeyDown_Nil(c.ImGuiMod_Shift);
        if (iconButton("##fprev", .up, bh, bh, false, "Previous (Shift+Enter)") or (enter and shift)) self.stepHit(rects, false);
        c.igSameLine(0, 0);
        if (iconButton("##fnext", .down, bh, bh, false, "Next (Enter)") or (enter and !shift)) self.stepHit(rects, true);
        c.igSameLine(0, 0);
        if (iconButton("##fclose", .close, bh, bh, false, "Close (Escape)")) self.closeFind();
    }

    fn stepHit(self: *PdfDoc, rects: []const Rect, next: bool) void {
        if (self.hits.len == 0) return;
        self.hit = if (next) (self.hit + 1) % self.hits.len else (self.hit + self.hits.len - 1) % self.hits.len;
        self.showHit(rects);
    }

    /// showHit scrolls the current match into view (a third of the way down).
    fn showHit(self: *PdfDoc, rects: []const Rect) void {
        const t = self.text orelse return;
        const h = self.hits[self.hit];
        if (h.page >= rects.len or h.page >= t.pages.len) return;
        const ws = pdftext.wordsOf(t.pages[h.page], h.start, h.end);
        if (ws.first >= ws.end) return;
        const w = t.pages[h.page].words[ws.first];
        const fy: f32 = switch (self.rot) {
            0 => w.y0,
            1 => w.x0,
            2 => 1 - w.y1,
            3 => 1 - w.x1,
        };
        self.goto = .{ .page = h.page, .frac = @max(fy, 0.0001) };
    }

    // --- toolbar -------------------------------------------------------------------

    /// drawToolbar is the reader's controls, at the bottom: the sidebar, zoom out, the
    /// zoom (back to the width), zoom in, fit the width, fit the page, two pages, the
    /// page (click to type one), find. Shown while the pointer moves over the
    /// document, then faded out; the page then shows alone while scrolling.
    fn drawToolbar(self: *PdfDoc, dl: *c.ImDrawList, wpos: c.ImVec2_c, wsize: c.ImVec2_c, in_view: bool, n: usize, fit_w: f32, gap: f32, rects: []const Rect) void {
        const lh = c.igGetTextLineHeight();
        const now = c.igGetTime();
        const bh = @round(lh * 1.8);
        const sep = lh * 0.5;
        var zb: [16]u8 = undefined;
        const ztxt = std.mem.printSentinel(&zb, "{d}%", .{@as(u32, @intFromFloat(@round(self.zoom * 100)))}, 0) catch "";
        var pb: [32]u8 = undefined;
        const ptxt = std.mem.printSentinel(&pb, "{d} of {d}", .{ self.at_centre + 1, n }, 0) catch "";
        const zw = c.igCalcTextSize("400%", null, false, -1).x + lh;
        const pw = c.igCalcTextSize(ptxt.ptr, null, false, -1).x + lh;
        const w = bh * 7 + zw + pw + sep * 4 + lh;
        const x0 = wpos.x + (wsize.x - w) * 0.5;
        const y0 = wpos.y + wsize.y - bh - lh * 0.8;
        const m = c.igGetMousePos();
        const over = m.x >= x0 and m.x <= x0 + w and m.y >= y0 - lh and m.y <= y0 + bh + lh;
        const recent = in_view and now - self.moved < 2.0;
        if (recent) _ = anim.cycle(1); // (frames until it's time to fade)
        const vis = anim.toward(c.igGetID_Str("##pdftools"), recent or over or self.page_edit, anim.normal);
        const bg_dark = theme.p().dark;
        if (vis < 0.02) {
            // Faded: the page alone, while scrolling.
            const pv = anim.toward(c.igGetID_Str("##pdfpage"), now - self.touched < 1.2 and n > 1, anim.normal);
            if (pv > 0.02) {
                const ts = c.igCalcTextSize(ptxt.ptr, null, false, -1);
                const pad = lh * 0.4;
                const cx = wpos.x + wsize.x * 0.5;
                const by = wpos.y + wsize.y - ts.y - pad * 2 - lh * 0.6;
                c.ImDrawList_AddRectFilled(dl, cimgui.vec2(cx - ts.x * 0.5 - pad * 2, by), cimgui.vec2(cx + ts.x * 0.5 + pad * 2, by + ts.y + pad * 2), alpha(if (bg_dark) 0xD0303030 else 0xD0F0F0F0, pv), ts.y, 0);
                const tc = theme.text();
                c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(cx - ts.x * 0.5, by + pad), c.igGetColorU32_Vec4(cimgui.vec4(tc.x, tc.y, tc.z, pv)), ptxt.ptr, ptxt.ptr + ptxt.len);
            }
            return;
        }
        c.igPushStyleVar_Float(c.ImGuiStyleVar_Alpha, vis);
        defer c.igPopStyleVar(1);
        c.ImDrawList_AddRectFilled(dl, cimgui.vec2(x0, y0), cimgui.vec2(x0 + w, y0 + bh), alpha(if (bg_dark) 0xE8303030 else 0xE8F2F2F2, vis), bh * 0.5, 0);
        var x = x0 + lh * 0.5;
        c.igSetCursorScreenPos(cimgui.vec2(x, y0));
        if (iconButton("##pside", .sidebar, bh, bh, self.side != .none, "Sidebar")) {
            self.side = if (self.side == .none) .thumbs else .none;
            sidebar_shown = self.side != .none; // (the next PDF opens the same way)
        }
        x += bh + sep;
        c.igSetCursorScreenPos(cimgui.vec2(x, y0));
        const cx = wsize.x * 0.5;
        const cy = wsize.y * 0.5;
        if (iconButton("##pzout", .minus, bh, bh, false, "Zoom Out (Ctrl+scroll)")) self.zoomBy(0.8, cx, cy);
        c.igSameLine(0, 0);
        if (textButton("##pzoom", ztxt, zw, bh, "Actual Size")) self.zoomBy(1 / self.zoom, cx, cy);
        c.igSameLine(0, 0);
        if (iconButton("##pzin", .plus, bh, bh, false, "Zoom In (Ctrl+scroll)")) self.zoomBy(1.25, cx, cy);
        x += bh * 2 + zw + sep;
        c.igSetCursorScreenPos(cimgui.vec2(x, y0));
        if (iconButton("##pfitw", .fit_width, bh, bh, false, "Fit Width")) {
            self.refit = true;
            self.goto = .{ .page = self.at_centre };
        }
        c.igSameLine(0, 0);
        if (iconButton("##pfitp", .fit_page, bh, bh, false, "Fit Page")) self.fitPage(rects, wsize.y, fit_w, gap);
        c.igSameLine(0, 0);
        if (iconButton("##pspread", .spread, bh, bh, self.spread, "Two Pages")) {
            self.spread = !self.spread;
            self.refit = true; // (one column or two: fitted to the width again)
            self.goto = .{ .page = self.at_centre };
        }
        x += bh * 3 + sep;
        c.igSetCursorScreenPos(cimgui.vec2(x, y0));
        if (self.page_edit) {
            // Type a page, Enter goes there.
            c.igSetCursorScreenPos(cimgui.vec2(x, y0 + (bh - c.igGetFrameHeight()) * 0.5));
            c.igSetNextItemWidth(pw);
            c.igSetKeyboardFocusHere(0);
            if (c.igInputText("##ppage", &self.page_buf, self.page_buf.len, c.ImGuiInputTextFlags_CharsDecimal | c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_AutoSelectAll, null, null)) {
                const v = std.fmt.parseInt(u32, std.mem.sliceTo(&self.page_buf, 0), 10) catch 0;
                if (v >= 1 and v <= n) self.goto = .{ .page = v - 1 };
                self.page_edit = false;
            } else if (c.igIsItemDeactivated()) self.page_edit = false;
        } else if (textButton("##ppagebtn", ptxt, pw, bh, "Go to Page\u{2026}")) {
            self.page_edit = true;
            @memset(&self.page_buf, 0);
            _ = std.fmt.bufPrint(&self.page_buf, "{d}", .{self.at_centre + 1}) catch {};
        }
        x += pw + sep;
        c.igSetCursorScreenPos(cimgui.vec2(x, y0));
        if (iconButton("##pfind", .find, bh, bh, self.find_open, "Find (Ctrl+F)")) {
            if (self.find_open) self.closeFind() else {
                self.find_open = true;
                self.find_focus = true;
                self.needText();
            }
        }
    }

    /// fitPage zooms so the page in view fits the window whole.
    fn fitPage(self: *PdfDoc, rects: []const Rect, view_h: f32, fit_w: f32, gap: f32) void {
        if (self.at_centre >= rects.len) return;
        const r = rects[self.at_centre];
        const col = if (self.spread) (fit_w - gap) * 0.5 else fit_w;
        const k = @min(col / @max(r.w, 1), (view_h - gap * 2) / @max(r.h, 1));
        self.zoom = std.math.clamp(self.zoom * k, zoom_min, zoom_max);
        self.goto = .{ .page = self.at_centre, .centre = true }; // (the page in the middle of the view)
    }

    // --- sidebar -------------------------------------------------------------------

    /// drawSide is the sidebar: the pages' thumbnails (click one to go there), or the
    /// table of contents when the PDF has one.
    fn drawSide(self: *PdfDoc, size: c.ImVec2_c) void {
        _ = c.igBeginChild_Str("##pdfside", size, 0, 0);
        defer c.igEndChild();
        const lh = c.igGetTextLineHeight();
        if (self.toc.len > 0) {
            const half = (c.igGetContentRegionAvail().x - lh * 0.2) * 0.5;
            if (tabButton("Pages", self.side == .thumbs, half)) self.side = .thumbs;
            c.igSameLine(0, lh * 0.2);
            if (tabButton("Contents", self.side == .contents, half)) self.side = .contents;
            c.igSpacing();
        } else self.side = .thumbs;
        if (self.side == .contents) return self.drawContents();
        self.thumb_need = null;
        const avail = c.igGetContentRegionAvail();
        const tw = @max(avail.x - lh * 1.2, 20);
        const x = c.igGetCursorScreenPos().x + (avail.x - tw) * 0.5;
        const dl = c.igGetWindowDrawList();
        const scale = fbScale();
        const turned = self.rot % 2 == 1;
        const want: u32 = @intFromFloat(std.math.clamp(@ceil(tw * scale / 64) * 64, 96, 448));
        var first: ?usize = null;
        var last: usize = 0;
        const follow = self.at_centre;
        for (self.page_size, 0..) |ps, i| {
            const th = if (turned) tw * ps[0] / @max(ps[1], 1) else tw * ps[1] / @max(ps[0], 1);
            const p0 = c.igGetCursorScreenPos();
            const mn = cimgui.vec2(x, p0.y);
            const mx = cimgui.vec2(x + tw, p0.y + th);
            c.igPushID_Int(@intCast(i));
            c.igSetCursorScreenPos(mn);
            if (c.igInvisibleButton("##t", cimgui.vec2(tw, th + lh * 1.3), 0)) self.goto = .{ .page = @intCast(i) };
            c.igPopID();
            if (c.igIsItemVisible()) {
                if (first == null) first = i;
                last = i;
                c.ImDrawList_AddRectFilled(dl, mn, mx, 0xFFFFFFFF, 0, 0);
                const t = self.thumbs[i];
                if (t.tex != 0) quad(dl, t.tex, mn, mx, self.rot) else if (self.thumb_need == null and t.tried != want) {
                    self.thumb_need = .{ .page = @intCast(i), .width = want, .thumb = true };
                }
                if (i == follow) c.ImDrawList_AddRect(dl, cimgui.vec2(mn.x - 3, mn.y - 3), cimgui.vec2(mx.x + 3, mx.y + 3), c.igGetColorU32_Vec4(theme.p().accent), 3, 2.5, 0);
                var nb: [16]u8 = undefined;
                const num = std.fmt.bufPrint(&nb, "{d}", .{i + 1}) catch "";
                const nw = c.igCalcTextSize(num.ptr, num.ptr + num.len, false, -1).x;
                c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(x + (tw - nw) * 0.5, mx.y + lh * 0.15), c.igGetColorU32_Vec4(theme.dim()), num.ptr, num.ptr + num.len);
            }
            c.igSetCursorScreenPos(cimgui.vec2(p0.x, p0.y + th + lh * 1.8));
            if (i == follow and self.side_follow != follow) {
                // The page in view changed: its thumbnail comes into view.
                if (!c.igIsItemVisible()) c.igSetScrollHereY(0.5);
            }
        }
        self.side_follow = follow;
        c.igDummy(cimgui.vec2(0, 0));
        // Thumbnails far out of view give their pictures back.
        if (first) |f| for (self.thumbs, 0..) |*t, k| {
            if (t.tex != 0 and (k + 12 < f or k > last + 12)) {
                zfd_texture_free(t.tex);
                t.* = .{};
            }
            if (t.tex == 0 and t.tried != 0 and t.tried != want) t.tried = 0; // (a new size: ask again)
        };
    }

    fn drawContents(self: *PdfDoc) void {
        const lh = c.igGetTextLineHeight();
        // The entry for the page in view: the last one starting at or before it.
        var cur: ?usize = null;
        for (self.toc, 0..) |e, i| if (e.page <= self.at_centre) {
            cur = i;
        };
        for (self.toc, 0..) |e, i| {
            var tb: [256]u8 = undefined;
            const title = std.mem.printSentinel(&tb, "{s}", .{e.title[0..@min(e.title.len, 250)]}, 0) catch continue;
            c.igPushID_Int(@intCast(i));
            c.igSetCursorPosX(c.igGetCursorPosX() + @as(f32, @floatFromInt(e.depth)) * lh * 0.8);
            if (c.igSelectable_Bool(title.ptr, cur == i, 0, cimgui.vec2(0, 0))) self.goto = .{ .page = e.page };
            if (c.igIsItemHovered(0)) c.igSetTooltip("Page %d", @as(c_int, @intCast(e.page + 1)));
            c.igPopID();
        }
    }

    // --- scrollbars ----------------------------------------------------------------

    /// drawScrollbar draws macOS's overlay scrollbars: thin over the pages' edge,
    /// shown while scrolling or with the pointer near them, then faded away; wider
    /// under the pointer, and dragged to scroll (a click beside the thumb jumps).
    fn drawScrollbar(self: *PdfDoc, dl: *c.ImDrawList, wpos: c.ImVec2_c, wsize: c.ImVec2_c, m: c.ImVec2_c, in_view: bool) void {
        const max_y = c.igGetScrollMaxY();
        const max_x = c.igGetScrollMaxX();
        const now = c.igGetTime();
        const near_v = in_view and m.x >= wpos.x + wsize.x - bar_zone;
        const near_h = in_view and m.y >= wpos.y + wsize.y - bar_zone;
        const recent = now - self.touched < 1.0;
        if (recent) _ = anim.cycle(1); // (frames until it's time to fade)
        const col = theme.text();
        if (max_y > 0) {
            const shown = anim.toward(c.igGetID_Str("##pdfbar_v"), recent or near_v or self.bar_drag, anim.normal);
            const track_top = wpos.y + 4;
            const track_len = wsize.y - 8 - (if (max_x > 0) bar_zone else 0);
            const view = wsize.y;
            const thumb = @min(@max(track_len * view / (view + max_y), c.igGetTextLineHeight() * 2.5), track_len); // (never too small to grab)
            const room = @max(track_len - thumb, 1);
            if (self.bar_drag) {
                if (self.bar_grab == null) {
                    const cur = track_top + room * c.igGetScrollY() / max_y;
                    // On the thumb: grab it there; beside it: jump so it's centred on the pointer.
                    self.bar_grab = if (m.y >= cur and m.y <= cur + thumb) m.y - cur else thumb * 0.5;
                }
                const pos = std.math.clamp(m.y - self.bar_grab.? - track_top, 0, room);
                self.glide_to = null;
                c.igSetScrollY_Float(pos / room * max_y);
                self.touched = now;
            } else self.bar_grab = null;
            if (shown > 0.01) {
                const wide = anim.toward(c.igGetID_Str("##pdfbar_vw"), near_v or self.bar_drag, anim.quick);
                const w = 6 + 4 * wide;
                const top = track_top + room * c.igGetScrollY() / max_y;
                const x1 = wpos.x + wsize.x - 3;
                c.ImDrawList_AddRectFilled(dl, cimgui.vec2(x1 - w, top), cimgui.vec2(x1, top + thumb), c.igGetColorU32_Vec4(cimgui.vec4(col.x, col.y, col.z, 0.45 * shown)), w * 0.5, 0);
            }
        }
        if (max_x > 0) {
            const shown = anim.toward(c.igGetID_Str("##pdfbar_h"), recent or near_h, anim.normal);
            if (shown > 0.01) {
                const track_l = wpos.x + 4;
                const track_len = wsize.x - 8 - (if (max_y > 0) bar_zone else 0);
                const thumb = @min(@max(track_len * wsize.x / (wsize.x + max_x), c.igGetTextLineHeight() * 2.5), track_len);
                const left = track_l + (track_len - thumb) * c.igGetScrollX() / max_x;
                const y1 = wpos.y + wsize.y - 3;
                c.ImDrawList_AddRectFilled(dl, cimgui.vec2(left, y1 - 6), cimgui.vec2(left + thumb, y1), c.igGetColorU32_Vec4(cimgui.vec4(col.x, col.y, col.z, 0.45 * shown)), 3, 0);
            }
        }
    }
};

// --- drawing helpers -----------------------------------------------------------------

/// quad draws a page's picture in mn..mx, turned `rot` quarter turns clockwise.
fn quad(dl: *c.ImDrawList, tex: c_uint, mn: c.ImVec2_c, mx: c.ImVec2_c, rot: u2) void {
    const ref: c.ImTextureRef_c = .{ ._TexData = null, ._TexID = tex };
    const uv = [4]c.ImVec2_c{ cimgui.vec2(0, 0), cimgui.vec2(1, 0), cimgui.vec2(1, 1), cimgui.vec2(0, 1) };
    const r: usize = rot;
    c.ImDrawList_AddImageQuad(dl, ref, mn, cimgui.vec2(mx.x, mn.y), mx, cimgui.vec2(mn.x, mx.y), uv[(4 - r) % 4], uv[(5 - r) % 4], uv[(6 - r) % 4], uv[(7 - r) % 4], 0xFFFFFFFF);
}

/// markWord fills a word's box (page fractions, upright) on the page drawn in mn..mx.
fn markWord(dl: *c.ImDrawList, w: pdftext.Word, mn: c.ImVec2_c, mx: c.ImVec2_c, rot: u2, col: u32) void {
    const a = turnPoint(w.x0, w.y0, rot);
    const b = turnPoint(w.x1, w.y1, rot);
    const pw = mx.x - mn.x;
    const ph = mx.y - mn.y;
    const x0 = mn.x + @min(a[0], b[0]) * pw;
    const x1 = mn.x + @max(a[0], b[0]) * pw;
    const y0 = mn.y + @min(a[1], b[1]) * ph;
    const y1 = mn.y + @max(a[1], b[1]) * ph;
    c.ImDrawList_AddRectFilled(dl, cimgui.vec2(x0 - 1, y0 - 1), cimgui.vec2(x1 + 1, y1 + 1), col, 2, 0);
}

/// turnPoint is where a point of the upright page (fractions) shows on the turned one.
fn turnPoint(fx: f32, fy: f32, rot: u2) [2]f32 {
    return switch (rot) {
        0 => .{ fx, fy },
        1 => .{ 1 - fy, fx },
        2 => .{ 1 - fx, 1 - fy },
        3 => .{ fy, 1 - fx },
    };
}

fn alpha(col: u32, k: f32) u32 {
    const a: f32 = @floatFromInt(col >> 24);
    return (col & 0x00FFFFFF) | (@as(u32, @intFromFloat(a * std.math.clamp(k, 0, 1))) << 24);
}

const Glyph = enum { sidebar, minus, plus, fit_width, fit_page, spread, find, up, down, close };

/// iconButton is a flat button `w`×`h` with a line-drawn glyph (no font glyphs: the
/// blocky font has few), lit when `on`.
fn iconButton(id: [*:0]const u8, g: Glyph, w: f32, h: f32, on: bool, tip: [*:0]const u8) bool {
    const p = c.igGetCursorScreenPos();
    const hit = c.igInvisibleButton(id, cimgui.vec2(w, h), 0);
    const hov = c.igIsItemHovered(0);
    const dl = c.igGetWindowDrawList();
    const a = c.igGetStyle().*.Alpha;
    const tc = theme.text();
    if (hov or on) {
        const k: f32 = if (on) 0.16 else 0.09;
        c.ImDrawList_AddRectFilled(dl, cimgui.vec2(p.x + 2, p.y + 2), cimgui.vec2(p.x + w - 2, p.y + h - 2), c.igGetColorU32_Vec4(cimgui.vec4(tc.x, tc.y, tc.z, k * a)), h * 0.3, 0);
    }
    if (hov) c.igSetTooltip("%s", tip);
    const col = c.igGetColorU32_Vec4(if (on) blk: {
        const ac = theme.p().accent;
        break :blk cimgui.vec4(ac.x, ac.y, ac.z, a);
    } else cimgui.vec4(tc.x, tc.y, tc.z, 0.85 * a));
    const s = h * 0.22; // half the glyph's size
    const cx = p.x + w * 0.5;
    const cy = p.y + h * 0.5;
    const t: f32 = @max(1.5, h * 0.055);
    switch (g) {
        .sidebar => {
            c.ImDrawList_AddRect(dl, cimgui.vec2(cx - s * 1.2, cy - s), cimgui.vec2(cx + s * 1.2, cy + s), col, 2, t, 0);
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx - s * 0.35, cy - s), cimgui.vec2(cx - s * 0.35, cy + s), col, t);
        },
        .minus => c.ImDrawList_AddLine(dl, cimgui.vec2(cx - s, cy), cimgui.vec2(cx + s, cy), col, t),
        .plus => {
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx - s, cy), cimgui.vec2(cx + s, cy), col, t);
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx, cy - s), cimgui.vec2(cx, cy + s), col, t);
        },
        .fit_width => {
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx - s * 1.2, cy - s), cimgui.vec2(cx - s * 1.2, cy + s), col, t);
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx + s * 1.2, cy - s), cimgui.vec2(cx + s * 1.2, cy + s), col, t);
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx - s * 0.8, cy), cimgui.vec2(cx + s * 0.8, cy), col, t);
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx - s * 0.8, cy), cimgui.vec2(cx - s * 0.4, cy - s * 0.4), col, t);
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx - s * 0.8, cy), cimgui.vec2(cx - s * 0.4, cy + s * 0.4), col, t);
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx + s * 0.8, cy), cimgui.vec2(cx + s * 0.4, cy - s * 0.4), col, t);
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx + s * 0.8, cy), cimgui.vec2(cx + s * 0.4, cy + s * 0.4), col, t);
        },
        .fit_page => c.ImDrawList_AddRect(dl, cimgui.vec2(cx - s * 0.75, cy - s), cimgui.vec2(cx + s * 0.75, cy + s), col, 1.5, t, 0),
        .spread => {
            c.ImDrawList_AddRect(dl, cimgui.vec2(cx - s * 1.3, cy - s * 0.9), cimgui.vec2(cx - s * 0.1, cy + s * 0.9), col, 1.5, t, 0);
            c.ImDrawList_AddRect(dl, cimgui.vec2(cx + s * 0.1, cy - s * 0.9), cimgui.vec2(cx + s * 1.3, cy + s * 0.9), col, 1.5, t, 0);
        },
        .find => {
            c.ImDrawList_AddCircle(dl, cimgui.vec2(cx - s * 0.25, cy - s * 0.25), s * 0.7, col, 16, t);
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx + s * 0.25, cy + s * 0.25), cimgui.vec2(cx + s, cy + s), col, t * 1.2);
        },
        .up, .down => {
            const d: f32 = if (g == .up) -1 else 1;
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx - s * 0.8, cy - d * s * 0.4), cimgui.vec2(cx, cy + d * s * 0.4), col, t);
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx, cy + d * s * 0.4), cimgui.vec2(cx + s * 0.8, cy - d * s * 0.4), col, t);
        },
        .close => {
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx - s * 0.7, cy - s * 0.7), cimgui.vec2(cx + s * 0.7, cy + s * 0.7), col, t);
            c.ImDrawList_AddLine(dl, cimgui.vec2(cx + s * 0.7, cy - s * 0.7), cimgui.vec2(cx - s * 0.7, cy + s * 0.7), col, t);
        },
    }
    return hit;
}

/// textButton is a flat button showing `label`, centred.
fn textButton(id: [*:0]const u8, label: [:0]const u8, w: f32, h: f32, tip: [*:0]const u8) bool {
    const p = c.igGetCursorScreenPos();
    const hit = c.igInvisibleButton(id, cimgui.vec2(w, h), 0);
    const dl = c.igGetWindowDrawList();
    const a = c.igGetStyle().*.Alpha;
    const tc = theme.text();
    if (c.igIsItemHovered(0)) {
        c.ImDrawList_AddRectFilled(dl, cimgui.vec2(p.x + 2, p.y + 2), cimgui.vec2(p.x + w - 2, p.y + h - 2), c.igGetColorU32_Vec4(cimgui.vec4(tc.x, tc.y, tc.z, 0.09 * a)), h * 0.3, 0);
        c.igSetTooltip("%s", tip);
    }
    const ts = c.igCalcTextSize(label.ptr, null, false, -1);
    c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(p.x + (w - ts.x) * 0.5, p.y + (h - ts.y) * 0.5), c.igGetColorU32_Vec4(cimgui.vec4(tc.x, tc.y, tc.z, a)), label.ptr, label.ptr + label.len);
    return hit;
}

/// tabButton is one of the sidebar's two tabs.
fn tabButton(label: [*:0]const u8, on: bool, w: f32) bool {
    if (on) {
        const ac = theme.p().accent;
        c.igPushStyleColor_Vec4(c.ImGuiCol_Button, cimgui.vec4(ac.x, ac.y, ac.z, 0.25));
    }
    const hit = c.igButton(label, cimgui.vec2(w, 0));
    if (on) c.igPopStyleColor(1);
    return hit;
}

fn fbScale() f32 {
    const vp = c.igGetWindowViewport();
    const s = vp.*.FramebufferScale.x;
    return if (s > 0.5) s else 1;
}

/// readInfo asks pdfinfo for every page's size (points, as the page shows: turned
/// pages swap). Null when it can't be read.
fn readInfo(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?[][2]f32 {
    const out = ql.runCapture(io, alloc, &.{ "pdfinfo", "-f", "1", "-l", "100000", path }, 16 << 20) orelse return null;
    defer alloc.free(out);
    return parseInfo(alloc, out);
}

fn parseInfo(alloc: std.mem.Allocator, out: []const u8) ?[][2]f32 {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |l| if (std.mem.startsWith(u8, l, "Pages:")) {
        n = std.fmt.parseInt(usize, std.mem.trim(u8, l[6..], " \t\r"), 10) catch 0;
    };
    if (n == 0) return null;
    n = @min(n, max_pages);
    const sizes = alloc.alloc([2]f32, n) catch return null;
    @memset(sizes, .{ 612, 792 });
    lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, "Page ")) continue;
        var it = std.mem.tokenizeAny(u8, l[5..], " \t\r");
        const num = std.fmt.parseInt(usize, it.next() orelse continue, 10) catch continue;
        if (num == 0 or num > n) continue;
        const what = it.next() orelse continue;
        if (std.mem.eql(u8, what, "size:")) {
            const w = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            _ = it.next(); // "x"
            const h = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
            if (w > 0 and h > 0) sizes[num - 1] = .{ w, h };
        } else if (std.mem.eql(u8, what, "rot:")) {
            const rot = std.fmt.parseInt(i32, it.next() orelse continue, 10) catch continue;
            if (@mod(rot, 180) == 90) std.mem.swap(f32, &sizes[num - 1][0], &sizes[num - 1][1]);
        }
    }
    return sizes;
}

test "parseInfo reads the pages' sizes, turned ones swapped" {
    const out =
        \\Title:          x
        \\Pages:          3
        \\Page    1 size: 595.276 x 841.89 pts (A4)
        \\Page    1 rot:  0
        \\Page    2 size: 612 x 792 pts (letter)
        \\Page    2 rot:  90
        \\Page    3 size: 100 x 50 pts
        \\Page    3 rot:  0
    ;
    const s = parseInfo(std.testing.allocator, out).?;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectApproxEqAbs(@as(f32, 841.89), s[0][1], 0.01);
    try std.testing.expectEqual(@as(f32, 792), s[1][0]); // turned
    try std.testing.expectEqual(@as(f32, 100), s[2][0]);
}
