//
// ─── Exercise 192: where kernels split ────────────────────────────────
//
// 191 moved ranges through one op. Rangeify (run_rangeify in
// tinygrad/schedule/indexing.py) moves them through the WHOLE graph, from
// the outputs toward the inputs, and on the way decides the most
// important question in an ML compiler: which values get their own
// buffer. Every value that does ("realize" it, 040, 081) is the output of
// one kernel. Everything else is computed inline, inside its consumer's
// loops: that's kernel fusion.
//
// Visit the UOps consumers-first (the toposort, reversed). Each one gets
// the ranges its OUTPUT is indexed by, "out", and passes "in" down to its
// srcs:
//
//   1. A realized value starts fresh: one new RANGE per axis. (An axis of
//      size 1 gets the constant 0, not a RANGE: tinygrad's new_range.)
//   2. One consumer: take its ranges. That's fusion, for free.
//   3. Several consumers that all index it the same way: same thing.
//      But if they disagree (x[i, j] here, x[j, i] there), one loop nest
//      can't produce both: realize it, with fresh ranges.
//   4. in = out for ALU ops. A movement op maps them (191). A REDUCE adds
//      fresh ranges in front, one per axis it pops: those are its loops.
//      (And a STACK's leading range picks one of its srcs, so its srcs get
//      the ranges after it.)
//
// And one more rule, tinygrad's "ending ranges". An EXPAND whose new axes
// are real loops reuses everything below it once per value of those loops.
// If what's below is a computed value, that's the same work again and
// again, so the first ALU op or REDUCE below an EXPAND like that is
// realized. ("fusion decision: REDUCE before the broadcast".)
//
// Softmax comes out as FOUR buffers here: the max, x - max (its two
// readers, the sum and the divide, index it differently: rule 3), the sum,
// and the output. tinygrad agrees, at this stage. Then a cost check
// throws away buffers that are cheap to recompute, and x - max is one:
// that's 194, and it's how tinygrad's softmax ends up as three kernels.
//
// YOUR TASK: rules 2, 3 and 4, and realizing below a broadcast.
//
const std = @import("std");

//@export rangeify_walk
const Ranges = struct { in: []const *const UOp, out: []const *const UOp };

const Rangeify = struct {
    g: *Graph,
    realize: std.AutoArrayHashMapUnmanaged(*const UOp, void) = .empty, // the values that get a buffer: one kernel each
    ranges: std.AutoHashMap(*const UOp, Ranges),
    slot: i64 = 0,

    fn init(g: *Graph) Rangeify {
        return .{ .g = g, .ranges = .init(g.alloc) };
    }

    /// One new RANGE per axis, or 0 for an axis of size 1. (tinygrad: new_range)
    fn fresh(rf: *Rangeify, shape: []const usize) []const *const UOp {
        const out = rf.g.alloc.alloc(*const UOp, shape.len) catch @panic("out of memory");
        for (out, shape) |*r, n| {
            if (n == 1) {
                r.* = rf.g.int(0);
            } else {
                r.* = rf.g.range(n, rf.slot);
                rf.slot += 1;
            }
        }
        return out;
    }

    fn sameRanges(a: []const *const UOp, b: []const *const UOp) bool {
        return std.mem.eql(*const UOp, a, b);
    }

    /// Run rangeify over the graph under `sink`, whose srcs are the outputs.
    fn walk(rf: *Rangeify, sink: *const UOp) Error!void {
        const g = rf.g;
        const order = toposort(g, sink, false);
        // who reads each UOp as data (not a movement op's shape arguments)
        var consumers = std.AutoHashMap(*const UOp, std.ArrayList(*const UOp)).init(g.alloc);
        for (order) |c| {
            const data = if (c.op.isMovement() or c.op == .reduce) c.src[0..1] else c.src;
            for (data) |s| {
                const gop = consumers.getOrPut(s) catch @panic("out of memory");
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.append(g.alloc, c) catch @panic("out of memory");
            }
        }
        for (sink.src) |out| rf.realize.put(g.alloc, out, {}) catch @panic("out of memory");

        var ending = std.AutoHashMap(*const UOp, bool).init(g.alloc);
        var i = order.len;
        while (i > 0) {
            i -= 1;
            const x = order[i];
            switch (x.op) {
                .sink, .constant, .buffer, .param => continue, // no loops of their own
                else => {},
            }
            const users = if (consumers.get(x)) |c| c.items else &.{};
            var end = false;
            for (users) |c| end = end or (ending.get(c) orelse false);
            var seen: std.ArrayList([]const *const UOp) = .empty;
            for (users) |c| {
                if (rf.ranges.get(c)) |r| seen.append(g.alloc, r.in) catch @panic("out of memory");
            }

            var out: []const *const UOp = undefined;
            if (rf.realize.contains(x)) {
                out = rf.fresh(x.shape);
                end = false;
            } else if (seen.items.len == 0) {
                continue; // nothing reads it with ranges: e.g. a shape argument
            } else if (seen.items.len == 1) {
                out = ⟪seen.items[0]|||???⟫;
            } else {
                var agree = true;
                for (seen.items[1..]) |s| agree = agree and sameRanges(s, seen.items[0]);
                if (agree) {
                    out = seen.items[0];
                } else {
                    ⟪rf.realize.put(g.alloc, x, {}) catch @panic("out of memory");|||???;⟫
                    out = rf.fresh(x.shape);
                }
            }

            // reused across a broadcast's loops: compute it once instead
            const computes = x.op.isAlu() or x.op == .reduce;
            if (end and computes) {
                end = false;
                rf.realize.put(g.alloc, x, {}) catch @panic("out of memory");
                out = ⟪rf.fresh(x.shape)|||???⟫;
            }

            var in = out;
            if (x.op.isMovement()) in = (try applyMovement(g, x, out, g.boolean(true))).idx;
            if (x.op == .stack) in = out[1..]; // the leading range picks the src; srcs get the rest
            if (x.op == .reduce) {
                const popped = x.src[0].shape[0..x.arg.reduce.pop];
                in = std.mem.concat(g.alloc, *const UOp, &.{ ⟪rf.fresh(popped)|||???⟫, out }) catch @panic("out of memory");
            }
            // an EXPAND whose new axes are real loops ends here
            if (x.op == .expand) {
                const front = (try g.asInts(x.src[1])).len;
                for (out[0..front]) |r| {
                    if (r.op == .range) end = true;
                }
            }
            ending.put(x, end) catch @panic("out of memory");
            rf.ranges.put(x, .{ .in = in, .out = out }) catch @panic("out of memory");
        }
    }
};
//@end

const t = std.testing;

fn kernels(g: *Graph, outputs: []const *const UOp) !Rangeify {
    var rf = Rangeify.init(g);
    try rf.walk(try g.sink(outputs));
    return rf;
}

test "an elementwise chain is one kernel" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 8);
    const y = try g.add(try g.mul(x, try g.expand(g.float(2), &.{8})), try g.expand(g.float(1), &.{8}));
    const rf = try kernels(&g, &.{y});
    try t.expectEqual(1, rf.realize.count());
    // and its loop runs over all of x
    try t.expectEqual(.range, rf.ranges.get(y).?.out[0].op);
    // the mul inside runs in the very same loop: that's fusion
    try t.expect(rf.ranges.get(y.src[0]).?.out[0] == rf.ranges.get(y).?.out[0]);
}

test "a sum is one kernel, with a loop for the reduce" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = try g.reshape(g.buffer(0, .f32, 12), &.{ 3, 4 });
    const s = try g.reduce(x, .add, 1); // sum over the 3 rows: shape (4)
    const rf = try kernels(&g, &.{s});
    try t.expectEqual(1, rf.realize.count());
    const r = rf.ranges.get(s).?;
    try t.expectEqual(1, r.out.len); // the output loop
    try t.expectEqual(2, r.in.len); //  plus the reduce loop in front
    try t.expect(r.in[1] == r.out[0]);
    try t.expect(r.in[0] != r.out[0]);
}

test "softmax: four buffers, for now" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 16);
    const m = try g.reduce(x, .max, 1);
    const d = try g.add(x, try g.mul(try g.expand(m, &.{16}), try g.expand(g.float(-1), &.{16}))); // x - max
    const s = try g.reduce(d, .add, 1); // (no exp in our op set: it changes nothing here)
    const inv = try g.alu(.recip, &.{s});
    const y = try g.mul(d, try g.expand(inv, &.{16}));
    const rf = try kernels(&g, &.{y});
    try t.expectEqual(4, rf.realize.count());
    try t.expect(rf.realize.contains(m)); //   the reduce before a broadcast
    try t.expect(rf.realize.contains(inv)); // the first computed value below the other broadcast
    try t.expect(!rf.realize.contains(s)); //  so the sum is computed inside inv's kernel
    try t.expect(rf.realize.contains(d)); //   read two different ways (194 undoes this one)
    try t.expect(rf.realize.contains(y)); //   the output
}

test "a matmul is one kernel" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const a = try g.reshape(g.buffer(0, .f32, 6), &.{ 2, 3 });
    const b = try g.reshape(g.buffer(1, .f32, 12), &.{ 3, 4 });
    const a3 = try g.permute(try g.expand(try g.permute(a, &.{ 1, 0 }), &.{4}), &.{ 1, 2, 0 });
    const b3 = try g.permute(try g.expand(b, &.{2}), &.{ 1, 0, 2 });
    const c = try g.reduce(try g.mul(a3, b3), .add, 1);
    const rf = try kernels(&g, &.{c});
    try t.expectEqual(1, rf.realize.count()); // only movement ops under the EXPANDs
}

test "consumers that disagree force a buffer" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = try g.reshape(g.buffer(0, .f32, 9), &.{ 3, 3 });
    const y = try g.add(x, try g.expand(g.float(1), &.{ 3, 3 }));
    // y + y.T: one loop nest can't produce y[i, j] and y[j, i] at once
    const rf = try kernels(&g, &.{try g.add(y, try g.permute(y, &.{ 1, 0 }))});
    try t.expectEqual(2, rf.realize.count());
    try t.expect(rf.realize.contains(y));
    // y * y reads it the same way twice: no buffer needed
    const rf2 = try kernels(&g, &.{try g.mul(y, y)});
    try t.expectEqual(1, rf2.realize.count());
    // x + x.T: x is a RESHAPE of a buffer, read two ways, so it gets a buffer
    // too, for now. "If a buffer is being stored just for permutes or
    // something, remove it" says tinygrad's remove_bufferize: that's 194.
    const rf3 = try kernels(&g, &.{try g.add(x, try g.permute(x, &.{ 1, 0 }))});
    try t.expectEqual(2, rf3.realize.count());
    try t.expect(rf3.realize.contains(x));
}

test "a computed value is broadcast: compute it once" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 4);
    const w = try g.reshape(g.buffer(1, .f32, 12), &.{ 3, 4 });
    const y = try g.mul(x, try g.expand(g.float(2), &.{4}));
    const rf = try kernels(&g, &.{try g.add(try g.expand(y, &.{3}), w)});
    try t.expectEqual(2, rf.realize.count());
    try t.expect(rf.realize.contains(y));
    // with a loop of its own, not the broadcast's
    const e = try g.expand(y, &.{3});
    try t.expect(rf.ranges.get(y).?.out[0] != rf.ranges.get(e).?.in[0]);
    // but broadcasting a buffer costs nothing
    const rf2 = try kernels(&g, &.{try g.add(try g.expand(x, &.{3}), w)});
    try t.expectEqual(1, rf2.realize.count());
}

test "an axis of size 1 gets the constant 0, not a loop" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = try g.reshape(g.buffer(0, .f32, 4), &.{ 1, 4 });
    const y = try g.add(x, try g.expand(g.float(1), &.{ 1, 4 }));
    const rf = try kernels(&g, &.{y});
    const out = rf.ranges.get(y).?.out;
    try t.expect(out[0] == g.int(0));
    try t.expectEqual(.range, out[1].op);
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

//@include symbolic

//@include movement_ranges
