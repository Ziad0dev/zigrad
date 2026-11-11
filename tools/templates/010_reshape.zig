//
// ─── Exercise 010: reshape ─────────────────────────────────────────────
//
// Exercises 010 to 014 are the *movement ops*: tinygrad's ops that
// rearrange a tensor. The punchline of all five: they only build a new
// view. Not one number gets copied.
//
// First up, reshape: same numbers, same order, new shape.
//
//     [ 1 2 3 4 5 6 ]   reshape [2, 3] ->  | 1 2 3 |   reshape [3, 2] -> | 1 2 |
//                                          | 4 5 6 |                     | 3 4 |
//                                                                        | 5 6 |
//
// For a contiguous view, that's easy: keep the offset and use fresh
// contiguous strides for the new shape (exercise 006, available below as
// View.init).
//
// Handy extra: one size may be -1, meaning "whatever makes it fit".
// 6 numbers reshaped to [3, -1] become [3, 2], because 6 / 3 = 2.
// tinygrad, NumPy and PyTorch all allow this.
//
// (What if the view ISN'T contiguous, e.g. transposed? New strides can't
// always describe that. NumPy and PyTorch's reshape then make a copy.
// tinygrad never does: older versions stacked a second view on top of
// the first (exercise 074), and newer ones compose the index maths (073).)
//
// Zig notes: this is our first function that can fail. `error{ShapeMismatch}!View`
// means "a View, or the error ShapeMismatch". `return error.ShapeMismatch`
// fails, and callers write `try` to pass errors on.
//
// YOUR TASK: finish inferShape() and reshape().
//
const std = @import("std");

const View = struct {
//@include view_core

    /// Same memory, new shape.
    fn reshape(v: View, shape: []const usize) error{ShapeMismatch}!View {
        if (product(shape) != v.numel()) return error.ShapeMismatch;
        std.debug.assert(v.isContiguous());
        var out = ⟪View.init(shape)|||???⟫;
        out.offset = v.offset;
        return out;
    }
};

/// Replace a -1 in `shape` with the size that makes `numel` fit. At
/// most one -1, and no other negative sizes.
fn inferShape(numel: usize, shape: []const isize, out: []usize) error{ShapeMismatch}!void {
    var known: usize = 1;
    var unknown_axis: ?usize = null;
    for (shape, 0..) |d, i| {
        if (d == -1 and unknown_axis == null) {
            unknown_axis = i;
        } else {
            if (d < 0) return error.ShapeMismatch;
            out[i] = @intCast(d);
            known *= out[i];
        }
    }
    if (unknown_axis) |i| {
        // [0, -1] could be any size at all: there is no answer
        if (known == 0) return error.ShapeMismatch;
        out[i] = ⟪numel / known|||???⟫;
    }
    // Not every shape works. With a -1, the division may not come out
    // whole: 6 numbers can't be [4, -1]. Without one, the sizes may just
    // be wrong: 6 numbers can't be [1, 2] either. One check covers both.
    if (⟪product(out[0..shape.len]) != numel|||???⟫) return error.ShapeMismatch;
}

//@include view_helpers

test "infer a -1" {
    var out: [2]usize = undefined;
    try inferShape(6, &.{ 3, -1 }, &out);
    try std.testing.expectEqualSlices(usize, &.{ 3, 2 }, &out);
    try inferShape(6, &.{ -1, 6 }, &out);
    try std.testing.expectEqualSlices(usize, &.{ 1, 6 }, &out);
    try std.testing.expectError(error.ShapeMismatch, inferShape(6, &.{ 4, -1 }, &out));
    // no -1 at all: the sizes are checked as they are
    try inferShape(6, &.{ 2, 3 }, &out);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, &out);
    try std.testing.expectError(error.ShapeMismatch, inferShape(6, &.{ 1, 2 }, &out));
    try std.testing.expectError(error.ShapeMismatch, inferShape(6, &.{ 1, 3 }, &out));
    // shapes that make no sense
    try std.testing.expectError(error.ShapeMismatch, inferShape(6, &.{ -1, -1 }, &out));
    try std.testing.expectError(error.ShapeMismatch, inferShape(6, &.{ -2, -3 }, &out));
    try std.testing.expectError(error.ShapeMismatch, inferShape(0, &.{ 0, -1 }, &out));
    // an empty tensor can still be reshaped
    try inferShape(0, &.{ 3, 0 }, &out);
    try std.testing.expectEqualSlices(usize, &.{ 3, 0 }, &out);
}

test "reshape changes the view, not the memory" {
    const memory = [_]f32{ 1, 2, 3, 4, 5, 6 };
    const v = try View.init(&.{6}).reshape(&.{ 3, 2 });
    try std.testing.expectEqualSlices(usize, &.{ 3, 2 }, v.shape[0..2]);
    try std.testing.expectEqualSlices(isize, &.{ 2, 1 }, v.strides[0..2]);

    var out: [6]f32 = undefined;
    contiguous(v, &memory, &out);
    try std.testing.expectEqualSlices(f32, &memory, &out); // same order!
}

test "reshape keeps the offset" {
    const memory = [_]f32{ 1, 2, 3, 4, 5, 6 };
    const row1 = View.make(&.{3}, &.{1}, 3);
    const column = try row1.reshape(&.{ 3, 1 });
    var out: [3]f32 = undefined;
    contiguous(column, &memory, &out);
    try std.testing.expectEqualSlices(f32, &.{ 4, 5, 6 }, &out);
}

test "sizes must match" {
    try std.testing.expectError(error.ShapeMismatch, View.init(&.{ 2, 3 }).reshape(&.{ 4, 2 }));
}
