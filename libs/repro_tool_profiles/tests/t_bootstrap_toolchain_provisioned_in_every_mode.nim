## The provider-compile toolchain does not wait for a provisioning mode, on
## any host.
##
## A recipe's ``defaultToolProvisioning`` is readable only after its provider
## is compiled, so the compiler for that compile cannot come from the recipe's
## mode. ``ensureBootstrapToolchainEnv`` used to fire only under ``tarball``
## and ``from-source``, which in practice meant only when
## ``REPRO_TOOL_PROVISIONING`` said so in advance. Measured 2026-09-23 on a
## Windows host without the DIY ``env.ps1``: ``repro shell`` compiled the
## workspace recipe with ``nim`` from ``PATH``, found none, and failed with
## ``CreateProcessW failed (2)``, although the recipe declares ``tarball``.
##
## Windows was ungated first (reprobuild 1dcf1516b). Linux and macOS kept the
## gate because they had no route that worked in every mode: Linux resolved
## through Nix only, macOS had no arm at all. Now every host has one
## (``bootstrapNimRoute`` / ``bootstrapCRoute``), so the bootstrap provisions
## in every mode everywhere (reprobuild-specs
## Distribution-And-Packaging.milestones.org, M5, rule 2).
##
## Restore ``mode != tpmTarball and mode != tpmFromSource: return`` (or the
## old per-host ``when``) and the second case fails for ``path``, ``nix``,
## ``scoop`` and the unspecified mode; drop a host's route and the third
## fails on that host.
##
## No mocks: these are the real policy procs.

import std/[strutils, unittest]

import repro_tool_profiles

suite "bootstrap toolchain provisioning":
  test "tarball and from-source provision on every host":
    check bootstrapToolchainProvisioned(tpmTarball)
    check bootstrapToolchainProvisioned(tpmFromSource)

  test "every other mode provisions too, on every host":
    for mode in [tpmUnspecified, tpmPathOnly, tpmNix, tpmScoop]:
      checkpoint $mode
      check bootstrapToolchainProvisioned(mode)

  test "this host has a route for both compilers":
    let nimRoute = bootstrapNimRoute()
    let cRoute = bootstrapCRoute()
    checkpoint "nim: " & describeBootstrapNimRoute(nimRoute)
    checkpoint "cc: " & describeBootstrapCRoute(cRoute,
      bootstrapSystemCCompilers)
    when defined(windows):
      check nimRoute == bnrArchive
      check cRoute == bcrArchive
    elif defined(macosx):
      # The official darwin archive for THIS cpu, not the Linux one that
      # used to be the fall-through.
      check nimRoute == bnrArchive
      check cRoute == bcrXcode
      let nim = bootstrapNimToolUse()
      check nim.tarballProvisioning.len == 2
      for entry in nim.tarballProvisioning:
        check entry.os == "macos"
        check "macosx_" in entry.url
    elif defined(linux):
      if bootstrapHostHasNix():
        check nimRoute == bnrNix
        check cRoute == bcrNix
      else:
        check nimRoute == bnrSource
        check cRoute == bcrSystem
    else:
      check nimRoute == bnrSource
      check cRoute == bcrSystem
    # Whatever the route, the description names something concrete rather
    # than "none".
    check "of which" notin describeBootstrapNimRoute(nimRoute)
    check "of which" notin describeBootstrapCRoute(cRoute,
      bootstrapSystemCCompilers)

  test "each Windows cpu provisions its own native C compiler":
    # reprobuild-pm Distribution-And-Packaging.md §7.1, W1: WinLibs GCC on
    # x64, llvm-mingw on arm64 (no maintained Windows-on-Arm-hosted GCC
    # exists), each recorded under its own identity. A pure function of the
    # cpu, so both answers are checked on every host. Hand an arm64 engine the
    # x64 archive and the first assertion on `arm` fails.
    let x64 = windowsBootstrapCToolUse("amd64")
    check x64.packageSelector == "gcc-winlibs@16.1.0"
    check x64.tarballProvisioning.len == 1
    check x64.tarballProvisioning[0].cpu == "x86_64"
    check "winlibs-x86_64-" in x64.tarballProvisioning[0].url

    let arm = windowsBootstrapCToolUse("arm64")
    check arm.tarballProvisioning.len == 1
    let rec = arm.tarballProvisioning[0]
    check rec.cpu == "aarch64"
    check rec.os == "windows"
    check rec.url == BootstrapLlvmMingwWindowsArm64TarballUrl
    check "-ucrt-aarch64.zip" in rec.url
    check rec.packageId == "llvm-mingw@" & BootstrapLlvmMingwWindowsArm64Release
    check arm.packageSelector == rec.packageId
    check rec.lockIdentity.startsWith("tarball:llvm-mingw@")
    check "gcc-winlibs" notin rec.lockIdentity
    # The driver Nim's `--cc:gcc` invokes: llvm-mingw's clang target wrapper.
    check rec.executablePath == "bin/gcc.exe"

    # No pinned toolchain for another cpu: no realization, not a borrowed one.
    check windowsBootstrapCToolUse("i386").tarballProvisioning.len == 0

  test "each Windows cpu bootstraps its own native Nim":
    # The engine's bootstrap Nim is the 2.2.10 vccexe maintenance prefix on
    # both Windows CPUs; the metacraft-labs/nim factory builds the aarch64 one
    # natively, because nim-lang publishes no Windows ARM64 archive. A
    # pure function of the cpu, so both answers are checked on every host.
    # Hand an arm64 engine the x64 prefix and the first assertion on `arm`
    # fails.
    let x64 = windowsBootstrapNimTarballProvisioning("amd64")
    check x64.len == 1
    check x64[0].cpu == "x86_64"
    check x64[0].os == "windows"
    check x64[0].url.endsWith("-windows-x64.zip")

    let arm = windowsBootstrapNimTarballProvisioning("arm64")
    check arm.len == 1
    let rec = arm[0]
    check rec.cpu == "aarch64"
    check rec.os == "windows"
    check rec.url == BootstrapNimTarballWindowsArm64Url
    check rec.sha256 == BootstrapNimTarballWindowsArm64Sha256
    check rec.url.endsWith("/nim-" & BootstrapNimVersion &
      "-vccexe-8910b50d-8910b50d2d21-windows-arm64.zip")
    check rec.archiveType == "zip"
    check rec.executablePath == "bin/nim.exe"
    check rec.stripComponents == 1
    check rec.packageId == "nim@" & BootstrapNimVersion
    check rec.detail.version == BootstrapNimVersion
    # Its own lock identity, never the x64 one: the two archives differ.
    check rec.lockIdentity == "tarball:nim@" & BootstrapNimVersion &
      ":windows-aarch64:sha256:" & BootstrapNimTarballWindowsArm64Sha256
    check rec.lockIdentity != x64[0].lockIdentity

    # The selector the acquisition uses picks each cpu's own archive.
    let armTarget = realizationTargetFor(pcAArch64, poWindows,
      baselineMicroarchLevel(pcAArch64))
    check selectTarballRecord(arm, armTarget,
      versionRange = ">=2.2 <3.0").status == kcSelected
    check selectTarballRecord(x64, armTarget,
      versionRange = ">=2.2 <3.0").status != kcSelected

    # No pinned prefix for another cpu: no realization, not a borrowed one.
    check windowsBootstrapNimTarballProvisioning("i386").len == 0
