//
// ─── Exercise 051: the JIT ─────────────────────────────────────────────
//
// Training runs the SAME step thousands of times: same ops, same shapes,
// only the numbers change. Yet every step we'd rebuild the lazy graph,
// schedule it, linearize, render and look up compiled kernels. For small
// models, that bookkeeping can take longer than the kernels themselves!
//
// tinygrad's TinyJit fixes this. Decorate your step function with it:
//   * the first call runs normally. The second runs normally too, while
//     the JIT records which kernels ran, on which buffers ("capture")
//   * every later call skips all the bookkeeping: put the new inputs where
//     the captured ones were, then launch the recorded kernels in order
//     ("replay"). Ours copies the new numbers into the old input buffer;
//     tinygrad swaps in the new buffers themselves, which saves the copy.
//
// The catch: a replay is a recording. Anything your function decided
// while capturing (the shapes, which branch of an `if` it took) is frozen
// in. Change the input shape and the recording is wrong, so the JIT must
// refuse.
//
// Here the "model" is y = relu(x * w + b) as 3 kernels, and schedule()
// stands in for all the expensive bookkeeping.
//
// YOUR TASK: finish the replay branch of Jit.call().
//
const std = @import("std");

const KernelFn = *const fn (out: []f32, a: []const f32, b: []const f32) void;

fn mulK(out: []f32, a: []const f32, b: []const f32) void {
    for (out, a, b) |*o, x, y| o.* = x * y;
}
fn addK(out: []f32, a: []const f32, b: []const f32) void {
    for (out, a, b) |*o, x, y| o.* = x + y;
}
fn reluK(out: []f32, a: []const f32, b: []const f32) void {
    _ = b;
    for (out, a) |*o, x| o.* = @max(x, 0);
}

/// One recorded kernel launch: which kernel, on which buffers.
const Launch = struct { kernel: KernelFn, a: usize, b: usize, out: usize };

const x_buf = 0;
const w_buf = 1;
const b_buf = 2;
const y_buf = 5;

const Runtime = struct {
    bufs: [6][]f32,
    schedules: usize = 0, // how often we did the expensive part
    launches: usize = 0,

    /// Graph -> schedule -> linearize -> compile. Expensive!
    fn schedule(rt: *Runtime) []const Launch {
        rt.schedules += 1;
        const plan = struct {
            const launches = [_]Launch{
                .{ .kernel = &mulK, .a = x_buf, .b = w_buf, .out = 3 },
                .{ .kernel = &addK, .a = 3, .b = b_buf, .out = 4 },
                .{ .kernel = &reluK, .a = 4, .b = 4, .out = y_buf },
            };
        };
        return &plan.launches;
    }

    fn launch(rt: *Runtime, l: Launch) void {
        rt.launches += 1;
        l.kernel(rt.bufs[l.out], rt.bufs[l.a], rt.bufs[l.b]);
    }
};

const Jit = struct {
    captured: ?[]const Launch = null,

    fn call(j: *Jit, rt: *Runtime, x: []const f32) ![]const f32 {
        if (j.captured) |launches| {
            // replay: same shapes only, then new inputs + recorded kernels
            if (x.len != rt.bufs[x_buf].len) return error.ShapeChanged;
//⟪
            @memcpy(rt.bufs[x_buf], x);
            for (launches) |l| rt.launch(l);
//|||
            ???;
//⟫
        } else {
            // capture: do everything the slow way, and remember the kernels
            @memcpy(rt.bufs[x_buf], x);
            const launches = rt.schedule();
            for (launches) |l| rt.launch(l);
            j.captured = launches;
        }
        return rt.bufs[y_buf];
    }
};

test "schedule once, replay forever" {
    var mem: [6][4]f32 = undefined;
    var rt: Runtime = .{ .bufs = undefined };
    for (&rt.bufs, &mem) |*b, *m| b.* = m;
    @memcpy(rt.bufs[w_buf], &[_]f32{ 1, 2, 3, 4 });
    @memcpy(rt.bufs[b_buf], &[_]f32{ -1, -1, -1, -1 });

    var jit: Jit = .{};
    for (0..10) |step| {
        const s: f32 = @floatFromInt(step);
        const y = try jit.call(&rt, &.{ s, s, -s, 1 });
        // relu(x * w + b), computed by hand
        try std.testing.expectEqualSlices(f32, &.{ @max(s - 1, 0), @max(2 * s - 1, 0), 0, 3 }, y);
    }
    try std.testing.expectEqual(1, rt.schedules);
    try std.testing.expectEqual(30, rt.launches);
}

test "a different shape can't be replayed" {
    var mem: [6][4]f32 = @splat(@splat(0));
    var rt: Runtime = .{ .bufs = undefined };
    for (&rt.bufs, &mem) |*b, *m| b.* = m;

    var jit: Jit = .{};
    _ = try jit.call(&rt, &.{ 1, 2, 3, 4 });
    try std.testing.expectError(error.ShapeChanged, jit.call(&rt, &.{ 1, 2, 3 }));
}
