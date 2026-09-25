// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 012: expand and broadcasting ─────────────────────────────
//
// You often want to combine tensors of different shapes, like adding a
// bias [3] to every row of a batch [2, 3]:
//
//     | 1 2 3 |  +  [10 20 30]  =  | 11 22 33 |
//     | 4 5 6 |                    | 14 25 36 |
//
// Libraries do this in two steps (tinygrad's Tensor, like NumPy and
// PyTorch, has a method for each):
//   1. reshape the bias to [1, 3]
//   2. *expand* it to [2, 3]: stretch the size-1 dimension to 2
//
// expand doesn't copy the row. It gives the stretched dimension stride 0,
// so every index along it lands on the same memory:
//
//     shape [1, 3], strides [3, 1]  ->  shape [2, 3], strides [0, 1]
//
// Now both tensors are [2, 3] and a plain elementwise add works.
//
// Which shapes can be combined? NumPy's *broadcasting* rule, which
// tinygrad follows:
//   1. line the shapes up from the RIGHT, treating missing sizes as 1
//   2. at each position the sizes must match, or one of them must be 1
//   3. the result takes the bigger size
//
//     a:       [2, 3]          a:  [4, 1, 5]         a: [2, 3]
//     b:          [3]          b:     [3, 1]         b:    [4]
//     result:  [2, 3]          r:  [4, 3, 5]         error: 3 vs 4
//
// YOUR TASK: finish expand() and broadcastShape().
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

    fn expand(v: View, shape: []const usize) error{CannotExpand}!View {
        var out = v;
        for (shape, 0..) |size, i| {
            if (v.shape[i] == size) continue;
            if (v.shape[i] != 1) return error.CannotExpand; // only 1s stretch
            out.shape[i] = size;
            out.strides[i] = 0;
        }
        return out;
    }
};

/// Writes the broadcast shape of a and b into `out`, returns its length.
fn broadcastShape(a: []const usize, b: []const usize, out: []usize) error{CannotBroadcast}!usize {
    const n = @max(a.len, b.len);
    for (0..n) |i| {
        // Size i counting from the right. Missing sizes count as 1.
        const da = if (i < a.len) a[a.len - 1 - i] else 1;
        const db = if (i < b.len) b[b.len - 1 - i] else 1;
        if (da != db and da != 1 and db != 1) return error.CannotBroadcast;
        out[n - 1 - i] = @max(da, db);
    }
    return n;
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

test "expand a row" {
    const bias = [_]f32{ 10, 20, 30 };
    const v = try View.init(&.{ 1, 3 }).expand(&.{ 2, 3 });
    try std.testing.expectEqualSlices(isize, &.{ 0, 1 }, v.strides[0..2]);

    var out: [6]f32 = undefined;
    contiguous(v, &bias, &out);
    try std.testing.expectEqualSlices(f32, &.{ 10, 20, 30, 10, 20, 30 }, &out);
}

test "expand a column" {
    const col = [_]f32{ 1, 2 };
    const v = try View.init(&.{ 2, 1 }).expand(&.{ 2, 3 });
    var out: [6]f32 = undefined;
    contiguous(v, &col, &out);
    try std.testing.expectEqualSlices(f32, &.{ 1, 1, 1, 2, 2, 2 }, &out);
}

test "only size-1 dimensions can expand" {
    try std.testing.expectError(error.CannotExpand, View.init(&.{ 2, 3 }).expand(&.{ 4, 3 }));
}

test "broadcasting rule" {
    var out: [4]usize = undefined;
    var n = try broadcastShape(&.{ 2, 3 }, &.{3}, &out);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, out[0..n]);
    n = try broadcastShape(&.{ 4, 1, 5 }, &.{ 3, 1 }, &out);
    try std.testing.expectEqualSlices(usize, &.{ 4, 3, 5 }, out[0..n]);
    n = try broadcastShape(&.{}, &.{ 2, 2 }, &out); // a scalar fits anything
    try std.testing.expectEqualSlices(usize, &.{ 2, 2 }, out[0..n]);
    try std.testing.expectError(error.CannotBroadcast, broadcastShape(&.{ 2, 3 }, &.{4}, &out));
}
