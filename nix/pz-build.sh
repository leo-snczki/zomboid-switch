# pz-build - the NixOS build of the Project Zomboid 41.78 Switch port (NixOS-WSL or native NixOS). `pz-build help`.
# Wrapped by writeShellApplication in nix/default.nix, which turns on errexit/nounset/pipefail and provides PZ_FHS
# (the FHS build environment), PZ_PACMAN_CONF, PZ_TOOLCHAINS and the host-side tools on PATH.

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
  --steam-user NAME Steam account name for fetch-game (asked for when not given)            [PZ_STEAM_USER]
  --qr              log into Steam with a QR code in the Steam app instead of a password; with --steam-user,
                    later runs reuse that login
  --non-interactive never prompt: fetch-game needs a login DepotDownloader remembers (exit 3 if there is none)

Defaults: on WSL <Windows user profile>\pz4-depot and \pz4-sd, otherwise ~/pz4-depot and ~/pz4-sd.
PZ_DEPOT, PZ_SD_OUT, PZ_DKP_ROOT and PZ_STEAM_USER can also be set in pz-build.conf at the repo root (shell syntax,
e.g. PZ_DEPOT=/mnt/d/pz4-depot). Options win over environment variables, which win over pz-build.conf.
EOF
}

die() { echo "pz-build: $*" >&2; exit 1; }
say() { printf '\n=== %s\n' "$*"; }
mmss() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

find_root() {
  local d=$PWD
  while [ "$d" != / ]; do
    if [ -f "$d/pz-switch/setup-deps.sh" ]; then echo "$d"; return 0; fi
    d=$(dirname "$d")
  done
  return 1
}

# --- WSL ---------------------------------------------------------------------------------------------------------------
is_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; }
win_run() {   # win_run <exe under /mnt/c/Windows/System32> <args...>: run a Windows program through WSL interop
  local exe=/mnt/c/Windows/System32/$1; shift
  [ -x "$exe" ] || return 1
  (cd /mnt/c && "$exe" "$@" 2>/dev/null | tr -d '\r')
}
win_home() {   # Windows %USERPROFILE% as a /mnt/<drive>/... path
  local p drive rest
  p=$(win_run cmd.exe /d /c 'echo %USERPROFILE%') || return 1
  case $p in [A-Za-z]:\\*) ;; *) return 1 ;; esac
  drive=${p:0:1}; rest=${p:2}
  echo "/mnt/${drive,,}${rest//\\//}"
}
win_ram_gib() {   # the Windows host's RAM in GiB
  local g
  g=$(win_run WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command \
      '[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB)') || return 1
  [[ $g =~ ^[0-9]+$ ]] && echo "$g"
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
outputs_ok() {   # outputs_ok <dir> <paths...>: every path exists under <dir> and isn't empty
  local d=$1 f; shift
  for f in "$@"; do [ -s "$d/$f" ] || { echo "missing: $d/$f"; return 1; }; done
}

# --- memory --------------------------------------------------------------------------------------------------------
# RAM + swap for the native image: its builder heap is capped at 24 GB, build 41 peaked at ~7 GB RSS
MEM_MIN_TOTAL_MIB=12288
MEM_REC_RAM_MIB=8192
mem_check() {   # returns 1 below the minimum, after saying how to fix it
  local ram swap host
  ram=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  swap=$(awk '/^SwapTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  echo "memory:       $ram MiB RAM + $swap MiB swap (native image: >= $MEM_MIN_TOTAL_MIB MiB together, >= $MEM_REC_RAM_MIB MiB RAM recommended)"
  if (( ram + swap >= MEM_MIN_TOTAL_MIB )); then
    (( ram >= MEM_REC_RAM_MIB )) || echo "  warning: with less than $MEM_REC_RAM_MIB MiB RAM the native image swaps a lot and is slow"
    return 0
  fi
  echo "  not enough memory for the native image."
  if is_wsl; then
    echo "  WSL limits its memory (by default to half of the host's RAM). In Windows, put this in %USERPROFILE%\\.wslconfig"
    echo "  (merge it into an existing [wsl2] section), then run \`wsl --shutdown\` in PowerShell and open this shell again:"
    echo "      [wsl2]"
    if host=$(win_ram_gib); then
      echo "      memory=$(( host > 7 ? host - 3 : 4 ))GB      # this PC has $host GB; ~3 GB stay with Windows"
    else
      echo "      memory=<this PC's RAM minus 3>GB"
    fi
    echo "      swap=16GB"
  else
    echo '  add swap, e.g. on NixOS: swapDevices = [ { device = "/swapfile"; size = 16384; } ];'
  fi
  return 1
}

# --- devkitPro (installed by the devkitpro stage into PZ_DKP_ROOT, mounted at /opt/devkitpro in the environment) ---
DKP_FILES=(devkitA64/bin/aarch64-none-elf-gcc tools/bin/elf2nro tools/bin/nacptool libnx/lib/libnx.a
           portlibs/switch/lib/libEGL.a portlibs/switch/lib/libglapi.a portlibs/switch/lib/libdrm_nouveau.a)
dkp_ok() { outputs_ok "$PZ_DKP_ROOT/opt/devkitpro" "${DKP_FILES[@]}" >/dev/null; }

# devkitPro's server only serves pacman (plain curl gets 403), so everything goes through pacman: no User-Agent tricks,
# no unsigned packages. pacman runs in a user namespace (unshare -r), so no root is needed.
DKP_WINTERMUTE_KEY=BC26F752D25B92CE272E0F44F7FD5492264BB9D0   # Dave Murphy (WinterMute): signs devkitpro-keyring
DKP_REPO_KEY=032F4C9D0B8FF3BC84019B7862C7609ADA219C60         # signs the repositories today; comes with devkitpro-keyring
DKP_PACKAGES=(devkitpro-keyring switch-dev switch-mesa switch-libdrm_nouveau)
dkp_set_args() {   # DKP_ARGS: pacman's view of PZ_DKP_ROOT
  local r=$PZ_DKP_ROOT
  DKP_ARGS=(--config "$r/etc/pacman.conf" --root "$r" --dbpath "$r/var/lib/pacman" --cachedir "$r/var/cache/pacman/pkg"
            --gpgdir "$r/etc/pacman.d/gnupg")
}
dkp_key() { unshare -r pacman-key --config "$PZ_DKP_ROOT/etc/pacman.conf" --gpgdir "$PZ_DKP_ROOT/etc/pacman.d/gnupg" "$@"; }
dkp_pacman() { dkp_set_args; unshare -r pacman "${DKP_ARGS[@]}" --noconfirm --noprogressbar --noscriptlet "$@"; }
dkp_report() {
  if dkp_ok; then
    dkp_set_args
    echo "devkitPro:    $(pacman "${DKP_ARGS[@]}" -Q devkitA64 libnx switch-mesa switch-libdrm_nouveau 2>/dev/null | tr '\n' ' ')"
    echo "              in $PZ_DKP_ROOT/opt/devkitpro"
  else
    echo "devkitPro:    not installed (pz-build devkitpro)"
  fi
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

# --- env-check ---------------------------------------------------------------------------------------------------------
stage_env_check() {
  local failed=0
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
  ' || failed=1
  dkp_report
  echo "game files:   $PZ_DEPOT"
  echo "SD folder:    $PZ_SD_OUT"
  if [ "$SKIP_MEM" = 1 ]; then mem_check || true; else mem_check || failed=1; fi
  [ $failed = 0 ] || die "env-check failed"
}

# --- deps: musl (plain + Horizon), zlib, libffi, LWJGL/OpenGL/stb and sqlite natives, box64 + JNI bridge, x86 libs ----
DEPS_IN=(pz-switch/setup-deps.sh pz-switch/build-natives.sh pz-switch/build-box64.sh pz-switch/horizon/box64
         pz-switch/horizon/musl-nx.patch pz-switch/horizon/jside)
X86LIBS=(_ld-linux-x86-64.so.2 _libc.so.6 libgcc_s.so.1 libjniwrapper.so libstdc++.so.6)
DEPS_OUT=(pz-switch/deps/natives-out/lwjgl.o pz-switch/deps/natives-out/lwjgl_opengl.o pz-switch/deps/natives-out/lwjgl_stb.o
          pz-switch/deps/natives-out/sqlitejdbc.o pz-switch/deps/natives-out/box64.o "${X86LIBS[@]/#/pz-switch/xfer/x86libs/}")
deps_fp() { fingerprint "$PZ_TOOLCHAINS" "${DEPS_IN[@]}"; }

stage_deps() {
  local fp; fp=$(deps_fp)
  if outputs_ok "$PZROOT" "${DEPS_OUT[@]}" >/dev/null && up_to_date deps "$fp"; then echo "up to date"; return 0; fi
  unmark deps
  # setup-deps.sh skips what it already built (musl, zlib, libffi, clones); natives and box64 are rebuilt
  in_env './pz-switch/setup-deps.sh' || die "deps: setup-deps.sh failed"
  outputs_ok "$PZROOT" "${DEPS_OUT[@]}" || die "deps: setup-deps.sh finished, but outputs are missing"
  mark deps "$fp"
}

# --- game files: PZ_DEPOT/game = Linux depot (manifest of 41.78), PZ_DEPOT/betterfps = the BetterFPS workshop item ------
STEAM_APP=108600 DEPOT_ID=108603 MANIFEST_ID=8887512142279836582 BFPS_ID=3022543997
DEPOT_MANIFEST=${DEPOT_ID}_$MANIFEST_ID
DEPOT_REQUIRED=(media stdlib.lbc stdlib.lua serialize.lua projectzomboid.png zombie lwjgl_util.jar sqlite-jdbc-3.27.2.1.jar
  commons-compress-1.18.jar istack-commons-runtime.jar jassimp.jar javacord-2.0.17-shaded.jar javax.activation-api.jar
  jaxb-api.jar jaxb-runtime.jar trove-3.0.3.jar uncommons-maths-1.2.3.jar libfmodintegration64.so libjassimp64.so
  libLighting64.so libPZBullet64.so libPZBulletNoOpenGL64.so libPZClipper64.so libPZPopMan64.so libRakNet64.so
  libZNetNoSteam64.so linux64/libfmod.so.13.6 linux64/libfmodstudio.so.13.6)
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

steam_libraries() {   # Steam library folders that may be on this machine
  echo "$HOME/.local/share/Steam"
  echo "$HOME/.steam/steam"
  if is_wsl; then echo "/mnt/c/Program Files (x86)/Steam"; fi
}
ensure_betterfps() {   # BetterFPS in PZ_DEPOT/betterfps (copied from a local workshop folder if needed), and its
  local lib src            # IsoChunkMap in the jar step's mod overlay
  if [ ! -f "$PZ_DEPOT/betterfps/$BFPS_CLASS" ]; then
    while read -r lib; do
      src=$lib/steamapps/workshop/content/$STEAM_APP/$BFPS_ID
      if [ -f "$src/$BFPS_CLASS" ]; then
        mkdir -p "$PZ_DEPOT/betterfps" && cp -r "$src/." "$PZ_DEPOT/betterfps/"
        echo "BetterFPS: copied from $src"
        break
      fi
    done < <(steam_libraries)
  fi
  [ -f "$PZ_DEPOT/betterfps/$BFPS_CLASS" ] || return 1
  install -D -m 644 "$PZ_DEPOT/betterfps/$BFPS_CLASS" "$PZROOT/pz41/mods/betterfps/classes/zombie/iso/IsoChunkMap.class"
}

# --- fetch-game: the user's own copy, through DepotDownloader -------------------------------------------------------
# The password and Steam Guard code are typed into DepotDownloader's own prompts (or replaced by a QR login with the
# Steam app); pz-build only ever passes the account name. -remember-password keeps a login token in DepotDownloader's
# per-user storage (outside the repo), keyed by account name, so later runs with that name need no interaction.
DD_GAME=(-app "$STEAM_APP" -depot "$DEPOT_ID" -manifest "$MANIFEST_ID" -beta legacy41)
steam_remembered() {   # does DepotDownloader hold a login token for this account? (its account.config is deflated protobuf)
  python3 - "$1" "${XDG_DATA_HOME:-$HOME/.local/share}/IsolatedStorage" <<'EOF'
import os, sys, zlib
user, root = sys.argv[1].encode(), sys.argv[2]
for d, _, files in os.walk(root):
    if 'account.config' in files:
        data = open(os.path.join(d, 'account.config'), 'rb').read()
        try: data = zlib.decompress(data, -15)
        except zlib.error: pass
        if user in data: sys.exit(0)
sys.exit(1)
EOF
}

stage_fetch_game() {
  local user=${PZ_STEAM_USER:-} login=() again=()
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
    read -r -p "Steam account name (leave empty to log in with a QR code in the Steam app): " user < /dev/tty \
      || die "fetch-game: no terminal to ask on; pass --steam-user NAME or --qr"
  fi
  if [ "$QR" = 1 ] || [ -z "$user" ]; then login=(-qr); else login=(-username "$user"); fi
  # after a QR login, a known account name lets the second download reuse the token instead of a second QR code
  if [ -n "$user" ]; then again=(-username "$user"); else again=("${login[@]}"); fi
  echo "DepotDownloader asks for the Steam password and Steam Guard code itself; pz-build never sees them."
  mkdir -p "$PZ_DEPOT"
  DepotDownloader "${DD_GAME[@]}" "${login[@]}" -remember-password -dir "$PZ_DEPOT/game" || die "fetch-game: DepotDownloader failed"
  depot_check || die "fetch-game: the download finished, but the game files are incomplete"
  if [ "$FORCE" = 1 ] || ! ensure_betterfps; then
    DepotDownloader -app "$STEAM_APP" -pubfile "$BFPS_ID" "${again[@]}" -remember-password -dir "$PZ_DEPOT/betterfps" \
      || die "fetch-game: downloading BetterFPS failed"
    ensure_betterfps || die "fetch-game: BetterFPS was downloaded, but has no $BFPS_CLASS"
  fi
  echo "game files: $PZ_DEPOT"
  [ -n "$user" ] || echo "(next time, pass --steam-user <your account name> to reuse this login)"
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
  local lib j
  if [ -n "${B42JAR:-}" ] && [ -f "$B42JAR" ]; then export B42JAR; return 0; fi
  while read -r lib; do   # Linux and Windows layouts of the game folder
    for j in "$lib/steamapps/common/ProjectZomboid/projectzomboid/projectzomboid.jar" \
             "$lib/steamapps/common/ProjectZomboid/projectzomboid.jar"; do
      if [ -f "$j" ]; then export B42JAR=$j; return 0; fi
    done
  done < <(steam_libraries)
  unset B42JAR
}
NRO=pz41/pz41.nro
nro_ok() { [ -f "$PZROOT/$NRO" ] && [ "$(dd if="$PZROOT/$NRO" bs=1 skip=16 count=4 2>/dev/null)" = NRO0 ]; }
nro_size() { du -h "$PZROOT/$NRO" | cut -f1; }

stage_nro() {
  local log=$PZROOT/pz41/ni-a64.log fp tailpid
  if ! depot_check; then
    [ "$OFFLINE" = 1 ] && die "nro: game files missing, and --offline rules out a Steam download (use --depot)"
    die "nro: game files missing (pz-build fetch-game, or --depot)"
  fi
  ensure_betterfps || die "nro: BetterFPS (workshop item $BFPS_ID) not found; pz-build fetch-game downloads it"
  link_game
  outputs_ok "$PZROOT" "${DEPS_OUT[@]}" >/dev/null || die "nro: dependencies missing (pz-build deps)"
  dkp_ok || die "nro: devkitPro missing (pz-build devkitpro)"
  b42_detect
  fp=$(fingerprint "$PZ_TOOLCHAINS $(deps_fp) $(depot_id) ${B42JAR:-substitute} $(dkp_report | head -1)" \
       "${NRO_IN[@]}" pz41/mods)
  if nro_ok && up_to_date nro "$fp"; then echo "up to date: $NRO ($(nro_size))"; return 0; fi
  if [ "$SKIP_MEM" = 0 ]; then
    mem_check || die "nro: not enough memory for the native image (--skip-memcheck to try anyway)"
  fi
  unmark nro; rm -f "${PZROOT:?}/$NRO"
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
  nro_ok || die "nro: build-nro.sh finished, but $NRO is not an NRO"
  mark nro "$fp"
  echo "NRO: $NRO ($(nro_size))"
}

# --- sd: the folder to copy to the SD card's root ----------------------------------------------------------------------
SD_OUT=(switch/pz41.nro pz41/args.txt pz41/xfer/game.tar.00 pz41/game/natives/libPZPopMan64.so
        pz41/game/natives/libfmod.so.13 pz41/zomboid/mods/SwitchTreatment/mod.info "${X86LIBS[@]/#/pz41/game/x86libs/}")
stage_sd() {
  local o=$PZ_SD_OUT fp
  nro_ok || die "sd: no NRO yet (pz-build nro)"
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
  cp "$PZROOT/$NRO" "$o/switch/pz41.nro"
  cp "$PZROOT/pz41/args.txt" "$o/pz41/args.txt"
  cp -L "$PZROOT"/pz-switch/xfer/x86libs/* "$o/pz41/game/x86libs/"
  rm -rf "$o/pz41/zomboid/mods/SwitchTreatment"
  cp -r "$PZROOT/pz41/share/mods/SwitchTreatment" "$o/pz41/zomboid/mods/"
  outputs_ok "$o" "${SD_OUT[@]}" || die "sd: the SD folder is incomplete"
  [ -z "$(find "$o" -type l)" ] || die "sd: $o has symlinks, which a FAT32 card can't hold"
  echo "SD folder: $o ($(du -sh "$o" | cut -f1)); copy what's inside it to the root of the SD card"
}

# --- clean: everything pz-build made, except the game files, the SD folder and the Steam login ----------------------
CLEAN_PATHS=(.pz-build pz41/jar pz41/pz41.jar pz41/build-a64 pz41/natives-out pz41/ni-a64.log "$NRO" pz41/mods/betterfps
             pz41/out/e2e-sd pz-switch/deps pz-switch/xfer pz-switch/horizon/app/build41 pz-switch/horizon/app/pz41.elf
             pz-switch/horizon/app/pz41.nacp)
stage_clean() {
  local answer path d=${PZ_DKP_ROOT%/} slashes
  slashes=${d//[!\/]/}
  # only a devkitPro root this stage would have made: at least three levels deep, holding opt/devkitpro
  if [ "${#slashes}" -lt 3 ] || [ "$d" = "${HOME%/}" ] || { [ -e "$d" ] && [ ! -d "$d/opt/devkitpro" ]; }; then
    die "clean: refusing to delete PZ_DKP_ROOT=$PZ_DKP_ROOT (not a devkitPro root)"
  fi
  echo "removes: in $PZROOT: ${CLEAN_PATHS[*]}, the pz41/game link and box64's generated header links"
  echo "         devkitPro: $PZ_DKP_ROOT"
  echo "keeps:   the game files ($PZ_DEPOT), the SD folder ($PZ_SD_OUT), DepotDownloader's remembered Steam login"
  echo "         (~/.local/share/IsolatedStorage) and the Nix store (nix-collect-garbage frees what nothing uses)"
  if [ "$FORCE" = 0 ]; then
    [ "$NONINTERACTIVE" = 0 ] || die "clean: needs --force with --non-interactive"
    read -r -p "remove them? [y/N] " answer < /dev/tty || answer=
    case $answer in y | Y) ;; *) echo "nothing removed"; return 0 ;; esac
  fi
  for path in "${CLEAN_PATHS[@]}"; do rm -rf "${PZROOT:?}/$path"; done
  if [ -L "$PZROOT/pz41/game" ]; then rm -f "$PZROOT/pz41/game"; fi   # a real folder there holds game files: kept
  "$PZROOT/pz-switch/horizon/box64/link-headers.sh" --remove
  rm -rf "$PZ_DKP_ROOT"
  echo "removed"
}

ALL_STAGES=(env-check devkitpro fetch-game deps nro sd)

# --- command line ----------------------------------------------------------------------------------------------------
PZROOT=${PZROOT:-$(find_root)} || die "not inside a zomboid-switch checkout (cd into one or set PZROOT)"
export PZROOT
CONF_VARS=(PZ_DEPOT PZ_SD_OUT PZ_DKP_ROOT PZ_STEAM_USER)
if [ -f "$PZROOT/pz-build.conf" ]; then   # environment variables win over pz-build.conf
  declare -A from_env=()
  for v in "${CONF_VARS[@]}"; do if [ -n "${!v:-}" ]; then from_env[$v]=${!v}; fi; done
  # shellcheck source=/dev/null
  . "$PZROOT/pz-build.conf"
  for v in "${!from_env[@]}"; do printf -v "$v" '%s' "${from_env[$v]}"; done
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
# absolute, so links (pz41/game) and the scripts' own cd's don't change what they point at
PZ_DEPOT=$(realpath -m -- "$PZ_DEPOT"); PZ_SD_OUT=$(realpath -m -- "$PZ_SD_OUT"); PZ_DKP_ROOT=$(realpath -m -- "$PZ_DKP_ROOT")
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
    echo "($st: $(mmss "${TOOK[$st]}"))"
  done
done
if [ ${#ORDER[@]} -gt 1 ]; then
  say "done"
  for st in "${ORDER[@]}"; do printf '  %-11s %6s\n' "$st" "$(mmss "${TOOK[$st]}")"; done
  if nro_ok; then echo "NRO:        $PZROOT/$NRO ($(nro_size))"; fi
  if [ -f "$PZ_SD_OUT/switch/pz41.nro" ]; then echo "SD folder:  $PZ_SD_OUT"; fi
fi
