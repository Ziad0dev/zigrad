//
// ─── Exercise 076: generating reduce kernels ───────────────────────────
//
// Chapter 15: code generation for real. In chapter 8 every kernel was one
// flat loop. Real kernels are *loop nests*, built from two kinds of axes:
//
//   * global axes, one per output dimension (tinygrad names their loop
//     variables gidx0, gidx1, ...; on a GPU they become thread indexes)
//   * reduce axes, the dimensions being summed (ridx0, ridx1, ...), which
//     become loops INSIDE each output element, with an accumulator
//
// Row sums of a [4, 3] tensor: one global axis (4 rows) and one reduce
// axis (3 columns):
//
//     void kernel(float* out, const float* in) {
//       for (int gidx0 = 0; gidx0 < 4; gidx0++) {
//         float acc = 0.0f;
//         for (int ridx0 = 0; ridx0 < 3; ridx0++) {
//           acc += in[gidx0*3 + ridx0];
//         }
//         out[gidx0] = acc;
//       }
//     }
//
// Each loop variable reads the input with its own stride (a view, 009).
// Summing the COLUMNS instead just swaps the roles: gidx0 walks the 3
// columns (stride 1) and ridx0 the 4 rows (stride 3).
//
// Index terms: stride 1 prints as just the variable, stride 0 (a
// broadcast) is dropped entirely, anything else prints as var*stride.
//
// YOUR TASK: open the reduce loops, write the accumulate line, and close
// the reduce loops.
//
const std = @import("std");

const Dim = struct { size: usize, stride: usize }; // stride into `in`

fn indent(w: *std.Io.Writer, depth: usize) !void {
    for (0..depth) |_| try w.writeAll("  ");
}

/// in[...] index: sum of var*stride over every loop variable.
fn renderIndex(w: *std.Io.Writer, global: []const Dim, reduce: []const Dim) !void {
    var first = true;
    for ([_][]const Dim{ global, reduce }, [_][]const u8{ "gidx", "ridx" }) |dims, prefix| {
        for (dims, 0..) |d, i| {
            if (d.stride == 0) continue;
            if (!first) try w.writeAll(" + ");
            first = false;
            try w.print("{s}{d}", .{ prefix, i });
            if (d.stride != 1) try w.print("*{d}", .{d.stride});
        }
    }
    if (first) try w.writeAll("0");
}

/// out[...] index: contiguous over the global axes.
fn renderOutIndex(w: *std.Io.Writer, global: []const Dim) !void {
    var stride: usize = 1;
    for (global) |d| stride *= d.size;
    for (global, 0..) |d, i| {
        stride /= d.size;
        if (i > 0) try w.writeAll(" + ");
        try w.print("gidx{d}", .{i});
        if (stride != 1) try w.print("*{d}", .{stride});
    }
    if (global.len == 0) try w.writeAll("0");
}

fn renderReduce(w: *std.Io.Writer, global: []const Dim, reduce: []const Dim) !void {
    try w.writeAll("void kernel(float* out, const float* in) {\n");
    var depth: usize = 1;
    for (global, 0..) |d, i| {
        try indent(w, depth);
        try w.print("for (int gidx{d} = 0; gidx{d} < {d}; gidx{d}++) {{\n", .{ i, i, d.size, i });
        depth += 1;
    }
    try indent(w, depth);
    try w.writeAll("float acc = 0.0f;\n");
    for (reduce, 0..) |d, i| {
        // Like the global loops above, with ridx.
        ???
    }
    try indent(w, depth);
    ???
    try renderIndex(w, global, reduce);
    try w.writeAll("];\n");
    for (reduce) |_| {
        ???
        try indent(w, depth);
        try w.writeAll("}\n");
    }
    try indent(w, depth);
    try w.writeAll("out[");
    try renderOutIndex(w, global);
    try w.writeAll("] = acc;\n");
    for (global) |_| {
        depth -= 1;
        try indent(w, depth);
        try w.writeAll("}\n");
    }
    try w.writeAll("}\n");
}

fn expectKernel(expected: []const u8, global: []const Dim, reduce: []const Dim) !void {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderReduce(&w, global, reduce);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "row sums of [4, 3]" {
    try expectKernel(
        \\void kernel(float* out, const float* in) {
        \\  for (int gidx0 = 0; gidx0 < 4; gidx0++) {
        \\    float acc = 0.0f;
        \\    for (int ridx0 = 0; ridx0 < 3; ridx0++) {
        \\      acc += in[gidx0*3 + ridx0];
        \\    }
        \\    out[gidx0] = acc;
        \\  }
        \\}
        \\
    , &.{.{ .size = 4, .stride = 3 }}, &.{.{ .size = 3, .stride = 1 }});
}

test "column sums: same code, swapped strides" {
    try expectKernel(
        \\void kernel(float* out, const float* in) {
        \\  for (int gidx0 = 0; gidx0 < 3; gidx0++) {
        \\    float acc = 0.0f;
        \\    for (int ridx0 = 0; ridx0 < 4; ridx0++) {
        \\      acc += in[gidx0 + ridx0*3];
        \\    }
        \\    out[gidx0] = acc;
        \\  }
        \\}
        \\
    , &.{.{ .size = 3, .stride = 1 }}, &.{.{ .size = 4, .stride = 3 }});
}

test "sum over the last two axes of [2, 3, 4]" {
    try expectKernel(
        \\void kernel(float* out, const float* in) {
        \\  for (int gidx0 = 0; gidx0 < 2; gidx0++) {
        \\    float acc = 0.0f;
        \\    for (int ridx0 = 0; ridx0 < 3; ridx0++) {
        \\      for (int ridx1 = 0; ridx1 < 4; ridx1++) {
        \\        acc += in[gidx0*12 + ridx0*4 + ridx1];
        \\      }
        \\    }
        \\    out[gidx0] = acc;
        \\  }
        \\}
        \\
    , &.{.{ .size = 2, .stride = 12 }}, &.{ .{ .size = 3, .stride = 4 }, .{ .size = 4, .stride = 1 } });
}
