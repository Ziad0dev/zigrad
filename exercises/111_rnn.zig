//
// ═══ PART III: the rest of the map ═════════════════════════════════════
//
// Part III covers what's left: other kinds of models (21-24), deeper
// optimization (25), training and serving at scale (26-27), how kernels
// really compute math functions (28), the memory hierarchy (29), and
// tinygrad's own internals (30), ending with a final capstone.
//
// ─── Exercise 111: recurrent networks ──────────────────────────────────
//
// Chapter 21: sequence models before transformers.
//
// A *recurrent neural network* (RNN) reads a sequence one step at a time,
// carrying a *hidden state* h, its memory of everything so far:
//
//     h_t = tanh(W h_(t-1) + U x_t + b)
//
// The SAME W, U and b are used at every step (weight sharing across time,
// like a convolution shares across space, 104). So one small network
// handles sequences of any length, with a fixed number of parameters.
//
// Transformers (chapter 17) replaced RNNs for most tasks because
// attention can look at any earlier token directly, and all tokens train
// in parallel. An RNN must squeeze the whole past through h, one step
// after another. But the ideas (and their problems, next exercises)
// explain a lot, and RNN-like models have made a comeback in state-space
// models such as Mamba.
//
// YOUR TASK: write one RNN step.
//
const std = @import("std");

const hidden = 2;
const inputs = 1;

const Rnn = struct {
    w: [hidden][hidden]f64,
    u: [hidden][inputs]f64,
    b: [hidden]f64,

    fn step(r: Rnn, h: [hidden]f64, x: [inputs]f64) [hidden]f64 {
        var out: [hidden]f64 = undefined;
        for (0..hidden) |i| {
            var pre = r.b[i];
            for (0..hidden) |j| pre += ???;
            for (0..inputs) |j| pre += ???;
            out[i] = ???;
        }
        return out;
    }

    fn run(r: Rnn, xs: []const [inputs]f64) [hidden]f64 {
        var h: [hidden]f64 = @splat(0);
        for (xs) |x| h = r.step(h, x);
        return h;
    }
};

test "one step by hand" {
    const r: Rnn = .{ .w = .{ .{ 0.5, 0 }, .{ 0, 0.5 } }, .u = .{ .{1}, .{-1} }, .b = .{ 0, 0.1 } };
    const h = r.step(.{ 0.2, 0.4 }, .{0.3});
    try std.testing.expectApproxEqAbs(std.math.tanh(@as(f64, 0.1 + 0.3)), h[0], 1e-12);
    try std.testing.expectApproxEqAbs(std.math.tanh(@as(f64, 0.2 - 0.3 + 0.1)), h[1], 1e-12);
}

test "a counter: the hidden state remembers how many 1s it has seen" {
    // h0 grows with every 1 in the input (while tanh is still roughly linear)
    const r: Rnn = .{ .w = .{ .{ 1, 0 }, .{ 0, 0 } }, .u = .{ .{0.1}, .{0} }, .b = .{ 0, 0 } };
    const few = r.run(&.{ .{1}, .{0}, .{1}, .{0}, .{0} });
    const many = r.run(&.{ .{1}, .{1}, .{1}, .{0}, .{1} });
    try std.testing.expect(many[0] > few[0]);
    // same parameters, any length
    _ = r.run(&[_][inputs]f64{.{1}} ** 100);
}
