//
// ─── Exercise 005: shapes ──────────────────────────────────────────────
//
// Chapter 2 is about part 2 of a tensor: the shape, and how it turns a
// flat row of numbers into rows, columns, and beyond.
//
// A *shape* lists the size of each dimension (tinygrad also says "axis"):
//
//     shape [3]        a list of 3 numbers             1 dimension
//     shape [2, 3]     2 rows of 3 numbers             2 dimensions
//     shape [4, 2, 3]  4 of those 2x3 matrices         3 dimensions
//     shape []         a single number, a "scalar"     0 dimensions
//
// How many numbers does a shape hold? Multiply the sizes:
// [4, 2, 3] holds 4 * 2 * 3 = 24.
//
// YOUR TASK: numel() below is wrong for EVERY shape. Find out why.
// Then think about the scalar, shape []: what's the product of no numbers
// at all? (Hint: the sum of no numbers is 0, the identity of +. What's
// the identity of *?)
//
const std = @import("std");

fn numel(shape: []const usize) usize {
    var n: usize = ⟪1|||0⟫;
    for (shape) |d| n *= d;
    return n;
}

/// The number of dimensions. tinygrad calls this `ndim`.
fn ndim(shape: []const usize) usize {
    return ⟪shape.len|||???⟫;
}

test "numel" {
    try std.testing.expectEqual(3, numel(&.{3}));
    try std.testing.expectEqual(6, numel(&.{ 2, 3 }));
    try std.testing.expectEqual(24, numel(&.{ 4, 2, 3 }));
    try std.testing.expectEqual(1, numel(&.{})); // a scalar is one number
    try std.testing.expectEqual(0, numel(&.{ 5, 0 })); // an empty tensor
}

test "ndim" {
    try std.testing.expectEqual(2, ndim(&.{ 2, 3 }));
    try std.testing.expectEqual(0, ndim(&.{}));
}
