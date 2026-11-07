//! Animated values for widgets, keyed by ImGui ID. Every animation in the UI goes
//! through here, so they share one clock (ImGui's frame time), one set of speeds,
//! and one switch (Reduce motion). The maths is core.anim's Tween.
//!
//!   const w = anim.value(c.igGetID_Str("search"), if (open) wide else narrow, anim.normal, .out_cubic);
//!
//! A key's first value is taken as-is (nothing animates into its first frame); after
//! that, a new target is eased towards from wherever it is. While anything is still
//! moving, `running` keeps the main loop drawing frames.

const std = @import("std");
const cimgui = @import("cimgui.zig");
const c = cimgui.c;
const core = @import("core");

const Tween = core.anim.Tween;
pub const Ease = core.anim.Ease;

/// Speeds (seconds), so every animation of a kind moves alike.
pub const quick: f32 = 0.12; // hover and press fades
pub const normal: f32 = 0.22; // fields, panes, disclosure triangles
pub const slow: f32 = 0.32; // a folder opening

/// Reduce motion (Settings > Appearance): every value lands on its target at once.
pub var reduce_motion = false;

const Slot = struct {
    id: c.ImGuiID = 0,
    tween: Tween = Tween.still(0),
    seen: c_int = -1, // frame last used, for recycling
};

// A fixed pool: only what's on screen animates, so a few hundred slots are plenty;
// when full, the slot unused for longest is recycled.
var slots: [384]Slot = @splat(.{});
var moving_frame: c_int = -1;

/// value is `key`'s current value on its way to `target`.
pub fn value(key: c.ImGuiID, target: f32, dur: f32, ease: Ease) f32 {
    const now = c.igGetTime();
    const s = find(key) orelse claim(key, Tween.still(target));
    if (reduce_motion) s.tween = Tween.still(target) else s.tween.retarget(now, target, dur, ease);
    return sample(s, now);
}

/// toward is `value` for a 0/1 state (hovered, open, selected …).
pub fn toward(key: c.ImGuiID, on: bool, dur: f32) f32 {
    return value(key, if (on) 1 else 0, dur, .out_cubic);
}

/// play starts `key` afresh from `from` to `to` (a one-shot: a pop, a flash);
/// read it back with `playing`.
pub fn play(key: c.ImGuiID, from: f32, to: f32, dur: f32, ease: Ease) void {
    const t: Tween = if (reduce_motion) Tween.still(to) else .{ .from = from, .to = to, .start = c.igGetTime(), .dur = dur, .ease = ease };
    if (find(key)) |s| s.tween = t else _ = claim(key, t);
}

/// playing is a one-shot's value while it runs, null once it has finished.
pub fn playing(key: c.ImGuiID) ?f32 {
    const s = find(key) orelse return null;
    const now = c.igGetTime();
    if (s.tween.done(now)) return null;
    return sample(s, now);
}

/// cycle is how far through a repeating loop (a busy indicator) the shared clock is,
/// 0..1 once every `period` seconds, and keeps frames coming while it's read.
/// Callers draw something still instead when `reduce_motion` is on.
pub fn cycle(period: f32) f32 {
    moving_frame = c.igGetFrameCount();
    const t = c.igGetTime() / period;
    return @floatCast(t - @floor(t));
}

/// running reports whether anything moved in the frame just drawn (the main loop
/// then draws another instead of waiting for input).
pub fn running() bool {
    return moving_frame == c.igGetFrameCount();
}

fn sample(s: *Slot, now: f64) f32 {
    s.seen = c.igGetFrameCount();
    if (!s.tween.done(now)) moving_frame = s.seen;
    return s.tween.value(now);
}

fn find(key: c.ImGuiID) ?*Slot {
    for (&slots) |*s| if (s.id == key and s.seen >= 0) return s;
    return null;
}

fn claim(key: c.ImGuiID, t: Tween) *Slot {
    var pick = &slots[0];
    for (&slots) |*s| {
        if (s.seen < pick.seen) pick = s;
        if (s.seen < 0) break; // never used
    }
    pick.* = .{ .id = key, .tween = t, .seen = c.igGetFrameCount() };
    return pick;
}
