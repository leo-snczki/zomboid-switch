# Flake entry to the NixOS build (the non-flake one is shell.nix; both use nix/default.nix):
#   nix develop        a shell with pz-build        nix run . -- all        pz-build without a shell
{
  description = "Project Zomboid 41.78 for Nintendo Switch: the NixOS build (pz-build)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";   # the prebuilt toolchains (GraalVM, devkitPro, ARM GNU) are x86-64 Linux binaries
      pkgs = nixpkgs.legacyPackages.${system};
      pz = import ./nix/default.nix { inherit pkgs; };
    in
    {
      packages.${system} = {
        default = pz.pz-build;
        inherit (pz) pz-build env;
      };
      apps.${system}.default = {
        type = "app";
        program = "${pz.pz-build}/bin/pz-build";
      };
      devShells.${system}.default = import ./nix/shell.nix { inherit pkgs; };
    };
}
