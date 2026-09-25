//
// ─── Exercise 139: pipeline parallelism ────────────────────────────────
//
// Another way to split a model: by LAYERS. Device 0 runs layers 1-10,
// device 1 layers 11-20, and so on: p *stages*. One batch would leave all
// but one device idle at any moment, so split the batch into m
// micro-batches (136) and pipeline them like an assembly line:
//
//     time:      1   2   3   4   5   6
//     stage 0:   m1  m2  m3  m4
//     stage 1:       m1  m2  m3  m4
//     stage 2:           m1  m2  m3  m4
//
// Micro-batch i reaches stage s at time slot i + s. The whole thing takes
// m + p - 1 slots, but each stage is busy for only m of them. The idle
// slots are the *bubble*:
//
//     bubble fraction = (p - 1) / (m + p - 1)
//
// More micro-batches means a smaller bubble. (The GPipe paper, 2018.
// Schedules like 1F1B interleave backward passes to also cut memory.)
//
// YOUR TASK: simulate the schedule, and write the bubble formula.
//
const std = @import("std");

fn bubble(p: f64, m: f64) f64 {
    return ???;
}

/// Fraction of (stage, slot) cells that are idle, by simulation.
fn simulate(p: usize, m: usize) f64 {
    const slots = ???;
    var busy: usize = 0;
    for (0..p) |stage| {
        for (0..slots) |t| {
            // is some micro-batch i at this stage at time t? (t = i + stage)
            if (???) busy += 1;
        }
    }
    const total = p * slots;
    return @as(f64, @floatFromInt(total - busy)) / @as(f64, @floatFromInt(total));
}

test "the bubble" {
    try std.testing.expectApproxEqAbs(0.5, bubble(4, 3), 1e-12); // 3 / 6
    try std.testing.expectApproxEqAbs(bubble(4, 3), simulate(4, 3), 1e-12);
    try std.testing.expectApproxEqAbs(bubble(8, 32), simulate(8, 32), 1e-12);
    try std.testing.expect(bubble(8, 64) < 0.1); // enough micro-batches: small bubble
}
