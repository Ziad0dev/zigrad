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
    .{ .file = "044_roofline.zig", .hint = "Each formula is written out in the comment. Flops for a matmul: a multiply and an add for each of the n^3 terms." },
    .{ .file = "045_upcast.zig", .hint = "Each of the four accumulators takes one of the four elements. Vectors add with +, and @reduce(.Add, v) sums the lanes." },
    .{ .file = "046_tiling.zig", .hint = "Inside a tile it's the ordinary matmul, just with ta and tb. Every loaded number gets used T times." },
    .{ .file = "047_parallel_reduce.zig", .hint = "Pair i adds elements 2i and 2i+1. An odd leftover moves up a level, and the next level has half the values, plus that leftover." },
    .{ .file = "048_beam_search.zig", .hint = "Stop if even the fastest candidate isn't better than the best so far. Keep at most `width` candidates, fewer if there aren't that many." },
    .{ .file = "049_dtypes.zig", .hint = "bf16 is the top 16 bits: shift right to convert, shift left (as a u32) to go back. Quantize: divide by the scale and round." },
    .{ .file = "050_memory_planner.zig", .hint = "Remember the latest step that reads each buffer. A free slot fits if it's the same size, and a buffer is freed after its last read." },
    .{ .file = "051_jit.zig", .hint = "A replay does what capture did, minus the schedule() call." },
    .{ .file = "052_compile.zig", .hint = "The comment shows the zig cc command. A C function pointer type needs callconv(.c), and arrays pass to [*] pointers directly." },
    .{ .file = "053_multi_device.zig", .hint = "Round the slice size up: (n + d - 1) / d. The last slice stops at n. The all-reduce writes the mean back into every slot." },
    .{ .file = "054_vectors.zig", .hint = "Length is the square root of a vector dotted with itself. Cosine divides the dot product by both lengths." },
    .{ .file = "055_linear_maps.zig", .hint = "Row 1 of M·x mirrors row 0. In a product, entry [i][j] is row i of a dotted with column j of b." },
    .{ .file = "056_transpose.zig", .hint = "Element (i, j) of A moves to (j, i) of Aᵀ, which has `rows` columns. For Aᵀy, read A normally but add into out[j]." },
    .{ .file = "057_solve.zig", .hint = "The factor is what makes row r's entry in this column zero. Whatever you do to a row of A, do to b too." },
    .{ .file = "058_eigen.zig", .hint = "Normalize by the length of A·v. The Rayleigh quotient is dot(v, A v). Stability needs lr * λ < 2." },
    .{ .file = "059_outer_products.zig", .hint = "Every (i, j) is u[i] * v[j]. Accumulate one outer product per k. LoRA trains B and A, not W." },
    .{ .file = "060_distributions.zig", .hint = "Box-Muller is written out in the comment. Shift by mu and stretch by sigma. The wobble shrinks like 1/sqrt(n)." },
    .{ .file = "061_likelihood.zig", .hint = "Copy the log density from the comment. NLL subtracts log-likelihoods. BCE picks log p or log(1 - p) using y." },
    .{ .file = "062_entropy.zig", .hint = "Each formula is a sum of p[i] times some log, and the comment has all three." },
    .{ .file = "063_sampling.zig", .hint = "Temperature divides the logits. Sampling stops at the first running total above u. top-k zeroes everything below the k-th largest." },
    .{ .file = "064_counter_rng.zig", .hint = "24 bits divided by 2^24 lands in [0, 1). The exponent trick ORs the bits into 1.0's pattern, then subtracts 1." },
    .{ .file = "065_jacobian.zig", .hint = "Column j comes from nudging input j. Row i is output i. J is stored row-major with n columns." },
    .{ .file = "066_vjp.zig", .hint = "Each shortcut is in the comment: mask, Aᵀv, broadcast, and p times (v - dot(v, p))." },
    .{ .file = "067_forward_vs_reverse.zig", .hint = "Forward goes J1, J2, J3 in order. Reverse goes J3, J2, J1. Forward needs one pass per input, reverse one per output." },
    .{ .file = "068_tensor_autograd.zig", .hint = "The comment's rule table maps straight onto the index maths. A bias position j collects every row's grad." },
    .{ .file = "069_symbolic_grad.zig", .hint = "Same rules as exercise 030, but build nodes with g.mul, g.cos and g.sin instead of computing numbers." },
    .{ .file = "070_newton.zig", .hint = "Root: x - f/f'. Minimum: x - f'/f''. And f'' is just the grad of the grad." },
    .{ .file = "071_index_bounds.zig", .hint = "add: add the ends. mul: min and max of the four corner products. mod: if x already fits in [0, d), keep its range." },
    .{ .file = "072_index_simplify.zig", .hint = "Use bounds() for the range rules. For (x*d + y) // d, the answer is x + y // d. recombine needs q to be exactly x // d." },
    .{ .file = "073_views_as_indexes.zig", .hint = "i_k is (g // inner) % shape[k]. Add i_k * stride to the running position." },
    .{ .file = "074_stacked_views.zig", .hint = "Merging needs stride[k] == stride[k+1] * shape[k+1]. Unravel flat over the old shape, then ask the old view for the position." },
    .{ .file = "075_symbolic_shapes.zig", .hint = "Record the step, then multiply it by this dimension's size. At run time, bind n to its current value." },
    .{ .file = "076_reduce_codegen.zig", .hint = "Reduce loops open exactly like the global ones, with ridx. The body adds into acc, and each closing brace goes up one level." },
    .{ .file = "077_gpu_grid.zig", .hint = "Round up: (n + bs - 1) / bs. A thread's global id is its block's start plus its own id. Guard with gid >= n." },
    .{ .file = "078_shared_memory.zig", .hint = "Threads below the stride add in the value `stride` places to their right." },
    .{ .file = "079_opt_ops.zig", .hint = "The amount must divide the size, and the old axis keeps size / amount. Threads per block come from local axes, outputs per thread from upcast axes." },
    .{ .file = "080_tensor_cores.zig", .hint = "Widen each f16 to f32 before multiplying. Tile (bi, bk) of A starts at row bi and column bk." },
    .{ .file = "081_store_or_recompute.zig", .hint = "Both formulas are in the comment. Recompute when it's no slower." },
    .{ .file = "082_linear_layer.zig", .hint = "db collects every example's g. dX uses W (walked as if transposed), and dW uses X." },
    .{ .file = "083_layernorm.zig", .hint = "1/σ is 1 / sqrt(var + eps), and x̂ is (x - μ) / σ. The dx formula is in the comment, term for term." },
    .{ .file = "084_batchnorm.zig", .hint = "Batch statistics average down each column. The running value moves `momentum` of the way toward the batch value. Eval uses only the running values." },
    .{ .file = "085_conv2d.zig", .hint = "(size + 2*pad - k) / stride + 1. A tap is inside when 0 <= y < h and 0 <= x < w." },
    .{ .file = "086_conv2d_backward.zig", .hint = "dW is dOut times colsᵀ. col2im walks the same indexes as im2col, but ADDS into dx instead of reading from x." },
    .{ .file = "087_pooling.zig", .hint = "Max keeps the biggest and remembers where it was. Average divides by 4. In backward, max sends the gradient to the winner and average splits it 4 ways." },
    .{ .file = "088_embeddings.zig", .hint = "Lookup copies row `id`. Backward ADDS into row `id`. One-hot is 1 exactly where v == id." },
    .{ .file = "089_dropout.zig", .hint = "Keep a value when uniform >= p, and scale survivors by 1/(1-p). Eval copies x unchanged. Backward uses the same mask." },
    .{ .file = "090_attention.zig", .hint = "A score is dot(query i, key j) times the scale. The output is the weighted sum of the value rows." },
    .{ .file = "091_causal_mask.zig", .hint = "Keys after the query (j > i) are the future. Give them -infinity." },
    .{ .file = "092_multi_head.zig", .hint = "Head h's dimension j of token tok sits at tok * width + h * dh + j, both when reading and when writing back." },
    .{ .file = "093_positions.zig", .hint = "freq is 1 / 10000^e. Even indexes use sin, odd ones cos. The rotation is 055's R(angle) applied to (a, b)." },
    .{ .file = "094_kv_cache.zig", .hint = "append copies v like k and bumps len. Scores are dot(q, key j) / sqrt(dim). Without a cache, step t projects t tokens." },
    .{ .file = "095_flash_attention.zig", .hint = "correction = e^(m - m_new), applied to both l and acc. Each new term adds p to l and p * value to acc. Finish with acc / l." },
    .{ .file = "096_losses.zig", .hint = "The Huber branches and the stable BCE formula are in the comment. The BCE gradient is sigmoid(z) - y." },
    .{ .file = "097_lr_schedules.zig", .hint = "Warmup ramps up by (t+1)/warmup. The decay is the half-cosine formula, with progress running 0 to 1." },
    .{ .file = "098_weight_decay.zig", .hint = "L2 adds wd * w to the gradient. AdamW subtracts lr * wd * w after the normal step." },
    .{ .file = "099_grad_clipping.zig", .hint = "Sum the squares of EVERY gradient, then take one square root. Scale everything by max_norm / norm." },
    .{ .file = "100_mixed_precision.zig", .hint = "Scale up before storing in f16, divide back after. On overflow halve the scale; after `interval` good steps double it." },
    .{ .file = "101_overfitting.zig", .hint = "Each power is the previous one times x. Ridge adds lambda to the diagonal. MSE is the mean of the squared errors." },
    .{ .file = "102_data_pipeline.zig", .hint = "Fisher-Yates picks j in [0, i] (so i + 1 choices) and swaps. Normalize with (x - mean) / sd. The last batch stops at n." },
    .{ .file = "103_mlp_classifier.zig", .hint = "forward is matmul, addBias, relu, matmul, addBias. Each step: zero every grad, backward, then w -= lr * g. Accuracy compares argmax with the label." },
    .{ .file = "104_cnn.zig", .hint = "Patch pixel (i, j) at output (oy, ox) is input pixel (oy + i, ox + j) of image b. Flatten to [batch, positions * filters]." },
    .{ .file = "105_evaluation.zig", .hint = "Count c[truth][predicted]. Precision sums a column, recall sums a row. F1 is the harmonic mean." },
    .{ .file = "106_command_queues.zig", .hint = "Each submit takes the next value up. A command is blocked while the other queue's signal is below what it waits for. wait() keeps ticking until the signal catches up." },
    .{ .file = "107_overlap.zig", .hint = "The formulas are in the comment. A compute starts when both its copy and the compute engine are ready: the later of the two times." },
    .{ .file = "108_launch_overhead.zig", .hint = "Plain pays a launch per kernel, a graph pays one launch in total. Speedup is plain / graph." },
    .{ .file = "109_ring_allreduce.zig", .hint = "Reduce-scatter sends chunk (d - s) mod N and ADDS. All-gather sends chunk (d + 1 - s) mod N and COPIES. Add n_dev before subtracting so nothing goes negative." },
    .{ .file = "110_safetensors.zig", .hint = "The first 8 bytes are a little-endian u64. Raw data starts right after the header, and offsets count from there." },
    .{ .file = "111_rnn.zig", .hint = "Add W times the old hidden state and U times the input to the bias, then squash with tanh." },
    .{ .file = "112_bptt.zig", .hint = "Each line in the comment's loop maps straight to one hole. The gradient passed back is dpre times w." },
    .{ .file = "113_vanishing_gradients.zig", .hint = "Each step multiplies the gradient by w times tanh's slope, 1 - h^2. A linear RNN just multiplies by w, T times." },
    .{ .file = "114_lstm.zig", .hint = "c = f*c + i*g, and h = o*tanh(c)." },
    .{ .file = "115_residuals.zig", .hint = "A plain layer multiplies the gradient by f'. A residual layer by 1 + f', and it adds f(x) to x." },
    .{ .file = "116_tokenize.zig", .hint = "The id is the vocab position, v.size. Encode looks up ids, decode looks up chars." },
    .{ .file = "117_bpe.zig", .hint = "Count each pair with +1. A match needs both tokens of the pair, in order. Decode expands both halves recursively." },
    .{ .file = "118_bigram.zig", .hint = "Count counts[prev][next]. Smoothing adds 1 on top and the vocab size underneath. NLL subtracts log probabilities." },
    .{ .file = "119_perplexity.zig", .hint = "Perplexity is e to the average NLL. Bits divide the NLL by ln 2." },
    .{ .file = "120_neural_bigram.zig", .hint = "The gradient is (p - truth) / n. Step against it." },
    .{ .file = "121_pca.zig", .hint = "Covariance averages x[i] * x[j]. Encode is a dot product with v, decode scales v by the code." },
    .{ .file = "122_vae.zig", .hint = "Both formulas are in the comment: the KL closed form, and z = μ + σε." },
    .{ .file = "123_diffusion_forward.zig", .hint = "ᾱ multiplies (1 - β) step after step. One-shot noise is sqrt(ᾱ) x0 + sqrt(1 - ᾱ) ε." },
    .{ .file = "124_diffusion_reverse.zig", .hint = "Both formulas are in the comment, x̂_0 first, then the DDPM mean." },
    .{ .file = "125_gan.zig", .hint = "The derivative of log(1 - d) is -1/(1 - d), and of -log(d) it's -1/d. D* is p_data over the sum." },
    .{ .file = "126_bandits.zig", .hint = "Explore when a random number is below ε. The update adds (reward - Q) / n." },
    .{ .file = "127_bellman.zig", .hint = "Each action scores its reward plus γ times the value of where it leads. Keep the best." },
    .{ .file = "128_q_learning.zig", .hint = "target = r + γ * future. Move Q a step of size lr toward the target." },
    .{ .file = "129_policy_gradient.zig", .hint = "∇ log π is onehot minus π. Scale it by (r - baseline) and by lr." },
    .{ .file = "130_preferences.zig", .hint = "Everything is σ of a difference. DPO's margin is β times (winner's log-ratio - loser's log-ratio)." },
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

    // Put this zig first on PATH, so exercises that run `zig cc` (052)
    // use the same compiler as the build.
    var env = try b.graph.environ_map.clone(b.allocator);
    const zig_dir = std.fs.path.dirname(b.graph.zig_exe) orelse ".";
    const old_path = env.get("PATH") orelse "";
    const sep = if (@import("builtin").os.tag == .windows) ";" else ":";
    try env.put("PATH", b.fmt("{s}{s}{s}", .{ zig_dir, sep, old_path }));

    for (exercises, 1..) |ex, n| {
        if (check.only) |only| if (only != n) continue;
        const rel = b.pathJoin(&.{ check.dir, ex.file });
        const name = ex.file[0 .. ex.file.len - ".zig".len];

        const result = try std.process.run(b.allocator, b.graph.io, .{
            .argv = &.{ b.graph.zig_exe, "test", b.pathFromRoot(rel) },
            .cwd = .{ .path = b.pathFromRoot(".") },
            .environ_map = &env,
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
            \\All {d} exercises pass. From flat memory to transformers, from the
            \\chain rule to tensor cores: you've built every major piece of tinygrad,
            \\and the maths underneath it.
            \\
            \\Next: read tinygrad's own source (github.com/tinygrad/tinygrad). You'll
            \\recognize it.
            \\
        , .{exercises.len});
    }
}
