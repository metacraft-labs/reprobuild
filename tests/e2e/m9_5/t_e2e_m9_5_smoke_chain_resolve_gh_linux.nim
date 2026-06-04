## M9.5 smoke — chainResolvePackage('gh', hostOs = poLinux) returns
## the Linux URL via cakBuiltin.
##
## This is the per-operator "Manual smoke" gate from the M9.5 hand-off
## verification list. Runs on Windows (resolver-only; no realize-side
## work) and confirms the M9.5 cross-OS catalog wiring end-to-end:
## the chain probes the catalog, selectPlatformBinary picks the
## (pcX86_64, poLinux) slice, and the resolution carries the Linux URL
## + Linux sha256 + Linux bin_relpath_override forward to the realize
## stage.

import std/[strutils, unittest]

import repro_dsl_stdlib/catalog_registry
import repro_dsl_stdlib/packages_schema
import repro_home_apply/package_catalog

suite "M9.5 smoke: chain resolves cakBuiltin Linux slice":

  test "gh resolves via cakBuiltin on Linux":
    var cat = openProductionCatalog()
    let res = chainResolvePackage(cat, "gh",
      chain = @[cakBuiltin],
      hostCpu = pcX86_64, hostOs = poLinux)
    check res.adapter == cakBuiltin
    check "linux_amd64.tar.gz" in res.urlUsed
    # The realize loop will key off archiveFormat to dispatch the
    # tar.gz extractor — confirm the per-platform override flowed
    # through.
    check res.archiveFormat == afTarGz
    # The binRelpath should be the Linux variant (no .exe suffix).
    check res.binRelpath.len > 0
    for b in res.binRelpath:
      check ".exe" notin b
    # digest matches the harvested sha256.
    check res.digestAlgorithm == "sha256"
    check res.digestValue.len == 64

  test "crystal resolves via cakBuiltin on Linux (Phase-2 fixture)":
    var cat = openProductionCatalog()
    let res = chainResolvePackage(cat, "crystal",
      chain = @[cakBuiltin],
      hostCpu = pcX86_64, hostOs = poLinux)
    check res.adapter == cakBuiltin
    check "linux-x86_64" in res.urlUsed
    check res.archiveFormat == afTarGz
    # Crystal Linux tarball nests; extractPath strips it.
    check res.extractPath == "crystal-1.20.2-1"

  test "ghc resolves via cakBuiltin on Linux (Phase-2 fixture)":
    var cat = openProductionCatalog()
    let res = chainResolvePackage(cat, "ghc",
      chain = @[cakBuiltin],
      hostCpu = pcX86_64, hostOs = poLinux)
    check res.adapter == cakBuiltin
    check "centos7-linux" in res.urlUsed
    # ghc Linux tarball stays afTarXz (same as Windows mingw32 variant).
    check res.archiveFormat == afTarXz

  test "cabal resolves via cakBuiltin on Linux (Phase-2 fixture)":
    var cat = openProductionCatalog()
    let res = chainResolvePackage(cat, "cabal",
      chain = @[cakBuiltin],
      hostCpu = pcX86_64, hostOs = poLinux)
    check res.adapter == cakBuiltin
    check "linux-deb10" in res.urlUsed
    check res.archiveFormat == afTarXz

  test "Windows resolution still works (no regression on existing tools)":
    ## Defensive: the M9.5 schema extension MUST NOT break existing
    ## Windows-only flows. Resolve gh on Windows and confirm the
    ## Windows URL flows.
    var cat = openProductionCatalog()
    let res = chainResolvePackage(cat, "gh",
      chain = @[cakBuiltin],
      hostCpu = pcX86_64, hostOs = poWindows)
    check res.adapter == cakBuiltin
    check "windows_amd64.zip" in res.urlUsed
    check res.archiveFormat == afZip
    # Windows bin_relpath retains the .exe suffix.
    var sawExe = false
    for b in res.binRelpath:
      if ".exe" in b:
        sawExe = true
        break
    check sawExe
