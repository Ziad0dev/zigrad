//
// ─── Exercise 097: learning-rate schedules ─────────────────────────────
//
// One fixed learning rate is rarely best. Real training varies it:
//
//   WARMUP: start tiny and ramp up linearly for the first few hundred
//   steps. At the start the weights are random, gradients are wild, and
//   Adam's second-moment estimate (038) is still unreliable. Big steps
//   then can wreck a model before it has learned anything.
//
//   DECAY: shrink the learning rate toward the end, so the weights can
//   settle into the bottom of the valley instead of bouncing around it.
//   The most popular shape is a half cosine wave, from lr_max down to
//   lr_min:
//
//       progress = (t - warmup) / (total - warmup)      from 0 to 1
//       lr = lr_min + 0.5 (lr_max - lr_min) (1 + cos(π progress))
//
//   At progress 0 the cosine is 1 (lr = lr_max), and at progress 1 it's
//   -1 (lr = lr_min).
//
// YOUR TASK: write the warmup ramp and the cosine decay.
//
const std = @import("std");

const Schedule = struct {
    lr_max: f64,
    lr_min: f64,
    warmup: usize,
    total: usize,

    fn at(s: Schedule, t: usize) f64 {
        const tf: f64 = @floatFromInt(t);
        if (t < s.warmup) return ⟪s.lr_max * (tf + 1) / @as(f64, @floatFromInt(s.warmup))|||???⟫;
        const progress = (tf - @as(f64, @floatFromInt(s.warmup))) / @as(f64, @floatFromInt(s.total - s.warmup));
        return ⟪s.lr_min + 0.5 * (s.lr_max - s.lr_min) * (1 + @cos(std.math.pi * progress))|||???⟫;
    }
};

test "warmup, peak, halfway, end" {
    const s: Schedule = .{ .lr_max = 1e-3, .lr_min = 1e-5, .warmup = 100, .total = 1100 };
    try std.testing.expectApproxEqAbs(1e-5, s.at(0), 1e-12); //     step 1 of 100
    try std.testing.expectApproxEqAbs(5e-4, s.at(49), 1e-12);
    try std.testing.expectApproxEqAbs(1e-3, s.at(100), 1e-12); //   warmup done: the peak
    try std.testing.expectApproxEqAbs((1e-3 + 1e-5) / 2.0, s.at(600), 1e-12); // halfway down
    try std.testing.expectApproxEqAbs(1e-5, s.at(1100), 1e-12); //  the floor
}

test "it only goes up, then only down" {
    const s: Schedule = .{ .lr_max = 1, .lr_min = 0, .warmup = 10, .total = 100 };
    for (1..10) |t| try std.testing.expect(s.at(t) > s.at(t - 1));
    for (11..100) |t| try std.testing.expect(s.at(t) < s.at(t - 1));
}
