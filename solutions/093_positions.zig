// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 093: where is each token? ────────────────────────────────
//
// Attention has no idea of ORDER: shuffle the tokens and each one gets the
// same weighted sum (softmax over a set doesn't care about positions).
// "dog bites man" and "man bites dog" would look identical. Position
// information must be added.
//
// 1. Sinusoidal encodings (the original transformer): add to token t's
//    vector a fixed pattern of waves at different frequencies:
//
//        PE[t][2i]   = sin(t * f_i)
//        PE[t][2i+1] = cos(t * f_i)       with f_i = 1 / 10000^(2i / d)
//
//    Fast waves tell nearby positions apart, slow waves far ones, like the
//    hands of a clock.
//
// 2. RoPE (rotary embeddings, used in LLaMA and most modern LLMs): instead
//    of adding, ROTATE each pair (x[2i], x[2i+1]) of q and k by the angle
//    t * f_i (the rotation matrix of 055). Then
//
//        dot(rotate(q, m), rotate(k, n)) depends only on m - n
//
//    because rotating both by the same extra angle doesn't change the
//    angle between them (054). The attention score only sees RELATIVE
//    position, exactly what language needs.
//
// YOUR TASK: write the frequency, the sinusoid, and the rotation.
//
const std = @import("std");

fn freq(i_pair: usize, d: usize) f64 {
    const e = @as(f64, @floatFromInt(2 * i_pair)) / @as(f64, @floatFromInt(d));
    return 1 / std.math.pow(f64, 10000, e);
}

fn sinusoidal(t: f64, index: usize, d: usize) f64 {
    const angle = t * freq(index / 2, d);
    return if (index % 2 == 0) @sin(angle) else @cos(angle);
}

fn rope(x: []const f64, t: f64, out: []f64) void {
    const d = x.len;
    for (0..d / 2) |i| {
        const angle = t * freq(i, d);
        const a = x[2 * i];
        const b = x[2 * i + 1];
        out[2 * i] = a * @cos(angle) - b * @sin(angle);
        out[2 * i + 1] = a * @sin(angle) + b * @cos(angle);
    }
}

fn dot(a: []const f64, b: []const f64) f64 {
    var acc: f64 = 0;
    for (a, b) |x, y| acc += x * y;
    return acc;
}

test "sinusoidal encodings" {
    for (0..8) |i| try std.testing.expectApproxEqAbs(@as(f64, if (i % 2 == 0) 0 else 1), sinusoidal(0, i, 8), 1e-12);
    try std.testing.expectApproxEqAbs(@sin(3.0), sinusoidal(3, 0, 8), 1e-12);
    try std.testing.expectApproxEqAbs(@cos(3.0 / 100.0), sinusoidal(3, 5, 8), 1e-12); // f_2 = 1/10000^(4/8)
}

const query = [_]f64{ 0.3, -1.2, 0.8, 0.5, 2, -0.1 };
const key = [_]f64{ 1, 0.4, -0.6, 0.9, 0.2, 1.5 };

test "rotation keeps lengths" {
    var r: [6]f64 = undefined;
    rope(&query, 17, &r);
    try std.testing.expectApproxEqAbs(dot(&query, &query), dot(&r, &r), 1e-12);
}

test "RoPE scores only see relative position" {
    var q5: [6]f64 = undefined;
    var k3: [6]f64 = undefined;
    var q12: [6]f64 = undefined;
    var k10: [6]f64 = undefined;
    var k5: [6]f64 = undefined;
    rope(&query, 5, &q5);
    rope(&key, 3, &k3);
    rope(&query, 12, &q12);
    rope(&key, 10, &k10);
    rope(&key, 5, &k5);
    try std.testing.expectApproxEqAbs(dot(&q5, &k3), dot(&q12, &k10), 1e-12); // both 2 apart
    try std.testing.expect(@abs(dot(&q5, &k3) - dot(&q5, &k5)) > 1e-3); // 2 apart vs 0 apart
}
