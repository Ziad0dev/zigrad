# zigrad

Learning how [tinygrad](https://github.com/tinygrad/tinygrad) works by rebuilding its core ideas in Zig.

Each lesson is one self-contained file. You need [Zig 0.15.1](https://ziglang.org/download/).

```sh
zig run  lessons/01_tinygrad_basics.zig   # see the kernels, then watch it learn y = 2x + 1
zig test lessons/01_tinygrad_basics.zig   # laziness, fusion and gradient checks
```

## Lessons

1. **tinygrad basics** (`lessons/01_tinygrad_basics.zig`): lazy tensors, a handful of primitive ops,
   kernel fusion, printing kernels as C code, autograd, and a training loop.
