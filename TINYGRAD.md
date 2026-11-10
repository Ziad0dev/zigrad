# Programming tinygrad: a field guide

The exercises rebuild tinygrad in Zig. This page is the other half: how to drive the real thing, in Python, and watch it do what you built. Do it alongside Part V, not after: every experiment below takes a minute, and seeing tinygrad print the kernel you just wrote by hand is the best check there is that you understood it.

Everything here was checked against tinygrad's source and its own `docs/` at commit `411dd8d` (November 9, 2026), and the experiments and the training step below were run at that commit on `DEV=CPU`. They were not run on a GPU: the machine this was written on had neither nvrtc nor an LLVM library tinygrad could load. tinygrad changes weekly. When this page and the source disagree, the source wins; `docs/env_vars.md` in the tinygrad repo is the first place to look.

## Setup

```sh
git clone https://github.com/tinygrad/tinygrad.git
cd tinygrad
python3 -m pip install -e .
```

tinygrad has no required dependencies beyond Python. Pick a device with `DEV`:

| `DEV=` | What runs your kernels | Needs |
|---|---|---|
| `CPU` | C compiled by clang, or `CPU:LLVM` | `clang` on your `PATH` |
| `CUDA` | the CUDA driver API, the path exercise 201 takes | an NVIDIA driver, plus something to compile with: nvrtc (from the CUDA toolkit), or `CUDA:PTX`, which needs an LLVM shared library instead |
| `NV` | tinygrad's own userspace NVIDIA driver, no CUDA at all | an Ampere, Ada or Blackwell GPU |
| `PYTHON` | a pure-Python interpreter of the UOps (043, 188) | nothing |

`DEV` can also name the renderer and the architecture, separated by colons: `DEV=NV:CUDA:sm_70`.

```python
from tinygrad import Tensor, Device
print(Device.DEFAULT)
print((Tensor([1, 2, 3]) + 1).tolist())
```

If that fails with "failed to load library ...: try setting X_PATH?", tinygrad couldn't find a shared library by its usual name. Point it at the file: `LIBC_PATH=/path/to/libc.so.6`, `CUDA_PATH=/path/to/libcuda.so.1`, `LLVM_PATH=/path/to/libLLVM.so`. This happens on NixOS, where libraries don't live in `/usr/lib`. There, also set `CC=clang`: the CPU backend runs `$CC`, and it passes flags only clang accepts.

## The one idea: nothing runs until you ask

A `Tensor` is a handle on a UOp graph (021, 182). `a + b` builds graph; nothing is computed. `.realize()`, or anything that needs the numbers (`.tolist()`, `.item()`, `.numpy()`), makes tinygrad schedule the graph into kernels, compile them, and run them.

```python
from tinygrad import Tensor
x = Tensor.rand(4, 4)
y = (x * 2 + 1).sum(axis=0)   # still just a graph
print(y.uop)                  # the UOps, before any scheduling
y.realize()                   # rangeify, codegen, compile, run
```

## Watching the compiler work

`DEBUG` is the window. Each level adds to the one before:

| `DEBUG=` | You see | You built it in |
|---|---|---|
| 1 | which devices were opened | 053 |
| 2 | one line per kernel run: time, memory, bandwidth, GFLOPS | 044, 176, 202 |
| 3 | the opts applied to each kernel | 079, 196 |
| 4 | the generated code (C, or PTX) | 042, 195, 201 |
| 5 | the UOps of each kernel, printed as UIR | 182, 187, 193 |
| 6 | the UOps linearized, one per line | 041, 199 |
| 7 | the assembly | 045 |

The other switches worth knowing:

| Variable | What it does | Exercise |
|---|---|---|
| `VIZ=1` | saves every rewrite pass and starts a local server to browse them: the graph before and after each pattern match. `python -m tinygrad.viz.cli` reads the same data in a terminal. | 025, 156 |
| `NOOPT=1` | no kernel optimizations at all: the code your 195 would write | 195 |
| `BEAM=2` | beam search of width 2 over opts, timing each candidate on your machine | 048, 200 |
| `IGNORE_BEAM_CACHE=1` | search again instead of reusing the cached winner | 200 |
| `BEAM_UPCAST_MAX`, `BEAM_LOCAL_MAX`, `BEAM_MIN_PROGRESS` | the limits and the stopping rule of the search (256, 1024, 0.01 by default) | 200 |
| `TC=0` | never use tensor cores | 080, 205 |
| `JIT=0` | turn `TinyJit` off | 051 |
| `DISALLOW_BROADCAST=1` | ALU ops need equal shapes, as in 10-411's spec | 182 |
| `DEFAULT_FLOAT=HALF` | weak floats commit to f16 instead of f32 | 181 |

You can also set them for one block of code:

```python
from tinygrad import Context
with Context(DEBUG=4):
  (Tensor.rand(8) * 2).realize()
```

## Twelve experiments

Each one is a prediction first: write down what you expect, then run it. If you were wrong, the exercise number says where to look.

1. **Fusion.** `DEBUG=2`, `((x * 2) + 1).relu().realize()` for `x = Tensor.rand(1024)`. How many kernels? (040, 192)
2. **A kernel split.** `Tensor.rand(16, 64).softmax()`: how many kernels, and which value does each compute? Exercise 194 says three. Then try it on a single vector, `Tensor.rand(1024).softmax()`: tinygrad needs only two. Read the second kernel with `DEBUG=4 NOOPT=1` to see why. (192, 194)
3. **Movement ops cost nothing.** `DEBUG=4`, `x.reshape(32, 32).permute(1, 0).contiguous().realize()`. Find the reshape and the permute in the C. They are only index maths. (073, 191)
4. **Padding becomes a WHERE.** `DEBUG=4`, `x.pad((1, 1)).contiguous().realize()`. Find the condition. (014, 193)
5. **A reduce is an accumulator.** `DEBUG=4`, `x.reshape(32, 32).sum(axis=1).realize()`. Which loop is the grid, which is the reduce? (076, 195, 208)
6. **The matmul.** `DEBUG=4 NOOPT=1`, `(Tensor.rand(256, 256) @ Tensor.rand(256, 256)).realize()`. Compare with what your 195 renders. Then drop `NOOPT=1` and read it again with `DEBUG=3` to see the opts. (019, 195, 196, 197)
7. **Search.** The same matmul with `BEAM=2 DEBUG=2`. How much faster than the default? Run it twice: the second run doesn't search. (200)
8. **Floor division.** `(Tensor([-7]) // 2).tolist()` and `(Tensor([-7]) % 2).tolist()`. Then read the C with `DEBUG=4`: how does tinygrad get floor division out of C's truncating `/`? (158, 183)
9. **Weak types.** `(Tensor([1, 2, 3], dtype=dtypes.int8) + 1).dtype`, then `+ 0.5`. The second one is still weak. (157, 181)
10. **UIR.** Print a graph in the course's text format, and read one back:

    ```python
    from tinygrad.uop.uir import render_uir, parse_uir
    print(render_uir((Tensor([1, 2, 3]) + 1).uop))
    print(parse_uir("%sum = add 2 3"))
    ```

    Then feed `parse_uir` the programs from 186's tests. tinygrad's own test of this is `test_studentgrad_syntax` in `test/null/test_uir_render.py`. (186, 187)
11. **The JIT.** Wrap a function in `@TinyJit`, call it five times with `DEBUG=2`. What happens on call 1, on call 2, from call 3 on? (051)
12. **Your GPU's numbers.** `DEV=CUDA DEBUG=2` on a 4096 by 4096 matmul. Compare the GFLOPS with what your 204 kernels reached, and with 202's peak. Then `BEAM=4`. (202, 204, 205)

## Training something

```python
from tinygrad import Tensor, TinyJit, Context, nn

class Net:
  def __init__(self):
    self.l1, self.l2 = nn.Linear(784, 128), nn.Linear(128, 10)
  def __call__(self, x): return self.l2(self.l1(x).relu())

net = Net()
opt = nn.optim.Adam(nn.state.get_parameters(net), lr=1e-3)

@TinyJit
@Context(TRAINING=1)   # dropout and friends only act when TRAINING is set
def step(x, y):
  opt.zero_grad()
  loss = net(x).sparse_categorical_crossentropy(y).backward()
  opt.step()
  return loss.realize()
```

Every line is something you built: the layers (082), the loss (036), `backward` (030, 068), Adam (038), dropout's switch (089), the JIT (051). tinygrad's `docs/quickstart.md` and `docs/mnist.md` carry this through to a trained MNIST model.

## Where each exercise lives in tinygrad

| tinygrad | What's there | Exercises |
|---|---|---|
| `tinygrad/tensor.py`, `tinygrad/mixin/` | `Tensor`: every op built from a few primitives; `backward`, `gradient` | 015–020, 030–036, 068 |
| `tinygrad/dtype.py`, `tinygrad/uop/weak.py` | dtypes, the promotion lattice, weak types | 157, 181 |
| `tinygrad/uop/ops.py` | `UOp`, hash-consing, shape and dtype rules, `python_alu`, `_min_max`, `toposort`, `substitute`, `PatternMatcher`, `graph_rewrite` | 021–025, 156, 182–185 |
| `tinygrad/uop/symbolic.py`, `tinygrad/uop/divandmod.py` | the simplifier | 071–072, 158, 191 |
| `tinygrad/uop/uir.py` | `render_uir`, `parse_uir` | 186–187 |
| `tinygrad/schedule/indexing.py` | `run_rangeify`, `apply_movement_op`, `new_range` | 191–192 |
| `tinygrad/schedule/rangeify.py` | `bufferize_to_store`, `remove_bufferize`, splitting into kernels | 193–194 |
| `tinygrad/schedule/memory.py` | the memory planner | 050 |
| `tinygrad/codegen/__init__.py` | the pass list: expander, `pm_reduce_local`, devectorize | 197, 199 |
| `tinygrad/codegen/opt/postrange.py` | `Scheduler`, `shift_to`, `apply_opt`, the TC opt | 079, 196 |
| `tinygrad/codegen/opt/search.py` | `beam_search` | 048, 200 |
| `tinygrad/codegen/gpudims.py` | `get_grouped_dims` | 077, 198 |
| `tinygrad/codegen/late/linearizer.py` | `linearize` and its priorities | 041, 199 |
| `tinygrad/renderer/cstyle.py`, `ptx.py`, `tc.py` | the C and PTX renderers; tensor core layouts | 042, 195, 201, 205 |
| `tinygrad/engine/jit.py`, `realize.py` | `TinyJit`; compiling and running a schedule | 043, 051 |
| `tinygrad/runtime/ops_cuda.py`, `ops_nv.py`, `ops_cpu.py` | the devices | 052, 053, 106, 201 |
| `tinygrad/viz/` | the rewrite and profile viewer | 025 |

## How to read the source

The compiler proper (`uop/`, `schedule/`, `codegen/`, `engine/`, `renderer/`) is about 13,000 lines, and you have written a small version of nearly every file. A good order:

1. `tinygrad/uop/ops.py`, the `UOp` class. You know its core from 182 to 185.
2. `tinygrad/uop/uir.py`: 200 lines, and you wrote the same parser in 186.
3. `tinygrad/schedule/indexing.py`: `run_rangeify` is 192's `walk`, with more cases.
4. `tinygrad/codegen/opt/postrange.py`: `shift_to` is 196's, nearly line for line.
5. `tinygrad/codegen/__init__.py`: the list of passes, top to bottom, is the pipeline of Part V in order.

For each function, find the exercise that built it (the table above), reread your own version, then read tinygrad's. The differences are where the real-world cases live: symbolic shapes, more dtypes, more devices. Then pick something small from the repo's issues, or write a test in UIR: that is exactly how 10-411 grades its students (190).
