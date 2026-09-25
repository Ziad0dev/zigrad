//
// ─── Exercise 041: linearize ───────────────────────────────────────────
//
// A kernel's graph (all its fused ops) has to become a flat list of
// instructions that a chip can run one after another. tinygrad calls
// this step *linearizing*. Each instruction computes one value, which
// later instructions refer to by number:
//
//     out = relu(a * b + c)
//
//     v0 = load in0          (a)
//     v1 = load in1          (b)
//     v2 = v0 * v1
//     v3 = load in2          (c)
//     v4 = v2 + v3
//     v5 = 0
//     v6 = max(v4, v5)       <- the last instruction is the result
//
// Every value is assigned exactly once (a form compilers call SSA), and
// every instruction comes after the ones it uses. That's just a
// topological order (exercise 023) of the graph! A map from node to
// instruction number makes sure a node used twice is emitted only once.
//
// YOUR TASK: finish Linearizer.emit().
//
const std = @import("std");

//@include tensor_graph

const Inst = struct {
    op: Op,
    a: usize = 0, //     operands: numbers of earlier instructions
    b: usize = 0,
    arg: usize = 0, //   .buffer: which input to load from
    value: f32 = 0, //   .constant
};

const Linearizer = struct {
    alloc: std.mem.Allocator,
    insts: std.ArrayList(Inst) = .empty,
    ids: std.AutoHashMap(*const Node, usize), // node -> its instruction number
    inputs: std.ArrayList(*const Node) = .empty, // the kernel's input buffers

    /// Emit n (after its sources), and return its instruction number.
    fn emit(l: *Linearizer, n: *const Node) error{OutOfMemory}!usize {
        if (l.ids.get(n)) |id| return id; // already emitted: reuse it

        var inst: Inst = .{ .op = n.op };
        switch (n.op) {
            .buffer => {
                inst.arg = l.inputs.items.len;
                try l.inputs.append(l.alloc, n);
            },
            .constant => inst.value = n.value,
            .add, .mul, .max => {
                inst.a = ⟪try l.emit(n.src[0])|||???⟫;
                inst.b = ⟪try l.emit(n.src[1])|||???⟫;
            },
            .sum => unreachable, // a sum ends a kernel, it's never inside one
        }

        const id = l.insts.items.len;
        try l.insts.append(l.alloc, inst);
        ⟪try l.ids.put(n, id);|||???;⟫
        return id;
    }
};

/// Print instructions like "v2 = v0 * v1", one per line.
fn dump(insts: []const Inst, w: *std.Io.Writer) !void {
    for (insts, 0..) |inst, id| {
        try w.print("v{d} = ", .{id});
        switch (inst.op) {
            .buffer => try w.print("load in{d}", .{inst.arg}),
            .constant => try w.print("{d}", .{inst.value}),
            .add => try w.print("v{d} + v{d}", .{ inst.a, inst.b }),
            .mul => try w.print("v{d} * v{d}", .{ inst.a, inst.b }),
            .max => try w.print("max(v{d}, v{d})", .{ inst.a, inst.b }),
            .sum => unreachable,
        }
        try w.writeAll("\n");
    }
}

fn expectLinear(expected: []const u8, root: *const Node) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var l: Linearizer = .{ .alloc = arena.allocator(), .ids = .init(arena.allocator()) };
    _ = try l.emit(root);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try dump(l.insts.items, &w);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "relu(a * b + c)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g: Graph = .{ .alloc = arena.allocator() };
    const a = g.buffer("a", 8);
    const b = g.buffer("b", 8);
    const c = g.buffer("c", 8);

    try expectLinear(
        \\v0 = load in0
        \\v1 = load in1
        \\v2 = v0 * v1
        \\v3 = load in2
        \\v4 = v2 + v3
        \\v5 = 0
        \\v6 = max(v4, v5)
        \\
    , g.relu(g.add(g.mul(a, b), c)));
}

test "shared values are emitted once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g: Graph = .{ .alloc = arena.allocator() };
    const a = g.buffer("a", 8);
    const b = g.buffer("b", 8);
    const s = g.add(a, b);

    try expectLinear(
        \\v0 = load in0
        \\v1 = load in1
        \\v2 = v0 + v1
        \\v3 = v2 * v2
        \\
    , g.mul(s, s));
}
