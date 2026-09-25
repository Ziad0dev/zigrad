//
// ─── Exercise 040: the scheduler ───────────────────────────────────────
//
// Chapter 8: the compiler. How does tinygrad turn a lazy graph into work
// on a GPU? Step one is the *scheduler*: cutting the graph into kernels.
//
// A kernel is one loop over its output elements (exercise 003). It reads
// some buffers from memory and writes one buffer back. And memory is
// SLOW: a GPU can do dozens of multiplies in the time it takes to fetch a
// single number. So the goal is as few kernels, and as little memory
// traffic, as possible.
//
// The rule (a simplified version of tinygrad's):
//   * elementwise ops FUSE into whatever uses them: their values are
//     computed inside the consumer's loop and never stored
//   * a reduce (sum) needs ALL of its input before it's done, so it ends
//     a kernel: its result is written to memory, and its users read it
//   * the final output is always written to memory
//
//     out = sum(a * b) + c           (c has 1 element)
//
//     kernel 1:  t   = sum over i of a[i] * b[i]    reads a, b   writes t
//     kernel 2:  out = t + c                        reads t, c   writes out
//
// Without fusion, every op is its own kernel, and a * b gets written to
// memory in full, only to be read straight back by the sum.
//
// (Real tinygrad is smarter than this rule: ops that only use a reduce's
// final result can join the reduce's kernel, so this example is ONE
// kernel there. But softmax, whose every element needs the max and then
// the sum, still takes three kernels. The simple rule is where it starts.)
//
// YOUR TASK: finish isKernel() and collectInputs(). The tests count
// kernels and bytes moved, fused vs. unfused.
//
const std = @import("std");

const Op = enum { buffer, constant, add, mul, max, sum };

/// A lazy tensor op: `len` elements, computed from `src`.
const Node = struct {
    op: Op,
    src: []const *const Node = &.{},
    len: usize,
    value: f32 = 0, //         for .constant
    name: []const u8 = "", //  for .buffer
};

const Graph = struct {
    alloc: std.mem.Allocator,

    fn buffer(g: Graph, name: []const u8, len: usize) *const Node {
        return g.new(.{ .op = .buffer, .len = len, .name = name });
    }
    fn constant(g: Graph, value: f32, len: usize) *const Node {
        return g.new(.{ .op = .constant, .len = len, .value = value });
    }
    fn add(g: Graph, a: *const Node, b: *const Node) *const Node {
        return g.binary(.add, a, b);
    }
    fn mul(g: Graph, a: *const Node, b: *const Node) *const Node {
        return g.binary(.mul, a, b);
    }
    fn max(g: Graph, a: *const Node, b: *const Node) *const Node {
        return g.binary(.max, a, b);
    }
    fn relu(g: Graph, a: *const Node) *const Node {
        return g.max(a, g.constant(0, a.len));
    }
    fn sum(g: Graph, a: *const Node) *const Node {
        return g.new(.{ .op = .sum, .src = g.dupe(&.{a}), .len = 1 });
    }
    fn binary(g: Graph, op: Op, a: *const Node, b: *const Node) *const Node {
        std.debug.assert(a.len == b.len);
        return g.new(.{ .op = op, .src = g.dupe(&.{ a, b }), .len = a.len });
    }
    fn dupe(g: Graph, src: []const *const Node) []const *const Node {
        return g.alloc.dupe(*const Node, src) catch @panic("out of memory");
    }
    fn new(g: Graph, n: Node) *const Node {
        const p = g.alloc.create(Node) catch @panic("out of memory");
        p.* = n;
        return p;
    }
};

/// Does node n get a kernel of its own (and a buffer in memory)?
fn isKernel(n: *const Node, root: *const Node) bool {
    return ???;
}

/// The buffers a kernel reads. Walk down from the kernel's node through
/// fused ops, stopping at buffers and at other kernels' outputs.
fn collectInputs(alloc: std.mem.Allocator, n: *const Node, root: *const Node, inputs: *std.ArrayList(*const Node)) error{OutOfMemory}!void {
    for (n.src) |s| {
        if (s.op == .constant) continue; // written into the code, not read from memory
        if (???) {
            // Read from memory, once, however often it's used.
            if (std.mem.indexOfScalar(*const Node, inputs.items, s) == null) {
                try inputs.append(alloc, s);
            }
        } else {
            // Fused: computed right here, so look at ITS sources.
            try collectInputs(alloc, s, root, inputs);
        }
    }
}

/// Every kernel, in an order where each runs after the ones it reads.
fn schedule(alloc: std.mem.Allocator, root: *const Node) ![]const *const Node {
    var visited = std.AutoHashMap(*const Node, void).init(alloc);
    var order: std.ArrayList(*const Node) = .empty;
    try toposort(alloc, root, &visited, &order);

    var kernels: std.ArrayList(*const Node) = .empty;
    for (order.items) |n| {
        if (isKernel(n, root)) try kernels.append(alloc, n);
    }
    return kernels.items;
}

fn toposort(alloc: std.mem.Allocator, n: *const Node, visited: *std.AutoHashMap(*const Node, void), order: *std.ArrayList(*const Node)) error{OutOfMemory}!void {
    if (visited.contains(n)) return;
    try visited.put(n, {});
    for (n.src) |s| try toposort(alloc, s, visited, order);
    try order.append(alloc, n);
}

/// Bytes moved with fusion: each kernel reads its inputs and writes its
/// output. (4 bytes per f32.)
fn fusedBytes(alloc: std.mem.Allocator, root: *const Node) !usize {
    var total: usize = 0;
    for (try schedule(alloc, root)) |k| {
        var inputs: std.ArrayList(*const Node) = .empty;
        try collectInputs(alloc, k, root, &inputs);
        total += k.len;
        for (inputs.items) |i| total += i.len;
    }
    return total * 4;
}

/// Bytes moved without fusion: every op reads its sources and writes its
/// result.
fn unfusedBytes(alloc: std.mem.Allocator, root: *const Node) !usize {
    var visited = std.AutoHashMap(*const Node, void).init(alloc);
    var order: std.ArrayList(*const Node) = .empty;
    try toposort(alloc, root, &visited, &order);
    var total: usize = 0;
    for (order.items) |n| {
        if (n.op == .buffer or n.op == .constant) continue;
        total += n.len;
        for (n.src) |s| {
            if (s.op != .constant) total += s.len;
        }
    }
    return total * 4;
}

test "a chain of elementwise ops is one kernel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const g: Graph = .{ .alloc = alloc };

    const n = 1000;
    const a = g.buffer("a", n);
    const b = g.buffer("b", n);
    const c = g.buffer("c", n);
    const out = g.relu(g.add(g.mul(a, b), c));

    try std.testing.expectEqual(1, (try schedule(alloc, out)).len);
    try std.testing.expectEqual(4 * 4 * n, try fusedBytes(alloc, out)); //    read a, b, c; write out
    // unfused: mul and add each read 2 and write 1, relu reads 1 and writes 1
    try std.testing.expectEqual(4 * 8 * n, try unfusedBytes(alloc, out));
}

test "a reduce ends a kernel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const g: Graph = .{ .alloc = alloc };

    const n = 1000;
    const t = g.sum(g.mul(g.buffer("a", n), g.buffer("b", n)));
    const out = g.add(t, g.buffer("c", 1));

    const kernels = try schedule(alloc, out);
    try std.testing.expectEqual(2, kernels.len);
    try std.testing.expectEqual(t, kernels[0]); // the sum runs first
    try std.testing.expectEqual(out, kernels[1]);

    // kernel 1: read a and b (2n), write t (1). kernel 2: read t, c, write out (3).
    try std.testing.expectEqual(4 * (2 * n + 1 + 3), try fusedBytes(alloc, out));
    // unfused: mul (3n), sum (n + 1), add (3)
    try std.testing.expectEqual(4 * (3 * n + n + 1 + 3), try unfusedBytes(alloc, out));
}

test "a value used twice is still read once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const g: Graph = .{ .alloc = alloc };

    const a = g.buffer("a", 10);
    const out = g.mul(g.add(a, a), a);
    try std.testing.expectEqual(4 * (10 + 10), try fusedBytes(alloc, out));
}
