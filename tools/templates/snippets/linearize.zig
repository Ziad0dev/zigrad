/// One instruction. Operands `a` and `b` are the numbers of earlier
/// instructions, whose results live in "registers" v0, v1, v2...
const Inst = struct {
    op: Op,
    a: usize = 0,
    b: usize = 0,
    arg: usize = 0, //   .buffer: which input buffer to load from
    value: f32 = 0, //   .constant
};

const Kernel = struct {
    insts: []const Inst,
    inputs: []const *const Node, // input buffers, in0, in1, ...
    reduce: bool, //                a sum kernel? (exercise 043)
};

/// Exercise 041: the kernel's graph as a flat list of instructions.
const Linearizer = struct {
    alloc: std.mem.Allocator,
    insts: std.ArrayList(Inst) = .empty,
    ids: std.AutoHashMap(*const Node, usize),
    inputs: std.ArrayList(*const Node) = .empty,

    fn emit(l: *Linearizer, n: *const Node) error{OutOfMemory}!usize {
        if (l.ids.get(n)) |id| return id;
        var inst: Inst = .{ .op = n.op };
        switch (n.op) {
            .buffer => {
                inst.arg = l.inputs.items.len;
                try l.inputs.append(l.alloc, n);
            },
            .constant => inst.value = n.value,
            .add, .mul, .max => {
                inst.a = try l.emit(n.src[0]);
                inst.b = try l.emit(n.src[1]);
            },
            .sum => unreachable, // a sum ends a kernel, it's never inside one
        }
        const id = l.insts.items.len;
        try l.insts.append(l.alloc, inst);
        try l.ids.put(n, id);
        return id;
    }
};

fn linearize(alloc: std.mem.Allocator, root: *const Node) !Kernel {
    var l: Linearizer = .{ .alloc = alloc, .ids = .init(alloc) };
    const reduce = root.op == .sum;
    _ = try l.emit(if (reduce) root.src[0] else root);
    return .{ .insts = l.insts.items, .inputs = l.inputs.items, .reduce = reduce };
}
