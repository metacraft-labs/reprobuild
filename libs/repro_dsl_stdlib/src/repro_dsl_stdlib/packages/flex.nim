## DSL-port M9.R.10a — stdlib provisioning stub for ``flex``.
##
## Widened in M9.R.11 from the original M9.R.10a single-nix stub.
##
## ``flex`` is reached by the wayland from-source chain via
## ``wayland → gcc → binutils → flex`` (binutils' lexer regenerates
## from flex sources at build time). Scoop ``main`` does NOT ship a
## ``flex`` manifest; the tarball channel covers Windows via MSYS2's
## flex toolchain.
##
## sha256 is the upstream-published value at
## ``github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz``,
## cross-checked against multiple downstream package indexes.

import repro_project_dsl

package `flex`:
  provisioning:
    nixPackage "nixpkgs#flex", executablePath = "bin/flex",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # **executablePath = "configure"** (M9.R.11 source-tarball
    # placeholder): see ``packages/texinfo.nim`` for the rationale.
    tarball url = "https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz",
      sha256 = "e87aae032bf07c26f85ac0ed3250998c37621d95f8bd748b31f15b33c45ee995",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "configure",
      packageId = "flex@2.6.4",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:flex@2.6.4:sha256:e87aae032bf07c26f85ac0ed3250998c37621d95f8bd748b31f15b33c45ee995"
