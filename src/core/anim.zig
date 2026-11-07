//! Animation maths: easing curves and a retargetable Tween. Pure (time is passed
//! in, in seconds), so it is frame-rate independent and unit-tested here; the UI's
//! per-widget store (ui/anim.zig) drives it from the frame clock.
//!
//! A Tween that is retargeted mid-flight starts again from where it currently is,
//! so an interrupted animation (hover off before the fade-in finished, a search
//! field closed while still opening) turns around smoothly instead of jumping.

const std = @import("std");

pub const Ease = enum {
    linear,
    /// Fast start, gentle stop: the default for things that move or grow.
    out_cubic,
    /// Slow start and stop: for things that travel across the screen.
    in_out_cubic,
    /// Overshoots slightly and settles: a "pop".
    out_back,

    pub fn at(e: Ease, t_in: f32) f32 {
        const t = std.math.clamp(t_in, 0, 1);
        return switch (e) {
            .linear => t,
            .out_cubic => 1 - cube(1 - t),
            .in_out_cubic => if (t < 0.5) 4 * t * t * t else 1 - cube(-2 * t + 2) / 2,
            .out_back => blk: {
                const k1: f32 = 1.70158;
                const k3 = k1 + 1;
                break :blk 1 + k3 * cube(t - 1) + k1 * (t - 1) * (t - 1);
            },
        };
    }
};

fn cube(x: f32) f32 {
    return x * x * x;
}

pub const Tween = struct {
    from: f32,
    to: f32,
    start: f64, // seconds
    dur: f32, // seconds; 0 = jump
    ease: Ease = .out_cubic,

    /// still is a Tween resting at `v`.
    pub fn still(v: f32) Tween {
        return .{ .from = v, .to = v, .start = 0, .dur = 0 };
    }

    pub fn progress(self: Tween, now: f64) f32 {
        if (self.dur <= 0) return 1;
        return std.math.clamp(@as(f32, @floatCast((now - self.start) / self.dur)), 0, 1);
    }

    pub fn value(self: Tween, now: f64) f32 {
        return self.from + (self.to - self.from) * self.ease.at(self.progress(now));
    }

    pub fn done(self: Tween, now: f64) bool {
        return self.progress(now) >= 1;
    }

    /// retarget heads for `to` from wherever the tween is at `now`. Retargeting to
    /// the current target changes nothing (the running animation carries on).
    pub fn retarget(self: *Tween, now: f64, to: f32, dur: f32, ease: Ease) void {
        if (to == self.to) return;
        self.* = .{ .from = self.value(now), .to = to, .start = now, .dur = dur, .ease = ease };
    }
};

// ---------------------------------------------------------------------------
const testing = std.testing;

test "easings run from 0 to 1 and clamp outside" {
    inline for (@typeInfo(Ease).@"enum".field_names) |n| {
        const e = @field(Ease, n);
        try testing.expectApproxEqAbs(@as(f32, 0), e.at(0), 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 1), e.at(1), 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 1), e.at(7), 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 0), e.at(-3), 1e-5);
    }
    try testing.expect(Ease.out_cubic.at(0.5) > 0.5); // front-loaded
    try testing.expect(Ease.out_back.at(0.7) > 1); // overshoots before settling
}

test "a tween moves over its duration, then rests" {
    const t: Tween = .{ .from = 10, .to = 20, .start = 1.0, .dur = 0.5, .ease = .linear };
    try testing.expectEqual(@as(f32, 10), t.value(0.5)); // not started yet
    try testing.expectApproxEqAbs(@as(f32, 15), t.value(1.25), 1e-4);
    try testing.expectEqual(@as(f32, 20), t.value(9));
    try testing.expect(!t.done(1.2));
    try testing.expect(t.done(1.5));
}

test "retargeting mid-flight continues from the current value" {
    var t: Tween = .{ .from = 0, .to = 100, .start = 0, .dur = 1, .ease = .linear };
    t.retarget(0.25, 0, 1, .linear); // turn around a quarter of the way
    try testing.expectApproxEqAbs(@as(f32, 25), t.value(0.25), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 12.5), t.value(0.75), 1e-4);
    const before = t;
    t.retarget(0.5, 0, 1, .linear); // same target: unchanged
    try testing.expectEqual(before, t);
    const s = Tween.still(3);
    try testing.expect(s.done(0));
    try testing.expectEqual(@as(f32, 3), s.value(123));
}
