## DSL-port M9.R.10a — stdlib provisioning stub for ``gmp``.
##
## Widened in M9.R.11 from the original M9.R.10a single-nix stub.
## ``gmp`` (GNU Multi-Precision Arithmetic Library) is a build-time
## dep of gcc; wayland → gcc → gmp.
##
## ``executablePath`` here points at the library/header artefact the
## downstream gcc build reads — there is no GMP CLI binary. The
## resolver currently treats ``executablePath`` as the file the realized
## prefix must contain; pointing at ``include/gmp.h`` lets the existence
## check pass on a header-only consumption pattern.
##
## sha256 cross-checked against nixpkgs's ``pkgs/development/libraries/
## gmp/6.x.nix`` (version 6.3.0).

import repro_project_dsl

package `gmp`:
  provisioning:
    nixPackage "nixpkgs#gmp", executablePath = "include/gmp.h",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # **executablePath = "configure"** (M9.R.11 source-tarball
    # placeholder): the gmp source tarball ships ``configure`` at the
    # root with +x. See ``packages/texinfo.nim`` for the broader
    # rationale. The convention layer drives the configure + make
    # cycle at build time to produce ``include/gmp.h`` + the static
    # libraries.
    tarball url = "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz",
      sha256 = "ac28211a7cfb609bae2e2c8d6058d66c8fe96434f740cf6fe2e47b000d1c20cb",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "configure",
      packageId = "gmp@6.3.0",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:gmp@6.3.0:sha256:ac28211a7cfb609bae2e2c8d6058d66c8fe96434f740cf6fe2e47b000d1c20cb"
