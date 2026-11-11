//! `zig build` checks your exercises in order and stops at the first one
//! that doesn't pass yet. Fix it, run `zig build` again, repeat.
//!
//!   zig build                  check everything, in order
//!   zig build -Dn=7            check only exercise 7
//!   zig build -Dcheckpoint=2   check only checkpoint 2 (the from-memory review of Part II)
//!   zig build -Dhard           the same course with no blanks: write whole functions
//!   zig build -Dsolutions      check the reference solutions instead
//!   zig build -Dfresh          recheck everything, even exercises that passed before
//!
//! Exercises that passed are remembered (in .zig-cache/zigrad), and skipped
//! next time as long as their file hasn't changed.

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
    .{ .file = "053_multi_device.zig", .hint = "The slice size must round UP, or the last elements get no device: integer division rounds down, so add something first. The last slice stops at n. The all-reduce writes the mean back into every slot." },
    .{ .file = "c1_checkpoint_part_one.zig", .hint = "Each doc comment names the exercise that taught it. Read your own finished version, close it, then write the function from memory." },
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
    .{ .file = "077_gpu_grid.zig", .hint = "Round the block count UP, like 053's slice size. A thread's global id is its block's start plus its own id. Guard with gid >= n." },
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
    .{ .file = "092_multi_head.zig", .hint = "A token's row holds every head side by side, each dh wide. Skip to the token's row, then to head h, then to j, the same way when reading and when writing back." },
    .{ .file = "093_positions.zig", .hint = "freq is 1 / 10000^e. Even indexes use sin, odd ones cos. The rotation is 055's R(angle) applied to (a, b)." },
    .{ .file = "094_kv_cache.zig", .hint = "append copies v like k and bumps len. Scores are dot(q, key j) / sqrt(dim). Without a cache, step t projects t tokens." },
    .{ .file = "095_flash_attention.zig", .hint = "correction = e^(m - m_new), applied to both l and acc. Each new term adds p to l and p * value to acc. Finish with acc / l." },
    .{ .file = "096_losses.zig", .hint = "The Huber branches and the stable BCE formula are in the comment. The BCE gradient is sigmoid(z) - y." },
    .{ .file = "097_lr_schedules.zig", .hint = "Warmup ramps up by (t+1)/warmup. The decay is the half-cosine formula, with progress running 0 to 1." },
    .{ .file = "098_weight_decay.zig", .hint = "L2 adds wd * w to the gradient. AdamW subtracts lr * wd * w after the normal step." },
    .{ .file = "099_grad_clipping.zig", .hint = "Sum the squares of EVERY gradient, then take one square root. When that norm is too big, scale everything by the factor that makes it exactly max_norm." },
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
    .{ .file = "c2_checkpoint_part_two.zig", .hint = "solve: pick the biggest pivot in each column. Attention: token i only looks at tokens 0..i. AdamW: Adam step first, then decay the weight." },
    .{ .file = "111_rnn.zig", .hint = "Add W times the old hidden state and U times the input to the bias, then squash with tanh." },
    .{ .file = "112_bptt.zig", .hint = "Each line in the comment's loop maps straight to one hole. The gradient passed back is dpre times w." },
    .{ .file = "113_vanishing_gradients.zig", .hint = "Each step multiplies the gradient by w times tanh's slope, 1 - h^2. A linear RNN just multiplies by w, T times." },
    .{ .file = "114_lstm.zig", .hint = "Follow the gates in the comments: the forget gate scales the old memory, the input gate scales the candidate, and the output gate scales tanh of the new memory." },
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
    .{ .file = "131_convexity.zig", .hint = "Convexity fails when f at the midpoint is ABOVE the average of the ends. f'' is (f(x+h) - 2f(x) + f(x-h)) / h^2." },
    .{ .file = "132_adagrad_rmsprop.zig", .hint = "Adagrad adds g^2 forever. RMSprop mixes it in with ρ. Both divide the step by sqrt of that." },
    .{ .file = "133_line_search.zig", .hint = "Keep halving t while the new loss is above f(x) - c * t * |g|^2." },
    .{ .file = "134_ema.zig", .hint = "ema = decay * ema + (1 - decay) * w. Correct by dividing by 1 - decay^t." },
    .{ .file = "135_saddle_points.zig", .hint = "The radius is sqrt(((a-c)/2)^2 + b^2). Both eigenvalues positive: minimum. Both negative: maximum." },
    .{ .file = "136_grad_accumulation.zig", .hint = "Add each micro-batch's gradient, then divide by how many micro-batches there were." },
    .{ .file = "137_checkpointing.zig", .hint = "Memory is (checkpoints, rounded up) + k. Keep the k with the smallest memory. Recomputing a segment costs its length minus the stored first activation." },
    .{ .file = "138_tensor_parallel.zig", .hint = "Column shard d starts at column d * cols. A row shard multiplies only its own k range." },
    .{ .file = "139_pipeline_parallel.zig", .hint = "There are m + p - 1 slots. Stage s is busy at slot t when a micro-batch index t - s exists." },
    .{ .file = "140_zero.zig", .hint = "Stage by stage, divide one more piece (optimizer 12, grads 2, weights 2) by n." },
    .{ .file = "141_int8_matmul.zig", .hint = "Columns divide by their own scale. Accumulate in i32, and multiply both scales back in at the end." },
    .{ .file = "142_int4_packing.zig", .hint = "The low nibble goes in the low bits, the high nibble shifted up by 4. An arithmetic >> 4 on an i8 brings the sign bits back down." },
    .{ .file = "143_group_quant.zig", .hint = "A group's scale is its biggest |value| / 7. Each element uses the scale of its group, i / group." },
    .{ .file = "144_speculative_decoding.zig", .hint = "Accept with min(1, p/q). The leftover is max(0, p - q), before normalizing." },
    .{ .file = "145_paged_kv.zig", .hint = "Multiply every factor in the formula. The block is table[t / 16], and the slot is t % 16." },
    .{ .file = "146_kahan.zig", .hint = "The three lines are in the comment, in order." },
    .{ .file = "147_exp_approx.zig", .hint = "f is what's left after removing n. Each term multiplies by y / k. 2^n's bits are (n + 1023) << 52." },
    .{ .file = "148_sin_approx.zig", .hint = "Subtract k whole turns (k * 2π). Fold with π - r. Each series term multiplies by -r^2 / ((2k)(2k+1))." },
    .{ .file = "149_fast_rsqrt.zig", .hint = "Magic constant minus half the bits. Newton: y * (1.5 - 0.5 x y^2)." },
    .{ .file = "150_log_approx.zig", .hint = "Exponent: bits 52-62, minus 1023. Mantissa: the fraction bits with exponent 1023. Series terms are power / k." },
    .{ .file = "151_caches.zig", .hint = "line = addr / 64, slot = line % slots, tag = line / slots. A hit is when the slot already holds this tag." },
    .{ .file = "152_loop_order.zig", .hint = "In ikj the innermost loop reads B[k][j] and C[i][j], walking along rows." },
    .{ .file = "153_coalescing.zig", .hint = "The segment is the address / 128. Count each segment once." },
    .{ .file = "154_bank_conflicts.zig", .hint = "The bank is word % 32. The degree is the busiest bank's count." },
    .{ .file = "155_register_blocking.zig", .hint = "Intensity is a*b / (a + b). Registers needed: a*b + a + b." },
    .{ .file = "156_upat.zig", .hint = "A repeated name must be the very same node. Check the op, match every source, then capture." },
    .{ .file = "157_dtype_promotion.zig", .hint = "Union in everything above each parent. The answer is the smallest type in both upward sets." },
    .{ .file = "158_strength_reduction.zig", .hint = "A power of two has one set bit: c & (c-1) == 0. Shifts need x >= 0 for division and modulo. The mask is c - 1." },
    .{ .file = "159_inplace.zig", .hint = "It's unsafe exactly when the kernel reads the target buffer at a nonzero offset." },
    .{ .file = "160_mini_tinygrad.zig", .hint = "Every hole matches an earlier exercise, named in the header. The gradient of sum is a broadcast of out[0], and the gradient of expand is a sum." },
    .{ .file = "c3_checkpoint_part_three.zig", .hint = "Kahan: what did the last addition lose? (next - sum) - y. Q-learning moves q[s][a] a fraction lr of the way to r + gamma * best future." },
    .{ .file = "161_simd_microkernel.zig", .hint = "Broadcast one number of A to every lane with @splat, then @mulAdd(V, a, b, acc). At the end, store each row vector back into its 8 slots of C." },
    .{ .file = "162_threads.zig", .hint = "Chunks are ceil(n / t) rows, and the end is capped at n. std.Thread.spawn(.{}, Job.run, .{job}) returns a thread to join." },
    .{ .file = "163_false_sharing.zig", .hint = "A line is 64 bytes: divide the address. A line is shared when two or more threads write it. The padded stride is one whole line." },
    .{ .file = "164_amdahl.zig", .hint = "Serial part plus parallel part divided by n, then take 1 over that. Keep adding workers while the speedup is still below the target." },
    .{ .file = "165_littles_law.zig", .hint = "Little's law: what must be in flight is the rate times how long each item takes. With less in flight you get in_flight / latency, but never more than the peak." },
    .{ .file = "166_occupancy.zig", .hint = "Registers per block are regs_per_thread * threads_per_block; divide the register file by that. Occupancy counts warps: blocks * warps per block." },
    .{ .file = "167_divergence.zig", .hint = "A warp pays for a path if ANY of its threads takes it. The sorted version just runs branchCost on the sorted copy." },
    .{ .file = "168_warp_shuffle.zig", .hint = "Lane i reads lane i ^ offset. Each step adds (or maxes) the partner's value into your own." },
    .{ .file = "169_prefix_scan.zig", .hint = "Add the value d places to the left. After each step, copy the new values back before the next one." },
    .{ .file = "170_triton_blocks.zig", .hint = "The mask is offs < n_cols, as a vector compare against @splat(n_cols). Masked lanes load -inf, and masked stores skip lanes where the mask is false." },
    .{ .file = "171_rmsnorm.zig", .hint = "rms is the square root of mean(x^2) + eps. dx is (dy * g - x_hat * m) / rms, with x_hat = x / rms." },
    .{ .file = "172_swiglu.zig", .hint = "silu is z times sigmoid(z); its slope comes from the product rule. The gate multiplies silu(W1 x) by W3 x. The hidden size is 8d/3." },
    .{ .file = "173_gqa.zig", .hint = "Heads are grouped: group = q_heads / kv_heads, and head h uses KV head h / group. The cache holds a K and a V for every layer and KV head." },
    .{ .file = "174_top_p.zig", .hint = "Stop as soon as the running total reaches p. Zero everything after the kept prefix, and divide the kept ones by the total." },
    .{ .file = "175_moe.zig", .hint = "Mark each chosen expert as used. The weights are a softmax over the chosen logits, shifted by the biggest. Each token adds 1 to each of its K experts." },
    .{ .file = "176_benchmarking.zig", .hint = "Skip the first `warmup` times. The median of an even count is the average of the two middle ones. GFLOPS is billions of flops per second." },
    .{ .file = "177_mfu.zig", .hint = "6 FLOPs per parameter per token. MFU divides the FLOPs you actually do per second by the peak. Days are seconds / 86400." },
    .{ .file = "178_scaling_laws.zig", .hint = "C = 6 N D and D = 20 N, so C = 120 N^2: N is the square root of C / 120." },
    .{ .file = "179_decode_speed.zig", .hint = "At batch 1 every token reads all the weights: bandwidth / weight bytes. Compute is 2 N B / peak; set it equal to the memory time and solve for B." },
    .{ .file = "180_transformer_block.zig", .hint = "q and k both get RoPE at the token's position (cache.len before appending). Bump cache.len after storing. Residuals add the sublayer's output to its input." },
    .{ .file = "c4_checkpoint_part_four.zig", .hint = "warpSum and prefixSum both read OLD values within a step: copy first. top-p: keep taking the most likely token until the total reaches p." },
    .{ .file = "181_weak_dtypes.zig", .hint = "A bare int is weakint, a bare float weakfloat. On a chain, the least upper bound is whichever type comes later. commit() picks tinygrad's defaults." },
    .{ .file = "182_uop.zig", .hint = "STACK and EXPAND put new axes in FRONT; INDEX and REDUCE take axes off the front. Output axis i of a PERMUTE is old axis perm[i]. Comparisons always give bool." },
    .{ .file = "183_alu.zig", .hint = "Zig has @divFloor. Python's % is defined from //: x - (x // y) * y. @truncate keeps the low bits; @floatCast rounds to f32." },
    .{ .file = "184_call_param.zig", .hint = "Substitute each src, and only make a new UOp if one of them changed. PARAM slot i means argument i of the CALL." },
    .{ .file = "185_vmin_vmax.zig", .hint = "A RANGE to n runs from 0 to n - 1. A WHERE can be either side. a < b is certain when even a's largest is below b's smallest, and impossible the other way round." },
    .{ .file = "186_uir_parse.zig", .hint = "After a %name, skip spaces: a = makes it an assignment. A word followed directly by = is a key. ( starts an op, [ a STACK. Args come after srcs." },
    .{ .file = "187_uir_print.zig", .hint = "Only CONSTs, and STACKs of nothing but CONSTs, are written in place. A float with no '.' or 'e' needs '.0'. pop=0 is the default, so it's left out." },
    .{ .file = "188_uir_run.zig", .hint = "An index is in bounds when it's in [0, length). A STORE fits each value to the buffer's dtype. AFTER runs its deps first; END runs its body once per step of its loops." },
    .{ .file = "189_uir_movement.zig", .hint = "EXPAND copies all of x once per position of the new axes. PERMUTE: input axis perm[i] gets output index i. PAD adds the offset to each index; SHRINK reads at index + offset." },
    .{ .file = "190_tests_due_monday.zig", .hint = "Each bug hides somewhere: division needs a negative number, a permute 3 axes, a reduce a non-square shape, a pad an asymmetric offset, and AFTER a read after a write." },
    .{ .file = "191_movement_on_ranges.zig", .hint = "Each case is one line of tinygrad's apply_movement_op: add the offset; route through perm; drop the leading ranges; subtract the offset and AND in the check; flatten, then unflatten." },
    .{ .file = "192_rangeify_walk.zig", .hint = "One consumer: take its ranges. Consumers that disagree: realize, with fresh ranges. A REDUCE's popped axes need fresh ranges in front of out." },
    .{ .file = "193_rangeify_lower.zig", .hint = "A realized value is read from its buffer with element(). A PAD's valid becomes a WHERE with 0. In kernel(), END the store over its loops, then AFTER the buffer on that END." },
    .{ .file = "194_kernels_and_calls.zig", .hint = "Keep a buffer made from more than 3 buffers, or one holding a reduce that reads a buffer. Each buffer becomes the next PARAM slot; an AFTER is passed as the argument itself; ranges renumber from 0." },
    .{ .file = "195_render_and_run.zig", .hint = "An INDEX into a PARAM prints as p<slot>[...]. A WHERE is C's ?:. A reduce line updates its accumulator; END opens one loop per range; a STORE prints its target first." },
    .{ .file = "196_shift_to.zig", .hint = "A reduce range unrolls up to 32, any other upcasts up to 16. top = false: old * amt + new. top = true: new * (n / amt) + old." },
    .{ .file = "197_expander.zig", .hint = "atLane() puts each lane's number in place of the range. The old reduce becomes lane u of the vector one: an INDEX. An unrolled reduce combines its lanes with its op, lane by lane." },
    .{ .file = "198_gpudims.zig", .hint = "Merge dims i and i + 1 if their product fits slot i. Divide the dim by the divisor you found. Every index but the first wraps around its dim." },
    .{ .file = "199_linearize.zig", .hint = "Loads go early: a negative priority. A key's first part is how many loops the node is inside. Take the ready node LATEST in the ideal order; a node is ready once its last user is placed." },
    .{ .file = "200_beam_for_real.zig", .hint = "Set the chosen axis's field to the amount. Stop when the best improves by less than min_progress; keep at most `width` candidates." },
    .{ .file = "c5_checkpoint_part_five.zig", .hint = "Leading axes: with `kept` elements left, element pos of x belongs to output pos % kept. A reshape is flatten, then unflatten." },
    .{ .file = "201_cuda_driver.zig", .hint = "cuMemcpyHtoD wants a pointer and a byte count. Round the block count up. kernelParams holds a POINTER to each argument, in order." },
    .{ .file = "202_gpu_roofline.zig", .hint = "Thread i reads element i * stride (as a long: it gets big). A copy reads and writes 4 bytes per element. An FMA is 2 FLOPs. The ridge is FLOPs per second over bytes per second." },
    .{ .file = "203_gpu_reduce.zig", .hint = "Threads below s add in the value s places above them. The butterfly adds the value from lane XOR o." },
    .{ .file = "204_gpu_gemm.zig", .hint = "Thread (tx, ty) loads A[row][kt*16 + tx] and B[kt*16 + ty][col]. Sync after loading, and again after computing. acc[r][c] gets a[r] * b[c]." },
    .{ .file = "205_gpu_tensor_cores.zig", .hint = "Register r's row is g, plus 8 when r is odd; its column is 2q, plus 8 for r = 2 and 3. Each k step is one call of tile()." },
    .{ .file = "206_gpu_flash_attention.zig", .hint = "The old sums shrink by exp(m - m_new). Then l gets the new weight p, and each acc gets p times its value from V." },
    .{ .file = "207_gpu_conv.zig", .hint = "One side is (size + 2 pad - kernel) / stride + 1. On the CPU the index is shifted by one, so 0 means padding. Blocked: one input value v goes into all 8 accumulators." },
    .{ .file = "208_compiler_to_gpu.zig", .hint = "gid is the block's first thread plus the thread's own index (077). A range is (gid / the sizes after it) % its own size. Each launch argument is a pointer to the u64 holding the address." },
    .{ .file = "c6_checkpoint_part_six.zig", .hint = "A sector is 32 bytes, an f32 is 4. block_max: 203's tree, with a compare where the add was, and no atomic: each block has its own out[b]." },
    .{ .file = "209_transistors.zig", .hint = "A pMOS conducts on a LOW gate. NAND: parallel up, series down; NOR is the other way round. Then every gate is some wiring of nand()." },
    .{ .file = "210_luts.zig", .hint = "The inputs, as a number, are the index of the stored bit. A flip-flop copies its LUT's answer on the tick. A counter bit flips when inputs 1 to 3 are all 1." },
    .{ .file = "211_blink.zig", .hint = "Each answer is a Zig multiline string of Verilog: lines starting with \\\\. Both swap lines read the OLD values. The blinker: if (count == HALF - 1) begin ... end else begin ... end." },
    .{ .file = "212_uart_tx.zig", .hint = "The frame, top to bottom: stop bit, data, start bit. Shifting down brings {1'b1, shift[9:1]}. In the decoder, bit k starts (k + 1) bit times after the fall; add half a bit for its middle." },
    .{ .file = "213_uart_rx.zig", .hint = "Half a bit, counted from 0. A new bit enters at the top: {rx, data[7:1]}. The echo starts the transmitter with `valid`, and the LED compares data with \"1\" and \"0\"." },
    .{ .file = "214_arm_encoding.zig", .hint = "Rotating the value LEFT by 2 * rotate undoes the instruction's rotate right. The shifts are the low bit of each field in the diagram. A branch counts from `from + 8`, in words." },
    .{ .file = "215_assembler_line.zig", .hint = "Only .data and .mul may take the s. Leftovers that aren't a condition mean: try the next base name. A plain register is shifted left by 0. Post-indexed clears `pre`; the ! sets `writeback`." },
    .{ .file = "216_assembler.zig", .hint = "A label is worth the current address; an instruction moves it by 4, a .word by 4 per value. Rounding up to a multiple of a power of two: add (to - 1), then clear the low bits. Wish number k uses pool word number k." },
    .{ .file = "217_alu.zig", .hint = "Carry: the 33rd bit of the wide sum. Overflow: the result's sign differs from both inputs' signs. a - b is a + ~b + 1. The conditions are the table in the comment, line by line." },
    .{ .file = "218_emulator.zig", .hint = "r15 reads as pc + 8. A branch offset counts words; bl saves pc + 4. [rn, #n] uses the moved address, and rn changes when the form is post-indexed or has a !. Reading the UART's data register consumes the byte." },
    .{ .file = "219_datapath.zig", .hint = "Each condition is one line: 8: pass = c && !z; and so on. Subtracting feeds the adder ~b with a carry in of 1 (or C). The carry out is sum[32]. For the shifts, copy LSL's shape: a result for n < 32, and the last bit out." },
    .{ .file = "220_cpu.zig", .hint = "The target: pc + 8 + {six copies of insn[23], insn[23:0], two zero bits}. A branch: bl (insn[24]) saves pc + 4 in r[14], then pc <= target. Data: flags only with s_bit; alu_y goes to pc when rd is 15, else to r[rd]." },
    .{ .file = "221_cpu_memory.zig", .hint = "addr is `moved` when insn[24] (P) is set. A byte's strobe is 4'b0001 << addr[1:0]. A load in EXEC only sets state <= LOAD, retired <= 0, pc <= pc; LOAD then writes rn, then rd (or pc), retires, and goes to FETCH." },
    .{ .file = "222_soc.zig", .hint = "The UART is where addr[31:28] is 4'b0001. Sending starts on a write (wstrb[0]) to register 0. Status is {30'b0, rx_have, !tx_busy}. getc is putc with the other status bit, and a load from [r1, #8] where the store was." },
    .{ .file = "223_bootrom.zig", .hint = "orr r4, r4, r0, lsl r5 puts the byte in its place; add 8 to r5 and loop until it is 32. The copy: strb r0, [r7], #1, then subs on r4 and bne. To run the program, move r6 into pc." },
    .{ .file = "224_c_lexer.zig", .hint = "A // comment stops at the newline, and a /* */ one two characters past where the */ was found. A keyword is the WHOLE name. Inside a string, a backslash takes the next character with it. Punctuation: the first entry of the list that the text starts with." },
    .{ .file = "225_c_expressions.zig", .hint = "lookup goes through `scope` from the end. An operator weaker than `min` belongs to a caller: break. The right-hand side is parseBinary(strength + 1), which makes equals group to the left. Assignment's right side is parseAssign. x++ is (x = x + 1) - 1." },
    .{ .file = "226_c_statements.zig", .hint = "An array is len times its element. A declaration appends the new local's number to scope; the end of a block cuts scope back to the length it had at the {. The else is there only if p.eat(\"else\"). A for is a block of two statements: the init, then a loop that keeps the step." },
    .{ .file = "227_c_codegen.zig", .hint = "A local is at fp minus its offset: sub r0, fp, #n. The address of *p is the value of p. A store is str r0, [r1]. The left value is in r1: sub r0, r1, r0 and cmp r1, r0. An if branches to `otherwise` when the condition is 0, and jumps to `end` after the then-part. A loop ends with a branch to `top`. Each local's offset is the frame size so far, including itself." },
    .{ .file = "228_c_pointers.zig", .hint = "An array's element is a.elem.*. &x has type pointer-to-(type of x). *p reads a byte when p points at chars. a[i] becomes a deref of the sum (a + i), which is then lowered again. In pointer + n the n is scaled by cStride of the pointer's element; in n + pointer it is the left side that is scaled." },
    .{ .file = "229_linker.zig", .hint = "Each object starts at alignUp(end, 4). A symbol's address is its object's start plus its offset. An abs32 hole gets the target address. A call24 gets target - (site + 8): the distance from where pc will be." },
    .{ .file = "230_libc.zig", .hint = "udiv: for i from 30 down to 0: r = (r << 1) | ((n >> i) & 1); if r >= d, subtract d and set bit i of q. strcmp: walk while *a is not 0 and equals *b; return *a - *b. print_int: a '-' and n = -n if negative; if n >= 10 print n / 10 first; then putchar('0' + n % 10). First fit: while (*link): take the block if block[0] >= words (unlink it with *link = (int *)block[1]), else link = (int **)(block + 1)." },
    .{ .file = "231_ethernet.zig", .hint = "The CRC step: does the register's low bit differ from the incoming bit? Shift right, and XOR the constant in if it did. In Verilog that is (crc[0] ^ data_bit) ? (crc >> 1) ^ 32'hEDB88320 : (crc >> 1). Pad to @max(len, 46). The check state sends ~crc[0] and shifts." },
    .{ .file = "232_bootloader.zig", .hint = "get_word: for shift = 0, 8, 16, 24: w = w | (getchar() << shift). The CRC's shift must clear the sign bit: (crc >> 1) & 0x7fffffff. The loop: read n, read n bytes to load[i], read the check; break if crc32(load, n) == check, else putchar('N')." },
    .{ .file = "233_traps.zig", .hint = "A trap saves cpu.r[PC] in saved_pc, leaves user mode (user = false) and jumps to the vector. The way back puts saved_pc into pc. A swi from user code is cause .syscall, and a fault records f.addr first." },
    .{ .file = "234_mmu.zig", .hint = "The page number is addr >> 12 (as a u20); the answer is the entry's ppage shifted back up, OR the address's low 12 bits. In Verilog: valid is bit 41, the virtual page bits 39..20, and paddr = {entries[i][19:0], vaddr[11:0]}." },
    .{ .file = "235_syscalls.zig", .hint = "The user's sp is at [r12, #0x10] and goes to [r0, #52]; lr goes straight to [r0, #56]; saved_pc from [r12, #0x08] to [r0, #60]. The first frame: regs[13] = 0x1c000, regs[14] = (int)&user_done, regs[15] = (int)&user_main. The table: current[0] is the number and gets the result; current[1] is the argument." },
    .{ .file = "236_processes.zig", .hint = "A new frame: frame[13] = 0x1c000 - p * 0x1000, frame[14] = (int)&user_done, frame[15] = entry. Round robin: for step = 1 to 4, p = (running + step) % 4; the first alive one becomes running, current = frames + p * 17, sys[7] = slice. A timer trap just calls schedule(); exit clears alive[running] first." },
    .{ .file = "237_address_spaces.zig", .hint = "Flush: for each i, sys[16] = i and sys[17] = 0. Every program starts at pc 0x40000000 with sp 0x80000000. page_fault: slot < 0 means 0. An empty slot gets new_page(), and a memcpy of 4096 bytes from image_base[running] + slot * 4096 if slot < image_pages[running]. Then sys[16] = next_tlb (and move it on, & 7), sys[18] = *entry, sys[17] = (addr & -4096) | 3." },
    .{ .file = "238_sd_card.zig", .hint = "Rising edge: rx <= {rx[6:0], miso}. Falling edge: shift <= {shift[6:0], 1'b0} and one bit fewer left. CRC-7: XOR 0x09 in when the register's top bit differs from the incoming bit. A command starts with 0x40 | cmd and its argument is big-endian. CMD17 takes block * 512; wait for 0xfe; then 512 exchanges of 0xff." },
    .{ .file = "239_fat.zig", .hint = "The root directory starts after the reserved blocks and all the FAT copies; the data after the root directory. Cluster n starts at data_start + (n - 2) * sectors_per_cluster. FAT entry n is in the table's block n / 256, at byte (n % 256) * 2. A first byte of 0 ends the directory; 0xe5 is a deleted entry. Reading follows fat.after(cluster); deleting sets each entry to 0, having read the link first." },
    .{ .file = "240_shell.zig", .hint = "split: skip spaces, writing 0 over them; stop at the end or at max words; note where the word starts; walk to its end. find: used[i] and strcmp(names + i * 16, name) == 0. cat: sizes[i] bytes from data + i * 256, or the error message. rm: used[i] = 0." },
    .{ .file = "241_ip_tcp.zig", .hint = "A 16-bit word is the first byte << 8, OR the second. Folding: (total & 0xffff) + (total >> 16), until nothing is above bit 15. seqBefore: the difference a -% b, read as an i32, is negative. A correct header sums (with its checksum) to 0 after finishing. TCP's sum starts from pseudoSum(src, dst, len)." },
    .{ .file = "242_tcp.zig", .hint = "Going back means sent = 0. An ack covers ack -% snd_una sequence numbers. Data is taken only if seg.seq == rcv_nxt, and rcv_nxt moves on by its length. A SYN uses up one number: rcv_nxt = seg.seq +% 1, and the answer to our SYN must acknowledge iss +% 1." },
    .{ .file = "243_telnetd.zig", .hint = "What is new is what comes after the part already passed on: received.items[typed..], then typed = received.items.len; uart_out.items[shown..]. When the program is over, close the connection." },
    .{ .file = "244_dynamic_linking.zig", .hint = "The entry: `name:` then `ldr pc, .Lslot{n}`; `.Lslot{n}: .word .Lstub{n}`; `.Lstub{n}: mov r12, #{n}`; `swi {dynamic_swi}`. The dynamic linker: look the import's name up in library.image.symbols, board.write it into program.slot(n), and set cpu.r[PC] to it." },
    .{ .file = "245_browser.zig", .hint = "The path is rest[slash..]; the port is 80 unless given. The request: GET {path} HTTP/1.0, then Host: {host}, each ending in \\r\\n, then one more \\r\\n. The body follows the first \\r\\n\\r\\n. &#65; is parseInt of what follows the #. After an entity, carry on at semi + 1. A word moves to the next line when line_len + 1 + its length is more than the width." },
    .{ .file = "c7_checkpoint_part_seven.zig", .hint = "encodeImm: rotate the value LEFT by 2 * rotate until it fits 8 bits. Overflow: the result's sign differs from both inputs'. translate: the page is addr >> 12. checksum: fold while anything is above bit 15. seqBefore: the sign of a -% b." },
};

/// How many of those are numbered exercises; the rest are checkpoints.
const numbered = count: {
    var n: usize = 0;
    for (exercises) |ex| {
        if (ex.file[0] != 'c') n += 1;
    }
    break :count n;
};

pub fn build(b: *std.Build) void {
    const check = b.allocator.create(Check) catch @panic("OOM");
    check.* = .{
        .step = .init(.{ .id = .custom, .name = "check exercises", .owner = b, .makeFn = make }),
        .only = b.option(usize, "n", "Check only exercise number n"),
        .checkpoint = b.option(usize, "checkpoint", "Check only checkpoint number n"),
        .dir = dir: {
            const solutions = b.option(bool, "solutions", "Check the reference solutions") orelse false;
            const hard = b.option(bool, "hard", "Hard mode: the exercises in hard/, where you write whole functions") orelse false;
            break :dir if (solutions) "solutions" else if (hard) "hard" else "exercises";
        },
        .fresh = b.option(bool, "fresh", "Recheck exercises that passed before") orelse false,
    };
    b.default_step.dependOn(&check.step);
}

const Check = struct {
    step: std.Build.Step,
    only: ?usize,
    checkpoint: ?usize,
    dir: []const u8,
    fresh: bool,
};

/// A fingerprint of an exercise file (and the compiler), for remembering passes.
fn fingerprint(contents: []const u8) [16]u8 {
    var h = std.hash.Wyhash.init(0);
    h.update(@import("builtin").zig_version_string);
    h.update(contents);
    return std.fmt.hex(h.final());
}

fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const check: *Check = @fieldParentPtr("step", step);
    const b = step.owner;
    const p = std.debug.print;

    if (check.only) |n| {
        if (n == 0 or n > numbered) {
            p("There is no exercise {d}. Pick 1 to {d}.\n", .{ n, numbered });
            std.process.exit(2);
        }
    }
    if (check.checkpoint) |c| {
        if (c == 0 or c > exercises.len - numbered) {
            p("There is no checkpoint {d}. Pick 1 to {d}.\n", .{ c, exercises.len - numbered });
            std.process.exit(2);
        }
    }
    const one = check.only != null or check.checkpoint != null;

    // Put this zig first on PATH, so exercises that run `zig cc` (052)
    // use the same compiler as the build.
    var env = try b.graph.environ_map.clone(b.allocator);
    const zig_dir = std.fs.path.dirname(b.graph.zig_exe) orelse ".";
    const old_path = env.get("PATH") orelse "";
    const sep = if (@import("builtin").os.tag == .windows) ";" else ":";
    try env.put("PATH", b.fmt("{s}{s}{s}", .{ zig_dir, sep, old_path }));

    // Where passes are remembered: one small file per exercise, holding the
    // fingerprint of the version that passed.
    const io = b.graph.io;
    const memo_dir = b.pathJoin(&.{ "zigrad", check.dir });
    b.cache_root.handle.createDirPath(io, memo_dir) catch {};

    // Remembered passes are summarized in one line instead of one each.
    var skipped: usize = 0;
    var first_skipped: []const u8 = "";
    var last_skipped: []const u8 = "";

    for (exercises, 0..) |ex, done| {
        if (one) {
            // "017_..." is exercise 17, "c2_..." is checkpoint 2
            const is_checkpoint = ex.file[0] == 'c';
            const digits = if (is_checkpoint) ex.file[1..2] else ex.file[0..3];
            const number = std.fmt.parseInt(usize, digits, 10) catch unreachable;
            const wanted = if (is_checkpoint) check.checkpoint else check.only;
            if (wanted == null or wanted.? != number) continue;
        }
        const rel = b.pathJoin(&.{ check.dir, ex.file });
        const name = ex.file[0 .. ex.file.len - ".zig".len];

        const memo = b.pathJoin(&.{ memo_dir, name });
        const contents = b.build_root.handle.readFileAlloc(io, rel, b.allocator, .limited(1 << 24)) catch "";
        const print = fingerprint(contents);
        if (!check.fresh and !one) {
            const old = b.cache_root.handle.readFileAlloc(io, memo, b.allocator, .limited(64)) catch "";
            if (std.mem.eql(u8, old, &print)) {
                if (skipped == 0) first_skipped = name;
                last_skipped = name;
                skipped += 1;
                continue;
            }
        }
        if (skipped > 0) {
            printSkipped(skipped, first_skipped, last_skipped);
            skipped = 0;
        }

        // A few exercises need extra flags for `zig test` (the GPU ones link
        // libc, to load the driver). They say so in a line of the file:
        // `// zig test flags: -lc`.
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(b.allocator, &.{ b.graph.zig_exe, "test" });
        const marker = "\n// zig test flags: ";
        if (std.mem.indexOf(u8, contents, marker)) |at| {
            const start = at + marker.len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '\n') orelse contents.len;
            var flags = std.mem.tokenizeScalar(u8, contents[start..end], ' ');
            while (flags.next()) |flag| try argv.append(b.allocator, flag);
        }
        try argv.append(b.allocator, b.pathFromRoot(rel));

        const result = try std.process.run(b.allocator, b.graph.io, .{
            .argv = argv.items,
            .cwd = .{ .path = b.pathFromRoot(".") },
            .environ_map = &env,
        });
        const passed = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };

        if (passed) {
            p("  ✓ {s}\n", .{name});
            b.cache_root.handle.writeFile(io, .{ .sub_path = memo, .data = &print }) catch {};
            continue;
        }

        p("  ✗ {s}\n\n{s}\n", .{ name, result.stderr });
        if (!one) {
            const width = 40;
            const filled = done * width / exercises.len;
            p("Progress: [", .{});
            for (0..width) |i| p("{s}", .{if (i < filled) "█" else "░"});
            p("] {d}/{d}\n", .{ done, exercises.len });
        }
        p("Hint: {s}\n\n", .{ex.hint});
        p("Edit {s} and run `zig build` again.\n", .{rel});
        if (std.mem.eql(u8, check.dir, "hard")) p("Too much for now? The fill-in version is exercises/{s}\n", .{ex.file});
        p("Really stuck? The answer is in solutions/{s}\n", .{ex.file});
        std.process.exit(2);
    }

    if (skipped > 0) printSkipped(skipped, first_skipped, last_skipped);

    if (!one) {
        p(
            \\
            \\All {d} exercises and checkpoints pass. From flat memory to transformers, from the
            \\chain rule to tensor cores and warp shuffles, from UIR through rangeify
            \\to kernels running on your own GPU: you've built every major piece of
            \\tinygrad and the maths underneath it. And then the machine under that:
            \\gates, a processor, a compiler, an operating system, a network stack and
            \\a browser, from the transistor up.
            \\
            \\Next: read tinygrad's own source (github.com/tinygrad/tinygrad), and build
            \\your own compiler: project/README.md. You'll recognize all of it.
            \\
        , .{exercises.len});
    }
}

fn printSkipped(count: usize, first: []const u8, last: []const u8) void {
    if (count == 1) {
        std.debug.print("  ✓ {s}\n", .{first});
    } else {
        std.debug.print("  ✓ {s} ... {s} ({d} passed before)\n", .{ first, last, count });
    }
}
