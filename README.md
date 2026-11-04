# Project Zomboid build 41 for Nintendo Switch

[Discord](https://discord.gg/dv28MgtaNn)

A native homebrew port of Project Zomboid 41.78. The game's Java code is compiled ahead of time with GraalVM
native-image, a small Linux layer on libnx runs it, box64 runs the game's x86-64 libraries, and BetterFPS (PotatoePC)
keeps the loaded map small enough for the console's memory.

No game files are in this repository. You need your own copy of Project Zomboid.

![New game](docs/new-game.jpg)
![Character](docs/character.jpg)
![Survival guide](docs/guide.jpg)
![In game](docs/ingame.jpg)

## Support

If you'd like to support development:

- USDT (TRC20): `TCJ4HMJF3JHQG66khYTj98Em7v74j3cry9`
- Bitcoin: `bc1qaeypp2m5h74alrmhyu4zvzf3yyf58k6mcw7868`
- Monero: `45npN9u6zMFE7xMxfszfWBX2jdDdtZaogcGex4s5D7QDNsGPtbXjtjtXpbx9cnxLaKXC1KzGgckN2fMwrYrw5yqPTG2KiPj`

## Building

Linux x86-64 host with:

- devkitPro with `switch-dev`, `switch-mesa`, `switch-libdrm_nouveau`
- `aarch64-linux-gnu-gcc`, `cmake`, `python3`, `imagemagick`, `git`, `curl`, `unzip`
- GraalVM CE 25.0.2 for linux-x64 in `~/graalvm-25/x64` (or set `GRAALVM`), with the aarch64 libraries from the
  linux-aarch64 download copied in:
  `lib/static/linux-aarch64` and `lib/svm/clibraries/linux-aarch64`
- about 24 GB of RAM for native-image

Game files (DepotDownloader, Linux depot of build 41.78, and the BetterFPS workshop item):

```
DepotDownloader -app 108600 -depot 108603 -manifest 8887512142279836582 -beta legacy41 -username YOU -dir pz41/game
DepotDownloader -app 108600 -pubfile 3022543997 -username YOU -dir pz41/mods/betterfps
mkdir -p pz41/mods/betterfps/classes/zombie/iso
cp pz41/mods/betterfps/mods/BetterFPS/media/PotatoePC/zombie/iso/IsoChunkMap.class pz41/mods/betterfps/classes/zombie/iso/
```

The build also takes LWJGL 3.4.1 and sqlite-jdbc classes from the current (build 42) `projectzomboid.jar` from Steam;
set `B42JAR` if it is not in the default Steam folder.

Then:

```
pz-switch/setup-deps.sh
pz41/build.sh
```

This gives `pz41/pz41.nro`.

## Building on NixOS (WSL or native)

On NixOS, `pz-build` does all of the above, and builds the SD card folder too. It needs no flakes, no root and no
changes to your system configuration. The toolchains are pinned by hash, devkitPro goes into your home directory
(signatures checked), and everything runs in an FHS environment (bubblewrap):

```
git clone https://github.com/etonedemid/zomboid-switch && cd zomboid-switch
nix-shell                 # or, with flakes: nix develop
pz-build all
```

`all` runs these stages, one after another. Each skips itself when its outputs are up to date, and `--force` redoes
it. `pz-build help` lists every option.

| stage        | what it does                                                                                          |
|--------------|-------------------------------------------------------------------------------------------------------|
| `env-check`  | toolchain versions, devkitPro, the game and SD folders, and memory                                     |
| `devkitpro`  | devkitPro's Switch packages into `~/.local/share/pz-switch/dkp-root`, through pacman, without root     |
| `fetch-game` | your copy of 41.78 for Linux and BetterFPS, with your Steam login (skipped if they're already there)   |
| `deps`       | `pz-switch/setup-deps.sh`                                                                              |
| `nro`        | `pz41/pz41.nro`: jar, reflection config, native image, link. A build 42 jar is optional (see below)   |
| `sd`         | the SD card folder, ready to copy to the card's root                                                   |

**Steam login.** `fetch-game` asks for your Steam account name. DepotDownloader then asks for your password and Steam
Guard code itself, so pz-build never sees them. `--qr` logs in with a QR code in the Steam app instead. The login is
remembered by account name, so later runs with `--steam-user <name>` don't ask again; that includes a QR login. If you
already have the Linux 41.78 depot, put it in the game files folder (below) as `game/`, or point `--depot` at its parent
folder. BetterFPS is also picked up from a local Steam workshop folder, including Windows Steam's when running in WSL.

**Folders.** Under WSL, the game files go to `%USERPROFILE%\pz4-depot` and the SD folder to `%USERPROFILE%\pz4-sd`, so
Windows can copy it to the card. On native NixOS they go to `~/pz4-depot` and `~/pz4-sd`. Change them with `--depot` and
`--sd-out`, with `PZ_DEPOT`/`PZ_SD_OUT` in the environment, or with `PZ_DEPOT=...` and `PZ_SD_OUT=...` in a
`pz-build.conf` at the repo root. Options win over the environment, which wins over `pz-build.conf`.

**Memory.** The native image needs at least 12 GiB of RAM plus swap, and 8 GiB of RAM is recommended (build 41 peaks at
about 7 GB). `pz-build` checks before it starts. WSL gives Linux only half of the host's RAM by default. If that's too
little, pz-build prints the `%USERPROFILE%\.wslconfig` lines for your PC (its RAM minus about 3 GB for Windows, plus
swap). Then run `wsl --shutdown`.

**Pinned nixpkgs.** `shell.nix` and the flake both use the same nixpkgs revision (`nix/nixpkgs.nix`, `flake.lock`), so
they build the same thing whatever channel your system follows.

**Build 42 jar.** The build needs LWJGL 3.4.1 and sqlite-jdbc classes. Without a build 42 install, `make-jar.sh` takes
the same versions from Maven Central (pinned by hash).

**Tests.** `nix-shell --run nix/tests/e2e.sh` runs the whole build from your game files, never logging into Steam. It
takes 15-60 minutes and writes its SD folder to `pz41/out/e2e-sd`. It then checks the NRO, the prelinked Java side and
the SD folder. `PZ_STEAM_USER=you nix-shell --run nix/tests/steam.sh` tests the Steam download into a temporary folder
(6.8 GB). It runs only once DepotDownloader remembers your login; otherwise it reports SKIPPED.

**Removing it all.** `pz-build clean` deletes what the build made: the build outputs, `pz-switch/deps`, the devkitPro
folder and the stage state. It keeps the game files, the SD folder and the Steam login. To remove those too:

```
rm -rf <game files folder> <SD folder>          # under WSL, e.g. /mnt/c/Users/<you>/pz4-depot and .../pz4-sd
rm -rf ~/.local/share/IsolatedStorage           # DepotDownloader's remembered Steam login (.NET isolated storage)
nix-collect-garbage                             # the toolchains and GraalVM in the Nix store, once nothing uses them
```

## Installing

SD card layout:

```
switch/pz41.nro
pz41/args.txt                 from pz41/args.txt
pz41/game/x86libs/            from pz-switch/xfer/x86libs (fetched by setup-deps.sh)
pz41/zomboid/options.ini      optional: low texture settings, recommended
```

plus the game data, built from the game folder:

```
python3 pz41/share/setup-sd.py pz41/game/projectzomboid out
```

and copy `out/pz41` onto the card. Start the NRO in full-RAM mode (hold R while starting a game). The first load
into the world takes 3-4 minutes. Controller and touch screen both work.

Recommended `options.ini` settings: `texture2x=false`, `maxVehicleTextureSize=1`, `simpleClothingTextures=2`,
`simpleWeaponTextures=true`.

## Credits

[zomdroid](https://github.com/liamelui/zomdroid) for the box64 JNI bridge design and its box64 fork,
[BetterFPS](https://steamcommunity.com/sharedfiles/filedetails/?id=3022543997), LWJGL, musl, GraalVM, devkitPro.
Project Zomboid is by The Indie Stone.
