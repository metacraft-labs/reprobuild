{
  lib,
  stdenv,
  fetchFromGitHub,
  just,
  nim2,
  libblake3,
  xxHash,
  sqlite,
  symlinkJoin,
}:

let
  # libblake3 may or may not have split `out` / `dev` outputs depending
  # on the nixpkgs version: the upstream reprobuild flake.nix pins a
  # nixpkgs revision where `dev` (carrying include/blake3.h) and `out`
  # (lib/libblake3.so) are separate, and reprobuild's config.nims
  # expects a single tree containing both. Older / newer nixpkgs ship
  # libblake3 with a single `out` output that already contains both.
  # Use `symlinkJoin` over whichever outputs exist so the resulting
  # prefix has both `include/` and `lib/` regardless of which nixpkgs
  # revision the consumer ships.
  blake3Prefix = symlinkJoin {
    name = "libblake3-prefix";
    paths =
      if libblake3 ? dev then
        [
          libblake3.dev
          libblake3.out
        ]
      else
        [ libblake3 ];
  };

  # Fixed source-only inputs. The upstream flake.nix takes both as
  # `flake = false` inputs and re-pins them on each `nix flake update`;
  # we inline the same commit + narHash so this package definition is
  # self-contained and works without flake plumbing. Update both halves
  # whenever the upstream flake.lock bumps the corresponding entry.
  nimcryptoSrc = fetchFromGitHub {
    owner = "cheatfate";
    repo = "nimcrypto";
    rev = "69eec0375dd146aede41f920c702c531bfe89c6b";
    hash = "sha256-Z6oaGzRiai/hLdudDb/VP6euoiEKG6T4sivucfmdFyM=";
  };

  runquotaSrc = fetchFromGitHub {
    owner = "metacraft-labs";
    repo = "runquota";
    rev = "cd7bf7a718730578a214745dc82bf93cb9707462";
    hash = "sha256-LXsc9ZC1MloTk0qcwnwRGFh0MjfiYVSpg1s4nE8wVcg=";
  };
in

stdenv.mkDerivation (finalAttrs: {
  pname = "reprobuild";
  # Kept in sync with reprobuild.nimble's `version = "..."` line. Bump
  # both in lockstep; the flake.nix parses the nimble manifest at
  # eval-time, but this nixpkgs-format package keeps the version
  # literal so it stays valid when consumed via `pkgs.callPackage` in
  # a nixpkgs fork that may not see the source tree at eval-time
  # (e.g. when the `src` argument is overridden to a tarball).
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "metacraft-labs";
    repo = "reprobuild";
    # TODO: pin to a tagged release once one is cut. Until then,
    # consumers in a nixpkgs fork should override `src` to point at the
    # commit they want to ship — and re-run `nix-build` to capture the
    # new `hash` value via the hash-mismatch error message.
    rev = "main";
    # Captured from the upstream `metacraft-labs/reprobuild` `main`
    # branch tarball on 2026-06-04. Re-derive whenever `rev` moves;
    # set this to `lib.fakeHash` first and copy the `got:` line from
    # the resulting `nix-build` failure.
    hash = "sha256-mKiUXZV3N0MmsDe1Zhf/v/cGIk/Uzf+3zUUu1X8f84Y=";
  };

  strictDeps = true;
  dontConfigure = true;

  nativeBuildInputs = [
    just
    nim2
  ];

  buildInputs = [
    libblake3
    sqlite
    xxHash
  ];

  # Every env var below mirrors the corresponding `flake.nix` assignment
  # so `just build` (which delegates to scripts/build_apps.sh, which
  # delegates to nim c with config.nims) sees the same toolchain prefix
  # lookups regardless of which entry point the consumer used.
  env = {
    BLAKE3_PREFIX = "${blake3Prefix}";
    NIMCRYPTO_SRC = "${nimcryptoSrc}";
    REPROBUILD_USE_SYSTEM_HASH_LIBS = "1";
    RUNQUOTA_SRC = "${runquotaSrc}";
    SQLITE_PREFIX = "${sqlite.out}";
    XXHASH_PREFIX = "${xxHash}";
  };

  buildPhase = ''
    runHook preBuild
    just build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/lib"
    for bin in build/bin/*; do
      install -m755 "$bin" "$out/bin/$(basename "$bin")"
    done
    for lib in build/lib/*; do
      [ -e "$lib" ] || continue
      install -m755 "$lib" "$out/lib/$(basename "$lib")"
    done
    runHook postInstall
  '';

  meta = {
    description = "Reprobuild build system";
    homepage = "https://github.com/metacraft-labs/reprobuild";
    license = lib.licenses.mit;
    mainProgram = "repro";
    platforms = lib.platforms.unix;
    maintainers = [ ];
  };
})
