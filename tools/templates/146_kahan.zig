//
// ─── Exercise 146: Kahan summation ─────────────────────────────────────
//
// Chapter 28: how kernels actually compute maths. First, adding up.
//
// Exercise 002 showed big numbers swallowing small ones, and 047 fixed it
// with a tree. *Kahan summation* fixes it in a plain loop, by keeping a
// second variable c that remembers what got rounded away:
//
//     y = x - c              correct the new value by last time's loss
//     t = sum + y            the rounded new sum
//     c = (t - sum) - y      what actually got added, minus what we wanted:
//                            the rounding error, recovered exactly
//     sum = t
//
// The error stays about one rounding step, no matter how many numbers you
// add. It costs 4 flops per element instead of 1, which is often free in
// a memory-bound kernel (044). (One catch: "fast-math" compiler flags let
// the optimizer simplify (t - sum) - y to 0 and silently undo the trick.
// Zig doesn't do that unless you ask it to.)
//
// YOUR TASK: write the Kahan loop.
//
const std = @import("std");

fn naiveSum(xs: []const f32) f32 {
    var sum: f32 = 0;
    for (xs) |x| sum += x;
    return sum;
}

fn kahanSum(xs: []const f32) f32 {
    var sum: f32 = 0;
    var c: f32 = 0;
    for (xs) |x| {
        const y = ⟪x - c|||???⟫;
        const t = ⟪sum + y|||???⟫;
        c = ⟪(t - sum) - y|||???⟫;
        sum = t;
    }
    return sum;
}

test "a million tenths" {
    const n = 1 << 20;
    const xs = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(xs);
    @memset(xs, 0.1);
    const exact = @as(f64, @as(f32, 0.1)) * n; // the f32 value 0.1, n times
    try std.testing.expect(@abs(naiveSum(xs) - exact) > 100);
    try std.testing.expect(@abs(kahanSum(xs) - exact) < 0.1);
}
