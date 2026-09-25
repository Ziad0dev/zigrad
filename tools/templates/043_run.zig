//
// ─── Exercise 043: run it ──────────────────────────────────────────────
//
// Last step: a *device* that runs kernels. Instead of compiling C, we'll
// interpret the instructions directly, one i at a time, like a GPU runs
// one thread per i. tinygrad has a device just like this: its PYTHON
// backend, an emulator used for testing, which interprets instructions
// in plain Python.
//
// Reduce kernels need one more idea. A sum kernel doesn't store a value
// per i. It keeps a running total, an *accumulator*, and writes it once
// at the end. (tinygrad's instruction list has a special op to declare one.)
//
//     acc = 0
//     for i:  run the instructions;  acc += (the last value)
//     out[0] = acc
//
// And then the whole tinygrad pipeline fits in one function:
//
//     lazy graph -> schedule -> linearize -> run each kernel
//       (ch. 4)      (040)       (041)       (this exercise)
//
// YOUR TASK: finish the device, then realize() ties everything together.
//
const std = @import("std");

//@include tensor_graph

//@include linearize

/// Run kernel k. `inputs[j]` is the memory for input buffer j.
fn run(k: Kernel, inputs: []const []const f32, out: []f32, regs: []f32, n: usize) void {
    var acc: f32 = 0;
    for (0..n) |i| {
        for (k.insts, 0..) |inst, id| {
            regs[id] = switch (inst.op) {
                .buffer => inputs[inst.arg][i],
                .constant => inst.value,
                .add => ⟪regs[inst.a] + regs[inst.b]|||???⟫,
                .mul => ⟪regs[inst.a] * regs[inst.b]|||???⟫,
                .max => ⟪@max(regs[inst.a], regs[inst.b])|||???⟫,
                .sum => unreachable,
            };
        }
        const result = regs[k.insts.len - 1];
        if (k.reduce) {
            ⟪acc += result;|||???;⟫
        } else {
            out[i] = result;
        }
    }
    if (k.reduce) out[0] = acc;
}

/// Compute `root`: schedule it, then linearize and run every kernel in
/// order. `memory` maps each buffer node to its numbers; kernel outputs
/// are added to it as they're computed.
fn realize(alloc: std.mem.Allocator, root: *const Node, memory: *std.AutoHashMap(*const Node, []f32)) ![]f32 {
    for (try schedule(alloc, root)) |node| {
        // The subgraph for this kernel stops at already-computed buffers.
        const kernel_root = try cutAtComputed(alloc, node, memory);
        const k = try linearize(alloc, kernel_root);

        var inputs = try alloc.alloc([]const f32, k.inputs.len);
        for (k.inputs, 0..) |buf, j| inputs[j] = memory.get(buf).?;

        const out = try alloc.alloc(f32, node.len);
        const regs = try alloc.alloc(f32, k.insts.len);
        const n = if (k.reduce) node.src[0].len else node.len;
        run(k, inputs, out, regs, n);
        try memory.put(node, out);
    }
    return memory.get(root).?;
}

// ─── From exercise 040 ───

fn schedule(alloc: std.mem.Allocator, root: *const Node) ![]const *const Node {
    var visited = std.AutoHashMap(*const Node, void).init(alloc);
    var order: std.ArrayList(*const Node) = .empty;
    try toposort(alloc, root, &visited, &order);
    var kernels: std.ArrayList(*const Node) = .empty;
    for (order.items) |n| {
        if (n == root or n.op == .sum) try kernels.append(alloc, n);
    }
    return kernels.items;
}

fn toposort(alloc: std.mem.Allocator, n: *const Node, visited: *std.AutoHashMap(*const Node, void), order: *std.ArrayList(*const Node)) error{OutOfMemory}!void {
    if (visited.contains(n)) return;
    try visited.put(n, {});
    for (n.src) |s| try toposort(alloc, s, visited, order);
    try order.append(alloc, n);
}

/// A copy of n's graph where anything already in `memory` (like an
/// earlier kernel's sum) is replaced by a plain buffer node.
fn cutAtComputed(alloc: std.mem.Allocator, n: *const Node, memory: *std.AutoHashMap(*const Node, []f32)) error{OutOfMemory}!*const Node {
    if (n.op == .buffer or n.op == .constant) return n;
    const src = try alloc.alloc(*const Node, n.src.len);
    for (n.src, src) |s, *out| {
        if (s.op != .buffer and memory.contains(s)) {
            const b = try alloc.create(Node);
            b.* = .{ .op = .buffer, .len = s.len };
            try memory.put(b, memory.get(s).?);
            out.* = b;
        } else {
            out.* = try cutAtComputed(alloc, s, memory);
        }
    }
    const copy = try alloc.create(Node);
    copy.* = n.*;
    copy.src = src;
    return copy;
}

test "an elementwise kernel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const g: Graph = .{ .alloc = alloc };

    var a = [_]f32{ 1, -2, 3, 0.5 };
    var b = [_]f32{ 2, 2, -1, 4 };
    const an = g.buffer("a", 4);
    const bn = g.buffer("b", 4);
    var memory = std.AutoHashMap(*const Node, []f32).init(alloc);
    try memory.put(an, &a);
    try memory.put(bn, &b);

    // relu(a * b + a)
    const out = try realize(alloc, g.relu(g.add(g.mul(an, bn), an)), &memory);
    try std.testing.expectEqualSlices(f32, &.{ 3, 0, 0, 2.5 }, out);
}

test "a dot product: one reduce kernel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const g: Graph = .{ .alloc = alloc };

    var a = [_]f32{ 1, 2, 3 };
    var b = [_]f32{ 4, 5, 6 };
    const an = g.buffer("a", 3);
    const bn = g.buffer("b", 3);
    var memory = std.AutoHashMap(*const Node, []f32).init(alloc);
    try memory.put(an, &a);
    try memory.put(bn, &b);

    const out = try realize(alloc, g.sum(g.mul(an, bn)), &memory);
    try std.testing.expectEqualSlices(f32, &.{32}, out);
}

test "the whole pipeline: two kernels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const g: Graph = .{ .alloc = alloc };

    var a = [_]f32{ 1, 2, 3, 4 };
    var c = [_]f32{10};
    const an = g.buffer("a", 4);
    const cn = g.buffer("c", 1);
    var memory = std.AutoHashMap(*const Node, []f32).init(alloc);
    try memory.put(an, &a);
    try memory.put(cn, &c);

    // sum(a * a) * c = (1 + 4 + 9 + 16) * 10
    const out = try realize(alloc, g.mul(g.sum(g.mul(an, an)), cn), &memory);
    try std.testing.expectEqualSlices(f32, &.{300}, out);
}
