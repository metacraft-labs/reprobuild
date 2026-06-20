## DSL-port M9.R.10a — stdlib provisioning stub for ``m4``.
##
## Widened in M9.R.11 from the original M9.R.10a single-nix stub.
##
## ``m4`` is reached by every autotools driver: ``wayland → expat →
## autoconf → m4`` AND ``wayland → gcc → binutils → m4``. The widening
## adds the ScoopInstaller/Main scoop manifest (Windows) + the GNU
## upstream tarball (cross-platform).
##
## sha256 cross-checked against nixpkgs's ``pkgs/os-specific/linux/
## minimal-bootstrap/gnum4/default.nix`` (version 1.4.21).

import repro_project_dsl

package `m4`:
  provisioning:
    nixPackage "nixpkgs#gnum4", executablePath = "bin/m4",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    scoopApp(bucket = "main", app = "m4",
      preferredVersion = ">=1", executablePath = "bin/m4.exe",
      requiresExecutionProfileChecksum = false)
    # **executablePath = "configure"** (M9.R.11 source-tarball
    # placeholder): the resolver requires this file to exist +x
    # post-extract. The GNU m4 source tarball ships ``configure`` at
    # the root with +x. The convention layer drives the configure +
    # make + install cycle at build time to produce ``src/m4``.
    # M9.R.11.1 follow-up — narrow to ``bin/m4`` once install-glue
    # lands.
    tarball url = "https://ftp.gnu.org/gnu/m4/m4-1.4.21.tar.xz",
      sha256 = "f25c6ab51548a73a75558742fb031e0625d6485fe5f9155949d6486a2408ab66",
      archiveType = "tar.xz",
      stripComponents = 1,
      executablePath = "configure",
      packageId = "m4@1.4.21",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:m4@1.4.21:sha256:f25c6ab51548a73a75558742fb031e0625d6485fe5f9155949d6486a2408ab66"
