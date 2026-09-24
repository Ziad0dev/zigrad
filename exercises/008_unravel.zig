//
// ─── Exercise 008: from memory back to index ───────────────────────────
//
// Now the other way round: which [row, column] is memory position 5?
// Divide and take remainders, from the last dimension to the first:
//
//     shape [2, 3], position 5:
//         column = 5 % 3 = 2         rest = 5 / 3 = 1
//         row    = 1 % 2 = 1         rest = 1 / 2 = 0
//     index = [1, 2]  ✓
//
// It's exactly how you turn seconds into a clock time. 3725 seconds with
// "shape" [24, 60, 60] (hours, minutes, seconds):
//
//         seconds = 3725 % 60 = 5    rest = 3725 / 60 = 62
//         minutes =   62 % 60 = 2    rest =   62 / 60 = 1
//         hours   =    1 % 24 = 1
//     01:02:05
//
// So a shape is a number system where each digit has its own base, and
// unravel() splits a number into its digits. We'll use it constantly to
// visit every element of a tensor in order.
//
// (% is remainder and / is whole-number division when used on integers.)
//
// YOUR TASK: fill in the two lines in the loop.
//
const std = @import("std");

fn unravel(flat: usize, shape: []const usize, idx: []usize) void {
    var rest = flat;
    var k = shape.len;
    while (k > 0) {
        k -= 1;
        idx[k] = ???;
        rest = ???;
    }
}

// From exercise 007.
fn position(idx: []const usize, strides: []const usize) usize {
    var pos: usize = 0;
    for (idx, strides) |i, s| pos += i * s;
    return pos;
}

test "clock" {
    var idx: [3]usize = undefined;
    unravel(3725, &.{ 24, 60, 60 }, &idx);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 5 }, &idx);
}

test "unravel undoes position" {
    const shape = [_]usize{ 2, 3, 4 };
    const strides = [_]usize{ 12, 4, 1 };
    var idx: [3]usize = undefined;
    for (0..24) |flat| {
        unravel(flat, &shape, &idx);
        try std.testing.expectEqual(flat, position(&idx, &strides));
    }
}
