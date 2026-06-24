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

package `tar`:
  provisioning:
    nixPackage "nixpkgs#gnutar", executablePath = "bin/tar",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
