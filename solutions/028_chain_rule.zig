// Reference solution. Try the exercise in exercises/ first:
// struggling a bit is how this stuff sticks.
//
// ─── Exercise 028: the chain rule ──────────────────────────────────────
//
// Neural nets are functions inside functions inside functions. For a
// function inside another, multiply the derivatives of the layers:
//
//     (f(g(x)))' = f'(g(x)) * g'(x)
//
// Intuition: if g moves 3x as fast as x, and f moves 2x as fast as g,
// then f moves 2 * 3 = 6x as fast as x. Rates multiply.
//
// Example: h(x) = sin(x^2). Outside: sin. Inside: x^2.
//     h'(x) = cos(x^2) * 2x
//              ^^^^^^   ^^
//              outside  inside
//              (evaluated AT the inside)
//
// More layers, more factors: (f(g(k(x))))' = f'(g(k(x))) * g'(k(x)) * k'(x).
// Backpropagation (exercise 030) is exactly this product, computed
// automatically, from the outside in.
//
// The most famous example, the derivative of sigmoid (exercise 016):
//     σ(x) = 1/u  with  u = 1 + e^(-x)
//     (1/u)' = -1/u^2                        (exercise 027)
//     u'     = -e^(-x)                       (chain rule again: inside is -x)
//     σ'(x)  = -1/u^2 * -e^(-x) = e^(-x) / (1 + e^(-x))^2
//            = 1/(1 + e^(-x)) * e^(-x)/(1 + e^(-x))
//            = σ(x) * (1 - σ(x))
// (because 1 - σ = (1 + e^(-x) - 1)/(1 + e^(-x)) = e^(-x)/(1 + e^(-x))).
// So once you know σ(x), its slope costs one multiply.
//
// YOUR TASK: write each derivative using the chain rule.
//
const std = @import("std");

/// sin(x^2)
fn h1(x: f64) f64 {
    return @sin(x * x);
}
fn dH1(x: f64) f64 {
    return @cos(x * x) * 2 * x;
}

/// e^(sin x). The derivative of e^u is e^u.
fn h2(x: f64) f64 {
    return @exp(@sin(x));
}
fn dH2(x: f64) f64 {
    return @exp(@sin(x)) * @cos(x);
}

/// sqrt(1 + x^2): three layers, sqrt(u), u = 1 + v, v = x^2.
/// (Simplify: 1/(2 sqrt(u)) * 1 * 2x.)
fn h3(x: f64) f64 {
    return @sqrt(1 + x * x);
}
fn dH3(x: f64) f64 {
    return x / @sqrt(1 + x * x);
}

fn sigmoid(x: f64) f64 {
    return 1 / (1 + @exp(-x));
}
fn dSigmoid(x: f64) f64 {
    const s = sigmoid(x);
    return s * (1 - s);
}

fn centralDiff(f: *const fn (f64) f64, x: f64) f64 {
    const h = 1e-5;
    return (f(x + h) - f(x - h)) / (2 * h);
}

fn check(f: *const fn (f64) f64, df: *const fn (f64) f64) !void {
    for ([_]f64{ -2, -0.5, 0.1, 1, 1.7 }) |x| {
        try std.testing.expectApproxEqAbs(centralDiff(f, x), df(x), 1e-6);
    }
}

test "sin(x^2)" {
    try check(&h1, &dH1);
}

test "e^sin(x)" {
    try check(&h2, &dH2);
}

test "sqrt(1 + x^2)" {
    try check(&h3, &dH3);
}

test "sigmoid" {
    try check(&sigmoid, &dSigmoid);
}
