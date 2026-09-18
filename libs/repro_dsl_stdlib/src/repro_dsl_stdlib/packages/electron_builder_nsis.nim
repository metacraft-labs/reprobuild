## ``electron-builder-nsis`` — the NSIS build electron-builder fetches.
##
## **Why this and not ``nsis``.** Both provide ``makensis``, and they are not
## interchangeable. The ``nsis`` package pins NSIS 3.12 from SourceForge,
## which is upstream's own release; electron-builder's NSIS target fetches
## ``nsis-3.0.4.1`` from the ``electron-builder-binaries`` repository — a
## repackaged 3.0.4 carrying electron-builder's own plugin set and a layout
## its scripts expect. A project building an installer through
## electron-builder wants the byte-identical tree rather than an equivalent
## one, for the same reason ``wix`` exists beside ``wix3_tools``.
##
## Use ``nsis`` for anything driving NSIS directly.
##
## The ``3.0.4.1`` string is electron-builder's PACKAGING tag: a fourth
## component appended to NSIS 3.0.4. The archive is flat — ``Bin/``,
## ``Contrib/``, ``Include/`` and friends at the root — so no strip.
##
## **Identified, not merely pinned.** The SHA-512 of this artifact matches
## the constant ``nsisUtil.js`` passes to ``getBinFromUrl("nsis", "3.0.4.1",
## …)`` byte for byte, so the digest below is demonstrably the archive
## electron-builder would otherwise download for itself.
##
## Windows only. NSIS builds Windows installers, and while the archive
## carries ``linux/makensis`` and ``mac/makensis`` cross-compilers, this
## package exists to satisfy an electron-builder cache entry on the platform
## that consumes it; declaring the other two would assert coverage nothing
## here exercises.

import repro_project_dsl

const ElectronBuilderNsisTag = "3.0.4.1"

package `electron-builder-nsis`:
  provisioning:
    tarball url = "https://github.com/electron-userland/electron-builder-binaries/releases/download/nsis-" &
        ElectronBuilderNsisTag & "/nsis-" & ElectronBuilderNsisTag & ".7z",
      sha256 = "9877df902530f96357d13a7a31ae2b9df67f48b11ffc9a1700a7c961574ec5fa",
      archiveType = "7z",
      executablePath = "Bin/makensis.exe",
      packageId = "electron-builder-nsis@" & ElectronBuilderNsisTag,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:electron-builder-nsis@" &
        ElectronBuilderNsisTag &
        ":windows-x86_64:sha256:9877df902530f96357d13a7a31ae2b9df67f48b11ffc9a1700a7c961574ec5fa"
