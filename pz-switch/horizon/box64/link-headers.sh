#!/bin/bash
# link-headers.sh - box64's Linux UAPI headers as symlinks into the cross compiler's own kernel headers, wherever its
# toolchain keeps them (Arch: /usr/aarch64-linux-gnu/include, Ubuntu: same, ARM GNU toolchain: <sysroot>/usr/include).
# Links inc/linux, inc/asm-generic and the inc/asm/ files named in asm-headers.txt; inc/asm/stat.h is our own.
# A header the toolchain doesn't have (asm/unistd_64.h before Linux 6.11) is skipped: box64 builds without it.
set -e
B=$(cd "$(dirname "$(readlink -f "$0")")" && pwd); H=$B/inc; CC=${CROSS_CC:-aarch64-linux-gnu-gcc}
I=$(echo | $CC -xc -E -v - 2>&1 >/dev/null | sed -n '/^#include <\.\.\.> search starts here:/,/^End of search list\./p' \
  | sed '1d;$d' | while read -r d; do [ -f "$d/linux/auxvec.h" ] && { readlink -f "$d"; break; }; done)
[ -n "$I" ] || { echo "link-headers: $CC has no linux/auxvec.h on its include path" >&2; exit 1; }
ln -sfn "$I/linux" "$H/linux"
ln -sfn "$I/asm-generic" "$H/asm-generic"
n=0
while read -r f; do
  [ -n "$f" ] || continue
  if [ -e "$I/asm/$f" ]; then ln -sfn "$I/asm/$f" "$H/asm/$f"; n=$((n+1)); else rm -f "$H/asm/$f"; fi
done < "$B/asm-headers.txt"
echo "box64 kernel headers: $I ($n asm headers)"
