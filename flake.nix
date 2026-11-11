{
  description = "zigrad: learn tinygrad by rebuilding it in Zig";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # tinygrad's source, at the commit the course was checked against. The dev
  # shell puts it on PYTHONPATH, so `import tinygrad` works there (TINYGRAD.md).
  inputs.tinygrad = {
    url = "github:tinygrad/tinygrad/411dd8d54e8b1ddaa22dcfc760553f44e32ea95b";
    flake = false;
  };

  outputs =
    { nixpkgs, tinygrad, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (
        pkgs:
        let
          llvm = pkgs.llvmPackages_21; # the newest LLVM tinygrad looks for by name
        in
        {
          # NoCC: no gcc and no $CC, so tinygrad falls back to the clang below
          default = pkgs.mkShellNoCC (
            {
              packages = [
                pkgs.zig_0_16 # the course targets Zig 0.16.0
                pkgs.python3 # tools/gen.py, and tinygrad itself (TINYGRAD.md)
                llvm.clang-unwrapped # tinygrad's CPU backend compiles its kernels with clang
                pkgs.iverilog # Part VII simulates its Verilog with Icarus Verilog (211 on)
              ];
              shellHook = ''
                # The NVIDIA driver's libcuda comes from the host, not from nixpkgs:
                # NixOS, then the usual places on other Linux systems.
                for lib in /run/opengl-driver/lib/libcuda.so.1 /usr/lib/x86_64-linux-gnu/libcuda.so.1 /usr/lib64/libcuda.so.1 /usr/lib/wsl/lib/libcuda.so.1; do
                  if [ -e "$lib" ]; then export CUDA_PATH="$lib"; break; fi
                done
                # A tinygrad of your own earlier on PYTHONPATH wins over this one.
                export PYTHONPATH="''${PYTHONPATH:+$PYTHONPATH:}${tinygrad}"
                echo "zigrad: zig $(zig version). Run 'zig build' to check the exercises."
              '';
            }
            # What real tinygrad needs to run from this shell (TINYGRAD.md). It
            # finds shared libraries by name in /usr/lib, which Nix doesn't use,
            # so each one is named here. All from one nixpkgs, so they agree on
            # glibc with the python that loads them.
            // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
              LIBC_PATH = "${pkgs.glibc}/lib/libc.so.6";
              LLVM_PATH = "${llvm.libllvm.lib}/lib/libLLVM.so"; # DEV=CUDA:PTX and DEV=CPU:LLVM
            }
          );
        }
      );
    };
}
