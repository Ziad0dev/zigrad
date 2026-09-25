// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 109: ring all-reduce ─────────────────────────────────────
//
// Data-parallel training (053) needs an all-reduce: every device ends up
// with the sum of everyone's gradients. The naive way sends everything to
// one device and back, and that one device's link becomes the bottleneck.
//
// The *ring* all-reduce keeps every link busy equally. Put the N devices
// in a ring, and split each device's vector into N chunks.
//
//   Phase 1, reduce-scatter (N - 1 steps). In step s, device d sends its
//   chunk (d - s) mod N to device d + 1, which ADDS it to its own copy.
//   A chunk's partial sum travels around the ring collecting one
//   contribution per step. Afterwards, device d holds the complete sum of
//   chunk (d + 1) mod N.
//
//   Phase 2, all-gather (N - 1 steps). In step s, device d sends its
//   finished chunk (d + 1 - s) mod N to device d + 1, which COPIES it.
//   Afterwards, everyone has everything.
//
// Each device sends 2(N - 1) chunks of size V/N: about 2V bytes in total,
// NO MATTER HOW MANY devices. That's why it scales, and it's what NCCL
// (and multi-GPU tinygrad) use.
//
// YOUR TASK: finish both phases.
//
const std = @import("std");

const n_dev = 4;
const chunk = 2; // numbers per chunk
const len = n_dev * chunk;

var sent: usize = 0; // chunks sent over any link, in total

fn send(from: *[len]f64, to: *[len]f64, c: usize, add: bool) void {
    sent += 1;
    for (0..chunk) |i| {
        const v = from[c * chunk + i];
        if (add) to[c * chunk + i] += v else to[c * chunk + i] = v;
    }
}

fn ringAllReduce(bufs: *[n_dev][len]f64) void {
    // Phase 1: reduce-scatter. (All devices send at once in each step, so
    // take a snapshot first: everyone sends what they had at the start.)
    for (0..n_dev - 1) |s| {
        const snapshot = bufs.*;
        for (0..n_dev) |d| {
            const c = (d + n_dev - s) % n_dev;
            var from = snapshot[d];
            send(&from, &bufs[(d + 1) % n_dev], c, true);
        }
    }
    // Phase 2: all-gather.
    for (0..n_dev - 1) |s| {
        const snapshot = bufs.*;
        for (0..n_dev) |d| {
            const c = (d + 1 + n_dev - s) % n_dev;
            var from = snapshot[d];
            send(&from, &bufs[(d + 1) % n_dev], c, false);
        }
    }
}

test "every device ends with the sum" {
    var bufs: [n_dev][len]f64 = undefined;
    var total: [len]f64 = @splat(0);
    for (&bufs, 0..) |*b, d| {
        for (b, 0..) |*v, i| {
            v.* = @floatFromInt(d * 10 + i);
            total[i] += v.*;
        }
    }
    sent = 0;
    ringAllReduce(&bufs);
    for (bufs) |b| try std.testing.expectEqualSlices(f64, &total, &b);
    // each device sent 2(N - 1) chunks
    try std.testing.expectEqual(n_dev * 2 * (n_dev - 1), sent);
}
