//
// ─── Exercise 047: reducing in parallel ────────────────────────────────
//
// A sum looks hopelessly sequential: each add needs the previous result.
// But addition is associative (well, almost: exercise 002!), so we can
// regroup it as a tree:
//
//     step 1:   x0+x1   x2+x3   x4+x5   x6+x7      4 adds, all at once
//     step 2:      a+b             c+d             2 adds, all at once
//     step 3:            everything                1 add
//
// n numbers take only log2(n) steps if you have enough workers. That's how
// a GPU reduces: each thread sums a piece, then the partial sums are
// combined in halves (tinygrad's GROUP optimizations split a reduce like
// this across the threads of a workgroup).
//
// A bonus: the tree is also more ACCURATE. Adding 0.1 a million times in
// order, the running total gets big and swallows the small 0.1s (002).
// In the tree, numbers of similar size get added together, and the
// rounding error grows like log(n) instead of n.
//
// Odd counts: if a level has an odd number of values, the last one moves
// up to the next level untouched.
//
// YOUR TASK: finish treeSum(). It works in place, halving `x` each step.
//
const std = @import("std");

/// Sums x (destroying it). Returns the sum and how many steps it took.
fn treeSum(x: []f32) struct { sum: f32, steps: usize } {
    var n = x.len;
    var steps: usize = 0;
    while (n > 1) {
        const half = n / 2;
        for (0..half) |i| {
            x[i] = ???;
        }
        if (n % 2 == 1) {
            // the odd one out moves up a level
            x[half] = ???;
        }
        n = ???;
        steps += 1;
    }
    return .{ .sum = if (x.len == 0) 0 else x[0], .steps = steps };
}

test "small sums" {
    var a = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const r = treeSum(&a);
    try std.testing.expectEqual(36, r.sum);
    try std.testing.expectEqual(3, r.steps); // log2(8)

    var b = [_]f32{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(15, treeSum(&b).sum);

    var c = [_]f32{42};
    try std.testing.expectEqual(42, treeSum(&c).sum);
}

test "a million numbers in 20 steps, and more accurately" {
    const n = 1 << 20;
    const x = try std.testing.allocator.alloc(f32, n);
    defer std.testing.allocator.free(x);
    @memset(x, 0.1);

    var sequential: f32 = 0;
    for (x) |v| sequential += v;

    const r = treeSum(x);
    const exact = 0.1 * @as(f64, n);
    try std.testing.expectEqual(20, r.steps);
    try std.testing.expect(@abs(sequential - exact) > 100); // way off!
    try std.testing.expect(@abs(r.sum - exact) < 1);
}
