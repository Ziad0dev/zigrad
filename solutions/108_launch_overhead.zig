// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 108: launch overhead and graphs ──────────────────────────
//
// Launching a kernel isn't free: the CPU builds the command, fills in
// arguments, and rings the GPU's doorbell. Call it ~5 microseconds. For a
// big matmul taking milliseconds, who cares. But generating text with a
// small model, one token at a time, can mean hundreds of tiny kernels of
// ~2 microseconds each, per token. Then the overhead IS the runtime.
//
//     plain:  n * (launch + kernel)
//     graph:  one launch for the whole batch of kernels, then n kernels:
//             launch + n * kernel
//
// A *graph* is the whole list of kernels (with their arguments) recorded
// once and submitted as a unit. CUDA calls them CUDA graphs. tinygrad's
// JIT (051) captures the kernel list, and on the GPUs it drives itself
// (the HCQ backends, 106) turns it into one prebuilt batch of commands,
// enqueued in one go. (Older tinygrad called these "graph" runners, after
// CUDA graphs.)
//
// YOUR TASK: write both times and the speedup.
//
const std = @import("std");

fn plainTime(n: f64, launch: f64, kernel: f64) f64 {
    return n * (launch + kernel);
}

fn graphTime(n: f64, launch: f64, kernel: f64) f64 {
    return launch + n * kernel;
}

fn speedup(n: f64, launch: f64, kernel: f64) f64 {
    return plainTime(n, launch, kernel) / graphTime(n, launch, kernel);
}

test "tiny kernels: the graph wins big" {
    // 500 kernels of 2 µs, 5 µs to launch each
    try std.testing.expectApproxEqAbs(3500e-6, plainTime(500, 5e-6, 2e-6), 1e-12);
    try std.testing.expectApproxEqAbs(1005e-6, graphTime(500, 5e-6, 2e-6), 1e-12);
    try std.testing.expect(speedup(500, 5e-6, 2e-6) > 3.4);
}

test "big kernels: it hardly matters" {
    try std.testing.expect(speedup(10, 5e-6, 10e-3) < 1.001);
}
