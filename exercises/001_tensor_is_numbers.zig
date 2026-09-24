//
// Welcome to zigrad!
//
// You're going to rebuild tinygrad, a tiny deep learning library, one
// small exercise at a time. Every exercise is broken on purpose: read the
// comments, fix the code, run `zig build`, and move on to the next one.
//
// ─── Exercise 001: a tensor is numbers in a row ───────────────────────
//
// "Tensor" sounds scary, but in tinygrad (and PyTorch, and NumPy) a
// tensor is only two things:
//
//     1. a flat list of numbers in memory
//     2. a *shape* that says how to read that list
//
// This 2x3 matrix...          ...is stored in memory as one row:
//
//     | 1 2 3 |
//     | 4 5 6 |                   [ 1 2 3 4 5 6 ]
//
// For now we only care about part 1, the numbers.
//
// Zig notes:
//   * `[6]f32` is an array of exactly six 32-bit floats.
//   * `[]const f32` is a *slice*: a pointer plus a length. Functions take
//     slices so they work for any length. `&array` turns an array into one.
//   * `for (data) |x| { ... }` runs the body once for every number x.
//
// YOUR TASK: replace each ??? so the test at the bottom passes.
//
const std = @import("std");

/// How many numbers the tensor holds. tinygrad calls this `numel`
/// ("number of elements").
fn numel(data: []const f32) usize {
    return ???;
}

/// Add up every number.
fn sum(data: []const f32) f32 {
    var total: f32 = 0;
    for (data) |x| {
        ???;
    }
    return total;
}

test "a tensor is numbers in a row" {
    const matrix = [_]f32{ 1, 2, 3, 4, 5, 6 };
    try std.testing.expectEqual(6, numel(&matrix));
    try std.testing.expectEqual(21, sum(&matrix));
}
