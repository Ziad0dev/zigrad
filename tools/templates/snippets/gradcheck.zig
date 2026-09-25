/// Check an analytic gradient against measured slopes (026).
/// `ctx` must have `fn loss(self) f64`, which reads `param`.
fn gradCheck(ctx: anytype, param: []f64, analytic: []const f64) !void {
    const h = 1e-6;
    for (param, analytic, 0..) |*p, g, i| {
        const orig = p.*;
        p.* = orig + h;
        const up = ctx.loss();
        p.* = orig - h;
        const down = ctx.loss();
        p.* = orig;
        const measured = (up - down) / (2 * h);
        if (@abs(measured - g) > 1e-5 * @max(1, @abs(measured))) {
            std.debug.print("gradient {d}: yours {d}, measured {d}\n", .{ i, g, measured });
            return error.WrongGradient;
        }
    }
}
