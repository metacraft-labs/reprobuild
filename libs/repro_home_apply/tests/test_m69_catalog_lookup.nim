## M69 → GM4b — version-pinned profile references.
##
## M69's catalog-slice lookup resolved `package(<id>, "<version>")` to a
## `VersionedProvisioning` catalog slice. GM4b removed the catalog: versions
## now live on the package's `tarball` (and `scoopApp`) realizations, and a pin
## filters the selection (Provisioning-Contributions.md §"Profile Package
## References" → Selection). What the lookup guarded, restated:
##
##   * a pinned reference selects the realization of exactly that version;
##   * a bare reference selects the FIRST eligible realization in declaration
##     order — authors list the default version first (the retired catalog
##     took the LAST entry; the stdlib conversion reordered to keep each
##     package's old default);
##   * an unknown version fails closed: a missing realization naming the
##     versions on offer — never a silent fallback to another version;
##   * an unknown package id is an unknown package, not a version miss;
##   * a malformed pin is just a version nobody offers;
##   * `repro home add <tool>@latest` writes the version an unpinned reference
##     resolves to on this host (`unpinnedHostVersion`), and `offeredVersions`
##     lists every pinned version a definition carries.
##
## Fixture packages are declared in this module, so they are registered in
## the test process exactly as the engine registers the stdlib; the live
## `jdk` definition is checked too. Selection is static metadata — nothing is
## downloaded. No mocks.

import std/[options, strutils, unittest]

import repro_project_dsl
import repro_home_apply/package_catalog

# Three Windows versions, default (21.0.5) declared first.
package gm4bversioned:
  provisioning:
    tarball url = "https://example.invalid/gm4bversioned-21.0.5.zip",
      sha256 = "2100000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip", executablePath = "bin/tool.exe",
      version = "21.0.5", cpu = "x86_64", os = "windows"
    tarball url = "https://example.invalid/gm4bversioned-17.0.13.zip",
      sha256 = "1700000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip", executablePath = "bin/tool.exe",
      version = "17.0.13", cpu = "x86_64", os = "windows"
    tarball url = "https://example.invalid/gm4bversioned-11.0.25.zip",
      sha256 = "1100000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip", executablePath = "bin/tool.exe",
      version = "11.0.25", cpu = "x86_64", os = "windows"

# Catch-all records (any cpu, any os): resolvable on whatever host runs this.
package gm4bhostversioned:
  provisioning:
    tarball url = "https://example.invalid/gm4bhostversioned-2.0.tar.gz",
      sha256 = "2000000000000000000000000000000000000000000000000000000000000000",
      executablePath = "bin/tool", version = "2.0"
    tarball url = "https://example.invalid/gm4bhostversioned-1.0.tar.gz",
      sha256 = "1000000000000000000000000000000000000000000000000000000000000000",
      executablePath = "bin/tool", version = "1.0"

let windowsX64 = realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1)

proc pinned(pkg, version: string): ProfilePackageResolution =
  resolveProfilePackage(pkg, windowsX64, DefaultSelectionPolicy,
    requestedVersion = version)

suite "M69/GM4b — version-pinned profile references":

  test "pinned `21.0.5` selects that exact realization":
    let r = pinned("gm4bversioned", "21.0.5")
    check r.selection.kind == rkTarball
    check r.selection.version == "21.0.5"
    check r.selection.tarball.url.endsWith("gm4bversioned-21.0.5.zip")

  test "pinned `17.0.13` selects the 17.x realization":
    let r = pinned("gm4bversioned", "17.0.13")
    check r.selection.version == "17.0.13"
    check r.selection.tarball.url.endsWith("gm4bversioned-17.0.13.zip")

  test "a bare reference selects the first declared version":
    let r = pinned("gm4bversioned", "")
    check r.selection.version == "21.0.5"

  test "an unknown version fails closed naming the offered versions":
    var raised = false
    try:
      discard pinned("gm4bversioned", "999.0.0")
    except EMissingRealization as err:
      raised = true
      check err.definitionKnown
      check err.packageName == "gm4bversioned"
      check "999.0.0" in err.msg
      for v in ["21.0.5", "17.0.13", "11.0.25"]:
        check v in err.msg
    check raised

  test "a malformed pin is a version nobody offers":
    var raised = false
    try:
      discard pinned("gm4bversioned", "21.0.5; rm -rf /")
    except EMissingRealization as err:
      raised = true
      check err.definitionKnown
    check raised

  test "the live jdk definition: pin, bare and unknown version":
    check pinned("jdk", "21.0.5").selection.version == "21.0.5"
    check pinned("jdk", "").selection.version == "21.0.5"
    var raised = false
    try:
      discard pinned("jdk", "999.0.0")
    except EMissingRealization as err:
      raised = true
      check err.definitionKnown
      check "21.0.5" in err.msg
    check raised

  test "an unknown package id is an unknown package, not a version miss":
    var raised = false
    try:
      discard pinned("nonexistent-tool-xyz", "1.0")
    except EMissingRealization as err:
      raised = true
      check not err.definitionKnown
      check "unknown package 'nonexistent-tool-xyz'" in err.msg
    check raised

  test "offeredVersions lists every pinned version in declaration order":
    check offeredVersions("gm4bversioned") ==
      @["21.0.5", "17.0.13", "11.0.25"]
    check "21.0.5" in offeredVersions("jdk")
    check offeredVersions("nonexistent-tool-xyz").len == 0

  test "unpinnedHostVersion is the version a bare reference resolves to":
    let v = unpinnedHostVersion("gm4bhostversioned")
    check v.isSome
    check v.get == "2.0"
    check unpinnedHostVersion("nonexistent-tool-xyz").isNone
