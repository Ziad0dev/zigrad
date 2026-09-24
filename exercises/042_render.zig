//
// ─── Exercise 042: render ──────────────────────────────────────────────
//
// Instructions in hand, tinygrad *renders* them into source code for the
// target chip: C for the CPU, CUDA for NVIDIA, Metal for Apple, OpenCL...
// (the classes are literally called renderers). Then it hands that text
// to the chip's compiler, and runs the result.
//
// Each instruction becomes one line. The whole kernel loops over i:
//
//     #include <math.h>
//
//     void kernel(float* out, const float* in0, const float* in1, int n) {
//       for (int i = 0; i < n; i++) {
//         float v0 = in0[i];
//         float v1 = in1[i];
//         float v2 = v0 * v1;
//         out[i] = v2;
//       }
//     }
//
// On a GPU the loop disappears: n threads each run the body with their
// own i. That's the only real difference.
//
// Fun fact: that's valid C, and Zig ships a C compiler. Save the output
// to kernel.c, and `zig cc -O2 -shared kernel.c -o kernel.so` builds it.
// tinygrad's CPU backend does exactly that, with clang.
//
// YOUR TASK: render the add, mul and max instructions.
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

/// One instruction. Operands `a` and `b` are the numbers of earlier
/// instructions, whose results live in "registers" v0, v1, v2...
const Inst = struct {
    op: Op,
    a: usize = 0,
    b: usize = 0,
    arg: usize = 0, //   .buffer: which input buffer to load from
    value: f32 = 0, //   .constant
};

const Kernel = struct {
    insts: []const Inst,
    inputs: []const *const Node, // input buffers, in0, in1, ...
    reduce: bool, //                a sum kernel? (exercise 043)
};

/// Exercise 041: the kernel's graph as a flat list of instructions.
const Linearizer = struct {
    alloc: std.mem.Allocator,
    insts: std.ArrayList(Inst) = .empty,
    ids: std.AutoHashMap(*const Node, usize),
    inputs: std.ArrayList(*const Node) = .empty,

    fn emit(l: *Linearizer, n: *const Node) error{OutOfMemory}!usize {
        if (l.ids.get(n)) |id| return id;
        var inst: Inst = .{ .op = n.op };
        switch (n.op) {
            .buffer => {
                inst.arg = l.inputs.items.len;
                try l.inputs.append(l.alloc, n);
            },
            .constant => inst.value = n.value,
            .add, .mul, .max => {
                inst.a = try l.emit(n.src[0]);
                inst.b = try l.emit(n.src[1]);
            },
            .sum => unreachable, // a sum ends a kernel, it's never inside one
        }
        const id = l.insts.items.len;
        try l.insts.append(l.alloc, inst);
        try l.ids.put(n, id);
        return id;
    }
};

fn linearize(alloc: std.mem.Allocator, root: *const Node) !Kernel {
    var l: Linearizer = .{ .alloc = alloc, .ids = .init(alloc) };
    const reduce = root.op == .sum;
    _ = try l.emit(if (reduce) root.src[0] else root);
    return .{ .insts = l.insts.items, .inputs = l.inputs.items, .reduce = reduce };
}

fn render(k: Kernel, w: *std.Io.Writer) !void {
    try w.writeAll("#include <math.h>\n\nvoid kernel(float* out");
    for (0..k.inputs.len) |i| try w.print(", const float* in{d}", .{i});
    try w.writeAll(", int n) {\n  for (int i = 0; i < n; i++) {\n");
    for (k.insts, 0..) |inst, id| {
        try w.print("    float v{d} = ", .{id});
        switch (inst.op) {
            .buffer => try w.print("in{d}[i]", .{inst.arg}),
            .constant => try w.print("{d}", .{inst.value}),
            .add => ???,
            .mul => ???,
            .max => ???,
            .sum => unreachable,
        }
        try w.writeAll(";\n");
    }
    try w.print("    out[i] = v{d};\n  }}\n}}\n", .{k.insts.len - 1});
}

test "render relu(a * b + c)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const g: Graph = .{ .alloc = arena.allocator() };
    const out = g.relu(g.add(g.mul(g.buffer("a", 8), g.buffer("b", 8)), g.buffer("c", 8)));

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(try linearize(arena.allocator(), out), &w);
    try std.testing.expectEqualStrings(
        \\#include <math.h>
        \\
        \\void kernel(float* out, const float* in0, const float* in1, const float* in2, int n) {
        \\  for (int i = 0; i < n; i++) {
        \\    float v0 = in0[i];
        \\    float v1 = in1[i];
        \\    float v2 = v0 * v1;
        \\    float v3 = in2[i];
        \\    float v4 = v2 + v3;
        \\    float v5 = 0;
        \\    float v6 = fmaxf(v4, v5);
        \\    out[i] = v6;
        \\  }
        \\}
        \\
    , w.buffered());
}
