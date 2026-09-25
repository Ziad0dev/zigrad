//
// ─── Exercise 118: a bigram language model ─────────────────────────────
//
// A *language model* gives the probability of the next token given the
// previous ones. The simplest possible one looks back just ONE token: a
// *bigram* model, P(next | previous).
//
// Training it is counting. Over a corpus of names (like Karpathy's
// "makemore" series), count how often each character follows each other
// character. '.' marks where names start and end:
//
//     "emma."  ->  (. e) (e m) (m m) (m a) (a .)
//
// Then P(b | a) = count[a][b] / (total count of pairs starting with a).
//
// Unseen pairs would get probability 0, and log 0 = -infinity. *Add-one
// smoothing* pretends every pair was seen once more than it was:
//
//     P(b | a) = (count[a][b] + 1) / (row total + vocab size)
//
// The model's quality is its average negative log-likelihood (061) on
// text: lower is better.
//
// YOUR TASK: count the bigrams, write the smoothed probability, and the
// average NLL.
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

const Bigram = struct {
    counts: [vocab][vocab]f64 = @splat(@splat(0)),

    fn train(text: []const u8) Bigram {
        var m: Bigram = .{};
        var prev: usize = 0; // every name starts after a '.'
        for (text) |ch| {
            const next = id(ch);
            ???
            prev = next;
        }
        return m;
    }

    fn prob(m: Bigram, a: usize, b: usize) f64 {
        var total: f64 = 0;
        for (m.counts[a]) |c| total += c;
        return ???;
    }

    /// Average negative log-likelihood per character of `text`.
    fn nll(m: Bigram, text: []const u8) f64 {
        var total: f64 = 0;
        var prev: usize = 0;
        for (text) |ch| {
            const next = id(ch);
            total -= ???;
            prev = next;
        }
        return total / @as(f64, @floatFromInt(text.len));
    }
};

test "counting" {
    const m = Bigram.train(corpus);
    try std.testing.expect(m.counts[id('.')][id('a')] > 5); // lots of names start with a
    try std.testing.expectEqual(0, m.counts[id('q')][id('z')]);
}

test "probabilities sum to 1" {
    const m = Bigram.train(corpus);
    for (0..vocab) |a| {
        var total: f64 = 0;
        for (0..vocab) |b| total += m.prob(a, b);
        try std.testing.expectApproxEqAbs(1.0, total, 1e-12);
    }
}

test "better than guessing" {
    const m = Bigram.train(corpus);
    const loss = m.nll(corpus);
    try std.testing.expect(loss < @log(@as(f64, vocab))); // uniform guessing costs ln 27
    // an unseen name still gets a finite loss, thanks to smoothing
    try std.testing.expect(std.math.isFinite(m.nll("qxz.")));
}
