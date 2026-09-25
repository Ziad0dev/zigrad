// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 120: the same model, learned ─────────────────────────────
//
// Now train a bigram model by gradient descent instead of counting: a
// table of logits W[prev][next] (an embedding, 088, of the previous
// character), softmax over each row, cross-entropy on the next character
// (036). The gradient for one example (a, b) is
//
//     dW[a][c] += p(c | a) - (1 if c == b else 0)
//
// averaged over all examples. Train long enough and something neat
// happens: the network's probabilities converge to the COUNTED ones (118,
// without smoothing), because counting IS the maximum-likelihood answer
// (061). Gradient descent rediscovers it.
//
// Why bother with the neural version? It generalizes: look back further,
// add layers, share parameters, and you have Bengio's 2003 neural language
// model, then an RNN (111), then a transformer (chapter 17). Counting
// tables can't do any of that.
//
// YOUR TASK: write the gradient and the update.
//
const std = @import("std");

// A tiny corpus of names, each ending in '.' (the end-of-name token).
const corpus = "emma.olivia.ava.isabella.sophia.charlotte.mia.amelia.harper.evelyn." ++
    "abigail.emily.elizabeth.mila.ella.avery.sofia.camila.aria.scarlett." ++
    "victoria.madison.luna.grace.chloe.penelope.layla.riley.zoey.nora." ++
    "lily.eleanor.hannah.lillian.addison.aubrey.ellie.stella.natalie.zoe." ++
    "leah.hazel.violet.aurora.savannah.audrey.brooklyn.bella.claire.skylar.";

const vocab = 27; // '.' and a-z

fn id(ch: u8) usize {
    return if (ch == '.') 0 else ch - 'a' + 1;
}

fn softmaxRow(logits: []const f64, out: []f64) void {
    var m: f64 = -std.math.inf(f64);
    for (logits) |v| m = @max(m, v);
    var total: f64 = 0;
    for (logits, out) |v, *o| {
        o.* = @exp(v - m);
        total += o.*;
    }
    for (out) |*o| o.* /= total;
}

const Model = struct {
    w: [vocab][vocab]f64 = @splat(@splat(0)),

    /// One step of gradient descent on the whole corpus. Returns the loss.
    fn step(m: *Model, text: []const u8, lr: f64) f64 {
        var grad: [vocab][vocab]f64 = @splat(@splat(0));
        var p: [vocab]f64 = undefined;
        var loss: f64 = 0;
        const n: f64 = @floatFromInt(text.len);
        var prev: usize = 0;
        for (text) |ch| {
            const next = id(ch);
            softmaxRow(&m.w[prev], &p);
            loss -= @log(p[next]) / n;
            for (0..vocab) |c| {
                const truth: f64 = if (c == next) 1 else 0;
                grad[prev][c] += (p[c] - truth) / n;
            }
            prev = next;
        }
        for (&m.w, grad) |*row, grow| {
            for (row, grow) |*w, g| w.* -= lr * g;
        }
        return loss;
    }
};

/// The loss of the counted (maximum likelihood) model, for comparison.
fn countedLoss(text: []const u8) f64 {
    var counts: [vocab][vocab]f64 = @splat(@splat(0));
    var prev: usize = 0;
    for (text) |ch| {
        counts[prev][id(ch)] += 1;
        prev = id(ch);
    }
    var loss: f64 = 0;
    prev = 0;
    for (text) |ch| {
        var total: f64 = 0;
        for (counts[prev]) |c| total += c;
        loss -= @log(counts[prev][id(ch)] / total);
        prev = id(ch);
    }
    return loss / @as(f64, @floatFromInt(text.len));
}

test "gradient descent rediscovers the counts" {
    var m: Model = .{};
    var loss: f64 = 0;
    for (0..3000) |_| loss = m.step(corpus, 50);
    try std.testing.expect(loss < @log(@as(f64, vocab))); // it learned something...
    try std.testing.expectApproxEqAbs(countedLoss(corpus), loss, 0.02); // ...the counts
}
