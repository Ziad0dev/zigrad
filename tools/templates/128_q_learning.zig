//
// ─── Exercise 128: Q-learning ──────────────────────────────────────────
//
// Value iteration (127) needs to KNOW the rules: next() and reward(). In
// real problems you usually don't. *Q-learning* learns by trying things.
//
// Q(s, a) estimates the value of taking action a in state s (and acting
// well afterwards). After each real step s --a--> s' with reward r:
//
//     target = r + γ * max over a' of Q(s', a')     (Bellman, from ONE sample)
//     Q(s, a) += lr * (target - Q(s, a))            (126's update shape)
//
// This is *temporal-difference* learning: nudge a guess toward a slightly
// better guess. With enough exploration (ε-greedy, 126), Q converges to
// the true values. DeepMind's DQN (2013) replaced the Q table with a
// neural network and learned Atari games from pixels.
//
// YOUR TASK: write the Q-learning update.
//
const std = @import("std");

const cells = 6;
const goal = 5;

fn next(s: usize, action: usize) usize {
    return if (action == 1) @min(s + 1, cells - 1) else s -| 1;
}

fn reward(s: usize, action: usize) f64 {
    return if (s + 1 == goal and action == 1) 1 else 0;
}

const Q = [cells][2]f64;

fn update(q: *Q, s: usize, a: usize, r: f64, s2: usize, gamma: f64, lr: f64) void {
    const future = if (s2 == goal) 0 else @max(q[s2][0], q[s2][1]);
    const target = ⟪r + gamma * future|||???⟫;
    q[s][a] += ⟪lr * (target - q[s][a])|||???⟫;
}

test "Q-learning learns the corridor from experience" {
    var q: Q = @splat(@splat(0));
    var prng = std.Random.DefaultPrng.init(128);
    const rand = prng.random();
    const gamma = 0.9;
    for (0..2000) |_| { // episodes
        var s = rand.uintLessThan(usize, goal);
        while (s != goal) {
            // ε-greedy, with random tie-breaking
            const a: usize = if (rand.float(f64) < 0.3 or q[s][0] == q[s][1])
                rand.uintLessThan(usize, 2)
            else if (q[s][1] > q[s][0]) 1 else 0;
            const s2 = next(s, a);
            update(&q, s, a, reward(s, a), s2, gamma, 0.2);
            s = s2;
        }
    }
    for (0..goal) |s| {
        try std.testing.expect(q[s][1] > q[s][0]); // "go right" learned everywhere
        try std.testing.expectApproxEqAbs(std.math.pow(f64, gamma, @floatFromInt(4 - s)), q[s][1], 0.02);
    }
}
