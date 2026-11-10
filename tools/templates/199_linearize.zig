//
// ─── Exercise 199: one instruction after another ──────────────────────
//
// 195 rendered C by walking the kernel as a tree. A real backend wants a
// flat list instead: one UOp per line, in an order a machine can execute
// (041, now for real). tinygrad gets there in two steps.
//
// 1. A REDUCE becomes memory: an accumulator (tinygrad: pm_reduce_local,
//    in tinygrad/codegen/__init__.py):
//
//        acc  = ALLOC (a register)                        float acc[1];
//        STORE(acc, identity)          after the outer loops open
//        for k:  STORE(acc, LOAD(acc) + x)                acc[0] = acc[0] + x;
//        LOAD(acc)                     after the loop ends
//
//    AFTER says what must happen first, and END closes the loop.
//
// 2. The order (tinygrad/codegen/late/linearizer.py, linearize). Any
//    toposort runs correctly, but some run much faster. tinygrad sorts by
//    a key, then takes the toposort that stays closest to that order:
//
//        key = (number of loops it's inside, priority, slot)
//        priority:  PARAM -20 (by slot)   ALLOC -18   LOAD -1 (early)
//                   STORE 1 (late)        RANGE 5     END -5   else 0
//
//    The first part of the key does the real work: a value that's inside
//    fewer loops sorts earlier, so it lands BEFORE an inner loop opens if
//    it doesn't need that loop. That's loop-invariant code motion, for
//    free: x[i] is loaded once per i, not once per k.
//
//    Then the toposort itself: start from the SINK and walk backwards.
//    Among the nodes whose users are all placed, place the one LATEST in
//    the ideal order. Reverse at the end.
//
// The same machinery, plus a check: loops must nest. A reduce's RANGE gets
// an extra dependency on its accumulator's first STORE, which sits inside
// the outer loops, so it can't open before them. (tinygrad adds such
// edges in pm_add_control_flow.)
//
// YOUR TASK: the load priority and the key in priority(), and the step of
// the toposort in linearize().
//
const std = @import("std");

//@export linearize_uops
/// The loops each node is inside: its open ranges (188's openRanges).
fn loopsOf(it: *Interp, u: *const UOp) usize {
    return it.openRanges(u).len;
}

/// Every REDUCE as an accumulator: ALLOC, STORE identity, a loop of
/// STORE(acc, LOAD(acc) op x), then LOAD after the loop. Also returns the
/// ordering edges for the linearizer: a reduce's RANGE comes after its
/// accumulator is set up.
fn lowerReduces(g: *Graph, ast: *const UOp, edges: *std.AutoHashMap(*const UOp, *const UOp)) Error!*const UOp {
    var map = Subst.init(g.alloc);
    var slot: u32 = 200;
    var it = Interp.init(g);
    for (toposort(g, ast, false)) |red| {
        if (red.op != .reduce) continue;
        const loops = red.src[1..];
        const x = try substitute(g, red.src[0], &map);
        const acc = g.local(slot, commit(red.dtype), null);
        slot += 1;
        // set it up inside whatever loops the reduce itself is inside
        const outer = it.openRanges(red);
        const init = try g.store(try g.after(acc, outer), identityConst(g, red.arg.reduce.op, red.dtype));
        const inside = try g.after(acc, std.mem.concat(g.alloc, *const UOp, &.{ &.{init}, loops }) catch @panic("out of memory"));
        const step = try g.store(inside, try g.alu(red.arg.reduce.op, &.{ try g.load(inside), x }));
        const done = try g.end(step, loops);
        map.put(red, try g.load(try g.after(acc, &.{done}))) catch @panic("out of memory");
        for (loops) |r| edges.put(r, init) catch @panic("out of memory");
    }
    return substitute(g, ast, &map);
}

const Priority = struct { loops: usize, priority: i32, slot: i64 };

fn priority(it: *Interp, u: *const UOp) Priority {
    const p: i32 = switch (u.op) {
        .param => -20,
        .alloc => -18,
        .load => ⟪-1|||???⟫, // loads early
        .store => 1, //                 stores late
        .range => 5,
        .end => -5,
        else => 0,
    };
    const slot: i64 = if (u.op == .param) u.arg.param.slot else 0;
    return .{ .loops = ⟪loopsOf(it, u)|||???⟫, .priority = p, .slot = slot };
}

fn keyLess(a: Priority, b: Priority) bool {
    if (a.loops != b.loops) return a.loops < b.loops;
    if (a.priority != b.priority) return a.priority < b.priority;
    return a.slot < b.slot;
}

/// The kernel as a flat list, close to the ideal order. (tinygrad: linearize)
fn linearize(g: *Graph, sink: *const UOp, edges: *const std.AutoHashMap(*const UOp, *const UOp)) []const *const UOp {
    var it = Interp.init(g);
    const all = toposort(g, sink, false);
    // the deps of each node: its srcs, plus the ordering edges
    var deps = std.AutoHashMap(*const UOp, []const *const UOp).init(g.alloc);
    var users = std.AutoHashMap(*const UOp, usize).init(g.alloc);
    for (all) |u| {
        var d: std.ArrayList(*const UOp) = .empty;
        d.appendSlice(g.alloc, u.src) catch @panic("out of memory");
        if (edges.get(u)) |e| d.append(g.alloc, e) catch @panic("out of memory");
        deps.put(u, d.items) catch @panic("out of memory");
        for (d.items) |s| {
            const gop = users.getOrPut(s) catch @panic("out of memory");
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }
    }
    // the ideal order: sorted by key
    const ideal = g.alloc.dupe(*const UOp, all) catch @panic("out of memory");
    std.mem.sort(*const UOp, ideal, &it, struct {
        fn lt(ctx: *Interp, a: *const UOp, b: *const UOp) bool {
            return keyLess(priority(ctx, a), priority(ctx, b));
        }
    }.lt);
    var order = std.AutoHashMap(*const UOp, usize).init(g.alloc);
    for (ideal, 0..) |u, i| order.put(u, i) catch @panic("out of memory");
    // walk back from the sink: of the ready nodes, place the latest in the ideal order
    var ready: std.ArrayList(*const UOp) = .empty;
    ready.append(g.alloc, sink) catch @panic("out of memory");
    var out: std.ArrayList(*const UOp) = .empty;
    while (ready.items.len > 0) {
        var best: usize = 0;
        for (ready.items, 0..) |u, i| {
            if (⟪order.get(u).? > order.get(ready.items[best]).?|||???⟫) best = i;
        }
        const u = ready.swapRemove(best);
        out.append(g.alloc, u) catch @panic("out of memory");
        for (deps.get(u).?) |s| {
            const left = users.getPtr(s).?;
            left.* -= 1;
            if (⟪left.* == 0|||???⟫) ready.append(g.alloc, s) catch @panic("out of memory");
        }
    }
    std.mem.reverse(*const UOp, out.items);
    return out.items;
}

/// The list as C, one line per UOp. Literals, ranges and addresses are
/// written in place; everything else gets a name.
fn renderLinear(g: *Graph, list: []const *const UOp, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var names = std.AutoHashMap(*const UOp, []const u8).init(g.alloc);
    try w.writeAll(c_helpers);
    try w.writeAll("void kernel(void **b) {\n");
    var depth: usize = 1;
    for (list, 0..) |u, n| {
        const name: []const u8 = switch (u.op) {
            .param, .alloc => blk: {
                const slot = u.arg.param.slot;
                const ty = CRender.ctype(u.arg.param.dtype);
                const nm = std.fmt.allocPrint(g.alloc, "{s}{d}", .{ if (u.op == .param) "p" else "a", slot }) catch @panic("out of memory");
                for (0..depth) |_| try w.writeAll("  ");
                if (u.op == .param) {
                    try w.print("{s} *{s} = ({s} *)b[{d}];\n", .{ ty, nm, ty, slot });
                } else try w.print("{s} {s}[{d}];\n", .{ ty, nm, @max(prod(u.shape), 1) });
                break :blk nm;
            },
            .constant => blk: {
                var buf: std.Io.Writer.Allocating = .init(g.alloc);
                var r: CRender = .{ .g = g, .w = &buf.writer, .accs = .init(g.alloc) };
                try r.expr(u);
                break :blk buf.written();
            },
            .range => blk: {
                for (0..depth) |_| try w.writeAll("  ");
                try w.print("for (int r{d} = 0; r{d} < {d}; r{d}++) {{\n", .{ u.arg.int, u.arg.int, u.src[0].intValue().?, u.arg.int });
                depth += 1;
                break :blk std.fmt.allocPrint(g.alloc, "r{d}", .{u.arg.int}) catch @panic("out of memory");
            },
            .end => blk: {
                for (u.src[1..]) |_| {
                    depth -= 1;
                    for (0..depth) |_| try w.writeAll("  ");
                    try w.writeAll("}\n");
                }
                break :blk "";
            },
            .after => names.get(u.src[0]).?, // the same memory, later
            .stack => "", // only ever a buffer's shape here
            .index => std.fmt.allocPrint(g.alloc, "{s}[{s}]", .{ names.get(u.src[0]).?, names.get(u.src[1]).? }) catch @panic("out of memory"),
            .sink => "",
            .store => blk: {
                const target = names.get(u.src[0]).?;
                const addr = if (u.src[0].op == .index) target else std.fmt.allocPrint(g.alloc, "{s}[0]", .{target}) catch @panic("out of memory");
                for (0..depth) |_| try w.writeAll("  ");
                try w.print("{s} = {s};\n", .{ addr, names.get(u.src[1]).? });
                break :blk "";
            },
            else => blk: {
                // a value: load, ALU op, ...
                const nm = std.fmt.allocPrint(g.alloc, "v{d}", .{n}) catch @panic("out of memory");
                for (0..depth) |_| try w.writeAll("  ");
                try w.print("{s} {s} = ", .{ CRender.ctype(u.dtype), nm });
                switch (u.op) {
                    .load => {
                        const src = names.get(u.src[0]).?;
                        if (u.src[0].op == .index) try w.writeAll(src) else try w.print("{s}[0]", .{src});
                    },
                    .where => try w.print("({s} ? {s} : {s})", .{ names.get(u.src[0]).?, names.get(u.src[1]).?, names.get(u.src[2]).? }),
                    .cast => if (u.dtype == .bool)
                        try w.print("({s} != 0)", .{names.get(u.src[0]).?})
                    else
                        try w.print("(({s}){s})", .{ CRender.ctype(u.dtype), names.get(u.src[0]).? }),
                    .recip => try w.print("(1.0f / {s})", .{names.get(u.src[0]).?}),
                    .max => try w.print("{s}({s}, {s})", .{ if (u.dtype.isFloat()) "fmax2" else "imax2", names.get(u.src[0]).?, names.get(u.src[1]).? }),
                    .div, .mod => try w.print("{s}({s}, {s})", .{ if (u.op == .div) "idiv" else "imod", names.get(u.src[0]).?, names.get(u.src[1]).? }),
                    else => {
                        const sym = switch (u.op) {
                            .add => if (u.dtype == .bool) "|" else "+",
                            .mul => "*",
                            .xor => "^",
                            .shl => "<<",
                            .cmplt => "<",
                            .cmpne => "!=",
                            else => unreachable,
                        };
                        try w.print("({s} {s} {s})", .{ names.get(u.src[0]).?, sym, names.get(u.src[1]).? });
                    },
                }
                try w.writeAll(";\n");
                break :blk nm;
            },
        };
        names.put(u, name) catch @panic("out of memory");
    }
    try w.writeAll("}\n");
}
//@end

const t = std.testing;

/// Implicit loads made explicit: INDEX used as a value gets a LOAD.
fn explicitLoads(g: *Graph, ast: *const UOp) !*const UOp {
    var done = Subst.init(g.alloc);
    for (toposort(g, ast, false)) |u| {
        const src = g.alloc.alloc(*const UOp, u.src.len) catch unreachable;
        for (u.src, src, 0..) |s, *n, i| {
            n.* = done.get(s) orelse s;
            const is_target = (u.op == .store and i == 0) or u.op == .index or u.op == .load;
            if (s.op == .index and !is_target) n.* = try g.load(n.*);
        }
        try done.put(u, try g.new(u.op, src, u.arg));
    }
    return done.get(ast).?;
}

/// A kernel with a loop-invariant load: out[i] = (sum over k of A[i, k]) * x[i]
fn rowSumTimesX(g: *Graph) !struct { body: *const UOp, args: []const *const UOp } {
    const a = g.buffer(0, .f32, 12);
    const x = g.buffer(1, .f32, 3);
    const s = try g.reduce(try g.permute(try g.reshape(a, &.{ 3, 4 }), &.{ 1, 0 }), .add, 1);
    const sched = try schedule(g, &.{try g.mul(s, x)});
    return .{ .body = sched.calls[0].src[0], .args = sched.calls[0].src[1..] };
}

test "linearized: loads hoisted, loops nested, stores late" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const k = try rowSumTimesX(&g);
    var edges = std.AutoHashMap(*const UOp, *const UOp).init(g.alloc);
    const lowered = try explicitLoads(&g, try lowerReduces(&g, k.body, &edges));
    const list = linearize(&g, lowered, &edges);
    // a toposort: every src (and ordering edge) before its user
    for (list, 0..) |u, i| {
        for (u.src) |s| try t.expect(std.mem.indexOfScalar(*const UOp, list[0..i], s) != null);
        if (edges.get(u)) |e| try t.expect(std.mem.indexOfScalar(*const UOp, list[0..i], e) != null);
    }
    // the PARAMs first (after the literals they're made from), in slot order
    var code: std.ArrayList(*const UOp) = .empty;
    for (list) |u| if (u.op != .constant and u.op != .stack) try code.append(g.alloc, u);
    try t.expectEqual(.param, code.items[0].op);
    try t.expectEqual(.param, code.items[1].op);
    try t.expect(code.items[0].arg.param.slot < code.items[1].arg.param.slot);
    // two loops, i then k, nested; and x[i] is loaded inside the i loop but
    // NOT inside the k loop: once per i, not once per (i, k)
    var opened: [2]usize = undefined;
    var n_open: usize = 0;
    var k_end: ?usize = null;
    var x_load: ?usize = null;
    for (list, 0..) |u, i| {
        if (u.op == .range) {
            opened[n_open] = i;
            n_open += 1;
        }
        if (u.op == .end and n_open == 2 and k_end == null) k_end = i;
        if (u.op == .load and u.src[0].op == .index and u.src[0].src[0].arg.param.slot == 2) x_load = i;
    }
    try t.expectEqual(2, n_open);
    try t.expect(x_load.? > opened[0]); //                           inside the i loop
    try t.expect(x_load.? < opened[1] or x_load.? > k_end.?); //     outside the k loop
}

test "the flat list runs, and agrees with 195's tree renderer" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const k = try rowSumTimesX(&g);
    var edges = std.AutoHashMap(*const UOp, *const UOp).init(g.alloc);
    const list = linearize(&g, try explicitLoads(&g, try lowerReduces(&g, k.body, &edges)), &edges);
    var src: std.Io.Writer.Allocating = .init(g.alloc);
    try renderLinear(&g, list, &src.writer);

    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "k.c", .data = src.written() });
    var dir_buf: [4096]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const c_path = try std.fs.path.join(g.alloc, &.{ dir, "k.c" });
    const so_path = try std.fs.path.join(g.alloc, &.{ dir, "k.so" });
    const result = try std.process.run(g.alloc, io, .{ .argv = &.{ "zig", "cc", "-O2", "-shared", "-fPIC", "-nostdlib", c_path, "-o", so_path } });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}\n{s}\n", .{ result.stderr, src.written() });
        return error.CompileFailed;
    }
    var lib = try std.DynLib.open(so_path);
    defer lib.close();
    const kernel = lib.lookup(*const fn ([*]const ?*anyopaque) callconv(.c) void, "kernel") orelse return error.KernelNotFound;
    var out = [_]f32{ 0, 0, 0 };
    var a = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    var x = [_]f32{ 2, -1, 0.5 };
    // the CALL's args: out first, then whichever buffer the body used first
    var ptrs: [3]?*anyopaque = undefined;
    for (k.args, 0..) |arg, j| {
        var buf = arg;
        while (buf.op == .after) buf = buf.src[0];
        ptrs[j] = if (buf.op == .alloc) @ptrCast(&out) else if (buf.arg.param.slot == 0) @ptrCast(&a) else @ptrCast(&x);
    }
    kernel(&ptrs);
    // rows of the (3, 4) A: sums 10, 26, 42
    try t.expectEqualSlices(f32, &.{ 20, -26, 21 }, &out);
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
