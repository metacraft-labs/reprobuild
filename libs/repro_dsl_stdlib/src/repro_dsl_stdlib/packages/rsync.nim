## DSL-port M9.R.10a — stdlib provisioning stub for ``rsync``.
##
## Widened in M9.R.11 from the original M9.R.10a single-nix stub.
## ``rsync`` is consumed by recipe install-stage glue (kernel make
## install, system stow) for tree mirroring.
##
## sha256 cross-checked against nixpkgs's ``pkgs/by-name/rs/rsync/
## package.nix`` (version 3.4.1). Scoop ``main`` does not ship
## ``rsync``; tarball is the cross-platform fall-through.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `rsync`:
  provisioning:
    nixPackage "nixpkgs#rsync", executablePath = "bin/rsync",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
    # **executablePath = "configure.sh"** (M9.R.11 source-tarball
    # placeholder): the rsync source tarball ships ``configure.sh`` at
    # the root with +x. See ``packages/texinfo.nim`` for the broader
    # rationale.
    tarball url = "https://download.samba.org/pub/rsync/src/rsync-3.4.1.tar.gz",
      sha256 = "2924bcb3a1ed8b551fc101f740b9f0fe0a202b115027647cf69850d65fd88c52",
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "configure.sh",
      packageId = "rsync@3.4.1",
      cpu = "any",
      os = "any",
      lockIdentity = "tarball:rsync@3.4.1:sha256:2924bcb3a1ed8b551fc101f740b9f0fe0a202b115027647cf69850d65fd88c52"
