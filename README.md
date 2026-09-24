# zigrad

Learn how [tinygrad](https://github.com/tinygrad/tinygrad) works, and the maths behind it, by rebuilding it in Zig, one small broken program at a time. The format follows [ziglings](https://codeberg.org/ziglings/exercises).

Each exercise in `exercises/` is a short lesson in its comments plus some code with a hole or a bug in it. Fix it, and the tests at the bottom pass.

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

Fix the file, run `zig build` again, and repeat until you're done.

| Command | What it does |
|---|---|
| `zig build` | Check all exercises in order |
| `zig build -Dn=17` | Check only exercise 17 |
| `zig build -Dsolutions` | Check the reference solutions |
| `zig test exercises/017_reduce_axis.zig` | Run one file's tests directly |

Stuck? Every exercise has a finished version in `solutions/`. Try for a while first, though: the struggle is where the learning happens.

## What you'll build

| Chapter | Exercises | You learn |
|---|---|---|
| 1. Numbers in a row | 001–004 | tensors are flat memory; float pitfalls; elementwise and reduce kernels |
| 2. Shapes and views | 005–014 | shapes, strides, views; reshape, permute, expand/broadcast, shrink, flip and pad without copying |
| 3. Ops from primitives | 015–020 | exp and log from exp2/log2; sigmoid and tanh; axis reductions; stable softmax; matmul and convolution built from movement ops |
| 4. The lazy graph | 021–025 | building a graph instead of computing; memoized evaluation; topological sort; hash-consing; rewrite rules and constant folding |
| 5. Derivatives | 026–032 | slopes; derivative rules; chain rule; forward-mode (dual numbers); backpropagation; gradient descent |
| 6. Tensor gradients | 033–036 | gradients of broadcasting and movement ops; matmul gradient; cross-entropy |
| 7. Training | 037–039 | weight initialization; momentum and Adam; training a network on XOR |
| 8. The compiler | 040–043 | scheduling and kernel fusion; linearizing to instructions; rendering C; running kernels on a tiny device |
| 9. Fast kernels | 044–048 | the roofline model; unrolling and SIMD upcasting; tiling for data reuse; parallel tree reductions; BEAM search over kernel variants |
| 10. The runtime | 049–053 | f16, bf16 and int8 quantization; memory planning; the JIT; compiling C with `zig cc` and loading it with `std.DynLib`; sharding and all-reduce across devices |

Want the whole picture before you start? `examples/tinygrad_in_one_file.zig` puts every piece together in about 500 lines:

```sh
zig run examples/tinygrad_in_one_file.zig
```

## Afterwards

Once every exercise passes, you've met every major piece of tinygrad. Its source is the best next read: [tinygrad/tinygrad](https://github.com/tinygrad/tinygrad). The names you'll see there (`UOp`, `graph_rewrite`, `PatternMatcher`, `ShapeTracker`/views, the scheduler, renderers, `BEAM`, `TinyJit`) are what you've just built.

## Maintaining the exercises

Every exercise must fail as shipped, and its solution must pass:

```sh
zig build -Dsolutions                 # every solution passes
for f in exercises/*.zig; do zig test "$f" >/dev/null 2>&1 && echo "passes already: $f"; done
```
