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
//@include view_core

    fn shrink(v: View, ranges: []const [2]usize) View {
        var out = v;
        for (ranges, 0..) |r, i| {
            const start = r[0];
            const end = r[1];
            out.offset += ⟪int(start) * v.strides[i]|||???⟫;
            out.shape[i] = ⟪end - start|||???⟫;
        }
        return out;
    }

    fn flip(v: View, axis: usize) View {
        var out = v;
        out.offset += ⟪int(v.shape[axis] - 1) * v.strides[axis]|||???⟫;
        out.strides[axis] = ⟪-v.strides[axis]|||???⟫;
        return out;
    }
};

//@include view_helpers

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
