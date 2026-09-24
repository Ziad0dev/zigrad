// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
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
// always describe that, so tinygrad makes a contiguous copy first.)
//
// Zig notes: this is our first function that can fail. `error{ShapeMismatch}!View`
// means "a View, or the error ShapeMismatch". `return error.ShapeMismatch`
// fails, and callers write `try` to pass errors on.
//
// YOUR TASK: finish inferShape() and reshape().
//
const std = @import("std");

const View = struct {
    ndim: usize,
    shape: [max_dims]usize = @splat(0),
    strides: [max_dims]isize = @splat(0),
    offset: isize = 0,

    /// A contiguous (row-major) view of `shape`. (Exercise 006.)
    fn init(shape: []const usize) View {
        var v: View = .{ .ndim = shape.len };
        var step: isize = 1;
        var i = shape.len;
        while (i > 0) {
            i -= 1;
            v.shape[i] = shape[i];
            v.strides[i] = step;
            step *= int(shape[i]);
        }
        return v;
    }

    /// A view with hand-picked strides and offset.
    fn make(shape: []const usize, strides: []const isize, offset: isize) View {
        var v: View = .{ .ndim = shape.len, .offset = offset };
        @memcpy(v.shape[0..shape.len], shape);
        @memcpy(v.strides[0..strides.len], strides);
        return v;
    }

    fn numel(v: View) usize {
        var n: usize = 1;
        for (v.shape[0..v.ndim]) |d| n *= d;
        return n;
    }

    /// Where in memory the element at `idx` lives. (Exercise 009.)
    fn position(v: View, idx: []const usize) usize {
        var pos = v.offset;
        for (idx, v.strides[0..v.ndim]) |i, s| pos += int(i) * s;
        return @intCast(pos);
    }

    /// Does this view read memory in plain row-major order?
    fn isContiguous(v: View) bool {
        const fresh = View.init(v.shape[0..v.ndim]);
        return std.mem.eql(isize, v.strides[0..v.ndim], fresh.strides[0..v.ndim]);
    }

    /// Same memory, new shape.
    fn reshape(v: View, shape: []const usize) error{ShapeMismatch}!View {
        if (product(shape) != v.numel()) return error.ShapeMismatch;
        std.debug.assert(v.isContiguous());
        var out = View.init(shape);
        out.offset = v.offset;
        return out;
    }
};

/// Replace a -1 in `shape` with the size that makes `numel` fit.
fn inferShape(numel: usize, shape: []const isize, out: []usize) error{ShapeMismatch}!void {
    var known: usize = 1;
    var unknown_axis: ?usize = null;
    for (shape, 0..) |d, i| {
        if (d == -1) {
            unknown_axis = i;
        } else {
            out[i] = @intCast(d);
            known *= out[i];
        }
    }
    if (unknown_axis) |i| out[i] = numel / known;
    // Not every shape works: 6 numbers can't be [4, -1] (6 / 4 isn't whole).
    if (product(out) != numel) return error.ShapeMismatch;
}

const max_dims = 4;

/// usize -> isize, for index maths with strides.
fn int(x: usize) isize {
    return @intCast(x);
}

fn product(shape: []const usize) usize {
    var n: usize = 1;
    for (shape) |d| n *= d;
    return n;
}

/// Flat position in a contiguous `shape` -> multi-index. (Exercise 008.)
fn unravel(flat: usize, shape: []const usize, idx: []usize) void {
    var rest = flat;
    var k = shape.len;
    while (k > 0) {
        k -= 1;
        idx[k] = rest % shape[k];
        rest /= shape[k];
    }
}

/// Read a view in logical order into a fresh buffer. (Exercise 009.)
fn contiguous(v: View, data: []const f32, out: []f32) void {
    var idx: [max_dims]usize = undefined;
    for (out, 0..) |*o, flat| {
        unravel(flat, v.shape[0..v.ndim], idx[0..v.ndim]);
        o.* = data[v.position(idx[0..v.ndim])];
    }
}

test "infer a -1" {
    var out: [2]usize = undefined;
    try inferShape(6, &.{ 3, -1 }, &out);
    try std.testing.expectEqualSlices(usize, &.{ 3, 2 }, &out);
    try inferShape(6, &.{ -1, 6 }, &out);
    try std.testing.expectEqualSlices(usize, &.{ 1, 6 }, &out);
    try std.testing.expectError(error.ShapeMismatch, inferShape(6, &.{ 4, -1 }, &out));
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
