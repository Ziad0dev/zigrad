//
// ─── Exercise 114: LSTM, a memory that doesn't fade ────────────────────
//
// The LSTM ("long short-term memory") fixes vanishing gradients with a
// separate *cell state* c that is updated by ADDING, controlled by gates:
//
//     f = σ(...)          forget gate: how much old memory to keep (0..1)
//     i = σ(...)          input gate: how much new stuff to write
//     g = tanh(...)       the new stuff
//     o = σ(...)          output gate: how much memory to show
//
//     c_t = f * c_(t-1) + i * g
//     h_t = o * tanh(c_t)
//
// (each "..." is W h_(t-1) + U x_t + b, with its own weights)
//
// The key: d c_t / d c_(t-1) = f. No weight matrix, no squashing. With
// the forget gate near 1, memory AND gradient pass through hundreds of
// steps almost untouched. The network learns when to open and close the
// gates.
//
// Here every gate has hidden size 1, and the "..." are given as
// functions of the input.
//
// YOUR TASK: write the cell update and the output.
//
const std = @import("std");

fn sigmoid(x: f64) f64 {
    return 1 / (1 + @exp(-x));
}

const Gates = struct { f: f64, i: f64, g: f64, o: f64 };

const Lstm = struct {
    // pre-activations as simple functions of the input x
    f_bias: f64,
    i_bias: f64,
    i_weight: f64,

    fn gates(l: Lstm, x: f64) Gates {
        return .{
            .f = sigmoid(l.f_bias),
            .i = sigmoid(l.i_bias + l.i_weight * x),
            .g = std.math.tanh(x),
            .o = sigmoid(2),
        };
    }

    fn step(l: Lstm, c: f64, x: f64) [2]f64 {
        const gt = l.gates(x);
        const c_new = ⟪gt.f * c + gt.i * gt.g|||???⟫;
        const h = ⟪gt.o * std.math.tanh(c_new)|||???⟫;
        return .{ c_new, h };
    }
};

test "one step by hand" {
    // all biases 0: f = i = σ(0) = 0.5, g = tanh(x), o = σ(2)
    const l: Lstm = .{ .f_bias = 0, .i_bias = 0, .i_weight = 0 };
    const r = l.step(1, 1);
    try std.testing.expectApproxEqAbs(0.5 * 1 + 0.5 * std.math.tanh(@as(f64, 1)), r[0], 1e-12);
    try std.testing.expectApproxEqAbs(sigmoid(2) * std.math.tanh(r[0]), r[1], 1e-12);
}

test "store a value, remember it for 100 steps" {
    // forget gate wide open; the input gate only opens for big inputs
    const l: Lstm = .{ .f_bias = 20, .i_bias = -10, .i_weight = 10 };
    var c: f64 = 0;
    c = l.step(c, 1.5)[0]; // a big input: written into memory
    const stored = c;
    // Small inputs: the input gate stays shut (sigmoid(-10 + 10 * 0.2) is
    // about 0.0003), so almost none of tanh(0.2) gets in. Without the
    // gate, 100 of them would add up to 20.
    for (0..100) |_| c = l.step(c, 0.2)[0];
    try std.testing.expectApproxEqAbs(stored, c, 0.01);
}

test "the gradient along the memory is the product of forget gates" {
    const l: Lstm = .{ .f_bias = 20, .i_bias = -10, .i_weight = 10 };
    const f = l.gates(0).f;
    // d c_100 / d c_0 = f^100, still about 1. Measured through step():
    const h = 1e-6;
    var up: f64 = 0.3 + h;
    var down: f64 = 0.3 - h;
    for (0..100) |_| {
        up = l.step(up, 0.1)[0];
        down = l.step(down, 0.1)[0];
    }
    const slope = (up - down) / (2 * h);
    try std.testing.expectApproxEqAbs(std.math.pow(f64, f, 100), slope, 1e-6);
    try std.testing.expect(slope > 0.99);
}
