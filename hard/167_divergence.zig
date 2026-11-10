// HARD MODE (zig build -Dhard): no blanks to fill in. Every function
// marked ??? has lost its whole body: write it, from its doc comment,
// its signature and the tests. The gentler version of this file is in
// exercises/, and the answer in solutions/.
//
// ─── Exercise 167: warp divergence ────────────────────────────────────
//
// The 32 threads of a warp share ONE instruction stream: every cycle, they
// all execute the same instruction, each on its own data (NVIDIA calls
// this SIMT, "single instruction, multiple threads"). So what happens at
// an `if`?
//
//     if (x[i] > 0) { a(); } else { b(); }
//
// If all 32 threads agree, the warp just runs one branch. If they
// disagree, the warp runs BOTH, one after the other: first a() with the
// else-threads switched off (masked), then b() with the if-threads masked.
// Nothing is wrong, it's just slower: the warp pays for every path any of
// its threads takes. That's *divergence*. (Since Volta, each NVIDIA thread
// has its own program counter, which makes divergent code safer to write,
// but a warp still runs one path at a time.)
//
// The cost of a branch for one warp, then, is the sum of the costs of the
// distinct paths its threads take. Tricks to avoid it: make the data that
// decides the branch uniform per warp (sort or group it), or replace short
// branches with arithmetic, like where(cond, a, b), which is how tinygrad
// renders most conditionals anyway.
//
// YOUR TASK: find which paths a warp takes, and what the branch costs.
//
const std = @import("std");

const warp = 32;

/// Cost of `if (x > 0) cost_a else cost_b` for every warp in `xs`,
/// added up. xs.len is a multiple of 32.
fn branchCost(xs: []const f32, cost_a: u32, cost_b: u32) u32 {
    ???; // write this function's body
}

/// The same data, reordered so positives come first. Returns the cost.
fn sortedCost(alloc: std.mem.Allocator, xs: []const f32, cost_a: u32, cost_b: u32) !u32 {
    ???; // write this function's body
}

test "uniform warps pay for one path" {
    var xs: [64]f32 = undefined;
    for (&xs, 0..) |*x, i| x.* = if (i < 32) 1 else -1;
    // warp 0 all positive, warp 1 all negative
    try std.testing.expectEqual(10 + 30, branchCost(&xs, 10, 30));
}

test "alternating signs: every warp pays for both" {
    var xs: [64]f32 = undefined;
    for (&xs, 0..) |*x, i| x.* = if (i % 2 == 0) 1 else -1;
    try std.testing.expectEqual(2 * (10 + 30), branchCost(&xs, 10, 30));
}

test "sorting the data removes the divergence" {
    var xs: [128]f32 = undefined;
    for (&xs, 0..) |*x, i| x.* = if (i % 2 == 0) 1 else -1;
    try std.testing.expectEqual(4 * 40, branchCost(&xs, 10, 30));
    // 64 positives then 64 negatives: two warps each way
    try std.testing.expectEqual(2 * 10 + 2 * 30, try sortedCost(std.testing.allocator, &xs, 10, 30));
}
