// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 176: measuring honestly ─────────────────────────────────
//
// Chapter 34: measure, don't guess. Every optimization in this course was
// justified by a model (044, 081, 151...). In real work you check the
// model against a stopwatch, and the stopwatch lies in predictable ways:
//
//   * the first runs are slow: compiling, loading code, cold caches,
//     a GPU still waking from its idle clocks. Always WARM UP and throw
//     those runs away.
//   * noise is one-sided. Other programs, interrupts and thermal limits
//     can only make a run SLOWER, never faster. So the minimum is the
//     best estimate of what the code itself costs, and the median is a
//     robust "typical" time. The mean gets dragged up by outliers.
//   * a single run tells you nothing about the noise. Repeat.
//
// Then turn times into rates, and compare with the roofline (044):
//
//     achieved FLOP/s = flops / seconds
//     achieved bytes/s = bytes / seconds
//
// tinygrad does exactly this for every kernel: run with DEBUG=2 and each
// kernel's line shows its time, GFLOPS and GB/s.
//
// YOUR TASK: drop the warmup, and compute min, median and the rates.
//
const std = @import("std");

const Stats = struct { min: f64, median: f64, mean: f64 };

fn stats(alloc: std.mem.Allocator, times: []const f64, warmup: usize) !Stats {
    const kept = times[warmup..];
    const sorted = try alloc.dupe(f64, kept);
    defer alloc.free(sorted);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));

    const n = sorted.len;
    const median = if (n % 2 == 1) sorted[n / 2] else (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
    var sum: f64 = 0;
    for (sorted) |t| sum += t;
    return .{ .min = sorted[0], .median = median, .mean = sum / @as(f64, @floatFromInt(n)) };
}

fn gflops(flops: f64, seconds: f64) f64 {
    return flops / seconds / 1e9;
}

fn gbps(bytes: f64, seconds: f64) f64 {
    return bytes / seconds / 1e9;
}

test "warmup and outliers" {
    // two slow warmup runs, then steady ~1 ms with one hiccup
    const times = [_]f64{ 0.050, 0.004, 0.00101, 0.00100, 0.00102, 0.00900, 0.00100, 0.00103 };
    const s = try stats(std.testing.allocator, &times, 2);
    try std.testing.expectEqual(0.00100, s.min);
    try std.testing.expectApproxEqAbs(0.001015, s.median, 1e-12);
    // the mean is dragged up by the one 9 ms hiccup
    try std.testing.expect(s.mean > 0.0023);
}

test "rates" {
    // a 4096^3 matmul (2 n^3 flops) in 2 ms
    const n = 4096.0;
    try std.testing.expectApproxEqRel(68719.47673600001, gflops(2 * n * n * n, 0.002), 1e-12);
    // copying 1 GiB (read + write = 2 GiB moved) in 1 ms
    try std.testing.expectApproxEqRel(2147.483648, gbps(2 * 1024 * 1024 * 1024, 0.001), 1e-12);
}
