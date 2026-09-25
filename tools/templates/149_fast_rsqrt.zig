//
// ─── Exercise 149: the fast inverse square root ────────────────────────
//
// 1 / sqrt(x) is everywhere: normalizing vectors (054), LayerNorm (083),
// RMSNorm. The famous trick from Quake III (1999):
//
//   1. treat the float's bits as an integer. Since a float stores
//      (roughly) log2 of the number in its exponent bits, halving and
//      negating the integer approximates halving and negating the log:
//      x^(-1/2). The magic constant fixes up the offsets:
//          bits = 0x5f3759df - (bits >> 1)
//      That alone is within about 3.5%.
//
//   2. refine with Newton's method (070) on f(y) = 1/y² - x:
//          y = y * (1.5 - 0.5 * x * y * y)
//      Each step roughly doubles the correct digits.
//
// GPUs now have a hardware rsqrt instruction, but "a cheap guess, then a
// few Newton steps" is still how division, sqrt and friends are built.
//
// YOUR TASK: the bit trick and the Newton step.
//
const std = @import("std");

fn rsqrt(x: f32, newton_steps: usize) f32 {
    const bits: u32 = @bitCast(x);
    var y: f32 = @bitCast(⟪@as(u32, 0x5f3759df) - (bits >> 1)|||???⟫);
    for (0..newton_steps) |_| y = ⟪y * (1.5 - 0.5 * x * y * y)|||???⟫;
    return y;
}

fn relError(x: f32, steps: usize) f32 {
    const exact = 1 / @sqrt(x);
    return @abs(rsqrt(x, steps) - exact) / exact;
}

test "a rough guess, then Newton" {
    var worst: [3]f32 = @splat(0);
    var x: f32 = 0.01;
    while (x < 1000) : (x *= 1.07) {
        for (&worst, 0..) |*w, steps| w.* = @max(w.*, relError(x, steps));
    }
    try std.testing.expect(worst[0] < 0.035);
    try std.testing.expect(worst[1] < 0.002);
    try std.testing.expect(worst[2] < 5e-6);
}
