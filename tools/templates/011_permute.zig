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
//@include view_core

    fn permute(v: View, order: []const usize) View {
        var out = v;
        for (order, 0..) |old, new| {
            out.shape[new] = ⟪v.shape[old]|||???⟫;
            out.strides[new] = ⟪v.strides[old]|||???⟫;
        }
        return out;
    }
};

//@include view_helpers

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
