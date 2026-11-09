//
// ─── Exercise 190: ten tests, due Monday ──────────────────────────────
//
// Every Monday of 10-411, you hand in ten tests, two days before your
// compiler is due. Each is run against an oracle first (a wrong test is
// worth nothing), then against everyone's compilers. Every compiler is
// graded on passing ALL the tests, and a correct test that breaks OTHER
// compilers earns bonus credit. So the skill isn't just writing a
// compiler. It's thinking of the bug someone else will make, and writing
// the smallest program that exposes it.
//
// Here the "other compilers" are mutants of the interpreter you just
// finished (188, 189). Each one rewrites your program with one classic
// bug before running it:
//
//     truncDiv      DIV rounds toward zero, like C's /  (183)
//     inversePerm   PERMUTE applies the inverse of its permutation
//     reduceLast    REDUCE pops the LAST axes instead of the leading ones
//     padEnd        PAD puts the data at the far end instead of at `off`
//     ignoreAfter   AFTER is dropped, so reads don't wait for the stores
//
// A good test PASSES on the correct interpreter and FAILS on its mutant
// (a wrong value, an error, anything). Bugs like to hide: for the
// permutation [1 0] the inverse IS the permutation; padding [1 2] by one
// on each side looks the same from either end; a reduce of a single axis
// can't pick the wrong one; and 7 DIV 2 is 3 either way. Your test has to
// reach the case where the bug shows.
//
// (The mutants are graph rewrites: mutate() rebuilds the program bottom-up
// and lets the bug replace nodes as it goes, like 184's substitute.)
//
// YOUR TASK: write five UIR tests, one to catch each mutant.
//
const std = @import("std");

const Mutant = enum { none, trunc_div, inverse_perm, reduce_last, pad_end, ignore_after };

//⟪
const trunc_div_test =
    \\%q = div -7 2
    \\%t = assert %q -4
;
//|||
const trunc_div_test = ???;
//⟫

//⟪
const inverse_perm_test =
    \\%x = reshape [0 1 2 3 4 5] [1 2 3]
    \\%p = permute %x [1 2 0]
    \\%t = assert (index %p 1 2 0) 5
;
//|||
const inverse_perm_test = ???;
//⟫

//⟪
const reduce_last_test =
    \\%x = reduce (reshape [1 2 3 4 5 6] [2 3]) op=add pop=1
    \\%t = assert %x [5 7 9]
;
//|||
const reduce_last_test = ???;
//⟫

//⟪
const pad_end_test =
    \\%x = pad [1 2] [0] [3]
    \\%t = assert %x [1 2 0]
;
//|||
const pad_end_test = ???;
//⟫

//⟪
const ignore_after_test =
    \\%buf = buffer [] slot=0 dtype=i32
    \\%w = store %buf 7
    \\%t = assert (after %buf %w) 7
;
//|||
const ignore_after_test = ???;
//⟫

/// A literal shaped like `like`, so it can meet it in an ALU op (182).
fn literalLike(g: *Graph, v: i64, like: *const UOp) Error!*const UOp {
    if (like.shape.len == 0) return g.int(v);
    return g.expand(g.int(v), like.shape);
}

/// The one node a mutant changes, or u as it is.
fn applyBug(g: *Graph, u: *const UOp, bug: Mutant) Error!*const UOp {
    switch (bug) {
        .none => {},
        .trunc_div => if (u.op == .div) {
            // C's a / b: one more than floor when it's inexact and the signs differ
            const a = u.src[0];
            const b = u.src[1];
            const inexact = try g.alu(.cmpne, &.{ try g.alu(.mod, &.{ a, b }), try literalLike(g, 0, a) });
            const signs_differ = try g.alu(.xor, &.{ try g.cmplt(a, try literalLike(g, 0, a)), try g.cmplt(b, try literalLike(g, 0, b)) });
            return g.where(try g.mul(inexact, signs_differ), try g.add(u, try literalLike(g, 1, u)), u);
        },
        .inverse_perm => if (u.op == .permute) {
            const p = try g.asInts(u.src[1]);
            const inv = g.alloc.alloc(usize, p.len) catch @panic("out of memory");
            for (p, 0..) |axis, i| inv[axis] = i;
            return g.permute(u.src[0], inv);
        },
        .reduce_last => if (u.op == .reduce and u.src.len == 1) {
            const x = u.src[0];
            const pop = u.arg.reduce.pop;
            const n = x.shape.len;
            if (pop == 0 or pop == n) return u;
            // move the last `pop` axes to the front, and reduce those instead
            const perm = g.alloc.alloc(usize, n) catch @panic("out of memory");
            for (perm, 0..) |*a, i| a.* = (i + n - pop) % n;
            return g.reduce(try g.permute(x, perm), u.arg.reduce.op, pop);
        },
        .pad_end => if (u.op == .pad) {
            const offsets = try g.asInts(u.src[1]);
            const sizes = try g.asInts(u.src[2]);
            const flipped = g.alloc.alloc(usize, offsets.len) catch @panic("out of memory");
            for (flipped, offsets, sizes, u.src[0].shape) |*f, off, size, n| f.* = size - n - off;
            return g.pad(u.src[0], flipped, sizes);
        },
        .ignore_after => if (u.op == .after) return u.src[0],
    }
    return u;
}

/// The program with the bug in it, rebuilt bottom-up.
fn mutate(g: *Graph, root: *const UOp, bug: Mutant) Error!*const UOp {
    var done = Subst.init(g.alloc);
    for (toposort(g, root, true)) |u| {
        const src = g.alloc.alloc(*const UOp, u.src.len) catch @panic("out of memory");
        for (u.src, src) |s, *n| n.* = done.get(s) orelse s;
        const rebuilt = try g.new(u.op, src, u.arg);
        done.put(u, try applyBug(g, rebuilt, bug)) catch @panic("out of memory");
    }
    return done.get(root).?;
}

/// Does the program pass, with this bug in the compiler?
fn passes(text: []const u8, bug: Mutant) bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    var it = Interp.init(&g);
    const lines = parseLines(&g, text) catch return false;
    for (lines, 0..) |line, i| {
        if (line.op != .assert and i != lines.len - 1) continue;
        const buggy = mutate(&g, line, bug) catch return false;
        _ = it.eval(buggy) catch return false;
    }
    return true;
}

fn expectCatches(text: []const u8, bug: Mutant) !void {
    if (std.mem.indexOf(u8, text, "assert") == null) return error.TestHasNoAssert;
    if (!passes(text, .none)) {
        std.debug.print("this test fails on the CORRECT interpreter:\n{s}\n", .{text});
        return error.TestIsWrong;
    }
    if (passes(text, bug)) {
        std.debug.print("the {s} mutant passes this test:\n{s}\n", .{ @tagName(bug), text });
        return error.MutantSurvived;
    }
}

test "the bugs hide: each of these passes on its mutant" {
    try std.testing.expect(passes("%q = div 7 2\n%t = assert %q 3", .trunc_div)); // same either way
    try std.testing.expect(passes("%p = permute (reshape [1 2 3 4] [2 2]) [1 0]\n%t = assert (index %p 0 1) 3", .inverse_perm));
    try std.testing.expect(passes("%x = reduce [1 2 3] op=add pop=1\n%t = assert %x 6", .reduce_last));
    try std.testing.expect(passes("%x = pad [1 2] [1] [4]\n%t = assert %x [0 1 2 0]", .pad_end));
}

test "catch truncating division" {
    try expectCatches(trunc_div_test, .trunc_div);
}

test "catch the inverse permutation" {
    try expectCatches(inverse_perm_test, .inverse_perm);
}

test "catch reducing the wrong end" {
    try expectCatches(reduce_last_test, .reduce_last);
}

test "catch padding the wrong end" {
    try expectCatches(pad_end_test, .pad_end);
}

test "catch a read that doesn't wait for its store" {
    try expectCatches(ignore_after_test, .ignore_after);
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

//@include substitute

//@include uir_parse

//@include interp

//@include interp_movement
