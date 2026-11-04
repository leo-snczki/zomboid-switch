# pz-build - the NixOS build of the Project Zomboid 41.78 Switch port (NixOS-WSL or native NixOS). `pz-build help`.
# Wrapped by writeShellApplication in nix/default.nix, which turns on errexit/nounset/pipefail and provides PZ_FHS
# (the FHS build environment), PZ_PACMAN_CONF and the host-side tools on PATH.

usage() {
  cat <<'EOF'
usage: pz-build [options] <stage>...
       pz-build run <command> [args...]     run a command inside the build environment, from the repo root
       pz-build shell                       open a shell inside the build environment

stages, run in the order given:
  env-check    toolchain versions, devkitPro status, memory check (with .wslconfig advice on WSL)
  devkitpro    install devkitPro's Switch packages into PZ_DKP_ROOT, signatures checked, no root
               (default ~/.local/share/pz-switch/dkp-root; --force to update)
  all          every stage below, in order

options:
  --depot DIR       game files: DIR/game is the Linux depot 108603, DIR/betterfps the BetterFPS item  [PZ_DEPOT]
  --sd-out DIR      the SD card folder to build                                                  [PZ_SD_OUT]
  --force           redo stages even when their outputs are up to date
  --skip-memcheck   build the native image even below the memory threshold

Defaults: on WSL <Windows user profile>\pz4-depot and \pz4-sd, otherwise ~/pz4-depot and ~/pz4-sd.
Settings can also be kept in pz-build.conf at the repo root (shell syntax, e.g. PZ_DEPOT=/mnt/d/pz4-depot).
EOF
}

die() { echo "pz-build: $*" >&2; exit 1; }
say() { printf '\n=== %s\n' "$*"; }

find_root() {
  local d=$PWD
  while [ "$d" != / ]; do
    if [ -f "$d/pz-switch/setup-deps.sh" ]; then echo "$d"; return 0; fi
    d=$(dirname "$d")
  done
  return 1
}

is_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; }

# Windows %USERPROFILE% as a /mnt/<drive>/... path (WSL interop)
win_home() {
  local cmd=/mnt/c/Windows/System32/cmd.exe p drive rest
  [ -x "$cmd" ] || return 1
  p=$(cd /mnt/c && "$cmd" /d /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r') || return 1
  case $p in [A-Za-z]:\\*) ;; *) return 1 ;; esac
  drive=${p:0:1}; rest=${p:2}
  echo "/mnt/${drive,,}${rest//\\//}"
}

# --- the build environment ---------------------------------------------------------------------------------------
in_env() { (cd "$PZROOT" && "$PZ_FHS" -c "$1"); }   # $1: a bash command line, run from the repo root

# --- stage bookkeeping: a stage is up to date when its outputs exist and its inputs' fingerprint is unchanged -----
fingerprint() {   # fingerprint <extra string> <repo paths...>
  local extra=$1; shift
  { echo "$extra"; (cd "$PZROOT" && find "$@" -type f ! -name '*.log' -print0 | sort -z | xargs -0 sha256sum); } \
    | sha256sum | cut -c1-16
}
mark() { mkdir -p "$STATE"; echo "$2" > "$STATE/$1.done"; }
up_to_date() { [ "$FORCE" = 0 ] && [ -f "$STATE/$1.done" ] && [ "$(cat "$STATE/$1.done")" = "$2" ]; }

# --- memory --------------------------------------------------------------------------------------------------------
# RAM + swap for the native image: its builder heap is capped at 24 GB, build 41 peaked at ~7 GB RSS
MEM_MIN_TOTAL_MIB=${PZ_MEM_MIN_MIB:-12288}
MEM_REC_RAM_MIB=8192
mem_check() {   # returns 1 below the minimum, after saying how to fix it
  local ram swap
  ram=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  swap=$(awk '/^SwapTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  echo "memory:       $ram MiB RAM + $swap MiB swap (native image: >= $MEM_MIN_TOTAL_MIB MiB together, >= $MEM_REC_RAM_MIB MiB RAM recommended)"
  if (( ram + swap >= MEM_MIN_TOTAL_MIB )); then
    (( ram >= MEM_REC_RAM_MIB )) || echo "  warning: with less than $MEM_REC_RAM_MIB MiB RAM the native image swaps a lot and is slow"
    return 0
  fi
  echo "  not enough memory for the native image."
  if is_wsl; then
    cat <<'EOF'
  WSL limits its memory (by default to half of the host's RAM). In Windows, write this to %USERPROFILE%\.wslconfig,
  leaving about 3 GB to Windows, then run `wsl --shutdown` in PowerShell and open this shell again:
      [wsl2]
      memory=12GB
      swap=16GB
EOF
  else
    echo '  add swap, e.g. on NixOS: swapDevices = [ { device = "/swapfile"; size = 16384; } ];'
  fi
  return 1
}

# --- devkitPro (installed by the devkitpro stage into PZ_DKP_ROOT, mounted at /opt/devkitpro in the environment) ---
DKP_FILES=(devkitA64/bin/aarch64-none-elf-gcc tools/bin/elf2nro tools/bin/nacptool libnx/lib/libnx.a
           portlibs/switch/lib/libEGL.a portlibs/switch/lib/libglapi.a portlibs/switch/lib/libdrm_nouveau.a)
dkp_ok() {
  local f
  for f in "${DKP_FILES[@]}"; do [ -e "$PZ_DKP_ROOT/opt/devkitpro/$f" ] || return 1; done
}
dkp_report() {
  if dkp_ok; then
    echo "devkitPro:    $(pacman --config "$PZ_DKP_ROOT/etc/pacman.conf" --root "$PZ_DKP_ROOT" --dbpath "$PZ_DKP_ROOT/var/lib/pacman" \
      -Q devkitA64 libnx switch-mesa switch-libdrm_nouveau 2>/dev/null | tr '\n' ' ')"
    echo "              in $PZ_DKP_ROOT/opt/devkitpro"
  else
    echo "devkitPro:    not installed (pz-build devkitpro)"
  fi
}

# devkitPro's server only serves pacman (plain curl gets 403), so everything goes through pacman: no User-Agent tricks,
# no unsigned packages. pacman runs in a user namespace (unshare -r), so no root is needed.
DKP_WINTERMUTE_KEY=BC26F752D25B92CE272E0F44F7FD5492264BB9D0   # Dave Murphy (WinterMute): signs devkitpro-keyring
DKP_REPO_KEY=032F4C9D0B8FF3BC84019B7862C7609ADA219C60         # signs the repositories today; comes with devkitpro-keyring
DKP_PACKAGES=(devkitpro-keyring switch-dev switch-mesa switch-libdrm_nouveau)
dkp_key() { unshare -r pacman-key --config "$PZ_DKP_ROOT/etc/pacman.conf" --gpgdir "$PZ_DKP_ROOT/etc/pacman.d/gnupg" "$@"; }
dkp_pacman() {
  unshare -r pacman --config "$PZ_DKP_ROOT/etc/pacman.conf" --root "$PZ_DKP_ROOT" --dbpath "$PZ_DKP_ROOT/var/lib/pacman" \
    --cachedir "$PZ_DKP_ROOT/var/cache/pacman/pkg" --gpgdir "$PZ_DKP_ROOT/etc/pacman.d/gnupg" \
    --noconfirm --noprogressbar --noscriptlet "$@"
}

stage_devkitpro() {
  local r=$PZ_DKP_ROOT kr k
  if [ "$FORCE" = 0 ] && dkp_ok; then dkp_report; return 0; fi
  mkdir -p "$r/etc/pacman.d/gnupg" "$r/var/lib/pacman/sync" "$r/var/cache/pacman/pkg" "$r/opt/devkitpro"
  install -m 644 "$PZ_PACMAN_CONF" "$r/etc/pacman.conf"
  if [ ! -e "$r/etc/pacman.d/gnupg/pubring.gpg" ] && [ ! -e "$r/etc/pacman.d/gnupg/pubring.kbx" ]; then dkp_key --init; fi
  if ! dkp_key --list-keys "$DKP_WINTERMUTE_KEY" >/dev/null 2>&1; then
    dkp_key --keyserver hkps://keyserver.ubuntu.com --recv-keys "$DKP_WINTERMUTE_KEY"
    dkp_key --lsign-key "$DKP_WINTERMUTE_KEY"
  fi
  # a sync that failed earlier leaves databases pacman refuses to load (even for -U); -Sy fetches them again
  rm -f "$r"/var/lib/pacman/sync/*
  if ! dkp_key --list-keys "$DKP_REPO_KEY" >/dev/null 2>&1; then
    # pacman checks the keyring package's signature against WinterMute's key before installing it
    dkp_pacman -U https://pkg.devkitpro.org/devkitpro-keyring.pkg.tar.zst
    kr=$r/usr/share/pacman/keyrings   # what `pacman-key --populate devkitpro` would do (scriptlets are off)
    dkp_key --add "$kr/devkitpro.gpg"
    while IFS=: read -r k _; do [ -z "$k" ] || dkp_key --lsign-key "$k"; done < "$kr/devkitpro-trusted"
    while IFS=: read -r k _; do [ -z "$k" ] || dkp_key --delete "$k" || true; done < "$kr/devkitpro-revoked"
  fi
  dkp_pacman -Sy --needed "${DKP_PACKAGES[@]}"
  dkp_ok || die "pacman finished but devkitPro files are missing under $r/opt/devkitpro"
  dkp_report
}

# --- stages ----------------------------------------------------------------------------------------------------------
stage_env_check() {
  local ok=0
  in_env '
    set -e
    for t in aarch64-linux-gnu-gcc aarch64-linux-gnu-ld aarch64-linux-gnu-ar aarch64-linux-gnu-objcopy aarch64-linux-gnu-nm \
             aarch64-linux-gnu-readelf magick cmake make python3 git curl zip unzip; do
      command -v $t >/dev/null || { echo "missing: $t"; exit 1; }
    done
    [ -x /usr/bin/aarch64-linux-gnu-gcc ] || { echo "missing /usr/bin/aarch64-linux-gnu-gcc (the native image is told this path)"; exit 1; }
    for d in lib/static/linux-aarch64 lib/svm/clibraries/linux-aarch64; do
      [ -d "$GRAALVM/$d" ] || { echo "GraalVM has no $d"; exit 1; }
    done
    echo "cross gcc:    $(aarch64-linux-gnu-gcc --version | head -1)"
    echo "binutils:     $(aarch64-linux-gnu-ld --version | head -1)"
    echo "GraalVM:      $("$GRAALVM"/bin/native-image --version | head -1)"
    echo "ImageMagick:  $(magick -version | head -1)"
    echo "cmake:        $(cmake --version | head -1)"
    echo "python:       $(python3 --version)"
  ' || ok=1
  dkp_report
  echo "game files:   $PZ_DEPOT"
  echo "SD folder:    $PZ_SD_OUT"
  if [ "$SKIP_MEM" = 1 ]; then mem_check || true; else mem_check || ok=1; fi
  [ $ok = 0 ] || die "env-check failed"
}

ALL_STAGES=(env-check devkitpro)

# --- command line ----------------------------------------------------------------------------------------------------
PZROOT=${PZROOT:-$(find_root)} || die "not inside a zomboid-switch checkout (cd into one or set PZROOT)"
export PZROOT
if [ -f "$PZROOT/pz-build.conf" ]; then
  # shellcheck source=/dev/null
  . "$PZROOT/pz-build.conf"
fi
FORCE=0 SKIP_MEM=0
STAGES=()
while [ $# -gt 0 ]; do
  case $1 in
    --depot) PZ_DEPOT=${2:?--depot needs a directory}; shift 2 ;;
    --sd-out) PZ_SD_OUT=${2:?--sd-out needs a directory}; shift 2 ;;
    --force) FORCE=1; shift ;;
    --skip-memcheck) SKIP_MEM=1; shift ;;
    -h | --help | help) usage; exit 0 ;;
    run) shift; STAGES=(run); break ;;
    -*) die "unknown option $1 (pz-build help)" ;;
    *) STAGES+=("$1"); shift ;;
  esac
done
[ ${#STAGES[@]} -gt 0 ] || { usage; exit 1; }

if [ -z "${PZ_DEPOT:-}" ] || [ -z "${PZ_SD_OUT:-}" ]; then
  base=$HOME
  if is_wsl && wh=$(win_home); then base=$wh; fi
  PZ_DEPOT=${PZ_DEPOT:-$base/pz4-depot}; PZ_SD_OUT=${PZ_SD_OUT:-$base/pz4-sd}
fi
PZ_DKP_ROOT=${PZ_DKP_ROOT:-$HOME/.local/share/pz-switch/dkp-root}
export PZ_DEPOT PZ_SD_OUT PZ_DKP_ROOT   # PZ_DKP_ROOT: the environment mounts its opt/devkitpro at /opt/devkitpro
STATE=$PZROOT/.pz-build

case ${STAGES[0]} in
  run) [ $# -gt 0 ] || die "run needs a command"; cd "$PZROOT"; exec "$PZ_FHS" -c '"$@"' pz-build-run "$@" ;;
  shell) cd "$PZROOT"; exec "$PZ_FHS" ;;
esac

declare -A TOOK
ORDER=()
for s in "${STAGES[@]}"; do
  if [ "$s" = all ]; then list=("${ALL_STAGES[@]}"); else list=("$s"); fi
  for st in "${list[@]}"; do
    fn=stage_${st//-/_}
    declare -F "$fn" >/dev/null || die "unknown stage '$st' (pz-build help)"
    say "$st"
    t0=$SECONDS
    "$fn"
    TOOK[$st]=$((SECONDS - t0)); ORDER+=("$st")
  done
done
if [ ${#ORDER[@]} -gt 1 ]; then
  say "done"
  for st in "${ORDER[@]}"; do printf '  %-11s %4d:%02d\n' "$st" $((TOOK[$st] / 60)) $((TOOK[$st] % 60)); done
fi
