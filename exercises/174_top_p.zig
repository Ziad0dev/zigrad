//
// ─── Exercise 174: nucleus (top-p) sampling ───────────────────────────
//
// Top-k (063) keeps a FIXED number of candidates. But sometimes the model
// is sure (one token has 95%) and sometimes it's torn between dozens of
// reasonable words. A fixed k is too many in the first case and too few in
// the second.
//
// *Nucleus sampling*, or top-p (Holtzman et al., 2019, "The Curious Case
// of Neural Text Degeneration"), adapts: keep the SMALLEST set of most
// likely tokens whose probabilities add up to at least p, renormalize, and
// sample from that:
//
//     p = 0.9, probs sorted: 0.5  0.3  0.15  0.05
//     running total:         0.5  0.8  0.95        <- reached 0.9: stop
//     keep {0.5, 0.3, 0.15}, renormalize by 0.95
//
// Confident step: one or two tokens survive. Uncertain step: many do.
// Implementations sort the probabilities (descending) and take a prefix
// sum (169), then cut where it first reaches p.
//
// YOUR TASK: find where to cut, and zero out everything past it.
//
const std = @import("std");

/// Keep the smallest top set with total >= p; renormalize in place.
/// Returns how many tokens were kept.
fn topP(alloc: std.mem.Allocator, probs: []f64, p: f64) !usize {
    // token ids sorted by probability, most likely first
    const order = try alloc.alloc(usize, probs.len);
    defer alloc.free(order);
    for (order, 0..) |*o, i| o.* = i;
    const Ctx = struct {
        probs: []const f64,
        fn more(ctx: @This(), a: usize, b: usize) bool {
            return ctx.probs[a] > ctx.probs[b];
        }
    };
    std.mem.sort(usize, order, Ctx{ .probs = probs }, Ctx.more);

    // how many to keep
    var total: f64 = 0;
    var keep: usize = 0;
    while (keep < order.len) {
        total += probs[order[keep]];
        keep += 1;
        if (???) break;
    }

    // drop the rest, renormalize the kept ones
    for (order[keep..]) |id| ???;
    for (order[0..keep]) |id| probs[id] /= ???;
    return keep;
}

test "the example from the comment" {
    var probs = [_]f64{ 0.05, 0.3, 0.5, 0.15 };
    try std.testing.expectEqual(3, try topP(std.testing.allocator, &probs, 0.9));
    try std.testing.expectEqual(0, probs[0]);
    try std.testing.expectApproxEqAbs(0.5 / 0.95, probs[2], 1e-12);
    var s: f64 = 0;
    for (probs) |x| s += x;
    try std.testing.expectApproxEqAbs(1, s, 1e-12);
}

test "confident vs uncertain" {
    var sure = [_]f64{ 0.95, 0.02, 0.01, 0.01, 0.01 };
    try std.testing.expectEqual(1, try topP(std.testing.allocator, &sure, 0.9));
    var torn = [_]f64{0.1} ** 10;
    try std.testing.expectEqual(9, try topP(std.testing.allocator, &torn, 0.85));
}

test "p = 1 keeps everything" {
    var probs = [_]f64{ 0.25, 0.25, 0.25, 0.25 };
    try std.testing.expectEqual(4, try topP(std.testing.allocator, &probs, 1));
}
