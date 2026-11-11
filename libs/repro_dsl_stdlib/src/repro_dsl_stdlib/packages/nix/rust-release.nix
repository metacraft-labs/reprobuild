# A rust-lang release of the Rust toolchain (``rustc``, ``cargo`` and the
# host's standard library), realized through the NIX provisioning channel
# from rust-lang's own release archive. Each ``rust-<version>/default.nix``
# beside this file names one release (its version and its archive per
# platform) and calls this function; the build is the same for every
# release, so it is written once.
#
# ## Why not ``nixpkgs#rustc``
#
# Two reasons, both measured.
#
# * The canonical nixpkgs pin (``nixpkgs_pin.CanonicalNixpkgsRev``,
#   ``addf7cf5``) carries rustc and cargo 1.91, so a recipe that declares
#   ``rustc >=1.94 <1.95`` -- a version the ``tarball`` arms pin -- is
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
# whose digest is upstream's published ``.sha256``), so
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
# ``pkgs`` is the caller's: each release's ``default.nix`` defaults it to
# the stdlib's nixpkgs pin.
#
# ``version`` is the release (``"1.94.0"``) and ``archives`` maps a Nix
# system to ``{ triple; sha256; }``, the archive rust-lang publishes for it
# and upstream's published ``.sha256`` of it.
{ pkgs, version, archives }:
let
  inherit (pkgs) lib stdenv;
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
