// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 019: matmul is not a primitive ───────────────────────────
//
// Matrix multiplication is the heart of deep learning. For A [M, K] and
// B [K, N], C = A·B is [M, N], and every C[i][j] is a dot product (007):
//
//     C[i][j] = A[i][0]*B[0][j] + A[i][1]*B[1][j] + ... + A[i][K-1]*B[K-1][j]
//
// tinygrad has no matmul op! It builds matmul from movement ops, one mul
// and one sum:
//
//     A: [M, K] --reshape--> [M, 1, K] --expand--> [M, N, K]
//     B: [K, N] --reshape--> [1, K, N] --permute--> [1, N, K] --expand--> [M, N, K]
//
//     prod[i][j][k] = A[i][k] * B[k][j]      (elementwise mul, [M, N, K])
//     C[i][j] = sum of prod[i][j][k] over k  (sum along axis 2)
//
// The expands make stride-0 views: no copies. Here we still write the
// [M, N, K] products into `scratch` before summing, which wastes a lot of
// memory. In tinygrad, fusion (chapter 8) puts the mul inside the sum's
// loop, so that big array never exists.
//
// YOUR TASK: finish the classic triple loop, then the tinygrad version.
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

/// A is [m, k], B is [k, n], both contiguous. C is [m, n].
fn naiveMatmul(a: []const f32, b: []const f32, m: usize, k: usize, n: usize, out: []f32) void {
    for (0..m) |i| {
        for (0..n) |j| {
            var acc: f32 = 0;
            for (0..k) |kk| acc += a[i * k + kk] * b[kk * n + j];
            out[i * n + j] = acc;
        }
    }
}

fn tinygradMatmul(a: []const f32, b: []const f32, m: usize, k: usize, n: usize, out: []f32, scratch: []f32) void {
    // A: [M, K] -> [M, 1, K] -> [M, N, K]
    const va = View.init(&.{ m, k }).reshape(&.{ m, 1, k }).expand(&.{ m, n, k });
    // B: [K, N] -> [1, K, N] -> [1, N, K] -> [M, N, K]
    const vb = View.init(&.{ k, n }).reshape(&.{ 1, k, n }).permute(&.{ 0, 2, 1 }).expand(&.{ m, n, k });
    // prod[i][j][kk] = A[i][kk] * B[kk][j]
    mulViews(va, a, vb, b, scratch);
    // C[i][j] = sum over kk
    sumLastAxis(scratch, k, out);
}

/// out[i] = a[i] * b[i], reading a and b through views of the same shape.
fn mulViews(va: View, a: []const f32, vb: View, b: []const f32, out: []f32) void {
    var idx: [max_dims]usize = undefined;
    for (out, 0..) |*o, flat| {
        unravel(flat, va.shape[0..va.ndim], idx[0..va.ndim]);
        o.* = a[va.position(idx[0..va.ndim])] * b[vb.position(idx[0..vb.ndim])];
    }
}

/// Sum a contiguous [rows, n] buffer along its last axis, giving [rows].
fn sumLastAxis(data: []const f32, n: usize, out: []f32) void {
    for (out, 0..) |*o, r| {
        var acc: f32 = 0;
        for (data[r * n ..][0..n]) |x| acc += x;
        o.* = acc;
    }
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

test "2x3 times 3x2" {
    const a = [_]f32{ 1, 2, 3, 4, 5, 6 };
    const b = [_]f32{ 7, 8, 9, 10, 11, 12 };
    const expected = [_]f32{ 58, 64, 139, 154 };
    var c: [4]f32 = undefined;

    naiveMatmul(&a, &b, 2, 3, 2, &c);
    try std.testing.expectEqualSlices(f32, &expected, &c);

    var scratch: [2 * 2 * 3]f32 = undefined;
    tinygradMatmul(&a, &b, 2, 3, 2, &c, &scratch);
    try std.testing.expectEqualSlices(f32, &expected, &c);
}

test "both ways agree" {
    var a: [3 * 4]f32 = undefined;
    var b: [4 * 5]f32 = undefined;
    for (&a, 0..) |*x, i| x.* = @as(f32, @floatFromInt(i % 7)) - 3;
    for (&b, 0..) |*x, i| x.* = @as(f32, @floatFromInt(i % 5)) * 0.5;

    var c1: [15]f32 = undefined;
    var c2: [15]f32 = undefined;
    var scratch: [3 * 5 * 4]f32 = undefined;
    naiveMatmul(&a, &b, 3, 4, 5, &c1);
    tinygradMatmul(&a, &b, 3, 4, 5, &c2, &scratch);
    try std.testing.expectEqualSlices(f32, &c1, &c2);
}
