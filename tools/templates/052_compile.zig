//
// ─── Exercise 052: compile it for real ─────────────────────────────────
//
// In 042 we printed C and in 043 we interpreted instructions. Now let's
// do what tinygrad's CPU backend does: render C, run a real C compiler on
// it, load the result, and call it.
//
// Zig makes this surprisingly easy:
//   * `zig cc` IS a C compiler (clang, bundled with Zig)
//   * `std.DynLib` loads a shared library (.so) and finds a function in
//     it by name
//
//     zig cc -O2 -shared -fPIC -nostdlib kernel.c -o kernel.so
//
// -shared builds a library instead of a program, -fPIC lets it be loaded
// at any address, and -nostdlib skips the C standard library (our kernel
// only does arithmetic; tinygrad's CPU backend passes -nostdlib too).
// That's why render() below writes max as `a > b ? a : b` instead of
// fmaxf from math.h.
//
// The loaded function has the C calling convention, so its Zig type is
//     *const fn (...) callconv(.c) void
// and C's `float*` is a Zig many-item pointer, `[*]f32`.
//
// The test writes the kernel into a temporary directory. `zig build` puts
// its own zig first on the PATH, so `zig cc` is found. (Tested on Linux.)
//
// YOUR TASK: fill in the compiler flag, the function type, and the call.
//
const std = @import("std");

//@include tensor_graph

//@include linearize

fn render(k: Kernel, w: *std.Io.Writer) !void {
    try w.writeAll("void kernel(float* out");
    for (0..k.inputs.len) |i| try w.print(", const float* in{d}", .{i});
    try w.writeAll(", int n) {\n  for (int i = 0; i < n; i++) {\n");
    for (k.insts, 0..) |inst, id| {
        try w.print("    float v{d} = ", .{id});
        switch (inst.op) {
            .buffer => try w.print("in{d}[i]", .{inst.arg}),
            .constant => try w.print("{d}", .{inst.value}),
            .add => try w.print("v{d} + v{d}", .{ inst.a, inst.b }),
            .mul => try w.print("v{d} * v{d}", .{ inst.a, inst.b }),
            .max => try w.print("v{d} > v{d} ? v{d} : v{d}", .{ inst.a, inst.b, inst.a, inst.b }),
            .sum => unreachable,
        }
        try w.writeAll(";\n");
    }
    try w.print("    out[i] = v{d};\n  }}\n}}\n", .{k.insts.len - 1});
}

/// A kernel with three inputs, as C sees it.
const Kernel3 = ⟪*const fn ([*]f32, [*]const f32, [*]const f32, [*]const f32, c_int) callconv(.c) void|||???⟫;

test "render, compile, load, run" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const g: Graph = .{ .alloc = arena.allocator() };

    // 1. the kernel for relu(a * b + c), as C source
    const n = 4;
    const out_node = g.relu(g.add(g.mul(g.buffer("a", n), g.buffer("b", n)), g.buffer("c", n)));
    var src: std.Io.Writer.Allocating = .init(alloc);
    defer src.deinit();
    try render(try linearize(arena.allocator(), out_node), &src.writer);

    // 2. write it to a temporary directory and compile it
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "kernel.c", .data = src.written() });
    var dir_buf: [4096]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const c_path = try std.fs.path.join(arena.allocator(), &.{ dir, "kernel.c" });
    const so_path = try std.fs.path.join(arena.allocator(), &.{ dir, "kernel.so" });

    const result = try std.process.run(alloc, io, .{
        .argv = &.{ "zig", "cc", "-O2", ⟪"-shared"|||???⟫, "-fPIC", "-nostdlib", c_path, "-o", so_path },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("zig cc failed:\n{s}\n", .{result.stderr});
        return error.CompileFailed;
    }

    // 3. load it and find the function called "kernel"
    var lib = try std.DynLib.open(so_path);
    defer lib.close();
    const kernel = lib.lookup(Kernel3, "kernel") orelse return error.KernelNotFound;

    // 4. run it on real data
    const a = [_]f32{ 1, -2, 3, 0.5 };
    const b = [_]f32{ 2, 2, -1, 4 };
    const c = [_]f32{ 1, 1, 1, -3 };
    var out: [n]f32 = undefined;
    ⟪kernel(&out, &a, &b, &c, n);|||???;⟫
    try std.testing.expectEqualSlices(f32, &.{ 3, 0, 0, 0 }, &out);
}
