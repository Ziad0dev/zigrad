//
// ─── Exercise 075: symbolic shapes ─────────────────────────────────────
//
// A language model generating text processes a sequence whose length n
// grows by one every step: 1, 2, 3, ... 2048. Compiling a fresh kernel
// for every length would be painfully slow.
//
// tinygrad's answer: let a shape contain a *Variable*, n in [1, 2048],
// and compile the kernel ONCE, with n as an argument. The index maths
// just carries n around symbolically:
//
//     a [4, n] tensor has strides [n, 1]    position = r * n + j
//     a [4, n, 2] tensor has strides [2n, 2, 1]
//
// At run time, you *bind* n to its current value and launch the same
// compiled kernel. (In tinygrad: Variable("n", 1, 2048).bind(17).)
//
// The kernel cache is keyed by the kernel's code, which says "n", not
// "17", so every length hits the same cache entry.
//
// YOUR TASK: finish symbolicStrides() and the binding in rowSums().
//
const std = @import("std");

//@include index_graph_types

//@include index_bounds

//@include index_rules

/// Contiguous strides for a shape whose sizes are expressions (006).
fn symbolicStrides(g: *Graph, shape: []const *const Node, out: []*const Node) void {
    var step = g.c(1);
    var i = shape.len;
    while (i > 0) {
        i -= 1;
        out[i] = ⟪step|||???⟫;
        step = ⟪simplify(g, g.mul(step, shape[i]))|||???⟫;
    }
}

/// A "compiled kernel": the index expression, plus a cache of compiles.
const Kernels = struct {
    compiles: usize = 0,
    cached: ?*const Node = null,

    fn get(k: *Kernels, e: *const Node) *const Node {
        if (k.cached != e) { // dedup makes "same code" a pointer compare
            k.compiles += 1;
            k.cached = e;
        }
        return e;
    }
};

/// The kernel's loop variables. They belong to the kernel, so they're made
/// once: fresh variables would be different nodes, and a different kernel.
const Loops = struct { r: *const Node, j: *const Node };

/// Sum each row of a [4, n] contiguous tensor, for the current n.
fn rowSums(g: *Graph, kernels: *Kernels, loops: Loops, n_var: *const Node, n: i64, data: []const f32, out: *[4]f32) void {
    const r = loops.r;
    const j = loops.j;
    var strides: [2]*const Node = undefined;
    symbolicStrides(g, &.{ g.c(4), n_var }, &strides);
    const pos = kernels.get(simplify(g, g.add(g.mul(r, strides[0]), g.mul(j, strides[1]))));

    for (out, 0..) |*o, row| {
        o.* = 0;
        var col: i64 = 0;
        while (col < n) : (col += 1) {
            const env: Env = .{ .vars = &.{ r, j, n_var }, .values = &.{ @intCast(row), col, ⟪n|||???⟫ } };
            o.* += data[@intCast(eval(pos, env))];
        }
    }
}

test "symbolic strides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const n = g.variable("n", 1, 16);
    var strides: [3]*const Node = undefined;
    symbolicStrides(&g, &.{ g.c(4), n, g.c(2) }, &strides);
    try expectRender("(2 * n)", strides[0]);
    try expectRender("2", strides[1]);
    try expectRender("1", strides[2]);
}

test "one kernel for every length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const n_var = g.variable("n", 1, 16);
    var kernels: Kernels = .{};
    const loops: Loops = .{ .r = g.variable("r", 0, 3), .j = g.variable("j", 0, 15) }; // j < n <= 16

    var data: [64]f32 = undefined;
    for (&data, 0..) |*d, i| d.* = @floatFromInt(i);
    for ([_]i64{ 3, 5, 7 }) |n| {
        var sums: [4]f32 = undefined;
        rowSums(&g, &kernels, loops, n_var, n, &data, &sums);
        const nf: f32 = @floatFromInt(n);
        for (sums, 0..) |s, row| {
            // row r holds r*n, r*n + 1, ..., r*n + n - 1
            const first = @as(f32, @floatFromInt(row)) * nf;
            try std.testing.expectEqual(nf * first + nf * (nf - 1) / 2, s);
        }
    }
    try std.testing.expectEqual(1, kernels.compiles);
}
