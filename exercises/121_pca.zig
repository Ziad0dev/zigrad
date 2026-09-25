//
// ─── Exercise 121: compressing data (PCA) ──────────────────────────────
//
// Chapter 23: generative models, which learn what data LOOKS like. The
// oldest ancestor: compress each data point to fewer numbers, then
// reconstruct it. An *autoencoder* does this with a network (encoder,
// small "code", decoder). The best LINEAR autoencoder is *PCA*, principal
// component analysis.
//
// For 2D points stretched along some direction:
//   1. subtract the mean
//   2. find the direction of greatest spread: the top eigenvector (058) of
//      the covariance matrix C = (1/n) sum of x xᵀ
//   3. encode: code = dot(x, v)        one number instead of two
//   4. decode: x ≈ code * v
//
// The average squared reconstruction error equals the variance you threw
// away (the smaller eigenvalue). Nothing linear does better. VAEs and
// diffusion models (next) are what you get when you want to generate NEW
// data instead of just compressing old data.
//
// YOUR TASK: build the covariance, then encode and decode.
//
const std = @import("std");

const Pt = [2]f64;

fn covariance(pts: []const Pt, cov: *[2][2]f64) void {
    cov.* = @splat(@splat(0));
    const n: f64 = @floatFromInt(pts.len);
    for (pts) |p| {
        for (0..2) |i| {
            for (0..2) |j| cov[i][j] += ???;
        }
    }
}

/// Top eigenvector by power iteration (058).
fn topDirection(cov: [2][2]f64) Pt {
    var v: Pt = .{ 1, 0.3 };
    for (0..200) |_| {
        const w: Pt = .{ cov[0][0] * v[0] + cov[0][1] * v[1], cov[1][0] * v[0] + cov[1][1] * v[1] };
        const len = @sqrt(w[0] * w[0] + w[1] * w[1]);
        v = .{ w[0] / len, w[1] / len };
    }
    return v;
}

fn encode(p: Pt, v: Pt) f64 {
    return ???;
}

fn decode(code: f64, v: Pt) Pt {
    return ???;
}

test "points along a line compress to one number each" {
    // points spread along the direction (3, 4)/5, with a little noise across it
    var pts: [100]Pt = undefined;
    var prng = std.Random.DefaultPrng.init(121);
    var mean: Pt = .{ 0, 0 };
    for (&pts) |*p| {
        const t = prng.random().floatNorm(f64) * 5; //    along
        const s = prng.random().floatNorm(f64) * 0.1; //  across
        p.* = .{ 0.6 * t - 0.8 * s + 10, 0.8 * t + 0.6 * s - 3 };
        mean[0] += p[0] / 100;
        mean[1] += p[1] / 100;
    }
    for (&pts) |*p| p.* = .{ p[0] - mean[0], p[1] - mean[1] };

    var cov: [2][2]f64 = undefined;
    covariance(&pts, &cov);
    const v = topDirection(cov);
    try std.testing.expectApproxEqAbs(0.6, @abs(v[0]), 0.01);
    try std.testing.expectApproxEqAbs(0.8, @abs(v[1]), 0.01);

    var err: f64 = 0;
    for (pts) |p| {
        const r = decode(encode(p, v), v);
        err += ((p[0] - r[0]) * (p[0] - r[0]) + (p[1] - r[1]) * (p[1] - r[1])) / 100;
    }
    try std.testing.expect(err < 0.02); // only the tiny "across" noise is lost
}
