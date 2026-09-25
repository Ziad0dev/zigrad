# zigrad

A zero-to-hero course on [tinygrad](https://github.com/tinygrad/tinygrad), on deep learning, and on the maths underneath both, taught by rebuilding it all in Zig one small broken program at a time. The format follows [ziglings](https://codeberg.org/ziglings/exercises).

There are 160 exercises in three parts. Each one teaches a single idea in its comments, then leaves you a hole or a bug to fix. Fix it and the tests at the bottom pass. You don't need any maths beyond school algebra, or any prior Zig: both are introduced as they come up.

## Getting started

You need **Zig 0.16.0** ([download](https://ziglang.org/download/)).

```sh
zig build
```

That checks the exercises in order and stops at the first one that doesn't pass yet, with a hint:

```
  ✓ 001_tensor_is_numbers
  ✗ 002_floats

exercises/002_floats.zig:27:15: error: expected type expression, found ';'
...
Hint: For approxEq, how far apart are a and b? ...
```

Fix the file, run `zig build` again, and repeat.

| Command | What it does |
|---|---|
| `zig build` | Check all exercises in order |
| `zig build -Dn=17` | Check only exercise 17 |
| `zig build -Dsolutions` | Check the reference solutions |
| `zig test exercises/017_reduce_axis.zig` | Run one file's tests directly |

Stuck? Every exercise has a finished version in `solutions/`. Try for a while first, though: the struggle is where the learning happens.

## Part I: build tinygrad in miniature

| Chapter | Exercises | You learn |
|---|---|---|
| 1. Numbers in a row | 001–004 | tensors are flat memory; float pitfalls; elementwise and reduce kernels |
| 2. Shapes and views | 005–014 | shapes, strides, views; reshape, permute, expand/broadcast, shrink, flip and pad without copying |
| 3. Ops from primitives | 015–020 | exp and log from exp2/log2; sigmoid and tanh; axis reductions; stable softmax; matmul and convolution built from movement ops |
| 4. The lazy graph | 021–025 | building a graph instead of computing; memoized evaluation; topological sort; hash-consing; rewrite rules |
| 5. Derivatives | 026–032 | slopes; derivative rules; chain rule; dual numbers; backpropagation; gradient descent |
| 6. Tensor gradients | 033–036 | gradients of broadcasting and movement ops; matmul gradient; cross-entropy |
| 7. Training | 037–039 | weight initialization; momentum and Adam; training a network on XOR |
| 8. The compiler | 040–043 | scheduling and kernel fusion; linearizing; rendering C; a tiny device to run kernels |
| 9. Fast kernels | 044–048 | the roofline model; unrolling and SIMD; tiling; parallel reductions; BEAM search |
| 10. The runtime | 049–053 | f16, bf16 and int8; memory planning; the JIT; compiling with `zig cc` and loading with `std.DynLib`; multiple devices |

## Part II: going deeper

| Chapter | Exercises | You learn |
|---|---|---|
| 11. Linear algebra | 054–059 | vectors as arrows; matrices as functions; the transpose; solving linear systems; eigenvalues and the learning-rate limit; outer products and LoRA |
| 12. Probability | 060–064 | distributions and Box-Muller; where losses come from (maximum likelihood); entropy, cross-entropy and KL; sampling with temperature and top-k; counter-based random numbers |
| 13. Autograd, properly | 065–070 | Jacobians; vector-Jacobian products; forward vs reverse mode; a tensor autograd engine; gradients as graphs; Newton's method |
| 14. Symbolic index maths | 071–075 | interval bounds; simplifying index expressions; views as index expressions; stacked views; symbolic shapes |
| 15. Real code generation | 076–081 | reduce loop nests; GPU grids; shared memory and barriers; OptOps; tensor cores; store vs recompute |
| 16. Neural network layers | 082–089 | linear, LayerNorm, BatchNorm, conv2d forward and backward, pooling, embeddings, dropout: all gradient-checked |
| 17. Transformers | 090–095 | attention; causal masks; multi-head attention; positional encodings and RoPE; the KV cache; flash attention |
| 18. Training in practice | 096–101 | loss functions; learning-rate schedules; AdamW; gradient clipping; mixed precision; overfitting and regularization |
| 19. Capstone | 102–105 | a data pipeline, then an MLP and a CNN trained to >90% on noisy digits, then evaluation beyond accuracy |
| 20. Down to the metal | 106–110 | command queues and signals; overlapping copies with compute; launch overhead and graphs; ring all-reduce; loading safetensors |

## Part III: the rest of the map

| Chapter | Exercises | You learn |
|---|---|---|
| 21. Sequence models | 111–115 | RNNs; backpropagation through time; vanishing and exploding gradients; LSTMs; residual connections |
| 22. Language modeling | 116–120 | tokenizing text; byte-pair encoding; bigram models; perplexity; a neural model that rediscovers the counts |
| 23. Generative models | 121–125 | PCA; the maths of VAEs; diffusion, forward and reverse; GAN losses |
| 24. Reinforcement learning | 126–130 | bandits; the Bellman equation; Q-learning; policy gradients; reward models and DPO |
| 25. Optimization theory | 131–135 | convexity; Adagrad and RMSprop; line search; weight averaging; saddle points |
| 26. Training at scale | 136–140 | gradient accumulation; activation checkpointing; tensor and pipeline parallelism; ZeRO |
| 27. Efficient inference | 141–145 | int8 matmuls; int4 packing; group-wise quantization; speculative decoding; paged KV caches |
| 28. Numerics inside kernels | 146–150 | Kahan summation; exp2, sin and log2 from scratch; the fast inverse square root |
| 29. The memory hierarchy | 151–155 | caches; loop order; coalescing; bank conflicts; register blocking |
| 30. tinygrad internals | 156–160 | UPat pattern matching; dtype promotion; strength reduction; in-place safety; a final mini-tinygrad capstone |

Want the whole picture before you start? `examples/tinygrad_in_one_file.zig` puts Part I's core together in about 500 lines:

```sh
zig run examples/tinygrad_in_one_file.zig
```

## Going further

See [RESOURCES.md](RESOURCES.md) for the best books, courses, videos, articles and papers to go with each chapter.

## Afterwards

Read tinygrad's own source. The names you'll meet there (`UOp`, `graph_rewrite`, `PatternMatcher`, views, the scheduler, renderers, OptOps, `BEAM`, `TinyJit`, HCQ) are all things you've built. tinygrad changes quickly, so details will differ, but the ideas are the ones in this course.

## Maintaining the exercises

`exercises/` and `solutions/` are generated: don't edit them by hand. Each exercise is one template in `tools/templates/`, where `⟪answer|||hole⟫` marks a hole (or `//⟪` ... `//|||` ... `//⟫` for multi-line ones). Shared code lives in `tools/templates/snippets/` and is pulled in with `//@include name`.

```sh
python3 tools/gen.py      # regenerate exercises/ and solutions/
tools/verify.sh           # every exercise fails, every solution passes and is zig fmt clean
tools/verify.sh 07        # just exercises 070-079
```

New exercises also need an entry, with a hint, in `build.zig`.
