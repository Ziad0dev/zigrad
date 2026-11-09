// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 198: fitting a kernel onto the GPU's grid ───────────────
//
// A kernel's GLOBAL axes become the grid, its LOCAL axes the block (077,
// 196). But hardware has limits. A CUDA grid has at most 3 dimensions,
// of at most (2^31 - 1, 65535, 65535) blocks; a block has at most
// (1024, 1024, 64) threads, and 1024 in total. A kernel can easily have 4
// global axes, or one axis of 100,000.
//
// tinygrad's get_grouped_dims (tinygrad/codegen/gpudims.py) fixes that in
// two moves, then works out each original index from the hardware ones:
//
//   group  too many dims, or one too big: merge a dim with its right
//          neighbour, if their product fits that slot. (a, b, c, d) ->
//          (a*b, c, d). Repeat. (_group_dims)
//   split  if grouping didn't change anything, split a dim that's too big
//          by its smallest divisor, moving the factor into the next slot:
//          (4096,) -> (2048, 2) -> (1024, 4). (_split_dims)
//
// Either way, the hardware indexes count through the same flat range as
// the original ones:
//
//     flat = sum of hw[i] * prod(limited[i+1..])
//     original[0] = flat DIV prod(dims[1..])
//     original[i] = (flat DIV prod(dims[i+1..])) MOD dims[i]
//
// One more thing: tinygrad maps the global dims in REVERSE (reverse=True),
// so the LAST axis, the one that walks along memory, lands on hardware x
// (blockIdx.x / gidx0). Neighbouring threads then read neighbouring
// addresses: coalescing (153).
//
// YOUR TASK: the merge condition in groupDims(), the split in splitDims(),
// and the index recovery in originalIndex().
//
const std = @import("std");

const cuda_global_max = [_]usize{ 2147483647, 65535, 65535 };
const cuda_local_max = [_]usize{ 1024, 1024, 64 };

fn prod(s: []const usize) usize {
    var p: usize = 1;
    for (s) |v| p *= v;
    return p;
}

fn fits(dims: []const usize, max: []const usize) bool {
    if (dims.len > max.len) return false;
    for (dims, max[0..dims.len]) |d, m| if (d > m) return false;
    return true;
}

/// Merge neighbours until the dims fit, or null if no merge fits. (_group_dims)
fn groupDims(alloc: std.mem.Allocator, dims: []const usize, max: []const usize) ?[]const usize {
    var d = alloc.dupe(usize, dims) catch @panic("out of memory");
    while (!fits(d, max)) {
        for (max, 0..) |m, i| {
            if (i + 1 < d.len and d[i] * d[i + 1] <= m) {
                const merged = alloc.alloc(usize, d.len - 1) catch @panic("out of memory");
                @memcpy(merged[0..i], d[0..i]);
                merged[i] = d[i] * d[i + 1];
                @memcpy(merged[i + 1 ..], d[i + 2 ..]);
                d = merged;
                break;
            }
        } else return null;
    }
    return d;
}

/// Split dims that are too big, moving a factor into the next slot. (_split_dims)
fn splitDims(alloc: std.mem.Allocator, dims: []const usize, max: []const usize) error{CantLimit}![]const usize {
    if (fits(dims, max)) return dims;
    var d = [3]usize{ 1, 1, 1 };
    @memcpy(d[0..dims.len], dims);
    for (0..3) |i| {
        while (d[i] > max[i]) {
            // the smallest divisor, up to the square root
            var div: usize = 2;
            while (div * div <= d[i] and d[i] % div != 0) div += 1;
            if (div * div > d[i]) return error.CantLimit; // a prime: nothing to split
            d[i] /= div;
            d[(i + 1) % 3] *= div;
        }
    }
    return alloc.dupe(usize, if (d[2] == 1) d[0..2] else d[0..3]) catch @panic("out of memory");
}

/// The hardware dims for `dims`. (get_grouped_dims, before the reverse)
fn limitDims(alloc: std.mem.Allocator, dims: []const usize, max: []const usize) error{CantLimit}![]const usize {
    const grouped = groupDims(alloc, dims, max) orelse dims;
    if (grouped.len > max.len) return error.CantLimit;
    if (std.mem.eql(usize, grouped, dims)) return splitDims(alloc, dims, max);
    return grouped;
}

/// Hardware indexes (one per limited dim) back to the original indexes.
fn originalIndex(dims: []const usize, limited: []const usize, hw: []const usize, out: []usize) void {
    var flat: usize = 0;
    for (hw, 0..) |h, i| flat += h * prod(limited[i + 1 ..]);
    for (out, 0..) |*o, i| {
        const q = flat / prod(dims[i + 1 ..]);
        o.* = if (i == 0) q else q % dims[i];
    }
}

const t = std.testing;

/// Every combination of hardware indexes must hit every original index once.
fn expectBijection(dims: []const usize, limited: []const usize) !void {
    try t.expectEqual(prod(dims), prod(limited));
    var seen = try t.allocator.alloc(bool, prod(dims));
    defer t.allocator.free(seen);
    @memset(seen, false);
    var hw: [3]usize = undefined;
    var orig: [8]usize = undefined;
    for (0..prod(limited)) |pos| {
        var rem = pos;
        var k = limited.len;
        while (k > 0) {
            k -= 1;
            hw[k] = rem % limited[k];
            rem /= limited[k];
        }
        originalIndex(dims, limited, hw[0..limited.len], orig[0..dims.len]);
        var flat: usize = 0;
        for (orig[0..dims.len], dims) |o, d| {
            try t.expect(o < d);
            flat = flat * d + o;
        }
        try t.expect(!seen[flat]);
        seen[flat] = true;
    }
}

test "four global dims don't fit in three: group" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const dims = [_]usize{ 2, 3, 4, 5 };
    const limited = try limitDims(arena.allocator(), &dims, &cuda_global_max);
    try t.expectEqualSlices(usize, &.{ 6, 4, 5 }, limited);
    try expectBijection(&dims, limited);
}

test "dims that fit are left alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualSlices(usize, &.{ 64, 16 }, try limitDims(arena.allocator(), &.{ 64, 16 }, &cuda_local_max));
}

test "a dim too big for its slot: split" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 4096 threads won't fit one block dimension: (1024, 4)
    const local = try limitDims(a, &.{4096}, &cuda_local_max);
    try t.expectEqualSlices(usize, &.{ 1024, 4 }, local);
    try expectBijection(&.{4096}, local);
    // y can hold at most 65535 blocks, and 70000 * 70000 won't fit x either
    const global = try limitDims(a, &.{ 70000, 70000 }, &cuda_global_max);
    try t.expectEqualSlices(usize, &.{ 70000, 35000, 2 }, global);
    // a prime that's too big can't be split
    try t.expectError(error.CantLimit, limitDims(a, &.{2053}, &cuda_local_max));
}

test "group first, if it helps" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // four block dims, three slots: merge the first two (4 * 8 fits in x)
    const dims = [_]usize{ 4, 8, 16, 2 };
    const limited = try limitDims(arena.allocator(), &dims, &cuda_local_max);
    try t.expectEqualSlices(usize, &.{ 32, 16, 2 }, limited);
    try expectBijection(&dims, limited);
    const a = arena.allocator();
    // 40 * 40 is too big for x, so the next pair merges instead
    try t.expectEqualSlices(usize, &.{ 40, 80, 2 }, try limitDims(a, &.{ 40, 40, 2, 2 }, &cuda_local_max));
    // a product of exactly the limit fits
    try t.expectEqualSlices(usize, &.{ 1024, 2, 2 }, try limitDims(a, &.{ 32, 32, 2, 2 }, &cuda_local_max));
    // merging can go on until it fits, all the way to one dim
    try t.expectEqualSlices(usize, &.{700000}, try limitDims(a, &.{ 2, 5, 70000 }, &cuda_global_max));
}

test "reversed, the last axis is hardware x" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // a (rows, cols) kernel: cols walks along memory, so it should be gidx0
    const dims = [_]usize{ 100, 300 };
    const rev = [_]usize{ dims[1], dims[0] };
    const hw = try limitDims(arena.allocator(), &rev, &cuda_global_max);
    try t.expectEqual(300, hw[0]); // x: the columns
    try t.expectEqual(100, hw[1]); // y: the rows
}
