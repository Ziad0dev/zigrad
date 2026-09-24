// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 077: how GPUs run kernels ────────────────────────────────
//
// A CPU runs the loops. A GPU deletes the global loops and runs the body
// once per THREAD, thousands at the same time. Threads come in *blocks*
// (CUDA's word; OpenCL says workgroups, tinygrad says "local"), and
// blocks form a *grid*:
//
//     launch <<<blocks, threads_per_block>>>
//     each thread knows block_id and thread_id, and computes
//         gid = block_id * threads_per_block + thread_id
//
// To cover n elements with blocks of size bs you need ceil(n / bs)
// blocks, (n + bs - 1) / bs in integers. The last block usually has spare
// threads, so kernels start with a guard: `if (gid >= n) return;`.
//
// Grids can be 2D (or 3D), which suits matrices: x picks the column and
// y the row, each computed the same way.
//
// tinygrad's global axes (076) become exactly these grid dimensions, and
// its local axes (079) become the block dimensions.
//
// YOUR TASK: finish blocksNeeded(), the 1D launch, and the 2D kernel.
//
const std = @import("std");

fn blocksNeeded(n: usize, bs: usize) usize {
    return (n + bs - 1) / bs;
}

const Stats = struct { threads: usize = 0, idle: usize = 0 };

/// c = a + b, run as a grid of blocks of `bs` threads.
fn launchAdd(a: []const f32, b: []const f32, c: []f32, bs: usize, stats: *Stats) void {
    const n = c.len;
    for (0..blocksNeeded(n, bs)) |block_id| {
        for (0..bs) |thread_id| { // on a GPU, these all run at once
            stats.threads += 1;
            const gid = block_id * bs + thread_id;
            if (gid >= n) {
                stats.idle += 1;
                continue; // the guard
            }
            c[gid] = a[gid] + b[gid];
        }
    }
}

/// out = transpose(in), in is [rows, cols]. 2D grid of 2D blocks.
fn launchTranspose(in: []const f32, rows: usize, cols: usize, out: []f32, bx: usize, by: usize) void {
    for (0..blocksNeeded(rows, by)) |block_y| {
        for (0..blocksNeeded(cols, bx)) |block_x| {
            for (0..by) |ty| {
                for (0..bx) |tx| {
                    const col = block_x * bx + tx;
                    const row = block_y * by + ty;
                    if (row >= rows or col >= cols) continue;
                    out[col * rows + row] = in[row * cols + col];
                }
            }
        }
    }
}

test "1D" {
    try std.testing.expectEqual(4, blocksNeeded(1000, 256));
    try std.testing.expectEqual(4, blocksNeeded(1024, 256));
    try std.testing.expectEqual(5, blocksNeeded(1025, 256));

    var a: [1000]f32 = undefined;
    var b: [1000]f32 = undefined;
    var c: [1000]f32 = undefined;
    for (&a, &b, 0..) |*x, *y, i| {
        x.* = @floatFromInt(i);
        y.* = 1;
    }
    var stats: Stats = .{};
    launchAdd(&a, &b, &c, 256, &stats);
    for (c, 0..) |v, i| try std.testing.expectEqual(@as(f32, @floatFromInt(i)) + 1, v);
    try std.testing.expectEqual(1024, stats.threads);
    try std.testing.expectEqual(24, stats.idle);
}

test "2D" {
    var in: [5 * 7]f32 = undefined;
    for (&in, 0..) |*x, i| x.* = @floatFromInt(i);
    var out: [7 * 5]f32 = undefined;
    launchTranspose(&in, 5, 7, &out, 4, 4);
    for (0..5) |r| {
        for (0..7) |col| try std.testing.expectEqual(in[r * 7 + col], out[col * 5 + r]);
    }
}
