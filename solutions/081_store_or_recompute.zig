// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 081: store it, or compute it twice? ──────────────────────
//
// Exercise 040 fused elementwise ops into whoever used them. But what if
// a value is used by TWO kernels? Say t = expensive(x), and both
// kernel A and kernel B read t:
//
//   recompute:  fuse t into A and into B. Its math runs twice, but it's
//               never written to or read from memory.
//   store:      give t its own kernel, write it to memory once, and have
//               A and B read it back.
//
// Which is faster? The roofline (044) answers it. For n elements with f
// flops each and c consumers, on a chip with `peak` flops/s and `bw`
// bytes/s (4 bytes per f32):
//
//     recompute = c * n * f / peak
//     store     = n * f / peak  +  (4n written + c * 4n read) / bw
//
// Cheap elementwise math: recompute wins (memory is the bottleneck).
// Very expensive math, or lots of consumers: store wins. With one
// consumer, recompute always wins, which is exactly plain fusion.
//
// tinygrad's scheduler makes these calls with its own heuristics, and you
// can force a store with .contiguous() (it's also how you stop a big
// graph from being fused into one huge kernel).
//
// YOUR TASK: write the two costs and decide().
//
const std = @import("std");

const Chip = struct { peak: f64, bw: f64 };
const gpu: Chip = .{ .peak = 100e12, .bw = 1e12 };

fn recomputeTime(chip: Chip, n: f64, flops: f64, consumers: f64) f64 {
    return consumers * n * flops / chip.peak;
}

fn storeTime(chip: Chip, n: f64, flops: f64, consumers: f64) f64 {
    return n * flops / chip.peak + (4 * n + consumers * 4 * n) / chip.bw;
}

const Decision = enum { recompute, store };

fn decide(chip: Chip, n: f64, flops: f64, consumers: f64, forced_contiguous: bool) Decision {
    if (forced_contiguous) return .store;
    return if (recomputeTime(chip, n, flops, consumers) <= storeTime(chip, n, flops, consumers)) .recompute else .store;
}

test "cheap math: recompute" {
    try std.testing.expectEqual(.recompute, decide(gpu, 1e6, 2, 2, false));
}

test "expensive math: store" {
    try std.testing.expectEqual(.store, decide(gpu, 1e6, 5000, 2, false));
}

test "many consumers tip the balance" {
    try std.testing.expectEqual(.recompute, decide(gpu, 1e6, 500, 2, false));
    try std.testing.expectEqual(.store, decide(gpu, 1e6, 500, 50, false));
}

test "one consumer: always fuse" {
    for ([_]f64{ 1, 100, 1e6 }) |flops| {
        try std.testing.expectEqual(.recompute, decide(gpu, 1e6, flops, 1, false));
    }
}

test ".contiguous() forces a store" {
    try std.testing.expectEqual(.store, decide(gpu, 1e6, 2, 2, true));
}
