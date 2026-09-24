//
// ─── Exercise 074: when strides aren't enough ──────────────────────────
//
// Exercise 010 cheated: it only reshaped CONTIGUOUS views. Try this:
//
//     x: [2, 3]  -> transpose ->  [3, 2], strides [1, 3]  -> reshape [6]
//
// The result must read memory positions 0, 3, 1, 4, 2, 5. No single
// stride does that: the steps are +3, -2, +3, -2... A single view with
// strides can't describe it.
//
// When CAN two neighbouring dimensions k and k+1 merge into one? When
// stepping off the end of dimension k+1 lands exactly one step along
// dimension k:
//
//     strides[k] == strides[k+1] * shape[k+1]
//
// Contiguous [2, 3] (strides [3, 1]): 3 == 1 * 3, so it merges.
// Transposed (strides [1, 3]): 1 != 3 * 2, so it doesn't.
//
// When merging fails, there are two options:
//   1. copy: make it contiguous (009) and reshape that. Costs a kernel.
//   2. STACK views: the new shape reads a *virtual* contiguous copy of
//      the old view, and the old view maps that to memory:
//
//          flat index -> unravel over the old shape -> old view's position
//
//      No copy at all. tinygrad's ShapeTracker was exactly a stack of
//      views like this. And since each view is an index expression (073),
//      the stack is too. Composing them and simplifying (072) often
//      collapses the whole thing back into something neat.
//
// YOUR TASK: finish canMerge() and stackedPosition().
//
const std = @import("std");

const View = struct {
    shape: []const i64,
    strides: []const i64,
    offset: i64 = 0,

    fn position(v: View, idx: []const i64) i64 {
        var pos = v.offset;
        for (idx, v.strides) |i, s| pos += i * s;
        return pos;
    }

    fn numel(v: View) i64 {
        var n: i64 = 1;
        for (v.shape) |d| n *= d;
        return n;
    }
};

fn canMerge(v: View, k: usize) bool {
    return ???;
}

/// Can the whole view become one flat dimension with a single stride?
fn canFlatten(v: View) bool {
    for (0..v.shape.len - 1) |k| {
        if (!canMerge(v, k)) return false;
    }
    return true;
}

/// Memory position of element `flat` of `old`, read as if contiguous.
fn stackedPosition(old: View, flat: i64) i64 {
    var idx: [8]i64 = undefined;
    var rest = flat;
    var k = old.shape.len;
    while (k > 0) {
        k -= 1;
        idx[k] = ???;
        rest = @divFloor(rest, old.shape[k]);
    }
    return ???;
}

fn flatten(v: View, out: []i64) void {
    for (out, 0..) |*o, i| o.* = stackedPosition(v, @intCast(i));
}

test "what merges" {
    try std.testing.expect(canFlatten(.{ .shape = &.{ 2, 3, 4 }, .strides = &.{ 12, 4, 1 } }));
    try std.testing.expect(!canFlatten(.{ .shape = &.{ 3, 2 }, .strides = &.{ 1, 3 } })); // transposed
    try std.testing.expect(!canFlatten(.{ .shape = &.{ 2, 3 }, .strides = &.{ 0, 1 } })); // expanded
    // columns 1..3 of a [2, 3]: rows start 3 apart, but only 2 wide
    try std.testing.expect(!canFlatten(.{ .shape = &.{ 2, 2 }, .strides = &.{ 3, 1 }, .offset = 1 }));
}

test "stacked views read the right memory" {
    var out: [6]i64 = undefined;
    flatten(.{ .shape = &.{ 3, 2 }, .strides = &.{ 1, 3 } }, &out);
    try std.testing.expectEqualSlices(i64, &.{ 0, 3, 1, 4, 2, 5 }, &out);

    flatten(.{ .shape = &.{ 2, 3 }, .strides = &.{ 0, 1 } }, &out);
    try std.testing.expectEqualSlices(i64, &.{ 0, 1, 2, 0, 1, 2 }, &out);

    var four: [4]i64 = undefined;
    flatten(.{ .shape = &.{ 2, 2 }, .strides = &.{ 3, 1 }, .offset = 1 }, &four);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 4, 5 }, &four);
}

test "a mergeable view gives the same answer both ways" {
    const v: View = .{ .shape = &.{ 2, 3, 4 }, .strides = &.{ 12, 4, 1 }, .offset = 5 };
    var out: [24]i64 = undefined;
    flatten(v, &out);
    for (out, 0..) |p, i| try std.testing.expectEqual(5 + @as(i64, @intCast(i)), p);
}
