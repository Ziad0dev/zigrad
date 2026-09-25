// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 126: multi-armed bandits ─────────────────────────────────
//
// Chapter 24: reinforcement learning (RL). No labels here: an agent takes
// ACTIONS and receives REWARDS, and must discover which actions pay off.
//
// The simplest setting: a row of slot machines ("one-armed bandits"),
// each paying out with its own unknown average. The core dilemma is
// *exploration vs exploitation*: keep pulling the best-looking arm, or try
// others that might be better?
//
// ε-greedy: with probability ε pick a random arm (explore), otherwise pick
// the arm with the best estimate so far (exploit).
//
// Each arm's estimate Q is the average of its rewards, updated
// incrementally (no need to store every reward):
//
//     n += 1
//     Q += (reward - Q) / n
//
// "Move the estimate toward the new sample, by 1/n of the gap." Every RL
// value update you'll see has this shape: old + step * (target - old).
//
// YOUR TASK: write the incremental average and the ε-greedy choice.
//
const std = @import("std");

const arms = 5;
const true_means = [arms]f64{ 0.2, 0.5, 0.35, 0.8, 0.6 };

const Agent = struct {
    q: [arms]f64 = @splat(0),
    n: [arms]f64 = @splat(0),
    epsilon: f64,

    fn choose(a: Agent, rand: std.Random) usize {
        if (rand.float(f64) < a.epsilon) return rand.uintLessThan(usize, arms);
        var best: usize = 0;
        for (a.q, 0..) |v, i| {
            if (v > a.q[best]) best = i;
        }
        return best;
    }

    fn learn(a: *Agent, arm: usize, reward: f64) void {
        a.n[arm] += 1;
        a.q[arm] += (reward - a.q[arm]) / a.n[arm];
    }
};

test "the incremental average is the average" {
    var a: Agent = .{ .epsilon = 0 };
    for ([_]f64{ 1, 0, 0, 1, 1 }) |r| a.learn(2, r);
    try std.testing.expectApproxEqAbs(0.6, a.q[2], 1e-12);
}

test "ε-greedy finds the best arm" {
    var prng = std.Random.DefaultPrng.init(126);
    const rand = prng.random();
    var a: Agent = .{ .epsilon = 0.1 };
    var pulls_of_best: usize = 0;
    for (0..5000) |step| {
        const arm = a.choose(rand);
        const reward: f64 = if (rand.float(f64) < true_means[arm]) 1 else 0;
        a.learn(arm, reward);
        if (step >= 4000 and arm == 3) pulls_of_best += 1;
    }
    try std.testing.expectApproxEqAbs(0.8, a.q[3], 0.05);
    try std.testing.expect(pulls_of_best > 850); // mostly exploiting by the end
}

test "pure greed can get stuck" {
    // with ε = 0 and all estimates starting at 0, the agent keeps pulling
    // whatever first paid off, and never tries the rest
    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();
    var a: Agent = .{ .epsilon = 0 };
    for (0..1000) |_| {
        const arm = a.choose(rand);
        a.learn(arm, if (rand.float(f64) < true_means[arm]) 1 else 0);
    }
    var never_tried: usize = 0;
    for (a.n) |c| {
        if (c == 0) never_tried += 1;
    }
    try std.testing.expect(never_tried >= 3);
}
