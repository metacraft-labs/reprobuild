## Windows-System-Resources Phase F — minimal stdlib provisioning stub
## for ``tar``.
##
## GNU/BSD ``tar`` is consumed by the ``expandArchive`` typed tool (see
## ``packages/expand_archive.nim``) when extracting tar-family archives
## (``tar`` / ``tar.gz`` / ``tar.bz2`` / ``tar.xz``) on Linux / macOS.
##
## On Windows ``tar.exe`` ships with Win11 in ``%SystemRoot%\System32\``
## so no Windows provisioning channel is declared here (the typed-tool
## dispatch resolves ``tar`` from ``%PATH%`` directly via the engine's
## tool-identity resolver). The Linux/macOS happy path uses Nix.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `tar`:
  provisioning:
    nixPackage "nixpkgs#gnutar", executablePath = "bin/tar",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
