//
// ─── Exercise 044: compute-bound or memory-bound? ──────────────────────
//
// Chapter 9: making kernels FAST. First, a way to know how fast a kernel
// could possibly be: the *roofline model*.
//
// A chip has two speed limits:
//     peak     how many flops (multiplies, adds...) per second it can do
//     bw       how many bytes per second it can move from memory
//
// A kernel does some flops and moves some bytes. It can't finish faster
// than either limit allows, so:
//
//     time ≈ max(flops / peak, bytes / bw)
//
// The deciding number is the kernel's *arithmetic intensity*:
//
//     intensity = flops / bytes          ("work per byte fetched")
//
//     attainable speed = min(peak, bw * intensity)
//
// Low intensity: the chip waits on memory ("memory-bound"). High
// intensity: memory keeps up and the math units are the limit
// ("compute-bound").
//
// Two examples, f32 (4 bytes each):
//
//     c = a + b, n elements:   n flops, 12n bytes     intensity 1/12
//     n x n matmul:            2n^3 flops (a multiply and an add per
//                              term), 12n^2 bytes (read A and B, write C)
//                              intensity n/6
//
// An add is hopelessly memory-bound, so all you can do is move fewer bytes
// (fusion, chapter 8). A big matmul can be compute-bound, but only if the
// kernel really reads each number just once. That's what the rest of this
// chapter is about.
//
// YOUR TASK: write the four formulas.
//
const std = @import("std");

fn intensity(flops: f64, bytes: f64) f64 {
    return ⟪flops / bytes|||???⟫;
}

/// Flops per second the kernel can reach.
fn attainable(peak: f64, bw: f64, i: f64) f64 {
    return ⟪@min(peak, bw * i)|||???⟫;
}

/// Seconds the kernel takes, at best.
fn kernelTime(flops: f64, bytes: f64, peak: f64, bw: f64) f64 {
    return ⟪@max(flops / peak, bytes / bw)|||???⟫;
}

/// Flops in an n x n by n x n matmul.
fn matmulFlops(n: f64) f64 {
    return ⟪2 * n * n * n|||???⟫;
}

// A made-up GPU: 100 TFLOP/s, 1 TB/s.
const gpu_peak = 100e12;
const gpu_bw = 1e12;

test "intensity" {
    const n = 1_000_000.0;
    try std.testing.expectApproxEqAbs(1.0 / 12.0, intensity(n, 12 * n), 1e-12);
    try std.testing.expectApproxEqAbs(1024.0 / 6.0, intensity(matmulFlops(1024), 12 * 1024 * 1024), 1e-9);
}

test "an add is memory-bound" {
    const speed = attainable(gpu_peak, gpu_bw, 1.0 / 12.0);
    try std.testing.expect(speed < gpu_peak / 1000); // under 0.1% of peak!
}

test "a big matmul can be compute-bound" {
    const i = intensity(matmulFlops(4096), 12 * 4096 * 4096);
    try std.testing.expectEqual(gpu_peak, attainable(gpu_peak, gpu_bw, i));
}

test "fusion is a speedup for a memory-bound kernel" {
    // relu(a * b + c) on 1M elements: unfused moves 32 bytes/element,
    // fused 16 (exercise 040), for the same 3 flops/element.
    const n = 1e6;
    const unfused = kernelTime(3 * n, 32 * n, gpu_peak, gpu_bw);
    const fused = kernelTime(3 * n, 16 * n, gpu_peak, gpu_bw);
    try std.testing.expectApproxEqAbs(2.0, unfused / fused, 1e-12);
}
