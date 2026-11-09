# Final project: your own ML compiler

The project follows **[10-411: Compilers for Machine Learning](https://10-411.com/)**, George Hotz's course at Carnegie Mellon (Spring 2027), and its **[technical syllabus](https://gist.github.com/geohot/4768597d9dc536446ee2d5de1f29e89d)**, which specifies the compiler week by week. You build a compiler from scratch over eleven weeks, starting with elementwise programs and ending with training state-of-the-art models on GPUs. Then you spend three weeks on a project of your own.

Both documents are drafts and still change often: the gist had over 60 revisions in October and November 2026. This guide was checked against 10-411.com and the gist's revision of November 4, 2026. When they disagree with this page, they win.

## First: the rules, if you're taking 10-411 for credit

10-411's policy: AI "may help explain concepts, debug code you wrote, and write tests or tooling. It may not write or rewrite your compiler implementation." And: "Study existing compilers, but do not copy their implementations."

Everything in this repository was written with AI. That includes `minicompiler.zig` and the compiler pieces of Part V: the UOp, the UIR parser and interpreter, rangeify, the renderers. So for credit:

- **Use the exercises to understand**, then close them and write your own.
- **Write your own oracle** (an interpreter). In 10-411 it's part of the week-1 compiler, not tooling.
- **Writing tests is allowed**, and 190 is practice for exactly that.

If you're following along on your own, none of this binds you. It's still the best way to learn.

## The format: UIR

Every student's compiler, in any language, reads the same text format. Tests are shared through it. tinygrad reads and writes it too (`tinygrad/uop/uir.py`, "(mostly) studentgrad compatible", added November 2026). That makes it a free second opinion on your parser. Exercises 186–190 build a parser, a printer and an interpreter for it.

```
# gemm_256x256.uir
%0 = buffer 65536 dtype=f32 slot=0
%1 = buffer 65536 dtype=f32 slot=1
%2 = reshape %0 [256 256 1]
%3 = reshape %1 [256 1 256]
%4 = mul %2 %3
%5 = reduce %4 op=add pop=1
```

The format has one line per UOp: `%name = op srcs key=value`. A value is one of:

- an earlier `%name`;
- a literal: `7`, `0x1f`, `2.5`, `1e3`, `-inf`, `true`;
- a `[stack]` of values;
- a nested `(op srcs args)`;
- a `{ %a = ... %b = ... }` block, whose value is its last line.

Tests end in `assert`, like the site's week 4 example:

```
%values = add [1 2 3] (expand 1 3)
%sum = reduce %values op=add pop=1
%test = assert %sum 9
```

Five conventions trip people up (182):

- **Shapes act at the front.** `STACK` adds a leading axis. `EXPAND` *adds* leading axes; it doesn't stretch size-1 ones. `INDEX` and `REDUCE pop=k` remove leading axes. To reduce another axis, `PERMUTE` it to the front first.
- **Shape arguments are srcs**, a CONST or a STACK of CONSTs: `reshape %x [2 2]`. `PAD` and `SHRINK` take two, the offsets and the sizes.
- **Buffers are flat**: `buffer []` is a scalar and `buffer 3` has three elements. More axes come from `RESHAPE`.
- **Literals are weak** (181): `add %i32 1` is an i32. A weak value only gets a real dtype when it's stored.
- **`DIV` and `MOD` are floor division**, like Python's (183). C's `/` truncates instead.

## Week by week

Each week below has what the spec adds, what to build, the exercises that teach it, and when you're done. Weeks follow the 10-411.com schedule. Op lists come from the gist.

### Week 1. UOps and rewrites (181–187, 021–025, 071–072, 156–158)

**Spec:**
- `UOp(op, src, arg)`, hash-consed, with recursive properties `dtype` (void, bool, i32, f32), `shape`, `cost` and `bounds`.
- Ops: `CONST`, `PARAM`/`CALL` ("lambda calculus"), `STACK`, `INDEX`, `CAST`/`RECIP`, `ADD`/`MUL`/`MAX`/`XOR`, `CMPLT` (gives bool), `SHL`/`DIV`/`MOD` (i32 only), `WHERE`, and `ASSERT` (for tests).
- Inputs can only be `STACK` or `CONST` until week 4. ALU ops are rank 0. The rewrite engine "runs" programs as an interpreter.

**Build:**
- The UOp with its dtype and shape rules (181, 182) and the exact ALU semantics (183).
- `CALL` by substitution (184) and `bounds` (185).
- A rewrite engine with constant folding and symbolic simplification (025, 156, 072, 191's `symbolic`).
- A UIR parser and printer (186, 187).

**Done when:** `%sum = add 2 3` / `%test = assert %sum 5` passes, and parse(print(x)) gives back x.

### Week 2. Loads, stores and memory (185, 188, 023, 041–043, 050, 159)

**Spec:**
- Properties: `addrspace` (GLOBAL, ALU), `accesses`, `storage_base`.
- Ops: `BUFFER`, `ALLOC` (call-scoped, like `float a[10]`), `SHRINK(offset, shape)`, `LOAD`/`STORE`, and `AFTER(buf, <store>)`.
- Loads and stores must be fully ordered, and are bounds checked to never be out of range.

**Build:**
- Memory, with `AFTER` as the only thing that orders a read after a write (188).
- The bounds check, done at compile time with `bounds` (185).
- Toposort and render loopless C (023, 041, 042), plus a runtime (043, 052).

**Done when:** the site's week 2 example passes: store 7, `after`, `load`, and `assert` 7.

### Week 3. Loops, rendering and runtime (188, 195, 019–020, 052, 076)

**Spec:**
- Ops: `RANGE` (src is the end, arg names it) and `END` (srcs are a passthrough and the ranges).
- Properties: `ranges`, `ended_ranges`.
- You can now write GEMMs and convolutions by hand. "If you still have an interpreter at this point, it's time to write a renderer."

**Build:** loops in the interpreter (188), then render loops to C, compile and run them (195).

**Done when:** the week 3 example passes: store `i` at `index %buf %i` for `i` in 0..3, then assert `[0 1 2]`. Hand-written GEMM and convolution programs should match the oracle.

### Week 4. Rangeify, reduce and materialization (191–194, 012, 017, 040, 081)

**Spec:** ops `REDUCE` (an op and an axis count), `STAGE` (a temporary buffer) and `EXPAND`. Rank-1 ALU ops are now allowed. "Rangeify removes shapes from all ops. We have to confront questions about materialization here."

**Build:**
- Movement ops as index maths on ranges (191).
- The rangeify walk that decides which values get buffers (192).
- Lowering to `STORE`/`INDEX`/`END`/`AFTER` (193).
- The cost check that removes cheap buffers, and kernels as `CALL`s (194).

**Done when:** the week 4 example passes, and you can predict the kernel count of any graph. Softmax should be three kernels.

### Week 5. Movement ops (189, 191, 009–014, 073–074, 147–150)

**Spec:**
- `RESHAPE`/`PERMUTE`/`PAD`, with rank ≥ 2 shapes; `FLIP` is a composite.
- `STACK` takes arbitrary inputs, and `SHRINK` takes `STACK`s in its params.
- Autodiff works on pure shape graphs only.
- "Here you will run Qwen", and learn Taylor expansions for `SIN`/`LOG2`/`EXP2`/`SQRT` (147–150): they aren't ALU ops in this spec.

**Build:** movement ops in the interpreter (189) and in rangeify (191). GEMMs and convolutions now fall out of reshape, expand, permute and reduce (189's tests, 195).

**Done when:** the week 5 example passes (`reshape`, `permute [1 0]`, `index 1 0` is 2), then a small real LLM matches a reference's tokens.

### Week 6. Autodiff and speed (026–036, 065–070, 103–104, 110, 177, 196–197)

**Spec:**
- Ops: `GRADIENT`/`DETACH`.
- Add `url=` and `sha256=` to `BUFFER`, to read weights from disk.
- Train MNIST, and run LLM and ResNet inference. "In week 6, timing starts to really matter."

**Build:**
- Gradients as more graph (069, 068): one rule per op, with movement-op gradients from 034.
- FLOP counting (177).
- The first fast CPU kernels: split and upcast (196, 197).

**Done when:**
- MNIST trains. 103's digits are a smaller first step, and real MNIST is a `url=` buffer away.
- A pretrained model's inference matches a reference.

### Week 7. Memory hierarchies, kernels and multithreading (196–200, 044–048, 151–155, 161–165)

**Spec:** axis types (`LOOP`, `UPCAST`, `THREAD`); the bar is state-of-the-art-competitive C for GEMMs, reduces and convolutions.

**Build:**
- `UPCAST` as register blocking (197): 3 → 85 GFLOPS on a 256² matmul, on an i5-12400F.
- Linearize with tinygrad's priorities (199).
- BEAM search over real compiled kernels (200).
- Threads over the outer loop (162).

**Done when:** a 256×256 matmul runs at least 10× faster than your first version. Compare with a BLAS library: benchmark it, don't call it.

### Week 8. GPUs and hardware accelerators (198, 201–204, 077–079, 106–108, 166–168)

**Spec:** kernels, axis mappings (`GLOBAL`, `LOCAL`), and "competitive CUDA/HIP code".

**Build:**
- The driver path, the way tinygrad does it (201).
- Fitting axes to the grid (198).
- Coalescing (202), reductions (203), tiled and register-blocked GEMMs (204).

Measure everything: 202 gives your GPU's real bandwidth and FLOPs.

**Done when:** the fuzz test passes on the GPU backend, and a large matmul is competitive with PyTorch on the same GPU. 10-411 grades performance on RTX 3080s, tentatively.

### Week 9. GPUs, part 2 (205, 206, 080, 095, 170)

**Spec:** tensor cores, upcasting, fast GEMMs, convolutions, and flash attention.

**Build:**
- `mma.sync` and its fragment layouts (205).
- Flash attention with an online softmax (206).
- Then feed the tensor cores from shared memory (204's staging, plus ldmatrix and cp.async).

**Done when:** f16 GEMMs run on tensor cores well past your best f32 kernel, and attention's memory grows linearly with sequence length.

### Week 10. Multiple GPUs and sharding (053, 109, 138–140)

**Spec:** scale execution across GPUs. In tinygrad this is `shard`, `UNSHARD`, `MSELECT`/`MSTACK`, `ALLREDUCE` and `COPY`.

**Build:**
- Data parallelism with a ring all-reduce (109).
- Tensor and pipeline parallelism (138, 139) and ZeRO (140).

These exercises simulate several devices. Real ones need two GPUs and peer copies.

**Done when:** training on two devices matches training on one, and is faster.

### Week 11. State-of-the-art inference and training (094, 097–101, 110, 116–117, 141–145, 171–180)

**Build:**
- Inference with real weights from safetensors (110) and a BPE tokenizer (116–117).
- A KV cache (094) and sampling (063, 174).
- The modern blocks: RMSNorm, SwiGLU, RoPE and GQA (093, 171–173).
- A symbolic sequence length (075) and a JIT (051).
- Training: AdamW (098), schedules (097), clipping (099) and mixed precision (100).

**Done when:** your compiler generates the same tokens as a reference implementation under greedy decoding, and a model trained by your compiler matches a reference loss curve.

## Weeks 12–14: your own project

"Use your compiler to implement a paper, port it to strange hardware, mostly anything." 10-411 asks for a short proposal, then code, reproducible results and a short report. Some ideas:

- **Strange hardware:** WebGPU in a browser, a Raspberry Pi, a microcontroller with no floats (int8 everywhere, 141), or Apple's AMX.
- **A paper:** speculative decoding (144), LoRA fine-tuning (059), mixture of experts (175), or a small diffusion model (123–124).
- **A smarter scheduler:** fuse softmax into one kernel (206's online trick, applied in rangeify), or overlap copies with compute (107).
- **Quantization:** int4 weights with group-wise scales (142–143), and a fast GEMV for decoding (179).
- **Compare with tinygrad:** run the same model through tinygrad with `DEBUG=5` (which prints UIR) and explain every difference from your kernels.

## How 10-411 is graded

From 10-411.com, as of November 2026:

- **55% compiler.**
  - 5% for ten tests each Monday, judged against an oracle. Up to 3% more if other compilers, or the reference compiler, fail your correct tests (190).
  - 25% for correctness: the percentage of all tests your Wednesday submission passes.
  - 15% for style: is it readable, can it be simpler?
  - 10% for performance in weeks 8–11, on a curve, on identical GPUs.
- **25% quizzes:** in person and closed book, at least 20 of them, lowest two dropped.
- **20% final project.**

"This course aggressively builds on the previous week, and is an exercise in slop management. If you let any slop in early, it will compound and you will not finish the class."

## What's here

`minicompiler.zig` is a small, deliberately simple ML compiler in one file. It takes a tensor graph, turns movement ops into index strings, fuses everything between reductions, renders C, compiles it with `zig cc` and runs it. It also has an oracle and a fuzz test.

```sh
zig test project/minicompiler.zig
```

Part V does all of this the way tinygrad and 10-411 do: hash-consed UOps, UIR, rangeify, kernels as `CALL`s, and renderers for C and the GPU. Read `minicompiler.zig` as the short version of the same idea, and Part V as the real one.

## Rules worth following anyway

- **Tests first.** Each week, write tests that would break a careless compiler, then make yours pass them (190).
- **No borrowed kernels or compilers.** General-purpose libraries, Clang, LLVM and the CUDA APIs are allowed. Prewritten numerical kernels (BLAS, cuBLAS) and ML or kernel-compiler frameworks (MLIR, PyTorch, tinygrad, Triton, ...) aren't. Benchmark against them; don't call them.
- **Measure, don't claim** (176). Later weeks are graded on a fixed benchmark suite, on a curve. Never trust a speedup you didn't measure.
