//
// ─── Exercise 189: running UIR: movement ops and REDUCE ───────────────
//
// Weeks 4 and 5 of 10-411 add the tensor-shaped ops, and with them you
// can write any model: matmuls and convolutions are movement ops plus a
// multiply and a REDUCE (019, 020), the leading-axis way (182):
//
//   EXPAND(x, [a b])        new leading axes: x, repeated a * b times.
//   PERMUTE(x, p)           output axis i is input axis p[i]. So output
//                           index i0 i1 ... reads input index j where
//                           j[p[i]] = i_i.
//   PAD(x, off, size)       x placed at `off` inside zeros of `size`.
//   SHRINK(x, off, size)    `size` elements of x, starting at `off`.
//   RESHAPE                 the same numbers, row-major, a new shape.
//   REDUCE(x, pop=k)        combine the k leading axes away: output
//                           element j is the sum (or max, or product) of
//                           every input element whose position, past the
//                           first k axes, is j.
//
// REDUCE starts from its op's identity: 0 for add, 1 for mul, and the
// smallest value there is for max (tinygrad's identity_element).
//
// After rangeify (Chapter 37), REDUCE has a second form: no axes to pop,
// but RANGEs as extra srcs, REDUCE(x, r0, r1, op=add). It means the sum of x
// over every value of the ranges: a loop with an accumulator, like END
// but adding up instead of storing. That's what a kernel's reduction
// looks like in tinygrad between rangeify and codegen.
//
// YOUR TASK: EXPAND, PERMUTE, PAD and SHRINK in evalMovement(), and the
// combining step of evalReduce().
//
const std = @import("std");

//@export interp_movement
/// A flat position as an index, for a row-major shape (008).
fn unravel(pos: usize, shape: []const usize, idx: []usize) void {
    var rem = pos;
    var k = shape.len;
    while (k > 0) {
        k -= 1;
        idx[k] = rem % shape[k];
        rem /= shape[k];
    }
}

/// An index as a flat position, for a row-major shape (007).
fn ravel(idx: []const usize, shape: []const usize) usize {
    var pos: usize = 0;
    for (idx, shape) |i, s| pos = pos * s + i;
    return pos;
}

fn evalMovement(it: *Interp, u: *const UOp, x: Value) RunError!Value {
    const g = it.g;
    const v = it.alloc(u.dtype, u.shape);
    const idx = g.alloc.alloc(usize, @max(u.shape.len, x.shape.len)) catch @panic("out of memory");
    switch (u.op) {
        .reshape => @memcpy(v.data, x.data), // row-major order doesn't move
        .expand => {
            // new axes in front: all of x, once per position of the new axes
            const n = x.data.len;
            if (n == 0) return v;
            for (0..v.data.len / n) |rep| {
                ⟪@memcpy(v.data[rep * n .. (rep + 1) * n], x.data);|||???;⟫
            }
        },
        .permute => {
            const perm = try g.asInts(u.src[1]);
            const in_idx = g.alloc.alloc(usize, perm.len) catch @panic("out of memory");
            for (v.data, 0..) |*d, pos| {
                unravel(pos, u.shape, idx[0..u.shape.len]);
                // output axis i is input axis perm[i]
                for (perm, 0..) |axis, i| in_idx[⟪axis|||???⟫] = idx[i];
                d.* = x.data[ravel(in_idx, x.shape)];
            }
        },
        .pad => {
            const offsets = try g.asInts(u.src[1]);
            @memset(v.data, 0);
            for (x.data, 0..) |d, pos| {
                unravel(pos, x.shape, idx[0..x.shape.len]);
                for (idx[0..x.shape.len], offsets) |*i, off| ⟪i.* += off|||???⟫;
                v.data[ravel(idx[0..u.shape.len], u.shape)] = d;
            }
        },
        .shrink => {
            const offsets = try g.asInts(u.src[1]);
            for (v.data, 0..) |*d, pos| {
                unravel(pos, u.shape, idx[0..u.shape.len]);
                for (idx[0..u.shape.len], offsets) |*i, off| i.* += off;
                d.* = ⟪x.data[ravel(idx[0..x.shape.len], x.shape)]|||???⟫;
            }
        },
        else => unreachable,
    }
    return v;
}

/// Where a REDUCE starts. (tinygrad: identity_element)
fn identity(op: Op, dtype: DType) f64 {
    return switch (op) {
        .add => 0,
        .mul => 1,
        .max => if (dtype == .i32) -2147483648 else -std.math.inf(f64),
        else => unreachable,
    };
}

/// REDUCE: pop leading axes off a tensor, or combine src[0] over the
/// values of the ranges src[1..] (after rangeify).
fn evalReduce(it: *Interp, u: *const UOp) RunError!Value {
    const op = u.arg.reduce.op;
    const v = it.alloc(u.dtype, u.shape);
    @memset(v.data, identity(op, u.dtype));
    if (u.src.len == 1) {
        const x = try it.eval(u.src[0]);
        // the leading axes go; what's left is the last v.data.len of each block
        const kept = v.data.len;
        for (x.data, 0..) |d, pos| {
            const j = pos % kept;
            v.data[j] = ⟪execAlu(op, u.dtype, &.{ v.data[j], d })|||???⟫;
        }
        return v;
    }
    const ranges = u.src[1..];
    const counters = it.g.alloc.alloc(i64, ranges.len) catch @panic("out of memory");
    if (it.startLoops(ranges, counters)) {
        while (true) {
            const x = try it.eval(u.src[0]);
            for (v.data, x.data) |*acc, d| acc.* = execAlu(op, u.dtype, &.{ acc.*, d });
            if (!it.step(ranges, counters)) break;
        }
    }
    return v;
}
//@end

const t = std.testing;

fn expectRuns(text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    var it = Interp.init(&g);
    runUir(&it, text) catch |err| {
        std.debug.print("{s}: {s}{s}\n", .{ @errorName(err), it.why, g.why });
        return err;
    };
}

test "weeks 4 and 5" {
    try expectRuns(
        \\%values = add [1 2 3] (expand 1 3)
        \\%sum = reduce %values op=add pop=1
        \\%test = assert %sum 9
    );
    try expectRuns(
        \\%matrix = reshape [1 2 3 4] [2 2]
        \\%transposed = permute %matrix [1 0]
        \\%test = assert (index %transposed 1 0) 2
    );
}

test "each movement op" {
    try expectRuns("%x = expand [1 2] [3]\n%t = assert %x [[1 2] [1 2] [1 2]]");
    try expectRuns("%x = expand 5 [2 2]\n%t = assert %x [[5 5] [5 5]]");
    try expectRuns("%x = pad [1 2 3] [1] [5]\n%t = assert %x [0 1 2 3 0]");
    try expectRuns("%x = shrink [10 20 30 40] [1] [2]\n%t = assert %x [20 30]");
    try expectRuns("%x = pad (reshape [1 2 3 4] [2 2]) [0 1] [3 3]\n%t = assert %x [[0 1 2] [0 3 4] [0 0 0]]");
    try expectRuns("%x = shrink (reshape [1 2 3 4 5 6] [2 3]) [1 1] [1 2]\n%t = assert %x [[5 6]]");
    // a 3-axis permute: output [i j k] is input [j k i], so out[3 1 2] = in[1 2 3] = 1*12 + 2*4 + 3
    try expectRuns(
        \\%x = reshape [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23] [2 3 4]
        \\%p = permute %x [2 0 1]
        \\%t = assert (index %p 3 1 2) 23
        \\%u = assert (index %p 0 1 1) 16
    );
}

test "reduces" {
    try expectRuns("%x = reduce (reshape [1 2 3 4 5 6] [2 3]) op=add pop=1\n%t = assert %x [5 7 9]");
    try expectRuns("%x = reduce (reshape [1 2 3 4 5 6] [2 3]) op=max pop=2\n%t = assert %x 6");
    try expectRuns("%x = reduce (reshape [1 2 3 4 5 6] [3 2]) op=mul pop=1\n%t = assert %x [15 48]");
    try expectRuns("%x = reduce [-5 -2 -9] op=max pop=1\n%t = assert %x -2");
    // over ranges: the sum of [1 2 3 4] at r = 0..3
    try expectRuns("%r = range 4 slot=0\n%s = reduce (index [1 2 3 4] %r) %r op=add\n%t = assert %s 10");
}

test "a matmul from movement ops, the leading-axis way" {
    // C[i, j] = sum over k of A[i, k] * B[k, j]: put k in front, then pop it
    try expectRuns(
        \\%a = reshape [1 2 3 4 5 6] [2 3]
        \\%b = reshape [7 8 9 10 11 12] [3 2]
        \\%a3 = permute (expand (permute %a [1 0]) [2]) [1 2 0]
        \\%b3 = permute (expand %b [2]) [1 0 2]
        \\%c = reduce (mul %a3 %b3) op=add pop=1
        \\%t = assert %c [[58 64] [139 154]]
    );
}

test "a 1D convolution: windows by shrink, stacked" {
    // [1 2 3 4 5] with the kernel [1 0 -1], no padding: x[i] - x[i+2]
    try expectRuns(
        \\%x = [1 2 3 4 5]
        \\%win = stack (shrink %x [0] [3]) (shrink %x [1] [3]) (shrink %x [2] [3])
        \\%w = permute (expand [1 0 -1] [3]) [1 0]
        \\%y = reduce (mul %win %w) op=add pop=1
        \\%t = assert %y [-2 -2 -2]
    );
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include dtypes

//@include uop_core

//@include uop_rules

//@include alu

//@include substitute

//@include uir_parse

//@include interp
