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
// Here we keep the reduced axis with size 1 ("keepdim"): [2, 3] summed
// along axis 0 becomes [1, 3], not [3]. A later reshape can drop the 1 if
// you want. Keeping it makes broadcasting back easy, which is why
// tinygrad's and PyTorch's sum and max take keepdim=True (NumPy spells
// it keepdims=True).
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
//@include view_core
//@include view_ops
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
            idx[axis] = ⟪k|||???⟫;
            acc += ⟪data[v.position(idx[0..v.ndim])]|||???⟫;
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
//⟪
        var acc: f32 = -std.math.inf(f32);
        for (0..v.shape[axis]) |k| {
            idx[axis] = k;
            acc = @max(acc, data[v.position(idx[0..v.ndim])]);
        }
//|||
        // Same as sumAxis, but starting from max's identity (exercise 004).
        var acc: f32 = ???;
        ???;
//⟫
        o.* = acc;
    }
    return out_view;
}

//@include view_helpers

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
