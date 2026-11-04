# `nix-shell` (from the repo root, via ../shell.nix): a shell with `pz-build` on PATH.
{ pkgs ? import <nixpkgs> { } }:
let
  pz = import ./default.nix { inherit pkgs; };
in
pkgs.mkShellNoCC {
  packages = [ pz.pz-build ];
  shellHook = ''
    echo "zomboid-switch: 'pz-build all' builds the NRO and the SD folder; 'pz-build help' for the stages and options."
  '';
}
