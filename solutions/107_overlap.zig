// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 107: overlapping copies and compute ──────────────────────
//
// Feeding a GPU: each batch must be copied from CPU memory to the GPU
// (over PCIe, which is slow) and then computed on. Done one after the
// other:
//
//     copy 0 | compute 0 | copy 1 | compute 1 | copy 2 | compute 2
//
// But the copy engine and the compute engine are separate hardware (106)!
// While batch i computes, batch i+1 can already be copying:
//
//     copy:     | c0 | c1 | c2 |
//     compute:       | k0 | k1 | k2 |
//
// For n batches with copy time c and compute time k:
//
//     sequential:  n * (c + k)
//     overlapped:  c + (n - 1) * max(c, k) + k
//
// (The first copy and the last compute are exposed. In between, each step
// takes as long as the SLOWER engine.) Double buffering (two buffers, one
// being filled while the other is used) is what makes this possible.
//
// The simulation checks the formula: two engines, each running its jobs
// in order. A compute can start only when its own copy is finished AND
// the compute engine is free.
//
// YOUR TASK: write both formulas and the compute start time.
//
const std = @import("std");

fn sequential(n: f64, c: f64, k: f64) f64 {
    return n * (c + k);
}

fn overlapped(n: f64, c: f64, k: f64) f64 {
    return c + (n - 1) * @max(c, k) + k;
}

/// When the last compute finishes, simulating both engines.
fn simulate(n: usize, c: f64, k: f64) f64 {
    var copy_free: f64 = 0; //    when the copy engine is next idle
    var compute_free: f64 = 0; // when the compute engine is next idle
    for (0..n) |_| {
        const copy_done = copy_free + c;
        copy_free = copy_done;
        const start = @max(copy_done, compute_free);
        compute_free = start + k;
    }
    return compute_free;
}

test "the formulas" {
    try std.testing.expectEqual(30, sequential(10, 1, 2));
    try std.testing.expectEqual(21, overlapped(10, 1, 2)); // compute-bound: mostly hidden copies
    try std.testing.expectEqual(21, overlapped(10, 2, 1)); // copy-bound: the same, mirrored
}

test "the simulation agrees" {
    for ([_][2]f64{ .{ 1, 2 }, .{ 2, 1 }, .{ 3, 3 }, .{ 0.5, 4 } }) |ck| {
        try std.testing.expectApproxEqAbs(overlapped(10, ck[0], ck[1]), simulate(10, ck[0], ck[1]), 1e-12);
    }
}
