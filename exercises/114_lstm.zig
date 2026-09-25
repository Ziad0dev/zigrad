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
        const c_new = ???;
        const h = ???;
        return .{ c_new, h };
    }
};

test "store a value, remember it for 100 steps" {
    // forget gate wide open; the input gate only opens for big inputs
    const l: Lstm = .{ .f_bias = 20, .i_bias = -10, .i_weight = 10 };
    var c: f64 = 0;
    c = l.step(c, 1.5)[0]; // a big input: written into memory
    const stored = c;
    for (0..100) |_| c = l.step(c, 0)[0]; // small inputs: gate stays shut
    try std.testing.expectApproxEqAbs(stored, c, 1e-4);
}

test "the gradient along the memory is the product of forget gates" {
    const l: Lstm = .{ .f_bias = 20, .i_bias = -10, .i_weight = 10 };
    const f = l.gates(0).f;
    // d c_100 / d c_0 = f^100, still about 1
    try std.testing.expect(std.math.pow(f64, f, 100) > 0.99);
}
