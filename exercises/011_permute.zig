//
// ─── Exercise 011: permute ─────────────────────────────────────────────
//
// permute reorders the dimensions. For a matrix, permute(.{1, 0}) is the
// *transpose*: rows become columns.
//
//     | 1 2 3 |    transpose    | 1 4 |
//     | 4 5 6 |    -------->    | 2 5 |
//                               | 3 6 |
//     shape [2, 3]              shape [3, 2]
//     strides [3, 1]            strides [1, 3]
//
// Look at the strides: we just swapped them, along with the shape. The
// memory is still [1 2 3 4 5 6]. Transposing a huge matrix is free!
//
// In general `order[new] = old`: new dimension `new` is old dimension
// `old`. Images are often stored as [height, width, channels], but conv
// layers want [channels, height, width]. That's permute(.{2, 0, 1}).
//
// YOUR TASK: finish permute().
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

    fn permute(v: View, order: []const usize) View {
        var out = v;
        for (order, 0..) |old, new| {
            out.shape[new] = ???;
            out.strides[new] = ???;
        }
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

const memory = [_]f32{ 1, 2, 3, 4, 5, 6 };

test "transpose" {
    const t = View.init(&.{ 2, 3 }).permute(&.{ 1, 0 });
    try std.testing.expectEqualSlices(usize, &.{ 3, 2 }, t.shape[0..2]);
    try std.testing.expectEqualSlices(isize, &.{ 1, 3 }, t.strides[0..2]);
    try std.testing.expect(!t.isContiguous());

    var out: [6]f32 = undefined;
    contiguous(t, &memory, &out);
    try std.testing.expectEqualSlices(f32, &.{ 1, 4, 2, 5, 3, 6 }, &out);
}

test "transposing twice gets you back" {
    const t = View.init(&.{ 2, 3 }).permute(&.{ 1, 0 }).permute(&.{ 1, 0 });
    try std.testing.expect(t.isContiguous());
}

test "3D permute" {
    // [height 2, width 3, channels 4] -> [channels, height, width]
    const v = View.init(&.{ 2, 3, 4 }).permute(&.{ 2, 0, 1 });
    try std.testing.expectEqualSlices(usize, &.{ 4, 2, 3 }, v.shape[0..3]);
    try std.testing.expectEqualSlices(isize, &.{ 1, 12, 4 }, v.strides[0..3]);
}
