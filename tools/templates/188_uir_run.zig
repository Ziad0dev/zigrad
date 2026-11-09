//
// ─── Exercise 188: running UIR: memory and loops ──────────────────────
//
// 10-411's week 1 asks for a rewrite engine that can "run" programs as an
// interpreter. It's also your oracle (project/README.md): the slow, obvious
// program every compiled result gets checked against. tinygrad has one
// too, its PYTHON device (043). This one runs UIR (186) directly.
//
// Values are tensors: a dtype, a shape and the numbers, row-major (183's
// f64s). Most ops are a few lines on those. The interesting ones are the
// ones with EFFECTS, from 10-411's weeks 2 and 3:
//
//   BUFFER     memory, zeros until something stores to it. Read like a
//              value, it gives its whole contents.
//   INDEX      into a buffer: one element of it, at that index. Reading
//              or writing outside the buffer is an error (185 checked this
//              at compile time; here it's checked as it happens).
//   STORE      writes src[1] into src[0] (a buffer, or an INDEX into one),
//              committing the value to the buffer's dtype (181).
//   AFTER      AFTER(buf, store, ...) is buf, once the stores have run.
//              It's the ONLY thing that orders a read after a write. Read
//              a written buffer through its AFTER, not the bare BUFFER.
//   RANGE      a loop counter. It only has a value inside its loop.
//   END        END(body, r0, r1, ...) runs body once for every value of
//              the ranges: r0 outermost, the last range innermost.
//
// Every value is computed once and remembered. Except inside a loop: a
// value that depends on a running RANGE (an "open" range, tinygrad's
// UOp.ranges) must be recomputed every time round. So there are two
// memos: `fixed`, kept for good, and `varying`, cleared at every step of
// every loop. END closes its ranges: once the loop is done, END's result
// no longer depends on them.
//
// A CALL is run by inlining it (184). The movement ops and REDUCE come in
// 189.
//
// YOUR TASK: finish place() (an INDEX into memory), write(), and the AFTER,
// END and ASSERT cases of compute().
//
const std = @import("std");

//@export interp
const Value = struct {
    dtype: DType,
    shape: []const usize,
    data: []f64,

    fn scalar(v: Value) f64 {
        std.debug.assert(v.data.len == 1);
        return v.data[0];
    }
};

const RunError = Error || error{ AssertFailed, OutOfBounds, Unbound };

/// Where a read or a write goes: a whole buffer, or one element of it.
const Place = struct { buf: *const UOp, mem: []f64, offset: usize, whole: bool };

const Interp = struct {
    g: *Graph,
    memory: std.AutoHashMap(*const UOp, []f64), //   each BUFFER's and ALLOC's numbers
    loops: std.AutoHashMap(*const UOp, i64), //      the current value of each running RANGE
    fixed: std.AutoHashMap(*const UOp, Value), //    values no running RANGE can change
    varying: std.AutoHashMap(*const UOp, Value), //  values in the current loop step
    open: std.AutoHashMap(*const UOp, []const *const UOp),
    why: []const u8 = "",

    fn init(g: *Graph) Interp {
        return .{
            .g = g,
            .memory = .init(g.alloc),
            .loops = .init(g.alloc),
            .fixed = .init(g.alloc),
            .varying = .init(g.alloc),
            .open = .init(g.alloc),
        };
    }

    fn fail(it: *Interp, err: RunError, why: []const u8) RunError {
        it.why = why;
        return err;
    }

    /// The numbers of a BUFFER or ALLOC: zeros, the first time.
    fn storage(it: *Interp, buf: *const UOp) []f64 {
        const gop = it.memory.getOrPut(buf) catch @panic("out of memory");
        if (!gop.found_existing) {
            gop.value_ptr.* = it.g.alloc.alloc(f64, prod(buf.shape)) catch @panic("out of memory");
            @memset(gop.value_ptr.*, 0);
        }
        return gop.value_ptr.*;
    }

    /// The RANGEs u depends on that nothing has closed. (tinygrad: UOp.ranges)
    fn openRanges(it: *Interp, u: *const UOp) []const *const UOp {
        if (it.open.get(u)) |r| return r;
        var out: std.ArrayList(*const UOp) = .empty;
        if (u.op == .range) out.append(it.g.alloc, u) catch @panic("out of memory");
        for (u.src, 0..) |s, i| {
            if (u.op == .call and i == 0) continue; // a CALL's body is its own world
            for (it.openRanges(s)) |r| {
                if (std.mem.indexOfScalar(*const UOp, out.items, r) == null) out.append(it.g.alloc, r) catch @panic("out of memory");
            }
        }
        // END, STAGE and a REDUCE over ranges close the ranges in src[1..]
        const closes = u.op == .end or u.op == .stage or (u.op == .reduce and u.src.len > 1);
        if (closes) {
            var i: usize = 0;
            while (i < out.items.len) {
                if (std.mem.indexOfScalar(*const UOp, u.src[1..], out.items[i]) != null) {
                    _ = out.orderedRemove(i);
                } else i += 1;
            }
        }
        it.open.put(u, out.items) catch @panic("out of memory");
        return out.items;
    }

    fn eval(it: *Interp, u: *const UOp) RunError!Value {
        if (it.fixed.get(u)) |v| return v;
        if (it.varying.get(u)) |v| return v;
        const v = try it.compute(u);
        const memo = if (it.openRanges(u).len == 0) &it.fixed else &it.varying;
        memo.put(u, v) catch @panic("out of memory");
        return v;
    }

    fn alloc(it: *Interp, dtype: DType, shape: []const usize) Value {
        const data = it.g.alloc.alloc(f64, prod(shape)) catch @panic("out of memory");
        return .{ .dtype = dtype, .shape = shape, .data = data };
    }

    fn void_(it: *Interp) Value {
        return it.alloc(.void, &.{});
    }

    /// Run the ranges' loops: set each to its next value, the innermost
    /// first. False when they've all been through every value.
    fn step(it: *Interp, ranges: []const *const UOp, counters: []i64) bool {
        it.varying.clearRetainingCapacity();
        var k = ranges.len;
        while (k > 0) {
            k -= 1;
            counters[k] += 1;
            if (counters[k] < ranges[k].src[0].intValue().?) {
                it.setLoops(ranges, counters);
                return true;
            }
            counters[k] = 0;
        }
        for (ranges) |r| _ = it.loops.remove(r);
        return false;
    }

    /// Start the loops over `ranges`. False if some range is empty.
    fn startLoops(it: *Interp, ranges: []const *const UOp, counters: []i64) bool {
        @memset(counters, 0);
        for (ranges) |r| {
            if (r.op != .range) return false;
            if (r.src[0].intValue().? <= 0) return false;
        }
        it.varying.clearRetainingCapacity();
        it.setLoops(ranges, counters);
        return true;
    }

    fn setLoops(it: *Interp, ranges: []const *const UOp, counters: []const i64) void {
        for (ranges, counters) |r, c| it.loops.put(r, c) catch @panic("out of memory");
    }

    /// Where a read or write of u goes, or null if u isn't memory at all.
    fn place(it: *Interp, u: *const UOp) RunError!?Place {
        switch (u.op) {
            .buffer, .alloc => return .{ .buf = u, .mem = it.storage(u), .offset = 0, .whole = true },
            .after => {
                for (u.src[1..]) |dep| _ = try it.eval(dep); // the stores happen first
                return it.place(u.src[0]);
            },
            .index => {
                const base = (try it.place(u.src[0])) orelse return null; // indexing a value, not memory
                if (u.src.len != 2 or !base.whole) return it.fail(error.Spec, "index a buffer with exactly one int");
                const i = (try it.eval(u.src[1])).scalar();
                if (⟪i < 0 or i >= @as(f64, @floatFromInt(base.mem.len))|||???⟫) return it.fail(error.OutOfBounds, "an INDEX outside its buffer");
                return .{ .buf = base.buf, .mem = base.mem, .offset = ⟪@intFromFloat(i)|||???⟫, .whole = false };
            },
            .param => return it.fail(error.Unbound, "a PARAM outside its CALL"),
            else => return null,
        }
    }

    fn read(it: *Interp, p: Place) Value {
        const dtype = p.buf.arg.param.dtype;
        if (p.whole) {
            const v = it.alloc(dtype, p.buf.shape);
            @memcpy(v.data, p.mem);
            return v;
        }
        const v = it.alloc(dtype, &.{});
        v.data[0] = p.mem[p.offset];
        return v;
    }

    /// STORE value into target, committed to the buffer's dtype.
    fn write(it: *Interp, target: *const UOp, value: Value) RunError!void {
        const p = (try it.place(target)) orelse return it.fail(error.Spec, "a STORE needs a buffer, or an INDEX into one");
        const n = if (p.whole) p.mem.len else 1;
        if (value.data.len != n) return it.fail(error.Spec, "a STORE's value doesn't fit its target");
        for (value.data, 0..) |x, i| ⟪p.mem[p.offset + i] = fit(p.buf.arg.param.dtype, x);|||???;⟫
    }

    fn compute(it: *Interp, u: *const UOp) RunError!Value {
        switch (u.op) {
            .constant => {
                const v = it.alloc(u.dtype, &.{});
                v.data[0] = switch (u.arg) {
                    .int => |x| @floatFromInt(x),
                    .float => |x| x,
                    .boolean => |x| if (x) 1 else 0,
                    else => unreachable,
                };
                return v;
            },
            .range => {
                const i = it.loops.get(u) orelse return it.fail(error.Unbound, "a RANGE outside its loop");
                const v = it.alloc(.weakint, &.{});
                v.data[0] = @floatFromInt(i);
                return v;
            },
            .param => return it.fail(error.Unbound, "a PARAM outside its CALL"),
            .call => return it.eval(try inlineCall(it.g, u)),
            .buffer, .alloc, .after, .load => {
                const target = if (u.op == .load) u.src[0] else u;
                if (try it.place(target)) |p| return it.read(p);
                return it.eval(target); // LOAD of a plain value is the value
            },
            .index => {
                if (try it.place(u)) |p| return it.read(p);
                return it.indexValue(u);
            },
            .store => {
                try it.write(u.src[0], try it.eval(u.src[1]));
                return it.void_();
            },
            .end => {
                const ranges = u.src[1..];
                const counters = it.g.alloc.alloc(i64, ranges.len) catch @panic("out of memory");
                if (it.startLoops(ranges, counters)) {
                    while (true) {
                        ⟪_ = try it.eval(u.src[0]);|||???;⟫
                        if (!it.step(ranges, counters)) break;
                    }
                }
                return it.void_();
            },
            .sink => {
                for (u.src) |s| _ = try it.eval(s);
                return it.void_();
            },
            .assert => {
                const got = try it.eval(u.src[0]);
                const want = try it.eval(u.src[1]);
                if (!sameShape(got.shape, want.shape)) return it.fail(error.AssertFailed, "assert: the shapes differ");
                for (got.data, want.data) |a, b| {
                    // compare as the actual dtype: the literal 0.1 is an f32's 0.1 here
                    const same = a == fit(got.dtype, b) or (std.math.isNan(a) and std.math.isNan(b));
                    if (⟪!same|||???⟫) return it.fail(error.AssertFailed, "assert: the values differ");
                }
                return it.void_();
            },
            .stack => {
                const v = it.alloc(u.dtype, u.shape);
                var at: usize = 0;
                for (u.src) |s| {
                    const x = try it.eval(s);
                    for (x.data) |d| {
                        v.data[at] = fit(u.dtype, d);
                        at += 1;
                    }
                }
                return v;
            },
            .where => {
                // a scalar condition is a GATE: only the side it picks runs, like
                // C's ?:. A padded read, WHERE(valid, x[i - 1], 0), must not read
                // x[-1] where it isn't valid. (tinygrad gates the load itself.)
                const c = try it.eval(u.src[0]);
                if (u.shape.len == 0) {
                    const picked = try it.eval(if (c.scalar() != 0) u.src[1] else u.src[2]);
                    const v = it.alloc(u.dtype, u.shape);
                    v.data[0] = fit(u.dtype, picked.scalar());
                    return v;
                }
                return it.elementwise(u);
            },
            .cast, .recip, .add, .mul, .max, .xor, .shl, .div, .mod, .cmplt, .cmpne => return it.elementwise(u),

            .reshape, .expand, .permute, .pad, .shrink => return evalMovement(it, u, try it.eval(u.src[0])),
            .reduce => return evalReduce(it, u),
            .stage => {
                // the value of src[0] at every value of the ranges, stacked in front
                const ranges = u.src[1..];
                const v = it.alloc(u.dtype, u.shape);
                const counters = it.g.alloc.alloc(i64, ranges.len) catch @panic("out of memory");
                var at: usize = 0;
                if (it.startLoops(ranges, counters)) {
                    while (true) {
                        const x = try it.eval(u.src[0]);
                        @memcpy(v.data[at .. at + x.data.len], x.data);
                        at += x.data.len;
                        if (!it.step(ranges, counters)) break;
                    }
                }
                return v;
            },
        }
    }

    /// An ALU op, element by element (183).
    fn elementwise(it: *Interp, u: *const UOp) RunError!Value {
        var srcs: [3]Value = undefined;
        for (u.src, 0..) |s, i| srcs[i] = try it.eval(s);
        const v = it.alloc(u.dtype, u.shape);
        for (v.data, 0..) |*d, j| {
            var args: [3]f64 = undefined;
            for (srcs[0..u.src.len], 0..) |s, i| args[i] = s.data[j];
            d.* = if (u.op == .cast) castValue(args[0], u.dtype) else execAlu(u.op, u.dtype, args[0..u.src.len]);
        }
        return v;
    }

    /// INDEX into a value (not memory): pops leading axes. An index that is
    /// itself a tensor gathers, its shape coming first (182).
    fn indexValue(it: *Interp, u: *const UOp) RunError!Value {
        const x = try it.eval(u.src[0]);
        const idx = u.src[1..];
        const v = it.alloc(u.dtype, u.shape);
        const inner = prod(x.shape[idx.len..]);
        var vals = it.g.alloc.alloc(Value, idx.len) catch @panic("out of memory");
        var front: usize = 1;
        for (idx, 0..) |s, j| {
            vals[j] = try it.eval(s);
            front *= vals[j].data.len;
        }
        for (0..front) |f| {
            var rem = f;
            var offset: usize = 0;
            var stride = inner;
            var j = idx.len;
            while (j > 0) {
                j -= 1;
                const n = vals[j].data.len;
                const i = vals[j].data[rem % n];
                rem /= n;
                if (i < 0 or i >= @as(f64, @floatFromInt(x.shape[j]))) return it.fail(error.OutOfBounds, "an INDEX outside its tensor");
                offset += @as(usize, @intFromFloat(i)) * stride;
                stride *= x.shape[j];
            }
            @memcpy(v.data[f * inner .. (f + 1) * inner], x.data[offset .. offset + inner]);
        }
        return v;
    }
};

/// Run a program: each ASSERT, in order, and then the last line. The other
/// lines are just definitions: they run when something uses them. (A bare
/// RANGE has no value outside its loop, nor a PARAM outside its CALL.)
/// A failure's reason is in it.why, or it.g.why if the spec rejected it.
fn runUir(it: *Interp, text: []const u8) RunError!void {
    const lines = try parseLines(it.g, text);
    for (lines, 0..) |line, i| {
        if (line.op == .assert or i == lines.len - 1) _ = try it.eval(line);
    }
}
//@end

const t = std.testing;

fn expectRuns(text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    var it = Interp.init(&g);
    runUir(&it, text) catch |err| {
        std.debug.print("{s}: {s}{s}\n", .{ @errorName(err), it.why, g.why });
        return err;
    };
}

fn expectFails(err: RunError, text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    var it = Interp.init(&g);
    try t.expectError(err, runUir(&it, text));
}

test "week 1: values" {
    try expectRuns("%sum = add 2 3\n%test = assert %sum 5");
    try expectFails(error.AssertFailed, "%sum = add 2 3\n%test = assert %sum 6");
    try expectRuns("%q = div -7 2\n%t = assert %q -4\n%m = mod -7 2\n%u = assert %m 1");
    try expectRuns("%x = index [10 20 30] 2\n%t = assert %x 30");
    try expectRuns("%x = where (cmplt 1 2) 7 9\n%t = assert %x 7");
    try expectRuns("%x = add (cast 2147483647 dtype=i32) 1\n%t = assert %x -2147483648");
}

test "week 2: store, then load through AFTER" {
    try expectRuns(
        \\%buf = buffer [] slot=0 dtype=i32
        \\%write = store %buf 7
        \\%ready = after %buf %write
        \\%value = load %ready
        \\%test = assert %value 7
    );
    // stores commit to the buffer's dtype: an f32 holds f32's 0.1
    try expectRuns(
        \\%buf = buffer 2 slot=0 dtype=f32
        \\%w = store (index %buf 1) 0.1
        \\%t = assert (after %buf %w) [0.0 0.1]
    );
    // a whole buffer at once
    try expectRuns(
        \\%buf = buffer 3 slot=0 dtype=i32
        \\%w = store %buf [4 5 6]
        \\%t = assert (after %buf %w) [4 5 6]
    );
    // two stores, in order
    try expectRuns(
        \\%buf = buffer [] slot=0 dtype=i32
        \\%a = store %buf 1
        \\%b = store (after %buf %a) (add (after %buf %a) 10)
        \\%t = assert (after %buf %b) 11
    );
}

test "week 3: loops" {
    try expectRuns(
        \\%buf = buffer 3 slot=0 dtype=i32
        \\%i = range 3 slot=0
        \\%write = store (index %buf %i) %i
        \\%done = end %write %i
        \\%test = assert (after %buf %done) [0 1 2]
    );
    // two ranges: the first is the outer loop
    try expectRuns(
        \\%buf = buffer 6 slot=0 dtype=i32
        \\%i = range 2 slot=0
        \\%j = range 3 slot=1
        \\%w = store (index %buf (add (mul %i 3) %j)) (add (mul %i 10) %j)
        \\%done = end %w %i %j
        \\%test = assert (after %buf %done) [0 1 2 10 11 12]
    );
    // a loop that reads one buffer and writes another
    try expectRuns(
        \\%x = buffer 4 slot=0 dtype=i32
        \\%y = buffer 4 slot=1 dtype=i32
        \\%i = range 4 slot=0
        \\%fill = end (store (index %x %i) (mul %i %i)) %i
        \\%xs = after %x %fill
        \\%j = range 4 slot=1
        \\%copy = end (store (index %y %j) (add (index %xs %j) 1)) %j
        \\%test = assert (after %y %copy) [1 2 5 10]
    );
}

test "a WHERE on a scalar is a gate" {
    // the side it doesn't pick never runs, so its out-of-bounds read is fine
    try expectRuns(
        \\%buf = buffer 2 slot=0 dtype=i32
        \\%x = where (cmplt 5 2) (index %buf 5) 7
        \\%t = assert %x 7
    );
}

test "running off the end of a buffer" {
    try expectFails(error.OutOfBounds,
        \\%buf = buffer 3 slot=0 dtype=i32
        \\%i = range 4 slot=0
        \\%done = end (store (index %buf %i) %i) %i
    );
    try expectFails(error.OutOfBounds, "%x = index [1 2 3] 3");
}

test "a call" {
    try expectRuns(
        \\%x = param [] slot=0 dtype=weakint
        \\%body = add (mul %x %x) 1
        \\%five = call %body 2
        \\%test = assert %five 5
    );
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

//@include interp_movement
