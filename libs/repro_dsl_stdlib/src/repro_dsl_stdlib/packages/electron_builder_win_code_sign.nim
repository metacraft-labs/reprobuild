## ``electron-builder-win-code-sign`` — the signing-tool bundle
## electron-builder fetches on Windows.
##
## **Why it is needed even with no certificate.** Reading electron-builder's
## source suggests it should not be: ``winPackager.js`` takes the
## wine/``winCodeSign`` branch only on Linux, and ``signUsingSigntool``
## returns at its ``cscInfo == null`` check before resolving the vendor path.
## The build disagrees. With ``ELECTRON_BUILDER_CACHE`` pointed at an empty
## directory, a Windows MSI build downloads this archive during "updating
## asar integrity executable resource" — BEFORE the first "no signing info
## identified, signing is skipped" — and deleting only this entry from an
## otherwise warm cache makes it the single download of the next run. So it
## is consumed, not merely resolved, and a build that must not reach the
## network needs it provisioned.
##
## **It is NOT republishable, and says so.** The archive bundles Microsoft's
## ``signtool`` and its manifests. Fetching that on a developer's behalf is
## one thing; re-serving it from a shared cache other people pull from is
## another, and not a right this licence grants. ``nonRedistributable =
## true`` is what makes that hold on a machine that HAS publish credentials
## configured, rather than only on one that happens not to.
##
## The archive is flat: ``windows-10/``, ``windows-6/``, ``darwin/``,
## ``linux/``, ``openssl-ia32/`` and ``appxAssets/`` at the root. The anchor
## is the x64 ``signtool.exe``, which is the half this platform uses.
##
## Windows only. The archive carries darwin and linux payloads for
## electron-builder's cross-building paths, but this package exists to
## satisfy the Windows cache entry, and declaring platforms nothing here
## exercises would assert coverage that has not been seen to work.

import repro_project_dsl

const ElectronBuilderWinCodeSignTag = "2.6.0"

package `electron-builder-win-code-sign`:
  provisioning:
    tarball url = "https://github.com/electron-userland/electron-builder-binaries/releases/download/winCodeSign-" &
        ElectronBuilderWinCodeSignTag & "/winCodeSign-" &
        ElectronBuilderWinCodeSignTag & ".7z",
      sha256 = "cdaec7154dda7cc31f88d886e2489379a0625a737d610b5ae7f62a12f16743a4",
      archiveType = "7z",
      nonRedistributable = true,
      executablePath = "windows-10/x64/signtool.exe",
      packageId = "electron-builder-win-code-sign@" &
        ElectronBuilderWinCodeSignTag,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:electron-builder-win-code-sign@" &
        ElectronBuilderWinCodeSignTag &
        ":windows-x86_64:sha256:cdaec7154dda7cc31f88d886e2489379a0625a737d610b5ae7f62a12f16743a4"
