## A cold tool store realizes 7z- and zstd-archived tools with NO extractor on
## PATH: the extractor is a provisioned package reached through a dependency
## edge of the provisioning edge that needs it.
##
## Dependency-Provisioning-In-Build-Graph.md section 4. Before the extractor
## became a dependency edge, the 7z arm took `7z` from PATH, so on a Windows
## host without 7-Zip and a cold store, git for Windows (a 7z SFX) and the
## bootstrap gcc (a .7z) could not be realized
## (reprobuild-specs/issues/2026-09-24-tarball-realizer-takes-7z-from-path.md);
## the `.tar.zst` arm took `zstd` from PATH the same way.
##
## What is asserted, on Windows x86_64, against the stdlib's own declarations:
##
##   * the process PATH is reduced to the Windows system directories, and a
##     positive control confirms no `7z`, `7zz`, `7zr` or `zstd` is findable
##     on it -- so a pass cannot come from a host extractor;
##   * git's provisioning subgraph is the 7-Zip edge followed by git's edge;
##   * realizing git into an EMPTY store succeeds, the 7-Zip that extracted it
##     is the one its dependency edge realized into that store, and the
##     realized `git --version` runs and reports the pinned version;
##   * a second realization is served by the action cache: no edge executes;
##   * `msys2-ncurses` (a `.pkg.tar.zst`) realizes into the same cold store
##     through its zstd dependency edge, with no zstd on PATH.
##
## No mocks. A network test: it downloads the pinned upstream archives (7-Zip
## MSI, PortableGit, zstd, ncurses) once into a fresh temporary store. On any
## other host there is no 7z- or zstd-archived tool in the catalog to realize,
## and the test says so rather than passing on a different code path.
##
## Falsifiable: make `extractorRolesFor` return no role for "7z.exe" and the
## git realization raises "needs 7-Zip, and this realization was given none";
## restore a PATH lookup in the 7z arm and the positive control's reduced PATH
## still has nothing to find, so the realization fails the same way.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_build_engine
import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles
import repro_dsl_stdlib/packages/git
import repro_dsl_stdlib/packages/msys2_ncurses
import repro_test_support/reasoned_skip

const HostHasArchivedTools = defined(windows) and defined(amd64)

proc stdlibToolUse(packageName, executableName: string): InterfaceToolUse =
  ## The tool use a consumer declaring `uses: "<packageName>"` gets, built
  ## from the registered stdlib package so the pins under test are the
  ## catalog's own.
  let iface = toProjectInterface(PackageDef(
    packageName: "coldStoreConsumer",
    nativeBuildDeps: @[PackageUseDef(
      rawConstraint: packageName, packageSelector: packageName,
      executableName: executableName, depKind: "native")]),
    registeredPackages())
  doAssert iface.toolUses.len == 1, "expected one tool use for " & packageName
  iface.toolUses[0]

suite "cold-store realization of archived tools without host extractors":
  putEnv("REPRO_CACHE_DISABLE", "1")
  let tempRoot = createTempDir("repro-cold-extractors-", "")
  let storeRoot = tempRoot / "store"

  when HostHasArchivedTools:
    let systemRoot = getEnv("SystemRoot", r"C:\Windows")
    putEnv("PATH", [systemRoot / "System32", systemRoot,
      systemRoot / "System32" / "Wbem",
      systemRoot / "System32" / "WindowsPowerShell" / "v1.0"].join($PathSep))

  test "the reduced PATH has no extractor (positive control)":
    when not HostHasArchivedTools:
      skip("no 7z- or zstd-archived tool is pinned for " & hostOS & "/" &
        hostCPU & "; there is nothing to extract")
    else:
      for name in ["7z", "7zz", "7zr", "zstd"]:
        check findExe(name).len == 0

  test "git realizes into a cold store through its 7-Zip dependency edge":
    when not HostHasArchivedTools:
      skip("no 7z-archived tool is pinned for " & hostOS & "/" & hostCPU)
    else:
      let useDef = stdlibToolUse("git", "git")
      require useDef.tarballProvisioning.len > 0
      let edges = tarballProvisioningEdges(useDef, storeRoot)
      require edges.actions.len == 2
      let sevenZipEdge = edges.actions[0]
      check sevenZipEdge.argv == @[TarballProvisionerName, "7zip@26.01"]
      check sevenZipEdge.id in edges.actions[1].deps
      check not dirExists(storeRoot / "prefixes")

      let profile = resolveTarballTool(useDef, storeRoot)
      check profile.installMethod == "tarball"
      check profile.resolvedExecutablePath.startsWith(storeRoot)
      let sevenZip = readTarballProvisionReceipt(sevenZipEdge.outputs[0])
      check sevenZip.executable.startsWith(storeRoot)
      check fileExists(sevenZip.executable)

      let version = execProcess(profile.resolvedExecutablePath,
        args = ["--version"], options = {})
      check version.startsWith("git version 2.54.0")

      let again = runProvisioningEdges(edges, storeRoot)
      for item in again.results:
        check item.status in {asUpToDate, asCacheHit}
        check not item.launched

  test "an MSYS2 .pkg.tar.zst realizes through its zstd dependency edge":
    when not HostHasArchivedTools:
      skip("no zstd-archived tool is pinned for " & hostOS & "/" & hostCPU)
    else:
      let useDef = stdlibToolUse("msys2-ncurses", "infocmp")
      require useDef.tarballProvisioning.len > 0
      let edges = tarballProvisioningEdges(useDef, storeRoot)
      require edges.actions.len == 2
      check edges.actions[0].argv == @[TarballProvisionerName, "zstd@1.5.6"]
      let profile = resolveTarballTool(useDef, storeRoot)
      check fileExists(profile.resolvedExecutablePath)
      check profile.resolvedExecutablePath.startsWith(storeRoot)
      let zstd = readTarballProvisionReceipt(edges.actions[0].outputs[0])
      check zstd.executable.startsWith(storeRoot)
