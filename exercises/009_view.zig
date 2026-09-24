//
// ─── Exercise 009: views ───────────────────────────────────────────────
//
// Put shape + strides together, add an *offset* (where element [0, 0, ...]
// lives in memory), and you have a *view*:
//
//     position(idx) = offset + idx[0]*strides[0] + idx[1]*strides[1] + ...
//
// Here's the magic: the SAME memory can be read through DIFFERENT views.
//
//     memory: [ 1 2 3 4 5 6 ]
//
//     shape [2, 3], strides [3, 1], offset 0     | 1 2 3 |
//                                                | 4 5 6 |
//
//     shape [3],    strides [1],    offset 3     [ 4 5 6 ]   (just row 1)
//
//     shape [3, 2], strides [1, 3], offset 0     | 1 4 |
//                                                | 2 5 |     (transposed!)
//                                                | 3 6 |
//
// Nothing was copied to make those. tinygrad tracks a view like this for
// its tensors (for years in objects called `View` and `ShapeTracker`;
// newer versions write the same index maths straight into their graph).
// It only copies data when it really has to.
//
// "Really have to" is `contiguous()`: it reads a view in order and writes
// the numbers into a fresh buffer, so they're plain row-major again.
// tinygrad's Tensor has a method with the same name.
//
// Zig notes:
//   * strides and offset are `isize` (signed) because in exercise 013
//     they go negative. `@intCast` converts between integer types (and
//     crashes in debug builds if the value doesn't fit).
//   * A View holds fixed-size arrays, so it's a small value you can copy
//     around freely, just like tinygrad's (immutable) views.
//
// YOUR TASK: position() has a bug, and contiguous() is unfinished.
//
const std = @import("std");

const max_dims = 4;

const View = struct {
    ndim: usize,
    shape: [max_dims]usize = @splat(0),
    strides: [max_dims]isize = @splat(0),
    offset: isize = 0,

    fn make(shape: []const usize, strides: []const isize, offset: isize) View {
        var v: View = .{ .ndim = shape.len, .offset = offset };
        @memcpy(v.shape[0..shape.len], shape);
        @memcpy(v.strides[0..strides.len], strides);
        return v;
    }

    /// Where in memory the element at `idx` lives.
    fn position(v: View, idx: []const usize) usize {
        var pos: isize = 0;
        for (idx, v.strides[0..v.ndim]) |i, s| {
            pos += @as(isize, @intCast(i)) * s;
        }
        return @intCast(pos);
    }
};

// From exercise 008.
fn unravel(flat: usize, shape: []const usize, idx: []usize) void {
    var rest = flat;
    var k = shape.len;
    while (k > 0) {
        k -= 1;
        idx[k] = rest % shape[k];
        rest /= shape[k];
    }
}

/// Read the view's elements in logical order (row by row) into `out`.
fn contiguous(v: View, data: []const f32, out: []f32) void {
    var idx: [max_dims]usize = undefined;
    for (out, 0..) |*o, flat| {
        // Which element of the view is number `flat`?
        unravel(flat, v.shape[0..v.ndim], idx[0..v.ndim]);
        // Read it from memory.
        o.* = ???;
    }
}

const memory = [_]f32{ 1, 2, 3, 4, 5, 6 };

test "the plain 2x3 view" {
    var out: [6]f32 = undefined;
    contiguous(View.make(&.{ 2, 3 }, &.{ 3, 1 }, 0), &memory, &out);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4, 5, 6 }, &out);
}

test "row 1 only" {
    var out: [3]f32 = undefined;
    contiguous(View.make(&.{3}, &.{1}, 3), &memory, &out);
    try std.testing.expectEqualSlices(f32, &.{ 4, 5, 6 }, &out);
}

test "transposed, without moving anything" {
    var out: [6]f32 = undefined;
    contiguous(View.make(&.{ 3, 2 }, &.{ 1, 3 }, 0), &memory, &out);
    try std.testing.expectEqualSlices(f32, &.{ 1, 4, 2, 5, 3, 6 }, &out);
}
