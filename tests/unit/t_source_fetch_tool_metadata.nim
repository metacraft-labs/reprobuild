import std/[sequtils, unittest]
import repro_project_dsl
import repro_interface_artifacts
import repro_dsl_stdlib/configurables/variants

const FetchHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const ArchiveSuffix = ".tar.xz?mirror=1"

package archiveFetchMetadata:
  nativeBuildDeps:
    "curl >=8"
  fetch:
    url: "https://example.invalid/source" & ArchiveSuffix
    sha256: FetchHash
  build:
    raise newException(ValueError, "metadata extraction must not execute build bodies")

package dataFetchMetadata:
  fetch:
    url: "https://example.invalid/config"
    sha256: FetchHash
    dataFile: true

package noFetchMetadata:
  discard

package blake3FetchMetadata:
  fetch:
    url: "https://example.invalid/source.tar.gz"
    blake3: FetchHash

package gitFetchMetadata:
  fetch:
    gitUrl: "https://example.invalid/source.git"
    gitRevision: "v1"
    sha256: FetchHash

proc definition(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "missing package: " & name)

suite "source fetch metadata":
  test "archive tools reach the interface without running a build":
    let pkg = definition("archiveFetchMetadata")
    let iface = toProjectInterface(pkg, registeredPackages())
    let tools = iface.toolUses.mapIt(it.executableName)
    for name in shellFetchToolIdentityRefs(@["sha256sum"],
        archiveUrl = "https://example.invalid/source" & ArchiveSuffix):
      check name in tools
      let uses = iface.toolUses.filterIt(it.executableName == name)
      check uses.len == 1
      if uses.len == 1:
        check uses[0].nixProvisioning.len > 0
    check "gzip" notin tools
    check "bzip2" notin tools
    check pkg.nativeBuildDeps.filterIt(it.executableName == "curl").len == 1
    check pkg.nativeBuildDeps.filterIt(it.executableName == "curl")[0].rawConstraint == "curl >=8"

  test "fetch requirements retain their build-platform dependency role":
    let pkg = definition("archiveFetchMetadata")
    for name in ["sh", "rm", "mkdir", "sha256sum", "tar", "xz"]:
      let uses = pkg.nativeBuildDeps.filterIt(it.executableName == name)
      check uses.len == 1
      if uses.len == 1:
        check uses[0].depKind == DepKindNative
      check name in registeredNativeBuildDeps(pkg.packageName)
      let solverUses = pendingSolverDependencies().filterIt(
        it.parentPackage == pkg.packageName and it.depPackage == name)
      check solverUses.len == 1
      if solverUses.len == 1:
        check solverUses[0].depKind == DepKindNative

  test "data files require copy but not archive extraction tools":
    let iface = toProjectInterface(definition("dataFetchMetadata"),
      registeredPackages())
    let tools = iface.toolUses.mapIt(it.executableName)
    check "cp" in tools
    check "sh" in tools
    check "tar" notin tools
    check "xz" notin tools
    check "gzip" notin tools

  test "packages without fetch declarations gain no tools":
    check toProjectInterface(definition("noFetchMetadata"),
      registeredPackages()).toolUses.len == 0

  test "BLAKE3 selects its real checksum implementation":
    let iface = toProjectInterface(definition("blake3FetchMetadata"),
      registeredPackages())
    let tools = iface.toolUses.mapIt(it.executableName)
    check "b3sum" in tools
    check "b2sum" notin tools
    check "blake3sum" notin tools
    let uses = iface.toolUses.filterIt(it.executableName == "b3sum")
    check uses.len == 1
    if uses.len == 1:
      check uses[0].nixProvisioning.len == 1

  test "git archives declare their source control tool":
    let iface = toProjectInterface(definition("gitFetchMetadata"),
      registeredPackages())
    check "git" in iface.toolUses.mapIt(it.executableName)
