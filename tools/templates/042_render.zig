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

//@include tensor_graph

//@include linearize

fn render(k: Kernel, w: *std.Io.Writer) !void {
    try w.writeAll("#include <math.h>\n\nvoid kernel(float* out");
    for (0..k.inputs.len) |i| try w.print(", const float* in{d}", .{i});
    try w.writeAll(", int n) {\n  for (int i = 0; i < n; i++) {\n");
    for (k.insts, 0..) |inst, id| {
        try w.print("    float v{d} = ", .{id});
        switch (inst.op) {
            .buffer => try w.print("in{d}[i]", .{inst.arg}),
            .constant => try w.print("{d}", .{inst.value}),
            .add => ⟪try w.print("v{d} + v{d}", .{ inst.a, inst.b })|||???⟫,
            .mul => ⟪try w.print("v{d} * v{d}", .{ inst.a, inst.b })|||???⟫,
            .max => ⟪try w.print("fmaxf(v{d}, v{d})", .{ inst.a, inst.b })|||???⟫,
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
