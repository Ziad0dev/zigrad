//
// ─── Exercise 027: the rules ───────────────────────────────────────────
//
// Measuring slopes is slow and inexact. For each primitive op there's an
// exact formula for its derivative instead. These are the ones tinygrad
// needs:
//
//   x^2      ->  2x            Power rule: (x^n)' = n * x^(n-1).
//                              Check: at x = 3 the slope is 6, like
//                              exercise 026 measured.
//
//   1/x      ->  -1/x^2        Power rule with n = -1:  x^(-1) -> -x^(-2).
//
//   sqrt(x)  ->  1/(2 sqrt(x)) Power rule with n = 1/2: x^(1/2) -> (1/2) x^(-1/2).
//
//   2^x      ->  2^x * ln 2    e^x is its own derivative, and
//                              2^x = e^(x ln 2), which adds a factor ln 2.
//
//   log2(x)  ->  1/(x ln 2)    ln(x) has derivative 1/x, and
//                              log2(x) = ln(x) / ln 2.
//
//   sin(x)   ->  cos(x)        The slope of a sine wave is a cosine wave:
//                              steepest where sin crosses 0, flat at its peaks.
//
// tinygrad stores exactly this kind of table: for each primitive op, how
// to compute its gradient. Everything else gets gradients by combining
// these (next exercise).
//
// YOUR TASK: write each derivative. The test compares them against
// measured slopes.
//
const std = @import("std");

fn square(x: f64) f64 {
    return x * x;
}
fn dSquare(x: f64) f64 {
    return ⟪2 * x|||???⟫;
}

fn recip(x: f64) f64 {
    return 1 / x;
}
fn dRecip(x: f64) f64 {
    return ⟪-1 / (x * x)|||???⟫;
}

fn sqrt(x: f64) f64 {
    return @sqrt(x);
}
fn dSqrt(x: f64) f64 {
    return ⟪1 / (2 * @sqrt(x))|||???⟫;
}

fn exp2(x: f64) f64 {
    return @exp2(x);
}
fn dExp2(x: f64) f64 {
    return ⟪@exp2(x) * std.math.ln2|||???⟫;
}

fn log2(x: f64) f64 {
    return @log2(x);
}
fn dLog2(x: f64) f64 {
    return ⟪1 / (x * std.math.ln2)|||???⟫;
}

fn sin(x: f64) f64 {
    return @sin(x);
}
fn dSin(x: f64) f64 {
    return ⟪@cos(x)|||???⟫;
}

fn centralDiff(f: *const fn (f64) f64, x: f64) f64 {
    const h = 1e-5;
    return (f(x + h) - f(x - h)) / (2 * h);
}

const Rule = struct {
    name: []const u8,
    f: *const fn (f64) f64,
    df: *const fn (f64) f64,
};

const rules = [_]Rule{
    .{ .name = "square", .f = &square, .df = &dSquare },
    .{ .name = "recip", .f = &recip, .df = &dRecip },
    .{ .name = "sqrt", .f = &sqrt, .df = &dSqrt },
    .{ .name = "exp2", .f = &exp2, .df = &dExp2 },
    .{ .name = "log2", .f = &log2, .df = &dLog2 },
    .{ .name = "sin", .f = &sin, .df = &dSin },
};

test "every rule matches the measured slope" {
    for (rules) |r| {
        for ([_]f64{ 0.3, 1, 2.5, 7 }) |x| {
            const measured = centralDiff(r.f, x);
            const claimed = r.df(x);
            if (@abs(measured - claimed) > 1e-6 * @max(1, @abs(measured))) {
                std.debug.print("{s}'({d}): your rule says {d}, the slope is {d}\n", .{ r.name, x, claimed, measured });
                return error.WrongDerivative;
            }
        }
    }
}
