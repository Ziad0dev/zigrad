//
// ─── Exercise 172: SwiGLU, the modern MLP ─────────────────────────────
//
// A transformer block's MLP was originally two layers with a ReLU:
//
//     mlp(x) = W2 · relu(W1 · x)            W1: [4d, d], W2: [d, 4d]
//
// Most open LLMs now use a *gated* version, SwiGLU (Shazeer, 2020, "GLU
// Variants Improve Transformer"):
//
//     mlp(x) = W2 · ( silu(W1 · x) ⊙ (W3 · x) )
//
// Two projections go up in parallel: one through an activation, one plain,
// and their elementwise product "gates" what gets through. The activation
// is SiLU (also called Swish):
//
//     silu(z)  = z * σ(z)                      (σ is sigmoid, 016)
//     silu'(z) = σ(z) * (1 + z * (1 - σ(z)))   (product rule, 028)
//
// SiLU is smooth everywhere, unlike ReLU's corner at 0, and lets a little
// negative signal through.
//
// A third matrix costs parameters, so the hidden size shrinks to keep the
// total the same: 3 matrices of d x h = 2 matrices of d x 4d gives
// h = 8d/3. LLaMA uses about that, rounded to a hardware-friendly
// multiple.
//
// YOUR TASK: silu, its derivative, and the gated hidden layer.
//
const std = @import("std");

fn sigmoid(z: f64) f64 {
    return 1 / (1 + @exp(-z));
}

fn silu(z: f64) f64 {
    return ⟪z * sigmoid(z)|||???⟫;
}

fn siluGrad(z: f64) f64 {
    const s = sigmoid(z);
    return ⟪s * (1 + z * (1 - s))|||???⟫;
}

/// hidden[j] = silu((W1 x)[j]) * (W3 x)[j]; W1, W3 are [h, d] row-major.
fn gatedHidden(w1: []const f64, w3: []const f64, x: []const f64, hidden: []f64) void {
    const d = x.len;
    for (hidden, 0..) |*o, j| {
        var a: f64 = 0;
        var b: f64 = 0;
        for (0..d) |i| {
            a += w1[j * d + i] * x[i];
            b += w3[j * d + i] * x[i];
        }
        o.* = ⟪silu(a) * b|||???⟫;
    }
}

/// The hidden size that keeps a SwiGLU MLP's parameters equal to a
/// classic 4x MLP's, before rounding.
fn swigluHidden(d: f64) f64 {
    return ⟪8 * d / 3|||???⟫;
}

test "silu" {
    try std.testing.expectEqual(0, silu(0));
    try std.testing.expectApproxEqAbs(0.7310585786300049, silu(1), 1e-12);
    // big inputs pass through, big negative ones are squashed to ~0
    try std.testing.expectApproxEqAbs(10, silu(10), 1e-3);
    try std.testing.expectApproxEqAbs(0, silu(-10), 1e-3);
    // but not exactly 0: a little negative signal gets through
    try std.testing.expect(silu(-1) < 0);
}

test "silu' matches measured slopes" {
    const h = 1e-6;
    for ([_]f64{ -3, -1, -0.2, 0, 0.5, 2, 4 }) |z| {
        try std.testing.expectApproxEqAbs((silu(z + h) - silu(z - h)) / (2 * h), siluGrad(z), 1e-8);
    }
}

test "the gate" {
    const w1 = [_]f64{ 1, 0, 0, 1 }; // identity
    const w3 = [_]f64{ 2, 0, 0, 0 }; // second gate row is all zeros
    const x = [_]f64{ 1, 5 };
    var hidden: [2]f64 = undefined;
    gatedHidden(&w1, &w3, &x, &hidden);
    try std.testing.expectApproxEqAbs(silu(1) * 2, hidden[0], 1e-12);
    // a zero gate shuts the unit off, however big its activation
    try std.testing.expectEqual(0, hidden[1]);
}

test "same parameter count as the classic MLP" {
    const d = 4096.0;
    try std.testing.expectApproxEqAbs(2 * d * 4 * d, 3 * d * swigluHidden(d), 1e-3);
    // LLaMA-7B's actual hidden size, 11008, is 8d/3 rounded up to a multiple of 256
    try std.testing.expectEqual(11008, std.mem.alignForward(usize, @intFromFloat(@ceil(swigluHidden(d))), 256));
}
