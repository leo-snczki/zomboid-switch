#!/usr/bin/env python3
"""Checks what a pz-build run produced (seam 1 of the NixOS build). Run inside the build environment:

    pz-build run python3 nix/tests/check_outputs.py --nro pz41/pz41.nro --jobj pz41/build-a64/j.o

Expected values come from the known-good build (see issue #1), not from the build scripts.
    pz-build run python3 nix/tests/check_outputs.py --nro pz41/pz41.nro --jobj pz41/build-a64/j.o --sd <SD folder>
"""
import argparse, filecmp, os, struct, subprocess, sys

NACP_TITLE, NACP_AUTHOR = 'Project Zomboid 41', 'etonedemid'
# everything the prelinked Java side may still need from the Horizon side
JOBJ_UNDEFINED = {'_DYNAMIC', '__lx_clone', 'lxh_dlsym', 'lx_jit_reserve', '__lx_syscall', '__lx_unmapself',
                  '__start_lx_init_array', '__stop_lx_init_array', '__start_lx_fini_array', '__stop_lx_fini_array'}

# the SD folder (README "Installing", plus the game data setup-sd.py packs)
SD_X86LIBS = {'_ld-linux-x86-64.so.2', '_libc.so.6', 'libgcc_s.so.1', 'libjniwrapper.so', 'libstdc++.so.6'}
SD_NATIVES = {'libLighting64.so', 'libPZBullet64.so', 'libPZBulletNoOpenGL64.so', 'libPZClipper64.so', 'libPZPopMan64.so',
              'libRakNet64.so', 'libZNetNoSteam64.so', 'libfmodintegration64.so', 'libjassimp64.so',
              'libfmod.so', 'libfmod.so.13', 'libfmodstudio.so', 'libfmodstudio.so.13'}
SD_PART = 3900 * 1024 * 1024   # FAT32-safe game data part

failures = []


def check(ok, what):
    print(('ok    ' if ok else 'FAIL  ') + what)
    if not ok: failures.append(what)


def check_nro(path):
    data = open(path, 'rb').read()
    check(data[0x10:0x14] == b'NRO0', '%s: NRO0 magic' % path)
    if data[0x10:0x14] != b'NRO0': return
    size = struct.unpack_from('<I', data, 0x18)[0]
    check(data[size:size + 4] == b'ASET', '%s: asset section after the %d-byte image' % (path, size))
    if data[size:size + 4] != b'ASET': return
    nacp_off, nacp_size = struct.unpack_from('<QQ', data, size + 0x18)
    nacp = data[size + nacp_off:size + nacp_off + nacp_size]
    title = nacp[0:0x200].split(b'\0')[0].decode()
    author = nacp[0x200:0x300].split(b'\0')[0].decode()
    check(title == NACP_TITLE, 'NACP title %r' % title)
    check(author == NACP_AUTHOR, 'NACP author %r' % author)


def check_jobj(path):
    out = subprocess.run(['aarch64-linux-gnu-nm', '-u', path], capture_output=True, text=True, check=True).stdout
    undef = {l.split()[-1] for l in out.splitlines() if l.strip()}
    check(undef == JOBJ_UNDEFINED, '%s: undefined symbols are exactly the Horizon-provided set' % path)
    if undef != JOBJ_UNDEFINED:
        print('      missing: %s\n      extra: %s' % (sorted(JOBJ_UNDEFINED - undef), sorted(undef - JOBJ_UNDEFINED)))


def files_in(d):
    return set(os.listdir(d)) if os.path.isdir(d) else set()


def check_sd(sd, nro):
    j = lambda *p: os.path.join(sd, *p)
    links = [os.path.join(r, n) for r, ds, fs in os.walk(sd) for n in ds + fs if os.path.islink(os.path.join(r, n))]
    check(not links, 'SD folder has no symlinks (FAT32)' + (': %s' % links[:3] if links else ''))
    check(os.path.isfile(j('switch', 'pz41.nro')) and filecmp.cmp(j('switch', 'pz41.nro'), nro, shallow=False),
          'switch/pz41.nro is the NRO that was built')
    check(os.path.isfile(j('pz41', 'args.txt')) and filecmp.cmp(j('pz41', 'args.txt'), 'pz41/args.txt', shallow=False),
          'pz41/args.txt')
    x86 = files_in(j('pz41', 'game', 'x86libs'))
    check(x86 == SD_X86LIBS, 'pz41/game/x86libs: the 5 x86 libraries (%d found)' % len(x86))
    nat = files_in(j('pz41', 'game', 'natives'))
    check(nat == SD_NATIVES, 'pz41/game/natives: the 13 game natives (%d found)' % len(nat))
    for d, names in (('x86libs', x86), ('natives', nat)):
        check(all(os.path.getsize(j('pz41', 'game', d, n)) > 0 for n in names), 'pz41/game/%s files are not empty' % d)
    parts = sorted(n for n in files_in(j('pz41', 'xfer')) if n.startswith('game.tar.'))
    sizes = [os.path.getsize(j('pz41', 'xfer', n)) for n in parts]
    check(parts == ['game.tar.%02d' % i for i in range(len(parts))] and len(parts) >= 2,
          'pz41/xfer: game data parts %s' % ', '.join(parts))
    check(sizes and all(s == SD_PART for s in sizes[:-1]) and 0 < sizes[-1] <= SD_PART,
          'every game data part but the last is exactly 3900 MiB')
    info = j('pz41', 'zomboid', 'mods', 'SwitchTreatment', 'mod.info')
    check(os.path.isfile(info) and 'id=SwitchTreatment' in open(info).read(), 'pz41/zomboid/mods/SwitchTreatment')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--nro', required=True)
    ap.add_argument('--jobj', required=True)
    ap.add_argument('--sd')
    a = ap.parse_args()
    check_nro(a.nro)
    check_jobj(a.jobj)
    if a.sd: check_sd(a.sd, a.nro)
    print('\n%s: %d failure(s)' % ('FAILED' if failures else 'PASSED', len(failures)))
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
