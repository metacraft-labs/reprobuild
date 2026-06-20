## DSL-port M9.R.10a — stdlib provisioning stub for ``mpfr``.
##
## Widened in M9.R.11 from the original M9.R.10a single-nix stub.
## ``mpfr`` is a build-time dep of gcc; wayland → gcc → mpfr.
##
## ``executablePath`` points at the header artefact (same pattern as
## ``gmp.nim``) because mpfr is library-only — no CLI surface.
##
## sha256 cross-checked against nixpkgs's ``pkgs/by-name/mp/mpfr/
## package.nix`` (version 4.2.2).

import repro_project_dsl

package `mpfr`:
  provisioning:
    nixPackage "nixpkgs#mpfr", executablePath = "include/mpfr.h",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # **executablePath = "configure"** (M9.R.11 source-tarball
    # placeholder): see ``packages/texinfo.nim`` for the rationale.
    tarball url = "https://www.mpfr.org/mpfr-4.2.2/mpfr-4.2.2.tar.xz",
      sha256 = "b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "configure",
      packageId = "mpfr@4.2.2",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:mpfr@4.2.2:sha256:b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01"
