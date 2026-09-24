fn softmaxInPlace(row: []f64) void {
    var m: f64 = -std.math.inf(f64);
    for (row) |v| m = @max(m, v);
    var total: f64 = 0;
    for (row) |*v| {
        v.* = @exp(v.* - m);
        total += v.*;
    }
    for (row) |*v| v.* /= total;
}

fn dot(a: []const f64, b: []const f64) f64 {
    var acc: f64 = 0;
    for (a, b) |x, y| acc += x * y;
    return acc;
}

/// Plain causal attention (exercise 091), to check against.
/// q, k: [t, d]; v: [t, dv]; out: [t, dv].
fn causalAttention(q: []const f64, k: []const f64, v: []const f64, t: usize, d: usize, dv: usize, out: []f64) void {
    var scores: [64]f64 = undefined;
    for (0..t) |i| {
        for (0..t) |j| {
            scores[j] = if (j > i) -std.math.inf(f64) else dot(q[i * d ..][0..d], k[j * d ..][0..d]) / @sqrt(@as(f64, @floatFromInt(d)));
        }
        softmaxInPlace(scores[0..t]);
        for (0..dv) |c| {
            var acc: f64 = 0;
            for (0..t) |j| acc += scores[j] * v[j * dv + c];
            out[i * dv + c] = acc;
        }
    }
}
