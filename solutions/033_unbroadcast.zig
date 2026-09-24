// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 033: the gradient of a broadcast ─────────────────────────
//
// Chapter 6 takes backprop from single numbers to whole tensors. Most
// rules carry over elementwise: for c = a * b, a.grad[i] += c.grad[i] *
// b[i]. The interesting ones are the movement ops. First: broadcasting.
//
// Adding a bias b [3] to a batch x [2, 3] expands b to [2, 3]
// (exercise 012). Each number of b is used once per row, so by the +=
// rule (exercise 030) its grad is the SUM of the grads of all its copies:
//
//     grad arriving at the [2, 3] result:   | 1 2 3 |
//                                           | 4 5 6 |
//
//     grad for b [3]:                       [ 5 7 9 ]    summed over rows
//
// The rule: sum over every dimension that was broadcast, whether it was
// added in front or stretched from size 1. That brings the grad back to
// the input's shape. The gradient of expand is a sum (and the gradient of
// a sum is an expand, as the intro lesson showed).
//
// YOUR TASK: finish unbroadcast(). For each grad element, work out which
// element of the original tensor it's a copy of, and add it there.
//
const std = @import("std");

const max_dims = 4;

fn unravel(flat: usize, shape: []const usize, idx: []usize) void {
    var rest = flat;
    var k = shape.len;
    while (k > 0) {
        k -= 1;
        idx[k] = rest % shape[k];
        rest /= shape[k];
    }
}

/// `grad` has shape `from`. The tensor it's for had shape `to`, and was
/// broadcast up to `from`. Write the gradient for that tensor into `out`.
fn unbroadcast(grad: []const f32, from: []const usize, to: []const usize, out: []f32) void {
    @memset(out, 0);
    const lead = from.len - to.len; // dimensions that were added in front
    var idx: [max_dims]usize = undefined;
    for (grad, 0..) |g, flat| {
        unravel(flat, from, idx[0..from.len]);
        // Where is this element's original? Go through `to`'s dimensions,
        // building the position like exercise 007 (row-major).
        var pos: usize = 0;
        for (to, 0..) |size, k| {
            const i = idx[lead + k];
            // A stretched size-1 dimension: every copy came from index 0.
            const original_i = if (size == 1) 0 else i;
            pos = pos * size + original_i;
        }
        out[pos] += g;
    }
}

const arriving = [_]f32{ 1, 2, 3, 4, 5, 6 }; // shape [2, 3]

test "a bias [3], broadcast over rows" {
    var out: [3]f32 = undefined;
    unbroadcast(&arriving, &.{ 2, 3 }, &.{3}, &out);
    try std.testing.expectEqualSlices(f32, &.{ 5, 7, 9 }, &out);
}

test "shape [1, 3] works the same" {
    var out: [3]f32 = undefined;
    unbroadcast(&arriving, &.{ 2, 3 }, &.{ 1, 3 }, &out);
    try std.testing.expectEqualSlices(f32, &.{ 5, 7, 9 }, &out);
}

test "a column [2, 1], broadcast over columns" {
    var out: [2]f32 = undefined;
    unbroadcast(&arriving, &.{ 2, 3 }, &.{ 2, 1 }, &out);
    try std.testing.expectEqualSlices(f32, &.{ 6, 15 }, &out);
}

test "a scalar, broadcast to everything" {
    var out: [1]f32 = undefined;
    unbroadcast(&arriving, &.{ 2, 3 }, &.{}, &out);
    try std.testing.expectEqualSlices(f32, &.{21}, &out);
}

test "no broadcast, no change" {
    var out: [6]f32 = undefined;
    unbroadcast(&arriving, &.{ 2, 3 }, &.{ 2, 3 }, &out);
    try std.testing.expectEqualSlices(f32, &arriving, &out);
}
