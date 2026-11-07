//! Selection model over the current listing: the familiar file-manager scheme
//! (goal 6): plain click selects one, Ctrl-click toggles, Shift-click selects a
//! contiguous range from an anchor. A `cursor` tracks the keyboard-focused row.
//! Index-based and reset on navigation (a fresh listing renumbers everything);
//! pure and unit-tested. The UI translates mouse/keyboard into these calls.

const std = @import("std");

pub const Selection = struct {
    selected: std.ArrayList(bool) = .empty, // one flag per listing row
    anchor: usize = 0, // pivot for Shift-range
    cursor: usize = 0, // keyboard-focused row
    reveal: bool = false, // a view moved the cursor and wants it scrolled into view

    pub fn deinit(self: *Selection, alloc: std.mem.Allocator) void {
        self.selected.deinit(alloc);
    }

    /// reset resizes to `n` rows, all deselected, cursor/anchor back to 0. Call
    /// whenever a new listing loads.
    pub fn reset(self: *Selection, alloc: std.mem.Allocator, n: usize) !void {
        self.selected.clearRetainingCapacity();
        try self.selected.appendNTimes(alloc, false, n);
        self.anchor = 0;
        self.cursor = 0;
        self.reveal = false;
    }

    pub fn len(self: *const Selection) usize {
        return self.selected.items.len;
    }

    pub fn isSelected(self: *const Selection, i: usize) bool {
        return i < self.selected.items.len and self.selected.items[i];
    }

    pub fn count(self: *const Selection) usize {
        var c: usize = 0;
        for (self.selected.items) |b| {
            if (b) c += 1;
        }
        return c;
    }

    /// click selects only row `i` (plain left-click).
    pub fn click(self: *Selection, i: usize) void {
        if (i >= self.len()) return;
        self.clearAll();
        self.selected.items[i] = true;
        self.anchor = i;
        self.cursor = i;
    }

    /// toggle flips row `i`'s selection, leaving the rest (Ctrl-click).
    pub fn toggle(self: *Selection, i: usize) void {
        if (i >= self.len()) return;
        self.selected.items[i] = !self.selected.items[i];
        self.anchor = i;
        self.cursor = i;
    }

    /// selectRange selects exactly the contiguous span from the anchor to `i`
    /// (Shift-click), replacing the previous selection; the anchor is unchanged.
    pub fn selectRange(self: *Selection, i: usize) void {
        if (i >= self.len()) return;
        self.clearAll();
        const lo = @min(self.anchor, i);
        const hi = @max(self.anchor, i);
        var k = lo;
        while (k <= hi) : (k += 1) self.selected.items[k] = true;
        self.cursor = i;
    }

    /// moveCursor moves the keyboard cursor by `delta` (clamped to the list) and
    /// updates the selection: `extend` (Shift) grows the range from the anchor,
    /// otherwise it's a plain single-row selection at the new cursor. Keyboard nav
    /// always reveals the cursor.
    pub fn moveCursor(self: *Selection, delta: isize, extend: bool) void {
        if (self.len() == 0) return;
        const next = clampStep(self.cursor, delta, self.len());
        if (extend) self.selectRange(next) else self.click(next);
        self.reveal = true;
    }

    /// requestReveal asks the scrollable view to scroll the cursor into view. Used
    /// when a *different* view (type-ahead, the treemap) moves the cursor, so the
    /// file list follows. A plain click on an already-visible row does NOT set this.
    pub fn requestReveal(self: *Selection) void {
        self.reveal = true;
    }

    /// takeReveal returns whether a reveal is pending and clears it (the file view
    /// calls this once per frame to decide whether to scroll to the cursor).
    pub fn takeReveal(self: *Selection) bool {
        const r = self.reveal;
        self.reveal = false;
        return r;
    }

    /// selectAll marks every row selected (Ctrl+A).
    pub fn selectAll(self: *Selection) void {
        for (self.selected.items) |*b| b.* = true;
    }

    /// invert flips every row (Ctrl+I): "everything except what I picked".
    pub fn invert(self: *Selection) void {
        for (self.selected.items) |*b| b.* = !b.*;
    }

    /// clear deselects every row (keeps the size). Used to rebuild a marquee box.
    pub fn clear(self: *Selection) void {
        self.clearAll();
    }

    /// select adds row `i` to the selection without clearing others (marquee add).
    pub fn select(self: *Selection, i: usize) void {
        if (i < self.len()) self.selected.items[i] = true;
    }

    fn clearAll(self: *Selection) void {
        for (self.selected.items) |*b| b.* = false;
    }
};

/// clampStep adds `delta` to `cur` and clamps the result to [0, n-1].
fn clampStep(cur: usize, delta: isize, n: usize) usize {
    const signed = @as(isize, @intCast(cur)) + delta;
    if (signed < 0) return 0;
    const hi = n - 1;
    return if (@as(usize, @intCast(signed)) > hi) hi else @intCast(signed);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "invert flips every row" {
    var s: Selection = .{};
    defer s.deinit(std.testing.allocator);
    try s.reset(std.testing.allocator, 4);
    s.click(1);
    s.invert();
    try std.testing.expect(s.isSelected(0) and !s.isSelected(1) and s.isSelected(2) and s.isSelected(3));
    try std.testing.expectEqual(@as(usize, 3), s.count());
}

test "click selects exactly one row and sets anchor/cursor" {
    const a = testing.allocator;
    var s = Selection{};
    defer s.deinit(a);
    try s.reset(a, 5);
    s.click(2);
    try testing.expect(s.isSelected(2));
    try testing.expectEqual(@as(usize, 1), s.count());
    try testing.expectEqual(@as(usize, 2), s.anchor);
    try testing.expectEqual(@as(usize, 2), s.cursor);
    s.click(4); // replaces
    try testing.expect(s.isSelected(4));
    try testing.expect(!s.isSelected(2));
    try testing.expectEqual(@as(usize, 1), s.count());
}

test "ctrl-toggle adds and removes without clearing" {
    const a = testing.allocator;
    var s = Selection{};
    defer s.deinit(a);
    try s.reset(a, 5);
    s.click(1);
    s.toggle(3);
    try testing.expect(s.isSelected(1) and s.isSelected(3));
    try testing.expectEqual(@as(usize, 2), s.count());
    s.toggle(3); // remove
    try testing.expect(!s.isSelected(3));
    try testing.expectEqual(@as(usize, 1), s.count());
}

test "shift-range selects a contiguous span from the anchor, both directions" {
    const a = testing.allocator;
    var s = Selection{};
    defer s.deinit(a);
    try s.reset(a, 6);
    s.click(1); // anchor = 1
    s.selectRange(4);
    try testing.expectEqual(@as(usize, 4), s.count()); // 1,2,3,4
    try testing.expect(s.isSelected(1) and s.isSelected(4) and !s.isSelected(5));
    s.selectRange(0); // anchor still 1 → span 0..1
    try testing.expectEqual(@as(usize, 2), s.count());
    try testing.expect(s.isSelected(0) and s.isSelected(1) and !s.isSelected(2));
}

test "reveal: cursor moves request it, a plain click does not, take consumes once" {
    const a = testing.allocator;
    var s = Selection{};
    defer s.deinit(a);
    try s.reset(a, 4);
    try testing.expect(!s.reveal); // before: reset clears it

    s.moveCursor(1, false); // keyboard nav
    try testing.expect(s.reveal); // after: reveal requested
    try testing.expect(s.takeReveal()); // consumed → true
    try testing.expect(!s.reveal); // and cleared
    try testing.expect(!s.takeReveal()); // second take → false

    s.click(2); // a click on an already-visible row must NOT reveal
    try testing.expect(!s.reveal);

    s.requestReveal(); // an off-view mover (type-ahead/treemap) does
    try testing.expect(s.takeReveal());
}

test "moveCursor steps, clamps, and extends" {
    const a = testing.allocator;
    var s = Selection{};
    defer s.deinit(a);
    try s.reset(a, 3);
    s.moveCursor(1, false); // 0 -> 1, single select
    try testing.expectEqual(@as(usize, 1), s.cursor);
    try testing.expect(s.isSelected(1) and s.count() == 1);
    s.moveCursor(5, false); // clamp to last
    try testing.expectEqual(@as(usize, 2), s.cursor);
    s.moveCursor(-5, false); // clamp to first
    try testing.expectEqual(@as(usize, 0), s.cursor);
    // extend from anchor (now 0) down to 2
    s.moveCursor(1, true);
    s.moveCursor(1, true);
    try testing.expectEqual(@as(usize, 3), s.count());
}
