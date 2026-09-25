// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 144: speculative decoding ────────────────────────────────
//
// Generating with a big model is slow because it's one token at a time,
// and each step is memory-bound (044). *Speculative decoding* uses a
// small, fast draft model q to guess several tokens ahead, then the big
// model p checks all the guesses in ONE parallel pass (like training, 091).
//
// The clever part is the acceptance rule, which makes the output
// distributed EXACTLY like sampling from p alone:
//
//   for a drafted token x:
//     accept it with probability min(1, p(x) / q(x))
//     if rejected, sample instead from the leftover distribution
//         r(x) = max(0, p(x) - q(x)), normalized to sum to 1
//
// If the draft agrees with p, almost everything is accepted and you get
// several tokens per big-model pass for free. If it doesn't, you lose a
// little time but never quality. The test checks the "exactly p" claim
// empirically.
//
// YOUR TASK: write the acceptance probability and the leftover
// distribution.
//
const std = @import("std");

const vocab = 4;
const big = [vocab]f64{ 0.5, 0.2, 0.2, 0.1 }; //   p: the big model
const draft = [vocab]f64{ 0.3, 0.4, 0.2, 0.1 }; // q: the draft model

fn acceptProb(x: usize) f64 {
    return @min(1, big[x] / draft[x]);
}

fn leftover() [vocab]f64 {
    var r: [vocab]f64 = undefined;
    var total: f64 = 0;
    for (&r, 0..) |*v, x| {
        v.* = @max(0, big[x] - draft[x]);
        total += v.*;
    }
    for (&r) |*v| v.* /= total;
    return r;
}

fn sample(p: [vocab]f64, u: f64) usize {
    var running: f64 = 0;
    for (p, 0..) |v, i| {
        running += v;
        if (u < running) return i;
    }
    return vocab - 1;
}

test "the result is distributed exactly like the big model" {
    var prng = std.Random.DefaultPrng.init(144);
    const rand = prng.random();
    const r = leftover();
    var counts: [vocab]f64 = @splat(0);
    var accepted: f64 = 0;
    const n = 200_000;
    for (0..n) |_| {
        const x = sample(draft, rand.float(f64));
        if (rand.float(f64) < acceptProb(x)) {
            counts[x] += 1;
            accepted += 1;
        } else {
            counts[sample(r, rand.float(f64))] += 1;
        }
    }
    for (counts, big) |c, p| try std.testing.expectApproxEqAbs(p, c / n, 0.005);
    // and most drafts were accepted: sum of min(p, q) = 0.8
    try std.testing.expectApproxEqAbs(0.8, accepted / n, 0.005);
}
