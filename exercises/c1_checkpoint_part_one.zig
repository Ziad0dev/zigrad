//
// ─── Checkpoint 1: Part I, from memory ────────────────────────────────
//
// No blanks this time, and nothing new to read. Five functions from five
// different chapters of Part I, each one yours to write whole.
//
// Why: pulling an idea back out of your own head is what makes it stay
// there, much more than reading it again does. And when the topics are
// mixed, you have to work out WHICH idea a problem needs, which is the
// part no fill-in-the-blank can practise.
//
// How to play:
//   1. Try each one cold. Being stuck for a few minutes is the exercise
//      working, not a sign that it isn't.
//   2. Still stuck? The number in each doc comment is the exercise that
//      taught it. Read YOUR finished version, close it, then write the
//      function here without looking.
//   3. Come back in a week and do the ones you had to look up again.
//
// YOUR TASK: write strides(), broadcastShape(), softmax(), visit() and
// backward().
//
const std = @import("std");

/// (006) The row-major strides of `shape`: how far to move in flat memory
/// when the index along each dimension goes up by one.
fn strides(shape: []const usize, out: []usize) void {
    ???;
}

/// (012) The shape two tensors broadcast to, written into `out` (which is
/// long enough) and returned as a slice of it; or null if they can't be
/// broadcast together.
fn broadcastShape(a: []const usize, b: []const usize, out: []usize) ?[]const usize {
    ???;
}

/// (018) Softmax of x into out. It must survive x = { 1000, 1001, 1002 }.
fn softmax(x: []const f32, out: []f32) void {
    ???;
}

/// (023) One step of a topological sort. deps[i] lists the nodes that node
/// i reads. Append to order[0..count.*] every node that `node` needs and
/// that isn't there yet, each one AFTER everything it reads, and `node`
/// itself last. seen[i] says whether node i has been handled.
fn visit(deps: []const []const usize, node: usize, seen: []bool, order: []usize, count: *usize) void {
    ???;
}

const Op = enum { input, add, mul, relu };

/// One node of a tiny computation: an input, or an op on earlier nodes.
/// (relu only uses `a`.)
const Node = struct { op: Op, a: usize = 0, b: usize = 0, value: f64 = 0, grad: f64 = 0 };

/// Compute every node's value. Nodes come in order: inputs before users.
fn forward(nodes: []Node) void {
    for (nodes) |*n| {
        n.value = switch (n.op) {
            .input => n.value,
            .add => nodes[n.a].value + nodes[n.b].value,
            .mul => nodes[n.a].value * nodes[n.b].value,
            .relu => @max(nodes[n.a].value, 0),
        };
    }
}

/// (030, 031) Backpropagation: set every node's grad to the derivative of
/// the LAST node's value with respect to that node. forward() has run.
fn backward(nodes: []Node) void {
    ???;
}

const t = std.testing;

test "strides" {
    var out: [4]usize = undefined;
    strides(&.{ 2, 3, 4 }, out[0..3]);
    try t.expectEqualSlices(usize, &.{ 12, 4, 1 }, out[0..3]);
    strides(&.{ 5, 1, 7, 2 }, &out);
    try t.expectEqualSlices(usize, &.{ 14, 14, 2, 1 }, &out);
    strides(&.{9}, out[0..1]);
    try t.expectEqual(1, out[0]);
}

test "broadcasting" {
    var out: [4]usize = undefined;
    try t.expectEqualSlices(usize, &.{ 3, 4 }, broadcastShape(&.{ 3, 1 }, &.{4}, &out).?);
    try t.expectEqualSlices(usize, &.{ 2, 3, 4 }, broadcastShape(&.{ 3, 4 }, &.{ 2, 1, 4 }, &out).?);
    try t.expectEqualSlices(usize, &.{ 5, 6 }, broadcastShape(&.{ 5, 6 }, &.{}, &out).?);
    try t.expectEqualSlices(usize, &.{ 7, 2 }, broadcastShape(&.{2}, &.{ 7, 1 }, &out).?);
    try t.expectEqualSlices(usize, &.{ 3, 0 }, broadcastShape(&.{ 3, 1 }, &.{0}, &out).?); // 1 stretches, even to 0
    try t.expect(broadcastShape(&.{ 3, 4 }, &.{3}, &out) == null); // aligned from the RIGHT: 4 meets 3
    try t.expect(broadcastShape(&.{ 2, 3 }, &.{ 4, 3 }, &out) == null);
}

test "softmax, also on numbers that overflow exp" {
    var out: [3]f32 = undefined;
    softmax(&.{ 1, 2, 3 }, &out);
    try t.expectApproxEqAbs(0.09003057, out[0], 1e-6);
    try t.expectApproxEqAbs(0.24472847, out[1], 1e-6);
    try t.expectApproxEqAbs(0.66524096, out[2], 1e-6);
    var big: [3]f32 = undefined;
    softmax(&.{ 1000, 1001, 1002 }, &big);
    for (out, big) |a, b| try t.expectApproxEqAbs(a, b, 1e-6);
    softmax(&.{ -1000, -1000, -1000 }, &big);
    for (big) |b| try t.expectApproxEqAbs(1.0 / 3.0, b, 1e-6);
    // far apart: one number takes everything, and nothing turns into nan
    softmax(&.{ 0, 1000, 0 }, &big);
    try t.expectEqualSlices(f32, &.{ 0, 1, 0 }, &big);
    var alone: [1]f32 = undefined;
    softmax(&.{-5}, &alone);
    try t.expectEqual(1, alone[0]);
}

test "toposort: everything a node reads comes before it" {
    // 0 reads 1 and 2; both read 3; 3 reads 5. Nobody reads 4.
    const deps = [_][]const usize{ &.{ 1, 2 }, &.{3}, &.{3}, &.{5}, &.{0}, &.{} };
    var seen = [_]bool{false} ** 6;
    var order: [6]usize = undefined;
    var count: usize = 0;
    visit(&deps, 0, &seen, &order, &count);
    try t.expectEqual(5, count); // not node 4: node 0 doesn't need it
    try t.expectEqual(0, order[count - 1]);
    for (order[0..count], 0..) |n, i| {
        try t.expect(n != 4);
        try t.expect(std.mem.indexOfScalar(usize, order[0..i], n) == null); // once each
        for (deps[n]) |d| try t.expect(std.mem.indexOfScalar(usize, order[0..i], d) != null);
    }
    // a second root adds only what's new
    visit(&deps, 4, &seen, &order, &count);
    try t.expectEqual(6, count);
    try t.expectEqual(4, order[5]);
}

/// relu(x * y + x) * x, as nodes.
fn example(x: f64, y: f64) [6]Node {
    return .{
        .{ .op = .input, .value = x },
        .{ .op = .input, .value = y },
        .{ .op = .mul, .a = 0, .b = 1 },
        .{ .op = .add, .a = 2, .b = 0 },
        .{ .op = .relu, .a = 3 },
        .{ .op = .mul, .a = 4, .b = 0 },
    };
}

test "backprop agrees with the slope" {
    for ([_][2]f64{ .{ 2, 3 }, .{ 0.5, -0.25 }, .{ -1, 4 }, .{ 3, -2 } }) |xy| {
        var nodes = example(xy[0], xy[1]);
        forward(&nodes);
        backward(&nodes);
        const h = 1e-6;
        for (0..2) |i| {
            var up = example(xy[0], xy[1]);
            var down = example(xy[0], xy[1]);
            up[i].value += h;
            down[i].value -= h;
            forward(&up);
            forward(&down);
            const slope = (up[5].value - down[5].value) / (2 * h);
            try t.expectApproxEqAbs(slope, nodes[i].grad, 1e-6);
        }
    }
    // by hand at (2, 3): out = (xy + x) x, d/dx = 2xy + 2x = 16, d/dy = x^2 = 4
    var nodes = example(2, 3);
    forward(&nodes);
    backward(&nodes);
    try t.expectEqual(16, nodes[0].grad);
    try t.expectEqual(4, nodes[1].grad);
    try t.expectEqual(1, nodes[5].grad);
    // running it twice gives the same grads, not double
    backward(&nodes);
    try t.expectEqual(16, nodes[0].grad);
}
