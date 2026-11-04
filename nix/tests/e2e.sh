#!/usr/bin/env bash
# e2e.sh - seam 1 of the NixOS build: the whole build from an already-downloaded depot, then checks on what it made.
# Opt-in: 15-60 minutes, about 10 GB of memory + swap. Never logs into Steam (--offline).
#
#   nix-shell --run nix/tests/e2e.sh          # depot from PZ_DEPOT / pz-build.conf / the default (see pz-build help)
#
# The SD folder goes to PZ_E2E_SD_OUT (default pz41/out/e2e-sd, gitignored) so the real one is left alone; it is passed
# as an option, which wins over PZ_SD_OUT in the environment or pz-build.conf.
set -euo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd); cd "$ROOT"
command -v pz-build >/dev/null || { echo "FAIL: pz-build is not on PATH (run this inside nix-shell)"; exit 1; }
sd=${PZ_E2E_SD_OUT:-$ROOT/pz41/out/e2e-sd}

pz-build --offline --sd-out "$sd" all
pz-build run python3 nix/tests/check_outputs.py --nro pz41/pz41.nro --jobj pz41/build-a64/j.o --sd "$sd"
