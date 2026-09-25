//
// ═══ PART II: going deeper ═════════════════════════════════════════════
//
// Part I built every piece of tinygrad in miniature. Part II goes deeper:
// the maths you need to read ML papers (chapters 11-13), how tinygrad's
// real compiler handles index maths and GPUs (14-15), the layers of real
// networks and transformers (16-18), a full training project (19), and
// what happens down at the hardware (20).
//
// ─── Exercise 054: vectors are arrows ──────────────────────────────────
//
// Chapter 11 is linear algebra, the language of deep learning. We start
// with the picture behind the numbers: a vector like [3, 4] is an ARROW,
// 3 steps right and 4 steps up.
//
//   * its length ("norm") is sqrt(3^2 + 4^2) = 5 (Pythagoras)
//   * the dot product (exercise 007) measures how much two arrows point
//     the same way:
//
//         dot(a, b) = |a| * |b| * cos(angle between them)
//
//     so dot > 0: roughly the same direction, dot = 0: perpendicular,
//     dot < 0: roughly opposite.
//
//   * dividing out the lengths gives *cosine similarity*, from -1 to 1.
//     It's how "is this word/image/sentence similar to that one?" is
//     measured on embeddings. And an attention score in a transformer
//     (chapter 17) is a dot product between two vectors.
//
//   * projecting a onto b ("how much of a points along b?"):
//
//         proj = (dot(a, b) / dot(b, b)) * b
//
// YOUR TASK: write dot, norm, cosine and project.
//
const std = @import("std");

fn dot(a: []const f64, b: []const f64) f64 {
    var acc: f64 = 0;
    for (a, b) |x, y| acc += ⟪x * y|||???⟫;
    return acc;
}

fn norm(a: []const f64) f64 {
    return ⟪@sqrt(dot(a, a))|||???⟫;
}

fn cosine(a: []const f64, b: []const f64) f64 {
    return ⟪dot(a, b) / (norm(a) * norm(b))|||???⟫;
}

fn angleDegrees(a: []const f64, b: []const f64) f64 {
    return std.math.acos(cosine(a, b)) * 180 / std.math.pi;
}

fn project(a: []const f64, b: []const f64, out: []f64) void {
    const scale = ⟪dot(a, b) / dot(b, b)|||???⟫;
    for (out, b) |*o, x| o.* = scale * x;
}

const tol = 1e-9;

test "length and dot" {
    try std.testing.expectApproxEqAbs(5.0, norm(&.{ 3, 4 }), tol);
    try std.testing.expectApproxEqAbs(11.0, dot(&.{ 1, 2 }, &.{ 3, 4 }), tol);
}

test "angles" {
    try std.testing.expectApproxEqAbs(90.0, angleDegrees(&.{ 1, 0 }, &.{ 0, 5 }), tol);
    try std.testing.expectApproxEqAbs(45.0, angleDegrees(&.{ 1, 0 }, &.{ 2, 2 }), tol);
    try std.testing.expectApproxEqAbs(-1.0, cosine(&.{ 1, 2, 3 }, &.{ -2, -4, -6 }), tol);
}

test "projection" {
    var out: [2]f64 = undefined;
    project(&.{ 3, 4 }, &.{ 1, 0 }, &out); // the "x part" of [3, 4]
    try std.testing.expectApproxEqAbs(3.0, out[0], tol);
    try std.testing.expectApproxEqAbs(0.0, out[1], tol);

    // what's left over is perpendicular to b
    project(&.{ 2, 3 }, &.{ 1, 1 }, &out);
    const rest = [_]f64{ 2 - out[0], 3 - out[1] };
    try std.testing.expectApproxEqAbs(0.0, dot(&rest, &.{ 1, 1 }), tol);
}
