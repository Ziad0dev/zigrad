//
// ─── Exercise 156: UPat, tinygrad's pattern language ───────────────────
//
// Chapter 30: tinygrad's internals. Exercise 025 wrote each rewrite rule
// as a hand-written function. tinygrad writes them as DATA: a pattern
// (UPat) and a replacement function, in a PatternMatcher:
//
//     (UPat.var("x") * 1, lambda x: x)
//     (UPat.var("x") + UPat.var("x"), lambda x: x * 2)
//
// A UPat is a small tree that matches a UOp tree. Each pattern node can
// require an op, require a constant's value, and capture the matched node
// under a NAME. Using the same name twice means "the same node both
// times": x + x matches a + a, but not a + b.
//
// Matching is recursive: check this node's constraints, match each source
// pattern against each source node, record the capture. (Real UPats also
// match either order of commutative ops, match dtypes, and so on.)
//
// YOUR TASK: finish match(), and the consistency check in capture().
//
const std = @import("std");

const Op = enum { constant, variable, add, mul };

const Node = struct {
    op: Op,
    src: []const *const Node = &.{},
    value: f64 = 0,
    name: []const u8 = "",
};

const UPat = struct {
    op: ?Op = null, //                 null: any op
    value: ?f64 = null, //             for constants
    name: ?[]const u8 = null, //       capture the matched node
    src: ?[]const UPat = null, //      null: don't care about sources

    fn any(name: []const u8) UPat {
        return .{ .name = name };
    }
    fn cnst(v: f64) UPat {
        return .{ .op = .constant, .value = v };
    }
};

const Captures = struct {
    names: [8][]const u8 = undefined,
    nodes: [8]*const Node = undefined,
    len: usize = 0,

    fn get(c: Captures, name: []const u8) ?*const Node {
        for (c.names[0..c.len], c.nodes[0..c.len]) |n, node| {
            if (std.mem.eql(u8, n, name)) return node;
        }
        return null;
    }

    /// Record name -> node. False if the name already means another node.
    fn capture(c: *Captures, name: []const u8, node: *const Node) bool {
        if (c.get(name)) |existing| return ???;
        c.names[c.len] = name;
        c.nodes[c.len] = node;
        c.len += 1;
        return true;
    }
};

fn match(p: UPat, n: *const Node, caps: *Captures) bool {
    if (p.op) |op| {
        if (???) return false;
    }
    if (p.value) |v| {
        if (n.op != .constant or n.value != v) return false;
    }
    if (p.src) |srcs| {
        if (srcs.len != n.src.len) return false;
        for (srcs, n.src) |sp, sn| {
            if (???) return false;
        }
    }
    if (p.name) |name| return ???;
    return true;
}

// a few nodes to match against
const a: Node = .{ .op = .variable, .name = "a" };
const b: Node = .{ .op = .variable, .name = "b" };
const one: Node = .{ .op = .constant, .value = 1 };
const a_times_one: Node = .{ .op = .mul, .src = &.{ &a, &one } };
const a_plus_a: Node = .{ .op = .add, .src = &.{ &a, &a } };
const a_plus_b: Node = .{ .op = .add, .src = &.{ &a, &b } };

test "x * 1" {
    const pat: UPat = .{ .op = .mul, .src = &.{ .any("x"), .cnst(1) } };
    var caps: Captures = .{};
    try std.testing.expect(match(pat, &a_times_one, &caps));
    try std.testing.expect(caps.get("x").? == &a);
    caps = .{};
    try std.testing.expect(!match(pat, &a_plus_a, &caps));
}

test "x + x needs the same node twice" {
    const pat: UPat = .{ .op = .add, .src = &.{ .any("x"), .any("x") } };
    var caps: Captures = .{};
    try std.testing.expect(match(pat, &a_plus_a, &caps));
    caps = .{};
    try std.testing.expect(!match(pat, &a_plus_b, &caps));
}

test "nested patterns" {
    const nested: Node = .{ .op = .add, .src = &.{ &a_times_one, &b } };
    const pat: UPat = .{ .op = .add, .src = &.{ .{ .op = .mul, .src = &.{ .any("x"), .cnst(1) } }, .any("y") } };
    var caps: Captures = .{};
    try std.testing.expect(match(pat, &nested, &caps));
    try std.testing.expect(caps.get("x").? == &a);
    try std.testing.expect(caps.get("y").? == &b);
}
