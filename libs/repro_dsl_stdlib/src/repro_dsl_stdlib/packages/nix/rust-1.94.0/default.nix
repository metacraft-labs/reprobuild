# The Rust 1.94.0 toolchain (``rustc``, ``cargo`` and the host's standard
# library), realized through the NIX provisioning channel from rust-lang's
# own release archive.
#
# ## Why not ``nixpkgs#rustc``
#
# Two reasons, both measured.
#
# * The canonical nixpkgs pin (``nixpkgs_pin.CanonicalNixpkgsRev``,
#   ``addf7cf5``) carries rustc and cargo 1.91, so a recipe that declares
#   ``rustc >=1.94 <1.95`` -- the version the ``tarball`` arms pin -- is
#   refused by the range check.
# * Even a nixpkgs rustc of the right version cannot use rust-lang's
#   prebuilt standard library for another target (the ``rust-std``
#   package, which a cross build merges into the sysroot): nixpkgs builds
#   rustc from source, and a crate compiled by one rustc build is refused
#   by another (``error[E0514]: found crate `core` compiled by an
#   incompatible version of rustc``). Only rust-lang's own compiler loads
#   rust-lang's ``rust-std``.
#
# ## Why this adds no dependency
#
# The URLs and digests are those of the ``tarball`` arms in
# ``packages/rustc.nim`` and ``packages/cargo.nim`` (plus aarch64 Linux,
# whose digest is upstream's published ``.sha256``, read 2026-11-01), so
# this channel realizes THE SAME COMPILER the ``tarball`` channel does,
# through nix's fetcher. It exists because the ``tarball`` channel's
# generic-Linux binaries name the FHS loader
# ``/lib64/ld-linux-x86-64.so.2``, which a NixOS host without nix-ld does
# not have (``TarballHostLoaderMissing``). Here every ELF executable is
# pointed at the loader of the pinned nixpkgs' glibc, and every dynamic
# ELF object gains the pinned glibc / libgcc_s / zlib directories on its
# RUNPATH. The existing ``$ORIGIN/../lib`` entries are kept, so rustc still
# finds ``librustc_driver`` beside itself. The patch is a function of the
# nixpkgs pin, which is part of this realization's store path.
#
# ``install.sh`` is upstream's own component merge (the one
# ``mergeRustInstallerComponents`` replays for the ``tarball`` arms); only
# the three components the ``rustc`` and ``cargo`` packages surface are
# installed.
#
# ``pkgs`` defaults to the stdlib's nixpkgs pin, which is what the engine
# evaluates (``nix build --file`` calls the function with its defaults). It
# is a parameter only so that a check can evaluate THIS expression for
# another platform, for example the same pin with ``crossSystem`` aarch64
# (decision 35: a realisation and build on aarch64-linux).
{ pkgs ? import ../nixpkgs.nix }:
let
  inherit (pkgs) lib stdenv;
  version = "1.94.0";
  archives = {
    x86_64-linux = {
      triple = "x86_64-unknown-linux-gnu";
      sha256 = "e8fa4185f3ef6ae32725ff638b1ecdbff28f5d651dc0b3111e2539350d03b15a";
    };
    aarch64-linux = {
      triple = "aarch64-unknown-linux-gnu";
      sha256 = "c6fd6d1c925ed986df3b2c0b89bbc90ce15afb62e4d522a054e7d50c856b3c1a";
    };
    aarch64-darwin = {
      triple = "aarch64-apple-darwin";
      sha256 = "9e55893e014e6aa76924b4cc244a289ad56de4d89d3721fbd5c7f497b31ea33c";
    };
    x86_64-darwin = {
      triple = "x86_64-apple-darwin";
      sha256 = "63fe27931d4b8da0b0069f13d4d2c04792203a5cabb4df17ff15495aaaab0ef7";
    };
  };
  system = stdenv.hostPlatform.system;
  archive = archives.${system} or (throw
    "reprobuild-rust-${version}: rust-lang publishes no archive pinned here for ${system}");
  runtimeLibraryPath = lib.makeLibraryPath [ stdenv.cc.libc stdenv.cc.cc.lib pkgs.zlib ];
in
stdenv.mkDerivation {
  pname = "reprobuild-rust";
  inherit version;
  src = pkgs.fetchurl {
    url = "https://static.rust-lang.org/dist/rust-${version}-${archive.triple}.tar.xz";
    inherit (archive) sha256;
  };
  nativeBuildInputs = lib.optional stdenv.hostPlatform.isLinux pkgs.patchelf;
  dontConfigure = true;
  dontBuild = true;
  # The binaries are rust-lang's; stripping or shrinking them would make this
  # a different compiler from the one the ``tarball`` arm realizes.
  dontStrip = true;
  dontPatchELF = true;
  installPhase = ''
    runHook preInstall
    patchShebangs install.sh
    ./install.sh --prefix="$out" --disable-ldconfig \
      --components=rustc,cargo,rust-std-${archive.triple}
    rm -rf "$out/share/doc"
    runHook postInstall
  '';
  postFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
    interpreter="$(cat "$NIX_CC/nix-support/dynamic-linker")"
    find "$out" -type f | while read -r f; do
      isELF "$f" || continue
      # Static archives and objects carry no dynamic section to patch.
      patchelf --print-needed "$f" >/dev/null 2>&1 || continue
      if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
        patchelf --set-interpreter "$interpreter" "$f"
      fi
      patchelf --add-rpath "${runtimeLibraryPath}" "$f"
    done
  '';
}
