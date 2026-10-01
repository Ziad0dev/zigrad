# Final project: your own ML compiler

`minicompiler.zig` is a real, working, deliberately simple ML compiler, about 500 lines in one file, tests included. It takes a lazy tensor graph, turns movement ops into index maths, fuses everything between reductions into one kernel, writes C, compiles it with `zig cc`, loads it with `std.DynLib`, runs it, and benchmarks it.

```sh
zig test project/minicompiler.zig
```

It prints the C it generates for a matmul (written the tinygrad way, as reshape + expand + mul + sum) and times it against a plain Zig loop. It works. It's also slow, and its code is ugly. **Your project is to make it good**, milestone by milestone. The milestones follow the same arc as George Hotz's [Compilers for Machine Learning syllabus](https://gist.github.com/geohot/4768597d9dc536446ee2d5de1f29e89d): UOps and rewrites, then loops and movement ops, then fast CPU code, then GPUs, then real models and autodiff.

Each milestone names the exercises that teach what you need. Keep the existing tests passing, and add a test for everything new.

## Milestones

### 1. Simplify the index maths (exercises 071–074)
Look at the matmul kernel it prints:
```c
acc += b1[0+(((0+(r)*1+(i0)*48)/1%48))*1+(((0+(r)*1+(i0)*48)/48%64))*48] * ...
```
That's `b1[i0*48 + r]`. Indexes are built as strings, so nothing can simplify them. Replace them with a small expression graph (`Var`, `Const`, `Add`, `Mul`, `Div`, `Mod`), with range analysis (071) and the rewrite rules of 072 (`x % d -> x` when `0 <= x < d`, `(x*d + y) / d -> x + y/d`, ...). **Done when** the matmul kernel reads `b1[i0*48+r]` and `b2[r*32+i1]`.

### 2. A real UOp graph with rewrite rules (021–025, 156)
Add hash-consing (024) so identical nodes are shared, and a `PatternMatcher`-style list of rewrite rules (156) for the tensor graph: constant folding, `x*1`, `x+0`, `neg(neg(x))`. **Done when** `relu(x*1 + 0)` renders the same C as `relu(x)`.

### 3. Fast CPU kernels (044–047, 151–155, 161–162)
Make the 256x256 matmul fast. In order: put the reduce loop where it reads memory contiguously (152), tile it (046), upcast into a register block with vector types (045, 155, 161), and split the outer loop across threads (162). Add an `Opt` list like 079's that describes these transformations, and a BEAM search (048) that times variants and keeps the fastest. **Done when** you reach at least 10x the starting GFLOPS. Then compare with a BLAS library; getting within 2x of it is excellent.

### 4. Every model: more ops (014, 020, 085–087)
Add `pad` and `shrink` (with a valid condition, 014, 073), then `exp2`/`log2` (with your own approximations from 147 and 150, since kernels are built with `-nostdlib`), `max` reduce, and conv2d built from pooling windows (020). **Done when** softmax, conv2d and max-pool match reference loops.

### 5. A GPU backend (077–080, 106–108, 166–170)
Write a second renderer that emits CUDA, Metal or OpenCL. Map output axes to the grid and blocks (077), reduce through shared memory (078) or warp shuffles (168), and try tensor cores (080). Needs a GPU, and the vendor's compiler or runtime. **Done when** the same graph runs on both backends and the results agree.

### 6. Autodiff and real training (030–035, 068–069, 103, 180)
Build backward as more graph (069): one gradient rule per op, and movement-op gradients from 034. Then train: an MLP on the digits of 102–103, then the transformer block of 180. **Done when** a model trained entirely by your compiler reaches the same loss as the reference engines in the course.

### 7. A JIT and symbolic shapes (051, 075)
Cache compiled kernels by their source, so a repeated graph never recompiles. Then make the sequence length a variable (075), so one compiled kernel serves every length. **Done when** a training loop compiles each kernel exactly once.

## More project ideas

Once the compiler can train something, pick one:

- **Port it to strange hardware.** WebGPU in a browser, a Raspberry Pi, a microcontroller with no floats (int8 everywhere, 141), or Apple's AMX.
- **Implement a paper on it.** FlashAttention (095) as a single fused kernel, speculative decoding (144), LoRA fine-tuning (059), or a small diffusion model (123–124).
- **Run a real model.** Load GPT-2 weights from safetensors (110), add a byte-level BPE tokenizer (117), and generate text with a KV cache (094) and top-p sampling (174).
- **Make the scheduler smarter.** Fuse softmax into ONE kernel (170, 040), decide when to store versus recompute (081), and plan memory (050).
- **Quantize.** Run inference with int4 weights and group-wise scales (142–143), and measure the speed against f32 (179).
- **Distribute it.** Data-parallel training across processes, with a ring all-reduce (109).
- **Compare with tinygrad.** Run the same graph through tinygrad with `DEBUG=4` and explain every difference in the kernels you get.

Write up what you built, what was fast, what wasn't, and why. That write-up is the best thing to show someone.
