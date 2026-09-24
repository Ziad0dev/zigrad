//
// ─── Exercise 006: strides ─────────────────────────────────────────────
//
// Memory is one long row. So how do we find row 1, column 2 of a 2x3
// matrix?
//
//     | 1 2 3 |          memory: [ 1 2 3 4 5 6 ]
//     | 4 5 6 |                    0 1 2 3 4 5    <- positions
//
//     one column to the right  = 1 step in memory
//     one row down             = 3 steps in memory (skip a whole row)
//
// Those step sizes, one per dimension, are the *strides*: [3, 1].
//
// For a normal ("contiguous", "row-major") tensor, the last dimension
// has stride 1. Each earlier stride is the next stride times the next
// size:
//
//     shape   [4, 2, 3]
//     strides [6, 3, 1]        3 = 1 * 3,   6 = 3 * 2
//
// Strides are THE big idea of this chapter. Almost every "movement" op in
// tinygrad (transpose, broadcast, slice, flip) works by changing strides
// instead of moving any data.
//
// Zig note: `for` only counts upwards, so to walk the dimensions from
// last to first we use `while` and count down by hand.
//
// YOUR TASK: fill in the loop body.
//
const std = @import("std");

fn contiguousStrides(shape: []const usize, strides: []usize) void {
    var step: usize = 1;
    var i = shape.len;
    while (i > 0) {
        i -= 1;
        strides[i] = ???;
        step *= ???;
    }
}

fn expectStrides(shape: []const usize, expected: []const usize) !void {
    var strides: [8]usize = undefined;
    contiguousStrides(shape, strides[0..shape.len]);
    try std.testing.expectEqualSlices(usize, expected, strides[0..shape.len]);
}

test "contiguous strides" {
    try expectStrides(&.{ 2, 3 }, &.{ 3, 1 });
    try expectStrides(&.{ 4, 2, 3 }, &.{ 6, 3, 1 });
    try expectStrides(&.{5}, &.{1});
    try expectStrides(&.{}, &.{});
}
