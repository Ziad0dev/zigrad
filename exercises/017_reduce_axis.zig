//
// ─── Exercise 017: reducing along an axis ──────────────────────────────
//
// Exercise 004 reduced a whole list to one number. Usually you want to
// reduce along ONE dimension (axis) and keep the others:
//
//     | 1 2 3 |    sum along axis 0 (down the columns) -> | 5 7 9 |
//     | 4 5 6 |
//                  sum along axis 1 (across the rows)   -> |  6 |
//                                                          | 15 |
//
// tinygrad's reduce ops keep the reduced axis with size 1 ("keepdim"):
// [2, 3] summed along axis 0 becomes [1, 3], not [3]. A later reshape can
// drop the 1 if you want. Keeping it makes broadcasting back easy.
//
// The plan: for each output element (whose index along `axis` is 0),
// walk k = 0, 1, 2, ... along `axis` and add up input[..., k, ...].
// Because we read the input through its View, this works for ANY view:
// transposed, flipped, expanded...
//
// YOUR TASK: finish sumAxis() and maxAxis().
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

    // Movement ops (exercises 010-013). None of them copy any data.

    fn reshape(v: View, shape: []const usize) View {
        std.debug.assert(v.isContiguous() and product(shape) == v.numel());
        var out = View.init(shape);
        out.offset = v.offset;
        return out;
    }

    fn permute(v: View, order: []const usize) View {
        var out = v;
        for (order, 0..) |old, new| {
            out.shape[new] = v.shape[old];
            out.strides[new] = v.strides[old];
        }
        return out;
    }

    fn expand(v: View, shape: []const usize) View {
        var out = v;
        for (shape, 0..) |size, i| {
            if (v.shape[i] == size) continue;
            std.debug.assert(v.shape[i] == 1);
            out.shape[i] = size;
            out.strides[i] = 0;
        }
        return out;
    }

    fn shrink(v: View, ranges: []const [2]usize) View {
        var out = v;
        for (ranges, 0..) |r, i| {
            out.offset += int(r[0]) * v.strides[i];
            out.shape[i] = r[1] - r[0];
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

fn sumAxis(v: View, data: []const f32, axis: usize, out: []f32) View {
    var out_shape = v.shape;
    out_shape[axis] = 1;
    const out_view = View.init(out_shape[0..v.ndim]);

    var idx: [max_dims]usize = undefined;
    for (out, 0..) |*o, flat| {
        // Which output element is this?
        unravel(flat, out_view.shape[0..v.ndim], idx[0..v.ndim]);
        var acc: f32 = 0;
        // Walk along `axis`, adding up everything that lands here.
        for (0..v.shape[axis]) |k| {
            idx[axis] = ???;
            acc += ???;
        }
        o.* = acc;
    }
    return out_view;
}

fn maxAxis(v: View, data: []const f32, axis: usize, out: []f32) View {
    var out_shape = v.shape;
    out_shape[axis] = 1;
    const out_view = View.init(out_shape[0..v.ndim]);

    var idx: [max_dims]usize = undefined;
    for (out, 0..) |*o, flat| {
        unravel(flat, out_view.shape[0..v.ndim], idx[0..v.ndim]);
        // Same as sumAxis, but starting from max's identity (exercise 004).
        var acc: f32 = ???;
        ???
        o.* = acc;
    }
    return out_view;
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

const memory = [_]f32{ 1, 2, 3, 4, 5, 6 };

test "sum a matrix both ways" {
    const m = View.init(&.{ 2, 3 });
    var cols: [3]f32 = undefined;
    const cv = sumAxis(m, &memory, 0, &cols);
    try std.testing.expectEqualSlices(f32, &.{ 5, 7, 9 }, &cols);
    try std.testing.expectEqualSlices(usize, &.{ 1, 3 }, cv.shape[0..2]);

    var rows: [2]f32 = undefined;
    const rv = sumAxis(m, &memory, 1, &rows);
    try std.testing.expectEqualSlices(f32, &.{ 6, 15 }, &rows);
    try std.testing.expectEqualSlices(usize, &.{ 2, 1 }, rv.shape[0..2]);
}

test "reduce works through any view" {
    // The transpose [3, 2]: summing axis 1 gives the sums of the columns.
    const t = View.init(&.{ 2, 3 }).permute(&.{ 1, 0 });
    var out: [3]f32 = undefined;
    _ = sumAxis(t, &memory, 1, &out);
    try std.testing.expectEqualSlices(f32, &.{ 5, 7, 9 }, &out);
}

test "3D" {
    var data: [24]f32 = undefined;
    for (&data, 0..) |*d, i| d.* = @floatFromInt(i);
    var out: [8]f32 = undefined;
    _ = sumAxis(View.init(&.{ 2, 3, 4 }), &data, 1, &out);
    try std.testing.expectEqualSlices(f32, &.{ 12, 15, 18, 21, 48, 51, 54, 57 }, &out);
}

test "max along an axis" {
    const data = [_]f32{ 3, -1, 2, -5, -2, -7 };
    var out: [2]f32 = undefined;
    _ = maxAxis(View.init(&.{ 2, 3 }), &data, 1, &out);
    try std.testing.expectEqualSlices(f32, &.{ 3, -2 }, &out);
}
