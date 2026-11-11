// HARD MODE (zig build -Dhard): no blanks to fill in. Every function
// marked ??? has lost its whole body: write it, from its doc comment,
// its signature and the tests. The gentler version of this file is in
// exercises/, and the answer in solutions/.
//
// ─── Exercise 078: shared memory and barriers ──────────────────────────
//
// Threads in the same block can cooperate through *shared memory*
// (CUDA's name; OpenCL and tinygrad say "local memory"): a small, very
// fast scratchpad the whole block can read and write.
//
// Summing within a block uses the tree from 047, in shared memory:
//
//     every thread:          sh[tid] = x[gid]
//     BARRIER
//     for stride = bs/2, bs/4, ..., 1:
//         if tid < stride:   sh[tid] += sh[tid + stride]
//         BARRIER
//     thread 0 writes sh[0], the block's partial sum
//
// The BARRIERs are essential. Threads don't run in perfect lockstep, so
// without them thread 0 might read sh[stride] before the thread that owns
// it has finished writing it, in the load or in the previous step. A
// barrier means "nobody continues until everyone has arrived here".
//
// The simulation below runs each "phase" (the code between barriers) for
// every thread before moving on, which is what a barrier guarantees.
// runWithoutBarriers() instead runs each thread start to finish, one after
// another. Thread 0 then adds up slots nobody has filled yet. The last
// test shows the difference.
//
// A full sum is then two levels: each block writes a partial sum, and a
// second (tiny) kernel adds those up. tinygrad generates this kind of
// code when it splits a reduce axis into LOCAL threads ("grouping", 047).
//
// YOUR TASK: write the tree step.
//
const std = @import("std");

const bs = 8; // threads per block

const Block = struct {
    sh: [bs]f32 = @splat(0), // shared memory
    x: []const f32,
    block_id: usize,

    fn phases() usize {
        return 1 + std.math.log2_int(usize, bs); // load, then log2(bs) tree steps
    }

    /// What thread `tid` does in phase `p` (between two barriers).
    fn phase(b: *Block, tid: usize, p: usize) void {
        ???; // write this function's body
    }
};

fn runWithBarriers(b: *Block) f32 {
    for (0..Block.phases()) |p| {
        for (0..bs) |tid| b.phase(tid, p);
        // BARRIER: every thread finished phase p
    }
    return b.sh[0];
}

/// A bad timing: thread 0 runs start to finish, then thread 1, ...
fn runWithoutBarriers(b: *Block) f32 {
    for (0..bs) |tid| {
        for (0..Block.phases()) |p| b.phase(tid, p);
    }
    return b.sh[0];
}

fn blockSums(x: []const f32, partials: []f32) void {
    for (partials, 0..) |*p, block_id| {
        var b: Block = .{ .x = x, .block_id = block_id };
        p.* = runWithBarriers(&b);
    }
}

test "one block" {
    var x: [8]f32 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var b: Block = .{ .x = &x, .block_id = 0 };
    try std.testing.expectEqual(36, runWithBarriers(&b));
}

test "two levels: blocks, then the partials" {
    var x: [50]f32 = undefined;
    for (&x, 0..) |*v, i| v.* = @floatFromInt(i + 1);
    var partials: [7]f32 = undefined; // ceil(50 / 8)
    blockSums(&x, &partials);
    var total: f32 = 0;
    for (partials) |p| total += p;
    try std.testing.expectEqual(1275, total); // 1 + 2 + ... + 50
}

/// The same barriers, but inside each phase the threads go in the
/// opposite order. A GPU promises nothing about that order, so a
/// correct block must give the same answer either way.
fn runWithBarriersBackwards(b: *Block) f32 {
    for (0..Block.phases()) |p| {
        var tid: usize = bs;
        while (tid > 0) {
            tid -= 1;
            b.phase(tid, p);
        }
    }
    return b.sh[0];
}

test "any order within a phase" {
    var x: [8]f32 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var b: Block = .{ .x = &x, .block_id = 0 };
    try std.testing.expectEqual(36, runWithBarriersBackwards(&b));
}

test "without barriers, the answer is wrong" {
    var x: [8]f32 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var b: Block = .{ .x = &x, .block_id = 0 };
    try std.testing.expect(runWithoutBarriers(&b) != 36);
}
