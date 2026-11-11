//
// ─── Exercise 195: kernels you can run ────────────────────────────────
//
// Chapter 37's capstone: from a tensor program to compiled C, through
// everything you've built. The gist's matmul (reshape, mul, reduce)
// becomes one kernel (192-194), and that kernel's body becomes C (042),
// compiled with `zig cc` and loaded with std.DynLib (052).
//
// Rendering the body is a walk over it. Statements come from the
// structure, expressions from the rest:
//
//   END(x, r0, r1)     for (int r0 = 0; r0 < n0; r0++) { for (...r1...) { x } }
//   STORE(INDEX(p, i), v)     p[i] = v;
//   REDUCE(x, r)       a statement BEFORE the store that uses it:
//                          float acc0 = 0.0f;              (its identity)
//                          for (int r = 0; r < n; r++) acc0 = acc0 + x;
//                      and then, in the expression, just acc0. A reduce
//                      inside a reduce goes inside that reduce's loop.
//   INDEX(p, i)        p[i]                 RANGE      r3
//   WHERE(c, a, b)     (c ? a : b)          DIV, MOD   idiv(a, b), imod(a, b):
//                                                      floor, not C's / (183)
//
// Every kernel gets the same C signature, `void kernel(void **b)`: its
// PARAMs, by slot, as pointers, so one Zig function type calls them all.
// (minicompiler.zig does the same.)
//
// This is the whole of tinygrad's pipeline in miniature: tensor graph,
// rangeify, kernels, render, compile, run. Chapter 38 makes it fast.
//
// YOUR TASK: the loop and the store in stmt(), a REDUCE's loop in
// reduceStmt(), and INDEX and WHERE in expr().
//
const std = @import("std");

//@export render_c
const CRender = struct {
    g: *Graph,
    w: *std.Io.Writer,
    accs: std.AutoHashMap(*const UOp, usize),
    depth: usize = 1,

    fn ctype(d: DType) []const u8 {
        return switch (commit(d)) {
            .f32 => "float",
            .i32, .bool => "int",
            else => "void",
        };
    }

    fn indent(r: *CRender) std.Io.Writer.Error!void {
        for (0..r.depth) |_| try r.w.writeAll("  ");
    }

    fn expr(r: *CRender, u: *const UOp) std.Io.Writer.Error!void {
        const w = r.w;
        switch (u.op) {
            .constant => switch (u.arg) {
                .int => |v| try w.print("{d}", .{v}),
                .boolean => |v| try w.writeAll(if (v) "1" else "0"),
                .float => |v| {
                    if (std.math.isNan(v)) return w.writeAll("__builtin_nanf(\"\")");
                    if (std.math.isInf(v)) return w.writeAll(if (v > 0) "__builtin_inff()" else "-__builtin_inff()");
                    // huge or tiny numbers in scientific notation: 1e30
                    // written out is 31 digits, too many for C's floats
                    var buf: [64]u8 = undefined;
                    const big_or_tiny = v != 0 and (@abs(v) >= 1e15 or @abs(v) < 1e-6);
                    const digits = (if (big_or_tiny) std.fmt.bufPrint(&buf, "{e}", .{v}) else std.fmt.bufPrint(&buf, "{d}", .{v})) catch unreachable;
                    try w.print("{s}{s}f", .{ digits, if (std.mem.indexOfAny(u8, digits, ".e") == null) ".0" else "" });
                },
                else => unreachable,
            },
            .range => try w.print("r{d}", .{u.arg.int}),
            .param => try w.print("p{d}[0]", .{u.arg.param.slot}), // a scalar buffer
            .index => {
                if (reduceLane(u)) |rl| return w.print("acc{d}[{d}]", .{ r.accs.get(rl.red).?, rl.lane });
                ⟪try w.print("p{d}[", .{u.src[0].arg.param.slot});|||???;⟫
                try r.expr(u.src[1]);
                try w.writeAll("]");
            },
            .reduce => try w.print("acc{d}", .{r.accs.get(u).?}),
            .where => {
                try w.writeAll("(");
                try r.expr(u.src[0]);
                ⟪try w.writeAll(" ? ");|||???;⟫
                try r.expr(u.src[1]);
                try w.writeAll(" : ");
                try r.expr(u.src[2]);
                try w.writeAll(")");
            },
            .cast => {
                // to bool is x != 0 (183), not C's (int)x
                if (u.dtype == .bool) try w.writeAll("(") else try w.print("(({s})", .{ctype(u.dtype)});
                try r.expr(u.src[0]);
                try w.writeAll(if (u.dtype == .bool) " != 0)" else ")");
            },
            .recip => {
                try w.writeAll("(1.0f / ");
                try r.expr(u.src[0]);
                try w.writeAll(")");
            },
            .max, .div, .mod => {
                const name = switch (u.op) {
                    .max => if (u.dtype.isFloat()) "fmax2" else "imax2",
                    .div => "idiv",
                    else => "imod",
                };
                try w.print("{s}(", .{name});
                try r.expr(u.src[0]);
                try w.writeAll(", ");
                try r.expr(u.src[1]);
                try w.writeAll(")");
            },
            .add, .mul, .xor, .shl, .cmplt, .cmpne => {
                const sym = switch (u.op) {
                    .add => if (u.dtype == .bool) " | " else " + ", // bool ADD is OR (183)
                    .mul => " * ",
                    .xor => " ^ ",
                    .shl => " << ",
                    .cmplt => " < ",
                    else => " != ",
                };
                try w.writeAll("(");
                try r.expr(u.src[0]);
                try w.writeAll(sym);
                try r.expr(u.src[1]);
                try w.writeAll(")");
            },
            else => unreachable,
        }
    }

    fn openLoop(r: *CRender, rng: *const UOp) std.Io.Writer.Error!void {
        try r.indent();
        try r.w.print("for (int r{d} = 0; r{d} < {d}; r{d}++) {{\n", .{ rng.arg.int, rng.arg.int, rng.src[0].intValue().?, rng.arg.int });
        r.depth += 1;
    }

    fn closeLoop(r: *CRender) std.Io.Writer.Error!void {
        r.depth -= 1;
        try r.indent();
        try r.w.writeAll("}\n");
    }

    /// Emit, as statements, every REDUCE that `u` uses (but not those
    /// inside them: each reduce emits its own).
    fn hoistReduces(r: *CRender, u: *const UOp) std.Io.Writer.Error!void {
        if (u.op == .reduce) {
            if (!r.accs.contains(u)) try r.reduceStmt(u);
            return;
        }
        for (u.src) |s| try r.hoistReduces(s);
    }

    fn reduceStmt(r: *CRender, red: *const UOp) std.Io.Writer.Error!void {
        const n = r.accs.count();
        const op = red.arg.reduce.op;
        // a vector reduce (197) has one accumulator per lane: an array
        const lanes = vectorLanes(r.g, red.src[0]);
        const vector = red.src[0].op == .stack;
        try r.indent();
        if (vector) {
            try r.w.print("{s} acc{d}[{d}] = {{", .{ ctype(red.dtype), n, lanes.len });
            for (lanes, 0..) |_, l| {
                if (l > 0) try r.w.writeAll(", ");
                try r.expr(identityConst(r.g, op, red.dtype));
            }
            try r.w.writeAll("};\n");
        } else {
            try r.w.print("{s} acc{d} = ", .{ ctype(red.dtype), n });
            try r.expr(identityConst(r.g, op, red.dtype));
            try r.w.writeAll(";\n");
        }
        for (red.src[1..]) |rng| try r.openLoop(rng);
        try r.hoistReduces(red.src[0]); // a reduce inside goes inside our loops
        for (lanes, 0..) |lane, l| {
            var name_buf: [32]u8 = undefined;
            const name = if (vector)
                std.fmt.bufPrint(&name_buf, "acc{d}[{d}]", .{ n, l }) catch unreachable
            else
                std.fmt.bufPrint(&name_buf, "acc{d}", .{n}) catch unreachable;
            try r.indent();
            switch (op) {
                .max => try r.w.print("{s} = {s}({s}, ", .{ name, if (red.dtype.isFloat()) "fmax2" else "imax2", name }),
                else => ⟪try r.w.print("{s} = {s} {s} ", .{ name, name, if (op == .add) "+" else "*" })|||???⟫,
            }
            try r.expr(lane);
            try r.w.writeAll(if (op == .max) ");\n" else ";\n");
        }
        for (red.src[1..]) |_| try r.closeLoop();
        r.accs.put(red, n) catch @panic("out of memory");
    }

    fn stmt(r: *CRender, u: *const UOp) std.Io.Writer.Error!void {
        switch (u.op) {
            .end => {
                for (u.src[1..]) |rng| ⟪try r.openLoop(rng);|||???;⟫
                try r.stmt(u.src[0]);
                for (u.src[1..]) |_| try r.closeLoop();
            },
            .store => {
                try r.hoistReduces(u.src[1]);
                try r.indent();
                ⟪try r.expr(u.src[0]);|||???;⟫
                try r.w.writeAll(" = ");
                try r.expr(u.src[1]);
                try r.w.writeAll(";\n");
            },
            .sink => for (u.src) |s| try r.stmt(s),
            else => unreachable,
        }
    }
};

/// The lanes of a vector: a STACK (of STACKs...) flattened, row-major.
fn vectorLanes(g: *Graph, u: *const UOp) []const *const UOp {
    if (u.op != .stack) return g.alloc.dupe(*const UOp, &.{u}) catch @panic("out of memory");
    var out: std.ArrayList(*const UOp) = .empty;
    for (u.src) |s| out.appendSlice(g.alloc, vectorLanes(g, s)) catch @panic("out of memory");
    return out.items;
}

/// INDEX(INDEX(REDUCE, a), b) with constant a, b: which reduce, which lane.
fn reduceLane(u: *const UOp) ?struct { red: *const UOp, lane: usize } {
    var x = u;
    var idx: [8]usize = undefined;
    var k: usize = 0;
    while (x.op == .index) {
        if (x.src.len != 2) return null;
        const c = x.src[1].intValue() orelse return null;
        idx[k] = @intCast(c);
        k += 1;
        x = x.src[0];
    }
    if (x.op != .reduce or k == 0) return null;
    // the outermost INDEX was found first: reverse into axis order
    std.mem.reverse(usize, idx[0..k]);
    var lane: usize = 0;
    for (idx[0..k], x.shape[0..k]) |i, n| lane = lane * n + i;
    return .{ .red = x, .lane = lane };
}

const c_helpers =
    \\static inline int idiv(int a, int b) { int q = a / b; return (q * b != a && ((a < 0) != (b < 0))) ? q - 1 : q; }
    \\static inline int imod(int a, int b) { return a - idiv(a, b) * b; }
    \\static inline float fmax2(float a, float b) { return a > b ? a : b; }
    \\static inline int imax2(int a, int b) { return a > b ? a : b; }
    \\
;

/// A kernel's body (a CALL's src[0]) as one C function: void kernel(void **b).
fn renderC(g: *Graph, body: *const UOp, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var params: [16]?*const UOp = @splat(null);
    var n: usize = 0;
    for (toposort(g, body, false)) |u| {
        if (u.op != .param) continue;
        params[u.arg.param.slot] = u;
        n = @max(n, u.arg.param.slot + 1);
    }
    try w.writeAll(c_helpers);
    try w.writeAll("void kernel(void **b) {\n");
    for (params[0..n], 0..) |p, i| {
        const ty = CRender.ctype(p.?.arg.param.dtype);
        try w.print("  {s} *p{d} = ({s} *)b[{d}];\n", .{ ty, i, ty, i });
    }
    var r: CRender = .{ .g = g, .w = w, .accs = .init(g.alloc) };
    try r.stmt(body);
    try w.writeAll("}\n");
}
//@end

const KernelFn = *const fn ([*]const ?*anyopaque) callconv(.c) void;

/// Render, compile with zig cc, and load one kernel body.
fn compile(g: *Graph, body: *const UOp, tmp: *std.testing.TmpDir, name: []const u8) !std.DynLib {
    const io = std.testing.io;
    var src: std.Io.Writer.Allocating = .init(g.alloc);
    try renderC(g, body, &src.writer);
    const c_name = try std.fmt.allocPrint(g.alloc, "{s}.c", .{name});
    try tmp.dir.writeFile(io, .{ .sub_path = c_name, .data = src.written() });
    var dir_buf: [4096]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const c_path = try std.fs.path.join(g.alloc, &.{ dir, c_name });
    const so_path = try std.fs.path.join(g.alloc, &.{ dir, try std.fmt.allocPrint(g.alloc, "{s}.so", .{name}) });
    const result = try std.process.run(g.alloc, io, .{
        .argv = &.{ "zig", "cc", "-O3", "-march=native", "-shared", "-fPIC", "-nostdlib", c_path, "-o", so_path },
    });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("zig cc failed:\n{s}\n{s}\n", .{ result.stderr, src.written() });
        return error.CompileFailed;
    }
    return std.DynLib.open(so_path);
}

/// Run a schedule of CALLs as compiled C. Buffers are f32 (or i32) arrays.
const Runner = struct {
    g: *Graph,
    tmp: std.testing.TmpDir,
    arrays: std.AutoHashMap(*const UOp, []f32),
    libs: std.ArrayList(std.DynLib) = .empty,

    fn array(rn: *Runner, buf: *const UOp) []f32 {
        const gop = rn.arrays.getOrPut(buf) catch @panic("out of memory");
        if (!gop.found_existing) {
            gop.value_ptr.* = rn.g.alloc.alloc(f32, prod(buf.shape)) catch @panic("out of memory");
            @memset(gop.value_ptr.*, 0);
        }
        return gop.value_ptr.*;
    }

    fn run(rn: *Runner, calls: []const *const UOp) !void {
        for (calls, 0..) |c, i| {
            var lib = try compile(rn.g, c.src[0], &rn.tmp, try std.fmt.allocPrint(rn.g.alloc, "k{d}", .{i}));
            try rn.libs.append(rn.g.alloc, lib);
            const kernel = lib.lookup(KernelFn, "kernel") orelse return error.KernelNotFound;
            var ptrs: [16]?*anyopaque = undefined;
            for (c.src[1..], 0..) |a, j| {
                var buf = a;
                while (buf.op == .after) buf = buf.src[0];
                ptrs[j] = rn.array(buf).ptr;
            }
            kernel(&ptrs);
        }
    }

    fn deinit(rn: *Runner) void {
        for (rn.libs.items) |*l| l.close();
        rn.tmp.cleanup();
    }
};

const t = std.testing;

fn gemm(g: *Graph, a_buf: *const UOp, b_buf: *const UOp, n: usize) !*const UOp {
    // the leading-axis way: C[i, j] = sum over k of A[i, k] * B[k, j]
    const a = try g.reshape(a_buf, &.{ n, n });
    const b = try g.reshape(b_buf, &.{ n, n });
    const a3 = try g.permute(try g.expand(try g.permute(a, &.{ 1, 0 }), &.{n}), &.{ 1, 2, 0 });
    const b3 = try g.permute(try g.expand(b, &.{n}), &.{ 1, 0, 2 });
    return g.reduce(try g.mul(a3, b3), .add, 1);
}

test "a column sum, as C" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .f32, 12);
    const s = try schedule(&g, &.{try g.reduce(try g.reshape(x, &.{ 3, 4 }), .add, 1)});
    var out: std.Io.Writer.Allocating = .init(g.alloc);
    try renderC(&g, s.calls[0].src[0], &out.writer);
    try t.expectEqualStrings(c_helpers ++
        \\void kernel(void **b) {
        \\  float *p0 = (float *)b[0];
        \\  float *p1 = (float *)b[1];
        \\  for (int r0 = 0; r0 < 4; r0++) {
        \\    float acc0 = 0.0f;
        \\    for (int r1 = 0; r1 < 3; r1++) {
        \\      acc0 = acc0 + p1[((r1 * 4) + r0)];
        \\    }
        \\    p0[r0] = acc0;
        \\  }
        \\}
        \\
    , out.written());
}

test "an int reduce gets an int accumulator" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.buffer(0, .i32, 12);
    const s = try schedule(&g, &.{try g.reduce(try g.reshape(x, &.{ 3, 4 }), .max, 1)});
    var out: std.Io.Writer.Allocating = .init(g.alloc);
    try renderC(&g, s.calls[0].src[0], &out.writer);
    // max starts from the smallest int, not from a float's -inf
    try t.expect(std.mem.indexOf(u8, out.written(), "int acc0 = -2147483648;") != null);
    try t.expect(std.mem.indexOf(u8, out.written(), "acc0 = imax2(acc0, p1[((r1 * 4) + r0)]);") != null);
}

test "bools in C follow the spec, not C" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    var out: std.Io.Writer.Allocating = .init(g.alloc);
    var r: CRender = .{ .g = &g, .w = &out.writer, .accs = .init(g.alloc) };
    const x = g.param(0, .f32, null);
    const b = try g.cast(x, .bool);
    try r.expr(try g.add(b, b)); // a cast to bool is x != 0, and bool ADD is OR (183)
    try t.expectEqualStrings("((p0[0] != 0) | (p0[0] != 0))", out.written());
}

test "float constants C can read" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    for ([_]f64{ 2, 0.5, 1e30, 1e-30, std.math.nan(f64), -std.math.inf(f64) }, [_][]const u8{ "2.0f", "0.5f", "1e30f", "1e-30f", "__builtin_nanf(\"\")", "-__builtin_inff()" }) |v, want| {
        var out: std.Io.Writer.Allocating = .init(g.alloc);
        var r: CRender = .{ .g = &g, .w = &out.writer, .accs = .init(g.alloc) };
        try r.expr(g.float(v));
        try t.expectEqualStrings(want, out.written());
    }
}

test "softmax, compiled: three kernels that agree with the interpreter" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const n = 7;
    const x = g.buffer(0, .f32, n);
    const m = try g.reduce(x, .max, 1);
    const d = try g.add(x, try g.mul(try g.expand(m, &.{n}), try g.expand(g.float(-1), &.{n})));
    const y = try g.mul(d, try g.expand(try g.alu(.recip, &.{try g.reduce(d, .add, 1)}), &.{n}));
    const data = [n]f64{ 0.5, 2, -1, 3, 0, 1.5, -2 };
    var it = Interp.init(&g);
    @memcpy(it.storage(x), &data);
    const want = try it.eval(y);

    const s = try schedule(&g, &.{y});
    try t.expectEqual(3, s.calls.len);
    var rn: Runner = .{ .g = &g, .tmp = t.tmpDir(.{}), .arrays = .init(g.alloc) };
    defer rn.deinit();
    for (rn.array(x), data) |*a, v| a.* = @floatCast(v);
    try rn.run(s.calls);
    const got = rn.array(s.lower.filled.get(y).?.src[0]);
    for (want.data, got) |w, v| try t.expectApproxEqAbs(w, v, 1e-5);
}

test "the gist's matmul: one kernel, checked, then timed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();

    // small, against the interpreter
    {
        const n = 16;
        const a = g.buffer(0, .f32, n * n);
        const b = g.buffer(1, .f32, n * n);
        const c = try gemm(&g, a, b, n);
        var it = Interp.init(&g);
        for (it.storage(a)) |*v| v.* = @floatCast(@as(f32, rand.float(f32) - 0.5));
        for (it.storage(b)) |*v| v.* = @floatCast(@as(f32, rand.float(f32) - 0.5));
        const want = try it.eval(c);
        const s = try schedule(&g, &.{c});
        try t.expectEqual(1, s.calls.len);
        var rn: Runner = .{ .g = &g, .tmp = t.tmpDir(.{}), .arrays = .init(g.alloc) };
        defer rn.deinit();
        for (rn.array(a), it.storage(a)) |*d, v| d.* = @floatCast(v);
        for (rn.array(b), it.storage(b)) |*d, v| d.* = @floatCast(v);
        try rn.run(s.calls);
        for (want.data, rn.array(s.lower.filled.get(c).?.src[0])) |w, v| try t.expectApproxEqAbs(w, v, 1e-4);
    }

    // 256 x 256, timed (176): compile once, then the best of 5 runs
    const n = 256;
    const a = g.buffer(2, .f32, n * n);
    const b = g.buffer(3, .f32, n * n);
    const s = try schedule(&g, &.{try gemm(&g, a, b, n)});
    try t.expectEqual(1, s.calls.len);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var lib = try compile(&g, s.calls[0].src[0], &tmp, "gemm");
    defer lib.close();
    const kernel = lib.lookup(KernelFn, "kernel") orelse return error.KernelNotFound;
    const av = try g.alloc.alloc(f32, n * n);
    const bv = try g.alloc.alloc(f32, n * n);
    const cv = try g.alloc.alloc(f32, n * n);
    for (av, bv) |*x, *y| {
        x.* = rand.float(f32);
        y.* = rand.float(f32);
    }
    // the CALL's args, in PARAM order: whichever buffers the body touched first
    var ptrs: [3]?*anyopaque = undefined;
    for (s.calls[0].src[1..], 0..) |arg, j| {
        var buf = arg;
        while (buf.op == .after) buf = buf.src[0];
        ptrs[j] = if (buf == a) av.ptr else if (buf == b) bv.ptr else cv.ptr;
    }
    const io = t.io;
    var best: f64 = std.math.inf(f64);
    for (0..5) |_| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        kernel(&ptrs);
        const dt = t0.durationTo(std.Io.Timestamp.now(io, .awake));
        best = @min(best, @as(f64, @floatFromInt(dt.nanoseconds)) * 1e-9);
    }
    // spot checks against a plain loop
    for ([_][2]usize{ .{ 0, 0 }, .{ 17, 200 }, .{ 255, 255 } }) |ij| {
        var sum: f32 = 0;
        for (0..n) |k| sum += av[ij[0] * n + k] * bv[k * n + ij[1]];
        try t.expectApproxEqRel(sum, cv[ij[0] * n + ij[1]], 1e-4);
    }
    const flops: f64 = 2.0 * n * n * n;
    std.debug.print("\n256x256 matmul, from tensors to C: {d:.3} ms, {d:.2} GFLOPS (best of 5)\nChapter 38 makes it faster.\n", .{ best * 1e3, flops / best * 1e-9 });
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
