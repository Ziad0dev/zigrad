//
// ─── Exercise 164: Amdahl's law ───────────────────────────────────────
//
// You parallelized the kernel over 64 cores (162). Why isn't the whole
// program 64 times faster? Because part of it didn't get faster at all:
// loading data, launching kernels, the Python around them, one serial step
// at the end.
//
// *Amdahl's law* (1967): if a fraction s of the running time is serial and
// the rest, 1 - s, speeds up perfectly on n workers, then
//
//     speedup(n) = 1 / (s + (1 - s) / n)
//
// and however many workers you add, it can never beat 1 / s. With just 5%
// serial work, the limit is 20x: a thousand cores or a million, 20x.
//
// The same law applies to any single optimization: making a kernel that
// takes 30% of the time infinitely fast saves at most 30%. Profile first,
// then optimize what actually takes the time (176).
//
// *Gustafson's law* (1988) is the optimist's reply: with more workers
// people run BIGGER problems, and the parallel part grows while the serial
// part doesn't. If a run on n workers spends fraction s of its time
// serial, the same work would take s + (1 - s) n on one worker:
//
//     scaled speedup(n) = s + (1 - s) * n
//
// That's why training runs on thousands of GPUs make sense: they don't
// train the same model faster, they train a much bigger one.
//
// YOUR TASK: write both laws, and the cores needed for a target speedup.
//
const std = @import("std");

fn amdahl(serial: f64, n: f64) f64 {
    return ⟪1 / (serial + (1 - serial) / n)|||???⟫;
}

fn amdahlLimit(serial: f64) f64 {
    return ⟪1 / serial|||???⟫;
}

fn gustafson(serial: f64, n: f64) f64 {
    return ⟪serial + (1 - serial) * n|||???⟫;
}

/// The smallest whole number of workers reaching `target` speedup, or
/// null if Amdahl says it's impossible.
fn workersFor(serial: f64, target: f64) ?usize {
    if (target >= amdahlLimit(serial)) return null;
    var n: usize = 1;
    while (⟪amdahl(serial, @floatFromInt(n)) < target|||???⟫) n += 1;
    return n;
}

test "Amdahl" {
    try std.testing.expectApproxEqAbs(1.0, amdahl(0.05, 1), 1e-12);
    // 5% serial on 8 workers: 1 / (0.05 + 0.95 / 8)
    try std.testing.expectApproxEqAbs(5.925925925925926, amdahl(0.05, 8), 1e-9);
    try std.testing.expectApproxEqAbs(20, amdahlLimit(0.05), 1e-12);
    // a thousand workers barely beat a hundred
    try std.testing.expect(amdahl(0.05, 1000) - amdahl(0.05, 100) < 3);
    // no serial part at all: perfect scaling
    try std.testing.expectApproxEqAbs(64, amdahl(0, 64), 1e-12);
}

test "Gustafson" {
    try std.testing.expectApproxEqAbs(60.85, gustafson(0.05, 64), 1e-9);
}

test "how many workers?" {
    // 5% serial, want 10x: need 1 / (0.05 + 0.95/n) >= 10, so n >= 19
    try std.testing.expectEqual(19, workersFor(0.05, 10).?);
    try std.testing.expectEqual(null, workersFor(0.05, 20));
}
