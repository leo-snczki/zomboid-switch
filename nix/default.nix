# The NixOS build of the Switch port. Non-flake entry: `nix-shell` at the repo root puts `pz-build` on PATH.
#   env       FHS build environment (bubblewrap) the upstream scripts run in: /usr/bin/aarch64-linux-gnu-gcc, glibc for
#             the prebuilt GraalVM/devkitPro/ARM binaries, devkitPro mounted at /opt/devkitpro. No root, no system changes.
#   pz-build  the orchestrator (nix/pz-build.sh)
{ pkgs ? import <nixpkgs> { } }:
let
  toolchains = import ./toolchains.nix { inherit pkgs; };

  env = pkgs.buildFHSEnv {
    name = "pz-switch-env";
    targetPkgs = p: with p; [
      toolchains.crossLinks
      gcc binutils gnumake cmake pkg-config perl python3 imagemagick git curl cacert
      unzip zip xz zstd bzip2 gzip gnutar file which patch diffutils gnused gawk gnugrep findutils coreutils procps
      zlib zlib.dev ncurses
    ];
    # devkitPro lives outside the store (pacman-managed, see the devkitpro stage); $PZ_DKP_ROOT is expanded when the
    # environment starts
    extraBwrapArgs = [ ''--bind-try "''${PZ_DKP_ROOT:-$HOME/.local/share/pz-switch/dkp-root}/opt/devkitpro" /opt/devkitpro'' ];
    profile = ''
      export DEVKITPRO=/opt/devkitpro DEVKITA64=/opt/devkitpro/devkitA64
      export GRAALVM=${toolchains.graalvm}
      export PATH=/opt/devkitpro/tools/bin:$PATH
    '';
    runScript = "bash";
  };

  pz-build = pkgs.writeShellApplication {
    name = "pz-build";
    runtimeInputs = with pkgs; [ coreutils findutils gnugrep gnused gawk ];
    runtimeEnv = {
      PZ_FHS = "${env}/bin/pz-switch-env";
    };
    excludeShellChecks = [ "SC2016" ];   # single-quoted command lines handed to the environment are meant literally
    text = builtins.readFile ./pz-build.sh;
  };
in
{
  inherit env pz-build;
  inherit (toolchains) armToolchain graalvm;
}
