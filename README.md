# zigrad

A zero-to-hero course on [tinygrad](https://github.com/tinygrad/tinygrad), on deep learning, and on the maths underneath both, taught by rebuilding it all in Zig one small broken program at a time. The format follows [ziglings](https://codeberg.org/ziglings/exercises).

There are 208 exercises in six parts, with a checkpoint after each part. Each exercise teaches a single idea in its comments, then leaves you a hole or a bug to fix. Fix it and the tests at the bottom pass. Each checkpoint asks you to write, from memory, functions from all over the part you just finished. You don't need any maths beyond school algebra, or any prior Zig: both are introduced as they come up.

Parts I–IV teach the ideas with small, made-up IRs. Part V rebuilds tinygrad as it is today, with its real UOps, the UIR text format, rangeify and its code generator, the way George Hotz's [10-411](https://10-411.com/) course specifies them. Part VI runs machine learning kernels on a real NVIDIA GPU; without one, its tests compile the kernels and then skip.

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
| `zig build -Dcheckpoint=2` | Check only checkpoint 2 |
| `zig build -Dhard` | Hard mode: the same course from `hard/`, where you write whole functions instead of filling blanks |
| `zig build -Dfresh` | Recheck everything, ignoring remembered passes |
| `zig test exercises/017_reduce_axis.zig` | Run one file's tests directly (`zig test -lc ...` for Part VI, which loads the GPU driver; `zig build` adds it for you) |

Stuck? Every exercise has a finished version in `solutions/`. Try for a while first, though: the struggle is where the learning happens.

## How to get the most out of it

The course has three levels of difficulty, on purpose. Filling a blank in code that is otherwise finished is the best way to *start* on something new: for a beginner, studying a nearly worked example beats solving from scratch. But that advantage disappears, and then reverses, as you get better (the "expertise reversal effect"), so the support has to fade or you stop learning from it.

| Level | Where | What you do |
|---|---|---|
| Fill in | `exercises/`, `zig build` | Complete a few expressions in finished code. Start here for anything new to you. |
| Hard mode | `hard/`, `zig build -Dhard` | Every function that had a blank has lost its whole body. Same tests, same hints. Progress is tracked separately, so you can do both. |
| Checkpoints | `c1` to `c6`, in the normal run after each part | No blanks and nothing new: five functions from five different chapters, written from memory. |

Some habits that the research on learning supports, and that this format makes easy:

- **Recall before you look.** Trying to pull an answer out of your own head, even when you fail, does more for memory than rereading the explanation. When you're stuck on a checkpoint, read *your own* finished exercise, close it, then write the function.
- **Come back later.** Redo an exercise in hard mode a few days after you first filled it in, not five minutes after. Forgetting a little first is what makes the second pass work. A good rhythm: fill in a chapter today, do the previous chapter in hard mode tomorrow.
- **Predict, then run.** Before `zig build`, say what the tests will print or which one will fail. Several exercises ask for this directly ("Predict it!"); do it for the others too, and for every benchmark: guess the GFLOPS before you see them.
- **Mix it up.** The checkpoints jumble their topics so that you have to work out *which* idea a problem needs. That is harder than a chapter where every exercise uses the idea you just read, and it is the skill you need in a real codebase.
- **Break it on purpose.** After an exercise passes, change one thing (a `<` to a `<=`, an axis, a stride) and predict which test catches it. `tools/mutate.py` does this to the reference answers; 190 makes a game of it.

These feel slower and harder than rereading. That is the point: the difficulty is what makes it stick. Background: [the worked-example and expertise-reversal effects](https://en.wikipedia.org/wiki/Worked-example_effect), [fading from examples to problems](https://faculty.engineering.asu.edu/mre/wp-content/uploads/sites/31/2020/02/1124_final.pdf), [retrieval, spacing and interleaving as "desirable difficulties"](https://edcog.pnb.mcmaster.ca/?p=1267), and [predicting before running (PRIMM)](https://static.teachcomputing.org/pedagogy/QR11-PRIMM.pdf).

## Learning paths

208 exercises is a lot. You don't have to do them in one straight line:

| If you want to... | Do |
|---|---|
| understand how tinygrad works, fast | Part I (001–053), then chapter 30 (156–160) |
| understand tinygrad as it is today | chapters 1–4 (001–025), then Part V (181–200) |
| learn the maths of deep learning | chapters 1–7 (001–039), then 11–13 (054–070) and 16–18 (082–101) |
| write fast kernels | chapters 1–4 and 8–10 (001–025, 040–053), then 14–15 (071–081), 28–29 (146–155), 31–32 (161–170), 38 (196–200) and Part VI (201–208) |
| understand modern LLMs | chapters 1–7 (001–039), 16–17 (082–095), 22 (116–120), 27 (141–145) and 33–34 (171–180) |
| build an ML compiler (George Hotz's [Compilers for Machine Learning](https://10-411.com/), CMU 10-411) | chapters 1–8 (001–043) for the ideas, then Part V (181–200) for the real IR, UIR, rangeify and codegen, Part VI (201–208) for GPUs, and the [final project](project/README.md), which maps every week of the course to the exercises |
| everything | 001 to 208 in order: each part builds on the ones before |
| the most challenge | `zig build -Dhard` from the start, dropping back to `exercises/` only for a file that defeats you |

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


## Part V: tinygrad today, the way 10-411 builds it

| Chapter | Exercises | You learn |
|---|---|---|
| 35. The UOp | 181–185 | weak dtypes and the promotion lattice; the hash-consed UOp with tinygrad's leading-axis shape rules; exact ALU semantics (floor DIV/MOD, i32 wraparound, f32 rounding); functions as PARAM and CALL; vmin/vmax and compile-time bounds checks |
| 36. UIR, the text format | 186–190 | parsing and printing UIR, 10-411's interchange format (and tinygrad's `uir.py`); an interpreter for memory, AFTER ordering, loops, movement ops and REDUCE; writing tests that catch other people's compiler bugs |
| 37. Rangeify | 191–195 | movement ops as index maths on ranges; where kernels split; lowering to STORE/INDEX/END/AFTER; cheap buffers and kernels as CALLs; rendering, compiling and running the gist's matmul |
| 38. Codegen | 196–200 | splitting ranges (OptOps.SPLIT, shift_to); UPCAST as vector lanes and register blocking (30x on a matmul); fitting axes to the GPU grid; linearizing with tinygrad's priorities; BEAM search over real compiled kernels |

## Part VI: machine learning kernels on a real GPU

| Chapter | Exercises | You learn |
|---|---|---|
| 39. The driver | 201–202 | the CUDA driver API from Zig, the way tinygrad's CUDA backend uses it; PTX; C kernels compiled to PTX by `zig cc`; your GPU's measured bandwidth, FLOPs, ridge point, and the price of uncoalesced reads |
| 40. ML kernels | 203–207 | reductions with atomics, shared-memory trees and warp shuffles; naive, tiled and register-blocked matmuls; tensor cores with `mma.sync` and its fragment layouts; flash attention with an online softmax; a convolution, direct and blocked over output channels |
| 41. The whole stack | 208 | Part V's compiler meets Part VI's driver: a tensor graph goes through rangeify, comes out as CUDA kernels with the output ranges as the grid, and runs on your GPU |

Want the whole picture before you start? `examples/tinygrad_in_one_file.zig` puts Part I's core together in about 500 lines:

```sh
zig run examples/tinygrad_in_one_file.zig
```

## Final project

Build your own ML compiler, following George Hotz's [Compilers for Machine Learning](https://10-411.com/) course (CMU 10-411) and its [technical syllabus](https://gist.github.com/geohot/4768597d9dc536446ee2d5de1f29e89d) week by week, from UOps and rewrites to training LLMs on GPUs. [`project/`](project/README.md) maps every week to the exercises, gives the current UIR format, and explains what 10-411's AI policy means for code from this repository if you take the course for credit. It also has a small compiler in one Zig file, with an oracle and a fuzz test.

```sh
zig test project/minicompiler.zig
```

## Going further

See [RESOURCES.md](RESOURCES.md) for the best books, courses, videos, articles and papers to go with each chapter.

## Afterwards

Use the real thing. [TINYGRAD.md](TINYGRAD.md) is a field guide to programming tinygrad itself: how to pick a device, what each `DEBUG` level shows, twelve experiments that make tinygrad print the kernels you wrote by hand, and a map from every tinygrad source file to the exercises that rebuilt it. It works best alongside Part V.

Read tinygrad's own source. The names you'll meet there (`UOp`, `graph_rewrite`, `PatternMatcher`, `UPat`, movement ops, `run_rangeify`, `apply_movement_op`, `remove_bufferize`, `shift_to`, the expander, `linearize`, renderers, OptOps, `BEAM`, `TinyJit`, HCQ, `render_uir`) are all things you've built. tinygrad changes quickly, so details will differ, but the ideas are the ones in this course. Every tinygrad fact in the exercises was checked against its source in November 2026 (tinygrad commit `411dd8d`).

## Maintaining the exercises

`exercises/`, `hard/` and `solutions/` are generated: don't edit them by hand. Each exercise is one template in `tools/templates/`, where `⟪answer|||hole⟫` marks a hole (or `//⟪` ... `//|||` ... `//⟫` for multi-line ones). Shared code lives in `tools/templates/snippets/` and is pulled in with `//@include name`. A template can also wrap code in `//@export name` ... `//@end`: later exercises `//@include name` its finished version, so an exercise and the exercises built on it can't drift apart (Part V works this way). An exercise that needs extra `zig test` flags says so in a line `// zig test flags: -lc`, which `zig build`, `verify.sh` and `mutate.py` all read.

```sh
python3 tools/gen.py      # regenerate exercises/, hard/ and solutions/
tools/verify.sh           # every exercise fails (both versions), every solution passes and is zig fmt clean
tools/verify.sh 07        # just exercises 070-079
python3 tools/check_holes.py   # every compile error points at a ??? hole
python3 tools/mutate.py 18     # mutation testing: do the tests catch wrong answers?
```

`tools/mutate.py` takes each hole's answer, makes one small mistake in it (a flipped operator, a constant off by one, swapped arguments, a dropped line), and checks that the exercise's tests then fail. A mistake that passes is either a gap in the tests or an equivalent answer; the known equivalent ones are listed, with the reason, in `tools/mutants_ok.txt`. Run it on any exercise you change.

GitHub Actions runs all of these on every push (`.github/workflows/check.yml`): mutation testing on the templates a change touches, and on everything once a week. CI has no GPU, so Part VI's tests compile their kernels there and skip the rest.

`hard/` needs no extra writing: `gen.py` takes each function that contains a hole and replaces its whole body with one hole (functions longer than 40 lines keep their fill-in holes). Checkpoints are ordinary templates named `c1_...`, whose holes are whole function bodies.

New exercises also need an entry, with a hint, in `build.zig`. Two rules the tools can't fully check for you: an exercise must not show its own answer anywhere else in the file (in the header comment, in a test, in a neighbouring function), and it may only `//@include` exports of *earlier* exercises (`gen.py` refuses the other direction, because it would paste a later exercise's answers into this one).

## License

MIT: see [LICENSE](LICENSE).
