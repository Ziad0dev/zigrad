//
// ─── Exercise 171: RMSNorm ────────────────────────────────────────────
//
// Chapter 33: the blocks inside today's LLMs. The 2017 transformer
// (090-093) has been refined piece by piece. First: normalization.
//
// LayerNorm (083) subtracts the mean, divides by the standard deviation,
// then applies a scale γ and shift β. *RMSNorm* (Zhang and Sennrich, 2019)
// drops the mean and the shift, and just divides by the root mean square:
//
//     rms = sqrt(mean(x²) + ε)
//     y   = g ⊙ x / rms
//
// It's cheaper (one reduction instead of two) and works just as well in
// practice. LLaMA and most open models since use it.
//
// The backward pass is LayerNorm's with the mean parts removed. With
// x̂ = x / rms and dx̂ = dy ⊙ g:
//
//     dx = (1 / rms) * ( dx̂ - x̂ * mean(dx̂ ⊙ x̂) )
//     dg = dy ⊙ x̂                    (summed over rows, if batched)
//
// The x̂ term is the part of the gradient that would only change the
// overall scale, which the normalization undoes anyway (083).
//
// YOUR TASK: the forward pass and dx. The test checks dx against measured
// slopes (026).
//
const std = @import("std");

const eps = 1e-6;

fn rms(x: []const f64) f64 {
    var s: f64 = 0;
    for (x) |v| s += v * v;
    return ???;
}

fn forward(x: []const f64, g: []const f64, y: []f64) void {
    const r = rms(x);
    for (y, x, g) |*o, v, gi| o.* = ???;
}

fn backward(x: []const f64, g: []const f64, dy: []const f64, dx: []f64) void {
    const r = rms(x);
    const n: f64 = @floatFromInt(x.len);
    var m: f64 = 0; // mean(dx̂ ⊙ x̂)
    for (x, g, dy) |v, gi, d| m += (d * gi) * (v / r);
    m /= n;
    for (dx, x, g, dy) |*o, v, gi, d| o.* = ???;
}

test "the output has root mean square 1 (before the scale)" {
    const x = [_]f64{ 3, -1, 4, 1, -5 };
    const g = [_]f64{1} ** 5;
    var y: [5]f64 = undefined;
    forward(&x, &g, &y);
    var s: f64 = 0;
    for (y) |v| s += v * v;
    try std.testing.expectApproxEqAbs(1.0, @sqrt(s / 5), 1e-6);
}

test "no mean is subtracted: a constant row stays constant" {
    const x = [_]f64{ 2, 2, 2 };
    const g = [_]f64{ 1, 1, 1 };
    var y: [3]f64 = undefined;
    forward(&x, &g, &y);
    for (y) |v| try std.testing.expectApproxEqAbs(1.0, v, 1e-6);
}

test "dx matches measured slopes" {
    var x = [_]f64{ 0.5, -1.2, 2.0, 0.3 };
    const g = [_]f64{ 1.5, 0.7, -0.4, 1.1 };
    const dy = [_]f64{ 0.2, -0.9, 0.4, 1.3 }; // loss = sum(y ⊙ dy)
    var dx: [4]f64 = undefined;
    backward(&x, &g, &dy, &dx);
    const h = 1e-6;
    for (0..4) |i| {
        var y: [4]f64 = undefined;
        const old = x[i];
        x[i] = old + h;
        forward(&x, &g, &y);
        var up: f64 = 0;
        for (y, dy) |a, b| up += a * b;
        x[i] = old - h;
        forward(&x, &g, &y);
        var down: f64 = 0;
        for (y, dy) |a, b| down += a * b;
        x[i] = old;
        try std.testing.expectApproxEqAbs((up - down) / (2 * h), dx[i], 1e-6);
    }
}
