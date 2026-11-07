//! Treemap representation of a Browser: a WinDirStat-like disk-usage view. It is a
//! *representation of the same data* as the file table: it draws the browser's VIEW
//! entries (so it respects the hidden/search filter), sizes them by their recursive
//! total (streamed from core/usage.zig), and shares the browser's selection: click
//! a tile and the corresponding row selects too. Double-click a folder to drill in.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const c = cimgui.c;
const core = @import("core");
const scan = core.scan;
const actions = @import("actions.zig");

const Browser = core.browser.Browser;

const max_cells = 512;

/// draw renders the treemap into the current region (a bottom pane), streaming in
/// with a progress bar while core/usage.zig computes sizes. `act` is the shared
/// ViewActions, so tiles raise the exact same right-click menu as the file list.
pub fn draw(b: *Browser, act: *actions.ViewActions) void {
    b.ensureUsage();

    if (b.usageScanning()) {
        const prog = b.usageProgress();
        const frac = @as(f32, @floatFromInt(prog.done)) / @as(f32, @floatFromInt(@max(prog.total, 1)));
        var lbuf: [64]u8 = undefined;
        const overlay = std.mem.printSentinel(&lbuf, "Scanning {d}/{d}", .{ prog.done, prog.total }, 0) catch "";
        // Progress bar with a Cancel button right next to it (leave room on the right).
        const btn_w: f32 = 80;
        const sp = c.igGetStyle().*.ItemSpacing.x;
        c.igProgressBar(frac, cimgui.vec2(-(btn_w + sp), 0), overlay.ptr);
        c.igSameLine(0, -1);
        if (c.igButton("Cancel##usage", cimgui.vec2(btn_w, 0))) b.cancelUsage();
    }

    const n = @min(b.count(), max_cells);
    if (n == 0) {
        cimgui.textUnformatted("Computing disk usage...");
        return;
    }

    // Sizes come from usage (recursive, by name); we lay out the browser's VIEW rows
    // so the treemap and the table are the same data, filtered the same way.
    var sizes: [max_cells]u64 = undefined;
    var order: [max_cells]usize = undefined;
    for (0..n) |i| {
        sizes[i] = b.usageSizeOf(b.at(i).name);
        order[i] = i;
    }
    std.mem.sort(usize, order[0..n], sizes[0..n], sizeDesc);

    var total: u64 = 0;
    for (sizes[0..n]) |sz| total += sz;
    if (total == 0) total = 1;

    const origin = c.igGetCursorScreenPos();
    const avail = c.igGetContentRegionAvail();
    var rects: [max_cells]Rect = undefined;
    layout(sizes[0..n], order[0..n], rects[0..n], 0, 0, avail.x, avail.y, total, true);

    const dl = c.igGetWindowDrawList();
    for (order[0..n], 0..) |vi, k| {
        const e = b.at(vi);
        const r = rects[k];
        if (r.w < 1 or r.h < 1) continue;
        const p_min = cimgui.vec2(origin.x + r.x, origin.y + r.y);
        const p_max = cimgui.vec2(origin.x + r.x + r.w, origin.y + r.y + r.h);

        c.igSetCursorScreenPos(p_min);
        var id_buf: [24]u8 = undefined;
        const id = std.mem.printSentinel(&id_buf, "##tm{d}", .{k}, 0) catch continue;
        _ = c.igInvisibleButton(id.ptr, cimgui.vec2(r.w, r.h), 0);
        const hovered = c.igIsItemHovered(0);
        if (hovered and c.igIsMouseClicked_Bool(0, false)) {
            b.sel.click(vi); // shared selection…
            b.sel.requestReveal(); // …and scroll the file list to it
        }
        if (hovered and c.igIsMouseDoubleClicked_Nil(0)) b.open(e) catch {};
        // Right-click a tile → the SAME context menu as the file list (selecting the
        // tile first if it isn't already), since both views drive one model.
        if (c.igBeginPopupContextItem(null, c.ImGuiPopupFlags_MouseButtonRight)) {
            if (!b.sel.isSelected(vi)) b.sel.click(vi);
            act.rowMenu(b, vi);
            c.igEndPopup();
        }

        const selected = b.sel.isSelected(vi);
        const col = c.igColorConvertFloat4ToU32(tileColor(e.name, selected, hovered));
        c.ImDrawList_AddRectFilled(dl, p_min, p_max, col, 0, 0);
        const bcol: c.ImU32 = if (selected) 0xFFFFFFFF else border_col;
        const bthick: f32 = if (selected) 2.0 else 1.0;
        c.ImDrawList_AddRect(dl, p_min, p_max, bcol, 0, bthick, 0);

        if (r.w > 42 and r.h > 16) {
            var lbl: [320]u8 = undefined;
            var szb: [32]u8 = undefined;
            const label = std.mem.print(&lbl, "{s} ({s})", .{ e.name, scan.humanizeSize(&szb, sizes[vi]) }) catch e.name;
            c.ImDrawList_AddText_Vec2(dl, cimgui.vec2(p_min.x + 4, p_min.y + 3), text_col, label.ptr, label.ptr + label.len);
        }
    }
}

const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
const border_col: c.ImU32 = 0xFF1A1A1A;
const text_col: c.ImU32 = 0xFF101010; // dark text; tiles are light

fn sizeDesc(sizes: []const u64, a: usize, b: usize) bool {
    return sizes[a] > sizes[b];
}

/// layout recursively splits the rect among the (size-desc-sorted) `order` entries,
/// alternating axis so tiles stay square-ish. `sizes` is indexed by view row.
fn layout(sizes: []const u64, order: []const usize, rects: []Rect, x: f32, y: f32, w: f32, h: f32, total: u64, horizontal: bool) void {
    if (order.len == 0) return;
    if (order.len == 1) {
        rects[0] = .{ .x = x, .y = y, .w = w, .h = h };
        return;
    }
    const half = total / 2;
    var acc: u64 = 0;
    var split: usize = 0;
    while (split < order.len) : (split += 1) {
        acc += sizes[order[split]];
        if (acc >= half) {
            split += 1;
            break;
        }
    }
    if (split == 0) split = 1;
    if (split >= order.len) split = order.len - 1;

    var first: u64 = 0;
    for (order[0..split]) |i| first += sizes[i];
    const second = total - first;
    const frac: f32 = if (total == 0) 0.5 else @as(f32, @floatFromInt(first)) / @as(f32, @floatFromInt(total));

    if (horizontal) {
        const w1 = w * frac;
        layout(sizes, order[0..split], rects[0..split], x, y, w1, h, first, false);
        layout(sizes, order[split..], rects[split..], x + w1, y, w - w1, h, second, false);
    } else {
        const h1 = h * frac;
        layout(sizes, order[0..split], rects[0..split], x, y, w, h1, first, true);
        layout(sizes, order[split..], rects[split..], x, y + h1, w, h - h1, second, true);
    }
}

/// tileColor spreads tiles across the full hue wheel (by name hash) so adjacent
/// blocks are easy to tell apart; selected/hovered tiles brighten.
fn tileColor(name: []const u8, selected: bool, hovered: bool) c.ImVec4_c {
    var hsh: u32 = 2166136261;
    for (name) |ch| hsh = (hsh ^ ch) *% 16777619;
    const hue = @as(f32, @floatFromInt(hsh % 360)) / 360.0;
    const val: f32 = if (selected) 0.97 else if (hovered) 0.88 else 0.74;
    var r: f32 = 0;
    var g: f32 = 0;
    var bl: f32 = 0;
    c.igColorConvertHSVtoRGB(hue, 0.5, val, &r, &g, &bl);
    return cimgui.vec4(r, g, bl, 1.0);
}
