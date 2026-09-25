// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 141: int8 matmul ─────────────────────────────────────────
//
// Chapter 27: serving models cheaply. Quantization (049) stores weights as
// int8, but you can also COMPUTE in integers: int8 multiply-adds are much
// faster and cheaper than f32 ones, on CPUs and GPUs alike.
//
// Give each row of A its own scale sa[i], and each column of B its own
// scale sb[j] ("per-channel" quantization: more accurate than one scale
// for everything). Then
//
//     A[i][k] ≈ qa[i][k] * sa[i]      B[k][j] ≈ qb[k][j] * sb[j]
//
//     C[i][j] = sum over k of A[i][k] B[k][j]
//             ≈ sa[i] * sb[j] * (sum over k of qa[i][k] * qb[k][j])
//
// The scales come OUTSIDE the sum! So the inner loop is pure integer maths
// (int8 times int8, accumulated in i32 so it can't overflow), and one
// float multiply per output converts back.
//
// YOUR TASK: quantize rows and columns, and do the integer matmul.
//
const std = @import("std");

fn quantizeRows(a: []const f32, m: usize, k: usize, q: []i8, scale: []f32) void {
    for (0..m) |i| {
        var big: f32 = 0;
        for (a[i * k ..][0..k]) |v| big = @max(big, @abs(v));
        scale[i] = if (big == 0) 1 else big / 127;
        for (0..k) |kk| q[i * k + kk] = @intFromFloat(@round(a[i * k + kk] / scale[i]));
    }
}

fn quantizeCols(b: []const f32, k: usize, n: usize, q: []i8, scale: []f32) void {
    for (0..n) |j| {
        var big: f32 = 0;
        for (0..k) |kk| big = @max(big, @abs(b[kk * n + j]));
        scale[j] = if (big == 0) 1 else big / 127;
        for (0..k) |kk| q[kk * n + j] = @intFromFloat(@round(b[kk * n + j] / scale[j]));
    }
}

fn int8Matmul(qa: []const i8, sa: []const f32, qb: []const i8, sb: []const f32, m: usize, k: usize, n: usize, out: []f32) void {
    for (0..m) |i| {
        for (0..n) |j| {
            var acc: i32 = 0;
            for (0..k) |kk| acc += @as(i32, qa[i * k + kk]) * @as(i32, qb[kk * n + j]);
            out[i * n + j] = @as(f32, @floatFromInt(acc)) * sa[i] * sb[j];
        }
    }
}

test "int8 matmul is close to the float one" {
    const m = 3;
    const k = 16;
    const n = 4;
    var a: [m * k]f32 = undefined;
    var b: [k * n]f32 = undefined;
    for (&a, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.7) * 2;
    for (&b, 0..) |*v, i| v.* = @cos(@as(f32, @floatFromInt(i)) * 1.3);

    var exact: [m * n]f32 = undefined;
    for (0..m) |i| {
        for (0..n) |j| {
            var acc: f32 = 0;
            for (0..k) |kk| acc += a[i * k + kk] * b[kk * n + j];
            exact[i * n + j] = acc;
        }
    }

    var qa: [m * k]i8 = undefined;
    var qb: [k * n]i8 = undefined;
    var sa: [m]f32 = undefined;
    var sb: [n]f32 = undefined;
    quantizeRows(&a, m, k, &qa, &sa);
    quantizeCols(&b, k, n, &qb, &sb);
    var got: [m * n]f32 = undefined;
    int8Matmul(&qa, &sa, &qb, &sb, m, k, n, &got);
    for (exact, got) |e, g| try std.testing.expectApproxEqAbs(e, g, 0.1);
}
