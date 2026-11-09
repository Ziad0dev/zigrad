//
// ─── Exercise 197: UPCAST: from loops to registers ────────────────────
//
// 196 split loops and marked some pieces UPCAST. An UPCAST range isn't a
// loop: its values become LANES of a vector, computed side by side
// (tinygrad's expander, in tinygrad/codegen/__init__.py, then devectorize).
// Three cases:
//
//   * A REDUCE whose input depends on the upcast range u, but that doesn't
//     loop over u: it becomes ONE reduce of a vector, a STACK of its input
//     at u = 0, 1, ..., n-1, with one accumulator per lane. Every use of
//     the old reduce becomes INDEX(vector reduce, u): its lane.
//   * An END that loops over u: its body n times, u = 0, 1, ..., n-1 (in a
//     SINK), and the END loops over the other ranges only.
//   * A REDUCE that loops over u (upcasting a reduce range: UNROLL): its
//     input at each lane, combined right there, and the reduce loops over
//     the other ranges only.
//
// Why bother? Look at a matmul with the j loop upcast by 4:
//
//     for i, for j4:                       float acc[4] = {0, 0, 0, 0};
//         4 reduces over k        ->       for k:  a = A[i, k]          (once)
//         (4 loops, A read 4x)                     acc[0..3] += a * B[k, 4*j4 + 0..3]
//
// One loop, A[i, k] read once for 4 outputs, and 4 accumulators the C
// compiler keeps in registers and fills with vector instructions (045,
// 155, 161). Upcast i too, and each A load and each B load is reused
// across a whole block of outputs: register blocking.
//
// YOUR TASK: the three cases in expandUpcast().
//
const std = @import("std");

//@export expander
fn dependsOn(g: *Graph, x: *const UOp, u: *const UOp) bool {
    return std.mem.indexOfScalar(*const UOp, toposort(g, x, false), u) != null;
}

/// a op b, lane by lane if they are vectors (STACKs, nested alike).
fn laneWise(g: *Graph, op: Op, a: *const UOp, b: *const UOp) Error!*const UOp {
    if (a.op != .stack or b.op != .stack) return g.alu(op, &.{ a, b });
    const lanes = g.alloc.alloc(*const UOp, a.src.len) catch @panic("out of memory");
    for (lanes, a.src, b.src) |*l, x, y| l.* = try laneWise(g, op, x, y);
    return g.stack(lanes);
}

/// x with the range u replaced by the constant i, simplified.
fn atLane(g: *Graph, x: *const UOp, u: *const UOp, i: usize) Error!*const UOp {
    var map = Subst.init(g.alloc);
    map.put(u, g.int(@intCast(i))) catch @panic("out of memory");
    return symbolic(g, try substitute(g, x, &map));
}

fn without(g: *Graph, list: []const *const UOp, u: *const UOp) []const *const UOp {
    var out: std.ArrayList(*const UOp) = .empty;
    for (list) |x| if (x != u) out.append(g.alloc, x) catch @panic("out of memory");
    return out.items;
}

/// Replace the UPCAST range u (n values) by n lanes.
fn expandUpcast(g: *Graph, ast: *const UOp, u: *const UOp) Error!*const UOp {
    const n: usize = @intCast(u.src[0].intValue().?);
    var cur = ast;
    // 1. a reduce that depends on u, without looping over it: a vector reduce
    var map = Subst.init(g.alloc);
    for (toposort(g, cur, false)) |red| {
        if (red.op != .reduce or std.mem.indexOfScalar(*const UOp, red.src[1..], u) != null) continue;
        if (!dependsOn(g, red.src[0], u)) continue;
        const src = try substitute(g, red.src[0], &map); // reduces inside it come first
        const lanes = g.alloc.alloc(*const UOp, n) catch @panic("out of memory");
        for (lanes, 0..) |*l, i| l.* = ⟪try atLane(g, src, u, i)|||???⟫;
        const vec_src = std.mem.concat(g.alloc, *const UOp, &.{ &.{try g.stack(lanes)}, red.src[1..] }) catch @panic("out of memory");
        const vec = try g.new(.reduce, vec_src, red.arg);
        map.put(red, ⟪try g.index(vec, &.{u})|||???⟫) catch @panic("out of memory");
    }
    cur = try substitute(g, cur, &map);
    // 2. an END that loops over u: its body once per lane
    var ends = Subst.init(g.alloc);
    for (toposort(g, cur, false)) |e| {
        if (e.op != .end or std.mem.indexOfScalar(*const UOp, e.src[1..], u) == null) continue;
        const copies = g.alloc.alloc(*const UOp, n) catch @panic("out of memory");
        for (copies, 0..) |*c, i| c.* = try atLane(g, e.src[0], u, i);
        const body = try g.sink(copies);
        const rest = without(g, e.src[1..], u);
        ends.put(e, if (rest.len == 0) body else ⟪try g.end(body, rest)|||???⟫) catch @panic("out of memory");
    }
    cur = try substitute(g, cur, &ends);
    // 3. a reduce that loops over u: combine its lanes right there
    var unrolls = Subst.init(g.alloc);
    for (toposort(g, cur, false)) |red| {
        if (red.op != .reduce or std.mem.indexOfScalar(*const UOp, red.src[1..], u) == null) continue;
        var acc = try atLane(g, red.src[0], u, 0);
        for (1..n) |i| acc = ⟪try laneWise(g, red.arg.reduce.op, acc, try atLane(g, red.src[0], u, i))|||???⟫;
        const rest = without(g, red.src[1..], u);
        const src = std.mem.concat(g.alloc, *const UOp, &.{ &.{acc}, rest }) catch @panic("out of memory");
        unrolls.put(red, if (rest.len == 0) acc else try g.new(.reduce, src, red.arg)) catch @panic("out of memory");
    }
    return substitute(g, cur, &unrolls);
}

/// Expand every UPCAST range of a scheduled kernel.
fn expandAll(s: *Sched) Error!*const UOp {
    var ast = s.ast;
    for (s.ranges()) |r| {
        if (s.typeOf(r) == .upcast) ast = try expandUpcast(s.g, ast, r);
    }
    return ast;
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

/// Run a kernel body through the interpreter with the CALL's buffers.
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

const Opts = struct { up_i: usize = 0, up_j: usize = 0, unroll_k: usize = 0 };

/// The gemm kernel with some upcasts applied and expanded.
fn optimized(g: *Graph, call: *const UOp, o: Opts) !*const UOp {
    var s = Sched.init(g, call.src[0]);
    const rs = s.ranges(); // i, j, k
    if (o.up_i > 1) _ = try s.shiftTo(rs[0], o.up_i, .upcast, false);
    if (o.up_j > 1) _ = try s.shiftTo(rs[1], o.up_j, .upcast, false);
    if (o.unroll_k > 1) _ = try s.shiftTo(rs[2], o.unroll_k, .upcast, false);
    return expandAll(&s);
}

test "upcasts change the code, not the answer" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const n = 8;
    const s = try schedule(&g, &.{try gemm(&g, g.buffer(0, .f32, n * n), g.buffer(1, .f32, n * n), n)});
    const call = s.calls[0];
    var data: [2][n * n]f64 = undefined;
    for (&data[0], &data[1], 0..) |*x, *y, i| {
        x.* = @floatFromInt(i % 7);
        y.* = @floatFromInt(i % 5);
    }
    const want = try g.alloc.dupe(f64, try runKernel(&g, call, call.src[0], &.{ &data[0], &data[1] }));
    for ([_]Opts{ .{ .up_j = 4 }, .{ .unroll_k = 4 }, .{ .up_i = 2, .up_j = 4 }, .{ .up_i = 2, .up_j = 4, .unroll_k = 2 } }) |o| {
        const body = try optimized(&g, call, o);
        // the upcast pieces are gone: each axis keeps just its (shorter) loop
        var sched = Sched.init(&g, body);
        try t.expectEqual(3, sched.ranges().len);
        try t.expectEqualSlices(f64, want, try runKernel(&g, call, body, &.{ &data[0], &data[1] }));
    }
}

test "j upcast by 4: one loop over k, four accumulators" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const s = try schedule(&g, &.{try gemm(&g, g.buffer(0, .f32, 64), g.buffer(1, .f32, 64), 8)});
    const body = try optimized(&g, s.calls[0], .{ .up_j = 4 });
    var reduces: usize = 0;
    for (toposort(&g, body, false)) |u| {
        if (u.op != .reduce) continue;
        reduces += 1;
        try t.expectEqual(.stack, u.src[0].op); // a vector of 4 lanes
        try t.expectEqualSlices(usize, &.{4}, u.shape);
    }
    try t.expectEqual(1, reduces);
    var c: std.Io.Writer.Allocating = .init(g.alloc);
    try renderC(&g, body, &c.writer);
    try t.expect(std.mem.indexOf(u8, c.written(), "float acc0[4] = {0.0f, 0.0f, 0.0f, 0.0f};") != null);
}

const KernelFn = *const fn ([*]const ?*anyopaque) callconv(.c) void;

fn compileAndTime(g: *Graph, body: *const UOp, args: []const *const UOp, bufs: [3][]f32, a: *const UOp, b: *const UOp) !f64 {
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var src: std.Io.Writer.Allocating = .init(g.alloc);
    try renderC(g, body, &src.writer);
    try tmp.dir.writeFile(io, .{ .sub_path = "k.c", .data = src.written() });
    var dir_buf: [4096]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const c_path = try std.fs.path.join(g.alloc, &.{ dir, "k.c" });
    const so_path = try std.fs.path.join(g.alloc, &.{ dir, "k.so" });
    const result = try std.process.run(g.alloc, io, .{ .argv = &.{ "zig", "cc", "-O3", "-march=native", "-shared", "-fPIC", "-nostdlib", c_path, "-o", so_path } });
    if (result.term != .exited or result.term.exited != 0) return error.CompileFailed;
    var lib = try std.DynLib.open(so_path);
    defer lib.close();
    const kernel = lib.lookup(KernelFn, "kernel") orelse return error.KernelNotFound;
    var ptrs: [3]?*anyopaque = undefined;
    for (args, 0..) |arg, j| {
        var buf = arg;
        while (buf.op == .after) buf = buf.src[0];
        ptrs[j] = if (buf == a) bufs[0].ptr else if (buf == b) bufs[1].ptr else bufs[2].ptr;
    }
    var best: f64 = std.math.inf(f64);
    for (0..5) |_| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        kernel(&ptrs);
        const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake));
        best = @min(best, @as(f64, @floatFromInt(dt.nanoseconds)) * 1e-9);
    }
    return best;
}

test "and on your CPU: 256x256, timed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const n = 256;
    const a = g.buffer(0, .f32, n * n);
    const b = g.buffer(1, .f32, n * n);
    const s = try schedule(&g, &.{try gemm(&g, a, b, n)});
    const call = s.calls[0];
    var prng = std.Random.DefaultPrng.init(0);
    const bufs = [3][]f32{ try g.alloc.alloc(f32, n * n), try g.alloc.alloc(f32, n * n), try g.alloc.alloc(f32, n * n) };
    for (bufs[0], bufs[1]) |*x, *y| {
        x.* = prng.random().float(f32);
        y.* = prng.random().float(f32);
    }
    const flops: f64 = 2.0 * n * n * n;
    std.debug.print("\n256x256 matmul, best of 5:\n", .{});
    for ([_]Opts{ .{}, .{ .up_j = 4 }, .{ .up_j = 8 }, .{ .up_i = 4, .up_j = 8 }, .{ .up_i = 4, .up_j = 16 }, .{ .up_i = 4, .up_j = 16, .unroll_k = 4 } }) |o| {
        const secs = try compileAndTime(&g, try optimized(&g, call, o), call.src[1..], bufs, a, b);
        // every version computes the same numbers
        var sum: f32 = 0;
        for (0..n) |k| sum += bufs[0][3 * n + k] * bufs[1][k * n + 77];
        try t.expectApproxEqRel(sum, bufs[2][3 * n + 77], 1e-4);
        std.debug.print("  upcast i {d:>2}, j {d:>2}, unroll k {d:>2}: {d:>7.3} ms  {d:>6.2} GFLOPS\n", .{ o.up_i, o.up_j, o.unroll_k, secs * 1e3, flops / secs * 1e-9 });
    }
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

//@include render_c

//@include shift_to
