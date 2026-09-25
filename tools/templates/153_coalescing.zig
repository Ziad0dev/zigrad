//
// ─── Exercise 153: coalesced memory access ─────────────────────────────
//
// On a GPU, the 32 threads of a *warp* execute each load instruction
// together. The memory system serves them in 128-byte *segments*. If all
// 32 threads read neighbouring floats (thread t reads address base + 4t),
// that's 128 contiguous bytes: ONE transaction for the whole warp. The
// access is *coalesced*.
//
// If thread t reads base + 4 * t * stride instead, the reads spread out:
// stride 2 needs 2 segments, stride 32 needs 32 (a full transaction per
// thread, fetching 128 bytes to use 4). Same instruction, up to 32x the
// memory traffic.
//
// This is why tinygrad (and every GPU compiler) cares which loop variable
// becomes the thread index: the one that walks memory with stride 1
// should vary fastest across threads.
//
// YOUR TASK: count the segments a warp's addresses touch.
//
const std = @import("std");

const warp = 32;
const segment = 128;

fn transactions(addrs: [warp]usize) usize {
    var seen: [warp]usize = undefined;
    var count: usize = 0;
    for (addrs) |a| {
        const seg = ⟪a / segment|||???⟫;
        if (⟪std.mem.indexOfScalar(usize, seen[0..count], seg) == null|||???⟫) {
            seen[count] = seg;
            count += 1;
        }
    }
    return count;
}

fn strided(base: usize, stride: usize) [warp]usize {
    var out: [warp]usize = undefined;
    for (&out, 0..) |*a, t| a.* = base + 4 * t * stride;
    return out;
}

test "coalesced vs strided" {
    try std.testing.expectEqual(1, transactions(strided(0, 1)));
    try std.testing.expectEqual(2, transactions(strided(0, 2)));
    try std.testing.expectEqual(32, transactions(strided(0, 32)));
}

test "misaligned by one float: two segments" {
    try std.testing.expectEqual(2, transactions(strided(4, 1)));
}
