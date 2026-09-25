/// The smallest and largest value n can take (exercise 071).
fn bounds(n: *const Node) [2]i64 {
    switch (n.op) {
        .constant => return .{ n.value, n.value },
        .variable => return .{ n.lo, n.hi },
        .add => {
            const a = bounds(n.src[0]);
            const b = bounds(n.src[1]);
            return .{ a[0] + b[0], a[1] + b[1] };
        },
        .mul => {
            const a = bounds(n.src[0]);
            const b = bounds(n.src[1]);
            const p = [_]i64{ a[0] * b[0], a[0] * b[1], a[1] * b[0], a[1] * b[1] };
            return .{ @min(@min(p[0], p[1]), @min(p[2], p[3])), @max(@max(p[0], p[1]), @max(p[2], p[3])) };
        },
        .idiv => {
            const a = bounds(n.src[0]);
            const d = n.src[1].value; // a positive constant
            return .{ @divFloor(a[0], d), @divFloor(a[1], d) };
        },
        .mod => {
            const a = bounds(n.src[0]);
            const d = n.src[1].value;
            if (a[0] >= 0 and a[1] < d) return a;
            return .{ 0, d - 1 };
        },
    }
}
