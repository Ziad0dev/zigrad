// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 034: gradients of movement ops ───────────────────────────
//
// Movement ops only move numbers around. So their gradients just move the
// grad numbers back to where they came from:
//
//     y = reshape(x)     dx = reshape dy back to x's shape
//     y = permute(x, o)  dx = permute dy by the INVERSE order of o
//     y = expand(x)      dx = sum (exercise 033)
//     y = pad(x)         dx = shrink dy: cut the padding's grads off,
//                             because padding zeros don't depend on x
//     y = shrink(x)      dx = pad dy with zeros: the cut-off elements
//                             didn't affect y at all
//     y = flip(x)        dx = flip dy again
//
// So pad and shrink are each other's gradients, just like sum and expand.
//
// The maths behind it: a movement op is a *linear map*, some matrix A
// with y = A x, and its gradient is the transpose, dx = Aᵀ dy. One way to
// test a gradient rule, then, is the *dot-product test*: for any x and dy,
//
//     dot(A x, dy) == dot(x, Aᵀ dy)
//
// The last test below does exactly that for pad and shrink.
//
// YOUR TASK: write the four gradient functions (1-D, to keep it simple).
//
const std = @import("std");

/// permute(order) puts old dimension order[i] at new position i.
/// Its inverse puts each one back: inv[order[i]] = i.
fn inversePermutation(order: []const usize, inv: []usize) void {
    for (order, 0..) |old, new| inv[old] = new;
}

/// y = pad(x, before, after). Given dy, compute dx.
fn padGrad(dy: []const f32, before: usize, after: usize, dx: []f32) void {
    @memcpy(dx, dy[before .. dy.len - after]);
}

/// y = x[start..end]. Given dy, compute dx.
fn shrinkGrad(dy: []const f32, start: usize, end: usize, dx: []f32) void {
    @memset(dx, 0);
    @memcpy(dx[start..end], dy);
}

/// y = flip(x). Given dy, compute dx.
fn flipGrad(dy: []const f32, dx: []f32) void {
    for (dx, 0..) |*d, i| d.* = dy[dy.len - 1 - i];
}

fn dot(a: []const f32, b: []const f32) f32 {
    var acc: f32 = 0;
    for (a, b) |x, y| acc += x * y;
    return acc;
}

test "inverse permutation" {
    var inv: [3]usize = undefined;
    inversePermutation(&.{ 2, 0, 1 }, &inv);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 0 }, &inv);

    // Permute a shape, then permute it by the inverse: back where we began.
    const shape = [_]usize{ 5, 6, 7 };
    const order = [_]usize{ 2, 0, 1 };
    var permuted: [3]usize = undefined;
    for (&permuted, order) |*p, o| p.* = shape[o];
    var back: [3]usize = undefined;
    for (&back, inv) |*b, o| b.* = permuted[o];
    try std.testing.expectEqualSlices(usize, &shape, &back);
}

test "pad and shrink" {
    var dx3: [3]f32 = undefined;
    padGrad(&.{ 1, 2, 3, 4, 5, 6 }, 1, 2, &dx3);
    try std.testing.expectEqualSlices(f32, &.{ 2, 3, 4 }, &dx3);

    var dx5: [5]f32 = undefined;
    shrinkGrad(&.{ 7, 8 }, 1, 3, &dx5);
    try std.testing.expectEqualSlices(f32, &.{ 0, 7, 8, 0, 0 }, &dx5);
}

test "flip" {
    var dx: [4]f32 = undefined;
    flipGrad(&.{ 1, 2, 3, 4 }, &dx);
    try std.testing.expectEqualSlices(f32, &.{ 4, 3, 2, 1 }, &dx);
}

test "dot-product test: pad and shrink are transposes" {
    const x = [_]f32{ 1.5, -2, 3 };
    const dy = [_]f32{ 0.5, 4, -1, 2, 7, -3 };

    // y = pad(x, 1, 2)
    const y = [_]f32{ 0, 1.5, -2, 3, 0, 0 };
    var dx: [3]f32 = undefined;
    padGrad(&dy, 1, 2, &dx);
    try std.testing.expectEqual(dot(&y, &dy), dot(&x, &dx));

    // y2 = dy[2..5], a shrink of the 6-long vector dy, and its transpose
    var back: [6]f32 = undefined;
    shrinkGrad(&x, 2, 5, &back);
    try std.testing.expectEqual(dot(dy[2..5], &x), dot(&dy, &back));
}
