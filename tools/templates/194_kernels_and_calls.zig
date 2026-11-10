//
// ─── Exercise 194: cheap buffers, and kernels as CALLs ────────────────
//
// Two last steps between rangeify and a list of kernels to run.
//
// 1. Throw away cheap buffers. 192 realizes everything it must, plus
//    things it merely could: a value read two different ways, a value
//    under a broadcast. Many of those are cheaper to recompute than to
//    store and reload. tinygrad's remove_bufferize (schedule/rangeify.py)
//    decides with a rule of thumb, and keeps a buffer only if:
//
//      * the value is made from more than 3 buffers (recomputing it means
//        reading them all again, in every reader), or
//      * its computation contains a REDUCE that reads a buffer
//        (recomputing that is a whole loop, per element).
//
//    "If a buffer is being stored just for permutes or something, remove
//    it", says the comment. That's what brings softmax from four kernels
//    (192) down to tinygrad's three: x - max is cheap, so the sum and the
//    divide each recompute it.
//
// 2. Split the graph into kernels you can compile once and launch many
//    times (split_store and to_define_global in rangeify.py). Each kernel
//    END becomes a CALL (184):
//
//      * every buffer it touches becomes a PARAM, slot 0, 1, 2... in the
//        order they appear, and the real buffers become the CALL's
//        arguments. A buffer read through an AFTER passes the AFTER as
//        the argument: the call waits for the kernel that writes it.
//      * its RANGEs are renumbered 0, 1, 2... in the order they appear.
//
//    Then the body no longer mentions which buffers or which loop names
//    it was made with, and two kernels doing the same thing to different
//    buffers have the SAME body: one UOp, hash-consed, compiled once.
//    "renumber the ranges starting with 0 so that kernel deduping works".
//
// YOUR TASK: keepBuffer()'s two rules, and the PARAMs and ranges in
// toCall().
//
const std = @import("std");

//@export kernels
/// Does x (a realized value) deserve its buffer? (tinygrad: remove_bufferize)
fn keepBuffer(rf: *Rangeify, x: *const UOp) bool {
    const g = rf.g;
    var buffers = std.AutoHashMap(*const UOp, void).init(g.alloc);
    var reduces: std.ArrayList(*const UOp) = .empty;
    // what x is computed from, down to buffers and other realized values
    var stack: std.ArrayList(*const UOp) = .empty;
    var seen = std.AutoHashMap(*const UOp, void).init(g.alloc);
    stack.append(g.alloc, x) catch @panic("out of memory");
    while (stack.pop()) |u| {
        if (seen.contains(u)) continue;
        seen.put(u, {}) catch @panic("out of memory");
        if (u != x and (u.op == .buffer or rf.realize.contains(u))) {
            buffers.put(u, {}) catch @panic("out of memory");
            continue;
        }
        if (u.op == .reduce) reduces.append(g.alloc, u) catch @panic("out of memory");
        const data = if (u.op.isMovement() or u.op == .reduce) u.src[0..1] else u.src;
        for (data) |s| stack.append(g.alloc, s) catch @panic("out of memory");
    }
    if (⟪buffers.count() > 3|||???⟫) return true;
    // a reduce that reads a buffer is a whole loop: don't redo it per element
    for (reduces.items) |r| {
        for (toposort(g, r, false)) |u| {
            if (⟪u != x and (u.op == .buffer or rf.realize.contains(u))|||???⟫) return true;
        }
    }
    return false;
}

/// Un-realize every buffer keepBuffer() doesn't want, producers first, so
/// each value is judged on the buffers that are really left below it.
fn removeCheapBuffers(rf: *Rangeify, outputs: []const *const UOp) void {
    const sink = rf.g.sink(outputs) catch unreachable;
    for (toposort(rf.g, sink, false)) |x| {
        if (!rf.realize.contains(x)) continue;
        const is_output = std.mem.indexOfScalar(*const UOp, outputs, x) != null;
        if (!is_output and !keepBuffer(rf, x)) _ = rf.realize.orderedRemove(x);
    }
}

/// The UOps of ONE kernel, srcs first. An AFTER is where another kernel's
/// work begins: we take its buffer and stop, without walking into the
/// kernel that wrote it.
fn kernelNodes(g: *Graph, u: *const UOp, seen: *std.AutoHashMap(*const UOp, void), out: *std.ArrayList(*const UOp)) void {
    if (seen.contains(u)) return;
    seen.put(u, {}) catch @panic("out of memory");
    const srcs = if (u.op == .after) u.src[0..1] else u.src;
    for (srcs) |s| kernelNodes(g, s, seen, out);
    out.append(g.alloc, u) catch @panic("out of memory");
}

/// A kernel (an END, or a STORE with no loop) as a CALL of a reusable body.
fn toCall(g: *Graph, kernel: *const UOp) Error!*const UOp {
    var map = Subst.init(g.alloc);
    var args: std.ArrayList(*const UOp) = .empty;
    var slot_of = std.AutoHashMap(*const UOp, u32).init(g.alloc); // buffer -> PARAM slot
    var ranges: u32 = 0;
    var seen = std.AutoHashMap(*const UOp, void).init(g.alloc);
    var nodes: std.ArrayList(*const UOp) = .empty;
    kernelNodes(g, kernel, &seen, &nodes);
    for (nodes.items) |u| {
        switch (u.op) {
            .buffer, .alloc => {
                if (slot_of.contains(u)) continue;
                const slot: u32 = @intCast(args.items.len);
                slot_of.put(u, slot) catch @panic("out of memory");
                args.append(g.alloc, u) catch @panic("out of memory");
                const size: ?usize = if (u.shape.len == 0) null else u.shape[0];
                map.put(u, ⟪g.param(slot, u.arg.param.dtype, size)|||???⟫) catch @panic("out of memory");
            },
            .after => {
                // a buffer some kernel writes first: the CALL waits on the AFTER
                const buf = u.src[0];
                const slot = slot_of.get(buf).?; // its BUFFER came first, in toposort order
                args.items[slot] = ⟪u|||???⟫;
                map.put(u, map.get(buf).?) catch @panic("out of memory");
            },
            .range => {
                map.put(u, ⟪g.range(@intCast(u.src[0].intValue().?), ranges)|||???⟫) catch @panic("out of memory");
                ranges += 1;
            },
            else => {},
        }
    }
    const body = try g.sink(&.{try substitute(g, kernel, &map)});
    return g.call(body, args.items);
}

/// The whole scheduler: rangeify (192), drop cheap buffers, write the
/// kernels (193), and make them CALLs, in the order they must run.
fn schedule(g: *Graph, outputs: []const *const UOp) Error!struct { calls: []const *const UOp, lower: Lower } {
    const rf = g.alloc.create(Rangeify) catch @panic("out of memory");
    rf.* = Rangeify.init(g);
    const sink = try g.sink(outputs);
    try rf.walk(sink);
    removeCheapBuffers(rf, outputs);
    var lw = Lower.init(g, rf);
    _ = try lw.run(sink);
    const calls = g.alloc.alloc(*const UOp, lw.kernels.items.len) catch @panic("out of memory");
    for (lw.kernels.items, calls) |k, *c| c.* = try toCall(g, k);
    return .{ .calls = calls, .lower = lw };
}
//@end

const t = std.testing;

/// Schedule y, run the CALLs in order, and compare with y run as tensors.
fn expectScheduled(g: *Graph, inputs: []const *const UOp, data: []const []const f64, y: *const UOp) ![]const *const UOp {
    var it = Interp.init(g);
    for (inputs, data) |b, d| @memcpy(it.storage(b), d);
    const want = try it.eval(y);
    const s = try schedule(g, &.{y});
    for (s.calls) |c| _ = try it.eval(c);
    // y's buffer: what its AFTER (193) waits on
    const out_buf = s.lower.filled.get(y).?.src[0];
    const got = it.storage(out_buf);
    try t.expectEqual(want.data.len, got.len);
    for (want.data, got) |w, v| try t.expectApproxEqAbs(w, v, 1e-5);
    return s.calls;
}

fn softmax(g: *Graph, x: *const UOp, n: usize) !*const UOp {
    const m = try g.reduce(x, .max, 1);
    const d = try g.add(x, try g.mul(try g.expand(m, &.{n}), try g.expand(g.float(-1), &.{n})));
    const inv = try g.alu(.recip, &.{try g.reduce(d, .add, 1)});
    return g.mul(d, try g.expand(inv, &.{n}));
}

test "softmax: three kernels, like tinygrad's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 5);
    const calls = try expectScheduled(&g, &.{x}, &.{&.{ 3, 1, 4, 1, 5 }}, try softmax(&g, x, 5));
    try t.expectEqual(3, calls.len);
    // the divide waits for the max and the sum: two of its args are AFTERs
    var afters: usize = 0;
    for (calls[2].src[1..]) |a| afters += @intFromBool(a.op == .after);
    try t.expectEqual(2, afters);
}

test "a kernel only takes its own buffers" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 4);
    const w = g.buffer(1, .f32, 4);
    const v = g.buffer(2, .f32, 4);
    // three kernels in a chain: sum(x), then 1 / sum(that + w), then that * v
    const y1 = try g.reduce(x, .add, 1);
    const inv = try g.alu(.recip, &.{try g.reduce(try g.add(try g.expand(y1, &.{4}), w), .add, 1)});
    const z = try g.mul(try g.expand(inv, &.{4}), v);
    const calls = try expectScheduled(&g, &.{ x, w, v }, &.{ &.{ 1, 2, 3, 4 }, &.{ 0.5, 0, -1, 2 }, &.{ 1, -1, 2, 0 } }, z);
    try t.expectEqual(3, calls.len);
    // the last one reads inv and v and writes z: 3 arguments, not x's and w's too
    try t.expectEqual(3, calls[2].src.len - 1);
    try t.expectEqual(2, calls[0].src.len - 1);
    // and its PARAMs are slots 0, 1, 2, with no gaps
    for (toposort(&g, calls[2].src[0], false)) |u| {
        if (u.op == .param) try t.expect(u.arg.param.slot < 3);
    }
}

test "a buffer just for a permute is removed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 9);
    const m = try g.reshape(x, &.{ 3, 3 });
    const calls = try expectScheduled(&g, &.{x}, &.{&.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }}, try g.add(m, try g.permute(m, &.{ 1, 0 })));
    try t.expectEqual(1, calls.len);
}

test "the rules of thumb" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const bufs = [_]*const UOp{ g.buffer(0, .f32, 4), g.buffer(1, .f32, 4), g.buffer(2, .f32, 4), g.buffer(3, .f32, 4) };
    var rf = Rangeify.init(&g);
    // made from 4 buffers: worth keeping
    const four = try g.add(try g.add(bufs[0], bufs[1]), try g.add(bufs[2], bufs[3]));
    try t.expect(keepBuffer(&rf, four));
    // from 3: recompute it
    const three = try g.add(try g.add(bufs[0], bufs[1]), bufs[2]);
    try t.expect(!keepBuffer(&rf, three));
    // contains a reduce over a buffer: keep
    try t.expect(keepBuffer(&rf, try g.alu(.recip, &.{try g.reduce(bufs[0], .add, 1)})));
    // a reduce over nothing but constants is cheap to redo
    try t.expect(!keepBuffer(&rf, try g.reduce(try g.expand(g.float(1), &.{4}), .add, 1)));
}

test "same kernel, different buffers: one body" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x1 = g.buffer(0, .f32, 8);
    const x2 = g.buffer(1, .f32, 8);
    const two = try g.expand(g.float(2), &.{8});
    const s = try schedule(&g, &.{ try g.mul(x1, two), try g.mul(x2, two) });
    try t.expectEqual(2, s.calls.len);
    try t.expect(s.calls[0] != s.calls[1]); //           two launches...
    try t.expect(s.calls[0].src[0] == s.calls[1].src[0]); // ...of ONE compiled kernel
}

test "a kernel body, as it would be compiled" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(7, .f32, 12);
    const s = try schedule(&g, &.{try g.reduce(try g.reshape(x, &.{ 3, 4 }), .add, 1)});
    var out: std.Io.Writer.Allocating = .init(g.alloc);
    try printUir(&g, s.calls[0].src[0], &out.writer);
    try t.expectEqualStrings(
        \\%0 = param 4 slot=0 dtype=f32
        \\%1 = range 4 slot=0
        \\%2 = index %0 %1
        \\%3 = param 12 slot=1 dtype=f32
        \\%4 = range 3 slot=1
        \\%5 = mul %4 4
        \\%6 = add %5 %1
        \\%7 = index %3 %6
        \\%8 = reduce %7 %4 op=add
        \\%9 = store %2 %8
        \\%10 = end %9 %1
        \\%11 = sink %10
        \\
    , out.written());
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
