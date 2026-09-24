//
// ─── Exercise 055: a matrix is a function ──────────────────────────────
//
// A matrix isn't just a grid of numbers. It's a *function* that moves
// arrows: y = M x. And there's an easy way to read it: the columns of M
// are where the basis arrows [1, 0] and [0, 1] land.
//
//     M = | 2  0 |      [1, 0] -> [2, 0]     (x doubled)
//         | 0  1 |      [0, 1] -> [0, 1]     (y unchanged)
//
//     M x = x[0] * (column 0) + x[1] * (column 1)
//
// Rotating by angle t sends [1, 0] to [cos t, sin t] and [0, 1] to
// [-sin t, cos t], so the rotation matrix is
//
//     R(t) = | cos t  -sin t |
//            | sin t   cos t |
//
// And here's WHY matrix multiplication is defined the weird way it is:
// A · B is the matrix of "do B, then do A". Composing functions. So
//
//     R(45°) · R(45°) = R(90°)
//     (A · B) x = A (B x)
//     A · B != B · A, usually (put on socks then shoes, or the reverse?)
//
// A neural network layer is exactly this: a matrix moving vectors around,
// followed by a nonlinearity (relu) so that stacking layers doesn't
// collapse into one big matrix.
//
// YOUR TASK: write apply, rotation and compose.
//
const std = @import("std");

const Mat2 = [2][2]f64; // Mat2[row][col]
const Vec2 = [2]f64;

fn apply(m: Mat2, x: Vec2) Vec2 {
    return .{
        m[0][0] * x[0] + m[0][1] * x[1],
        ⟪m[1][0] * x[0] + m[1][1] * x[1]|||???⟫,
    };
}

fn rotation(t: f64) Mat2 {
    return .{
        .{ @cos(t), -@sin(t) },
        ⟪.{ @sin(t), @cos(t) }|||???⟫,
    };
}

/// The matrix of "do b, then do a": a · b.
fn compose(a: Mat2, b: Mat2) Mat2 {
    var out: Mat2 = undefined;
    for (0..2) |i| {
        for (0..2) |j| {
            out[i][j] = ⟪a[i][0] * b[0][j] + a[i][1] * b[1][j]|||???⟫;
        }
    }
    return out;
}

fn expectVec(expected: Vec2, got: Vec2) !void {
    try std.testing.expectApproxEqAbs(expected[0], got[0], 1e-12);
    try std.testing.expectApproxEqAbs(expected[1], got[1], 1e-12);
}

const deg = std.math.pi / 180.0;

test "columns are where the basis lands" {
    const m: Mat2 = .{ .{ 2, 5 }, .{ 3, 7 } };
    try expectVec(.{ 2, 3 }, apply(m, .{ 1, 0 }));
    try expectVec(.{ 5, 7 }, apply(m, .{ 0, 1 }));
}

test "rotation" {
    try expectVec(.{ 0, 1 }, apply(rotation(90 * deg), .{ 1, 0 }));
    try expectVec(.{ -1, 0 }, apply(rotation(90 * deg), .{ 0, 1 }));
}

test "composing is multiplying" {
    const r45 = rotation(45 * deg);
    const r90 = compose(r45, r45);
    try expectVec(apply(rotation(90 * deg), .{ 3, 1 }), apply(r90, .{ 3, 1 }));

    const stretch: Mat2 = .{ .{ 2, 0 }, .{ 0, 1 } };
    const x: Vec2 = .{ 1, 1 };
    // (A · B) x = A (B x)
    try expectVec(apply(stretch, apply(r45, x)), apply(compose(stretch, r45), x));
    // order matters
    const ab = apply(compose(stretch, r45), x);
    const ba = apply(compose(r45, stretch), x);
    try std.testing.expect(@abs(ab[0] - ba[0]) > 0.1);
}
