//
// zig test flags: -lc
//
// ─── Exercise 208: your compiler, on your GPU ─────────────────────────
//
// Chapter 41: the whole stack. Part V ended with kernels rendered as C and
// run on the CPU (195). Part VI ran hand-written kernels on the GPU. Put
// them together and you have what tinygrad is: a tensor program goes in,
// and kernels your compiler wrote run on the GPU.
//
//     tensor graph -> rangeify (191-194) -> kernel bodies -> CUDA C (here)
//         -> PTX (zig cc, 201) -> the driver -> your GPU
//
// Only one thing changes from 195. On the CPU, a kernel's outer ranges
// were `for` loops. On a GPU they're the GRID: one thread per output
// element, and no loop at all (077; tinygrad marks these ranges GLOBAL,
// 196). Each thread works out which element is its own:
//
//     gid = block index * block size + thread index       (077, 201)
//     if gid is past the last element: return             (the grid rounds up)
//     r0, r1, ...  from gid, by DIV and MOD                (198's originalIndex)
//
// For ranges of sizes (n0, n1, n2), gid counts through them row-major:
// r2 = gid MOD n2, r1 = (gid DIV n2) MOD n1, r0 = (gid DIV (n1 * n2)) MOD n0.
// The LAST range changes fastest, so neighbouring threads touch
// neighbouring addresses: coalesced (202), and the reason tinygrad maps
// its dims in reverse (198).
//
// (A subtlety: with a MOD on r0 too, a spare thread past the end wraps
// around onto a real element and computes it a second time, writing the
// same value. So in these kernels a missing guard costs work, not
// correctness, and only the rendered text shows it. Keep the guard: a
// kernel that accumulates into memory, or tinygrad's, which has no MOD
// on its outermost index, would go wrong without it.)
//
// A REDUCE's range stays a loop, inside each thread. The body of the
// kernel is rendered by 195's CRender, unchanged: C is C.
//
// And cuLaunchKernel's arguments are POINTERS to each argument (201): for
// a buffer, a pointer to the u64 that holds its device address.
//
// The matmul this produces is 204's "naive" kernel, written by a compiler
// this time. 196-200's opts are what turn it into 204's "blocked" one:
// LOCAL splits become blocks, UPCAST becomes register blocking.
//
// YOUR TASK: the thread's gid, the guard, each range from gid, and the
// launch arguments.
//
const std = @import("std");

/// A kernel body (a CALL's src[0], 194) as a CUDA kernel. Its END's ranges
/// become the grid. Returns how many threads it needs: one per element.
fn renderCuda(g: *Graph, body: *const UOp, w: *std.Io.Writer) std.Io.Writer.Error!usize {
    var params: [16]?*const UOp = @splat(null);
    var n: usize = 0;
    for (toposort(g, body, false)) |u| {
        if (u.op != .param) continue;
        params[u.arg.param.slot] = u;
        n = @max(n, u.arg.param.slot + 1);
    }
    try w.writeAll(c_helpers);
    try w.writeAll("KERNEL void kernel(");
    for (params[0..n], 0..) |p, i| {
        try w.print("{s}{s} *p{d}", .{ if (i > 0) ", " else "", CRender.ctype(p.?.arg.param.dtype), i });
    }
    try w.writeAll(") {\n");
    // the kernel is SINK(END(STORE, ranges...)), or SINK(STORE) for a scalar
    const top = body.src[0];
    const ranges: []const *const UOp = if (top.op == .end) top.src[1..] else &.{};
    var total: usize = 1;
    for (ranges) |r| total *= @intCast(r.src[0].intValue().?);
    try w.print("  int gid = {s};\n", .{⟪"blockIdx_x * blockDim_x + threadIdx_x"|||???⟫});
    try w.print("  if (gid >= {d}) return;\n", .{⟪total|||???⟫});
    var after = total; // the product of the sizes of the ranges after this one
    for (ranges) |r| {
        const size: usize = @intCast(r.src[0].intValue().?);
        after /= size;
        try w.print("  int r{d} = (gid / {d}) % {d};\n", .{ r.arg.int, ⟪after|||???⟫, ⟪size|||???⟫ });
    }
    var r: CRender = .{ .g = g, .w = w, .accs = .init(g.alloc) };
    try r.stmt(if (top.op == .end) top.src[0] else top);
    try w.writeAll("}\n");
    return total;
}

/// How many blocks of `block` threads cover n (077, 201).
fn blocksFor(n: usize, block: u32) u32 {
    return @intCast((n + block - 1) / block);
}

/// Runs a schedule of CALLs (194) on the GPU. Every buffer lives in GPU memory.
const GpuRunner = struct {
    g: *Graph,
    gpu: *Gpu,
    mem: std.AutoHashMap(*const UOp, u64),

    fn init(g: *Graph, gpu: *Gpu) GpuRunner {
        return .{ .g = g, .gpu = gpu, .mem = .init(g.alloc) };
    }

    fn deinit(rn: *GpuRunner) void {
        var it = rn.mem.valueIterator();
        while (it.next()) |p| rn.gpu.free(p.*);
    }

    /// The device address of a BUFFER or ALLOC: zeros, the first time.
    fn address(rn: *GpuRunner, buf: *const UOp) !u64 {
        if (rn.mem.get(buf)) |p| return p;
        const bytes = prod(buf.shape) * 4;
        const p = try rn.gpu.alloc(bytes);
        try rn.gpu.cu.check(rn.gpu.cu.cuMemsetD8_v2(p, 0, bytes));
        try rn.mem.put(buf, p);
        return p;
    }

    const Launch = struct {
        f: ?*anyopaque,
        grid: [3]u32,
        ptrs: [16]u64, // each buffer's device address, in PARAM order
        n: usize,

        /// What cuLaunchKernel wants: one pointer per argument (201).
        fn args(l: *Launch, out: *[16]?*anyopaque) []const ?*anyopaque {
            for (0..l.n) |j| out[j] = ⟪@ptrCast(&l.ptrs[j])|||???⟫;
            return out[0..l.n];
        }
    };

    /// Render, compile and load one CALL; nothing runs yet.
    fn prepare(rn: *GpuRunner, call: *const UOp) !Launch {
        var src: std.Io.Writer.Allocating = .init(rn.g.alloc);
        const threads = try renderCuda(rn.g, call.src[0], &src.writer);
        const ptx = try compilePtx(rn.g.alloc, src.written(), "sm_70");
        var l: Launch = .{ .f = try rn.gpu.function(ptx, "kernel"), .grid = .{ blocksFor(threads, 256), 1, 1 }, .ptrs = undefined, .n = call.src.len - 1 };
        for (call.src[1..], 0..) |arg, j| {
            var buf = arg;
            while (buf.op == .after) buf = buf.src[0]; // run in order, so it has been written
            l.ptrs[j] = try rn.address(buf);
        }
        return l;
    }

    fn launch(rn: *GpuRunner, l: *Launch) !void {
        var buf: [16]?*anyopaque = undefined;
        try rn.gpu.launch(l.f, l.grid, .{ 256, 1, 1 }, 0, l.args(&buf));
    }

    /// Run the whole schedule, in order, and wait for it.
    fn run(rn: *GpuRunner, calls: []const *const UOp) !void {
        for (calls) |c| {
            var l = try rn.prepare(c);
            try rn.launch(&l);
        }
        try rn.gpu.sync();
    }
};

const t = std.testing;

fn gemm(g: *Graph, a_buf: *const UOp, b_buf: *const UOp, n: usize) !*const UOp {
    const a = try g.reshape(a_buf, &.{ n, n });
    const b = try g.reshape(b_buf, &.{ n, n });
    const a3 = try g.permute(try g.expand(try g.permute(a, &.{ 1, 0 }), &.{n}), &.{ 1, 2, 0 });
    const b3 = try g.permute(try g.expand(b, &.{n}), &.{ 1, 0, 2 });
    return g.reduce(try g.mul(a3, b3), .add, 1);
}

test "a column sum, as CUDA: the output range is the grid" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 12);
    const s = try schedule(&g, &.{try g.reduce(try g.reshape(x, &.{ 3, 4 }), .add, 1)});
    var out: std.Io.Writer.Allocating = .init(g.alloc);
    try t.expectEqual(4, try renderCuda(&g, s.calls[0].src[0], &out.writer));
    const c = out.written();
    // one thread per output element; the reduce is still a loop, inside each thread
    try t.expect(std.mem.indexOf(u8, c, "KERNEL void kernel(float *p0, float *p1) {") != null);
    try t.expect(std.mem.indexOf(u8, c, "for (int r0") == null);
    try t.expect(std.mem.indexOf(u8, c, "for (int r1 = 0; r1 < 3; r1++) {") != null);
    try t.expect(std.mem.indexOf(u8, c, "  p0[r0] = acc0;\n}\n") != null);
    // gid is made of the three things a thread knows about itself (the GPU tests check how)
    const at = std.mem.indexOf(u8, c, "  int gid = ").?;
    const gid_line = c[at .. at + std.mem.indexOfScalar(u8, c[at..], '\n').?];
    for ([_][]const u8{ "blockIdx_x", "blockDim_x", "threadIdx_x" }) |piece| try t.expectEqual(1, std.mem.count(u8, gid_line, piece));
}

test "three output axes: each range from gid, last one fastest" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = try g.reshape(g.buffer(0, .f32, 24), &.{ 2, 3, 4 });
    const s = try schedule(&g, &.{try g.add(x, try g.expand(g.float(1), &.{ 2, 3, 4 }))});
    var out: std.Io.Writer.Allocating = .init(g.alloc);
    try t.expectEqual(24, try renderCuda(&g, s.calls[0].src[0], &out.writer));
    const c = out.written();
    try t.expect(std.mem.indexOf(u8, c, "if (gid >= 24) return;") != null);
    try t.expect(std.mem.indexOf(u8, c, "int r0 = (gid / 12) % 2;") != null);
    try t.expect(std.mem.indexOf(u8, c, "int r1 = (gid / 4) % 3;") != null);
    try t.expect(std.mem.indexOf(u8, c, "int r2 = (gid / 1) % 4;") != null);
}

test "softmax's shape, three kernels from your compiler, on the GPU" {
    // (x - max) / sum(x - max): softmax's structure, a max, a broadcast,
    // a sum and a divide, without the exp, which our UIR doesn't have
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const n = 1000; // not a multiple of 256: the last block has spare threads
    const x = g.buffer(0, .f32, n);
    const m = try g.reduce(x, .max, 1);
    const d = try g.add(x, try g.mul(try g.expand(m, &.{n}), try g.expand(g.float(-1), &.{n})));
    const y = try g.mul(d, try g.expand(try g.alu(.recip, &.{try g.reduce(d, .add, 1)}), &.{n}));
    const s = try schedule(&g, &.{y});
    try t.expectEqual(3, s.calls.len);

    var prng = std.Random.DefaultPrng.init(6);
    var data: [n]f32 = undefined;
    for (&data) |*v| v.* = prng.random().float(f32) * 4 - 2;
    var it = Interp.init(&g);
    for (it.storage(x), data) |*v, f| v.* = f;
    const want = try it.eval(y);

    var gpu = Gpu.open() catch return error.SkipZigTest;
    var rn = GpuRunner.init(&g, &gpu);
    defer rn.deinit();
    try gpu.upload(try rn.address(x), &data);
    try rn.run(s.calls);
    var got: [n]f32 = undefined;
    try gpu.download(&got, try rn.address(s.lower.filled.get(y).?.src[0]));
    for (want.data, got) |w, v| try t.expectApproxEqAbs(w, v, 1e-4);
}

test "the gist's matmul, from tensors to your GPU" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const n = 1024;
    const a = g.buffer(0, .f32, n * n);
    const b = g.buffer(1, .f32, n * n);
    const c = try gemm(&g, a, b, n);
    const s = try schedule(&g, &.{c});
    try t.expectEqual(1, s.calls.len);

    var gpu = Gpu.open() catch return error.SkipZigTest;
    var rn = GpuRunner.init(&g, &gpu);
    defer rn.deinit();
    const av = try t.allocator.alloc(f32, n * n);
    defer t.allocator.free(av);
    const bv = try t.allocator.alloc(f32, n * n);
    defer t.allocator.free(bv);
    const cv = try t.allocator.alloc(f32, n * n);
    defer t.allocator.free(cv);
    var prng = std.Random.DefaultPrng.init(8);
    for (av, bv) |*p, *q| {
        p.* = prng.random().float(f32) - 0.5;
        q.* = prng.random().float(f32) - 0.5;
    }
    try gpu.upload(try rn.address(a), av);
    try gpu.upload(try rn.address(b), bv);
    var l = try rn.prepare(s.calls[0]);
    var buf: [16]?*anyopaque = undefined;
    const secs = try gpu.time(3, l.f, l.grid, .{ 256, 1, 1 }, 0, l.args(&buf));
    try gpu.download(cv, try rn.address(s.lower.filled.get(c).?.src[0]));
    var r = std.Random.DefaultPrng.init(9);
    for (0..32) |_| {
        const i = r.random().uintLessThan(usize, n);
        const j = r.random().uintLessThan(usize, n);
        var want: f64 = 0;
        for (0..n) |k| want += @as(f64, av[i * n + k]) * bv[k * n + j];
        try t.expectApproxEqAbs(want, cv[i * n + j], 1e-3);
    }
    const flops = 2.0 * @as(f64, n) * n * n;
    std.debug.print(
        \\
        \\{d}x{d} matmul, from a tensor graph to {s}:
        \\  {d:.3} ms, {d:.2} TFLOPS, with no opts at all.
        \\  That's 204's naive kernel, written by your compiler. 196-200's opts
        \\  (LOCAL, UPCAST, BEAM) are how tinygrad gets from here to 204's blocked one.
        \\
    , .{ n, n, gpu.name(), secs * 1e3, flops / secs * 1e-12 });
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

//@include cuda
