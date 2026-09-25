//
// ─── Exercise 170: thinking in blocks, the Triton way ─────────────────
//
// CUDA makes you write one THREAD's code (077). *Triton*, the language
// behind many of PyTorch's generated GPU kernels, makes you write one
// BLOCK's code instead: each "program" handles a whole block of elements
// at once, as vectors, and the compiler decides how threads, registers and
// shared memory implement it. A row-softmax in Triton looks like:
//
//     row    = tl.program_id(0)                  # which program am I?
//     offs   = tl.arange(0, BLOCK)               # [0, 1, ..., BLOCK-1]
//     mask   = offs < n_cols                     # BLOCK must be a power of 2
//     x      = tl.load(ptr + row * stride + offs, mask=mask, other=-inf)
//     x      = x - tl.max(x, axis=0)             # stable softmax (018)
//     num    = tl.exp(x)
//     y      = num / tl.sum(num, axis=0)
//     tl.store(out + row * stride + offs, y, mask=mask)
//
// The *mask* is the key idea. Blocks have a fixed power-of-two size, but
// rows don't, so lanes past the end are switched off: masked loads return
// `other` instead of touching memory, and masked stores write nothing.
// Picking other = -inf is what makes the padding harmless here: it never
// wins the max, and e^-inf = 0 adds nothing to the sum.
//
// It's the same idea as tinygrad's valid conditions (014, 073). And the
// whole softmax is ONE kernel, reading and writing each element once,
// where tinygrad's scheduler splits softmax into three (040): a
// hand-written kernel can keep a row in registers between the max, the
// sum and the divide.
//
// Here a block is a Zig @Vector, so the kernel below really is written one
// block at a time.
//
// YOUR TASK: build the mask, the masked load's filler, and the masked
// store.
//
const std = @import("std");

const BLOCK = 8;
const Vf = @Vector(BLOCK, f32);
const Vi = @Vector(BLOCK, usize);
const Vb = @Vector(BLOCK, bool);

fn arange() Vi {
    return std.simd.iota(usize, BLOCK);
}

/// Lanes where mask is false get `other`, and memory isn't read there.
fn load(mem: []const f32, base: usize, mask: Vb, other: f32) Vf {
    var out: [BLOCK]f32 = undefined;
    inline for (0..BLOCK) |l| out[l] = if (mask[l]) mem[base + l] else other;
    return out;
}

/// Lanes where mask is false are not written.
fn store(mem: []f32, base: usize, v: Vf, mask: Vb) void {
    inline for (0..BLOCK) |l| {
        if (⟪mask[l]|||???⟫) mem[base + l] = v[l];
    }
}

/// One program: softmax of row `row` of a [rows, n_cols] matrix.
fn softmaxProgram(row: usize, x: []const f32, out: []f32, n_cols: usize, stride: usize) void {
    const offs = arange();
    const mask: Vb = ⟪offs < @as(Vi, @splat(n_cols))|||???⟫;
    var v = load(x, row * stride, mask, ⟪-std.math.inf(f32)|||???⟫);
    v -= @as(Vf, @splat(@reduce(.Max, v)));
    const num = @exp(v);
    const y = num / @as(Vf, @splat(@reduce(.Add, num)));
    store(out, row * stride, y, mask);
}

/// The launch: one program per row (Triton's grid).
fn softmax(x: []const f32, out: []f32, rows: usize, n_cols: usize) void {
    for (0..rows) |row| softmaxProgram(row, x, out, n_cols, n_cols);
}

test "rows shorter than a block" {
    // 3 rows of 5: the last 3 lanes of every block are masked off
    const x = [_]f32{ 1, 2, 3, 4, 5, 0, 0, 0, 0, 0, 1000, 1001, 999, 1000, 1000 };
    var out = [_]f32{-1} ** 16; // one guard element at the end
    softmax(&x, &out, 3, 5);
    for (0..3) |r| {
        var s: f32 = 0;
        for (out[r * 5 ..][0..5]) |p| s += p;
        try std.testing.expectApproxEqAbs(1.0, s, 1e-6);
    }
    for (out[5..10]) |p| try std.testing.expectApproxEqAbs(0.2, p, 1e-6);
    // huge logits don't overflow
    try std.testing.expect(!std.math.isNan(out[11]));
    // nothing written past the last row
    try std.testing.expectEqual(-1, out[15]);
}

test "masked-off memory is never read" {
    // the row is at the very end of memory: an unmasked load of 8 would
    // run off the end of the slice
    const x = [_]f32{ 0, 0 };
    var out: [2]f32 = undefined;
    softmax(&x, &out, 1, 2);
    try std.testing.expectApproxEqAbs(0.5, out[0], 1e-6);
}
