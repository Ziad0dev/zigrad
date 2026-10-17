# Final project: your own ML compiler

The project follows **[10-411: Compilers for Machine Learning](https://geohot.github.io/web10411/)**, George Hotz's course at Carnegie Mellon (Spring 2027), and its **[technical syllabus](https://gist.github.com/geohot/4768597d9dc536446ee2d5de1f29e89d)**, which specifies the compiler week by week. Both are drafts, still changing as of October 2026. In ten weeks you build a compiler from scratch, starting with elementwise programs and ending with training LLMs on GPUs. Then you spend four weeks on a project of your own.

Each week below gives what the spec adds, what to build, the exercises that teach it, and a test that tells you you're done.

## What's here

`minicompiler.zig` is a real, working, deliberately simple ML compiler in one file, tests included. It takes a lazy tensor graph, turns movement ops into index maths, fuses everything between reductions into one kernel, writes C, compiles it with `zig cc`, loads it with `std.DynLib`, runs it, and benchmarks it.

```sh
zig test project/minicompiler.zig
```

It prints the C it generates for a matmul (written the tinygrad way, as reshape + expand + mul + sum) and times it against a plain Zig loop. It works. It's also slow, and its code is ugly: it takes every shortcut the course teaches you to replace.

It also has **an oracle**: `interpret`, a slow, obviously correct interpreter (whole tensors, one op at a time, nothing fused or compiled). `expectMatchesOracle` checks any compiled graph against it, and a fuzz test throws random graphs at both.

## Two ways to do it

1. **The 10-411 way: from scratch.** Start from an empty file, in any language you like; the course has no starter code. Follow the spec's weeks below. Read `minicompiler.zig` for ideas, but port its oracle and fuzz test first, and write the rest yourself.
2. **Grow `minicompiler.zig`.** Week by week, replace its shortcuts with the spec's design. Each week has a "minicompiler" note saying where it stands. Keep every test passing.

Either way, **tests come first**. Each week of 10-411 starts with ten tests, due before the compiler. The tests are judged by an openly accessible oracle. Every compiler is graded on passing all students' tests plus the teachers', and a correct test that breaks other compilers earns bonus credit. So: write your ten tests, then make them pass. When you add an op, teach the oracle first.

## The format

The spec defines the compiler's IR as hash-consed UOps, `UOp(op, src: tuple[UOp, ...], arg)`. Every UOp carries a dtype (`void`, `bool`, `i32`, `f32`) and a shape. It also introduces a simple text format for UOp programs, so that tests can be shared between compilers written in any language. This is the spec's example:

```
# gemm_256x256.uir
%0 = buffer 65536 : dtype=f32 slot=0
%1 = buffer 65536 : dtype=f32 slot=1
%2 = reshape %0 [256 256 1]
%3 = reshape %1 [256 1 256]
%4 = mul %2 %3
%5 = reduce %4 : op=add pop=1
```

It's a matmul in four ops: two reshapes, a broadcasting multiply, and a sum. The format isn't fully specified yet (the gist says it "will be established"). For example, the gist doesn't yet spell out which axis `pop=1` removes. Reading it as the leading axis, the one both inputs share, matches how `INDEX` "pops axes off the left", and makes this exactly a GEMM, `C = AᵀB`. Write a parser and a printer for it in week 1, and keep them up to date as the spec settles.

## Week by week

### Week 1. UOps and rewrites (015, 021–025, 042, 071–072, 156–158)
**Spec:** `PARAM`, `CALL`, `CONST`, `STACK` (a new leading axis), `INDEX` (pops axes off the left), `CAST`, `RECIPROCAL`/`LOG2`/`EXP2`/`SIN`, `ADD`/`MUL`/`MAX`/`CMPLT`, `FLOORDIV`/`FLOORMOD`, `WHERE`. Until week 4, inputs can only be `STACK` or `CONST`.

Build a hash-consed UOp (024) and a bottom-up greedy rewrite engine (025, 156). The engine "runs" programs by constant folding, so in week 1 your compiler is also an interpreter. Add dtype promotion (157), symbolic simplification (071–072, 158), and a renderer to C (042). The ALU set is deliberately small: everything else is built from it, like 015's `exp` from `EXP2` and `MUL`.

**minicompiler:** nodes aren't hash-consed, nothing is rewritten, and index expressions are strings, so nothing can simplify them. Its matmul kernel reads `b1[0+(((0+(r)*1+(i0)*48)/1%48))*1+(((0+(r)*1+(i0)*48)/48%64))*48]`, which is `b1[i0*48 + r]`.

**Done when** a program built only from `STACK`, `CONST` and ALU ops folds to its answer, `x*1 + 0` rewrites to `x`, and (in minicompiler) the matmul kernel reads `b1[i0*48+r]` and `b2[r*32+i1]`.

### Week 2. Rendering, runtime and memory (023, 041–043, 049, 052, 159)
**Spec:** an address space per UOp (`GLOBAL`, `ALU`), and `BUFFER`, `ALLOC` (call-scoped storage, like `float a[10]`), `LOAD`/`STORE`, `AFTER(buf, <store>)`. Loads and stores must be fully ordered.

Render loopless C functions that read and write memory, compile them, and run them (042, 043, 052). Toposort for the order (023) and linearize into SSA (041), so every value is computed once. `AFTER(buf, store)` is the buffer as it is once that store has happened, so a load from it can't be reordered before the store. Getting this order right is also what makes in-place updates safe (159).

**minicompiler:** the renderer turns the tensor graph straight into one C expression, so anything used twice is copied, and `max` uses each operand twice. Ten nested relus load `b1` **1024 times**, in 46 KB of C.

**Done when** a program that stores, then loads the same buffer, runs correctly, and (in minicompiler) ten nested relus load `b1` once.

### Week 3. Loops (019–020, 041, 076)
**Spec:** `RANGE` (src is the end, arg is the name) and `END` (srcs are a passthrough and the range). Basic rangeify is allowed.

With loops, you can write GEMMs and convolutions by hand in the IR, with explicit index maths on flat buffers (019, 020). A reduction becomes a range plus an accumulator (076).

**minicompiler:** loops are written by the renderer as text, not part of any IR.

**Done when** hand-written GEMM and convolution programs match reference loops (and the oracle).

### Week 4. Rangeify, fusion and fission (012, 017, 040, 050, 076, 081)
**Spec:** `REDUCE` (an axis count and an op) and `STAGE` (a temporary buffer). Shapes are still rank < 2, and `LOAD` can be implicit.

Rangeify turns shapes into loops, so that no op has a shape any more. Broadcasting (012) and reductions (017) become index maths over ranges. Then face materialization: which values get a buffer (`STAGE`) and which are recomputed. That decides where kernels split (fusion and fission; 040, 081) and how much memory they need (050).

**minicompiler:** its only rule is that every sum gets its own kernel and everything else is recomputed by every reader. Replace that with 081's store-or-recompute cost.

**Done when** you can predict the kernel count of every test graph, and the fuzz test still passes.

### Week 5. Movement ops and autodiff (009–014, 019–020, 030–035, 068–069, 073–074, 090–094, 102–103)
**Spec:** `STACK` with arbitrary inputs, and `RESHAPE`/`EXPAND`/`PERMUTE`/`SHRINK`. Shapes of rank ≥ 2 arrive, and `PAD` and `FLIP` are composites. Autodiff works on pure shape graphs: not `STORE`, `CALL`, `AFTER`, `RANGE` or `END`.

Movement ops become index maths (073–074), and GEMMs and convolutions now fall out of them (019–020): the `.uir` example above. Build backward as more graph (069): one gradient rule per op, and movement-op gradients from 034 (expand's is a sum, shrink's is a pad, ...). Your compiler can now compile any model, split it into kernels, and train it.

**minicompiler:** has `RESHAPE`, `EXPAND` and `PERMUTE`; add `SHRINK` (013) and the composites (014), and autodiff.

**Done when** you train your first MNIST (103's digits are a smaller start) and run a simple LLM, such as the transformer block of 180 matching its reference output.

### Week 6. Memory hierarchies, multithreading and fast kernels (044–048, 095, 151–155, 161–165, 177)
**Spec:** each range has an axis type: `LOOP`, `UPCAST` or `THREAD`.

Count FLOPs and bytes per kernel from the IR (177), so you know where each one sits on the roofline (044). Then make kernels fast, still on the CPU:

1. Put the reduce loop where it reads memory contiguously (152).
2. Tile it (046).
3. Upcast into a register block of vector types (045, 155, 161).
4. Split the outer loop across threads (162).

Choose among the variants with a BEAM search (048). Do the same for reduces and convolutions. Then flash attention (095): attention without ever writing the full score matrix to memory.

**minicompiler:** the benchmark test prints its matmul GFLOPS. Start there.

**Done when** the 256x256 matmul runs at least 10x faster than at the start, and attention's memory grows linearly with sequence length. The course's bar is SOTA-competitive C: compare with a BLAS library (benchmark it, don't call it).

### Weeks 7–8. GPUs and hardware accelerators (077–080, 106–108, 153–154, 166–170)
Add kernels for GPUs: a CUDA or HIP renderer, and a runtime that allocates device memory, copies, and launches (106–108). Map ranges to the grid, blocks and threads (077), and reduce through shared memory (078) or warp shuffles (168). Then make it fast: coalesce loads (153), avoid bank conflicts (154), watch occupancy (166), and use tensor cores (080). Needs a CUDA-capable GPU.

**Done when** the fuzz test passes on the GPU backend, and a large half-precision matmul is competitive with what PyTorch gets on the same GPU.

### Weeks 9–10. Real models (038, 051, 063, 075, 093–094, 096–101, 110, 116–117, 171–175, 179–180)
**Spec topics:** real models, and `symbolic`.

Inference first. Load real weights from safetensors (110), tokenize with byte-level BPE (116–117), and generate with a KV cache (094) and sampling (063, 174). Modern models need RMSNorm, SwiGLU, RoPE and grouped-query attention (093, 171–173). Make the sequence length symbolic (075), so one compiled kernel serves every length, and cache compiled kernels with a JIT (051). Then train: AdamW (098), a learning-rate schedule (097), gradient clipping (099), and mixed precision (100).

**Done when** your compiler generates the same tokens as a reference implementation of a real open model under greedy decoding, and a model trained by your compiler matches a reference engine's loss curve.

## Weeks 11–14: your own project

Use your compiler to implement a paper, port it to strange hardware, or mostly anything else. 10-411 asks for a short proposal first, then code, reproducible results and a short report. Some ideas:

- **Port it to strange hardware.** WebGPU in a browser, a Raspberry Pi, a microcontroller with no floats (int8 everywhere, 141), or Apple's AMX.
- **Implement a paper on it.** Speculative decoding (144), LoRA fine-tuning (059), mixture-of-experts (175), or a small diffusion model (123–124).
- **Make the scheduler smarter.** Fuse softmax into one kernel (170, 040), and overlap copies with compute (107).
- **Quantize.** Run inference with int4 weights and group-wise scales (142–143), and measure the speed against f32 (179).
- **Distribute it.** Data-parallel training across processes or GPUs, with a ring all-reduce (109).
- **Compare with tinygrad.** Run the same model through tinygrad with `DEBUG=4` and explain every difference in the kernels you get.

Write up what you built, what was fast, what wasn't, and why. That write-up is the best thing to show someone.

## The 10-411 rules, worth following anyway

From the course's drafts. They exist because they make you learn:

- **No slop.** "This course aggressively builds on the previous week, and is an exercise in slop management. If you let any slop in early, it will compound and you will not finish the class." Style counts for 15% of the grade: did you write slop, can it be read, can it be simpler?
- **No borrowed kernels or compilers.** General-purpose libraries, Clang, LLVM and the CUDA APIs are fine. Prewritten numerical kernels (BLAS, cuBLAS) and ML or kernel-compiler frameworks (MLIR, PyTorch, tinygrad, Triton, ...) are not. Benchmark against them; don't call them.
- **AI can explain, debug and test, but not write.** AI may explain concepts, help debug code you wrote, and write tests or tooling. It may not write or rewrite your compiler. You must understand everything you hand in.
- **Performance is measured, not claimed.** Later weeks are graded on a fixed benchmark suite, on a curve against everyone else. Keep your own benchmark suite from week 6 on (176), and never trust a speedup you didn't measure.
