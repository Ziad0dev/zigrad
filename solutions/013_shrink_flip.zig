// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 013: shrink and flip ─────────────────────────────────────
//
// shrink keeps a range [start, end) of each dimension, like x[1:3, 0:2]
// in Python:
//
//     | 1 2 3 |   rows [1, 3)     | 4 5 |
//     | 4 5 6 |   cols [0, 2)     | 7 8 |
//     | 7 8 9 |   ---------->
//
// Nothing moves: start reading further in (offset += start * stride) and
// read fewer elements (shape = end - start). The strides stay the same.
//
// flip reverses one dimension:
//
//     | 1 2 3 |   flip axis 1     | 3 2 1 |
//     | 4 5 6 |   ---------->     | 6 5 4 |
//
// Walk that dimension backwards: negate its stride, and start at its far
// end (offset += (size - 1) * stride). THIS is why strides are signed.
//
// Zig note: `int(x)` (bottom of the file) turns a usize into an isize.
//
// YOUR TASK: finish shrink() and flip().
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

    fn shrink(v: View, ranges: []const [2]usize) View {
        var out = v;
        for (ranges, 0..) |r, i| {
            const start = r[0];
            const end = r[1];
            out.offset += int(start) * v.strides[i];
            out.shape[i] = end - start;
        }
        return out;
    }

    fn flip(v: View, axis: usize) View {
        var out = v;
        out.offset += int(v.shape[axis] - 1) * v.strides[axis];
        out.strides[axis] = -v.strides[axis];
        return out;
    }
};

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

test "shrink" {
    const memory = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const v = View.init(&.{ 3, 3 }).shrink(&.{ .{ 1, 3 }, .{ 0, 2 } });
    var out: [4]f32 = undefined;
    contiguous(v, &memory, &out);
    try std.testing.expectEqualSlices(f32, &.{ 4, 5, 7, 8 }, &out);
}

test "flip" {
    const memory = [_]f32{ 1, 2, 3, 4, 5, 6 };
    const m = View.init(&.{ 2, 3 });
    var out: [6]f32 = undefined;

    contiguous(m.flip(1), &memory, &out);
    try std.testing.expectEqualSlices(f32, &.{ 3, 2, 1, 6, 5, 4 }, &out);

    contiguous(m.flip(0), &memory, &out);
    try std.testing.expectEqualSlices(f32, &.{ 4, 5, 6, 1, 2, 3 }, &out);

    // flip both = rotate by 180 degrees
    contiguous(m.flip(0).flip(1), &memory, &out);
    try std.testing.expectEqualSlices(f32, &.{ 6, 5, 4, 3, 2, 1 }, &out);
}

test "shrink a flipped view" {
    const memory = [_]f32{ 1, 2, 3, 4, 5 };
    const v = View.init(&.{5}).flip(0).shrink(&.{.{ 1, 4 }});
    var out: [3]f32 = undefined;
    contiguous(v, &memory, &out);
    try std.testing.expectEqualSlices(f32, &.{ 4, 3, 2 }, &out);
}
