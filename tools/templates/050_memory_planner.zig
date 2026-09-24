//
// ─── Exercise 050: reusing memory ──────────────────────────────────────
//
// Every kernel writes its output into a buffer. A training step can run
// hundreds of kernels, and most of their outputs are temporary: used by
// the next kernel or two, then never again. Giving each one fresh memory
// wastes a lot of GPU memory.
//
// A memory planner looks at the whole schedule ahead of time (another
// perk of laziness!) and works out when each buffer is last used. After
// that step, its memory can be handed to a later buffer of the same size:
//
//     step 0:  t0 = f(input)       t0 -> slot A
//     step 1:  t1 = g(t0)          t1 -> slot B     t0 is done: A is free
//     step 2:  t2 = h(t1)          t2 -> slot A!    t1 is done: B is free
//     step 3:  out = k(t2)         out -> slot B!
//
// Four buffers, two slots of real memory. tinygrad does this in its
// memory planner, and also keeps freed GPU buffers in a cache (grouped
// by size), so it doesn't have to ask the driver for memory every time.
//
// One rule: a step's output gets its slot BEFORE the step's inputs are
// freed, because a kernel can't write over something it's still reading.
//
// YOUR TASK: finish plan().
//
const std = @import("std");

const Step = struct {
    out: usize, //              buffer id written
    reads: []const usize, //    buffer ids read
};

/// Assigns every buffer written by `steps` to a slot of memory. Buffers
/// that are only read (inputs) aren't planned. Returns the total size of
/// all the slots.
fn plan(alloc: std.mem.Allocator, steps: []const Step, sizes: []const usize, slot_of: []usize) !usize {
    // 1. the last step that reads each buffer
    const last_use = try alloc.alloc(?usize, sizes.len);
    defer alloc.free(last_use);
    @memset(last_use, null);
    for (steps, 0..) |s, i| {
        for (s.reads) |b| ⟪last_use[b] = i|||???⟫;
    }

    var slot_sizes: std.ArrayList(usize) = .empty;
    defer slot_sizes.deinit(alloc);
    var free: std.ArrayList(usize) = .empty; // slots nobody is using
    defer free.deinit(alloc);

    for (steps, 0..) |s, i| {
        // 2. give the output a free slot of the right size, or a new one
        const want = sizes[s.out];
        const reuse = for (free.items, 0..) |slot, j| {
            if (⟪slot_sizes.items[slot] == want|||???⟫) break j;
        } else null;
        if (reuse) |j| {
            slot_of[s.out] = free.swapRemove(j);
        } else {
            slot_of[s.out] = slot_sizes.items.len;
            try slot_sizes.append(alloc, want);
        }

        // 3. free every buffer whose last use was this step
        //    (only buffers we planned, and each only once)
        for (s.reads, 0..) |b, k| {
            const planned = for (steps[0..i]) |earlier| {
                if (earlier.out == b) break true;
            } else false;
            const repeat = std.mem.indexOfScalar(usize, s.reads[0..k], b) != null;
            if (planned and !repeat and ⟪last_use[b] == i|||???⟫) {
                try free.append(alloc, slot_of[b]);
            }
        }
    }

    var total: usize = 0;
    for (slot_sizes.items) |size| total += size;
    return total;
}

test "a chain needs only two slots" {
    // buffer 0 is the input; 1, 2, 3, 4 are outputs of 100 floats each
    const sizes = [_]usize{ 100, 100, 100, 100, 100 };
    const steps = [_]Step{
        .{ .out = 1, .reads = &.{0} },
        .{ .out = 2, .reads = &.{1} },
        .{ .out = 3, .reads = &.{2} },
        .{ .out = 4, .reads = &.{3} },
    };
    var slot_of: [5]usize = undefined;
    const total = try plan(std.testing.allocator, &steps, &sizes, &slot_of);
    try std.testing.expectEqual(200, total); // instead of 400
    try std.testing.expectEqual(slot_of[1], slot_of[3]);
    try std.testing.expectEqual(slot_of[2], slot_of[4]);
}

test "a buffer stays alive until its last reader" {
    // t1 = f(in); t2 = g(t1); t3 = h(t1); out = k(t2, t3)
    const sizes = [_]usize{ 10, 10, 10, 10, 10 };
    const steps = [_]Step{
        .{ .out = 1, .reads = &.{0} },
        .{ .out = 2, .reads = &.{1} },
        .{ .out = 3, .reads = &.{1} },
        .{ .out = 4, .reads = &.{ 2, 3 } },
    };
    var slot_of: [5]usize = undefined;
    const total = try plan(std.testing.allocator, &steps, &sizes, &slot_of);
    try std.testing.expectEqual(30, total);
    try std.testing.expect(slot_of[3] != slot_of[1]); // t1 was still being read
    try std.testing.expectEqual(slot_of[1], slot_of[4]);
}

test "different sizes don't share" {
    const sizes = [_]usize{ 10, 10, 20, 10 };
    const steps = [_]Step{
        .{ .out = 1, .reads = &.{0} },
        .{ .out = 2, .reads = &.{1} },
        .{ .out = 3, .reads = &.{2} },
    };
    var slot_of: [4]usize = undefined;
    const total = try plan(std.testing.allocator, &steps, &sizes, &slot_of);
    try std.testing.expectEqual(30, total); // 2 needs its own slot...
    try std.testing.expectEqual(slot_of[1], slot_of[3]); // ...but 3 reuses 1's
}
