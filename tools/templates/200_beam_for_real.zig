//
// ─── Exercise 200: BEAM, for real ─────────────────────────────────────
//
// 048 searched a made-up timing table. Now the kernels are real: each
// candidate is the matmul with some upcasts (196, 197), rendered (195),
// compiled with zig cc, and timed on YOUR CPU. That's tinygrad's BEAM=2
// (tinygrad/codegen/opt/search.py, beam_search), with its pieces:
//
//   * actions: every SPLIT the kernel allows, here an UPCAST of 2, 4, 8
//     or 16 on i or j, or an unroll of 2, 4, 8 on the reduce k. (tinygrad's
//     list is longer: LOCAL, PADTO, SWAP, TC, more amounts.) An action that
//     breaks a rule (196's checks) just isn't a candidate.
//   * timing: compile, run a few times, keep the best (176). tinygrad also
//     stops timing a candidate early once it's 3x slower than the best.
//   * the beam: keep the fastest `width`, try one more action on each,
//     and stop when the best gets better by less than min_progress
//     (BEAM_MIN_PROGRESS, 048).
//   * tinygrad caches the winner on disk, keyed by the kernel, so the next
//     run of the same kernel skips the search. (Not here.)
//
// What wins depends on your machine: the registers, the vector width,
// the caches. That's the point of searching instead of guessing.
//
// YOUR TASK: the candidates in next(), and keeping the best `width` with
// the progress check in beam().
//
const std = @import("std");

const Opts = struct { up_i: usize = 1, up_j: usize = 1, unroll_k: usize = 1 };

const matmul_n = 128; // the matmul is matmul_n by matmul_n
const KernelFn = *const fn ([*]const ?*anyopaque) callconv(.c) void;

const Search = struct {
    g: *Graph,
    call: *const UOp,
    bufs: [3][]f32,
    a: *const UOp,
    b: *const UOp,
    timed: usize = 0,
    fake: ?*const fn (Opts) f64 = null, // a made-up clock, for testing the search itself

    /// The kernel with these opts, or an error if 196's checks refuse them.
    fn kernel(s: *Search, o: Opts) !*const UOp {
        var sched = Sched.init(s.g, s.call.src[0]);
        const rs = sched.ranges(); // i, j, k
        if (o.up_i > 1) _ = try sched.shiftTo(rs[0], o.up_i, .upcast, false);
        if (o.up_j > 1) _ = try sched.shiftTo(rs[1], o.up_j, .upcast, false);
        if (o.unroll_k > 1) _ = try sched.shiftTo(rs[2], o.unroll_k, .upcast, false);
        return expandAll(&sched);
    }

    /// Compile and time: the best of 3 runs, in seconds.
    fn time(s: *Search, o: Opts) !f64 {
        const g = s.g;
        const io = std.testing.io;
        s.timed += 1;
        if (s.fake) |f| return f(o);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var src: std.Io.Writer.Allocating = .init(g.alloc);
        try renderC(g, try s.kernel(o), &src.writer);
        try tmp.dir.writeFile(io, .{ .sub_path = "k.c", .data = src.written() });
        var dir_buf: [4096]u8 = undefined;
        const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
        const c_path = try std.fs.path.join(g.alloc, &.{ dir, "k.c" });
        const so_path = try std.fs.path.join(g.alloc, &.{ dir, "k.so" });
        const result = try std.process.run(g.alloc, io, .{ .argv = &.{ "zig", "cc", "-O3", "-march=native", "-shared", "-fPIC", "-nostdlib", c_path, "-o", so_path } });
        if (result.term != .exited or result.term.exited != 0) return error.CompileFailed;
        var lib = try std.DynLib.open(so_path);
        defer lib.close();
        const f = lib.lookup(KernelFn, "kernel") orelse return error.KernelNotFound;
        var ptrs: [3]?*anyopaque = undefined;
        for (s.call.src[1..], 0..) |arg, j| {
            var buf = arg;
            while (buf.op == .after) buf = buf.src[0];
            ptrs[j] = if (buf == s.a) s.bufs[0].ptr else if (buf == s.b) s.bufs[1].ptr else s.bufs[2].ptr;
        }
        var best: f64 = std.math.inf(f64);
        for (0..3) |_| {
            const t0 = std.Io.Timestamp.now(io, .awake);
            f(&ptrs);
            const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake));
            best = @min(best, @as(f64, @floatFromInt(dt.nanoseconds)) * 1e-9);
        }
        return best;
    }

    /// Every kernel one more action away from o, that 196's checks allow.
    fn next(s: *Search, o: Opts, out: *std.ArrayList(Opts)) void {
        for ([_]usize{ 2, 4, 8, 16 }) |amt| {
            for (0..3) |axis| {
                var c = o;
                const field = switch (axis) {
                    0 => &c.up_i,
                    1 => &c.up_j,
                    else => &c.unroll_k,
                };
                if (field.* != 1) continue; // one split per axis, here
                if (axis == 2 and amt > 8) continue;
                ⟪field.* = amt;|||???;⟫
                // too many lanes would spill out of registers: tinygrad caps this too
                if (c.up_i * c.up_j > 256) continue;
                _ = s.kernel(c) catch continue; // the checks say no: not a candidate
                out.append(s.g.alloc, c) catch @panic("out of memory");
            }
        }
    }

    const Scored = struct { opts: Opts, secs: f64 };

    fn faster(_: void, a: Scored, b: Scored) bool {
        return a.secs < b.secs;
    }

    fn beam(s: *Search, width: usize, min_progress: f64) !Scored {
        const g = s.g;
        var current: std.ArrayList(Scored) = .empty;
        try current.append(g.alloc, .{ .opts = .{}, .secs = try s.time(.{}) });
        var best = current.items[0];
        while (true) {
            var options: std.ArrayList(Opts) = .empty;
            for (current.items) |c| s.next(c.opts, &options);
            var scored: std.ArrayList(Scored) = .empty;
            for (options.items) |o| {
                const seen = for (scored.items) |x| {
                    if (std.meta.eql(x.opts, o)) break true;
                } else false;
                if (!seen) try scored.append(g.alloc, .{ .opts = o, .secs = try s.time(o) });
            }
            if (scored.items.len == 0) return best;
            std.mem.sort(Scored, scored.items, {}, faster);
            if (⟪best.secs - scored.items[0].secs < min_progress|||???⟫) return best;
            best = scored.items[0];
            current.clearRetainingCapacity();
            try current.appendSlice(g.alloc, scored.items[0..⟪@min(width, scored.items.len)|||???⟫]);
        }
    }
};

const t = std.testing;

fn gemm(g: *Graph, a_buf: *const UOp, b_buf: *const UOp) !*const UOp {
    const a = try g.reshape(a_buf, &.{ matmul_n, matmul_n });
    const b = try g.reshape(b_buf, &.{ matmul_n, matmul_n });
    const a3 = try g.permute(try g.expand(try g.permute(a, &.{ 1, 0 }), &.{matmul_n}), &.{ 1, 2, 0 });
    const b3 = try g.permute(try g.expand(b, &.{matmul_n}), &.{ 1, 0, 2 });
    return g.reduce(try g.mul(a3, b3), .add, 1);
}

test "the candidates follow the rules" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const a = g.buffer(0, .f32, matmul_n * matmul_n);
    const b = g.buffer(1, .f32, matmul_n * matmul_n);
    const sched = try schedule(&g, &.{try gemm(&g, a, b)});
    var s: Search = .{ .g = &g, .call = sched.calls[0], .bufs = undefined, .a = a, .b = b };
    var options: std.ArrayList(Opts) = .empty;
    s.next(.{}, &options);
    try t.expectEqual(11, options.items.len); // 4 for i, 4 for j, 3 for k
    for (options.items) |o| try t.expect(o.up_i * o.up_j * o.unroll_k > 1);
    // from (i 16, j 16), there's no room for more upcasts, only unrolls
    options.clearRetainingCapacity();
    s.next(.{ .up_i = 16, .up_j = 16 }, &options);
    try t.expectEqual(3, options.items.len);
    for (options.items) |o| try t.expectEqual(256, o.up_i * o.up_j);
}

fn optsUsed(o: Opts) f64 {
    return @floatFromInt(@as(usize, @intFromBool(o.up_i > 1)) + @intFromBool(o.up_j > 1) + @intFromBool(o.unroll_k > 1));
}

/// Every opt saves exactly 5: 100, then 95, 90, 85.
fn fiveEach(o: Opts) f64 {
    return 100 - 5 * optsUsed(o);
}

/// One first move is great (90), the rest barely help (99). Then 85.
fn oneGoodMove(o: Opts) f64 {
    const k = optsUsed(o);
    if (k == 0) return 100;
    if (k == 1) return if (o.up_j == 4) 90 else 99;
    return 85;
}

fn fakeSearch(g: *Graph, f: *const fn (Opts) f64) !Search {
    const a = g.buffer(0, .f32, matmul_n * matmul_n);
    const b = g.buffer(1, .f32, matmul_n * matmul_n);
    const sched = try schedule(g, &.{try gemm(g, a, b)});
    return .{ .g = g, .call = sched.calls[0], .bufs = undefined, .a = a, .b = b, .fake = f };
}

test "the search logic, on a made-up clock" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    // progress of exactly min_progress is enough to go on...
    var s = try fakeSearch(&g, &fiveEach);
    try t.expectEqual(85, (try s.beam(1, 5)).secs);
    // ...a little less isn't
    s = try fakeSearch(&g, &fiveEach);
    try t.expectEqual(100, (try s.beam(1, 6)).secs);
    // progress is measured with the FASTEST candidate
    s = try fakeSearch(&g, &oneGoodMove);
    try t.expectEqual(85, (try s.beam(1, 5)).secs);
    // a wider beam tries more kernels
    var narrow = try fakeSearch(&g, &fiveEach);
    _ = try narrow.beam(1, 1);
    var wide = try fakeSearch(&g, &fiveEach);
    _ = try wide.beam(3, 1);
    try t.expect(wide.timed > narrow.timed);
    // a beam wider than there are candidates keeps them all
    var huge = try fakeSearch(&g, &fiveEach);
    try t.expectEqual(85, (try huge.beam(100, 5)).secs);
}

test "search, on your machine" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const a = g.buffer(0, .f32, matmul_n * matmul_n);
    const b = g.buffer(1, .f32, matmul_n * matmul_n);
    const sched = try schedule(&g, &.{try gemm(&g, a, b)});
    var prng = std.Random.DefaultPrng.init(1);
    const bufs = [3][]f32{ try g.alloc.alloc(f32, matmul_n * matmul_n), try g.alloc.alloc(f32, matmul_n * matmul_n), try g.alloc.alloc(f32, matmul_n * matmul_n) };
    for (bufs[0], bufs[1]) |*x, *y| {
        x.* = prng.random().float(f32);
        y.* = prng.random().float(f32);
    }
    var s: Search = .{ .g = &g, .call = sched.calls[0], .bufs = bufs, .a = a, .b = b };
    const baseline = try s.time(.{});
    const best = try s.beam(2, 0.00001);
    // the start is a candidate, so the winner can't be slower (give timing noise 20%)
    try t.expect(best.secs <= baseline * 1.2);
    // and it computes the same thing
    _ = try s.time(best.opts);
    var sum: f32 = 0;
    for (0..matmul_n) |k| sum += bufs[0][5 * matmul_n + k] * bufs[1][k * matmul_n + 99];
    try t.expectApproxEqRel(sum, bufs[2][5 * matmul_n + 99], 1e-4);
    const flops: f64 = 2.0 * matmul_n * matmul_n * matmul_n;
    std.debug.print("\nBEAM on a {d}x{d} matmul: timed {d} kernels\n  start: {d:>7.2} GFLOPS\n  best:  {d:>7.2} GFLOPS with upcast i {d}, j {d}, unroll k {d}\n", .{ matmul_n, matmul_n, s.timed, flops / baseline * 1e-9, flops / best.secs * 1e-9, best.opts.up_i, best.opts.up_j, best.opts.unroll_k });
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

//@include expander
