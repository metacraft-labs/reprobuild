## DSL-port M9.R.10a — stdlib provisioning stub for ``bison``.
##
## Widened in M9.R.11 from the original M9.R.10a single-nix stub.
##
## ``bison`` is reached by the wayland from-source chain via
## ``wayland → gcc → binutils → bison`` (binutils' parser generators
## consume bison at build time). Widened to (nix, scoop, tarball) so
## the resolver lands on Windows + non-Nix Linux.
##
## sha256 cross-checked against nixpkgs's ``pkgs/os-specific/linux/
## minimal-bootstrap/bison/default.nix`` (version 3.8.2).

import repro_project_dsl

package `bison`:
  provisioning:
    nixPackage "nixpkgs#bison", executablePath = "bin/bison",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    scoopApp(bucket = "main", app = "bison",
      preferredVersion = ">=2.4", executablePath = "bin/bison.exe",
      requiresExecutionProfileChecksum = false)
    # **executablePath = "configure"** (M9.R.11 source-tarball
    # placeholder): see ``packages/texinfo.nim`` for the rationale.
    # The bison source tarball ships ``configure`` at the root +x. The
    # convention layer drives the configure + make cycle at build time
    # to produce ``./src/bison``. M9.R.11.1 follow-up — narrow to
    # ``bin/bison`` once install-glue lands.
    tarball url = "https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz",
      sha256 = "9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "configure",
      packageId = "bison@3.8.2",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:bison@3.8.2:sha256:9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2"
