# nixpkgs for the non-flake entry (shell.nix), pinned to the revision flake.lock locks, so both entries build the same
# store paths whatever channel this machine follows. Update both together.
import (builtins.fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/fcb8fcd6bf2d0adecae5bd491afaaaf8311b758d.tar.gz";
  sha256 = "1ni2nndk89vfvpzlakj8w2r1pbpqp9m5zf9k6h7fsxhn0lxbn4gl";
})
