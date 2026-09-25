//
// ─── Exercise 046: tiling ──────────────────────────────────────────────
//
// Exercise 044 said a matmul CAN be compute-bound, if every number is read
// from memory just once. The naive triple loop (019) is nowhere close: for
// each of the M*N*K multiplies it fetches one number of A and one of B,
// 2*M*N*K loads in total.
//
// The fix is *tiling*. Chips have a little fast memory close to the math
// units: caches on a CPU, "shared memory" on a GPU (tinygrad's LOCAL
// buffers). Cut the matrices into T x T tiles, copy a tile of A and a tile
// of B into fast memory, and do ALL the work those two tiles allow before
// fetching more:
//
//     for each tile row bi, tile column bj of C:
//       for each bk:
//         load tile A[bi][bk] and tile B[bk][bj] into fast memory  (2 T^2 loads)
//         C tile += A tile · B tile                                (T^3 multiplies, no loads)
//
// Now every loaded number is used T times, so the loads drop from
// 2*M*N*K to 2*M*N*K / T. With T = 32, that's 32x less memory traffic
// for exactly the same arithmetic.
//
// Here the "slow memory" is the input slices, and we count every read
// from them in `loads`.
//
// YOUR TASK: finish the inner tile loop and loadsTiled().
//
const std = @import("std");

const Counter = struct {
    loads: usize = 0,

    fn read(c: *Counter, slow: []const f32, i: usize) f32 {
        c.loads += 1;
        return slow[i];
    }
};

fn naiveMatmul(c: *Counter, a: []const f32, b: []const f32, m: usize, k: usize, n: usize, out: []f32) void {
    for (0..m) |i| {
        for (0..n) |j| {
            var acc: f32 = 0;
            for (0..k) |kk| acc += c.read(a, i * k + kk) * c.read(b, kk * n + j);
            out[i * n + j] = acc;
        }
    }
}

const T = 4; // tile size

/// Assumes m, k and n are multiples of T.
fn tiledMatmul(c: *Counter, a: []const f32, b: []const f32, m: usize, k: usize, n: usize, out: []f32) void {
    @memset(out, 0);
    var ta: [T][T]f32 = undefined; // "fast memory"
    var tb: [T][T]f32 = undefined;
    var bi: usize = 0;
    while (bi < m) : (bi += T) {
        var bj: usize = 0;
        while (bj < n) : (bj += T) {
            var bk: usize = 0;
            while (bk < k) : (bk += T) {
                // load the two tiles: the only reads from slow memory
                for (0..T) |r| {
                    for (0..T) |s| {
                        ta[r][s] = c.read(a, (bi + r) * k + (bk + s));
                        tb[r][s] = c.read(b, (bk + r) * n + (bj + s));
                    }
                }
                // multiply them, using fast memory only
                for (0..T) |r| {
                    for (0..T) |s| {
                        var acc: f32 = 0;
                        for (0..T) |t| acc += ⟪ta[r][t] * tb[t][s]|||???⟫;
                        out[(bi + r) * n + (bj + s)] += acc;
                    }
                }
            }
        }
    }
}

/// Loads done by tiledMatmul, as a formula.
fn loadsTiled(m: usize, k: usize, n: usize) usize {
    return ⟪2 * m * n * k / T|||???⟫;
}

test "tiling gives the same answer with T times fewer loads" {
    const m = 8;
    const k = 12;
    const n = 8;
    var a: [m * k]f32 = undefined;
    var b: [k * n]f32 = undefined;
    for (&a, 0..) |*x, i| x.* = @as(f32, @floatFromInt(i % 7)) - 3;
    for (&b, 0..) |*x, i| x.* = @as(f32, @floatFromInt(i % 5)) * 0.5;

    var c1: [m * n]f32 = undefined;
    var c2: [m * n]f32 = undefined;
    var naive: Counter = .{};
    var tiled: Counter = .{};
    naiveMatmul(&naive, &a, &b, m, k, n, &c1);
    tiledMatmul(&tiled, &a, &b, m, k, n, &c2);

    try std.testing.expectEqualSlices(f32, &c1, &c2);
    try std.testing.expectEqual(2 * m * n * k, naive.loads);
    try std.testing.expectEqual(loadsTiled(m, k, n), tiled.loads);
    try std.testing.expectEqual(naive.loads / T, tiled.loads);
}
