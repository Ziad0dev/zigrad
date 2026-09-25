// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 087: pooling ─────────────────────────────────────────────
//
// Pooling shrinks an image by summarizing each 2x2 block with one number:
//
//     | 1 3 | 2 0 |
//     | 4 2 | 1 5 |       max pool:  | 4 5 |     average pool: | 2.5 2    |
//     |-----+-----|                  | 9 7 |                   | 4.5 5.25 |
//     | 8 0 | 7 6 |
//     | 1 9 | 3 5 |
//
// It makes the network less sensitive to exact positions and cuts the
// work for later layers. tinygrad builds both from the window views of
// 020 plus a max or sum reduce.
//
// Backward:
//   * average: each output averaged 4 inputs with weight 1/4, so each
//     input gets dout / 4
//   * max: only the WINNER affected the output (like relu's max, 031), so
//     the whole gradient goes to the position of the max, and the others
//     get 0. Forward remembers where each max was.
//
// YOUR TASK: finish both forward passes and both backward passes.
//
const std = @import("std");

/// 2x2, stride 2, on an [h, w] image (h, w even).
fn maxPool(x: []const f64, h: usize, w: usize, out: []f64, argmax: []usize) void {
    for (0..h / 2) |oy| {
        for (0..w / 2) |ox| {
            var best: f64 = -std.math.inf(f64);
            var best_at: usize = 0;
            for (0..2) |i| {
                for (0..2) |j| {
                    const at = (oy * 2 + i) * w + (ox * 2 + j);
                    if (x[at] > best) {
                        best = x[at];
                        best_at = at;
                    }
                }
            }
            out[oy * (w / 2) + ox] = best;
            argmax[oy * (w / 2) + ox] = best_at;
        }
    }
}

fn maxPoolBackward(dout: []const f64, argmax: []const usize, dx: []f64) void {
    @memset(dx, 0);
    for (dout, argmax) |g, at| dx[at] += g;
}

fn avgPool(x: []const f64, h: usize, w: usize, out: []f64) void {
    for (0..h / 2) |oy| {
        for (0..w / 2) |ox| {
            var acc: f64 = 0;
            for (0..2) |i| {
                for (0..2) |j| acc += x[(oy * 2 + i) * w + (ox * 2 + j)];
            }
            out[oy * (w / 2) + ox] = acc / 4;
        }
    }
}

fn avgPoolBackward(dout: []const f64, h: usize, w: usize, dx: []f64) void {
    for (0..h) |y| {
        for (0..w) |xx| dx[y * w + xx] = dout[(y / 2) * (w / 2) + xx / 2] / 4;
    }
}

/// Check an analytic gradient against measured slopes (026).
/// `ctx` must have `fn loss(self) f64`, which reads `param`.
fn gradCheck(ctx: anytype, param: []f64, analytic: []const f64) !void {
    const h = 1e-6;
    for (param, analytic, 0..) |*p, g, i| {
        const orig = p.*;
        p.* = orig + h;
        const up = ctx.loss();
        p.* = orig - h;
        const down = ctx.loss();
        p.* = orig;
        const measured = (up - down) / (2 * h);
        if (@abs(measured - g) > 1e-5 * @max(1, @abs(measured))) {
            std.debug.print("gradient {d}: yours {d}, measured {d}\n", .{ i, g, measured });
            return error.WrongGradient;
        }
    }
}

const img = [_]f64{
    1, 3, 2, 0,
    4, 2, 1, 5,
    8, 0, 7, 6,
    1, 9, 3, 5,
};

test "max pool" {
    var out: [4]f64 = undefined;
    var argmax: [4]usize = undefined;
    maxPool(&img, 4, 4, &out, &argmax);
    try std.testing.expectEqualSlices(f64, &.{ 4, 5, 9, 7 }, &out);

    var dx: [16]f64 = undefined;
    maxPoolBackward(&.{ 1, 2, 3, 4 }, &argmax, &dx);
    try std.testing.expectEqualSlices(f64, &.{
        0, 0, 0, 0,
        1, 0, 0, 2,
        0, 0, 4, 0,
        0, 3, 0, 0,
    }, &dx);
}

const AvgCheck = struct {
    x: []f64,
    r: []const f64,
    fn loss(c: AvgCheck) f64 {
        var out: [4]f64 = undefined;
        avgPool(c.x, 4, 4, &out);
        var total: f64 = 0;
        for (out, c.r) |a, b| total += a * b;
        return total;
    }
};

test "average pool" {
    var x = img;
    var out: [4]f64 = undefined;
    avgPool(&x, 4, 4, &out);
    try std.testing.expectEqualSlices(f64, &.{ 2.5, 2, 4.5, 5.25 }, &out);

    const r = [_]f64{ 1, -2, 0.5, 3 };
    var dx: [16]f64 = undefined;
    avgPoolBackward(&r, 4, 4, &dx);
    try gradCheck(AvgCheck{ .x = &x, .r = &r }, &x, &dx);
}
