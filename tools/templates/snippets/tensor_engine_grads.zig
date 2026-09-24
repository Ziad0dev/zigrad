fn passGrad(t: *Tensor) void {
    switch (t.op) {
        .leaf => {},
        .matmul => {
            const a = t.a.?;
            const b = t.b.?;
            // dA = dC · Bᵀ, dB = Aᵀ · dC
            for (0..a.rows) |i| {
                for (0..a.cols) |k| {
                    for (0..b.cols) |j| {
                        a.grad[i * a.cols + k] += t.grad[i * t.cols + j] * b.at(k, j);
                        b.grad[k * b.cols + j] += a.at(i, k) * t.grad[i * t.cols + j];
                    }
                }
            }
        },
        .add_bias => {
            const x = t.a.?;
            const bias = t.b.?;
            for (0..t.rows) |i| {
                for (0..t.cols) |j| {
                    x.grad[i * t.cols + j] += t.grad[i * t.cols + j];
                    bias.grad[j] += t.grad[i * t.cols + j];
                }
            }
        },
        .relu => {
            const x = t.a.?;
            for (x.grad, x.data, t.grad) |*g, v, dg| {
                if (v > 0) g.* += dg;
            }
        },
        .sum => {
            const x = t.a.?;
            for (x.grad) |*g| g.* += t.grad[0];
        },
        .mul => {
            const a = t.a.?;
            const b = t.b.?;
            for (a.grad, b.grad, a.data, b.data, t.grad) |*ga, *gb, x, y, dg| {
                ga.* += dg * y;
                gb.* += dg * x;
            }
        },
    }
}
