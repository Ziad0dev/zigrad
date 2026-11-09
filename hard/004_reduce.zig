// HARD MODE (zig build -Dhard): no blanks to fill in. Every function
// marked ??? has lost its whole body: write it, from its doc comment,
// its signature and the tests. The gentler version of this file is in
// exercises/, and the answer in solutions/.
//
// ─── Exercise 004: reduce ops ─────────────────────────────────────────
//
// A *reduce* op squashes many numbers into one:
//
//     sum([3, 1, 2])  = 6
//     max([3, 1, 2])  = 3
//     mean([3, 1, 2]) = 6 / 3 = 2
//
// Every reduce starts from a value that "changes nothing", called its
// *identity*:
//     for sum it's 0, because x + 0 = x
//     for max it's minus infinity, because max(x, -inf) = x for any x
//
// tinygrad has just three reduce primitives: sum, product and max
// (in its source, REDUCE with ADD, MUL or MAX). Everything else is built
// from them: mean is a sum divided by the count, and min flips the
// numbers' order (for floats, by negating them), takes the max, and
// flips back.
//
// YOUR TASK: finish mean(). Then run `zig build` again: max() has a bug,
// and one of the tests will catch it. Fix that too.
//
const std = @import("std");

fn sum(data: []const f32) f32 {
    var total: f32 = 0;
    for (data) |x| total += x;
    return total;
}

fn max(data: []const f32) f32 {
    ???; // write this function's body
}

fn mean(data: []const f32) f32 {
    ???; // write this function's body
}

test "sum" {
    try std.testing.expectEqual(6, sum(&.{ 3, 1, 2 }));
}

test "max" {
    try std.testing.expectEqual(3, max(&.{ 3, 1, 2 }));
    try std.testing.expectEqual(-1, max(&.{ -3, -1, -2 }));
}

test "mean" {
    try std.testing.expectEqual(2, mean(&.{ 3, 1, 2 }));
    try std.testing.expectEqual(1.5, mean(&.{ 1, 2 }));
}
