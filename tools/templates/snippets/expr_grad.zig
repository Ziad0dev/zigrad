/// d(root)/d(wrt), as a new graph (exercise 069).
fn grad(g: *Graph, root: *const Node, wrt: *const Node) !*const Node {
    var visited = std.AutoHashMap(*const Node, void).init(g.alloc);
    var order: std.ArrayList(*const Node) = .empty;
    try toposort(g.alloc, root, &visited, &order);

    var bp: Backprop = .{ .g = g, .grads = .init(g.alloc) };
    try bp.grads.put(root, g.constant(1));
    var i = order.items.len;
    while (i > 0) {
        i -= 1;
        const n = order.items[i];
        const out = bp.grads.get(n) orelse continue;
        switch (n.op) {
            .constant, .variable => {},
            .add => {
                try bp.acc(n.src[0], out);
                try bp.acc(n.src[1], out);
            },
            .mul => {
                try bp.acc(n.src[0], g.mul(out, n.src[1]));
                try bp.acc(n.src[1], g.mul(out, n.src[0]));
            },
            .sin => try bp.acc(n.src[0], g.mul(out, g.cos(n.src[0]))),
            .cos => try bp.acc(n.src[0], g.mul(out, g.mul(g.constant(-1), g.sin(n.src[0])))),
        }
    }
    return simplify(g, bp.grads.get(wrt) orelse g.constant(0));
}

const Backprop = struct {
    g: *Graph,
    grads: std.AutoHashMap(*const Node, *const Node),

    /// grads[n] += more  (as graph nodes)
    fn acc(bp: *Backprop, n: *const Node, more: *const Node) !void {
        const sum = if (bp.grads.get(n)) |existing| bp.g.add(existing, more) else more;
        try bp.grads.put(n, sum);
    }
};
