//
// ─── Exercise 073: a view is an index expression ───────────────────────
//
// Chapter 2's views, and 071-072's expressions, are the same thing. A
// kernel loops over a flat g, and a view turns g into a memory position:
//
//     for each dimension k, from the last:
//         i_k = (g // inner) % shape[k]        (unravel, 008)
//         pos += i_k * strides[k]              (position, 007)
//         inner *= shape[k]
//
// Build that as a graph, simplify it (072), and the movement ops turn
// into strikingly simple maths:
//
//     contiguous [2, 3]:            g
//     row 1 (offset 3):             3 + g
//     transposed [3, 2]:            (g % 2) * 3 + g // 2
//     broadcast [3] to [2, 3]:      g % 3             <- expand is modulo!
//
// This is what tinygrad actually generates code from. (Newer tinygrad
// versions go further and build these index graphs directly, instead of
// storing View objects at all.) Masks (014) work the same way, as a
// "valid" condition expression, like 1 <= i && i < 4, next to the index.
//
// YOUR TASK: finish viewIndex().
//
const std = @import("std");

//@include index_graph_types

//@include index_bounds

//@include index_rules

/// The memory position that loop variable `gv` reads, through a view.
fn viewIndex(g: *Graph, gv: *const Node, shape: []const i64, strides: []const i64, offset: i64) *const Node {
    var pos = g.c(offset);
    var inner: i64 = 1;
    var k = shape.len;
    while (k > 0) {
        k -= 1;
        const i_k = ⟪g.mod(g.idiv(gv, g.c(inner)), g.c(shape[k]))|||???⟫;
        pos = ⟪g.add(pos, g.mul(i_k, g.c(strides[k])))|||???⟫;
        inner *= shape[k];
    }
    return simplify(g, pos);
}

fn positions(e: *const Node, gv: *const Node, out: []i64) void {
    for (out, 0..) |*o, i| o.* = eval(e, .{ .vars = &.{gv}, .values = &.{@intCast(i)} });
}

test "contiguous is just g" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const gv = g.variable("g", 0, 5);
    try expectRender("g", viewIndex(&g, gv, &.{ 2, 3 }, &.{ 3, 1 }, 0));
    try expectRender("(3 + g)", viewIndex(&g, g.variable("g", 0, 2), &.{3}, &.{1}, 3));
}

test "transpose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const gv = g.variable("g", 0, 5);
    const e = viewIndex(&g, gv, &.{ 3, 2 }, &.{ 1, 3 }, 0);
    try expectRender("(((g % 2) * 3) + (g // 2))", e);
    var pos: [6]i64 = undefined;
    positions(e, gv, &pos);
    try std.testing.expectEqualSlices(i64, &.{ 0, 3, 1, 4, 2, 5 }, &pos); // exercise 011's order
}

test "expand is modulo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const gv = g.variable("g", 0, 5);
    try expectRender("(g % 3)", viewIndex(&g, gv, &.{ 2, 3 }, &.{ 0, 1 }, 0));
}

test "3D contiguous still reads in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g: Graph = .init(arena.allocator());
    const gv = g.variable("g", 0, 23);
    var pos: [24]i64 = undefined;
    positions(viewIndex(&g, gv, &.{ 2, 3, 4 }, &.{ 12, 4, 1 }, 0), gv, &pos);
    for (pos, 0..) |p, i| try std.testing.expectEqual(@as(i64, @intCast(i)), p);
}
