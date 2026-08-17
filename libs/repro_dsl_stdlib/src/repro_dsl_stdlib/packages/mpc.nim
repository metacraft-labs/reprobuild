## DSL-port M9.R.10a — stdlib provisioning stub for ``mpc``.
##
## Widened in M9.R.11 from the original M9.R.10a single-nix stub.
## ``mpc`` (multiprecision complex) is a build-time dep of gcc;
## wayland → gcc → mpc.
##
## ``executablePath`` points at the header artefact (same pattern as
## ``gmp.nim`` / ``mpfr.nim``) because mpc is library-only.
##
## sha256 cross-checked against nixpkgs's ``pkgs/by-name/li/libmpc/
## package.nix`` (version 1.4.0).

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `mpc`:
  provisioning:
    nixPackage "nixpkgs#libmpc", executablePath = "include/mpc.h",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # **executablePath = "configure"** (M9.R.11 source-tarball
    # placeholder): see ``packages/texinfo.nim`` for the rationale.
    tarball url = "https://ftp.gnu.org/gnu/mpc/mpc-1.4.0.tar.gz",
      sha256 = "3210b3a546b1cb00c296ca360891d7740ee6ff06deb02a27a35b20cd3c0bb1a5",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "configure",
      packageId = "mpc@1.4.0",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:mpc@1.4.0:sha256:3210b3a546b1cb00c296ca360891d7740ee6ff06deb02a27a35b20cd3c0bb1a5"
