//
// ─── Exercise 193: from tensors to loops ──────────────────────────────
//
// 192 decided which values get a buffer. Now write the kernels: plain
// loops over memory, in the same UOps, with no shapes and no movement ops
// left. tinygrad does it in two passes over the graph, pm_apply_rangeify
// and then bufferize_to_store (tinygrad/schedule/indexing.py and
// rangeify.py). Here it's one recursive function, at(x, idx): "the value
// of x at this index", built as a scalar UOp:
//
//   a BUFFER          INDEX(buf, flat index): a load from memory
//   a realized value  INDEX(its buffer, after the kernel that wrote it)
//   an ALU op         the op, of its srcs at the same index
//   a movement op     its src at the index 191 maps to. A PAD is valid
//                     only inside the data, so it becomes
//                     WHERE(valid, src at the index, 0).
//                     (tinygrad: convert_pad_to_where_to_keep_behavior_local)
//   a REDUCE          the ranges 192 made for the axes it pops, its src
//                     at (those ++ idx), and REDUCE(that, the ranges): a
//                     loop with an accumulator, the form 189 runs.
//                     (tinygrad: convert_reduce_to_reduce_with_ranges)
//
// And each realized value x becomes one kernel:
//
//     ALLOC a buffer for x                     (a buffer is never weak:
//                                               commit its dtype, 181)
//     STORE(INDEX(buf, flat(ranges)), at(x, ranges))
//     END that over x's ranges                 (its loops)
//     AFTER(buf, that END)                     (x, for its readers)
//
// That's tinygrad's bufferize_to_store, almost word for word:
//   do_store = buf.index(idx).store(x.src[0]).end(*rngs)
//   return buf.after(do_store)
//
// Kernels are made in toposort order, so a kernel always comes after the
// ones whose buffers it reads. And the result runs in 188's interpreter:
// the test checks every lowered graph against running the original tensor
// graph directly.
//
// YOUR TASK: in at(), reading a realized value, the movement ops and the
// REDUCE. In kernel(), the STORE, END and AFTER.
//
const std = @import("std");

//@export rangeify_lower
/// The flat position of an index into a row-major shape, simplified.
fn flatIndex(g: *Graph, idx: []const *const UOp, shape: []const usize) Error!*const UOp {
    var flat = g.int(0);
    for (idx, 0..) |i, k| flat = try g.add(flat, try g.mul(i, g.int(@intCast(prod(shape[k + 1 ..])))));
    return symbolic(g, flat);
}

/// Where element idx of x lives in buf: buf itself for a scalar, else an INDEX.
fn element(g: *Graph, buf: *const UOp, idx: []const *const UOp, shape: []const usize) Error!*const UOp {
    if (shape.len == 0) return buf;
    return g.index(buf, &.{try flatIndex(g, idx, shape)});
}

fn zeroOf(g: *Graph, dtype: DType) *const UOp {
    return if (dtype.isFloat()) g.float(0) else if (dtype == .bool) g.boolean(false) else g.int(0);
}

const Lower = struct {
    g: *Graph,
    rf: *Rangeify,
    filled: std.AutoHashMap(*const UOp, *const UOp), // realized value -> AFTER(its buffer, its kernel)
    kernels: std.ArrayList(*const UOp) = .empty, //       each kernel, in order: its END, or its bare STORE if it has no loops
    slot: u32 = 100, //                                  slots for new buffers (inputs use small ones)

    fn init(g: *Graph, rf: *Rangeify) Lower {
        return .{ .g = g, .rf = rf, .filled = .init(g.alloc) };
    }

    /// The scalar value of x at index idx (one index per axis of x).
    fn at(lw: *Lower, x: *const UOp, idx: []const *const UOp) Error!*const UOp {
        const g = lw.g;
        if (lw.filled.get(x)) |buf| return ⟪element(g, buf, idx, x.shape)|||???⟫;
        return lw.compute(x, idx);
    }

    /// Like at(), but x's own value, never its buffer: for x's own kernel.
    fn compute(lw: *Lower, x: *const UOp, idx: []const *const UOp) Error!*const UOp {
        const g = lw.g;
        switch (x.op) {
            .constant => return x,
            .buffer => return element(g, x, idx, x.shape),
            .stack => {
                // pick a src by the leading index: a chain of WHEREs (tinygrad builds a tree)
                var v = try lw.at(x.src[x.src.len - 1], idx[1..]);
                var k = x.src.len - 1;
                while (k > 0) {
                    k -= 1;
                    v = try g.where(try g.cmplt(idx[0], g.int(@intCast(k + 1))), try lw.at(x.src[k], idx[1..]), v);
                }
                return v;
            },
            .reshape, .permute, .expand, .shrink, .pad => {
                const m = try applyMovement(g, x, idx, g.boolean(true));
                const inner = try lw.at(x.src[0], m.idx);
                if (m.valid == g.boolean(true)) return inner;
                return ⟪g.where(m.valid, inner, zeroOf(g, x.dtype))|||???⟫;
            },
            .reduce => {
                // the loops 192 made for the axes it pops (fresh ones if it never got any)
                const pop = x.arg.reduce.pop;
                const loops = if (lw.rf.ranges.get(x)) |r| r.in[0..pop] else lw.rf.fresh(x.src[0].shape[0..pop]);
                const inner = try lw.at(x.src[0], std.mem.concat(g.alloc, *const UOp, &.{ loops, idx }) catch @panic("out of memory"));
                var srcs: std.ArrayList(*const UOp) = .empty;
                srcs.append(g.alloc, inner) catch @panic("out of memory");
                for (loops) |r| if (r.op == .range) srcs.append(g.alloc, r) catch @panic("out of memory");
                return ⟪g.new(.reduce, srcs.items, .{ .reduce = .{ .op = x.arg.reduce.op, .pop = 0 } })|||???⟫;
            },
            else => {
                if (!x.op.isAlu()) return g.fail("can't lower this op");
                const src = g.alloc.alloc(*const UOp, x.src.len) catch @panic("out of memory");
                for (x.src, src) |s, *n| n.* = try lw.at(s, idx);
                return g.new(x.op, src, x.arg);
            },
        }
    }

    /// One kernel: loops over x's ranges, storing every element of x into
    /// a new buffer (slots count up from `slot`). END closes the real
    /// loops only: a size-1 axis has the constant 0 for its index, which
    /// is no loop, and a kernel with no loops at all is just its STORE.
    /// The kernel goes on `kernels`, and `filled` maps x to AFTER(buffer,
    /// kernel), which later kernels read x through.
    fn kernel(lw: *Lower, x: *const UOp) Error!void {
        const g = lw.g;
        const ranges = (lw.rf.ranges.get(x) orelse return g.fail("an output must be computed: a bare buffer or literal has no kernel")).out;
        const size: ?usize = if (x.shape.len == 0) null else prod(x.shape);
        const buf = g.local(lw.slot, commit(x.dtype), size);
        lw.slot += 1;
        const st = try g.store(try element(g, buf, ranges, x.shape), try lw.compute(x, ranges));
        var loops: std.ArrayList(*const UOp) = .empty;
        for (ranges) |r| if (r.op == .range) loops.append(g.alloc, r) catch @panic("out of memory");
        const done = if (loops.items.len == 0) st else ⟪try g.end(st, loops.items)|||???⟫;
        lw.kernels.append(g.alloc, done) catch @panic("out of memory");
        lw.filled.put(x, ⟪try g.after(buf, &.{done})|||???⟫) catch @panic("out of memory");
    }

    /// Every realized value under sink gets its kernel, producers first.
    /// The result: each output, read from its buffer after its kernel.
    fn run(lw: *Lower, sink: *const UOp) Error!*const UOp {
        for (toposort(lw.g, sink, false)) |x| {
            if (lw.rf.realize.contains(x)) try lw.kernel(x);
        }
        const outs = lw.g.alloc.alloc(*const UOp, sink.src.len) catch @panic("out of memory");
        for (sink.src, outs) |s, *o| o.* = lw.filled.get(s).?;
        return lw.g.sink(outs);
    }
};

/// Rangeify a tensor graph: decide the buffers (192), then write the kernels.
fn rangeify(g: *Graph, outputs: []const *const UOp) Error!Lower {
    const rf = g.alloc.create(Rangeify) catch @panic("out of memory");
    rf.* = Rangeify.init(g);
    const sink = try g.sink(outputs);
    try rf.walk(sink);
    var lw = Lower.init(g, rf);
    _ = try lw.run(sink);
    return lw;
}
//@end

const t = std.testing;

/// Lower `y` and check it against running y itself, on the given inputs.
fn expectSameAsTensors(g: *Graph, inputs: []const *const UOp, data: []const []const f64, y: *const UOp) !Lower {
    var it = Interp.init(g);
    for (inputs, data) |b, d| @memcpy(it.storage(b), d);
    const want = try it.eval(y);
    const lw = try rangeify(g, &.{y});
    // the buffer is flat: compare the numbers, row-major
    const got = try it.eval(lw.filled.get(y).?);
    try t.expectEqual(want.data.len, got.data.len);
    for (want.data, got.data) |w, v| try t.expectApproxEqAbs(w, v, 1e-5);
    return lw;
}

fn printed(g: *Graph, root: *const UOp) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(g.alloc);
    try printUir(g, root, &out.writer);
    return out.written();
}

test "a column sum, lowered: this is what a kernel looks like now" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 12);
    const s = try g.reduce(try g.reshape(x, &.{ 3, 4 }), .add, 1);
    const lw = try expectSameAsTensors(&g, &.{x}, &.{&.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }}, s);
    try t.expectEqual(1, lw.kernels.items.len);
    try t.expectEqualStrings(
        \\%0 = alloc 4 slot=100 dtype=f32
        \\%1 = range 4 slot=0
        \\%2 = index %0 %1
        \\%3 = buffer 12 slot=0 dtype=f32
        \\%4 = range 3 slot=1
        \\%5 = mul %4 4
        \\%6 = add %5 %1
        \\%7 = index %3 %6
        \\%8 = reduce %7 %4 op=add
        \\%9 = store %2 %8
        \\%10 = end %9 %1
        \\
    , try printed(&g, lw.kernels.items[0]));
}

test "elementwise, matmul, and a padded read" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 6);
    const w = g.buffer(1, .f32, 12);
    const xd = [_]f64{ 1, 2, 3, 4, 5, 6 };
    const wd = [_]f64{ 1, -1, 2, 0, 0.5, 3, -2, 1, 1, 1, 1, 1 };
    // relu(x * 2 - 3)
    const y = try g.alu(.max, &.{ try g.add(try g.mul(x, try g.expand(g.float(2), &.{6})), try g.expand(g.float(-3), &.{6})), try g.expand(g.float(0), &.{6}) });
    _ = try expectSameAsTensors(&g, &.{x}, &.{&xd}, y);
    // (2, 3) @ (3, 4), the leading-axis way
    const a = try g.reshape(x, &.{ 2, 3 });
    const b = try g.reshape(w, &.{ 3, 4 });
    const a3 = try g.permute(try g.expand(try g.permute(a, &.{ 1, 0 }), &.{4}), &.{ 1, 2, 0 });
    const b3 = try g.permute(try g.expand(b, &.{2}), &.{ 1, 0, 2 });
    const c = try g.reduce(try g.mul(a3, b3), .add, 1);
    const lw = try expectSameAsTensors(&g, &.{ x, w }, &.{ &xd, &wd }, c);
    try t.expectEqual(1, lw.kernels.items.len);
    // pad, then a 3-wide sliding sum: the padded reads become WHEREs
    const p = try g.pad(x, &.{1}, &.{8});
    const win = try g.stack(&.{ try g.shrink(p, &.{0}, &.{6}), try g.shrink(p, &.{1}, &.{6}), try g.shrink(p, &.{2}, &.{6}) });
    _ = try expectSameAsTensors(&g, &.{x}, &.{&xd}, try g.reduce(win, .add, 1));
}

test "softmax, as four kernels in order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 5);
    const m = try g.reduce(x, .max, 1);
    const d = try g.add(x, try g.mul(try g.expand(m, &.{5}), try g.expand(g.float(-1), &.{5})));
    const inv = try g.alu(.recip, &.{try g.reduce(d, .add, 1)});
    const y = try g.mul(d, try g.expand(inv, &.{5}));
    const lw = try expectSameAsTensors(&g, &.{x}, &.{&.{ 3, 1, 4, 1, 5 }}, y);
    try t.expectEqual(4, lw.kernels.items.len);
    // the max is a scalar: its kernel has no loop of its own, just the reduce's
    try t.expectEqual(.store, lw.kernels.items[0].op);
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
