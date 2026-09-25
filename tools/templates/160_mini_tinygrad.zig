//
// ─── Exercise 160: the final capstone ──────────────────────────────────
//
// Everything, together. Below is a complete, working mini tinygrad in one
// file: lazy tensors built from 7 primitive ops (chapters 3-4), kernel
// fusion and a scheduler (040), C code printed like DEBUG=4 (042),
// autograd (030, 068), and a training loop (032, 039). The same file is
// in examples/tinygrad_in_one_file.zig, whole.
//
// Its heart has been cut out. Put it back:
//
//   * at(): how a fused kernel computes one element of mul and of expand
//     (019: expand is a stride-0 read, 073: an index that ignores i)
//   * realizeDeps(): the one rule that ends a kernel (040)
//   * backwardStep(): the rules for mul, sum and expand, and the seed of
//     backward() (030, 033: sum and expand are each other's gradients)
//
// Then run it for real:  zig run exercises/160_mini_tinygrad.zig
// It prints the kernels it generates and learns y = 2x + 1.
//
// Congratulations on making it here. Go read tinygrad.
//
const std = @import("std");

// ─── 1. The primitive ops ───────────────────────────────────────────────
//
// tinygrad's big trick: only a few dozen primitive ops exist. Everything
// else (relu, mean, softmax, conv2d...) is built by combining them, so a
// new backend (GPU, etc.) only has to know how to run the primitives.
// We use 7.

pub const Op = enum {
    load, //     a buffer that already holds numbers (inputs, weights)
    constant, // the same number at every position
    add, //      a + b        elementwise
    mul, //      a * b        elementwise
    max, //      max(a, b)    elementwise
    sum, //      add everything up -> length 1        (a "reduce" op)
    expand, //   stretch length 1 -> length n, no math (a "movement" op)
};

// ─── 2. The graph ───────────────────────────────────────────────────────
//
// Zig has no garbage collector, so something has to own the memory for
// all the tensors we create. We give the Graph an allocator; in main() it
// is an *arena*, which frees the whole graph in one shot when we are done.

pub const Graph = struct {
    alloc: std.mem.Allocator,
    count: u32 = 0, //       tensors created so far (doubles as their ids)
    kernels_run: u32 = 0,
    debug: bool = false, //  like tinygrad's DEBUG=4: print each kernel's code

    pub fn init(alloc: std.mem.Allocator) Graph {
        return .{ .alloc = alloc };
    }

    /// A tensor backed by existing memory. It is "already realized".
    pub fn fromSlice(g: *Graph, name: []const u8, data: []f32) *Tensor {
        const t = g.node(.load, &.{}, data.len);
        t.name = name;
        t.buf = data;
        return t;
    }

    /// A tensor of `len` copies of `value`. No memory is used for it.
    pub fn full(g: *Graph, len: usize, value: f32) *Tensor {
        const t = g.node(.constant, &.{}, len);
        t.value = value;
        return t;
    }

    fn node(g: *Graph, op: Op, src: []const *Tensor, len: usize) *Tensor {
        const t = g.alloc.create(Tensor) catch oom();
        t.* = .{
            .graph = g,
            .id = g.count,
            .op = op,
            .src = g.alloc.dupe(*Tensor, src) catch oom(),
            .len = len,
        };
        g.count += 1;
        return t;
    }
};

// Idiomatic Zig returns `error.OutOfMemory` to the caller. To keep lesson
// code readable (`x.mul(w).add(b)` instead of `try (try x.mul(w)).add(b)`)
// we simply crash instead.
fn oom() noreturn {
    @panic("out of memory");
}

// ─── 3. The Tensor: a node in the graph ─────────────────────────────────

pub const Tensor = struct {
    graph: *Graph,
    id: u32,
    op: Op, //                what produces this tensor
    src: []const *Tensor, //  which tensors it is computed from
    len: usize,
    value: f32 = 0, //        only used by .constant
    name: ?[]const u8 = null,
    buf: ?[]f32 = null, //    the real numbers. null = not computed yet (lazy!)
    grad: ?[]f32 = null, //   filled in by backward()

    // ── Building the graph. Note that none of these compute anything. ──

    pub fn add(a: *Tensor, b: *Tensor) *Tensor {
        return a.graph.node(.add, &.{ a, b }, sameLen(a, b));
    }
    pub fn mul(a: *Tensor, b: *Tensor) *Tensor {
        return a.graph.node(.mul, &.{ a, b }, sameLen(a, b));
    }
    pub fn max(a: *Tensor, b: *Tensor) *Tensor {
        return a.graph.node(.max, &.{ a, b }, sameLen(a, b));
    }
    pub fn sum(a: *Tensor) *Tensor {
        return a.graph.node(.sum, &.{a}, 1);
    }
    pub fn expand(a: *Tensor, len: usize) *Tensor {
        std.debug.assert(a.len == 1);
        return a.graph.node(.expand, &.{a}, len);
    }

    // ── "Composite" ops: made purely from the primitives above. ──
    // They get forward, backward and GPU support for free.

    pub fn neg(a: *Tensor) *Tensor {
        return a.mul(a.graph.full(a.len, -1));
    }
    pub fn sub(a: *Tensor, b: *Tensor) *Tensor {
        return a.add(b.neg());
    }
    pub fn relu(a: *Tensor) *Tensor {
        return a.max(a.graph.full(a.len, 0));
    }
    pub fn square(a: *Tensor) *Tensor {
        return a.mul(a);
    }
    pub fn mean(a: *Tensor) *Tensor {
        const n: f32 = @floatFromInt(a.len);
        return a.sum().mul(a.graph.full(1, 1.0 / n));
    }

    fn sameLen(a: *Tensor, b: *Tensor) usize {
        if (a.len != b.len) std.debug.panic("length {d} vs {d}: use expand() to broadcast", .{ a.len, b.len });
        return a.len;
    }

    // ─── 4. Realize: turning the lazy graph into actual work ────────────
    //
    // Kernel rule, a simpler version of tinygrad's scheduler (040):
    //   * a chain of elementwise ops (add, mul, max, expand, constant)
    //     is FUSED into one loop, with no temporary arrays in between;
    //   * a reduce (sum) needs every input before it can finish, so it
    //     ends a kernel. Whoever reads it runs as a later kernel.

    /// Compute this tensor (and whatever it needs) and return its numbers.
    pub fn realize(t: *Tensor) []f32 {
        if (t.buf) |b| return b; // already computed, or a .load
        t.realizeDeps(); // first run the earlier kernels we read from

        const g = t.graph;
        if (g.debug) t.printKernel();
        const out = g.alloc.alloc(f32, t.len) catch oom();
        if (t.op == .sum) {
            // Reduce kernel: one loop that adds up the fused input expression.
            var acc: f32 = 0;
            for (0..t.src[0].len) |i| acc += t.src[0].at(i);
            out[0] = acc;
        } else {
            // Elementwise kernel: one loop, the whole expression per element.
            for (0..t.len) |i| out[i] = t.at(i);
        }
        t.buf = out;
        g.kernels_run += 1;
        return out;
    }

    fn realizeDeps(t: *Tensor) void {
        for (t.src) |s| {
            if (s.buf != null) continue; //       has memory already
            if (s.op == .sum) {
                ⟪_ = s.realize();|||???;⟫ //               a reduce is its own kernel
            } else {
                s.realizeDeps(); //               elementwise: fused into ours
            }
        }
    }

    /// The value at position i, computed straight from the graph.
    /// Recursing like this *is* kernel fusion: for `a + b*c` we compute
    /// b[i]*c[i] and add a[i] in one go, without storing b*c anywhere.
    pub fn at(t: *Tensor, i: usize) f32 {
        if (t.buf) |b| return b[i];
        return switch (t.op) {
            .constant => t.value,
            .add => t.src[0].at(i) + t.src[1].at(i),
            .mul => ⟪t.src[0].at(i) * t.src[1].at(i)|||???⟫,
            .max => @max(t.src[0].at(i), t.src[1].at(i)),
            // Every position reads element 0. Nothing is copied: movement
            // ops only change *which index you read*. (In tinygrad this
            // index math is how reshape, permute, pad, etc. all work.)
            .expand => ⟪t.src[0].at(0)|||???⟫,
            .load => unreachable, // loads always have a buf
            .sum => @panic("a sum must be realized as its own kernel before it is read"),
        };
    }

    // ─── 5. Codegen: print the kernel as C, like tinygrad with DEBUG=4 ──
    //
    // tinygrad renders each kernel into source code (C, CUDA, Metal...),
    // hands it to a real compiler and runs the binary on the device. We
    // only print it; at() above interprets the same computation.

    fn printKernel(t: *Tensor) void {
        const g = t.graph;
        const seen = g.alloc.alloc(bool, g.count) catch oom();
        const p = std.debug.print;

        p("void kernel{d}(float* ", .{g.kernels_run});
        printName(t);
        @memset(seen, false);
        printInputs(t, seen);
        p(") {{\n", .{});

        const body = if (t.op == .sum) t.src[0] else t;
        if (t.op == .sum) p("  float acc = 0;\n", .{});
        p("  for (int i = 0; i < {d}; i++) {{\n", .{body.len});
        @memset(seen, false);
        printLines(body, seen);
        if (t.op == .sum) {
            p("    acc += ", .{});
            printRef(body);
            p(";\n  }}\n  ", .{});
            printName(t);
            p("[0] = acc;\n}}\n", .{});
        } else {
            p("    ", .{});
            printName(t);
            p("[i] = ", .{});
            printRef(t);
            p(";\n  }}\n}}\n", .{});
        }
    }

    /// Kernel arguments: every buffer the fused expression reads from.
    fn printInputs(t: *Tensor, seen: []bool) void {
        if (seen[t.id]) return;
        seen[t.id] = true;
        if (t.buf != null) {
            std.debug.print(", const float* ", .{});
            printName(t);
            return;
        }
        for (t.src) |s| printInputs(s, seen);
    }

    /// One line of C per op, in dependency order.
    fn printLines(t: *Tensor, seen: []bool) void {
        if (seen[t.id] or t.buf != null or t.op == .constant) return;
        seen[t.id] = true;
        for (t.src) |s| printLines(s, seen);
        if (t.op == .expand) return; // just indexing, no code of its own

        const p = std.debug.print;
        p("    float v{d} = ", .{t.id});
        switch (t.op) {
            .add, .mul => {
                printRef(t.src[0]);
                p("{s}", .{if (t.op == .add) " + " else " * "});
                printRef(t.src[1]);
            },
            .max => {
                p("fmaxf(", .{});
                printRef(t.src[0]);
                p(", ", .{});
                printRef(t.src[1]);
                p(")", .{});
            },
            else => unreachable,
        }
        p(";\n", .{});
    }

    fn printRef(t: *Tensor) void {
        if (t.op == .expand) return printRef(t.src[0]);
        if (t.op == .constant) return std.debug.print("{d}", .{t.value});
        if (t.buf != null) {
            printName(t);
            std.debug.print("[{s}]", .{if (t.len == 1) "0" else "i"});
        } else {
            std.debug.print("v{d}", .{t.id});
        }
    }

    fn printName(t: *Tensor) void {
        if (t.name) |n| std.debug.print("{s}", .{n}) else std.debug.print("t{d}", .{t.id});
    }

    // ─── 6. Autograd: the graph, walked backwards ───────────────────────
    //
    // backward() answers "if I nudge this input, how much does the loss
    // move?" for every tensor, using the chain rule: each op only needs
    // to know its own local derivative. We visit the graph from the loss
    // back to the inputs, so each tensor's grad is complete before it is
    // passed on to that tensor's sources.
    //
    // Simplification: real tinygrad builds the backward pass as *more lazy
    // graph*, so gradients get fused and compiled exactly like forward
    // code. Here we just compute them with plain loops.

    pub fn backward(loss: *Tensor) void {
        std.debug.assert(loss.len == 1);
        _ = loss.realize(); // forward pass first: sums must hold values

        const g = loss.graph;
        const visited = g.alloc.alloc(bool, g.count) catch oom();
        @memset(visited, false);
        var order: std.ArrayList(*Tensor) = .empty;
        topoSort(loss, visited, &order, g.alloc);

        loss.gradBuf()[0] = ⟪1|||0⟫; // d(loss)/d(loss)

        var k = order.items.len;
        while (k > 0) {
            k -= 1;
            order.items[k].backwardStep();
        }
    }

    /// Puts every tensor after the tensors it was built from.
    fn topoSort(t: *Tensor, visited: []bool, order: *std.ArrayList(*Tensor), alloc: std.mem.Allocator) void {
        if (visited[t.id]) return;
        visited[t.id] = true;
        for (t.src) |s| topoSort(s, visited, order, alloc);
        order.append(alloc, t) catch oom();
    }

    /// Pass this tensor's grad on to its sources (the chain rule).
    /// `+=` matters: in square(x) = x*x, x receives gradient twice.
    fn backwardStep(t: *Tensor) void {
        const out = t.grad orelse return;
        switch (t.op) {
            .load, .constant => {}, // leaves: nothing further back
            .add => {
                // d(a+b)/da = 1 and d(a+b)/db = 1: pass the grad through
                const a = t.src[0].gradBuf();
                const b = t.src[1].gradBuf();
                for (0..t.len) |i| {
                    a[i] += out[i];
                    b[i] += out[i];
                }
            },
            .mul => {
                // d(a*b)/da = b and d(a*b)/db = a
                const a = t.src[0];
                const b = t.src[1];
                for (0..t.len) |i| {
                    const av = a.at(i);
                    const bv = b.at(i);
                    a.gradBuf()[i] += ⟪out[i] * bv|||???⟫;
                    b.gradBuf()[i] += ⟪out[i] * av|||???⟫;
                }
            },
            .max => {
                // Only the input that "won" affects the output.
                const a = t.src[0];
                const b = t.src[1];
                for (0..t.len) |i| {
                    const av = a.at(i);
                    const bv = b.at(i);
                    const to_a: f32 = if (av > bv) 1 else if (av < bv) 0 else 0.5;
                    a.gradBuf()[i] += out[i] * to_a;
                    b.gradBuf()[i] += out[i] * (1 - to_a);
                }
            },
            .sum => {
                // Every input moved the sum by the same amount: the
                // gradient of a sum is an expand.
                const a = t.src[0].gradBuf();
                for (a) |*x| x.* += ⟪out[0]|||???⟫;
            },
            .expand => {
                // One value fed n outputs, so it collects all n gradients:
                // the gradient of an expand is a sum.
                const a = t.src[0].gradBuf();
                for (out) |x| a[0] += ⟪x|||???⟫;
            },
        }
    }

    fn gradBuf(t: *Tensor) []f32 {
        if (t.grad) |gr| return gr;
        const gr = t.graph.alloc.alloc(f32, t.len) catch oom();
        @memset(gr, 0);
        t.grad = gr;
        return gr;
    }
};

// ─── 7. Putting it together: learn y = 2x + 1 ───────────────────────────

const Model = struct { loss: *Tensor, w: *Tensor, b: *Tensor };

fn buildLoss(g: *Graph, xs: []f32, ys: []f32, w: []f32, b: []f32) Model {
    const x = g.fromSlice("x", xs);
    const y = g.fromSlice("y", ys);
    const wt = g.fromSlice("w", w);
    const bt = g.fromSlice("b", b);

    // prediction = w*x + b   (w and b have 1 value, so expand them to 4)
    const pred = x.mul(wt.expand(x.len)).add(bt.expand(x.len));
    // loss = mean((prediction - y)^2)   "how wrong are we, on average"
    const loss = pred.sub(y).square().mean();
    loss.name = "loss";
    return .{ .loss = loss, .w = wt, .b = bt };
}

pub fn main() void {
    const p = std.debug.print;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var xs = [_]f32{ 1, 2, 3, 4 };
    var ys = [_]f32{ 3, 5, 7, 9 }; // y = 2x + 1: the model must find 2 and 1
    // The weights live outside the arena: they must survive every step.
    var w = [_]f32{0};
    var b = [_]f32{0};

    {
        var g = Graph.init(arena.allocator());
        g.debug = true;

        p("── Part 1: building the graph computes nothing ──\n", .{});
        const m = buildLoss(&g, &xs, &ys, &w, &b);
        p("created {d} tensors, ran {d} kernels, loss is {s}\n\n", .{
            g.count, g.kernels_run, if (m.loss.buf == null) "not computed yet" else "computed",
        });

        p("── Part 2: realize() fuses everything into 2 kernels ──\n", .{});
        const loss = m.loss.realize()[0];
        p("loss = {d} after {d} kernels\n\n", .{ loss, g.kernels_run });
    }
    _ = arena.reset(.retain_capacity);

    p("── Part 3: training (backward + gradient descent) ──\n", .{});
    const lr: f32 = 0.05;
    for (0..501) |step| {
        // Build a fresh graph every step, throw it all away at the end.
        defer _ = arena.reset(.retain_capacity);
        var g = Graph.init(arena.allocator());
        const m = buildLoss(&g, &xs, &ys, &w, &b);
        m.loss.backward();

        if (step % 100 == 0) p("step {d:>3}  loss {d:>9.5}  w {d:.4}  b {d:.4}\n", .{ step, m.loss.buf.?[0], w[0], b[0] });

        // Step each weight a little bit downhill.
        w[0] -= lr * m.w.grad.?[0];
        b[0] -= lr * m.b.grad.?[0];
    }
    p("learned: y = {d:.3}x + {d:.3}\n", .{ w[0], b[0] });
}

// ─── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "building the graph is lazy, realize computes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    var a = [_]f32{ 1, -2, 3 };
    var c = [_]f32{ 4, 5, 6 };

    const out = g.fromSlice("a", &a).mul(g.fromSlice("c", &c)).relu();
    try testing.expectEqual(null, out.buf);
    try testing.expectEqual(0, g.kernels_run);

    try testing.expectEqualSlices(f32, &.{ 4, 0, 18 }, out.realize());
}

test "an elementwise chain is one kernel, a reduce adds one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    var x = [_]f32{ 1, 2, 3 };
    var w = [_]f32{2};

    const t = g.fromSlice("x", &x);
    const y = t.mul(g.fromSlice("w", &w).expand(3)).add(t).relu().neg();
    _ = y.realize();
    try testing.expectEqual(1, g.kernels_run);

    try testing.expectEqual(-18, y.mean().realize()[0] * 3);
    try testing.expectEqual(3, g.kernels_run);
}

test "gradients match finite differences" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var x = [_]f32{ 0.5, -1.5, 2 };
    var c = [_]f32{ 1, 1, -3 };

    // f(x) = mean(relu(x*x + c*x) - x)
    const f = struct {
        fn build(g: *Graph, xs: []f32, cs: []f32) Model {
            const xt = g.fromSlice("x", xs);
            const ct = g.fromSlice("c", cs);
            const loss = xt.square().add(ct.mul(xt)).relu().sub(xt).mean();
            return .{ .loss = loss, .w = xt, .b = ct };
        }
    }.build;

    var g = Graph.init(arena.allocator());
    const m = f(&g, &x, &c);
    m.loss.backward();

    const eps: f32 = 1e-3;
    for (0..x.len) |i| {
        const orig = x[i];
        x[i] = orig + eps;
        var g1 = Graph.init(arena.allocator());
        const up = f(&g1, &x, &c).loss.realize()[0];
        x[i] = orig - eps;
        var g2 = Graph.init(arena.allocator());
        const down = f(&g2, &x, &c).loss.realize()[0];
        x[i] = orig;

        const numeric = (up - down) / (2 * eps);
        try testing.expectApproxEqAbs(numeric, m.w.grad.?[i], 1e-2);
    }
}
