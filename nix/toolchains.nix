# Prebuilt toolchains the build needs, pinned by hash (checked against ARM's and GraalVM's published checksums).
# They are glibc FHS binaries: left unpatched and run inside the FHS build environment (nix/default.nix).
{ pkgs }:
let
  inherit (pkgs) fetchurl stdenvNoCC runCommand;
  unpatched = { dontConfigure = true; dontBuild = true; dontFixup = true; };

  # ARM GNU Toolchain for aarch64 GNU/Linux. Not nixpkgs' cross gcc: its wrapper adds hardening flags and glibc
  # include/library paths, which leak into the musl-gcc builds of the Java side's native code.
  armToolchain = stdenvNoCC.mkDerivation (unpatched // rec {
    pname = "arm-gnu-toolchain-aarch64-none-linux-gnu";
    version = "15.2.rel1";
    src = fetchurl {
      url = "https://developer.arm.com/-/media/Files/downloads/gnu/${version}/binrel/arm-gnu-toolchain-${version}-x86_64-aarch64-none-linux-gnu.tar.xz";
      sha256 = "9a685b335bd709d683a8c782253c37e8c36c10e6924e59e39d4769b02132eb43";
    };
    installPhase = "mkdir -p $out && cp -a . $out";
  });

  # ... under the aarch64-linux-gnu- names the build scripts (and the native image's C compiler path) use
  crossLinks = runCommand "aarch64-linux-gnu-links" { } ''
    mkdir -p $out/bin
    for f in ${armToolchain}/bin/aarch64-none-linux-gnu-*; do
      ln -s "$f" "$out/bin/aarch64-linux-gnu-''${f##*/aarch64-none-linux-gnu-}"
    done
  '';

  # GraalVM CE 25.0.2 for x64, plus the aarch64 static and SVM C libraries from the aarch64 release, so the x64
  # native-image can write an aarch64 image (README: "with the aarch64 libraries ... copied in").
  graalvmRelease = arch: sha256: fetchurl {
    url = "https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-25.0.2/graalvm-community-jdk-25.0.2_linux-${arch}_bin.tar.gz";
    inherit sha256;
  };
  graalvm = stdenvNoCC.mkDerivation (unpatched // {
    pname = "graalvm-ce-x64-with-aarch64-libs";
    version = "25.0.2";
    x64 = graalvmRelease "x64" "e0be791c8fda4d03b6b0a0cb824fef3149736170057b3a515252b44419606af0";
    aarch64 = graalvmRelease "aarch64" "b4580d9f223d0a4b3a1757e58b18ff4c1db950e67e105fc5cb741457d2384a71";
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out a64
      tar xzf $x64 -C $out --strip-components=1
      tar xzf $aarch64 -C a64 --strip-components=1 --wildcards '*/lib/static/linux-aarch64/*' '*/lib/svm/clibraries/linux-aarch64/*'
      cp -r a64/lib/static/linux-aarch64 $out/lib/static/
      cp -r a64/lib/svm/clibraries/linux-aarch64 $out/lib/svm/clibraries/
    '';
  });
in
{ inherit armToolchain crossLinks graalvm; }
