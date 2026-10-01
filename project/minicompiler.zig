//! The final project: a real (tiny) ML compiler, in one file.
//!
//! Everything the course built in pieces, working together for real:
//!
//!   lazy graph (021)  ->  movement ops as index maths (073)  ->  kernel
//!   fusion and scheduling (040)  ->  C code generation (042, 076)  ->
//!   compile with `zig cc` and load with std.DynLib (052)  ->  run and
//!   benchmark (176)
//!
//! A matmul is written the tinygrad way, as reshape + expand + mul + sum
//! (019), and this compiler fuses it into ONE C kernel, compiles it, and
//! times it against a plain Zig triple loop.
//!
//!   Run it:  zig test project/minicompiler.zig
//!
//! Then read project/README.md for the milestones to extend it with.

const std = @import("std");

// ─── 1. The graph ───────────────────────────────────────────────────────

pub const Op = enum {
    buffer, //  input data, or an already-computed kernel output
    constant, // the same number everywhere
    neg,
    add,
    mul,
    max,
    sum, //      reduce the LAST axis to size 1 (keepdim)
    reshape, // movement ops: no math, only change which index is read
    permute,
    expand,
};

pub const Node = struct {
    op: Op,
    shape: []const usize,
    src: [2]?*Node = .{ null, null },
    value: f32 = 0, //                  .constant
    perm: []const usize = &.{}, //      .permute: new axis i is old axis perm[i]
    data: ?[]f32 = null, //             .buffer, or a realized node
};

pub const Graph = struct {
    alloc: std.mem.Allocator,

    fn node(g: Graph, n: Node) *Node {
        const p = g.alloc.create(Node) catch @panic("OOM");
        p.* = n;
        return p;
    }

    fn dup(g: Graph, s: []const usize) []const usize {
        return g.alloc.dupe(usize, s) catch @panic("OOM");
    }

    pub fn buffer(g: Graph, shape: []const usize, data: []f32) *Node {
        return g.node(.{ .op = .buffer, .shape = g.dup(shape), .data = data });
    }
    pub fn constant(g: Graph, shape: []const usize, v: f32) *Node {
        return g.node(.{ .op = .constant, .shape = g.dup(shape), .value = v });
    }
    pub fn neg(g: Graph, a: *Node) *Node {
        return g.node(.{ .op = .neg, .shape = a.shape, .src = .{ a, null } });
    }
    fn binary(g: Graph, op: Op, a: *Node, b: *Node) *Node {
        std.debug.assert(std.mem.eql(usize, a.shape, b.shape));
        return g.node(.{ .op = op, .shape = a.shape, .src = .{ a, b } });
    }
    pub fn add(g: Graph, a: *Node, b: *Node) *Node {
        return g.binary(.add, a, b);
    }
    pub fn mul(g: Graph, a: *Node, b: *Node) *Node {
        return g.binary(.mul, a, b);
    }
    pub fn max(g: Graph, a: *Node, b: *Node) *Node {
        return g.binary(.max, a, b);
    }
    pub fn sum(g: Graph, a: *Node) *Node {
        const s = g.alloc.dupe(usize, a.shape) catch @panic("OOM");
        s[s.len - 1] = 1;
        return g.node(.{ .op = .sum, .shape = s, .src = .{ a, null } });
    }
    pub fn reshape(g: Graph, a: *Node, shape: []const usize) *Node {
        std.debug.assert(numel(shape) == numel(a.shape));
        return g.node(.{ .op = .reshape, .shape = g.dup(shape), .src = .{ a, null } });
    }
    pub fn permute(g: Graph, a: *Node, perm: []const usize) *Node {
        const s = g.alloc.alloc(usize, perm.len) catch @panic("OOM");
        for (s, perm) |*d, p| d.* = a.shape[p];
        return g.node(.{ .op = .permute, .shape = s, .src = .{ a, null }, .perm = g.dup(perm) });
    }
    pub fn expand(g: Graph, a: *Node, shape: []const usize) *Node {
        for (a.shape, shape) |from, to| std.debug.assert(from == to or from == 1);
        return g.node(.{ .op = .expand, .shape = g.dup(shape), .src = .{ a, null } });
    }

    /// The tinygrad matmul (019): [m, k] x [k, n] -> [m, n, 1].
    pub fn matmul(g: Graph, a: *Node, b: *Node) *Node {
        const m = a.shape[0];
        const k = a.shape[1];
        const n = b.shape[1];
        const ae = g.expand(g.reshape(a, &.{ m, 1, k }), &.{ m, n, k });
        const be = g.expand(g.permute(g.reshape(b, &.{ 1, k, n }), &.{ 0, 2, 1 }), &.{ m, n, k });
        return g.sum(g.mul(ae, be));
    }
};

pub fn numel(shape: []const usize) usize {
    var n: usize = 1;
    for (shape) |d| n *= d;
    return n;
}

// ─── 2. Index maths: movement ops never move data (073) ─────────────────
//
// To read node n at a multi-index (one C expression per axis), write the
// C expression for its value. Movement ops just rewrite the index
// expressions and pass them on to their source.

const Ctx = struct {
    alloc: std.mem.Allocator,
    bufs: *std.ArrayList(*Node), // kernel arguments, in order

    fn bufIndex(c: Ctx, n: *Node) usize {
        for (c.bufs.items, 0..) |b, i| if (b == n) return i;
        c.bufs.append(c.alloc, n) catch @panic("OOM");
        return c.bufs.items.len - 1;
    }

    fn fmt(c: Ctx, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(c.alloc, f, args) catch @panic("OOM");
    }

    /// The C expression for the value of n at index `idx`.
    fn expr(c: Ctx, n: *Node, idx: []const []const u8) []const u8 {
        if (n.data != null) {
            // a buffer in memory: row-major position, a dot product with the strides (007)
            var lin: []const u8 = "0";
            var stride: usize = 1;
            var i = n.shape.len;
            while (i > 0) {
                i -= 1;
                if (n.shape[i] != 1) lin = c.fmt("{s}+({s})*{d}", .{ lin, idx[i], stride });
                stride *= n.shape[i];
            }
            return c.fmt("b{d}[{s}]", .{ c.bufIndex(n), lin });
        }
        return switch (n.op) {
            .constant => c.fmt("((float){d})", .{n.value}),
            .neg => c.fmt("(-{s})", .{c.expr(n.src[0].?, idx)}),
            .add => c.fmt("({s}+{s})", .{ c.expr(n.src[0].?, idx), c.expr(n.src[1].?, idx) }),
            .mul => c.fmt("({s}*{s})", .{ c.expr(n.src[0].?, idx), c.expr(n.src[1].?, idx) }),
            .max => blk: {
                const a = c.expr(n.src[0].?, idx);
                const b = c.expr(n.src[1].?, idx);
                break :blk c.fmt("(({s})>({s})?({s}):({s}))", .{ a, b, a, b });
            },
            .expand => blk: {
                // a stretched size-1 axis always reads index 0 (012)
                const src = n.src[0].?;
                const out = c.alloc.alloc([]const u8, idx.len) catch @panic("OOM");
                for (out, src.shape, idx) |*o, d, e| o.* = if (d == 1) "0" else e;
                break :blk c.expr(src, out);
            },
            .permute => blk: {
                const src = n.src[0].?;
                const out = c.alloc.alloc([]const u8, idx.len) catch @panic("OOM");
                for (n.perm, idx) |p, e| out[p] = e;
                break :blk c.expr(src, out);
            },
            .reshape => blk: {
                // flatten the new index, then unravel it over the old shape (008)
                const src = n.src[0].?;
                var lin: []const u8 = "0";
                var stride: usize = 1;
                var i = n.shape.len;
                while (i > 0) {
                    i -= 1;
                    if (n.shape[i] != 1) lin = c.fmt("{s}+({s})*{d}", .{ lin, idx[i], stride });
                    stride *= n.shape[i];
                }
                const out = c.alloc.alloc([]const u8, src.shape.len) catch @panic("OOM");
                stride = 1;
                i = src.shape.len;
                while (i > 0) {
                    i -= 1;
                    out[i] = if (src.shape[i] == 1) "0" else c.fmt("(({s})/{d}%{d})", .{ lin, stride, src.shape[i] });
                    stride *= src.shape[i];
                }
                break :blk c.expr(src, out);
            },
            .buffer, .sum => unreachable, // always realized before being read
        };
    }
};

// ─── 3. Scheduling and codegen ──────────────────────────────────────────
//
// The kernel rule (040): elementwise and movement ops fuse into whoever
// reads them; a sum is realized as its own kernel first. One kernel per
// realized node, as C:
//
//     void kernel(float** b) { for each output index: b[0][...] = <expr>; }

pub const Kernel = struct {
    source: []const u8,
    bufs: []*Node, // b[0] is the output
};

/// Make sure every sum feeding n has been computed, then emit n's kernel.
fn collectSums(n: *Node, out: *std.ArrayList(*Node), alloc: std.mem.Allocator) void {
    if (n.data != null) return;
    for (n.src) |s| if (s) |src| collectSums(src, out, alloc);
    if (n.op == .sum) out.append(alloc, n) catch @panic("OOM");
}

pub fn renderKernel(alloc: std.mem.Allocator, n: *Node) !Kernel {
    var bufs: std.ArrayList(*Node) = .empty;
    try bufs.append(alloc, n); // the output is b0
    const c: Ctx = .{ .alloc = alloc, .bufs = &bufs };

    var src: std.Io.Writer.Allocating = .init(alloc);
    const w = &src.writer;
    try w.writeAll("void kernel(float** b) {\n");

    var idx = try alloc.alloc([]const u8, n.shape.len);
    var indent: usize = 1;
    for (n.shape, 0..) |d, i| {
        idx[i] = if (d == 1) "0" else c.fmt("i{d}", .{i});
        if (d == 1) continue;
        try w.splatByteAll(' ', indent * 2);
        try w.print("for (int i{d} = 0; i{d} < {d}; i{d}++) {{\n", .{ i, i, d, i });
        indent += 1;
    }

    // the output position, row-major
    var lin: []const u8 = "0";
    var stride: usize = 1;
    var i = n.shape.len;
    while (i > 0) {
        i -= 1;
        if (n.shape[i] != 1) lin = c.fmt("{s}+i{d}*{d}", .{ lin, i, stride });
        stride *= n.shape[i];
    }

    try w.splatByteAll(' ', indent * 2);
    if (n.op == .sum) {
        // a reduce loop with an accumulator (076)
        const s = n.src[0].?;
        const r = s.shape[s.shape.len - 1];
        const ridx = try alloc.dupe([]const u8, idx);
        ridx[ridx.len - 1] = "r";
        try w.print("float acc = 0.0f;\n", .{});
        try w.splatByteAll(' ', indent * 2);
        try w.print("for (int r = 0; r < {d}; r++) acc += {s};\n", .{ r, c.expr(s, ridx) });
        try w.splatByteAll(' ', indent * 2);
        try w.print("b0[{s}] = acc;\n", .{lin});
    } else {
        try w.print("b0[{s}] = {s};\n", .{ lin, c.expr(n, idx) });
    }
    while (indent > 1) {
        indent -= 1;
        try w.splatByteAll(' ', indent * 2);
        try w.writeAll("}\n");
    }
    try w.writeAll("}\n");

    // name the buffers at the top: float* b0 = b[0]; ...
    var full: std.Io.Writer.Allocating = .init(alloc);
    const body = src.written();
    const brace = std.mem.indexOfScalar(u8, body, '{').? + 2;
    try full.writer.writeAll(body[0..brace]);
    for (0..bufs.items.len) |k| try full.writer.print("  float* b{d} = b[{d}];\n", .{ k, k });
    try full.writer.writeAll(body[brace..]);
    return .{ .source = full.written(), .bufs = bufs.items };
}

// ─── 4. Compile, load, run (052) ────────────────────────────────────────

const KernelFn = *const fn ([*]const [*]f32) callconv(.c) void;

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: []const u8, //  where .c and .so files go
    kernels: usize = 0, // how many kernels were compiled
    libs: std.ArrayList(std.DynLib) = .empty,
    verbose: bool = false,

    pub fn deinit(rt: *Runtime) void {
        for (rt.libs.items) |*l| l.close();
        rt.libs.deinit(rt.alloc);
    }

    /// Compile C source to a shared library and return its `kernel`.
    pub fn compile(rt: *Runtime, source: []const u8) !KernelFn {
        const name = try std.fmt.allocPrint(rt.alloc, "k{d}", .{rt.kernels});
        defer rt.alloc.free(name);
        rt.kernels += 1;
        const c_path = try std.fmt.allocPrint(rt.alloc, "{s}/{s}.c", .{ rt.dir, name });
        defer rt.alloc.free(c_path);
        const so_path = try std.fmt.allocPrint(rt.alloc, "{s}/{s}.so", .{ rt.dir, name });
        defer rt.alloc.free(so_path);
        try std.Io.Dir.cwd().writeFile(rt.io, .{ .sub_path = c_path, .data = source });
        const result = try std.process.run(rt.alloc, rt.io, .{
            .argv = &.{ "zig", "cc", "-O3", "-march=native", "-shared", "-fPIC", "-nostdlib", c_path, "-o", so_path },
        });
        defer rt.alloc.free(result.stdout);
        defer rt.alloc.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("zig cc failed:\n{s}\n{s}\n", .{ source, result.stderr });
            return error.CompileFailed;
        }
        try rt.libs.append(rt.alloc, try std.DynLib.open(so_path));
        return rt.libs.items[rt.libs.items.len - 1].lookup(KernelFn, "kernel") orelse error.KernelNotFound;
    }

    /// Compute n: realize the sums it needs, then n itself. Returns its data.
    pub fn realize(rt: *Runtime, arena: std.mem.Allocator, n: *Node) ![]f32 {
        if (n.data) |d| return d;
        var sums: std.ArrayList(*Node) = .empty;
        for (n.src) |s| if (s) |src| collectSums(src, &sums, arena);
        for (sums.items) |s| _ = try rt.realize(arena, s);

        const k = try renderKernel(arena, n);
        if (rt.verbose) std.debug.print("── kernel {d} ──\n{s}", .{ rt.kernels, k.source });
        const f = try rt.compile(k.source);
        const out = try arena.alloc(f32, numel(n.shape));
        n.data = out;
        const ptrs = try arena.alloc([*]f32, k.bufs.len);
        for (ptrs, k.bufs) |*p, b| p.* = b.data.?.ptr;
        f(ptrs.ptr);
        return out;
    }
};

// ─── 5. Tests: correctness, then a benchmark ────────────────────────────

fn testRuntime(_: std.mem.Allocator, dir: []const u8) Runtime {
    return .{ .alloc = std.testing.allocator, .io = std.testing.io, .dir = dir };
}

fn tmpPath(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(std.testing.io, buf)];
}

test "elementwise ops fuse into one kernel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g: Graph = .{ .alloc = arena.allocator() };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    var rt = testRuntime(arena.allocator(), try tmpPath(&tmp, &buf));
    defer rt.deinit();

    var a = [_]f32{ 1, -2, 3, -4 };
    var b = [_]f32{ 2, 2, 2, 2 };
    // relu(a * b + 1)
    const x = g.buffer(&.{4}, &a);
    const y = g.buffer(&.{4}, &b);
    const out = g.max(g.add(g.mul(x, y), g.constant(&.{4}, 1)), g.constant(&.{4}, 0));
    try std.testing.expectEqualSlices(f32, &.{ 3, 0, 7, 0 }, try rt.realize(arena.allocator(), out));
    try std.testing.expectEqual(1, rt.kernels);
}

test "movement ops are free: a transpose is just index maths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g: Graph = .{ .alloc = arena.allocator() };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    var rt = testRuntime(arena.allocator(), try tmpPath(&tmp, &buf));
    defer rt.deinit();

    var a = [_]f32{ 1, 2, 3, 4, 5, 6 }; // [2, 3]
    const t = g.reshape(g.permute(g.buffer(&.{ 2, 3 }, &a), &.{ 1, 0 }), &.{6});
    try std.testing.expectEqualSlices(f32, &.{ 1, 4, 2, 5, 3, 6 }, try rt.realize(arena.allocator(), t));
}

test "a sum is its own kernel, and its reader is another" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g: Graph = .{ .alloc = arena.allocator() };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    var rt = testRuntime(arena.allocator(), try tmpPath(&tmp, &buf));
    defer rt.deinit();

    var a = [_]f32{ 1, 2, 3, 4, 5, 6 }; // [2, 3]
    // row sums, broadcast back, subtracted: x - sum(x)
    const x = g.buffer(&.{ 2, 3 }, &a);
    const s = g.expand(g.sum(x), &.{ 2, 3 });
    const out = g.add(x, g.neg(s));
    try std.testing.expectEqualSlices(f32, &.{ -5, -4, -3, -11, -10, -9 }, try rt.realize(arena.allocator(), out));
    try std.testing.expectEqual(2, rt.kernels);
}

test "matmul from movement ops, fused into one kernel, matches the triple loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const g: Graph = .{ .alloc = alloc };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    var rt = testRuntime(alloc, try tmpPath(&tmp, &buf));
    defer rt.deinit();
    rt.verbose = true; // print the generated C

    const m = 64;
    const k = 48;
    const n = 32;
    const a = try alloc.alloc(f32, m * k);
    const b = try alloc.alloc(f32, k * n);
    for (a, 0..) |*v, i| v.* = @floatFromInt(@as(i32, @intCast(i % 7)) - 3);
    for (b, 0..) |*v, i| v.* = @floatFromInt(@as(i32, @intCast(i % 5)) - 2);

    const c = try rt.realize(alloc, g.matmul(g.buffer(&.{ m, k }, a), g.buffer(&.{ k, n }, b)));
    try std.testing.expectEqual(1, rt.kernels);
    for (0..m) |i| for (0..n) |j| {
        var want: f32 = 0;
        for (0..k) |kk| want += a[i * k + kk] * b[kk * n + j];
        try std.testing.expectEqual(want, c[i * n + j]); // small integers: exact
    };
}

test "benchmark: compiled matmul vs a plain Zig loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = std.testing.io;
    const g: Graph = .{ .alloc = alloc };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    var rt = testRuntime(alloc, try tmpPath(&tmp, &buf));
    defer rt.deinit();

    const n = 256;
    const a = try alloc.alloc(f32, n * n);
    const b = try alloc.alloc(f32, n * n);
    for (a, b, 0..) |*x, *y, i| {
        x.* = @floatFromInt(i % 3);
        y.* = @floatFromInt(i % 5);
    }

    // compile once (outside the timing, like a JIT, 051)
    const node = g.matmul(g.buffer(&.{ n, n }, a), g.buffer(&.{ n, n }, b));
    const kern = try renderKernel(alloc, node);
    const f = try rt.compile(kern.source);
    const out = try alloc.alloc(f32, n * n);
    node.data = out;
    const ptrs = try alloc.alloc([*]f32, kern.bufs.len);
    for (ptrs, kern.bufs) |*p, bn| p.* = bn.data.?.ptr;

    const flops: f64 = 2.0 * n * n * n;
    var best_compiled: f64 = std.math.inf(f64);
    for (0..5) |_| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        f(ptrs.ptr);
        const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake));
        best_compiled = @min(best_compiled, @as(f64, @floatFromInt(dt.nanoseconds)) * 1e-9);
    }

    const ref = try alloc.alloc(f32, n * n);
    var best_naive: f64 = std.math.inf(f64);
    for (0..5) |_| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        for (0..n) |i| for (0..n) |j| {
            var s: f32 = 0;
            for (0..n) |kk| s += a[i * n + kk] * b[kk * n + j];
            ref[i * n + j] = s;
        };
        const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake));
        best_naive = @min(best_naive, @as(f64, @floatFromInt(dt.nanoseconds)) * 1e-9);
    }

    try std.testing.expectEqualSlices(f32, ref, out);
    std.debug.print(
        \\
        \\{d}x{d} matmul, best of 5 (176):
        \\  compiled from the graph:  {d:8.3} ms  {d:7.2} GFLOPS
        \\  plain Zig triple loop:    {d:8.3} ms  {d:7.2} GFLOPS  (debug build of the test)
        \\Milestone 3 of project/README.md: make the compiled one fast.
        \\
    , .{ n, n, best_compiled * 1e3, flops / best_compiled / 1e9, best_naive * 1e3, flops / best_naive / 1e9 });
}
