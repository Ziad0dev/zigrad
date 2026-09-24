//
// ─── Exercise 007: from index to memory ────────────────────────────────
//
// With strides, finding any element is one formula. For the index
// [i0, i1, i2, ...]:
//
//     position = i0 * stride0 + i1 * stride1 + i2 * stride2 + ...
//
// Row 1, column 2 of our 2x3 matrix (strides [3, 1]):
//
//     position = 1*3 + 2*1 = 5          memory[5] = 6  ✓
//
//     | 1 2 3 |          memory: [ 1 2 3 4 5 6 ]
//     | 4 5 6 |                              ^
//
// Multiplying two lists pairwise and adding up the results is called a
// *dot product*. Keep an eye out for dot products: matrix multiplication
// (exercise 019) is nothing but a big grid of them.
//
// YOUR TASK: finish position().
//
const std = @import("std");

fn position(idx: []const usize, strides: []const usize) usize {
    var pos: usize = 0;
    for (idx, strides) |i, s| {
        pos += ???;
    }
    return pos;
}

test "2x3 matrix" {
    const memory = [_]f32{ 1, 2, 3, 4, 5, 6 };
    const strides = [_]usize{ 3, 1 };
    try std.testing.expectEqual(1, memory[position(&.{ 0, 0 }, &strides)]);
    try std.testing.expectEqual(4, memory[position(&.{ 1, 0 }, &strides)]);
    try std.testing.expectEqual(6, memory[position(&.{ 1, 2 }, &strides)]);
}

test "2x2x2 cube" {
    const memory = [_]f32{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const strides = [_]usize{ 4, 2, 1 };
    try std.testing.expectEqual(5, memory[position(&.{ 1, 0, 1 }, &strides)]);
    try std.testing.expectEqual(6, memory[position(&.{ 1, 1, 0 }, &strides)]);
}
