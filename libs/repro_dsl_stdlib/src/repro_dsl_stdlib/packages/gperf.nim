## DSL-port M9.R.10a — stdlib provisioning stub for ``gperf``.
##
## Widened in M9.R.11 from the original M9.R.10a single-nix stub.
## ``gperf`` (perfect hash generator) is consumed transitively by the
## wayland from-source chain through glib2 / wayland-protocols and by
## gcc's bootstrap suite.
##
## sha256 cross-checked against nixpkgs's ``pkgs/by-name/gp/gperf/
## package.nix`` (version 3.3). Scoop ``main`` does not ship a
## ``gperf`` manifest; tarball is the cross-platform fall-through.

import repro_project_dsl

package `gperf`:
  provisioning:
    nixPackage "nixpkgs#gperf", executablePath = "bin/gperf",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # **executablePath = "configure"** (M9.R.11 source-tarball
    # placeholder): see ``packages/texinfo.nim`` for the rationale.
    tarball url = "https://ftp.gnu.org/gnu/gperf/gperf-3.3.tar.gz",
      sha256 = "fd87e0aba7e43ae054837afd6cd4db03a3f2693deb3619085e6ed9d8d9604ad8",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "configure",
      packageId = "gperf@3.3",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:gperf@3.3:sha256:fd87e0aba7e43ae054837afd6cd4db03a3f2693deb3619085e6ed9d8d9604ad8"
