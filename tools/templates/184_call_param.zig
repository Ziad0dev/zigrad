//
// ─── Exercise 184: functions, as PARAM and CALL ───────────────────────
//
// 10-411's first week calls this part "lambda calculus". A function is a
// graph that uses PARAMs as placeholders for its arguments, and CALL
// applies it:
//
//     PARAM slot=0                   the function's first argument
//     CALL(body, arg0, arg1, ...)    body, with PARAM slot i meaning arg i
//
//     %x    = param [] slot=0 dtype=i32
//     %body = add (mul %x %x) 1                x * x + 1
//     %five = call %body 2                     = 5
//
// In tinygrad, every kernel is a CALL: its body is a SINK of STOREs into
// PARAM buffers, and its arguments are the real buffers (194). And since
// UOps are hash-consed, every call of the same kernel shares ONE body: you
// compile it once and launch it many times.
//
// You can run a CALL two ways:
//   * keep it, and evaluate the body with the PARAMs bound to the
//     arguments (the interpreter in 188 does this);
//   * inline it ("beta reduction"): replace each PARAM by its argument,
//     everywhere in the body, and you're left with plain ops.
//
// Replacing nodes is substitute() (tinygrad: UOp.substitute). It rebuilds
// the graph bottom-up, and a node whose srcs didn't change IS the old node,
// so only the path from a replaced node up to the root is rebuilt.
//
// One subtlety. PARAMs are positional and hash-consed: "slot 0, i32,
// scalar" is the SAME UOp in every function that has one. So a PARAM means
// "argument k of the nearest enclosing CALL", and substitute() must not
// walk into the body of a nested CALL. Its PARAMs aren't ours. (tinygrad's
// substitute and toposort take enter_calls for this, and default to not.)
// Only the nested call's arguments are ours to rewrite.
//
// YOUR TASK: finish substitute() and inlineCall().
//
const std = @import("std");

//@export substitute
const Subst = std.AutoHashMap(*const UOp, *const UOp);

/// `root`, with every key of `map` replaced by its value. `map` also
/// remembers every node done so far, so shared nodes are rebuilt once.
fn substitute(g: *Graph, root: *const UOp, map: *Subst) Error!*const UOp {
    if (map.get(root)) |done| return done;
    const src = g.alloc.alloc(*const UOp, root.src.len) catch @panic("out of memory");
    var changed = false;
    for (root.src, src, 0..) |s, *n, i| {
        if (root.op == .call and i == 0) {
            n.* = s; // a CALL's body has its own PARAMs: leave it alone
            continue;
        }
        n.* = ⟪try substitute(g, s, map)|||???⟫;
        if (n.* != s) changed = true;
    }
    const out = if (changed) ⟪try g.new(root.op, src, root.arg)|||???⟫ else root;
    map.put(root, out) catch @panic("out of memory");
    return out;
}

/// Beta reduction: the CALL's body with each PARAM replaced by its argument.
fn inlineCall(g: *Graph, c: *const UOp) Error!*const UOp {
    std.debug.assert(c.op == .call);
    const body = c.src[0];
    const args = c.src[1..];
    var map = Subst.init(g.alloc);
    for (toposort(g, body, false)) |u| {
        if (u.op != .param) continue;
        const slot = u.arg.param.slot;
        if (slot >= args.len) return g.fail("a PARAM's slot has no argument");
        map.put(u, ⟪args[slot]|||???⟫) catch @panic("out of memory");
    }
    return substitute(g, body, &map);
}
//@end

/// A tiny evaluator for scalar graphs of literals and ALU ops (183).
fn evalScalar(u: *const UOp) f64 {
    if (u.op == .constant) return switch (u.arg) {
        .int => |v| @floatFromInt(v),
        .float => |v| v,
        .boolean => |v| if (v) 1 else 0,
        else => unreachable,
    };
    if (u.op == .cast) return castValue(evalScalar(u.src[0]), u.dtype);
    var s: [3]f64 = undefined;
    for (u.src, 0..) |x, i| s[i] = evalScalar(x);
    return execAlu(u.op, u.dtype, s[0..u.src.len]);
}

const t = std.testing;

test "inline a call" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.param(0, .i32, null);
    const body = try g.add(try g.mul(x, x), g.int(1)); // x * x + 1
    const c = try g.call(body, &.{try g.cast(g.int(2), .i32)});
    try t.expectEqual(.i32, c.dtype); // a call has its body's dtype
    const flat = try inlineCall(&g, c);
    try t.expectEqual(5, evalScalar(flat));
    // inlined, it's exactly the graph you'd have written by hand
    const two = try g.cast(g.int(2), .i32);
    try t.expect(flat == try g.add(try g.mul(two, two), g.int(1)));
}

test "two arguments, used in any order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const a = g.param(0, .weakint, null);
    const b = g.param(1, .weakint, null);
    const body = try g.alu(.div, &.{ b, a }); // b DIV a
    try t.expectEqual(-4, evalScalar(try inlineCall(&g, try g.call(body, &.{ g.int(2), g.int(-7) }))));
}

test "substitute only rebuilds what changed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.param(0, .i32, null);
    const y = g.param(1, .i32, null);
    const left = try g.mul(y, y); // doesn't use x
    const root = try g.add(left, x);
    var map = Subst.init(arena.allocator());
    try map.put(x, try g.cast(g.int(3), .i32));
    const out = try substitute(&g, root, &map);
    try t.expect(out != root);
    try t.expect(out.src[0] == left); // the untouched side is the same object
    // replacing nothing gives back root itself
    var none = Subst.init(arena.allocator());
    try t.expect(try substitute(&g, root, &none) == root);
}

test "a nested call keeps its own PARAMs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const p = g.param(0, .weakint, null); // the same UOp in both functions!
    const f = try g.add(p, g.int(1)); //                      f(x) = x + 1
    const h = try g.call(f, &.{try g.mul(p, g.int(2))}); //   h(y) = f(y * 2)
    const flat = try inlineCall(&g, try g.call(h, &.{g.int(3)})); // h(3)
    // the outer PARAM became 3, the inner one is untouched: f(3 * 2)
    try t.expectEqual(.call, flat.op);
    try t.expect(flat.src[0] == f);
    try t.expectEqual(7, evalScalar(try inlineCall(&g, flat)));
}

test "calls of the same function share one body" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = g.param(0, .weakint, null);
    const square = try g.mul(x, x);
    const c1 = try g.call(square, &.{g.int(3)});
    const c2 = try g.call(try g.mul(x, x), &.{g.int(4)});
    try t.expect(c1.src[0] == c2.src[0]); // compile once, run twice
    try t.expect(try g.call(square, &.{g.int(3)}) == c1); // and the same call is the same UOp
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include dtypes

//@include uop_core

//@include uop_rules

//@include alu
