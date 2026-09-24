//! `zig build` checks your exercises in order and stops at the first one
//! that doesn't pass yet. Fix it, run `zig build` again, repeat.
//!
//!   zig build                  check everything, in order
//!   zig build -Dn=7            check only exercise 7
//!   zig build -Dsolutions      check the reference solutions instead

const std = @import("std");

const Exercise = struct {
    file: []const u8,
    hint: []const u8,
};

const exercises = [_]Exercise{
    .{ .file = "001_tensor_is_numbers.zig", .hint = "Slices carry their length with them. And Zig has +=, like C." },
    .{ .file = "002_floats.zig", .hint = "For approxEq, how far apart are a and b? For the predictions: near 100,000,000, f32 can only step in 8s." },
    .{ .file = "003_elementwise.zig", .hint = "relu is 'max with zero'. mulAdd walks one more slice than mul does." },
    .{ .file = "004_reduce.zig", .hint = "Which starting value can EVERY number beat, even -1000? The comments name max's identity." },
    .{ .file = "005_shape.zig", .hint = "What's 0 times anything? And what's the identity of multiplication?" },
    .{ .file = "006_strides.zig", .hint = "Walking from the last dimension: record the current step, then make it bigger for the next dimension." },
    .{ .file = "007_position.zig", .hint = "It's a dot product of the index and the strides." },
    .{ .file = "008_unravel.zig", .hint = "Same as the clock example: the remainder gives this digit, the division gives what's left." },
    .{ .file = "009_view.zig", .hint = "Where does element [0, 0] live? Not always at memory position 0." },
    .{ .file = "010_reshape.zig", .hint = "A contiguous reshape needs fresh contiguous strides, and View already has a function for that. -1 is whatever's left after dividing by the known sizes." },
    .{ .file = "011_permute.zig", .hint = "Moving a dimension means moving its size AND its stride." },
    .{ .file = "012_expand.zig", .hint = "Which stride makes every index read the same memory? For broadcasting, reread the three rules in the comment." },
    .{ .file = "013_shrink_flip.zig", .hint = "shrink starts `start` steps in. flip starts at the last element and walks backwards." },
    .{ .file = "014_pad.zig", .hint = "Real data now sits `before` places further right, both where it starts and where it ends." },
    .{ .file = "015_exp2_log2.zig", .hint = "Use the two change-of-base formulas in the comment. pow uses the same trick." },
    .{ .file = "016_composites.zig", .hint = "Translate each formula in the comment into P calls, one operation at a time." },
    .{ .file = "017_reduce_axis.zig", .hint = "Move the index along the axis, then read memory through the view. max works the same way from a different starting value." },
    .{ .file = "018_softmax.zig", .hint = "The big-number test overflows. What does the comment say to subtract?" },
    .{ .file = "019_matmul.zig", .hint = "Follow the shape diagram in the comment step by step: which reshape, which permute, which axis to sum." },
    .{ .file = "020_conv.zig", .hint = "Draw the window view: how far apart do the rows start, and how far apart are neighbours within a row? Weights repeat on every row." },
    .{ .file = "021_graph.zig", .hint = "Every piece is recursive: render and count the sources the same way you handle the node." },
    .{ .file = "022_eval.zig", .hint = "The Evaluator checks its cache, but does it ever fill it?" },
    .{ .file = "023_toposort.zig", .hint = "Socks before shoes: when may a node be appended?" },
    .{ .file = "024_dedup.zig", .hint = "Hash the value's raw bits. If the cache already has this key, what should new() give back?" },
    .{ .file = "025_rewrite.zig", .hint = "Copy the shape of addZero. fold does the operation the node describes, right now." },
    .{ .file = "026_slope.zig", .hint = "Rise over run. For the central difference, the run is 2h." },
    .{ .file = "027_derivative_rules.zig", .hint = "Each rule is spelled out in the comment above it." },
    .{ .file = "028_chain_rule.zig", .hint = "Outside derivative (evaluated at the inside), times inside derivative." },
    .{ .file = "029_dual_numbers.zig", .hint = "Product rule for mul, chain rule for sin and exp." },
    .{ .file = "030_backprop.zig", .hint = "How much does the output change when the output changes? And each input of a mul gets grad times the OTHER input." },
    .{ .file = "031_backprop_more.zig", .hint = "Each rule is in the comment table. Some reuse n.value, the node's own output." },
    .{ .file = "032_gradient_descent.zig", .hint = "Step AGAINST the slope. The error is prediction minus truth." },
    .{ .file = "033_unbroadcast.zig", .hint = "Every copy of a stretched element came from index 0. And copies' grads add up." },
    .{ .file = "034_movement_grads.zig", .hint = "Each gradient moves grads back to where their numbers came from. For the inverse permutation, undo each move." },
    .{ .file = "035_matmul_grad.zig", .hint = "Check the shapes: what are m, k and n for dC · Bᵀ, and for Aᵀ · dC?" },
    .{ .file = "036_cross_entropy.zig", .hint = "Both formulas are in the comment: logsumexp minus the right logit, and 'predicted minus truth'." },
    .{ .file = "037_init.zig", .hint = "Variance is the average squared distance from the mean. Solve a^2 / 3 = 1 / n for a." },
    .{ .file = "038_optimizers.zig", .hint = "Translate the update formulas in the comment one by one. std.math.pow(f64, base, exponent)." },
    .{ .file = "039_xor.zig", .hint = "Grads add up with +=, so what has to happen before every forward pass? Then backward, then step." },
    .{ .file = "040_schedule.zig", .hint = "Which nodes must be written to memory? The comment lists all three rules." },
    .{ .file = "041_linearize.zig", .hint = "Sources must be emitted before the node that uses them. And remember each node's number, or it gets emitted twice." },
    .{ .file = "042_render.zig", .hint = "Same idea as dump() in 041, but in C. C spells max as fmaxf." },
    .{ .file = "043_run.zig", .hint = "Each instruction reads its operands from earlier registers. A reduce kernel adds each result into acc." },
};

pub fn build(b: *std.Build) void {
    const check = b.allocator.create(Check) catch @panic("OOM");
    check.* = .{
        .step = .init(.{ .id = .custom, .name = "check exercises", .owner = b, .makeFn = make }),
        .only = b.option(usize, "n", "Check only exercise number n"),
        .dir = if (b.option(bool, "solutions", "Check the reference solutions") orelse false) "solutions" else "exercises",
    };
    b.default_step.dependOn(&check.step);
}

const Check = struct {
    step: std.Build.Step,
    only: ?usize,
    dir: []const u8,
};

fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const check: *Check = @fieldParentPtr("step", step);
    const b = step.owner;
    const p = std.debug.print;

    if (check.only) |n| {
        if (n == 0 or n > exercises.len) {
            p("There is no exercise {d}. Pick 1 to {d}.\n", .{ n, exercises.len });
            std.process.exit(2);
        }
    }

    for (exercises, 1..) |ex, n| {
        if (check.only) |only| if (only != n) continue;
        const rel = b.pathJoin(&.{ check.dir, ex.file });
        const name = ex.file[0 .. ex.file.len - ".zig".len];

        const result = try std.process.run(b.allocator, b.graph.io, .{
            .argv = &.{ b.graph.zig_exe, "test", b.pathFromRoot(rel) },
            .cwd = .{ .path = b.pathFromRoot(".") },
        });
        const passed = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };

        if (passed) {
            p("  ✓ {s}\n", .{name});
            continue;
        }

        p("  ✗ {s}\n\n{s}\n", .{ name, result.stderr });
        p("Hint: {s}\n\n", .{ex.hint});
        p("Edit {s} and run `zig build` again.\n", .{rel});
        p("Really stuck? The answer is in solutions/{s}\n", .{ex.file});
        std.process.exit(2);
    }

    if (check.only == null) {
        p(
            \\
            \\All {d} exercises pass. You rebuilt the core of tinygrad:
            \\views, primitive ops, a lazy graph, autograd, training, and a
            \\compiler with a device to run on.
            \\
            \\See it all in one piece:  zig run examples/tinygrad_in_one_file.zig
            \\
        , .{exercises.len});
    }
}
