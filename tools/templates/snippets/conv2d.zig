const Conv2d = struct {
    cin: usize,
    cout: usize,
    k: usize, //      square kernel, k x k
    stride: usize = 1,
    pad: usize = 0,

    fn outSize(c: Conv2d, size: usize) usize {
        return (size + 2 * c.pad - c.k) / c.stride + 1;
    }

    /// x is [cin, h, w]. cols is [cin*k*k, oh*ow]: column p holds the
    /// window that output pixel p sees, zeros where it hangs off the edge.
    fn im2col(c: Conv2d, x: []const f64, h: usize, w: usize, cols: []f64) void {
        const oh = c.outSize(h);
        const ow = c.outSize(w);
        for (0..c.cin) |ch| {
            for (0..c.k) |i| {
                for (0..c.k) |j| {
                    const row = (ch * c.k + i) * c.k + j;
                    for (0..oh) |oy| {
                        for (0..ow) |ox| {
                            // where this tap lands in the (unpadded) input
                            const y = @as(isize, @intCast(oy * c.stride + i)) - @as(isize, @intCast(c.pad));
                            const xx = @as(isize, @intCast(ox * c.stride + j)) - @as(isize, @intCast(c.pad));
                            const inside = y >= 0 and y < h and xx >= 0 and xx < w;
                            cols[row * (oh * ow) + oy * ow + ox] = if (inside)
                                x[(ch * h + @as(usize, @intCast(y))) * w + @as(usize, @intCast(xx))]
                            else
                                0;
                        }
                    }
                }
            }
        }
    }

    /// weight is [cout, cin*k*k]; out is [cout, oh*ow] = weight · cols.
    fn forward(c: Conv2d, weight: []const f64, x: []const f64, h: usize, w: usize, cols: []f64, out: []f64) void {
        c.im2col(x, h, w, cols);
        const p = c.outSize(h) * c.outSize(w);
        const r = c.cin * c.k * c.k;
        for (0..c.cout) |co| {
            for (0..p) |q| {
                var acc: f64 = 0;
                for (0..r) |t| acc += weight[co * r + t] * cols[t * p + q];
                out[co * p + q] = acc;
            }
        }
    }
};
