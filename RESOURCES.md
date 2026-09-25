# Resources

The best books, courses, videos, articles and papers to go with this course, grouped roughly in course order. Nearly everything here is free. Where a resource fits particular exercises, the chapter numbers are in brackets.

**How to use this list.** Don't try to read it all. When an exercise's comments make you curious, look up that topic here, watch or read one thing, and come back. If you only pick three, pick: Karpathy's *Zero to Hero* videos, 3Blue1Brown's *Essence of linear algebra*, and *Understanding Deep Learning* by Simon Prince.

## tinygrad itself

- [tinygrad on GitHub](https://github.com/tinygrad/tinygrad): the source. Everything in this course, for real. Start with `tinygrad/tensor.py` and the `tinygrad/mixin/` folder (most Tensor methods live there now), then `tinygrad/uop/ops.py`.
- [tinygrad docs](https://docs.tinygrad.org/): user docs, plus a developer section with [an intro to the internals](https://docs.tinygrad.org/developer/developer/) and [UOps](https://docs.tinygrad.org/developer/uop/). [chapters 4, 8, 14, 15, 30]
- [tinygrad-notes](https://mesozoic-egg.github.io/tinygrad-notes/): a long series of community write-ups walking through tinygrad's internals. Many were written for older versions (with ShapeTracker), so check details against the current source. [chapters 8, 14, 15, 30]
- [teenygrad](https://github.com/tinygrad/teenygrad): a sub-1000-line MNIST trainer sharing most of its code with (an older) tinygrad. A great next read after this course.
- [george hotz archive](https://www.youtube.com/@geohotarchive/videos): recordings of George Hotz's live-coding streams, many of them building tinygrad. Try ["tinygrad refactoring + new tour"](https://www.youtube.com/watch?v=nyDGXlLp578) (2025), or the original ["a tiny tour through tinygrad"](https://www.youtube.com/watch?v=-MhwhiReY-s) (2022, a much older tinygrad).
- [micrograd](https://github.com/karpathy/micrograd): Karpathy's ~150-line scalar autograd engine, the idea behind exercises 030-031.

## Zig

- [ziglang.org/learn](https://ziglang.org/learn/): the official docs and language reference.
- [Ziglings](https://codeberg.org/ziglings/exercises): the course that inspired this one's format. Do it alongside if Zig itself is new to you.
- [zig.guide](https://zig.guide): a friendly tutorial-style introduction. It tracks Zig's development version, so small details can differ from 0.16.

## Maths

### Linear algebra [chapters 2, 11]

- [Essence of linear algebra (3Blue1Brown)](https://www.youtube.com/playlist?list=PLZHQObOWTQDPD3MizzM2xVFitgF8hE_ab): short videos that make vectors, matrices, determinants and eigenvectors *visual*. The best starting point there is.
- [MIT 18.06 Linear Algebra (Gilbert Strang)](https://ocw.mit.edu/courses/18-06-linear-algebra-spring-2010/): the classic university course, free video lectures.
- [Mathematics for Machine Learning (Deisenroth, Faisal, Ong)](https://mml-book.github.io/): free book covering the linear algebra, calculus and probability behind ML.

### Calculus and matrix calculus [chapters 5, 6, 13]

- [Essence of calculus (3Blue1Brown)](https://www.youtube.com/playlist?list=PLZHQObOWTQDMsr9K-rj53DwVRMYO3t5Yr): derivatives, the chain rule and e, visually.
- [The Matrix Calculus You Need For Deep Learning (Parr and Howard)](https://explained.ai/matrix-calculus/): Jacobians and gradients of vector functions, from scratch. [chapter 13]

### Probability and information theory [chapter 12]

- [Seeing Theory](https://seeing-theory.brown.edu/): an interactive, visual introduction to probability and statistics.
- [Information Theory, Inference, and Learning Algorithms (MacKay)](http://www.inference.org.uk/mackay/itila/book.html): free book, and a beautiful one. Entropy, coding, and where it all meets learning.

### Optimization [chapters 5, 7, 18, 25]

- [Convex Optimization (Boyd and Vandenberghe)](https://web.stanford.edu/~boyd/cvxbook/): the standard text, free online.

### Floating point and numerics [chapters 1, 18, 28]

- [What Every Computer Scientist Should Know About Floating-Point Arithmetic (Goldberg)](https://docs.oracle.com/cd/E19957-01/806-3568/ncg_goldberg.html): the classic paper on rounding error, cancellation and IEEE 754.
- *Hacker's Delight* (Henry S. Warren): a book of bit tricks, from fast division by constants (158) to counting bits.

## Deep learning

### Courses and videos

- [Neural Networks: Zero to Hero (Karpathy)](https://karpathy.ai/zero-to-hero.html): builds micrograd, then language models, up to GPT, all in code. The perfect video companion to this course. ([notebooks](https://github.com/karpathy/nn-zero-to-hero)) [chapters 5, 17, 22]
- [Neural networks (3Blue1Brown)](https://www.youtube.com/playlist?list=PLZHQObOWTQDNU6R1_67000Dx_ZCJB-3pi): what a network is, gradient descent and backprop, then transformers and attention, visually.
- [Practical Deep Learning for Coders (fast.ai)](https://course.fast.ai/): top-down and practical, the opposite direction from this course. Great for balance.
- [CS231n: Deep Learning for Computer Vision](https://cs231n.github.io/): Stanford's course notes. The backprop and CNN notes are excellent. [chapters 6, 16]

### Books

- [Understanding Deep Learning (Simon Prince)](https://udlbook.github.io/udlbook/): free, modern, clear, with great figures. Goes from basics to transformers, diffusion and RL. The best single deep learning book right now.
- [Dive into Deep Learning](https://d2l.ai/): free interactive book, with code for every idea.
- [Deep Learning (Goodfellow, Bengio, Courville)](https://www.deeplearningbook.org/): the classic reference, free online. Chapters 2-4 are a maths refresher.
- [Neural Networks and Deep Learning (Nielsen)](http://neuralnetworksanddeeplearning.com/): a free, gentle book, excellent on backprop.

### Transformers and language models [chapters 17, 21, 22]

- [The Illustrated Transformer (Jay Alammar)](https://jalammar.github.io/illustrated-transformer/): the transformer, in pictures.
- [The Annotated Transformer (Harvard NLP)](https://nlp.seas.harvard.edu/annotated-transformer/): the original paper as a line-by-line runnable implementation.
- [Understanding LSTM Networks (Chris Olah)](https://colah.github.io/posts/2015-08-Understanding-LSTMs/): the clearest explanation of LSTMs. [exercise 114]
- [nanoGPT](https://github.com/karpathy/nanoGPT) and [llm.c](https://github.com/karpathy/llm.c): minimal GPT training code, in PyTorch and in plain C/CUDA.

### Generative models [chapter 23]

- [What are Diffusion Models? (Lilian Weng)](https://lilianweng.github.io/posts/2021-07-11-diffusion-models/): the maths of diffusion models, carefully derived. Her [blog](https://lilianweng.github.io/) covers much more.

### Reinforcement learning [chapter 24]

- [Reinforcement Learning: An Introduction (Sutton and Barto)](http://incompleteideas.net/book/the-book-2nd.html): *the* RL textbook, free online.
- [Spinning Up in Deep RL (OpenAI)](https://spinningup.openai.com/): a practical introduction to deep RL and policy gradients.

## Performance, kernels and hardware

- [Making Deep Learning Go Brrrr From First Principles (Horace He)](https://horace.io/brrr_intro.html): compute-bound vs memory-bound vs overhead-bound. Chapter 9's roofline, in prose. [chapters 9, 20]
- [How to Optimize a CUDA Matmul Kernel (Simon Boehm)](https://siboehm.com/articles/22/CUDA-MMM): a naive matmul optimized step by step to near cuBLAS speed. Coalescing, shared memory, tiling, register blocking. [chapters 9, 15, 29]
- [GPU MODE lectures](https://github.com/gpu-mode/lectures): a community lecture series on GPU programming, from CUDA basics to Triton and FlashAttention.
- [CUDA Programming Guide (NVIDIA)](https://docs.nvidia.com/cuda/cuda-programming-guide/index.html): the reference for GPU threads, blocks, shared memory and the memory model. It replaced the older CUDA C++ Programming Guide. [chapters 15, 20, 29]
- *Programming Massively Parallel Processors* (Hwu, Kirk, El Hajj): the standard textbook on GPU programming.
- [What Every Programmer Should Know About Memory (Drepper)](https://people.freebsd.org/~lstewart/articles/cpumemory.pdf): caches, from the hardware up. [chapter 29]
- [Crafting Interpreters (Robert Nystrom)](https://craftinginterpreters.com/): a free, wonderful book on building languages. The best intro to how compilers think. [chapters 4, 8]

## Training at scale

- [How to Scale Your Model (Google DeepMind)](https://jax-ml.github.io/scaling-book/): a free book on the parallelism and hardware maths of LLMs: rooflines, sharding, communication costs. [chapters 10, 26]
- [The Ultra-Scale Playbook (Hugging Face)](https://huggingface.co/spaces/nanotron/ultrascale-playbook): data, tensor, pipeline and context parallelism and ZeRO, with thousands of measured experiments. [chapter 26]
- [Machine Learning Engineering Open Book (Stas Bekman)](https://github.com/stas00/ml-engineering): the practical side of training big models: hardware, networking, debugging.

## Papers

The original papers behind the exercises, all free on arXiv. They're easier to read AFTER doing the exercise.

| Paper | Exercises |
|---|---|
| [Auto-Encoding Variational Bayes (VAE)](https://arxiv.org/abs/1312.6114) (2013) | 122 |
| [Playing Atari with Deep Reinforcement Learning (DQN)](https://arxiv.org/abs/1312.5602) (2013) | 128 |
| [Adam](https://arxiv.org/abs/1412.6980) (2014) | 038 |
| [Generative Adversarial Networks](https://arxiv.org/abs/1406.2661) (2014) | 125 |
| [Batch Normalization](https://arxiv.org/abs/1502.03167) (2015) | 084 |
| [Deep Residual Learning (ResNet)](https://arxiv.org/abs/1512.03385) (2015) | 115 |
| [Neural Machine Translation of Rare Words with Subword Units (BPE)](https://arxiv.org/abs/1508.07909) (2015) | 117 |
| [Training Deep Nets with Sublinear Memory Cost](https://arxiv.org/abs/1604.06174) (2016) | 137 |
| [Layer Normalization](https://arxiv.org/abs/1607.06450) (2016) | 083 |
| [Attention Is All You Need](https://arxiv.org/abs/1706.03762) (2017) | 090-093 |
| [Mixed Precision Training](https://arxiv.org/abs/1710.03740) (2017) | 100 |
| [Decoupled Weight Decay Regularization (AdamW)](https://arxiv.org/abs/1711.05101) (2017) | 098 |
| [Proximal Policy Optimization](https://arxiv.org/abs/1707.06347) (2017) | 129 |
| [GPipe](https://arxiv.org/abs/1811.06965) (2018) | 139 |
| [Megatron-LM](https://arxiv.org/abs/1909.08053) (2019) | 138 |
| [ZeRO](https://arxiv.org/abs/1910.02054) (2019) | 140 |
| [Denoising Diffusion Probabilistic Models](https://arxiv.org/abs/2006.11239) (2020) | 123-124 |
| [RoFormer (rotary embeddings)](https://arxiv.org/abs/2104.09864) (2021) | 093 |
| [LoRA](https://arxiv.org/abs/2106.09685) (2021) | 059 |
| [Training language models to follow instructions (InstructGPT, RLHF)](https://arxiv.org/abs/2203.02155) (2022) | 130 |
| [FlashAttention](https://arxiv.org/abs/2205.14135) (2022) | 095 |
| [GPTQ](https://arxiv.org/abs/2210.17323) (2022) | 143 |
| [Fast Inference via Speculative Decoding](https://arxiv.org/abs/2211.17192) (2022) | 144 |
| [Direct Preference Optimization](https://arxiv.org/abs/2305.18290) (2023) | 130 |
| [PagedAttention (vLLM)](https://arxiv.org/abs/2309.06180) (2023) | 145 |
