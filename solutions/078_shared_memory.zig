// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
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
//     for stride = bs/2, bs/4, ..., 1:
//         if tid < stride:   sh[tid] += sh[tid + stride]
//         BARRIER
//     thread 0 writes sh[0], the block's partial sum
//
// The BARRIER is essential. Threads don't run in perfect lockstep, so
// without it thread 0 might read sh[stride] before the thread that owns it
// has finished writing its value from the previous step. A barrier means
// "nobody continues until everyone has arrived here".
//
// The simulation below runs each "phase" (the code between barriers) for
// every thread before moving on, which is what a barrier guarantees.
// runWithoutBarriers() instead runs each thread start to finish, one after
// another. Thread 0 then adds up slots nobody has filled yet. The last
// test shows the difference.
//
// A full sum is then two levels: each block writes a partial sum, and a
// second (tiny) kernel adds those up. tinygrad's GROUP optimization
// generates this kind of code.
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
        if (p == 0) {
            const gid = b.block_id * bs + tid;
            b.sh[tid] = if (gid < b.x.len) b.x[gid] else 0;
            return;
        }
        const stride = @as(usize, bs) >> @intCast(p); // bs/2, bs/4, ..., 1
        if (tid < stride) b.sh[tid] += b.sh[tid + stride];
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

test "without barriers, the answer is wrong" {
    var x: [8]f32 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var b: Block = .{ .x = &x, .block_id = 0 };
    try std.testing.expect(runWithoutBarriers(&b) != 36);
}
