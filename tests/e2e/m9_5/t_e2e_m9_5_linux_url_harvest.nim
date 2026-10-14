## M9.5 → GM4b — Linux URL harvester pass gate.
##
## Asserts that every package the M9.5 milestone graduated carries BOTH a
## Windows AND a Linux archive realization, and that the Linux one has a
## non-empty URL and digest. GM4b: the per-platform catalog slices are now
## `tarball` realizations of each package definition (one record per
## (version, platform)), read here through `profileToolUse` — the same
## projection a profile reference resolves against. The M9 canary's
## per-tool classification matrix covers the resolver-side contract;
## this test covers the catalog-side contract (the slice set has the
## right shape).
##
## **Graduation set:** the 15 catalog files that gained a poLinux slice
## in M9.5 — see the milestone's deliverable table for the per-tool
## rationale. Two files (``zig`` + ``gradle``) carry the Linux slice
## across MULTIPLE versions; both versions are asserted (total 17
## slice-level expectations across 15 files).
##
## Per the operator's M9.5 hand-off:
##   * Per-tool table: tool | Linux source | URL | bin_relpath | sha256
##   * Final count: 15 of ~24 registered tools gained Linux slices
##     (17 slice-level when counting per-version)
##   * M9 canary test: was ``== 0``, now ``== 8`` per the
##     subset checked by the M9 hermetic gate
##
## The remaining ~10 registered tools are documented as M9.6+
## candidates (apt/dnf/pacman-source territory) in the M9.5 spec.

import std/[options, strutils, tables, unittest]

import repro_interface_artifacts
import repro_home_apply/package_catalog

type
  LinuxSliceExpectation = object
    tool: string
    versionPrefix: string  ## empty = any version; non-empty = match
                           ## a single version with this prefix
    expectedUrlMarker: string  ## a substring the URL must contain
    expectedBinSubstring: string  ## a substring at least one bin_relpath
                                  ## entry must contain (the linux variant
                                  ## of the binary name)

const M9_5GraduatedTools = @[
  LinuxSliceExpectation(tool: "gh", versionPrefix: "2.93.0",
    expectedUrlMarker: "gh_2.93.0_linux_amd64.tar.gz",
    expectedBinSubstring: "gh"),
  LinuxSliceExpectation(tool: "just", versionPrefix: "1.51.0",
    expectedUrlMarker: "just-1.51.0-x86_64-unknown-linux-musl.tar.gz",
    expectedBinSubstring: "just"),
  LinuxSliceExpectation(tool: "ninja", versionPrefix: "1.13.2",
    expectedUrlMarker: "ninja-linux.zip",
    expectedBinSubstring: "ninja"),
  LinuxSliceExpectation(tool: "cmake", versionPrefix: "4.3.3",
    expectedUrlMarker: "cmake-4.3.3-linux-x86_64.tar.gz",
    expectedBinSubstring: "cmake"),
  LinuxSliceExpectation(tool: "crystal", versionPrefix: "1.20.2",
    expectedUrlMarker: "crystal-1.20.2-1-linux-x86_64.tar.gz",
    expectedBinSubstring: "crystal"),
  LinuxSliceExpectation(tool: "alire", versionPrefix: "2.1.1",
    expectedUrlMarker: "alr-2.1.1-bin-x86_64-linux.zip",
    expectedBinSubstring: "alr"),
  LinuxSliceExpectation(tool: "jdk", versionPrefix: "21.0.5",
    expectedUrlMarker: "OpenJDK21U-jdk_x64_linux_hotspot",
    expectedBinSubstring: "javac"),
  LinuxSliceExpectation(tool: "llvm-mingw", versionPrefix: "20260519",
    expectedUrlMarker: "ucrt-ubuntu-22.04-x86_64.tar.xz",
    expectedBinSubstring: "clang"),
  LinuxSliceExpectation(tool: "nim", versionPrefix: "2.2.10",
    expectedUrlMarker: "nim-2.2.10-linux_x64.tar.xz",
    expectedBinSubstring: "nim"),
  LinuxSliceExpectation(tool: "ghc", versionPrefix: "9.12.1",
    expectedUrlMarker: "ghc-9.12.1-x86_64-centos7-linux.tar.xz",
    expectedBinSubstring: "ghc"),
  LinuxSliceExpectation(tool: "cabal", versionPrefix: "3.16.1.0",
    expectedUrlMarker: "cabal-install-3.16.1.0-x86_64-linux-deb10.tar.xz",
    expectedBinSubstring: "cabal"),
  LinuxSliceExpectation(tool: "node", versionPrefix: "24.16.0",
    expectedUrlMarker: "node-v24.16.0-linux-x64.tar.xz",
    expectedBinSubstring: "node"),
  # zig carries the Linux slice for BOTH 0.16.0 and 0.13.0 versions.
  LinuxSliceExpectation(tool: "zig", versionPrefix: "0.16.0",
    expectedUrlMarker: "zig-x86_64-linux-0.16.0.tar.xz",
    expectedBinSubstring: "zig"),
  LinuxSliceExpectation(tool: "zig", versionPrefix: "0.13.0",
    expectedUrlMarker: "zig-linux-x86_64-0.13.0.tar.xz",
    expectedBinSubstring: "zig"),
  LinuxSliceExpectation(tool: "maven", versionPrefix: "3.9.16",
    expectedUrlMarker: "apache-maven-3.9.16-bin.tar.gz",
    expectedBinSubstring: "mvn"),
  # gradle carries the Linux slice for BOTH 9.5.1 and 8.10.2 versions.
  LinuxSliceExpectation(tool: "gradle", versionPrefix: "9.5.1",
    expectedUrlMarker: "gradle-9.5.1-all.zip",
    expectedBinSubstring: "gradle"),
  LinuxSliceExpectation(tool: "gradle", versionPrefix: "8.10.2",
    expectedUrlMarker: "gradle-8.10.2-all.zip",
    expectedBinSubstring: "gradle"),
]

proc archivesOf(spec: LinuxSliceExpectation):
    seq[InterfaceTarballProvisioning] =
  ## The package's archive realizations at the spec's version.
  for r in profileToolUse(spec.tool).useDef.tarballProvisioning:
    if r.detail.version.startsWith(spec.versionPrefix):
      result.add(r)

proc linuxArchive(spec: LinuxSliceExpectation):
    tuple[found: bool; record: InterfaceTarballProvisioning] =
  for r in archivesOf(spec):
    if r.os == "linux" and r.cpu == "x86_64":
      return (true, r)

proc windowsArchive(spec: LinuxSliceExpectation):
    tuple[found: bool; record: InterfaceTarballProvisioning] =
  for r in archivesOf(spec):
    if r.os == "windows" and r.cpu in ["x86_64", "", "any"]:
      return (true, r)

proc executables(r: InterfaceTarballProvisioning): seq[string] =
  @[r.executablePath] & r.detail.extraExecutables

suite "M9.5/GM4b e2e: Linux URL harvester pass":

  test "every graduated package has Windows AND Linux archives":
    for spec in M9_5GraduatedTools:
      checkpoint("tool=" & spec.tool & " version~" & spec.versionPrefix)
      check archivesOf(spec).len > 0
      check windowsArchive(spec).found
      check linuxArchive(spec).found

  test "every Linux archive carries a non-empty URL and digest":
    for spec in M9_5GraduatedTools:
      checkpoint("tool=" & spec.tool & " version~" & spec.versionPrefix)
      let lin = linuxArchive(spec)
      check lin.found
      if not lin.found:
        continue
      check lin.record.url.len > 0
      # maven uses Apache's canonical sha512 sidecar; accept any digest.
      check (lin.record.sha256.len > 0) or
            (lin.record.detail.sha512.len > 0) or
            (lin.record.detail.sha1.len > 0)
      # Defends against a Windows URL copy-pasted into the Linux record.
      check spec.expectedUrlMarker in lin.record.url

  test "Linux executables name the linux binary":
    for spec in M9_5GraduatedTools:
      checkpoint("tool=" & spec.tool & " version~" & spec.versionPrefix)
      let lin = linuxArchive(spec)
      check lin.found
      if not lin.found:
        continue
      var sawTool = false
      for b in executables(lin.record):
        if spec.expectedBinSubstring in b:
          sawTool = true
        check ".exe" notin b
      check sawTool

  test "a pinned reference on x86_64-linux selects the Linux archive":
    ## Resolver smoke: the selection a profile makes (exact version pin,
    ## so multi-version tools resolve the spec's version, not the default).
    let target = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v1)
    for spec in M9_5GraduatedTools:
      checkpoint("tool=" & spec.tool & " version~" & spec.versionPrefix)
      let lin = linuxArchive(spec)
      check lin.found
      if not lin.found:
        continue
      let res = resolveProfilePackage(spec.tool, target, @[rkTarball],
        requestedVersion = lin.record.detail.version)
      check res.selection.kind == rkTarball
      check spec.expectedUrlMarker in res.selection.tarball.url
      for b in executables(res.selection.tarball):
        check ".exe" notin b

  test "count: 15 packages gained a Linux archive":
    ## M9.5 graduated EXACTLY 15 packages, two of them (zig + gradle)
    ## across MULTIPLE versions — 17 archive-level expectations.
    check M9_5GraduatedTools.len == 17
    var files = initTable[string, int]()
    for spec in M9_5GraduatedTools:
      files.mgetOrPut(spec.tool, 0).inc
    check files.len == 15
