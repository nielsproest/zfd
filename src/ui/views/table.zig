//! Table representation of a Browser: a sortable Name/Size/Date grid with
//! click/Ctrl/Shift selection, Up/Down/Enter/Backspace navigation, clipboard
//! shortcuts (Ctrl+C/X/V), Delete-to-trash, and F2 inline rename. One of several
//! content views over the same browser model (see ../shell.zig); a treemap and
//! icon grid are future siblings. Disk work is off-thread (Scanner/OpRunner); this
//! only reads state and calls model methods. Keep drawn strings ASCII.

const std = @import("std");
const cimgui = @import("../cimgui.zig");
const c = cimgui.c;
const theme = @import("../theme.zig");
const core = @import("core");
const scan = core.scan;
const actions = @import("actions.zig");
const icons = @import("icons.zig");
const anim = @import("../anim.zig");
const pdfview = @import("../pdfview.zig");

const Browser = core.browser.Browser;
const ViewActions = actions.ViewActions;

// Dummy payload byte for internal drag-and-drop; the real dragged set is the
// snapshot the Browser takes at drag start (b.beginDrag / b.dragPaths). Passing
// pointers through ImGui's memcpy'd payload would be unsafe, and the *selection*
// can't be read at drop time either: it is indexed by view row, and a rescan
// landing mid-drag re-indexes the view under us.
pub const DRAG_PAYLOAD = "ZFD_ROWS"; // data = the source Browser's address (ViewActions.dragPayload)

pub const TableView = struct {
    renaming: ?usize = null, // view row currently being renamed
    rename_buf: [600]u8 = @splat(0),
    rename_focus: bool = false, // grab keyboard focus for the rename field next frame
    rename_select: bool = false, // select the core name (stem) on the field's next frame
    ta_buf: [64]u8 = undefined, // type-ahead-find accumulated prefix
    ta_len: usize = 0,
    ta_time: f64 = 0, // last type-ahead keystroke time (igGetTime); reset after idle
    marquee_active: bool = false, // rubber-band drag in progress
    marquee_pending: bool = false, // pressed on no item: a rubber band once it's dragged
    marquee_add: bool = false, // Ctrl/Shift held at marquee start: add to the selection
    marquee_start: c.ImVec2_c = .{ .x = 0, .y = 0 }, // marquee anchor (screen)
    list_min: c.ImVec2_c = .{ .x = 0, .y = 0 }, // the list's screen rect, for its drop target
    list_max: c.ImVec2_c = .{ .x = 0, .y = 0 },
    sort_synced: usize = 0, // browser whose sort order the header was last set from
    sort_shown: scan.SortOrder = .{}, // the order the header shows (resync when the model moves)
    rename_width: f32 = -1, // inline rename field width (-1 = fill; the icon grid narrows it to a cell)

    /// draw renders the content region. `keyboard` is false when the path bar owns
    /// the keyboard; we also suppress navigation/op keys while renaming.
    /// `list_height` is the table's outer height (0 = fill; negative = fill minus
    /// that many pixels, to leave room for a dialog footer).
    pub fn draw(self: *TableView, b: *Browser, act: *ViewActions, keyboard: bool, list_height: f32) void {
        // A freshly-created New Folder/File (or a menu Rename): jump to it and start
        // renaming immediately.
        if (b.takeWantRename() and b.count() > 0) self.beginRename(b, b.sel.cursor);
        // Suppress list keyboard handling (esp. the type-ahead, which reads the input
        // queue directly) while a popup/modal is open, else typing in the Open-with
        // search would also drive the file list underneath.
        const popup_open = c.igIsPopupOpen_Str(null, c.ImGuiPopupFlags_AnyPopup);
        if (keyboard and !popup_open and self.renaming == null) {
            _ = handleNav(b, act); // moveCursor sets sel.reveal
            _ = self.typeAhead(b); // requests reveal on a match
            self.handleOpKeys(b, act);
        }
        // The scroll-to-reveal signal lives on the shared Selection, so ANY view
        // (keyboard nav, type-ahead, the treemap) can move the cursor and the file
        // list follows; not a table-local flag.
        self.drawTable(b, act, b.sel.takeReveal(), list_height);
        self.listDropTarget(b, act);
    }

    /// typeAhead jumps the cursor to the next entry matching the letters typed while
    /// the list has focus (Explorer-style). A repeated same letter cycles matches;
    /// the prefix resets after ~1s idle. Returns true if it moved the cursor.
    pub fn typeAhead(self: *TableView, b: *Browser) bool {
        var chars: [16]u8 = undefined;
        const n: usize = @intCast(cimgui.zfd_input_chars(&chars, @intCast(chars.len)));
        if (n == 0) return false;

        const now = c.igGetTime();
        if (now - self.ta_time > 1.0) self.ta_len = 0; // reset a stale prefix
        self.ta_time = now;
        for (chars[0..n]) |ch| {
            if (ch == ' ' and self.ta_len == 0) continue; // a lone Space is Quick Look, not a jump
            if (self.ta_len < self.ta_buf.len) {
                self.ta_buf[self.ta_len] = ch;
                self.ta_len += 1;
            }
        }
        const cnt = b.count();
        if (cnt == 0 or self.ta_len == 0) return false;

        const prefix = self.ta_buf[0..self.ta_len];
        const same = allSameChar(prefix);
        const needle = if (same) prefix[0..1] else prefix;
        const from = if (same) b.sel.cursor + 1 else 0; // repeat a letter → cycle
        var i: usize = 0;
        while (i < cnt) : (i += 1) {
            const idx = (from + i) % cnt;
            if (startsWithCI(b.at(idx).name, needle)) {
                b.sel.click(idx);
                b.sel.requestReveal();
                return true;
            }
        }
        return false;
    }

    pub fn handleOpKeys(self: *TableView, b: *Browser, act: *ViewActions) void {
        const ctrl = c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl);
        const shift = c.igIsKeyDown_Nil(c.ImGuiMod_Shift);
        const alt = c.igIsKeyDown_Nil(c.ImGuiMod_Alt);
        // (Ctrl+Shift+C and +H are the Go menu's Computer and Home.)
        // (A PDF read in Quick Look copies its own selected text, and selects its own.)
        if (ctrl and !shift and c.igIsKeyPressed_Bool(c.ImGuiKey_C, false) and !pdfview.takesCopy()) b.copySelection();
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_X, false)) b.cutSelection();
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_V, false)) b.paste();
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_A, false) and !pdfview.ownsKeys()) b.selectAll();
        if (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_I, false)) b.sel.invert();
        if (ctrl and !shift and c.igIsKeyPressed_Bool(c.ImGuiKey_H, false)) b.toggleHidden(); // as in Dolphin/Nautilus
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_F5, false) or (ctrl and c.igIsKeyPressed_Bool(c.ImGuiKey_R, false))) b.refresh();
        if (ctrl and !shift and c.igIsKeyPressed_Bool(c.ImGuiKey_Backspace, false)) b.deleteSelection(false); // Finder's ⌘⌫
        // Tab / Shift+Tab: the next or previous item by name, whatever the sort (Finder).
        // The list takes Tab for it, or ImGui would jump into a text field.
        if (!ctrl and !alt) {
            c.igSetKeyOwner(c.ImGuiKey_Tab, c.igGetID_Str("##listtab"), 0);
            if (c.igIsKeyPressed_Bool(c.ImGuiKey_Tab, true)) if (nextByName(b, shift)) |i| {
                b.sel.click(i);
                b.sel.reveal = true;
            };
        }
        if (!ctrl and !alt and c.igIsKeyPressed_Bool(c.ImGuiKey_Space, false)) act.quicklook_toggle = true;
        // Delete → trash (reversible, no prompt); Shift+Delete → permanent (confirm).
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Delete, false)) {
            if (shift) act.askDeleteConfirm(b) else b.deleteSelection(false);
        }
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_F2, false) and b.count() > 0) {
            // Several selected → the batch dialog; one → rename it in place.
            if (b.sel.count() > 1) act.openBatchRename(b) else self.beginRename(b, b.sel.cursor);
        }
        // Alt+Left/Right → back/forward; Alt+Enter → Properties. Back climbs to the
        // parent when there's no history (same as the toolbar/mouse Back, Up folded in).
        if (alt and c.igIsKeyPressed_Bool(c.ImGuiKey_LeftArrow, false)) b.backOrUp();
        if (alt and c.igIsKeyPressed_Bool(c.ImGuiKey_RightArrow, false)) b.forward();
        if (alt and c.igIsKeyPressed_Bool(c.ImGuiKey_Enter, false) and b.count() > 0) act.openProperties(b, b.sel.cursor);
    }

    /// listDropTarget makes the list's empty space a drop target: into THIS folder.
    /// Registered after the rows on purpose: ImGui gives a drop to the smallest hovered
    /// target, so a folder row under the pointer still wins and only the gaps fall
    /// through to here), and after EndTable, because inside the table the clip rect is
    /// the last column's, which would shrink the hover area to a sliver. Dropping rows
    /// back into their own folder is a no-op (dropDraggedInto skips items already
    /// there); from another tab or the split pane it moves them in.
    pub fn listDropTarget(self: *TableView, b: *Browser, act: *ViewActions) void {
        if (self.list_max.x <= self.list_min.x) return;
        if (c.igBeginDragDropTargetCustom(.{ .Min = self.list_min, .Max = self.list_max }, c.igGetID_Str("##listdrop"))) {
            const payload = c.igAcceptDragDropPayload(DRAG_PAYLOAD, 0);
            if (payload != null and payload.*.Delivery) {
                if (act.dragSource(payload)) |src| b.dropDraggedInto(src.dragPaths(), b.dir, c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl));
            }
            c.igEndDragDropTarget();
        }
    }

    pub fn beginRename(self: *TableView, b: *Browser, index: usize) void {
        if (index >= b.count()) return;
        b.sel.click(index); // select + cursor the row being renamed
        self.renaming = index;
        // basename: a subfolder-search result is listed as "sub/x.txt", but only its own
        // name is editable (renameCursor renames it where it lives).
        _ = std.mem.printSentinel(&self.rename_buf, "{s}", .{std.fs.path.basename(b.at(index).name)}, 0) catch return;
        self.rename_focus = true;
        self.rename_select = true; // preselect the stem, like the Save dialog's name box
    }

    fn drawTable(self: *TableView, b: *Browser, act: *ViewActions, scroll_to_cursor: bool, list_height: f32) void {
        // Finder's list: striped rows, no vertical grid lines (columns still resize by
        // dragging the header edges).
        const table_flags: c_int = c.ImGuiTableFlags_RowBg | c.ImGuiTableFlags_ScrollY |
            c.ImGuiTableFlags_Resizable | c.ImGuiTableFlags_Sortable |
            c.ImGuiTableFlags_Reorderable | c.ImGuiTableFlags_Hideable; // drag headers; right-click to show/hide

        // Rubber-band select: a drag starting on empty list space (no row/header
        // hovered) draws a box and selects the rows it covers. Detect it against the
        // table's outer rect BEFORE BeginTable (IsAnyItemHovered reflects last frame),
        // and only with the list's window under the mouse: not through Quick Look or
        // another window over it.
        const tbl_min = c.igGetCursorScreenPos();
        const tbl_avail = c.igGetContentRegionAvail();
        const tbl_h = if (list_height > 0) list_height else tbl_avail.y + list_height;
        const tbl_max = cimgui.vec2(tbl_min.x + tbl_avail.x, tbl_min.y + tbl_h);
        const box = marquee(self, b, tbl_min, tbl_max);
        const mr_min = box[0];
        const mr_max = box[1];

        if (!c.igBeginTable("##files", 12, table_flags, cimgui.vec2(0, list_height), 0)) return;
        defer c.igEndTable();

        // Widths in font sizes, so they follow DPI and zoom ("Yesterday at 21:30" fits).
        const em = c.igGetFontSize();
        c.igTableSetupColumn("Name", c.ImGuiTableColumnFlags_WidthStretch | c.ImGuiTableColumnFlags_DefaultSort, 0, 0);
        c.igTableSetupColumn("Size", c.ImGuiTableColumnFlags_WidthFixed | c.ImGuiTableColumnFlags_PreferSortDescending, @round(em * 5.5), 0);
        c.igTableSetupColumn("Kind", c.ImGuiTableColumnFlags_WidthFixed, @round(em * 7), 0);
        c.igTableSetupColumn("Date Modified", c.ImGuiTableColumnFlags_WidthFixed, @round(em * 11), 0);
        // Extra columns, hidden by default; enable via the header's right-click menu
        // (visibility persists in imgui.ini). All sortable; data is free from statx.
        const hide: c_int = c.ImGuiTableColumnFlags_WidthFixed | c.ImGuiTableColumnFlags_DefaultHide;
        c.igTableSetupColumn("Date Created", hide, @round(em * 11), 0);
        c.igTableSetupColumn("Date Last Opened", hide, @round(em * 11), 0);
        c.igTableSetupColumn("Changed", hide, @round(em * 11), 0);
        c.igTableSetupColumn("Permissions", hide, @round(em * 6.5), 0);
        c.igTableSetupColumn("Owner", hide, @round(em * 7), 0);
        c.igTableSetupColumn("Group", hide, @round(em * 7), 0);
        c.igTableSetupColumn("Link target", hide, @round(em * 12), 0);
        c.igTableSetupColumn("Opens with", hide, @round(em * 10), 0);
        c.igTableSetupScrollFreeze(0, 1);
        // View Options shows/hides columns through here; report what's shown back.
        if (act.column_toggle) |t| {
            c.igTableSetColumnEnabled(t.col, t.on);
            act.column_toggle = null;
        }
        for (&act.columns_on, 0..) |*on, col| on.* = c.igTableGetColumnFlags(@intCast(col)) & c.ImGuiTableColumnFlags_IsEnabled != 0;
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim()); // Finder's headers are quiet
        c.igTableHeadersRow();
        c.igPopStyleColor(1);

        // The browser owns the sort order (restored from settings, per tab), so push it
        // into the header when this table starts showing a browser; otherwise the
        // header's own default (Name ascending) would be read back as a click and
        // overwrite it. After that, header clicks flow the other way.
        // The same goes for a sort the model changed itself: entering a folder with
        // its own remembered view.
        const so = b.sort_order;
        if (self.sort_synced != @intFromPtr(b) or so.column != self.sort_shown.column or so.ascending != self.sort_shown.ascending) {
            self.sort_synced = @intFromPtr(b);
            syncSortHeader(b);
        } else applySortSpecs(b);
        self.sort_shown = b.sort_order;

        // Drag auto-scroll: holding a drag near the top or bottom edge of the list
        // scrolls it, so a folder further down the directory is reachable at all. Without
        // it a drop target simply had to already be on screen, and in a folder of any size
        // that made drag-to-move useless. Speed ramps up the deeper into the edge band
        // the pointer sits, the way Explorer's does.
        if (c.igIsDragDropActive()) {
            const mp = c.igGetMousePos();
            const band = c.igGetTextLineHeightWithSpacing() * 2;
            if (mp.x >= tbl_min.x and mp.x <= tbl_max.x) {
                var dy: f32 = 0;
                if (mp.y >= tbl_min.y and mp.y < tbl_min.y + band) dy = -(band - (mp.y - tbl_min.y));
                if (mp.y <= tbl_max.y and mp.y > tbl_max.y - band) dy = band - (tbl_max.y - mp.y);
                if (dy != 0) c.igSetScrollY_Float(std.math.clamp(c.igGetScrollY() + dy * 0.35, 0, c.igGetScrollMaxY()));
            }
        }

        var open_idx: ?usize = null;
        var drop_target: ?usize = null; // folder row under an external (from-another-app) drop, if any
        const cnt = b.count();
        const now = nowSecs(); // for "Today at …"
        // A row is the text's height, taller with the list's item size (View Options,
        // Ctrl+scroll): the icon fills it, and the text sits centred in every column.
        const line_h = c.igGetTextLineHeight();
        const row_h = @round(line_h * act.list_scale);
        const row_off = @round((row_h - line_h) * 0.5);
        const row_min = row_h + c.igGetStyle().*.CellPadding.y * 2;
        // ListClipper: submit only the visible rows so huge directories stay smooth.
        // Accessed via opaque handle + a two-field mirror (see cimgui.zig), no shim.
        // The +1 is the trailing empty row; include the reveal target so scroll-to
        // works even when the cursor is off-screen.
        // With Use Groups on, a heading row starts each section: display rows are the
        // entries with those headings mixed in (see groupRow).
        const starts: []const usize = if (b.group_by != .none) b.group_starts.items else &.{};
        const clip = cimgui.ImGuiListClipper_ImGuiListClipper();
        cimgui.ImGuiListClipper_Begin(clip, @intCast(cnt + starts.len + 1), -1);
        if (scroll_to_cursor and b.sel.cursor < cnt) cimgui.ImGuiListClipper_IncludeItemByIndex(clip, @intCast(displayRow(starts, b.sel.cursor)));
        while (cimgui.ImGuiListClipper_Step(clip)) {
            const range = cimgui.clipperRange(clip);
            var d: usize = @intCast(range.start);
            const stop: usize = @intCast(range.end);
            while (d < stop) : (d += 1) {
                if (d >= cnt + starts.len) {
                    c.igTableNextRow(0, c.igGetFrameHeight() * 2); // trailing empty row
                    continue;
                }
                const i = switch (groupRow(starts, d)) {
                    .header => |pos| {
                        c.igTableNextRow(0, 0);
                        _ = c.igTableSetColumnIndex(0);
                        drawGroupHeader(b.groupLabelAt(pos));
                        continue;
                    },
                    .entry => |ei| ei,
                };
                const e = b.at(i);
                b.wantDetails(i); // on screen: its details first
                c.igTableNextRow(0, row_min);
                // A selected row is solid accent with white text throughout (Finder).
                const row_sel = b.sel.isSelected(i) and !(self.renaming != null and self.renaming.? == i);
                if (row_sel) theme.pushSelected();
                defer if (row_sel) theme.popSelected();

                _ = c.igTableSetColumnIndex(0);
                if (self.renaming != null and self.renaming.? == i) {
                    c.igSetCursorPosY(c.igGetCursorPosY() + @max(0, @round((row_h - c.igGetFrameHeight()) * 0.5)));
                    self.drawRenameField(b);
                } else {
                    // Marquee hit-test BEFORE the Selectable, against the row band we are
                    // about to fill (rows span all columns, so only Y really matters). The
                    // old code tested igGetItemRect *after* submitting the Selectable, which
                    // meant the row's highlight was drawn from the just-cleared selection and
                    // only caught up a frame later: the box looked like it selected nothing
                    // until release. Selecting first makes the sweep live.
                    if (self.marquee_active) {
                        const rt = c.igGetCursorScreenPos();
                        const rb = rt.y + row_h + c.igGetStyle().*.ItemSpacing.y;
                        if (rectsOverlap(mr_min, mr_max, cimgui.vec2(tbl_min.x, rt.y), cimgui.vec2(tbl_max.x, rb)))
                            b.sel.select(i);
                    }
                    // A subfolder-search or Recent result is named by its relative path
                    // ("sub/x.txt"): show the file's own name, then its folder dimmed.
                    const slash = std.mem.lastIndexOfScalar(u8, e.name, '/');
                    const full = if (slash) |sl| e.name[sl + 1 ..] else e.name;
                    // A name too long for the column keeps its start and end (Finder).
                    const lead_w = (if (b.canExpand()) @as(f32, @floatFromInt(b.depthOf(e) + 1)) * row_h else 0) + row_h + 5;
                    const room = c.igGetContentRegionAvail().x - lead_w - (if (e.tags != 0) c.igGetFontSize() * 1.6 else 0);
                    var fit_buf: [600]u8 = undefined;
                    const shown = core.elide.middle(&fit_buf, full, room, cimgui.Measure{});
                    var name_buf: [640]u8 = undefined;
                    const label = std.mem.printSentinel(&name_buf, "{s}##{d}", .{ shown, i }, 0) catch continue;
                    // Cut (Ctrl+X, pending move) rows draw faded; else colored by type.
                    const name_col = if (row_sel) theme.selectedText() else if (b.isCut(i)) theme.dim() else nameColor(e);
                    var dl_state: ?DownloadState = null;
                    var dl_x: f32 = 0;
                    var dl_y: f32 = 0;
                    // A small type icon before the name, as in Finder's list, after a
                    // disclosure triangle (folders open in place) and the item's depth.
                    const icon_sz = row_h;
                    const row_pos = c.igGetCursorScreenPos();
                    const nestable = b.canExpand();
                    const depth = b.depthOf(e);
                    const lead: f32 = if (nestable) @as(f32, @floatFromInt(depth + 1)) * icon_sz else 0;
                    const icon_pos = cimgui.vec2(row_pos.x + lead, row_pos.y);
                    c.igIndent(lead + icon_sz + 5);
                    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, name_col);
                    // The disclosure triangle and a download's button sit on the row.
                    if ((nestable and e.isDir()) or core.procwatch.isDownloadName(e.name)) c.igSetNextItemAllowOverlap();
                    c.igPushStyleVar_Vec2(c.ImGuiStyleVar_SelectableTextAlign, cimgui.vec2(0, 0.5));
                    const clicked = c.igSelectable_Bool(label.ptr, b.sel.isSelected(i), c.ImGuiSelectableFlags_SpanAllColumns, cimgui.vec2(0, row_h));
                    c.igPopStyleVar(1);
                    c.igPopStyleColor(1);
                    c.igUnindent(lead + icon_sz + 5);
                    icons.draw(c.igGetWindowDrawList(), e, icon_pos.x, icon_pos.y, icon_sz, b.isCut(i));
                    act.pop.note(b, i, c.igIsItemHovered(0), icon_pos.x, icon_pos.y, icon_sz); // the row is the last item
                    // The name starts after the icon (the row's rect starts at the cell edge).
                    const name_x = icon_pos.x + icon_sz + 5;
                    if (e.tags != 0) {
                        const vis_end = std.mem.indexOf(u8, label, "##") orelse label.len;
                        const tw = c.igCalcTextSize(label.ptr, label.ptr + vis_end, false, -1).x;
                        _ = drawTagDots(c.igGetWindowDrawList(), name_x + tw + 6, icon_pos.y + row_h * 0.5, e.tags);
                    }
                    if (slash) |sl| if (depth == 0) drawFolderHint(b, e.name[0..sl], label, name_x, icon_pos.y + row_off);
                    dl_state = downloadState(b, act, e);
                    if (dl_state != null) {
                        const vis_end = std.mem.indexOf(u8, label, "##") orelse label.len;
                        dl_x = name_x + c.igCalcTextSize(label.ptr, label.ptr + vis_end, false, -1).x + 8;
                        dl_y = icon_pos.y + row_off;
                    }
                    if (clicked) {
                        if (c.igIsKeyDown_Nil(c.ImGuiMod_Shift)) {
                            b.sel.selectRange(i);
                        } else if (c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl)) {
                            b.sel.toggle(i);
                        } else {
                            b.sel.click(i);
                        }
                    }
                    // External drop (from another app) landing on this folder row → target it.
                    if (e.isDir()) {
                        if (b.pendingDropPos()) |pos| {
                            const rmin = c.igGetItemRectMin();
                            const rmax = c.igGetItemRectMax();
                            if (pos[0] >= rmin.x and pos[0] <= rmax.x and pos[1] >= rmin.y and pos[1] <= rmax.y)
                                drop_target = i;
                        }
                    }
                    // Drag source: dragging a row carries the selection (selecting the
                    // row first if it wasn't). The payload names this browser; beginDrag
                    // snapshots the actual paths once, on the drag's first frame.
                    if (c.igBeginDragDropSource(0)) {
                        if (!b.sel.isSelected(i)) b.sel.click(i);
                        b.beginDrag();
                        const pl = ViewActions.dragPayload(b);
                        _ = c.igSetDragDropPayload(DRAG_PAYLOAD, &pl, pl.len, 0);
                        drawDragPreview(b);
                        c.igEndDragDropSource();
                    }
                    // Drop target: dropping onto a directory moves the dragged set into it
                    // (Ctrl = copy). Delivery gates it to the release frame. A folder that is
                    // itself being dragged is not a target: accepting there would be a
                    // move-into-self, which dropDraggedInto only silently discards.
                    if (e.isDir() and !isDragged(act, b.dir, e.name) and c.igBeginDragDropTarget()) {
                        const payload = c.igAcceptDragDropPayload(DRAG_PAYLOAD, 0);
                        if (payload != null and payload.*.Delivery) {
                            var dbuf: [4200]u8 = undefined;
                            if (act.dragSource(payload)) |src| if (joinPath(&dbuf, b.dir, e.name)) |dst|
                                b.dropDraggedInto(src.dragPaths(), dst, c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl));
                        }
                        c.igEndDragDropTarget();
                    }
                    if (e.isDir() and !isDragged(act, b.dir, e.name)) {
                        var sbuf: [4200]u8 = undefined;
                        if (joinPath(&sbuf, b.dir, e.name)) |p| if (act.spring.open(p)) {
                            b.open(e) catch {};
                            break; // the listing is being replaced
                        };
                    }
                    // Right-click this row → context menu (selects it first if needed).
                    if (c.igBeginPopupContextItem(null, c.ImGuiPopupFlags_MouseButtonRight)) {
                        if (!b.sel.isSelected(i)) b.sel.click(i);
                        act.rowMenu(b, i);
                        c.igEndPopup();
                    }
                    if (c.igIsItemHovered(0) and openClicked()) open_idx = i;
                    // Middle-click a folder → open it in a new background tab.
                    if (e.isDir() and c.igIsItemHovered(0) and c.igIsMouseClicked_Bool(c.ImGuiMouseButton_Middle, false)) {
                        var tbuf: [4200]u8 = undefined;
                        if (joinPath(&tbuf, b.dir, e.name)) |path| b.requestNewTab(path);
                    }
                    if (scroll_to_cursor and i == b.sel.cursor) c.igSetScrollHereY(0.5);
                    // Partial download: Cancel / Delete after the name (submitted after the
                    // row's own item, so it gets the click).
                    if (dl_state) |ds| {
                        c.igPushID_Int(@intCast(i));
                        const del = drawDownloadButton(dl_x, dl_y, c.igGetTextLineHeight(), ds);
                        c.igPopID();
                        if (del) {
                            b.sel.click(i);
                            b.deleteSelection(false); // to the Trash, as Finder does
                        }
                    }
                    if (nestable and e.isDir()) {
                        const tx = row_pos.x + @as(f32, @floatFromInt(depth)) * icon_sz;
                        c.igPushID_Int(@intCast(i));
                        const toggle = drawDisclosure(tx + @round((icon_sz - line_h) * 0.5), row_pos.y + row_off, line_h, b.isExpanded(e.name));
                        c.igPopID();
                        if (toggle) b.toggleExpand(i);
                    }
                }

                // Its details are still on their way: the other columns stay blank
                // rather than showing 0 B and no date for a moment.
                if (e.pending) continue;
                _ = cell(1, row_off);
                if (!e.isDir()) {
                    var size_buf: [32]u8 = undefined;
                    rightText(scan.humanizeSize(&size_buf, e.size));
                } else if (act.dir_sizes == null or !act.folder_sizes) {
                    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
                    rightText("--");
                    c.igPopStyleColor(1);
                } else if (act.dir_sizes) |ds| {
                    // The files directly inside (dimmed: not counting subfolders).
                    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
                    if (joinPath(&pbuf, b.dir, e.name)) |path| {
                        var size_buf: [32]u8 = undefined;
                        var lb: [40]u8 = undefined;
                        const txt: []const u8 = if (ds.get(path, e.mtime_secs)) |sz|
                            (std.mem.print(&lb, "{s}{s}", .{ scan.humanizeSize(&size_buf, sz.bytes), if (sz.partial) "+" else "" }) catch "")
                        else
                            "\u{2026}";
                        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
                        rightText(txt);
                        c.igPopStyleColor(1);
                        if (c.igIsItemHovered(0)) c.igSetTooltip("Files directly in this folder (subfolders not counted)");
                    }
                }

                _ = cell(2, row_off);
                var type_buf: [64]u8 = undefined;
                if (downloadState(b, act, e)) |ds| {
                    const downloading = ds.writer != null;
                    // A browser's partial download: still coming in only while some
                    // process has it open; otherwise it's left over (the browser quit
                    // or died).
                    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, if (downloading) theme.info() else theme.dim());
                    cimgui.textUnformatted(if (downloading) "Downloading\u{2026}" else "Incomplete");
                    c.igPopStyleColor(1);
                    const tip: [*:0]const u8 = if (downloading) "Still being downloaded" else "Incomplete download: nothing is writing it any more, so it was left over from a download that stopped (the browser quit or crashed).";
                    if (c.igIsItemHovered(0)) c.igSetTooltip("%s", tip);
                } else fitText(b.typeLabel(e, &type_buf));

                _ = cell(3, row_off);
                var date_buf: [40]u8 = undefined;
                fitText(scan.formatDateFriendly(&date_buf, e.mtime_secs, now));

                // Optional columns: TableSetColumnIndex returns false when hidden, so we
                // only format (and, for Owner/Group, look up) what's actually visible.
                if (cell(4, row_off)) { // Created
                    var tb: [40]u8 = undefined;
                    fitText(if (e.btime_secs > 0) scan.formatDateFriendly(&tb, e.btime_secs, now) else "--");
                }
                if (cell(5, row_off)) { // Accessed
                    var tb: [40]u8 = undefined;
                    fitText(scan.formatDateFriendly(&tb, e.atime_secs, now));
                }
                if (cell(6, row_off)) { // Changed
                    var tb: [40]u8 = undefined;
                    fitText(scan.formatDateFriendly(&tb, e.ctime_secs, now));
                }
                if (cell(7, row_off)) { // Permissions
                    var mb: [10]u8 = undefined;
                    cimgui.textUnformatted(scan.formatMode(&mb, e.mode));
                }
                if (cell(8, row_off)) { // Owner
                    fitText(scan.ownerName(e.uid));
                }
                if (cell(9, row_off)) { // Group
                    fitText(scan.groupName(e.gid));
                }
                if (cell(10, row_off)) { // Link target
                    if (e.link_target.len > 0) fitText(e.link_target);
                }
                if (cell(11, row_off)) { // Opens with
                    if (!e.isDir()) fitText(b.opensWith(e.name));
                }
            }
        }
        cimgui.ImGuiListClipper_destroy(clip); // Step-to-false already called End()

        if (self.marquee_active) {
            const dl = c.igGetWindowDrawList();
            c.ImDrawList_AddRectFilled(dl, mr_min, mr_max, 0x22FFFFFF, 0, 0);
            c.ImDrawList_AddRect(dl, mr_min, mr_max, 0x99FFFFFF, 0, 1.0, 0);
        }

        if (open_idx) |idx| act.open(b, idx);

        self.list_min = tbl_min;
        self.list_max = tbl_max;

        // Resolve a queued external drop: into the folder row it landed on, else into the
        // current directory (dropped on empty space / a file / the header). Only claim
        // drops that actually landed INSIDE the list; one that hit the sidebar or the
        // tab strip belongs to that target, and the shell resolves it after the body is
        // drawn (falling back to the current dir if nothing claimed it). Without this
        // the table swallowed every drop, so dropping a file on a bookmark or another
        // tab silently imported it into the folder already on screen.
        if (b.pendingDropPos()) |pos| {
            const inside = pos[0] >= tbl_min.x and pos[0] <= tbl_max.x and
                pos[1] >= tbl_min.y and pos[1] <= tbl_max.y;
            if (inside) {
                if (drop_target) |ti| {
                    var dbuf: [4200]u8 = undefined;
                    if (joinPath(&dbuf, b.dir, b.at(ti).name)) |dst|
                        b.commitExternalDrop(dst)
                    else
                        b.commitExternalDrop(b.dir);
                } else {
                    b.commitExternalDrop(b.dir);
                }
            }
        }
        // The Properties/Open-with/Delete modals are opened + drawn by the shared
        // ViewActions at shell scope (act.drawModals), so they work from any view.

        backgroundMenu(b);
    }

    pub fn drawRenameField(self: *TableView, b: *Browser) void {
        if (self.rename_focus) {
            c.igSetKeyboardFocusHere(0);
            self.rename_focus = false;
        }
        c.igSetNextItemWidth(self.rename_width);
        // Preselect the "core" name on focus, like the Save dialog's name box: for a
        // file, the stem (name without extension) so ".ext" stays; for a folder, the
        // whole name (nothing to keep). Pass the length via `stem`; the C callback
        // selects [0, stem) once. Re-arm on click so re-focusing re-selects.
        const name = std.mem.sliceTo(&self.rename_buf, 0);
        const is_dir = if (self.renaming) |ri| (ri < b.count() and b.at(ri).isDir()) else false;
        const core_len: usize = if (is_dir) name.len else cimgui.stemLen(name);
        var stem: c_int = if (self.rename_select) @intCast(core_len) else -1;
        // Reject an invalid leaf up front ('/' would silently turn the rename into a move,
        // "."/".." are reserved). Tint the text red while it's bad (read from the buffer as
        // it stands at frame start; a 1-frame lag on the tint is invisible) and explain in
        // a hover tooltip; the commit below is blocked to match.
        const bad = core.fsops.invalidNameReason(std.mem.trim(u8, name, " \t"));
        if (bad != null) c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.err());
        const flags = c.ImGuiInputTextFlags_EnterReturnsTrue | c.ImGuiInputTextFlags_CallbackAlways;
        const submitted = c.igInputText(
            "##rename",
            &self.rename_buf,
            self.rename_buf.len,
            flags,
            cimgui.selectStem,
            &stem,
        );
        if (bad != null) c.igPopStyleColor(1);
        if (bad) |r| if (c.igBeginItemTooltip()) {
            cimgui.textUnformatted(r);
            c.igEndTooltip();
        };
        self.rename_select = false;
        if (c.igIsItemActivated()) self.rename_select = true; // re-select on next focus/click
        // End the rename when the field loses focus. Escape cancels (discards edits). Enter
        // commits a VALID name; on an invalid one it keeps the field open (re-focus) so it
        // can be fixed. Clicking away commits a valid name, or on an invalid one discards
        // the edit rather than creating a bad path. renameCursor no-ops an unchanged name,
        // so a click-away that didn't edit anything does nothing.
        const nn = std.mem.trim(u8, std.mem.sliceTo(&self.rename_buf, 0), " \t");
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
            self.renaming = null;
        } else if (submitted) {
            if (core.fsops.invalidNameReason(nn) == null) {
                b.renameCursor(nn);
                self.renaming = null;
            } else {
                self.rename_focus = true; // reject: keep editing so the name can be fixed
            }
        } else if (c.igIsItemDeactivated()) {
            if (core.fsops.invalidNameReason(nn) == null) b.renameCursor(nn);
            self.renaming = null;
        }
    }
};

/// drawTagDots draws an item's colour tags as small overlapping dots starting at x,
/// vertically centred on cy (Finder style). Returns the width used.
pub fn drawTagDots(dl: *c.ImDrawList, x: f32, cy: f32, mask: core.tags.Mask) f32 {
    const r = @round(c.igGetFontSize() * 0.3);
    var px = x + r;
    var used: f32 = 0;
    for (core.tags.list()) |col| {
        if (mask & col.bit() == 0) continue;
        const rgb = col.rgb();
        const abgr: u32 = 0xFF000000 | ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF);
        c.ImDrawList_AddCircleFilled(dl, cimgui.vec2(px, cy), r + 1, 0xFF101010, 12);
        c.ImDrawList_AddCircleFilled(dl, cimgui.vec2(px, cy), r, abgr, 12);
        if (col.color() == .none) c.ImDrawList_AddCircleFilled(dl, cimgui.vec2(px, cy), r * 0.45, 0xFF101010, 12); // a ring: no colour
        px += r * 1.3;
        used = px + r - x;
    }
    return used;
}

/// backgroundMenu: right-click on empty space (not over an item) → folder actions.
pub fn backgroundMenu(b: *Browser) void {
    if (c.igBeginPopupContextWindow("##bgctx", c.ImGuiPopupFlags_MouseButtonRight | c.ImGuiPopupFlags_NoOpenOverItems)) {
        folderItems(b);
        c.igEndPopup();
    }
}

/// folderItems are the actions on the folder itself: the empty-space menu, and the
/// toolbar's "…" menu when nothing is selected.
pub fn folderItems(b: *Browser) void {
    if (c.igMenuItem_Bool("New Folder", "Ctrl+Shift+N", false, true)) b.newFolder();
    if (c.igMenuItem_Bool("New File", null, false, true)) b.newFile();
    if (c.igMenuItem_Bool("Open Terminal Here", "F4", false, true)) b.openTerminalHere();
    c.igSeparator();
    if (c.igMenuItem_Bool("Paste", "Ctrl+V", false, !b.clipboard.isEmpty())) b.paste();
}

/// handleNav applies list navigation. Returns true if the cursor moved this frame.
fn handleNav(b: *Browser, act: *ViewActions) bool {
    const shift = c.igIsKeyDown_Nil(c.ImGuiMod_Shift);
    var moved = false;
    if (c.igIsKeyPressed_Bool(c.ImGuiKey_DownArrow, true)) {
        b.sel.moveCursor(1, shift);
        moved = true;
    }
    if (c.igIsKeyPressed_Bool(c.ImGuiKey_UpArrow, true)) {
        b.sel.moveCursor(-1, shift);
        moved = true;
    }
    if (c.igIsKeyPressed_Bool(c.ImGuiKey_Enter, false) and !c.igIsKeyDown_Nil(c.ImGuiMod_Alt)) act.openCursor(b);
    if (!c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl) and c.igIsKeyPressed_Bool(c.ImGuiKey_Backspace, false)) b.backOrUp(); // history back, else parent
    // Right opens the folder under the cursor in place, Left closes it, or, on an
    // item inside an opened folder, steps out to that folder (Finder's list keys).
    const alt = c.igIsKeyDown_Nil(c.ImGuiMod_Alt);
    if (!alt and b.canExpand() and b.sel.cursor < b.count()) {
        const e = b.at(b.sel.cursor);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_RightArrow, false) and e.isDir() and !b.isExpanded(e.name)) b.toggleExpand(b.sel.cursor);
        if (c.igIsKeyPressed_Bool(c.ImGuiKey_LeftArrow, false)) {
            if (e.isDir() and b.isExpanded(e.name)) {
                b.toggleExpand(b.sel.cursor);
            } else if (std.mem.lastIndexOfScalar(u8, e.name, '/')) |sl| {
                b.setPendingSelect(e.name[0..sl]);
                b.reselect();
            }
        }
    }
    return moved;
}

/// joinPath writes "<dir>/<name>" into buf, collapsing the separator when dir already
/// ends in one (dir == "/" is the case that produced "//name": a path that compares
/// unequal to the same file reached any other way, so the drop-into-self and
/// already-in-this-folder guards both missed it).
/// openClicked is a double-click that opens an item: not one with Ctrl or Shift
/// held, which are two clicks adding to the selection and taking away again.
pub fn openClicked() bool {
    return c.igIsMouseDoubleClicked_Nil(0) and !c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl) and !c.igIsKeyDown_Nil(c.ImGuiMod_Shift);
}

pub fn joinPath(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    const d = if (dir.len > 1 and dir[dir.len - 1] == '/') dir[0 .. dir.len - 1] else dir;
    const sep: []const u8 = if (std.mem.endsWith(u8, d, "/")) "" else "/";
    return std.mem.print(buf, "{s}{s}{s}", .{ d, sep, name }) catch null;
}

/// isDragged reports whether <dir>/<name> is one of the items in the live drag; used
/// to refuse a folder as a drop target while it is itself being dragged.
pub fn isDragged(act: *const ViewActions, dir: []const u8, name: []const u8) bool {
    const src = act.dragSource(c.igGetDragDropPayload()) orelse return false;
    const dragged = src.dragPaths();
    if (dragged.len == 0) return false;
    var buf: [4200]u8 = undefined;
    const p = joinPath(&buf, dir, name) orelse return false;
    for (dragged) |d| {
        if (std.mem.eql(u8, d, p)) return true;
    }
    return false;
}

/// drawDragPreview is the tooltip that follows the cursor during an internal drag. It
/// names the action (Ctrl toggles copy/move) and how many items are riding along, so a
/// multi-select drag no longer looks identical to a single-row one.
/// drawDisclosure is a folder row's open/close triangle (h×h at x,y): it turns from
/// pointing right (closed) to pointing down (open). Returns whether it was clicked.
/// cell moves to column `col` of the current row, `off` down: text sits centred in a
/// row taller than it.
fn cell(col: c_int, off: f32) bool {
    if (!c.igTableSetColumnIndex(col)) return false;
    if (off > 0) c.igSetCursorPosY(c.igGetCursorPosY() + off);
    return true;
}

fn drawDisclosure(x: f32, y: f32, h: f32, open: bool) bool {
    c.igSetCursorScreenPos(cimgui.vec2(x, y));
    const clicked = c.igInvisibleButton("##disclose", cimgui.vec2(h, h), 0);
    const col = c.igGetColorU32_Vec4(if (c.igIsItemHovered(0)) theme.text() else theme.dim());
    const turn = anim.toward(c.igGetItemID(), open, anim.normal) * std.math.pi * 0.5;
    const r = h * 0.22;
    const ctr = cimgui.vec2(x + h * 0.5, y + h * 0.5);
    // The right-pointing triangle, turned about the box's centre.
    const pts = [_][2]f32{ .{ -0.6, -1 }, .{ 0.8, 0 }, .{ -0.6, 1 } };
    var v: [3]c.ImVec2_c = undefined;
    for (pts, 0..) |pt, k| {
        const px = pt[0] * r;
        const py = pt[1] * r;
        v[k] = cimgui.vec2(ctr.x + px * @cos(turn) - py * @sin(turn), ctr.y + px * @sin(turn) + py * @cos(turn));
    }
    c.ImDrawList_AddTriangleFilled(c.igGetWindowDrawList(), v[0], v[1], v[2], col);
    return clicked;
}

/// fitText draws a cell's text, shortened in the middle to the cell's width.
pub fn fitText(s: []const u8) void {
    var buf: [600]u8 = undefined;
    cimgui.textUnformatted(core.elide.middle(&buf, s, c.igGetContentRegionAvail().x, cimgui.Measure{}));
}

/// rightText draws a cell's text against its right edge (Finder's sizes).
fn rightText(s: []const u8) void {
    const w = c.igCalcTextSize(s.ptr, s.ptr + s.len, false, -1).x;
    const avail = c.igGetContentRegionAvail().x;
    if (w < avail) c.igSetCursorPosX(c.igGetCursorPosX() + avail - w);
    cimgui.textUnformatted(s);
}

/// nowSecs is the wall clock in Unix seconds.
pub fn nowSecs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// drawFolderHint draws a result's folder, dimmed, after its name in the Name cell
/// (clipped to the column like the name). `label` is the Selectable's label, whose
/// visible part ends at "##".
fn drawFolderHint(b: *Browser, folder: []const u8, label: [:0]const u8, x: f32, y: f32) void {
    const vis_end = std.mem.indexOf(u8, label, "##") orelse label.len;
    const name_w = c.igCalcTextSize(label.ptr, label.ptr + vis_end, false, -1).x;
    var buf: [600]u8 = undefined;
    // Recent lists paths relative to "/": show them absolute.
    const hint = std.mem.print(&buf, "  {s}{s}", .{ if (b.in_recent) "/" else "", folder }) catch return;
    const pos = cimgui.vec2(x + name_w, y);
    const col = c.igGetColorU32_Vec4(theme.dim());
    c.ImDrawList_AddText_Vec2(c.igGetWindowDrawList(), pos, col, hint.ptr, hint.ptr + hint.len);
}

pub fn drawDragPreview(b: *Browser) void {
    const n = b.dragPaths().len;
    const copy = c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl);
    var buf: [640]u8 = undefined;
    const verb: []const u8 = if (copy) "Copy" else "Move";
    const text = if (n == 1)
        std.mem.print(&buf, "{s} {s}", .{ verb, std.fs.path.basename(b.dragPaths()[0]) }) catch verb
    else
        std.mem.print(&buf, "{s} {d} items", .{ verb, n }) catch verb;
    cimgui.textUnformatted(text);
    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
    cimgui.textUnformatted(if (copy) "Release on a folder (Ctrl held = copy)" else "Release on a folder (hold Ctrl to copy)");
    c.igPopStyleColor(1);
}

/// rectsOverlap reports whether two screen-space AABBs intersect (marquee vs row).
/// marquee runs the rubber band over the area min–max (the list's, the icons'), and
/// gives its box while one is drawn (the rows or icons it covers get selected; the
/// box is empty otherwise). A press on no item there starts it, but only a drag makes
/// it one: a click stays a click. Whether the press was on an item is last frame's
/// word (this frame's items come later), and a quick hand arriving on a row as it
/// clicked started a band: the row was selected by it, but the cursor (what the
/// preview and Open go by) stayed where it was. Now that row takes the click itself,
/// later in the frame; a click on empty space clears the selection.
pub fn marquee(self: *TableView, b: *Browser, area_min: c.ImVec2_c, area_max: c.ImVec2_c) [2]c.ImVec2_c {
    if (!self.marquee_active and !self.marquee_pending and c.igIsWindowHovered(c.ImGuiHoveredFlags_ChildWindows) and
        c.igIsMouseHoveringRect(area_min, area_max, false) and !c.igIsAnyItemHovered() and c.igIsMouseClicked_Bool(0, false))
    {
        self.marquee_pending = true;
        // Ctrl/Shift+drag extends the existing selection (Explorer); a plain drag
        // replaces it. Recorded at the press so releasing the modifier mid-drag
        // doesn't suddenly wipe what the box already added.
        self.marquee_add = c.igIsKeyDown_Nil(c.ImGuiMod_Ctrl) or c.igIsKeyDown_Nil(c.ImGuiMod_Shift);
        self.marquee_start = c.igGetMousePos();
    }
    // A live drag-and-drop always wins: pressing on a row starts a DnD, and the band
    // must not also run (it would clear the very selection being dragged).
    const dnd = c.igGetDragDropPayload() != null;
    if (self.marquee_pending) {
        if (dnd) {
            self.marquee_pending = false;
        } else if (!c.igIsMouseDown_Nil(0)) {
            self.marquee_pending = false;
            if (!self.marquee_add) b.sel.clear(); // (a row clicked takes it after this)
        } else if (c.igIsMouseDragging(0, -1)) {
            self.marquee_pending = false;
            self.marquee_active = true;
        }
    }
    if (self.marquee_active and (dnd or !c.igIsMouseDown_Nil(0))) self.marquee_active = false;
    if (!self.marquee_active) return .{ cimgui.vec2(0, 0), cimgui.vec2(0, 0) };
    if (!self.marquee_add) b.sel.clear(); // rebuild the selection from the box each frame
    const cur = c.igGetMousePos();
    return .{
        cimgui.vec2(@min(self.marquee_start.x, cur.x), @min(self.marquee_start.y, cur.y)),
        cimgui.vec2(@max(self.marquee_start.x, cur.x), @max(self.marquee_start.y, cur.y)),
    };
}

pub fn rectsOverlap(a_min: c.ImVec2_c, a_max: c.ImVec2_c, b_min: c.ImVec2_c, b_max: c.ImVec2_c) bool {
    return a_min.x <= b_max.x and a_max.x >= b_min.x and a_min.y <= b_max.y and a_max.y >= b_min.y;
}

fn allSameChar(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s[1..]) |ch| {
        if (std.ascii.toLower(ch) != std.ascii.toLower(s[0])) return false;
    }
    return true;
}

fn startsWithCI(name: []const u8, prefix: []const u8) bool {
    if (name.len < prefix.len) return false;
    for (prefix, 0..) |ch, i| {
        if (std.ascii.toLower(name[i]) != std.ascii.toLower(ch)) return false;
    }
    return true;
}

/// DownloadState is a partial download's: who's still writing it (null: left over).
pub const DownloadState = struct { writer: ?core.procwatch.Writer };

/// downloadState is null for ordinary files; for a partial download (.part,
/// .crdownload), whether (and by what) it's still being written.
pub fn downloadState(b: *Browser, act: *const ViewActions, e: scan.Entry) ?DownloadState {
    if (e.isDir() or !core.procwatch.isDownloadName(e.name)) return null;
    const pw = act.procwatch orelse return null;
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const p = joinPath(&pbuf, b.dir, e.name) orelse return null;
    return .{ .writer = pw.writerOf(p) };
}

/// drawDownloadButton is the round button after a partial download's name, as on a
/// Mac: ✕ Cancel while it downloads (a download program is told to stop; a browser's
/// download can only be cancelled in the browser), turning into a trash can that
/// deletes it once nothing writes it any more. Returns whether Delete was clicked.
fn drawDownloadButton(x: f32, y: f32, h: f32, st: DownloadState) bool {
    c.igSetCursorScreenPos(cimgui.vec2(x, y));
    const sz = h;
    const live = st.writer != null;
    const can = if (st.writer) |w| w.stoppable() else true;
    c.igBeginDisabled(!can);
    const clicked = c.igInvisibleButton("##dlbtn", cimgui.vec2(sz, sz), 0);
    const hovered = c.igIsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled);
    c.igEndDisabled();
    const dl = c.igGetWindowDrawList();
    const ctr = cimgui.vec2(x + sz * 0.5, y + sz * 0.5);
    const r = sz * 0.45;
    const col = c.igGetColorU32_Vec4(if (!can) theme.dim() else if (hovered) theme.text() else theme.dim());
    c.ImDrawList_AddCircle(dl, ctr, r, col, 16, 1.2);
    const k = r * 0.42;
    if (live) {
        c.ImDrawList_AddLine(dl, cimgui.vec2(ctr.x - k, ctr.y - k), cimgui.vec2(ctr.x + k, ctr.y + k), col, 1.4);
        c.ImDrawList_AddLine(dl, cimgui.vec2(ctr.x + k, ctr.y - k), cimgui.vec2(ctr.x - k, ctr.y + k), col, 1.4);
    } else {
        // A small trash can.
        c.ImDrawList_AddLine(dl, cimgui.vec2(ctr.x - k * 1.1, ctr.y - k * 0.7), cimgui.vec2(ctr.x + k * 1.1, ctr.y - k * 0.7), col, 1.3);
        c.ImDrawList_AddRect(dl, cimgui.vec2(ctr.x - k * 0.75, ctr.y - k * 0.6), cimgui.vec2(ctr.x + k * 0.75, ctr.y + k * 1.05), col, 1, 1.3, 0); // rounding, thickness, flags
    }
    if (hovered) {
        var tb: [160]u8 = undefined;
        const tip = if (st.writer) |w|
            (if (w.stoppable())
                std.mem.printSentinel(&tb, "Cancel the download (stops {s})", .{w.comm()}, 0) catch "Cancel the download"
            else
                std.mem.printSentinel(&tb, "Being downloaded by {s}: cancel it there", .{w.comm()}, 0) catch "Cancel it in the browser")
        else
            "Delete this incomplete download (to the Trash)";
        c.igSetTooltip("%s", tip.ptr);
    }
    if (clicked) if (st.writer) |w| w.stop();
    return clicked and !live;
}

/// GroupRow is what display row `d` of a grouped list shows.
const GroupRow = union(enum) { header: usize, entry: usize };

/// groupRow maps display row `d` to a section heading (by the view position its
/// section starts at) or an entry. Section g's heading sits at row starts[g] + g.
fn groupRow(starts: []const usize, d: usize) GroupRow {
    if (starts.len == 0) return .{ .entry = d };
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (hi - lo > 1) { // the last section whose heading is at or above d
        const mid = (lo + hi) / 2;
        if (starts[mid] + mid <= d) lo = mid else hi = mid;
    }
    if (starts[lo] + lo == d) return .{ .header = starts[lo] };
    return .{ .entry = d - (lo + 1) };
}

/// displayRow is the display row of view position `i` in a grouped list.
fn displayRow(starts: []const usize, i: usize) usize {
    var n: usize = 0;
    for (starts) |st| {
        if (st <= i) n += 1 else break;
    }
    return i + n;
}

/// drawGroupHeader is a section heading: the name in bold-ish dim text with a rule
/// under it, as in Finder's grouped lists.
pub fn drawGroupHeader(label: []const u8) void {
    const pos = c.igGetCursorScreenPos();
    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
    cimgui.textUnformatted(label);
    c.igPopStyleColor(1);
    const h = c.igGetTextLineHeight();
    const w = c.igGetWindowWidth();
    c.ImDrawList_AddLine(c.igGetWindowDrawList(), cimgui.vec2(pos.x, pos.y + h + 1), cimgui.vec2(pos.x + w, pos.y + h + 1), c.igGetColorU32_Col(c.ImGuiCol_Separator, 1), 1);
}

test "groupRow and displayRow agree" {
    const starts = [_]usize{ 0, 3, 5 };
    try std.testing.expectEqual(GroupRow{ .header = 0 }, groupRow(&starts, 0));
    try std.testing.expectEqual(GroupRow{ .entry = 0 }, groupRow(&starts, 1));
    try std.testing.expectEqual(GroupRow{ .entry = 2 }, groupRow(&starts, 3));
    try std.testing.expectEqual(GroupRow{ .header = 3 }, groupRow(&starts, 4));
    try std.testing.expectEqual(GroupRow{ .entry = 3 }, groupRow(&starts, 5));
    try std.testing.expectEqual(GroupRow{ .header = 5 }, groupRow(&starts, 7));
    for (0..8) |i| try std.testing.expectEqual(GroupRow{ .entry = i }, groupRow(&starts, displayRow(&starts, i)));
}

/// nameColor is the colour a name is drawn in: the theme's text colour, as in Finder
/// (the file type shows in the icon instead).
pub fn nameColor(e: scan.Entry) c.ImVec4_c {
    _ = e;
    return theme.text();
}

/// typeColor is the file type's colour (folders blue, images green, …), for icons.
pub fn typeColor(e: scan.Entry) c.ImVec4_c {
    return switch (scan.category(e)) {
        .folder => cimgui.vec4(0.55, 0.75, 1.00, 1.0),
        .link => cimgui.vec4(0.50, 0.90, 0.85, 1.0),
        .image => cimgui.vec4(0.65, 0.85, 0.55, 1.0),
        .video => cimgui.vec4(0.85, 0.65, 0.90, 1.0),
        .audio => cimgui.vec4(0.90, 0.80, 0.55, 1.0),
        .text => cimgui.vec4(0.82, 0.82, 0.82, 1.0),
        .pdf => cimgui.vec4(0.90, 0.55, 0.50, 1.0),
        .archive => cimgui.vec4(0.85, 0.70, 0.45, 1.0),
        .source => cimgui.vec4(0.55, 0.85, 0.85, 1.0),
        .library => cimgui.vec4(0.72, 0.72, 0.60, 1.0),
        .other => cimgui.vec4(0.86, 0.86, 0.86, 1.0),
    };
}

/// syncSortHeader shows the browser's sort order in the header (column + arrow) and
/// consumes the resulting dirty specs without feeding them back.
fn syncSortHeader(b: *Browser) void {
    const dir: c.ImGuiSortDirection = if (b.sort_order.ascending) c.ImGuiSortDirection_Ascending else c.ImGuiSortDirection_Descending;
    c.igTableSetColumnSortDirection(columnIndex(b.sort_order.column), dir, false);
    if (c.igTableGetSortSpecs()) |specs| specs.*.SpecsDirty = false;
}

fn columnIndex(col: scan.SortColumn) c_int {
    return switch (col) {
        .name => 0,
        .size => 1,
        .type => 2,
        .date => 3,
        .created => 4,
        .accessed => 5,
        .changed => 6,
        .perms => 7,
        .owner => 8,
        .group => 9,
        .link => 10,
        .opens => 11,
    };
}

/// applySortSpecs pushes ImGui's header-click sort state into the browser model.
fn applySortSpecs(b: *Browser) void {
    const specs = c.igTableGetSortSpecs();
    if (specs == null or !specs.*.SpecsDirty or specs.*.SpecsCount == 0) {
        if (specs != null) specs.*.SpecsDirty = false;
        return;
    }
    const s0 = specs.*.Specs[0];
    const col: scan.SortColumn = switch (s0.ColumnIndex) {
        1 => .size,
        2 => .type,
        3 => .date, // Modified
        4 => .created,
        5 => .accessed,
        6 => .changed,
        7 => .perms,
        8 => .owner,
        9 => .group,
        10 => .link,
        11 => .opens,
        else => .name,
    };
    b.setSort(col, s0.SortDirection == c.ImGuiSortDirection_Ascending);
    specs.*.SpecsDirty = false;
}

/// nextByName is the item whose name comes right after (or before) the cursor's,
/// ignoring case; null at the end.
fn nextByName(b: *Browser, back: bool) ?usize {
    const n = b.count();
    if (n == 0) return null;
    const cur: ?[]const u8 = if (b.sel.cursor < n) std.fs.path.basename(b.at(b.sel.cursor).name) else null;
    var best: ?usize = null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const name = std.fs.path.basename(b.at(i).name);
        if (cur) |cn| {
            const order = std.ascii.orderIgnoreCase(name, cn);
            if (if (back) order != .lt else order != .gt) continue;
        }
        if (best) |bi| {
            const o = std.ascii.orderIgnoreCase(name, std.fs.path.basename(b.at(bi).name));
            if (if (back) o != .gt else o != .lt) continue;
        }
        best = i;
    }
    return best;
}
