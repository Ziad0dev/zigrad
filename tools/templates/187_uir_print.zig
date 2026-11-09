//
// ─── Exercise 187: printing UIR ───────────────────────────────────────
//
// The other direction: a UOp graph back to text (tinygrad: render_uir).
// You need it all the time: to write tests, to dump what your compiler did
// to a graph (tinygrad prints this with DEBUG=5), to diff two versions.
//
// The recipe:
//   1. toposort the graph (023), so every UOp comes after its srcs;
//   2. give each one a line, %0, %1, ..., in that order;
//   3. write srcs as %ids, then the args as key=value.
//
// Except that literals don't get lines. A CONST is written in place, and
// so is a STACK whose srcs are all CONSTs: `[0 1 2]`. That's what keeps
// UIR short enough to read. (A STACK of STACKs gets a line; its inner
// STACKs are inline.)
//
// A float must still look like a float when it comes back: 100.0 printed
// as "100" would be parsed as the int 100, a weakint (181). So a float
// that has no '.', 'e', "inf" or "nan" in its digits gets a ".0".
//
// Args, in tinygrad's order: a buffer's `slot=0 dtype=f32`, a range's
// `slot=0`, a reduce's `op=add`, plus ` pop=n` only when n isn't 0, and a
// cast's `dtype=i32`.
//
// Since UOps are hash-consed, parse(print(x)) is x itself: the very same
// pointer. That's the test.
//
// YOUR TASK: finish isInline(), the float rule, the reduce args, and the
// inline STACK in writeSrc().
//
const std = @import("std");

//@export uir_print
/// Literals are written in place: a CONST, or a STACK of CONSTs.
fn isInline(u: *const UOp) bool {
    if (u.op == .constant) return true;
    if (u.op != .stack) return false;
    for (u.src) |s| {
        if (⟪s.op != .constant|||???⟫) return false;
    }
    return true;
}

fn writeLiteral(u: *const UOp, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (u.arg) {
        .int => |v| try w.print("{d}", .{v}),
        .boolean => |v| try w.writeAll(if (v) "true" else "false"),
        .float => |v| {
            if (std.math.isNan(v)) return w.writeAll("nan");
            if (std.math.isInf(v)) return w.writeAll(if (v > 0) "inf" else "-inf");
            var buf: [64]u8 = undefined;
            const digits = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
            try w.writeAll(digits);
            // 100.0 must not come back as the int 100
            if (⟪std.mem.indexOfAny(u8, digits, ".e") == null|||???⟫) try w.writeAll(".0");
        },
        else => unreachable,
    }
}

const Ids = std.AutoHashMap(*const UOp, usize);

fn writeSrc(u: *const UOp, ids: *const Ids, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (ids.get(u)) |id| return w.print("%{d}", .{id});
    if (u.op == .constant) return writeLiteral(u, w);
    // an inline STACK: [a b c]
    try w.writeAll("[");
    for (u.src, 0..) |s, i| {
        if (i > 0) try w.writeAll(" ");
        ⟪try writeSrc(s, ids, w);|||???;⟫
    }
    try w.writeAll("]");
}

fn writeArgs(u: *const UOp, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (u.op) {
        .buffer, .param, .alloc => try w.print(" slot={d} dtype={s}", .{ u.arg.param.slot, @tagName(u.arg.param.dtype) }),
        .range => try w.print(" slot={d}", .{u.arg.int}),
        .cast => try w.print(" dtype={s}", .{@tagName(u.arg.dtype)}),
        .reduce => {
            try w.print(" op={s}", .{@tagName(u.arg.reduce.op)});
            if (⟪u.arg.reduce.pop != 0|||???⟫) try w.print(" pop={d}", .{u.arg.reduce.pop});
        },
        else => {},
    }
}

/// One line per UOp: %id = op srcs key=value. (tinygrad: render_uir)
fn printUir(g: *Graph, root: *const UOp, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var ids = Ids.init(g.alloc);
    for (toposort(g, root, true)) |u| {
        if (isInline(u)) continue;
        const id = ids.count();
        try w.print("%{d} = {s}", .{ id, @tagName(u.op) });
        for (u.src) |s| {
            try w.writeAll(" ");
            try writeSrc(s, &ids, w);
        }
        try writeArgs(u, w);
        try w.writeAll("\n");
        ids.put(u, id) catch @panic("out of memory");
    }
    // a root that is a literal has no line of its own: give it one
    if (isInline(root)) {
        try w.print("%{d} = ", .{ids.count()});
        try writeSrc(root, &ids, w);
        try w.writeAll("\n");
    }
}
//@end

const t = std.testing;

fn printed(g: *Graph, root: *const UOp) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(g.alloc);
    try printUir(g, root, &out.writer);
    return out.written();
}

test "week 3, printed the way tinygrad prints it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const root = try parseUir(&g,
        \\%buf = buffer 3 slot=0 dtype=i32
        \\%i = range 3 slot=0
        \\%write = store (index %buf %i) %i
        \\%done = end %write %i
        \\%test = assert (after %buf %done) [0 1 2]
    );
    try t.expectEqualStrings(
        \\%0 = buffer 3 slot=0 dtype=i32
        \\%1 = range 3 slot=0
        \\%2 = index %0 %1
        \\%3 = store %2 %1
        \\%4 = end %3 %1
        \\%5 = after %0 %4
        \\%6 = assert %5 [0 1 2]
        \\
    , try printed(&g, root));
}

test "args and literals" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const x = try g.reshape(g.buffer(1, .f32, 6), &.{ 2, 3 });
    try t.expectEqualStrings(
        \\%0 = buffer 6 slot=1 dtype=f32
        \\%1 = reshape %0 [2 3]
        \\%2 = reduce %1 op=max pop=1
        \\%3 = reduce %2 op=add
        \\
    , try printed(&g, try g.reduce(try g.reduce(x, .max, 1), .add, 0)));
    try t.expectEqualStrings("%0 = add 100.0 0.5\n", try printed(&g, try g.add(g.float(100), g.float(0.5))));
    try t.expectEqualStrings("%0 = add -inf 7\n", try printed(&g, try g.add(g.float(-std.math.inf(f64)), g.int(7))));
    try t.expectEqualStrings("%0 = cast true dtype=i32\n", try printed(&g, try g.cast(g.boolean(true), .i32)));
    try t.expectEqualStrings("%0 = [1 2 3]\n", try printed(&g, g.ints(&.{ 1, 2, 3 })));
    try t.expectEqualStrings("%0 = stack [1 2] [3 4]\n", try printed(&g, try g.stack(&.{ g.ints(&.{ 1, 2 }), g.ints(&.{ 3, 4 }) })));
}

test "parse(print(x)) is x" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const programs = [_][]const u8{
        "%sum = add 2 3\n%test = assert %sum 5",
        "%buf = buffer [] slot=0 dtype=i32\n%w = store %buf 7\n%r = after %buf %w\n%v = load %r\n%t = assert %v 7",
        "%values = add [1 2 3] (expand 1 3)\n%sum = reduce %values op=add pop=1\n%test = assert %sum 9",
        "%m = reshape [1 2 3 4] [2 2]\n%tr = permute %m [1 0]\n%test = assert (index %tr 1 0) 2",
        "%x = pad (shrink [1.5 2.5 3.5] [1] [2]) [1] [4]\n%y = where (cmplt %x (expand 2.0 4)) %x (expand 0.1 4)",
        "%b = buffer 8 slot=2 dtype=f32\n%c = cast (load (index %b 3)) dtype=i32\n%d = add %c 0x10",
    };
    for (programs) |text| {
        const root = try parseUir(&g, text);
        try t.expect(try parseUir(&g, try printed(&g, root)) == root);
    }
}

// ─── Finished code from earlier exercises ─────────────────────────────
//
// Everything below is code you finished in earlier exercises, pasted in
// whole so this file compiles on its own. You don't need to read it
// again: this exercise is everything above.

//@include dtypes

//@include uop_core

//@include uop_rules

//@include uir_parse
