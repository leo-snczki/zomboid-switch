# NixOS build (no flakes needed): `nix-shell`, then `pz-build all`. See nix/default.nix.
{ pkgs ? import <nixpkgs> { } }:
import ./nix/shell.nix { inherit pkgs; }
