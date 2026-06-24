## Windows-System-Resources Phase F — minimal stdlib provisioning stub
## for ``unzip``.
##
## ``unzip`` is the InfoZIP CLI; consumed by the ``expandArchive`` typed
## tool (see ``packages/expand_archive.nim``) when extracting ``zip``
## archives on Linux / macOS. Windows uses ``Expand-Archive`` PowerShell
## cmdlet directly so no Windows provisioning channel is needed (Scoop
## does not ship a first-party ``unzip`` manifest either).
##
## Per the spec §2.2 fallback note, ``python3 -m zipfile`` is an
## acceptable substitute if ``unzip`` is unavailable; the typed-tool
## dispatch lands ``unzip`` first and recipes that need the fallback can
## override at the call site (the typed wrapper does not currently
## auto-degrade — Phase F lands the happy-path provisioning + dispatch).

import repro_project_dsl

package `unzip`:
  provisioning:
    nixPackage "nixpkgs#unzip", executablePath = "bin/unzip",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
