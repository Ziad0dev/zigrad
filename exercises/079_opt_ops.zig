//
// ─── Exercise 079: OptOps, reshaping the loops ─────────────────────────
//
// A kernel's loop structure is just a list of axes: sizes plus kinds.
// tinygrad optimizes a kernel by applying *OptOps*, each of which splits
// one axis in two and gives the new piece a special job:
//
//   LOCAL(axis, n)    split a global axis; the n-sized piece becomes the
//                     block/workgroup dimension (077). Threads in a block
//                     can share data (078).
//   UPCAST(axis, n)   split a global axis; the n-sized piece is done by
//                     ONE thread, unrolled into registers: each thread
//                     computes n outputs (045).
//   UNROLL(axis, n)   split a reduce axis; unroll n steps of the reduce
//                     loop in the code.
//
// Splitting axis size s by n leaves s / n on the old axis, and adds a new
// n-sized axis of the new kind. s must divide evenly. The total amount of
// work never changes: only who does it, and in what order.
//
// A 64x64 matmul (K = 64) after LOCAL(0,16) LOCAL(1,16) UPCAST(0,4)
// UNROLL(2,4):
//
//     axes:  [1 global] [4 global] [16 reduce] [16 local] [16 local] [4 upcast] [4 unroll]
//     4 blocks of 16*16 = 256 threads, each computing 4 outputs,
//     with a reduce loop of 16 iterations doing 4 multiply-adds each.
//
// BEAM search (048) just tries lots of these OptOp lists and times them.
//
// YOUR TASK: finish apply() and the launch numbers.
//
const std = @import("std");

const Kind = enum { global, reduce, local, upcast, unroll };
const Axis = struct { size: usize, kind: Kind };
const OptOp = enum { local, upcast, unroll };
const Opt = struct { op: OptOp, axis: usize, amount: usize };

const Kernel = struct {
    axes: [16]Axis = undefined,
    n: usize = 0,

    fn init(globals: []const usize, reduces: []const usize) Kernel {
        var k: Kernel = .{};
        for (globals) |s| k.push(.{ .size = s, .kind = .global });
        for (reduces) |s| k.push(.{ .size = s, .kind = .reduce });
        return k;
    }

    fn push(k: *Kernel, a: Axis) void {
        k.axes[k.n] = a;
        k.n += 1;
    }

    fn apply(k: *Kernel, opt: Opt) error{ WrongAxisKind, DoesNotDivide }!void {
        const ax = &k.axes[opt.axis];
        const needs: Kind = if (opt.op == .unroll) .reduce else .global;
        if (ax.kind != needs) return error.WrongAxisKind;
        if (???) return error.DoesNotDivide;
        ???;
        k.push(.{ .size = opt.amount, .kind = switch (opt.op) {
            .local => .local,
            .upcast => .upcast,
            .unroll => .unroll,
        } });
    }

    fn product(k: Kernel, kind: Kind) usize {
        var p: usize = 1;
        for (k.axes[0..k.n]) |a| {
            if (a.kind == kind) p *= a.size;
        }
        return p;
    }

    /// Total multiply-adds (or whatever the body does): never changes.
    fn work(k: Kernel) usize {
        var p: usize = 1;
        for (k.axes[0..k.n]) |a| p *= a.size;
        return p;
    }

    fn blocks(k: Kernel) usize {
        return k.product(.global);
    }
    fn threadsPerBlock(k: Kernel) usize {
        return ???;
    }
    fn outputsPerThread(k: Kernel) usize {
        return ???;
    }
    fn reduceIterations(k: Kernel) usize {
        return k.product(.reduce);
    }
};

test "optimizing a 64x64x64 matmul" {
    var k = Kernel.init(&.{ 64, 64 }, &.{64});
    const before = k.work();
    try k.apply(.{ .op = .local, .axis = 0, .amount = 16 });
    try k.apply(.{ .op = .local, .axis = 1, .amount = 16 });
    try k.apply(.{ .op = .upcast, .axis = 0, .amount = 4 });
    try k.apply(.{ .op = .unroll, .axis = 2, .amount = 4 });

    try std.testing.expectEqual(before, k.work()); // same work, rearranged
    try std.testing.expectEqual(4, k.blocks());
    try std.testing.expectEqual(256, k.threadsPerBlock());
    try std.testing.expectEqual(4, k.outputsPerThread());
    try std.testing.expectEqual(16, k.reduceIterations());
    // every output computed exactly once
    try std.testing.expectEqual(64 * 64, k.blocks() * k.threadsPerBlock() * k.outputsPerThread());
}

test "invalid OptOps are refused" {
    var k = Kernel.init(&.{ 64, 64 }, &.{64});
    try std.testing.expectError(error.WrongAxisKind, k.apply(.{ .op = .upcast, .axis = 2, .amount = 4 }));
    try std.testing.expectError(error.WrongAxisKind, k.apply(.{ .op = .unroll, .axis = 0, .amount = 4 }));
    try std.testing.expectError(error.DoesNotDivide, k.apply(.{ .op = .local, .axis = 0, .amount = 3 }));
}
