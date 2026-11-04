# NixOS build (no flakes needed): `nix-shell`, then `pz-build all`. See nix/default.nix.
{ pkgs ? import ./nix/nixpkgs.nix { } }:
import ./nix/shell.nix { inherit pkgs; }
