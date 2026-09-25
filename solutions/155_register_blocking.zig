// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 155: register blocking ───────────────────────────────────
//
// Registers are the fastest memory of all, and each thread has a limited
// number of them. In a matmul, let each thread compute an a x b block of
// outputs (UPCAST, 079). Per step of k it:
//
//     loads a values of A and b values of B        (a + b loads)
//     does a * b multiply-adds                      (every pair)
//
// so its arithmetic intensity (044) is a*b / (a + b): bigger blocks reuse
// each loaded value more. But the accumulators (a*b) and the loaded
// values (a + b) all need registers:
//
//     a*b + a + b <= register budget
//
// Picking the block shape is a small optimization problem, and exactly
// the kind of choice BEAM search (048) makes by timing real kernels.
//
// YOUR TASK: write the intensity and the register check, and search.
//
const std = @import("std");

fn intensity(a: usize, b: usize) f64 {
    return @as(f64, @floatFromInt(a * b)) / @as(f64, @floatFromInt(a + b));
}

fn fits(a: usize, b: usize, budget: usize) bool {
    return a * b + a + b <= budget;
}

fn bestBlock(budget: usize) [2]usize {
    var best: [2]usize = .{ 1, 1 };
    for (1..budget) |a| {
        for (1..budget) |b| {
            if (fits(a, b, budget) and intensity(a, b) > intensity(best[0], best[1])) best = .{ a, b };
        }
    }
    return best;
}

test "bigger blocks reuse more" {
    try std.testing.expectApproxEqAbs(0.5, intensity(1, 1), 1e-12);
    try std.testing.expectApproxEqAbs(2.0, intensity(4, 4), 1e-12);
}

test "the best block for 64 registers" {
    const b = bestBlock(64);
    try std.testing.expectEqual([2]usize{ 7, 7 }, b); // 49 + 14 = 63 registers
    try std.testing.expectApproxEqAbs(3.5, intensity(b[0], b[1]), 1e-12);
}
