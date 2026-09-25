//
// ─── Exercise 143: outliers and group-wise scales ──────────────────────
//
// One scale for a whole tensor (049) has a weakness: a single big value
// (an *outlier*) sets the scale for everyone. If one weight is 100 and the
// rest are around 0.1, the scale is 100/127 ≈ 0.8, and every small weight
// rounds to 0 or ±1 step. Their information is gone. LLMs are notorious
// for such outliers.
//
// *Group-wise* quantization gives each group of, say, 32 consecutive
// weights its own scale. The outlier only ruins its own group. The cost
// is one extra scale per group: with 4-bit weights and an f16 scale per
// 32, that's 4.5 bits per weight instead of 4. Formats like GGUF's Q4 and
// GPTQ/AWQ all do some version of this.
//
// YOUR TASK: quantize and dequantize with a scale per group.
//
const std = @import("std");

/// Quantize to [-7, 7] (4-bit symmetric), with one scale per group.
fn quantize(x: []const f32, group: usize, q: []i8, scales: []f32) void {
    var g: usize = 0;
    while (g * group < x.len) : (g += 1) {
        const chunk = x[g * group ..][0..@min(group, x.len - g * group)];
        var big: f32 = 0;
        for (chunk) |v| big = @max(big, @abs(v));
        scales[g] = ⟪if (big == 0) 1 else big / 7|||???⟫;
        for (chunk, 0..) |v, i| q[g * group + i] = @intFromFloat(@round(v / scales[g]));
    }
}

fn dequantize(q: []const i8, group: usize, scales: []const f32, out: []f32) void {
    for (q, out, 0..) |v, *o, i| o.* = ⟪@as(f32, @floatFromInt(v)) * scales[i / group]|||???⟫;
}

fn meanError(x: []const f32, group: usize) f32 {
    var q: [256]i8 = undefined;
    var s: [256]f32 = undefined;
    var back: [256]f32 = undefined;
    quantize(x, group, q[0..x.len], &s);
    dequantize(q[0..x.len], group, &s, back[0..x.len]);
    var err: f32 = 0;
    for (x, back[0..x.len]) |a, b| err += @abs(a - b) / @as(f32, @floatFromInt(x.len));
    return err;
}

test "an outlier ruins one scale, but only one group" {
    var x: [128]f32 = undefined;
    for (&x, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i))) * 0.1;
    x[5] = 100; // the outlier

    const per_tensor = meanError(&x, 128);
    const per_group = meanError(&x, 32);
    try std.testing.expect(per_group < per_tensor / 3);
}
