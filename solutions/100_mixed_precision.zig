// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 100: mixed precision ─────────────────────────────────────
//
// Training in f16 is about twice as fast as f32 (044, 049, 080). But f16
// has a tiny range: nothing below about 6e-8 survives (it rounds to 0),
// and nothing above 65504 (it becomes inf). Tiny gradients are common,
// and in f16 the smallest of them would silently vanish.
//
// The standard recipe ("mixed precision"):
//   1. keep a master copy of the weights in f32
//   2. do the forward and backward passes in f16
//   3. LOSS SCALING: multiply the loss by a big S (like 65536) before
//      backward. Every gradient gets multiplied by S too (the chain rule
//      is linear), lifting them out of the underflow zone
//   4. convert the gradients to f32, divide by S, update the master
//      weights
//
// Dynamic scaling picks S automatically: if any gradient came out inf
// or nan, S was too big, so skip this step and halve S. After a run of
// good steps, double it again to use as much of the range as possible.
//
// (bf16, 049, has f32's range, so it usually doesn't need loss scaling.
// That's much of why it took over.)
//
// YOUR TASK: write roundTrip(), and the Scaler's update.
//
const std = @import("std");

/// A gradient stored in f16 with loss scaling S, then recovered in f32.
fn roundTrip(grad: f32, scale: f32) f32 {
    const stored: f16 = @floatCast(grad * scale);
    return @as(f32, stored) / scale;
}

const Scaler = struct {
    scale: f32 = 65536,
    good_steps: usize = 0,
    interval: usize = 3, // grow after this many good steps in a row

    /// Look at this step's f16 gradients. Returns whether to apply the step.
    fn update(s: *Scaler, grads: []const f16) bool {
        for (grads) |g| {
            if (std.math.isInf(g) or std.math.isNan(g)) {
                s.scale /= 2;
                s.good_steps = 0;
                return false;
            }
        }
        s.good_steps += 1;
        if (s.good_steps == s.interval) {
            s.scale *= 2;
            s.good_steps = 0;
        }
        return true;
    }
};

test "without scaling, small gradients vanish" {
    try std.testing.expectEqual(0, roundTrip(1e-8, 1));
    try std.testing.expectApproxEqRel(1e-8, roundTrip(1e-8, 1024), 0.05);
}

test "overflow: skip the step, halve the scale" {
    var s: Scaler = .{};
    const huge: f16 = @floatCast(@as(f32, 100) * s.scale); // 6.5 million: inf in f16
    try std.testing.expect(!s.update(&.{ 0.5, huge }));
    try std.testing.expectEqual(32768, s.scale);
}

test "a run of good steps grows the scale" {
    var s: Scaler = .{ .scale = 1024 };
    const ok = [_]f16{ 0.1, -3 };
    try std.testing.expect(s.update(&ok));
    try std.testing.expect(s.update(&ok));
    try std.testing.expectEqual(1024, s.scale);
    try std.testing.expect(s.update(&ok));
    try std.testing.expectEqual(2048, s.scale);
}
