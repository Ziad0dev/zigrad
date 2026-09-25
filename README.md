# zigrad

A zero-to-hero course on [tinygrad](https://github.com/tinygrad/tinygrad), on deep learning, and on the maths underneath both, taught by rebuilding it all in Zig one small broken program at a time. The format follows [ziglings](https://codeberg.org/ziglings/exercises).

There are 180 exercises in four parts. Each one teaches a single idea in its comments, then leaves you a hole or a bug to fix. Fix it and the tests at the bottom pass. You don't need any maths beyond school algebra, or any prior Zig: both are introduced as they come up.

## Getting started

You need **Zig 0.16.0** ([download](https://ziglang.org/download/)).

Or, with [Nix](https://nixos.org/download/) (flakes enabled), get it from the dev shell in this repo:

```sh
nix develop               # a shell with zig 0.16.0 (and python3)
```

With [direnv](https://direnv.net/) (plus [nix-direnv](https://github.com/nix-community/nix-direnv) for caching), run `direnv allow` once in the repo and the shell loads by itself every time you `cd` in.

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

Fix the file, run `zig build` again, and repeat. Exercises that already pass are remembered, so reruns are instant: only new or edited files get checked again.

| Command | What it does |
|---|---|
| `zig build` | Check all exercises in order |
| `zig build -Dn=17` | Check only exercise 17 |
| `zig build -Dsolutions` | Check the reference solutions |
| `zig build -Dfresh` | Recheck everything, ignoring remembered passes |
| `zig test exercises/017_reduce_axis.zig` | Run one file's tests directly |

Stuck? Every exercise has a finished version in `solutions/`. Try for a while first, though: the struggle is where the learning happens.

## Learning paths

180 exercises is a lot. You don't have to do them in one straight line:

| If you want to... | Do |
|---|---|
| understand how tinygrad works, fast | Part I (001–053), then chapter 30 (156–160) |
| learn the maths of deep learning | chapters 1–7 (001–039), then 11–13 (054–070) and 16–18 (082–101) |
| write fast kernels | chapters 1–4 and 8–10 (001–025, 040–053), then 14–15 (071–081), 28–29 (146–155) and 31–32 (161–170) |
| understand modern LLMs | chapters 1–7 (001–039), 16–17 (082–095), 22 (116–120), 27 (141–145) and 33–34 (171–180) |
| everything | 001 to 180 in order: each part builds on the ones before |

Later exercises point back to the earlier ones they use (for example "softmax (018)"), so if you skip ahead and meet something unfamiliar, the number tells you where it's taught. `zig build -Dn=N` checks a single exercise.

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

## Part IV: performance engineering and modern models

| Chapter | Exercises | You learn |
|---|---|---|
| 31. The CPU, for real | 161–165 | a SIMD matmul microkernel with FMA; splitting work over threads; false sharing; Amdahl's and Gustafson's laws; Little's law and latency hiding |
| 32. How GPUs execute | 166–170 | occupancy; warp divergence; warp shuffles; parallel prefix sums; Triton-style block programming with masks |
| 33. Inside modern LLMs | 171–175 | RMSNorm; SwiGLU; grouped-query attention; nucleus (top-p) sampling; mixture-of-experts routing |
| 34. Measure, don't guess | 176–180 | honest benchmarking; 6ND and MFU; Chinchilla scaling laws; the speed limit of decoding; a LLaMA-style transformer block, checked against its KV-cache version |

Want the whole picture before you start? `examples/tinygrad_in_one_file.zig` puts Part I's core together in about 500 lines:

```sh
zig run examples/tinygrad_in_one_file.zig
```

## Going further

See [RESOURCES.md](RESOURCES.md) for the best books, courses, videos, articles and papers to go with each chapter.

## Afterwards

Read tinygrad's own source. The names you'll meet there (`UOp`, `graph_rewrite`, `PatternMatcher`, `UPat`, movement ops, the scheduler, renderers, OptOps, `BEAM`, `TinyJit`, HCQ) are all things you've built. tinygrad changes quickly, so details will differ, but the ideas are the ones in this course. Every tinygrad fact in the exercises was checked against its source as of September 2026.

## Maintaining the exercises

`exercises/` and `solutions/` are generated: don't edit them by hand. Each exercise is one template in `tools/templates/`, where `⟪answer|||hole⟫` marks a hole (or `//⟪` ... `//|||` ... `//⟫` for multi-line ones). Shared code lives in `tools/templates/snippets/` and is pulled in with `//@include name`.

```sh
python3 tools/gen.py      # regenerate exercises/ and solutions/
tools/verify.sh           # every exercise fails, every solution passes and is zig fmt clean
tools/verify.sh 07        # just exercises 070-079
python3 tools/check_holes.py   # every compile error points at a ??? hole
```

GitHub Actions runs all of these on every push (`.github/workflows/check.yml`).

New exercises also need an entry, with a hint, in `build.zig`.

## License

MIT: see [LICENSE](LICENSE).
