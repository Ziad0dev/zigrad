// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 159: in-place updates ────────────────────────────────────
//
// An optimizer step, w = w - lr * g, would normally allocate a new buffer
// for the new w. For a 7B-parameter model that's 14+ GB of pointless
// allocation every step. tinygrad's Tensor.assign() lets the kernel write
// the result straight back into w's buffer, in place.
//
// When is that safe? A kernel computes output element i from some input
// elements. Writing into an input buffer is only safe if no element is
// READ after it's been OVERWRITTEN. If element i only ever reads position
// i of the buffer it writes, each element reads its own old value just
// before replacing it: safe, whatever order the threads run in.
//
// But a kernel like y[i] = x[i - 1] + x[i] (a shift) reads a NEIGHBOUR.
// Writing in place, element i - 1 might already hold its new value when
// element i reads it: the result depends on thread timing. The scheduler
// must detect that and write to a fresh buffer (and copy back).
//
// A kernel here is described by its reads: which buffer, at which offset
// from i.
//
// YOUR TASK: write the safety check.
//
const std = @import("std");

const Read = struct { buffer: usize, offset: isize };

/// May the kernel write its output into buffer `target`?
fn inPlaceSafe(reads: []const Read, target: usize) bool {
    for (reads) |r| {
        if (r.buffer == target and r.offset != 0) return false;
    }
    return true;
}

/// Run y[i] = sum of the reads, in place on `data` (buffer 0), in order.
fn runInPlace(reads: []const Read, data: []f64, other: []const f64) void {
    for (0..data.len) |i| {
        var acc: f64 = 0;
        for (reads) |r| {
            const j = @as(isize, @intCast(i)) + r.offset;
            if (j < 0 or j >= data.len) continue;
            acc += if (r.buffer == 0) data[@intCast(j)] else other[@intCast(j)];
        }
        data[i] = acc;
    }
}

fn runFresh(reads: []const Read, data: []f64, other: []const f64, scratch: []f64) void {
    @memcpy(scratch, data);
    for (0..data.len) |i| {
        var acc: f64 = 0;
        for (reads) |r| {
            const j = @as(isize, @intCast(i)) + r.offset;
            if (j < 0 or j >= data.len) continue;
            acc += if (r.buffer == 0) scratch[@intCast(j)] else other[@intCast(j)];
        }
        data[i] = acc;
    }
}

test "an optimizer step is safe in place" {
    // w[i] = w[i] + (-lr * g)[i]
    const step = [_]Read{ .{ .buffer = 0, .offset = 0 }, .{ .buffer = 1, .offset = 0 } };
    try std.testing.expect(inPlaceSafe(&step, 0));
    var a = [_]f64{ 1, 2, 3, 4 };
    var b = a;
    const g = [_]f64{ -0.1, -0.2, -0.3, -0.4 };
    var scratch: [4]f64 = undefined;
    runInPlace(&step, &a, &g);
    runFresh(&step, &b, &g, &scratch);
    try std.testing.expectEqualSlices(f64, &b, &a);
}

test "reading a neighbour is not" {
    // y[i] = x[i - 1] + x[i]
    const shift = [_]Read{ .{ .buffer = 0, .offset = -1 }, .{ .buffer = 0, .offset = 0 } };
    try std.testing.expect(!inPlaceSafe(&shift, 0));
    try std.testing.expect(inPlaceSafe(&shift, 1)); // writing elsewhere is fine
    var a = [_]f64{ 1, 1, 1, 1 };
    var b = a;
    var scratch: [4]f64 = undefined;
    runInPlace(&shift, &a, &.{ 0, 0, 0, 0 });
    runFresh(&shift, &b, &.{ 0, 0, 0, 0 }, &scratch);
    try std.testing.expectEqualSlices(f64, &.{ 1, 2, 2, 2 }, &b); // the right answer
    try std.testing.expect(!std.mem.eql(f64, &a, &b)); // in place got it wrong
}
