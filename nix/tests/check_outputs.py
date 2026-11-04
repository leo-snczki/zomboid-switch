#!/usr/bin/env python3
"""Checks what a pz-build run produced (seam 1 of the NixOS build). Run inside the build environment:

    pz-build run python3 nix/tests/check_outputs.py --nro pz41/pz41.nro --jobj pz41/build-a64/j.o

Expected values come from the known-good build (see issue #1), not from the build scripts.
"""
import argparse, struct, subprocess, sys

NACP_TITLE, NACP_AUTHOR = 'Project Zomboid 41', 'etonedemid'
# everything the prelinked Java side may still need from the Horizon side
JOBJ_UNDEFINED = {'_DYNAMIC', '__lx_clone', 'lxh_dlsym', 'lx_jit_reserve', '__lx_syscall', '__lx_unmapself',
                  '__start_lx_init_array', '__stop_lx_init_array', '__start_lx_fini_array', '__stop_lx_fini_array'}

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--nro', required=True)
    ap.add_argument('--jobj', required=True)
    a = ap.parse_args()
    check_nro(a.nro)
    check_jobj(a.jobj)
    print('\n%s: %d failure(s)' % ('FAILED' if failures else 'PASSED', len(failures)))
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
