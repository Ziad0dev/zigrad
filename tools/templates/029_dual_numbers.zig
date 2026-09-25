//
// ─── Exercise 029: derivatives for free, forward mode ──────────────────
//
// Applying the chain rule by hand is slow and easy to get wrong. Let's
// make the computer do it.
//
// The trick: carry TWO numbers through every calculation. The value, and
// its derivative with respect to x (how fast it moves when x moves):
//
//     x itself:      value = x,  deriv = 1       x moves at rate 1
//     a constant c:  value = c,  deriv = 0       constants don't move
//
// Each operation updates both parts, using rules you already know:
//
//     (a + b).deriv = a.deriv + b.deriv
//     (a * b).deriv = a.deriv * b.value + a.value * b.deriv   (product rule)
//     sin(a).deriv  = cos(a.value) * a.deriv                  (chain rule)
//     exp(a).deriv  = exp(a.value) * a.deriv                  (chain rule)
//
// Push any formula through these, and the derivative falls out at the
// end. That's *forward-mode automatic differentiation*. These pairs are
// called dual numbers.
//
// Its weakness: one pass gives the derivative with respect to ONE input.
// A neural net has millions of weights, so that would take millions of
// passes. Next exercise: reverse mode, which gets them all in one pass.
//
// YOUR TASK: finish mul, sin and exp.
//
const std = @import("std");

const Dual = struct {
    value: f64,
    deriv: f64,

    fn variable(x: f64) Dual {
        return .{ .value = x, .deriv = 1 };
    }

    fn constant(c: f64) Dual {
        return .{ .value = c, .deriv = 0 };
    }

    fn add(a: Dual, b: Dual) Dual {
        return .{ .value = a.value + b.value, .deriv = a.deriv + b.deriv };
    }

    fn mul(a: Dual, b: Dual) Dual {
        return .{ .value = a.value * b.value, .deriv = ⟪a.deriv * b.value + a.value * b.deriv|||???⟫ };
    }

    fn sin(a: Dual) Dual {
        return .{ .value = @sin(a.value), .deriv = ⟪@cos(a.value) * a.deriv|||???⟫ };
    }

    fn exp(a: Dual) Dual {
        const e = @exp(a.value);
        return .{ .value = e, .deriv = ⟪e * a.deriv|||???⟫ };
    }
};

test "x^3 + 2x at 2" {
    const x = Dual.variable(2);
    const y = x.mul(x).mul(x).add(Dual.constant(2).mul(x));
    try std.testing.expectApproxEqAbs(12.0, y.value, 1e-12);
    try std.testing.expectApproxEqAbs(14.0, y.deriv, 1e-12); // 3x^2 + 2
}

test "sin(x^2), the chain rule example" {
    const x = Dual.variable(1.5);
    const y = x.mul(x).sin();
    try std.testing.expectApproxEqAbs(@cos(2.25) * 3, y.deriv, 1e-12);
}

test "e^sin(x) * x matches the measured slope" {
    const f = struct {
        fn f(x: f64) f64 {
            return @exp(@sin(x)) * x;
        }
    }.f;
    const x0 = 0.7;
    const x = Dual.variable(x0);
    const y = x.sin().exp().mul(x);

    const h = 1e-5;
    const measured = (f(x0 + h) - f(x0 - h)) / (2 * h);
    try std.testing.expectApproxEqAbs(f(x0), y.value, 1e-12);
    try std.testing.expectApproxEqAbs(measured, y.deriv, 1e-8);
}
