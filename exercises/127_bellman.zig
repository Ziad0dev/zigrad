//
// ─── Exercise 127: values and the Bellman equation ─────────────────────
//
// Real RL problems have STATES: actions change where you are, and rewards
// may come much later. The *value* V(s) of a state is the total reward you
// can expect from there, with future rewards discounted by γ per step
// (a reward k steps away is worth γ^k now).
//
// The *Bellman equation* says the value of a state is the best you can do
// in one step, plus the discounted value of where that lands you:
//
//     V(s) = max over actions a of [ reward(s, a) + γ V(next(s, a)) ]
//
// *Value iteration* turns that into an algorithm: start with V = 0
// everywhere, and apply the equation to every state, again and again,
// until nothing changes.
//
// Here: a corridor of 6 cells. Moving right from cell 4 into the goal
// (cell 5) gives reward 1; every other move gives 0. The goal ends the
// episode (its value stays 0). The answer: V(s) = γ^(4 - s) for s < 5.
//
// YOUR TASK: write one sweep of value iteration.
//
const std = @import("std");

const cells = 6;
const goal = 5;

fn next(s: usize, action: u1) usize {
    return if (action == 1) @min(s + 1, cells - 1) else s -| 1;
}

fn reward(s: usize, action: u1) f64 {
    return if (s + 1 == goal and action == 1) 1 else 0;
}

/// One sweep. Returns the biggest change.
fn sweep(v: *[cells]f64, gamma: f64) f64 {
    var change: f64 = 0;
    for (0..cells) |s| {
        if (s == goal) continue;
        var best: f64 = -std.math.inf(f64);
        for ([_]u1{ 0, 1 }) |a| {
            best = @max(best, ???);
        }
        change = @max(change, @abs(best - v[s]));
        ???;
    }
    return change;
}

test "value iteration on a corridor" {
    var v: [cells]f64 = @splat(0);
    const gamma = 0.9;
    while (sweep(&v, gamma) > 1e-12) {}
    for (0..goal) |s| {
        try std.testing.expectApproxEqAbs(std.math.pow(f64, gamma, @floatFromInt(4 - s)), v[s], 1e-9);
    }
}
