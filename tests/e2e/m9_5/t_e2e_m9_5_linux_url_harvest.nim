## M9.5 — Linux URL harvester pass gate.
##
## Asserts that every catalog file the M9.5 milestone graduated carries
## BOTH a Windows AND a Linux platform slice, and that the Linux slice
## has a non-empty URL and a non-empty sha256 digest. The M9 canary's
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

import repro_dsl_stdlib/catalog_registry
import repro_dsl_stdlib/packages_schema
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

proc selectLinuxBinary(vp: VersionedProvisioning):
    tuple[found: bool; binary: PlatformBinary] =
  for pb in vp.platforms:
    if pb.os == poLinux and pb.cpu == pcX86_64:
      return (true, pb)
  (false, PlatformBinary())

proc selectWindowsBinary(vp: VersionedProvisioning):
    tuple[found: bool; binary: PlatformBinary] =
  for pb in vp.platforms:
    if pb.os == poWindows and (pb.cpu == pcX86_64 or pb.cpu == pcAny):
      return (true, pb)
  (false, PlatformBinary())

suite "M9.5 e2e: Linux URL harvester pass":

  test "every graduated catalog file has Windows AND Linux slices":
    for spec in M9_5GraduatedTools:
      checkpoint("tool=" & spec.tool & " version~" & spec.versionPrefix)
      let cat = getCatalog(spec.tool)
      check cat.isSome
      let entries = cat.get
      check entries.len > 0
      # Locate the version-matching entry.
      var matched: VersionedProvisioning
      var foundVersion = false
      for vp in entries:
        if vp.version.startsWith(spec.versionPrefix):
          matched = vp
          foundVersion = true
          break
      check foundVersion
      if not foundVersion:
        continue
      # Windows slice present (the pre-M9.5 baseline).
      let win = selectWindowsBinary(matched)
      check win.found
      # Linux slice present (the M9.5 addition).
      let lin = selectLinuxBinary(matched)
      check lin.found

  test "every Linux slice carries a non-empty URL and sha256":
    for spec in M9_5GraduatedTools:
      checkpoint("tool=" & spec.tool & " version~" & spec.versionPrefix)
      let cat = getCatalog(spec.tool)
      check cat.isSome
      var matched: VersionedProvisioning
      var foundVersion = false
      for vp in cat.get:
        if vp.version.startsWith(spec.versionPrefix):
          matched = vp
          foundVersion = true
          break
      check foundVersion
      if not foundVersion:
        continue
      let lin = selectLinuxBinary(matched)
      check lin.found
      if not lin.found:
        continue
      # Non-empty URL.
      check lin.binary.url.len > 0
      # Non-empty digest: per the M9.5 spec note about maven (which
      # uses Apache's canonical sha512 sidecar), accept either sha256
      # or sha512 — both are strong digests. sha1 is M1's weak-hash
      # fallback and is acceptable too but no M9.5 tool uses it.
      check (lin.binary.sha256.len > 0) or
            (lin.binary.sha512.len > 0) or
            (lin.binary.sha1.len > 0)
      # URL contains the expected marker (defends against accidental
      # copy-paste of the Windows URL into the Linux slice).
      check spec.expectedUrlMarker in lin.binary.url

  test "Linux bin_relpath_override (when set) names the linux binary":
    ## The M9.5 schema extension promoted bin_relpath_override onto
    ## PlatformBinary. When set, it carries the platform-specific
    ## binary name (no ``.exe`` suffix on Linux). The default
    ## (empty seq) falls back to the parent VersionedProvisioning's
    ## bin_relpath.
    for spec in M9_5GraduatedTools:
      checkpoint("tool=" & spec.tool & " version~" & spec.versionPrefix)
      let cat = getCatalog(spec.tool)
      check cat.isSome
      var matched: VersionedProvisioning
      var foundVersion = false
      for vp in cat.get:
        if vp.version.startsWith(spec.versionPrefix):
          matched = vp
          foundVersion = true
          break
      check foundVersion
      if not foundVersion:
        continue
      let lin = selectLinuxBinary(matched)
      check lin.found
      if not lin.found:
        continue
      # The effective bin_relpath for Linux: override if set; else
      # the VP's. At least one entry should contain the tool's
      # canonical Linux binary name.
      let effective =
        if lin.binary.bin_relpath_override.len > 0:
          lin.binary.bin_relpath_override
        else:
          matched.bin_relpath
      var sawTool = false
      for b in effective:
        if spec.expectedBinSubstring in b:
          sawTool = true
          break
      check sawTool
      # No Linux entry should carry the ``.exe`` suffix (windows-only).
      for b in effective:
        check ".exe" notin b

  test "resolveBuiltinPackage on Linux returns Linux URL for graduated tools":
    ## End-to-end resolver smoke: the chain-level test covers
    ## chainResolvePackage; this test exercises the inner
    ## resolveBuiltinPackage directly so we surface schema bugs
    ## (e.g. a malformed Linux slice) earlier in the call chain.
    for spec in M9_5GraduatedTools:
      checkpoint("tool=" & spec.tool & " version~" & spec.versionPrefix)
      let cat = getCatalog(spec.tool)
      check cat.isSome
      if cat.isNone:
        continue
      # Pass an exact version pin so multi-version tools (zig, gradle)
      # resolve the slice that matches the spec, not the catalog's
      # default-last entry.
      var pin = ""
      for vp in cat.get:
        if vp.version.startsWith(spec.versionPrefix):
          pin = vp.version
          break
      let res = resolveBuiltinPackage(spec.tool, cat.get,
        version = pin, hostCpu = pcX86_64, hostOs = poLinux)
      check res.found
      if not res.found:
        echo "resolveBuiltinPackage failed for ", spec.tool, ": ",
             res.error, " (", res.errorDetail, ")"
        continue
      check spec.expectedUrlMarker in res.resolution.urlUsed
      # The resolution's binRelpath should be the Linux variant (no
      # .exe suffix).
      for b in res.resolution.binRelpath:
        check ".exe" notin b

  test "count: 15 catalog files gained a poLinux slice":
    ## A meta-assertion: M9.5 graduated EXACTLY 15 catalog files,
    ## with two of them (zig + gradle) carrying the Linux slice
    ## across MULTIPLE versions for a total of 17 graduated slices.
    ## A reviewer adding more should update both this count and the
    ## M9 canary's ExpectedBuiltinResolvedOnLinux.
    check M9_5GraduatedTools.len == 17
    # Distinct file-level count (collapsing zig + gradle to one each).
    var files = initTable[string, int]()
    for spec in M9_5GraduatedTools:
      files.mgetOrPut(spec.tool, 0).inc
    check files.len == 15
