#!/bin/bash
PZROOT=${PZROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
# b42-substitute.sh <out.jar> <lwjgl_util.jar> - what make-jar.sh takes from the build 42 game jar, for when there is
# none: LWJGL 3.4.1 (core, glfw, opengl, stb, jemalloc) and sqlite-jdbc 3.48.0.0 classes from Maven Central, the versions
# the Java side's natives are built against (setup-deps.sh), without sqlite-jdbc's bundled native libraries; plus build
# 41's own org/lwjgl/util from <lwjgl_util.jar>, because make-jar.sh deletes the whole org/lwjgl tree before unpacking.
# Downloads are cached in pz-switch/deps/maven and checked against the SHA-256 sums below.
set -e
[ $# = 2 ] && [ -f "$2" ] || { echo "usage: $0 <out.jar> <lwjgl_util.jar>" >&2; exit 1; }
OUT=$(readlink -f "$1"); UTIL=$(readlink -f "$2")
M=https://repo1.maven.org/maven2; C=$PZROOT/pz-switch/deps/maven
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$C" "$T/jar"
while read -r p sum; do
  [ -n "$p" ] || continue
  f=$C/$(basename "$p")
  if ! echo "$sum  $f" | sha256sum -c --status 2>/dev/null; then
    curl -fsSL "$M/$p" -o "$f.part"
    echo "$sum  $f.part" | sha256sum -c --status || { rm -f "$f.part"; echo "b42-substitute: checksum mismatch for $p" >&2; exit 1; }
    mv "$f.part" "$f"
  fi
  case $p in
    */sqlite-jdbc-*) unzip -qo "$f" 'org/sqlite/*' -x 'org/sqlite/native/*' -d "$T/jar" ;;
    *) unzip -qo "$f" 'org/lwjgl/*' -d "$T/jar" ;;
  esac
done <<'EOF'
org/lwjgl/lwjgl/3.4.1/lwjgl-3.4.1.jar                 9b1c3a3a078c2377219ecb8a2662730b3dece07c10592cf1d12f957286037b69
org/lwjgl/lwjgl-glfw/3.4.1/lwjgl-glfw-3.4.1.jar       c2d93964f0a8b2a846708c7fb1b0a095e7d79dce8ea4c543969ffef508027190
org/lwjgl/lwjgl-opengl/3.4.1/lwjgl-opengl-3.4.1.jar   a76b8fd9ff7428ae5e0f01b8f91a4e44debba87285048e965757742093418702
org/lwjgl/lwjgl-stb/3.4.1/lwjgl-stb-3.4.1.jar         3d77b0a242b8a52788934356560191db910ed242ab23c521d55f030b4e867970
org/lwjgl/lwjgl-jemalloc/3.4.1/lwjgl-jemalloc-3.4.1.jar 184866f4dcb444666e9062f690c389d69e4a62dd7fd9e2bb13ab7bdf3d03bd1e
org/xerial/sqlite-jdbc/3.48.0.0/sqlite-jdbc-3.48.0.0.jar dbe24ab138e9654c918f561299e47cb6a3baf1a946eda97871f6f3abd4eca395
EOF
unzip -qo "$UTIL" 'org/lwjgl/util/*' -d "$T/jar"
rm -f "$OUT" && (cd "$T/jar" && zip -qr "$OUT" .)
