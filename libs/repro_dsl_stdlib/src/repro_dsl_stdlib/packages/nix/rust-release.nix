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
# ## The linker: ``cc``'s own, not the bundled ``rust-lld``
#
# Since Rust 1.90 a rust-lang release links the x86_64-unknown-linux-gnu
# target through ``cc -B <sysroot>/lib/rustlib/x86_64-unknown-linux-gnu/bin/gcc-ld
# -fuse-ld=lld``, so ``cc`` runs the bundled ``rust-lld`` instead of its own
# ``ld``. Under Nix that skips the bintools wrapper, which is what adds a
# RUNPATH entry for every ``-L`` directory a library was linked from; a
# binary that links a store library (``openssl-sys``'s ``libssl.so.3``)
# then cannot find it at run time. nixpkgs' own rustc is built without the
# self-contained linker, so it links through the wrapper. Measured
# 2026-11-18 against rust-lang's 1.94.0: the binary's ``.comment`` reads
# ``Linker: LLD 21.1.8``, and ``-C linker-features=-lld`` removes exactly
# the ``-B`` and ``-fuse-ld=lld`` arguments from the link line.
#
# So on Linux ``rustc`` is a small wrapper that passes
# ``-C linker-features=-lld`` when the target is
# x86_64-unknown-linux-gnu, the one target where that flag is stable. On
# any other target rustc refuses it without ``-Z unstable-options``, so it
# is not passed there. That leaves a gap: from an x86_64 host, rustc also
# uses the self-contained rust-lld for some other gnu targets (measured:
# i686- and aarch64-unknown-linux-gnu), and there is no stable opt-out for
# them. The target is the last ``--target``/``--target=`` (also inside an
# ``@argfile``, with a trailing CR stripped as rustc strips it), else the
# host. An ``@argfile`` the wrapper cannot read as a regular file (a pipe,
# which reading would drain before rustc sees it, or the unstable
# ``@shell:`` form) may name any target, so then no flag is passed: rustc
# links as upstream does rather than refusing the flag on a cross target.
# The real binary is ``bin/.rustc-wrapped``; rustc finds its sysroot from
# its own executable, which stays in ``bin/``. The ``tarball`` arm is
# unchanged.
#
# ``rustdoc`` is not wrapped: it compiles and links doctests by running
# the sysroot's ``bin/rustc``, which is this wrapper (measured with
# 1.94.0 under ``strace``, editions 2015 and 2024).
#
# Cargo does not see the flag (``rustc -vV`` is unchanged), so a target
# directory built before this change keeps its rust-lld-linked binaries
# until ``cargo clean``.
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
  # The ``rustc`` wrapper described above; ``@shell@``, ``@host@`` and
  # ``@real@`` are substituted in ``postFixup``.
  linkerWrapper = pkgs.writeText "rust-linker-wrapper.sh" ''
    #!@shell@
    # Generated by reprobuild's rust-release.nix: link the
    # x86_64-unknown-linux-gnu target through cc's own linker (the Nix
    # bintools wrapper, which writes RUNPATH), not the bundled rust-lld.
    target=@host@
    expect_target=
    unknown_target=
    scan() {
      for a in "$@"; do
        if [ -n "$expect_target" ]; then
          target=$a
          expect_target=
          continue
        fi
        case $a in
          --target) expect_target=1 ;;
          --target=*) target=''${a#--target=} ;;
        esac
      done
    }
    scan "$@"
    for a in "$@"; do
      case $a in
        @*)
          # A regular file only: reading a pipe here would empty it before
          # rustc reads it (``rustc @/dev/stdin``). Anything else may name
          # any target, so the flag is withheld.
          if [ -f "''${a#@}" ] && [ -r "''${a#@}" ]; then
            lines=()
            while IFS= read -r line || [ -n "$line" ]; do
              lines+=("''${line%$'\r'}")
            done < "''${a#@}"
            scan "''${lines[@]}"
          else
            unknown_target=1
          fi
          ;;
      esac
    done
    if [ -z "$unknown_target" ] && [ "$target" = x86_64-unknown-linux-gnu ]; then
      exec "@real@" -C linker-features=-lld "$@"
    fi
    exec "@real@" "$@"
  '';
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
    mv "$out/bin/rustc" "$out/bin/.rustc-wrapped"
    substitute ${linkerWrapper} "$out/bin/rustc" \
      --subst-var-by shell "${pkgs.runtimeShell}" \
      --subst-var-by host "${archive.triple}" \
      --subst-var-by real "$out/bin/.rustc-wrapped"
    chmod +x "$out/bin/rustc"
  '';
}
