//
// ─── Exercise 165: Little's law, or why GPUs need so many threads ─────
//
// Memory is far away. A load from DRAM takes about a hundred nanoseconds
// to come back on a CPU, and several hundred on a GPU (its *latency*), yet
// a big GPU moves terabytes per second (its *bandwidth*). Both are true at
// once only if MANY loads are on their way at the same time, like cars on
// a long highway.
//
// *Little's law* (from queueing theory) says exactly how many:
//
//     bytes in flight = bandwidth * latency
//
// Example: 1 TB/s with 500 ns of latency needs 10^12 * 500 * 10^-9 =
// 500,000 bytes in flight: over 120,000 f32 loads outstanding, all the
// time. If the code issues fewer, the memory system idles, and you get a
// fraction of the peak bandwidth no matter how good the kernel looks.
//
// That's the real reason GPUs run tens of thousands of threads: while one
// warp waits for its data, others issue more loads. It's also why the
// number of threads that can be resident at once, *occupancy* (166),
// matters, and why CPUs have out-of-order execution and prefetchers:
// they're all ways of keeping enough loads in flight.
//
// YOUR TASK: write Little's law, and the bandwidth you actually get when
// there isn't enough in flight.
//
const std = @import("std");

/// Bytes that must be in flight to sustain `bandwidth` (bytes/s) with
/// `latency` (seconds).
fn bytesInFlight(bandwidth: f64, latency: f64) f64 {
    return ???;
}

/// Achieved bandwidth with only `in_flight` bytes outstanding: each batch
/// of in-flight bytes takes one latency to arrive, capped at the peak.
fn achievedBandwidth(in_flight: f64, latency: f64, peak: f64) f64 {
    return ???;
}

/// Threads needed if each keeps `loads` loads of `bytes` each in flight.
fn threadsNeeded(bandwidth: f64, latency: f64, loads: f64, bytes: f64) f64 {
    return ???;
}

test "the example from the comment" {
    try std.testing.expectApproxEqRel(500_000.0, bytesInFlight(1e12, 500e-9), 1e-12);
}

test "too few loads in flight" {
    // 100 KB in flight, 500 ns latency: 200 GB/s, a fifth of the 1 TB/s peak
    try std.testing.expectApproxEqRel(2e11, achievedBandwidth(100_000, 500e-9, 1e12), 1e-12);
    // plenty in flight: the peak is the limit
    try std.testing.expectApproxEqRel(1e12, achievedBandwidth(1e6, 500e-9, 1e12), 1e-12);
}

test "threads needed" {
    // each thread with one f32 load outstanding: 125,000 threads
    try std.testing.expectApproxEqRel(125_000.0, threadsNeeded(1e12, 500e-9, 1, 4), 1e-12);
    // four float4 loads each (64 bytes): far fewer
    try std.testing.expectApproxEqRel(7812.5, threadsNeeded(1e12, 500e-9, 4, 16), 1e-12);
}
