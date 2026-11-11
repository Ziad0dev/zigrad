//
// ─── Exercise 196: splitting a range ──────────────────────────────────
//
// Chapter 38: codegen, the way tinygrad does it today
// (tinygrad/codegen/opt/postrange.py). 195's kernels are correct and slow.
// Making them fast is mostly ONE move, applied with different arguments:
// split a loop in two, and give the inner piece a job (079).
//
//     for r in 0..n                   for o in 0..n/4
//         body(r)            ->           for i in 0..4      <- this piece
//                                             body(o*4 + i)     is "UPCAST"
//
// tinygrad's only OptOp left for this is SPLIT, with an amount and an
// AxisType for the new piece: Opt(OptOps.SPLIT, axis, (4, AxisType.UPCAST)).
// What the types mean:
//
//     LOOP, WEAK   a plain loop
//     GLOBAL       a GPU grid dimension (077); LOCAL a block dimension
//     UPCAST       not a loop at all: unrolled, n copies in a row (197).
//                  On a reduce range that's what older tinygrad called UNROLL.
//
// The move itself is shift_to: a new RANGE of `amt` values, the old one
// shrunk to n / amt, and every use of the old range replaced:
//
//     top = false:   r -> old * amt + new      (new is the fast-changing piece)
//     top = true:    r -> new * (n/amt) + old  (new is the slow-changing piece)
//
// substitute() (184) does the replacing. Then END and REDUCE, which list
// RANGEs as srcs, have an expression where a RANGE was: list the RANGEs in
// it instead (tinygrad: pm_flatten_range).
//
// And tinygrad's checks, before it does anything:
//   * UPCAST splits a GLOBAL, LOCAL or WEAK range; LOCAL splits GLOBAL or
//     WEAK. (split_targets)
//   * amt must divide n.
//   * UPCAST at most 32 on a reduce range ("don't unroll more than 32"),
//     at most 16 on any other ("don't upcast more than 16").
//
// YOUR TASK: the two substitutions and the size checks in shiftTo().
//
const std = @import("std");

//@export shift_to
const AxisType = enum { weak, loop, global, local, upcast };

const OptError = Error || error{KernelOpt};

/// A kernel body, the types of its ranges, and the opts applied so far.
const Sched = struct {
    g: *Graph,
    ast: *const UOp,
    types: std.AutoHashMap(i64, AxisType), // range slot -> type (WEAK if not here)
    why: []const u8 = "",

    fn init(g: *Graph, ast: *const UOp) Sched {
        return .{ .g = g, .ast = ast, .types = .init(g.alloc) };
    }

    fn typeOf(s: *Sched, r: *const UOp) AxisType {
        return s.types.get(r.arg.int) orelse .weak;
    }

    fn check(s: *Sched, ok: bool, why: []const u8) OptError!void {
        if (ok) return;
        s.why = why;
        return error.KernelOpt;
    }

    /// The kernel's RANGEs, in slot order.
    fn ranges(s: *Sched) []const *const UOp {
        var out: std.ArrayList(*const UOp) = .empty;
        for (toposort(s.g, s.ast, false)) |u| {
            if (u.op == .range) out.append(s.g.alloc, u) catch @panic("out of memory");
        }
        std.mem.sort(*const UOp, out.items, {}, struct {
            fn lt(_: void, a: *const UOp, b: *const UOp) bool {
                return a.arg.int < b.arg.int;
            }
        }.lt);
        return out.items;
    }

    fn isReduce(s: *Sched, r: *const UOp) bool {
        for (toposort(s.g, s.ast, false)) |u| {
            if (u.op == .reduce and std.mem.indexOfScalar(*const UOp, u.src[1..], r) != null) return true;
        }
        return false;
    }

    fn nextSlot(s: *Sched) i64 {
        var m: i64 = -1;
        for (s.ranges()) |r| m = @max(m, r.arg.int);
        return m + 1;
    }

    /// tinygrad's shift_to: split r, of n values, into n/amt and amt.
    /// Checks, in this order and with these messages in `why` (the
    /// tests compare them): that the type may be split off (split_targets:
    /// "that type can't be split off that range"), that 1 < amt and amt
    /// divides n ("amt can't divide the range"), and for UPCAST the size
    /// limits ("don't unroll more than 32" on a reduce range, "don't
    /// upcast more than 16" otherwise). The new range of amt gets the
    /// next slot, and its type goes into `types`; the old range keeps its
    /// slot, now n/amt long. `top` puts the new range outside: new *
    /// (n/amt) + old; otherwise old * amt + new.
    fn shiftTo(s: *Sched, r: *const UOp, amt: usize, new_type: AxisType, top: bool) OptError!struct { old: *const UOp, new: *const UOp } {
        const g = s.g;
        const old_type = s.typeOf(r);
        try s.check(switch (new_type) {
            .upcast => old_type == .global or old_type == .local or old_type == .weak,
            .local => old_type == .global or old_type == .weak,
            else => false,
        }, "that type can't be split off that range");
        const n: usize = @intCast(r.src[0].intValue().?);
        try s.check(amt > 1 and n % amt == 0, "amt can't divide the range");
        if (new_type == .upcast) {
            if (s.isReduce(r)) {
                try s.check(⟪amt <= 32|||???⟫, "don't unroll more than 32");
            } else try s.check(⟪amt <= 16|||???⟫, "don't upcast more than 16");
        }
        const new = g.range(amt, s.nextSlot());
        const old = g.range(n / amt, r.arg.int); // same slot: same axis, now shorter
        s.types.put(new.arg.int, new_type) catch @panic("out of memory");
        const sub_axis = if (top)
            ⟪try g.add(try g.mul(new, g.int(@intCast(n / amt))), old)|||???⟫
        else
            ⟪try g.add(try g.mul(old, g.int(@intCast(amt))), new)|||???⟫;
        var map = Subst.init(g.alloc);
        map.put(r, sub_axis) catch @panic("out of memory");
        s.ast = try flattenRanges(g, try substitute(g, s.ast, &map));
        return .{ .old = old, .new = new };
    }
};

/// END and REDUCE list RANGEs as srcs: where a substitution left an
/// expression, list the RANGEs in it instead. (tinygrad: pm_flatten_range)
fn flattenRanges(g: *Graph, root: *const UOp) Error!*const UOp {
    var done = Subst.init(g.alloc);
    for (toposort(g, root, false)) |u| {
        var src: std.ArrayList(*const UOp) = .empty;
        for (u.src, 0..) |x, i| {
            const s = done.get(x) orelse x;
            const lists_ranges = (u.op == .end or u.op == .reduce) and i > 0;
            if (!lists_ranges or s.op == .range) {
                src.append(g.alloc, s) catch @panic("out of memory");
                continue;
            }
            for (toposort(g, s, false)) |y| {
                if (y.op == .range and std.mem.indexOfScalar(*const UOp, src.items, y) == null) src.append(g.alloc, y) catch @panic("out of memory");
            }
        }
        done.put(u, try g.new(u.op, src.items, u.arg)) catch @panic("out of memory");
    }
    return done.get(root).?;
}
//@end

const t = std.testing;

fn gemm(g: *Graph, a_buf: *const UOp, b_buf: *const UOp, n: usize) !*const UOp {
    const a = try g.reshape(a_buf, &.{ n, n });
    const b = try g.reshape(b_buf, &.{ n, n });
    const a3 = try g.permute(try g.expand(try g.permute(a, &.{ 1, 0 }), &.{n}), &.{ 1, 2, 0 });
    const b3 = try g.permute(try g.expand(b, &.{n}), &.{ 1, 0, 2 });
    return g.reduce(try g.mul(a3, b3), .add, 1);
}

/// Run a kernel body (with its buffers as PARAMs) through a CALL, return the output.
fn runKernel(g: *Graph, call: *const UOp, body: *const UOp, data: []const []const f64) ![]f64 {
    var it = Interp.init(g);
    for (call.src[1..], 0..) |arg, j| {
        var buf = arg;
        while (buf.op == .after) buf = buf.src[0];
        if (j > 0) @memcpy(it.storage(buf), data[j - 1]);
    }
    _ = try it.eval(try g.call(body, call.src[1..]));
    var out = call.src[1];
    while (out.op == .after) out = out.src[0];
    return it.storage(out);
}

test "split, and the kernel computes the same thing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const n = 8;
    const a = g.buffer(0, .f32, n * n);
    const b = g.buffer(1, .f32, n * n);
    const s = try schedule(&g, &.{try gemm(&g, a, b, n)});
    const call = s.calls[0];
    var data: [2][n * n]f64 = undefined;
    for (&data[0], &data[1], 0..) |*x, *y, i| {
        x.* = @floatFromInt(i % 7);
        y.* = @floatFromInt(i % 5);
    }
    const want = try g.alloc.dupe(f64, try runKernel(&g, call, call.src[0], &.{ &data[0], &data[1] }));

    var sched = Sched.init(&g, call.src[0]);
    const rs = sched.ranges(); // the two output axes, then the reduce
    try t.expectEqual(3, rs.len);
    try t.expect(sched.isReduce(rs[2]));
    _ = try sched.shiftTo(rs[1], 4, .upcast, false); // j: upcast by 4
    _ = try sched.shiftTo(rs[2], 2, .upcast, true); //  the reduce: unroll by 2, the slow piece
    try t.expectEqual(5, sched.ranges().len);
    try t.expectEqualSlices(f64, want, try runKernel(&g, call, sched.ast, &.{ &data[0], &data[1] }));
}

test "what a split does to the index" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const buf = g.buffer(0, .f32, 16);
    const r = g.range(16, 0);
    const ast = try g.sink(&.{try g.end(try g.store(try g.index(buf, &.{r}), g.float(1)), &.{r})});
    var s = Sched.init(&g, ast);
    const split = try s.shiftTo(r, 4, .upcast, false);
    try t.expectEqual(4, split.old.src[0].intValue().?);
    try t.expectEqual(4, split.new.src[0].intValue().?);
    // the store now writes buf[old * 4 + new], and the END lists both ranges
    const end = s.ast.src[0];
    try t.expect(end.src[0].src[0].src[1] == try g.add(try g.mul(split.old, g.int(4)), split.new));
    try t.expectEqual(3, end.src.len);
    // top = true makes the new piece the slow one
    var s2 = Sched.init(&g, ast);
    const top = try s2.shiftTo(r, 2, .upcast, true);
    try t.expect(s2.ast.src[0].src[0].src[0].src[1] == try g.add(try g.mul(top.new, g.int(8)), top.old));
}

test "tinygrad's checks" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const buf = g.buffer(0, .f32, 64);
    const r = g.range(64, 0);
    const k = g.range(64, 1);
    const sum = try g.new(.reduce, &.{ try g.index(buf, &.{k}), k }, .{ .reduce = .{ .op = .add, .pop = 0 } });
    const ast = try g.sink(&.{try g.end(try g.store(try g.index(buf, &.{r}), sum), &.{r})});
    var s = Sched.init(&g, ast);
    try t.expectError(error.KernelOpt, s.shiftTo(r, 3, .upcast, false)); // 3 doesn't divide 64
    try t.expectEqualStrings("amt can't divide the range", s.why);
    try t.expectError(error.KernelOpt, s.shiftTo(r, 32, .upcast, false));
    try t.expectEqualStrings("don't upcast more than 16", s.why);
    _ = try s.shiftTo(r, 16, .upcast, false); // 16 is fine
    try t.expectError(error.KernelOpt, s.shiftTo(k, 64, .upcast, false));
    try t.expectEqualStrings("don't unroll more than 32", s.why);
    _ = try s.shiftTo(k, 32, .upcast, false); // a reduce can unroll to 32
    // the limits are exact: 17 and 33 are one too many, even when they divide
    const r34 = g.range(34, 2);
    const k66 = g.range(66, 3);
    const sum66 = try g.new(.reduce, &.{ try g.index(buf, &.{try g.alu(.mod, &.{ k66, g.int(64) })}), k66 }, .{ .reduce = .{ .op = .add, .pop = 0 } });
    var s3 = Sched.init(&g, try g.sink(&.{try g.end(try g.store(try g.index(buf, &.{try g.alu(.mod, &.{ r34, g.int(64) })}), sum66), &.{r34})}));
    try t.expectError(error.KernelOpt, s3.shiftTo(r34, 17, .upcast, false));
    try t.expectError(error.KernelOpt, s3.shiftTo(k66, 33, .upcast, false));
    // the UPCAST piece can't itself be split into a LOCAL
    const up = s.ranges()[2];
    try t.expectEqual(.upcast, s.typeOf(up));
    try t.expectError(error.KernelOpt, s.shiftTo(up, 2, .local, false));
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

//@include bounds

//@include uir_parse

//@include uir_print

//@include interp

//@include interp_movement

//@include symbolic

//@include movement_ranges

//@include rangeify_walk

//@include rangeify_lower

//@include kernels
