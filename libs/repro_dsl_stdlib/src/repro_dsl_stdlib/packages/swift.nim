## M4 (Realize-Closure-And-Catalog-Expansion spec) note: the
## ``installMethod`` flipped from ``extract`` to
## ``installer-nsis-bundle`` so the home archive realizer dispatches
## through the M4 NSIS-unwrap + per-MSI dark extractor. The Scoop
## manifest's ``pre_install`` block carries Expand-DarkArchive +
## Expand-MsiArchive — i.e. swift.org's Windows toolchain ships as a
## Burn/NSIS bundle whose payload is multiple MSIs (swift-runtime.msi,
## swift-compiler.msi, swift-sdk-windows.msi, …) plus a layout reshuffle
## (the Scoop pre_install's ``Move-Item`` dance reorganizes the
## ``LocalApp\Programs\Swift\Runtimes\`` + ``Toolchains\`` subtrees up
## to the prefix root).
##
## **Honest scope per M71 + M51**: swift's full end-to-end ALSO depends
## on Visual Studio Build Tools env-activation (rtl.msi expects
## ``VCToolsInstallDir``-tagged headers + libs). M4 makes the swift
## PREFIX realize cleanly (bin/swift.exe + bin/swiftc.exe at the
## documented relpath); end-to-end fixture PASS continues to be gated
## on the unrelated VS Build Tools env-activation issue (M83 territory
## per the M51 closing table). **swift's M11 re-graduation row flips to
## CLEAN-IN-PREFIX after M4** — full GRADUATE-PASS waits for the VS
## Build Tools follow-up.
##
## **Re-harvest preservation**: the per-tool flatten dance encoded in
## the manifest's ``pre_install`` block (Move-Item / Remove-Item /
## Expand-{Dark,Msi}Archive) lands in the realization's
## ``preInstall`` array via the M4 harvester. Lines that
## escape the allowlist (the ``$xml.BurnManifest`` XML traversal,
## the variable-substituted Move-Item paths with $ver expansion) land
## in ``preInstallUnrecognized`` and emit ``WPreInstallUnrecognized``
## warnings at apply time — honest about the gap.

## Archive realizations harvested by tools/catalog-harvester. GM4b: the
## harvester emits ``tarball`` statements, which live in the hand-maintained
## ``package`` block below; merge a re-harvest into it.
## Harvested from bucket: ScoopInstaller/Main
## Versions (newest-first): 6.3.1
## M4 amendment: install method = installer-nsis-bundle (was extract).

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

package swift:
  provisioning:
    tarball url = "https://download.swift.org/swift-6.3.1-release/windows10/swift-6.3.1-RELEASE/swift-6.3.1-RELEASE-windows10.exe",
      sha256 = "e5a0e6b5bd8f8f3045b1d2420c06eceb6b7918d800bec3733ce4d657e7170f51",
      archiveType = "installer-nsis",
      executablePath = "Runtimes/usr/bin/swift.exe",
      extraExecutable = "Runtimes/usr/bin/swiftc.exe",
      extraExecutable = "Toolchains/usr/bin/swift.exe",
      extraExecutable = "Toolchains/usr/bin/swiftc.exe",
      version = "6.3.1",
      packageId = "swift@6.3.1",
      installMethod = "installer-nsis-bundle",
      env = "SDKROOT=${prefix}\\Platforms\\Windows.platform\\Developer\\SDKs\\Windows.sdk",
      cpu = "x86_64",
      os = "windows"
    tarball url = "https://download.swift.org/swift-6.3.1-release/windows10-arm64/swift-6.3.1-RELEASE/swift-6.3.1-RELEASE-windows10-arm64.exe",
      sha256 = "9e99e2dde52df516e7ea1ff151d9cb296629d5274e7820f71635ae78a86975fd",
      archiveType = "installer-nsis",
      executablePath = "Runtimes/usr/bin/swift.exe",
      extraExecutable = "Runtimes/usr/bin/swiftc.exe",
      extraExecutable = "Toolchains/usr/bin/swift.exe",
      extraExecutable = "Toolchains/usr/bin/swiftc.exe",
      version = "6.3.1",
      packageId = "swift@6.3.1",
      installMethod = "installer-nsis-bundle",
      env = "SDKROOT=${prefix}\\Platforms\\Windows.platform\\Developer\\SDKs\\Windows.sdk",
      cpu = "aarch64",
      os = "windows"
