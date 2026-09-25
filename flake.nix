{
  description = "zigrad: learn tinygrad by rebuilding it in Zig";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
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
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig_0_16 # the course targets Zig 0.16.0
            pkgs.python3 # only for tools/gen.py
          ];
          shellHook = ''
            echo "zigrad: zig $(zig version). Run 'zig build' to check the exercises."
          '';
        };
      });
    };
}
