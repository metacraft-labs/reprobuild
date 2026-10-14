## M9.5 smoke → GM4b — a profile reference to `gh` resolved for an
## x86_64-linux target selects the Linux archive.
##
## The per-operator "Manual smoke" gate from the M9.5 hand-off list,
## restated for GM4b: the M9.5 cross-OS archives are `tarball`
## realizations of each package (formerly per-platform catalog slices), and
## `resolveProfilePackage` with the `[tarball]` policy picks the
## x86_64-linux record and carries its URL, digest, archive type and
## executable forward to the realize stage. Resolver-only (no realize, no
## network), with a stated target, so it runs identically on any host.
## No mocks.

import std/[strutils, unittest]

import repro_home_apply/package_catalog

proc resolveTarball(pkg: string; cpu: PlatformCpu; os: PlatformOs):
    ProfilePackageResolution =
  resolveProfilePackage(pkg, realizationTargetFor(cpu, os, mlX86_64_v1),
    @[rkTarball])

suite "M9.5/GM4b smoke: Linux archives resolve":

  test "gh resolves to its Linux archive":
    let res = resolveTarball("gh", pcX86_64, poLinux)
    check res.selection.kind == rkTarball
    let record = res.selection.tarball
    check "linux_amd64.tar.gz" in record.url
    check parseArchiveFormatToken(record.archiveType).format == afTarGz
    # The executable is the Linux variant (no .exe suffix).
    check record.executablePath.len > 0
    check ".exe" notin record.executablePath
    for extra in record.detail.extraExecutables:
      check ".exe" notin extra
    check record.sha256.len == 64
    # A plain archive: realized by the `uses:` provisioning edge.
    check res.archiveRoute == arExtract

  test "crystal resolves to its Linux archive (Phase-2 fixture)":
    let res = resolveTarball("crystal", pcX86_64, poLinux)
    check "linux-x86_64" in res.selection.tarball.url
    check parseArchiveFormatToken(res.selection.tarball.archiveType).format ==
      afTarGz
    # Crystal's Linux tarball nests; extractPath flattens it, which the home
    # archive realizer performs.
    check res.selection.tarball.detail.extractPath == "crystal-1.20.2-1"
    check res.archiveRoute == arInstaller
    check res.archive.extractPath == "crystal-1.20.2-1"

  test "ghc resolves to its Linux archive (Phase-2 fixture)":
    let res = resolveTarball("ghc", pcX86_64, poLinux)
    check "centos7-linux" in res.selection.tarball.url
    check parseArchiveFormatToken(res.selection.tarball.archiveType).format ==
      afTarXz

  test "cabal resolves to its Linux archive (Phase-2 fixture)":
    let res = resolveTarball("cabal", pcX86_64, poLinux)
    check "linux-deb10" in res.selection.tarball.url
    check parseArchiveFormatToken(res.selection.tarball.archiveType).format ==
      afTarXz

  test "Windows resolution still works (no regression on existing tools)":
    let res = resolveTarball("gh", pcX86_64, poWindows)
    check "windows_amd64.zip" in res.selection.tarball.url
    check parseArchiveFormatToken(res.selection.tarball.archiveType).format ==
      afZip
    check ".exe" in res.selection.tarball.executablePath
