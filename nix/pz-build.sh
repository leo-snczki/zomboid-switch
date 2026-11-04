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
  fetch-game   download Project Zomboid 41.78 for Linux (depot 108603) and BetterFPS with your Steam login; skipped
               when PZ_DEPOT already has them (BetterFPS is also taken from a local Steam workshop folder)
  deps         musl, zlib, libffi, the LWJGL/OpenGL/stb/sqlite natives, box64 and the x86 libraries (setup-deps.sh)
  nro          pz41/pz41.nro from the game files: jar, reflection config, aarch64 native image (needs memory), link
  sd           the SD card folder (PZ_SD_OUT): switch/pz41.nro, pz41/ with args, x86 libraries, game natives, game
               data in FAT32-sized parts, the SwitchTreatment mod; no symlinks
  all          env-check devkitpro fetch-game deps nro sd, in order
  clean        delete what the build made, devkitPro included (asks first; --force doesn't), keeping the game
               files, the SD folder and the Steam login

options:
  --depot DIR       game files: DIR/game is the Linux depot 108603, DIR/betterfps the BetterFPS item  [PZ_DEPOT]
  --sd-out DIR      the SD card folder to build                                                  [PZ_SD_OUT]
  --force           redo stages even when their outputs are up to date
  --skip-memcheck   build the native image even below the memory threshold
  --offline         never log into Steam; fail when game files are missing
  --steam-user NAME Steam username for fetch-game (asked for when not given)                [PZ_STEAM_USER]
  --qr              log into Steam with a QR code in the Steam app instead of a password
  --non-interactive never prompt: fetch-game needs a login DepotDownloader remembers (exit 3 if there is none)

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
unmark() { rm -f "$STATE/$1.done"; }   # before a stage starts work, so a failed run is never taken as up to date
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

# --- deps: musl (plain + Horizon), zlib, libffi, LWJGL/OpenGL/stb and sqlite natives, box64 + JNI bridge, x86 libs ----
DEPS_IN=(pz-switch/setup-deps.sh pz-switch/build-natives.sh pz-switch/build-box64.sh pz-switch/horizon/box64
         pz-switch/horizon/musl-nx.patch pz-switch/horizon/jside)
DEPS_OUT=(pz-switch/deps/natives-out/lwjgl.o pz-switch/deps/natives-out/lwjgl_opengl.o pz-switch/deps/natives-out/lwjgl_stb.o
          pz-switch/deps/natives-out/sqlitejdbc.o pz-switch/deps/natives-out/box64.o
          pz-switch/xfer/x86libs/_ld-linux-x86-64.so.2 pz-switch/xfer/x86libs/_libc.so.6 pz-switch/xfer/x86libs/libgcc_s.so.1
          pz-switch/xfer/x86libs/libjniwrapper.so pz-switch/xfer/x86libs/libstdc++.so.6)
outputs_ok() { local f; for f in "$@"; do [ -s "$PZROOT/$f" ] || { echo "missing: $f"; return 1; }; done; }
deps_fp() { fingerprint "$PZ_TOOLCHAINS" "${DEPS_IN[@]}"; }

stage_deps() {
  local fp; fp=$(deps_fp)
  if outputs_ok "${DEPS_OUT[@]}" >/dev/null && up_to_date deps "$fp"; then echo "up to date"; return 0; fi
  unmark deps
  # setup-deps.sh skips what it already built (musl, zlib, libffi, clones); natives and box64 are rebuilt
  in_env './pz-switch/setup-deps.sh' || die "deps: setup-deps.sh failed"
  outputs_ok "${DEPS_OUT[@]}" || die "deps: setup-deps.sh finished, but outputs are missing"
  mark deps "$fp"
}

# --- game files: PZ_DEPOT/game = Linux depot 108603 (manifest of 41.78), PZ_DEPOT/betterfps = workshop item -------------
DEPOT_MANIFEST=108603_8887512142279836582
DEPOT_REQUIRED=(media stdlib.lbc stdlib.lua serialize.lua projectzomboid.png zombie lwjgl_util.jar sqlite-jdbc-3.27.2.1.jar
  commons-compress-1.18.jar istack-commons-runtime.jar jassimp.jar javacord-2.0.17-shaded.jar javax.activation-api.jar
  jaxb-api.jar jaxb-runtime.jar trove-3.0.3.jar uncommons-maths-1.2.3.jar libfmodintegration64.so libjassimp64.so
  libLighting64.so libPZBullet64.so libPZBulletNoOpenGL64.so libPZClipper64.so libPZPopMan64.so libRakNet64.so
  libZNetNoSteam64.so linux64/libfmod.so.13.6 linux64/libfmodstudio.so.13.6)
BFPS_ID=3022543997
BFPS_CLASS=mods/BetterFPS/media/PotatoePC/zombie/iso/IsoChunkMap.class

depot_check() {   # lists what's missing; returns 1 if anything is
  local g=$PZ_DEPOT/game/projectzomboid f missing=()
  for f in "${DEPOT_REQUIRED[@]}"; do [ -e "$g/$f" ] || missing+=("$f"); done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "game files in $PZ_DEPOT/game are incomplete; missing from projectzomboid/: ${missing[*]}"
    return 1
  fi
  if [ -d "$PZ_DEPOT/game/.DepotDownloader" ] && [ ! -f "$PZ_DEPOT/game/.DepotDownloader/$DEPOT_MANIFEST.manifest" ]; then
    echo "$PZ_DEPOT/game was downloaded from another manifest than $DEPOT_MANIFEST (build 41.78)"
    return 1
  fi
}
depot_id() {   # changes when the game files do
  if [ -f "$PZ_DEPOT/game/.DepotDownloader/$DEPOT_MANIFEST.manifest.sha" ]; then
    cat "$PZ_DEPOT/game/.DepotDownloader/$DEPOT_MANIFEST.manifest.sha"
  else
    (cd "$PZ_DEPOT/game/projectzomboid" && stat -c '%n %s %Y' "${DEPOT_REQUIRED[@]}")
  fi | sha256sum | cut -c1-16
}

betterfps_sources() {   # places that may already hold the BetterFPS workshop item
  echo "$PZ_DEPOT/betterfps"
  echo "$HOME/.local/share/Steam/steamapps/workshop/content/108600/$BFPS_ID"
  echo "$HOME/.steam/steam/steamapps/workshop/content/108600/$BFPS_ID"
  if is_wsl; then echo "/mnt/c/Program Files (x86)/Steam/steamapps/workshop/content/108600/$BFPS_ID"; fi
}
ensure_betterfps() {   # BetterFPS in PZ_DEPOT/betterfps, and its IsoChunkMap in the jar step's mod overlay
  local d
  if [ ! -f "$PZ_DEPOT/betterfps/$BFPS_CLASS" ]; then
    while read -r d; do
      if [ -f "$d/$BFPS_CLASS" ]; then
        mkdir -p "$PZ_DEPOT/betterfps" && cp -r "$d/." "$PZ_DEPOT/betterfps/"
        echo "BetterFPS: copied from $d"
        break
      fi
    done < <(betterfps_sources)
  fi
  [ -f "$PZ_DEPOT/betterfps/$BFPS_CLASS" ] || return 1
  install -D -m 644 "$PZ_DEPOT/betterfps/$BFPS_CLASS" "$PZROOT/pz41/mods/betterfps/classes/zombie/iso/IsoChunkMap.class"
}

# --- fetch-game: the user's own copy, through DepotDownloader -------------------------------------------------------
# The password and Steam Guard code are typed into DepotDownloader's own prompts (or replaced by a QR login with the
# Steam app); pz-build only ever passes the username. -remember-password keeps a login token in DepotDownloader's
# per-user storage (outside the repo), so later runs need no interaction.
DD_GAME=(-app 108600 -depot 108603 -manifest 8887512142279836582 -beta legacy41)
steam_remembered() {   # does DepotDownloader hold a login token for this user?
  local f
  while IFS= read -r -d '' f; do grep -qaF -- "$1" "$f" && return 0; done \
    < <(find "${XDG_DATA_HOME:-$HOME/.local/share}/IsolatedStorage" -name account.config -print0 2>/dev/null)
  return 1
}

stage_fetch_game() {
  local user=${PZ_STEAM_USER:-} login=()
  if [ "$FORCE" = 0 ] && depot_check >/dev/null && ensure_betterfps; then
    echo "game files already in $PZ_DEPOT (--force to download them again)"; return 0
  fi
  [ "$OFFLINE" = 0 ] || die "fetch-game: game files missing in $PZ_DEPOT, and --offline rules out a Steam download"
  if [ "$NONINTERACTIVE" = 1 ]; then
    if [ -z "$user" ] || ! steam_remembered "$user"; then
      echo "fetch-game: no remembered Steam login for '${user:-(no --steam-user)}'; log in once without --non-interactive"
      exit 3
    fi
  elif [ "$QR" = 0 ] && [ -z "$user" ]; then
    read -r -p "Steam username (leave empty to log in with a QR code in the Steam app): " user < /dev/tty \
      || die "fetch-game: no terminal to ask on; pass --steam-user NAME or --qr"
  fi
  if [ "$QR" = 1 ] || [ -z "$user" ]; then login=(-qr); else login=(-username "$user"); fi
  login+=(-remember-password)
  echo "DepotDownloader asks for the Steam password and Steam Guard code itself; pz-build never sees them."
  mkdir -p "$PZ_DEPOT"
  DepotDownloader "${DD_GAME[@]}" "${login[@]}" -dir "$PZ_DEPOT/game" || die "fetch-game: DepotDownloader failed"
  depot_check || die "fetch-game: the download finished, but the game files are incomplete"
  if [ "$FORCE" = 1 ] || ! ensure_betterfps; then
    DepotDownloader -app 108600 -pubfile "$BFPS_ID" "${login[@]}" -dir "$PZ_DEPOT/betterfps" \
      || die "fetch-game: downloading BetterFPS failed"
    ensure_betterfps || die "fetch-game: BetterFPS was downloaded, but has no $BFPS_CLASS"
  fi
  echo "game files: $PZ_DEPOT"
}

link_game() {   # the upstream scripts read the game from pz41/game
  local l=$PZROOT/pz41/game
  if [ -e "$l" ] && [ ! -L "$l" ]; then
    [ "$(readlink -f "$l")" = "$(readlink -f "$PZ_DEPOT/game")" ] || die "pz41/game is a real folder; move it into $PZ_DEPOT/game or point --depot at its parent"
    return 0
  fi
  ln -sfn "$PZ_DEPOT/game" "$l"
}

# --- nro: pz41.jar -> Lua/JNI reachability config -> aarch64 native image -> pz41.nro ---------------------------------
NRO_IN=(pz41/make-jar.sh pz41/b42-substitute.sh pz41/build-image.sh pz41/build-nro.sh pz41/patches pz41/config-res
        pz-switch/build-a64.sh pz-switch/prelink-j.sh pz-switch/gen-lua-config.py pz-switch/gen-natives.py pz-switch/tools
        pz-switch/config pz-switch/buildtime.txt pz-switch/cap-a64 pz-switch/horizon/app/Makefile pz-switch/horizon/lxnx
        pz-switch/horizon/jside)
b42_detect() {   # a build 42 game jar, if one is installed, is used for LWJGL/sqlite-jdbc (else make-jar.sh substitutes)
  local j
  for j in "${B42JAR:-}" "$HOME/.steam/steam/steamapps/common/ProjectZomboid/projectzomboid/projectzomboid.jar" \
           "$HOME/.local/share/Steam/steamapps/common/ProjectZomboid/projectzomboid/projectzomboid.jar" \
           "/mnt/c/Program Files (x86)/Steam/steamapps/common/ProjectZomboid/projectzomboid.jar"; do
    if [ -n "$j" ] && [ -f "$j" ]; then export B42JAR=$j; return 0; fi
  done
  unset B42JAR
}
nro_magic_ok() { [ "$(dd if="$1" bs=1 skip=16 count=4 2>/dev/null)" = NRO0 ]; }

stage_nro() {
  local nro=$PZROOT/pz41/pz41.nro log=$PZROOT/pz41/ni-a64.log fp tailpid
  if ! depot_check; then
    [ "$OFFLINE" = 1 ] && die "nro: game files missing, and --offline rules out a Steam download (use --depot)"
    die "nro: game files missing (pz-build fetch-game, or --depot)"
  fi
  ensure_betterfps || die "nro: BetterFPS (workshop item $BFPS_ID) not found; pz-build fetch-game downloads it"
  link_game
  outputs_ok "${DEPS_OUT[@]}" >/dev/null || die "nro: dependencies missing (pz-build deps)"
  dkp_ok || die "nro: devkitPro missing (pz-build devkitpro)"
  b42_detect
  fp=$(fingerprint "$PZ_TOOLCHAINS $(deps_fp) $(depot_id) ${B42JAR:-substitute} $(dkp_report | head -1)" \
       "${NRO_IN[@]}" pz41/mods)
  if [ -s "$nro" ] && up_to_date nro "$fp"; then echo "up to date: $nro"; return 0; fi
  if [ "$SKIP_MEM" = 0 ]; then
    mem_check || die "nro: not enough memory for the native image (--skip-memcheck to try anyway)"
  fi
  unmark nro; rm -f "$nro"
  echo "game files: $PZ_DEPOT/game"
  in_env 'cd pz41 && ./make-jar.sh' || die "nro: make-jar.sh failed"
  in_env 'cd pz41 && JAR=$PWD/pz41.jar OUT=$PWD/config-lua NATIVES="$PWD/game/projectzomboid/*.so" python3 ../pz-switch/gen-lua-config.py' \
    || die "nro: gen-lua-config.py failed"
  echo "native image (log: pz41/ni-a64.log):"
  : > "$log"
  tail -n +1 -F "$log" 2>/dev/null & tailpid=$!
  if ! in_env 'cd pz41 && ./build-image.sh'; then kill "$tailpid"; die "nro: native image failed (pz41/ni-a64.log)"; fi
  sleep 1; kill "$tailpid"; wait "$tailpid" 2>/dev/null || true
  in_env 'cd pz41 && ./build-nro.sh' || die "nro: linking the NRO failed"
  nro_magic_ok "$nro" || die "nro: build-nro.sh finished, but $nro is not an NRO"
  mark nro "$fp"
  echo "NRO: $nro ($(du -h "$nro" | cut -f1))"
}

# --- sd: the folder to copy to the SD card's root ----------------------------------------------------------------------
stage_sd() {
  local nro=$PZROOT/pz41/pz41.nro o=$PZ_SD_OUT fp
  if [ ! -f "$nro" ] || ! nro_magic_ok "$nro"; then die "sd: no NRO yet (pz-build nro)"; fi
  depot_check || die "sd: game files missing in $PZ_DEPOT"
  # the game data (6.6 GB, FAT32-sized parts) only depends on the game files: repack it only when they change
  fp=$(fingerprint "$(depot_id) $o" pz41/share/setup-sd.py)
  if [ -f "$o/pz41/xfer/game.tar.00" ] && up_to_date sd-data "$fp"; then
    echo "game data up to date in $o/pz41/xfer"
  else
    unmark sd-data
    python3 "$PZROOT/pz41/share/setup-sd.py" "$PZ_DEPOT/game/projectzomboid" "$o" || die "sd: setup-sd.py failed"
    mark sd-data "$fp"
  fi
  mkdir -p "$o/switch" "$o/pz41/game/x86libs" "$o/pz41/zomboid/mods"
  cp "$nro" "$o/switch/pz41.nro"
  cp "$PZROOT/pz41/args.txt" "$o/pz41/args.txt"
  cp -L "$PZROOT"/pz-switch/xfer/x86libs/* "$o/pz41/game/x86libs/"
  rm -rf "$o/pz41/zomboid/mods/SwitchTreatment"
  cp -r "$PZROOT/pz41/share/mods/SwitchTreatment" "$o/pz41/zomboid/mods/"
  [ -z "$(find "$o" -type l)" ] || die "sd: $o has symlinks, which a FAT32 card can't hold"
  echo "SD folder: $o ($(du -sh "$o" | cut -f1)); copy what's inside it to the root of the SD card"
}

# --- clean: everything pz-build made, except the game files, the SD folder and the Steam login ----------------------
CLEAN_PATHS=(.pz-build pz41/jar pz41/pz41.jar pz41/build-a64 pz41/natives-out pz41/ni-a64.log pz41/pz41.nro pz41/game
             pz41/mods/betterfps pz41/out/e2e-sd pz-switch/deps pz-switch/xfer pz-switch/horizon/app/build41
             pz-switch/horizon/app/pz41.elf pz-switch/horizon/app/pz41.nacp pz-switch/horizon/box64/inc/linux
             pz-switch/horizon/box64/inc/asm-generic)
stage_clean() {
  local p d=${PZ_DKP_ROOT%/} slashes
  slashes=${d//[!\/]/}
  # only a devkitPro root this stage would have made: at least three levels deep, holding opt/devkitpro
  if [ "${#slashes}" -lt 3 ] || [ "$d" = "${HOME%/}" ] || { [ -e "$d" ] && [ ! -d "$d/opt/devkitpro" ]; }; then
    die "clean: refusing to delete PZ_DKP_ROOT=$PZ_DKP_ROOT (not a devkitPro root)"
  fi
  echo "removes: in $PZROOT: ${CLEAN_PATHS[*]} and the generated box64 asm header links"
  echo "         devkitPro: $PZ_DKP_ROOT"
  echo "keeps:   the game files ($PZ_DEPOT), the SD folder ($PZ_SD_OUT), DepotDownloader's remembered Steam login"
  echo "         (~/.local/share/IsolatedStorage) and the Nix store (nix-collect-garbage frees what nothing uses)"
  if [ "$FORCE" = 0 ]; then
    [ "$NONINTERACTIVE" = 0 ] || die "clean: needs --force with --non-interactive"
    read -r -p "remove them? [y/N] " p < /dev/tty || p=
    case $p in y | Y) ;; *) echo "nothing removed"; return 0 ;; esac
  fi
  for p in "${CLEAN_PATHS[@]}"; do rm -rf "${PZROOT:?}/$p"; done
  while read -r p; do
    [ -z "$p" ] || rm -f "$PZROOT/pz-switch/horizon/box64/inc/asm/$p"
  done < "$PZROOT/pz-switch/horizon/box64/asm-headers.txt"
  rm -rf "$PZ_DKP_ROOT"
  echo "removed"
}

ALL_STAGES=(env-check devkitpro fetch-game deps nro sd)

# --- command line ----------------------------------------------------------------------------------------------------
PZROOT=${PZROOT:-$(find_root)} || die "not inside a zomboid-switch checkout (cd into one or set PZROOT)"
export PZROOT
if [ -f "$PZROOT/pz-build.conf" ]; then
  # shellcheck source=/dev/null
  . "$PZROOT/pz-build.conf"
fi
FORCE=0 SKIP_MEM=0 OFFLINE=0 QR=0 NONINTERACTIVE=0
STAGES=()
while [ $# -gt 0 ]; do
  case $1 in
    --depot) PZ_DEPOT=${2:?--depot needs a directory}; shift 2 ;;
    --sd-out) PZ_SD_OUT=${2:?--sd-out needs a directory}; shift 2 ;;
    --force) FORCE=1; shift ;;
    --skip-memcheck) SKIP_MEM=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --steam-user) PZ_STEAM_USER=${2:?--steam-user needs a name}; shift 2 ;;
    --qr) QR=1; shift ;;
    --non-interactive) NONINTERACTIVE=1; shift ;;
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
