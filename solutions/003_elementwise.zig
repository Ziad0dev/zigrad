// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 003: elementwise ops, your first kernels ─────────────────
//
// An *elementwise* op does the same thing at every position:
//
//     a        = [ 1  2  3 ]
//     b        = [10 20 30 ]
//     add(a,b) = [11 22 33 ]          out[i] = a[i] + b[i]
//
// That loop is what tinygrad calls a *kernel*: one small program that is
// run for every index i. On a GPU, thousands of i's run at the same time.
//
// Zig notes:
//   * `for (out, a, b) |*o, x, y|` walks three slices side by side. They
//     must all have the same length.
//   * `|*o|` gives a pointer to each slot of `out`, and `o.* = ...` writes
//     through that pointer.
//
// YOUR TASK: finish mul, relu and mulAdd.
//
const std = @import("std");

fn add(out: []f32, a: []const f32, b: []const f32) void {
    for (out, a, b) |*o, x, y| o.* = x + y;
}

fn mul(out: []f32, a: []const f32, b: []const f32) void {
    for (out, a, b) |*o, x, y| o.* = x * y;
}

/// ReLU ("rectified linear unit") is the most common activation function
/// in neural networks: positive numbers pass, negative numbers become 0.
/// In other words relu(x) = max(x, 0). Zig has a builtin @max(a, b).
fn relu(out: []f32, a: []const f32) void {
    for (out, a) |*o, x| o.* = @max(x, 0);
}

/// out = a * b + c, in ONE loop.
///
/// You could call mul() and then add(), but that writes a temporary array
/// to memory and reads it straight back. Doing everything in one pass is
/// called *fusion*. It's one of tinygrad's main tricks, and chapter 8 is
/// all about it.
fn mulAdd(out: []f32, a: []const f32, b: []const f32, c: []const f32) void {
    for (out, a, b, c) |*o, x, y, z| o.* = x * y + z;
}

test "elementwise ops" {
    const a = [_]f32{ 1, -2, 3 };
    const b = [_]f32{ 10, 20, 30 };
    var out: [3]f32 = undefined;

    add(&out, &a, &b);
    try std.testing.expectEqualSlices(f32, &.{ 11, 18, 33 }, &out);

    mul(&out, &a, &b);
    try std.testing.expectEqualSlices(f32, &.{ 10, -40, 90 }, &out);

    relu(&out, &a);
    try std.testing.expectEqualSlices(f32, &.{ 1, 0, 3 }, &out);

    mulAdd(&out, &a, &b, &a);
    try std.testing.expectEqualSlices(f32, &.{ 11, -42, 93 }, &out);
}
