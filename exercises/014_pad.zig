//
// ─── Exercise 014: pad ─────────────────────────────────────────────────
//
// pad adds a border of zeros:
//
//     pad([1 2 3], before 1, after 2)  =  [0 1 2 3 0 0]
//
// Convolutions (exercise 020) pad all the time. Allocating a bigger
// buffer and copying just to add zeros would be a waste, so tinygrad
// never stores the zeros. The view gets a *mask* instead: a valid range
// for each dimension. Inside that range we read memory as usual. Outside
// it the answer is simply 0, and memory is never touched. (Older tinygrad
// kept the mask in its View objects. Newer versions put the same range
// check into the index maths, as a condition: exercise 073.)
//
//     memory:              [ 1 2 3 ]
//     padded view:     [ 0 1 2 3 0 0 ]     shape 6, valid range [1, 4)
//                        0 1 2 3 4 5       <- view index
//
// For position() to keep working in the valid range, view index 1 must
// land on memory position 0. So move the offset back by before * stride.
// Here that makes the offset -1. That's fine: we never read memory at an
// index outside the valid range.
//
// YOUR TASK: finish read() and pad().
//
const std = @import("std");

const max_dims = 4;

const View = struct {
    ndim: usize,
    shape: [max_dims]usize = @splat(0),
    strides: [max_dims]isize = @splat(0),
    offset: isize = 0,
    /// Per dimension, the range [start, end) that has real data.
    valid: [max_dims][2]usize = @splat(.{ 0, 0 }),

    fn init(shape: []const usize) View {
        var v: View = .{ .ndim = shape.len };
        var step: isize = 1;
        var i = shape.len;
        while (i > 0) {
            i -= 1;
            v.shape[i] = shape[i];
            v.strides[i] = step;
            v.valid[i] = .{ 0, shape[i] };
            step *= int(shape[i]);
        }
        return v;
    }

    fn position(v: View, idx: []const usize) usize {
        var pos = v.offset;
        for (idx, v.strides[0..v.ndim]) |i, s| pos += int(i) * s;
        return @intCast(pos);
    }

    /// The value at `idx`: 0 in the padding, otherwise read memory.
    fn read(v: View, data: []const f32, idx: []const usize) f32 {
        for (idx, v.valid[0..v.ndim]) |i, range| {
            if (???) return 0;
        }
        return data[v.position(idx)];
    }

    /// amounts[i] = .{ before, after } for dimension i.
    fn pad(v: View, amounts: []const [2]usize) View {
        var out = v;
        for (amounts, 0..) |a, i| {
            const before = a[0];
            const after = a[1];
            out.shape[i] = v.shape[i] + before + after;
            out.offset -= ???;
            // The real data moved `before` places to the right.
            out.valid[i] = .{ v.valid[i][0] + before, ??? };
        }
        return out;
    }
};

fn int(x: usize) isize {
    return @intCast(x);
}

fn unravel(flat: usize, shape: []const usize, idx: []usize) void {
    var rest = flat;
    var k = shape.len;
    while (k > 0) {
        k -= 1;
        idx[k] = rest % shape[k];
        rest /= shape[k];
    }
}

fn contiguous(v: View, data: []const f32, out: []f32) void {
    var idx: [max_dims]usize = undefined;
    for (out, 0..) |*o, flat| {
        unravel(flat, v.shape[0..v.ndim], idx[0..v.ndim]);
        o.* = v.read(data, idx[0..v.ndim]);
    }
}

test "pad a list" {
    const memory = [_]f32{ 1, 2, 3 };
    const v = View.init(&.{3}).pad(&.{.{ 1, 2 }});
    var out: [6]f32 = undefined;
    contiguous(v, &memory, &out);
    try std.testing.expectEqualSlices(f32, &.{ 0, 1, 2, 3, 0, 0 }, &out);
}

test "pad a matrix with a border" {
    const memory = [_]f32{ 1, 2, 3, 4 };
    const v = View.init(&.{ 2, 2 }).pad(&.{ .{ 1, 1 }, .{ 1, 1 } });
    var out: [16]f32 = undefined;
    contiguous(v, &memory, &out);
    try std.testing.expectEqualSlices(f32, &.{
        0, 0, 0, 0,
        0, 1, 2, 0,
        0, 3, 4, 0,
        0, 0, 0, 0,
    }, &out);
}

test "pad twice" {
    const memory = [_]f32{ 1, 2, 3 };
    const v = View.init(&.{3}).pad(&.{.{ 1, 0 }}).pad(&.{.{ 2, 1 }});
    var out: [7]f32 = undefined;
    contiguous(v, &memory, &out);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 1, 2, 3, 0 }, &out);
}
