#!/usr/bin/env bash
# steam.sh - seam 2 of the NixOS build: fetch-game downloads the game files with a Steam login DepotDownloader already
# remembers. Never prompts and never sees a password: it runs only when PZ_STEAM_USER is set and that login is
# remembered (log in once with `pz-build --steam-user NAME fetch-game`); otherwise it reports SKIPPED.
#
#   PZ_STEAM_USER=name nix-shell --run nix/tests/steam.sh      # downloads ~6.8 GB into a temporary folder
set -euo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd); cd "$ROOT"
command -v pz-build >/dev/null || { echo "FAIL: pz-build is not on PATH (run this inside nix-shell)"; exit 1; }
[ -n "${PZ_STEAM_USER:-}" ] || { echo "SKIPPED: PZ_STEAM_USER is not set"; exit 0; }

depot=$(mktemp -d "${TMPDIR:-/tmp}/pz-steam-test.XXXXXX"); trap 'rm -rf "$depot"' EXIT
rc=0
pz-build --non-interactive --force --depot "$depot" fetch-game </dev/null || rc=$?
[ $rc = 3 ] && { echo "SKIPPED: DepotDownloader has no remembered login for $PZ_STEAM_USER"; exit 0; }
[ $rc = 0 ] || { echo "FAIL: fetch-game exited with $rc"; exit 1; }

fail=0
check() { if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }
g=$depot/game/projectzomboid
check "manifest 8887512142279836582 (41.78) downloaded" '[ -f "$depot/game/.DepotDownloader/108603_8887512142279836582.manifest" ]'
for f in media stdlib.lbc libPZPopMan64.so linux64/libfmod.so.13.6; do check "game file $f" '[ -e "$g/$f" ]'; done
c=mods/BetterFPS/media/PotatoePC/zombie/iso/IsoChunkMap.class
check "BetterFPS downloaded" '[ -f "$depot/betterfps/$c" ]'
check "BetterFPS class in the jar step's mod overlay" 'cmp -s "$depot/betterfps/$c" pz41/mods/betterfps/classes/zombie/iso/IsoChunkMap.class'
[ $fail = 0 ] && echo "PASSED" || { echo "FAILED"; exit 1; }
