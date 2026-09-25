// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 166: occupancy ──────────────────────────────────────────
//
// Chapter 32: how a GPU really executes. A GPU is a few dozen to a few
// hundred *streaming multiprocessors* (SMs; AMD says compute units). Each
// SM runs several blocks (077) at once, and every resident thread keeps
// its registers on the SM the whole time. So how many blocks fit is set by
// whichever resource runs out FIRST:
//
//     threads      at most max_threads resident threads per SM
//     blocks       at most max_blocks resident blocks per SM
//     registers    regs_per_thread * threads_per_block per block, out of
//                  the SM's register file
//     shared mem   each block's shared memory (078), out of the SM's
//
// *Occupancy* is the resident warps (groups of 32 threads) as a fraction
// of the most the SM can hold. More warps means more loads in flight (165)
// to hide latency. It's not everything: 155's register blocking
// deliberately uses MORE registers, lowering occupancy, to do more work
// per load. But a kernel stuck at 10% occupancy is often starving.
//
// Our SM uses numbers like an NVIDIA H100's: 2048 threads, 32 blocks,
// 65536 registers, 228 KB of shared memory. (Real hardware also rounds
// allocations up to fixed granularities; NVIDIA's occupancy calculator
// does it exactly. We skip that.)
//
// YOUR TASK: find the blocks per SM, and the occupancy.
//
const std = @import("std");

const SM = struct {
    max_threads: usize = 2048,
    max_blocks: usize = 32,
    registers: usize = 65536,
    shared: usize = 228 * 1024,
};

const Kernel = struct {
    threads_per_block: usize,
    regs_per_thread: usize,
    shared_per_block: usize,
};

const Limit = enum { threads, blocks, registers, shared };

fn blocksPerSM(sm: SM, k: Kernel) struct { blocks: usize, limit: Limit } {
    const by_threads = sm.max_threads / k.threads_per_block;
    const by_regs = sm.registers / (k.regs_per_thread * k.threads_per_block);
    const by_shared = if (k.shared_per_block == 0) sm.max_blocks else sm.shared / k.shared_per_block;

    var best: usize = sm.max_blocks;
    var limit: Limit = .blocks;
    if (by_threads < best) {
        best = by_threads;
        limit = .threads;
    }
    if (by_regs < best) {
        best = by_regs;
        limit = .registers;
    }
    if (by_shared < best) {
        best = by_shared;
        limit = .shared;
    }
    return .{ .blocks = best, .limit = limit };
}

/// Resident warps / maximum warps.
fn occupancy(sm: SM, k: Kernel) f64 {
    const blocks = blocksPerSM(sm, k).blocks;
    const warps_per_block = (k.threads_per_block + 31) / 32;
    const warps: f64 = @floatFromInt(blocks * warps_per_block);
    const max_warps: f64 = @floatFromInt(sm.max_threads / 32);
    return warps / max_warps;
}

test "a light kernel fills the SM" {
    const k: Kernel = .{ .threads_per_block = 256, .regs_per_thread = 32, .shared_per_block = 0 };
    const r = blocksPerSM(.{}, k);
    try std.testing.expectEqual(8, r.blocks);
    try std.testing.expectEqual(.threads, r.limit);
    try std.testing.expectApproxEqAbs(1.0, occupancy(.{}, k), 1e-12);
}

test "registers run out" {
    // 128 registers per thread: 65536 / (128 * 256) = 2 blocks, 16 of 64 warps
    const k: Kernel = .{ .threads_per_block = 256, .regs_per_thread = 128, .shared_per_block = 0 };
    try std.testing.expectEqual(.registers, blocksPerSM(.{}, k).limit);
    try std.testing.expectApproxEqAbs(0.25, occupancy(.{}, k), 1e-12);
}

test "shared memory runs out" {
    // 64 KB tiles: only 3 blocks fit in 228 KB
    const k: Kernel = .{ .threads_per_block = 128, .regs_per_thread = 32, .shared_per_block = 64 * 1024 };
    const r = blocksPerSM(.{}, k);
    try std.testing.expectEqual(3, r.blocks);
    try std.testing.expectEqual(.shared, r.limit);
    try std.testing.expectApproxEqAbs(12.0 / 64.0, occupancy(.{}, k), 1e-12);
}

test "tiny blocks hit the block limit" {
    const k: Kernel = .{ .threads_per_block = 32, .regs_per_thread = 16, .shared_per_block = 0 };
    try std.testing.expectEqual(.blocks, blocksPerSM(.{}, k).limit);
    try std.testing.expectApproxEqAbs(0.5, occupancy(.{}, k), 1e-12);
}
