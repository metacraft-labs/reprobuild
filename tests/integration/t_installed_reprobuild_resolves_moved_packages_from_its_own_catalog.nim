## An installed reprobuild resolves a package that moved to
## `reprobuild-packages` from the catalog its release archive ships.
##
## reprobuild-specs/Provisioning-Contributions.md, "Catalog Lookup And
## Provisioning": the lookup's last place is a `reprobuild-packages` directory
## beside the reprobuild checkout the DSL was compiled from. In the installed
## layout the DSL is compiled from `<prefix>/share/repro/source`, so the
## catalog an archive ships at `<prefix>/share/repro/reprobuild-packages` is
## found there, with no workspace and no `$REPROBUILD_PACKAGES_ROOT`. Before
## this, an installed `repro` carried no catalog, and outside a workspace a
## recipe using a moved package did not compile at all.
##
## The fixture is real throughout: a git repository stands in for the catalog,
## `scripts/release/stage_release_catalog.sh` (the script the release legs run)
## stages its PINNED commit into a fresh install prefix, and the lookup module
## itself is copied into that prefix's source tree, compiled there, and run
## from a directory with no catalog above it. Nothing is mocked.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
const CatalogModuleRel = "libs/repro_project_dsl/src/repro_project_dsl/" &
  "reprobuild_packages_catalog.nim"
const StageScript = RepoRoot / "scripts" / "release" / "stage_release_catalog.sh"

const FixtureInterface = """
import repro_project_dsl

package rpinstalledfixture:
  provisioning:
    tarball url = "https://example.invalid/rpinstalledfixture-1.0.zip",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip",
      executablePath = "rpinstalledfixture",
      packageId = "rpinstalledfixture@1.0",
      lockIdentity = "tarball:rpinstalledfixture@1.0:sha256:0000000000000000000000000000000000000000000000000000000000000000"
"""

const Probe = """
import std/os
import "$1"

let search = reprobuildPackagesSearch("rpinstalledfixture",
  getCurrentDir() / "consumer" / "repro.nim")
echo "module=", search.module
let root = search.module.parentDir.parentDir.parentDir.parentDir
let marker = readCatalogRevisionMarker(root)
echo "url=", marker.url
echo "revision=", marker.revision
"""

proc run(command: string; cwd = ""; env: StringTableRef = nil):
    tuple[output: string, exitCode: int] =
  execCmdEx(command, options = {poStdErrToStdOut, poUsePath},
    workingDir = cwd, env = env)

proc git(repo: string; args: varargs[string]): string =
  var command = "git -C " & quoteShell(repo)
  for arg in args:
    command.add(" " & quoteShell(arg))
  let (output, exitCode) = run(command)
  doAssert exitCode == 0, command & "\n" & output
  output.strip()

proc childEnv(extra: openArray[(string, string)]): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key.toUpperAscii() != "REPROBUILD_PACKAGES_ROOT":
      result[key] = value
  for (key, value) in extra:
    result[key] = value

suite "an installed reprobuild carries the catalog it was released with":
  let scratch = createTempDir("repro-installed-catalog-", "")

  # The catalog repository, committed once. The pinned commit defines the
  # fixture; a later, uncommitted file must NOT reach the archive.
  let catalogRepo = scratch / "catalog-src"
  createDir(catalogRepo / "packages" / "interfaces" / "rpinstalledfixture")
  writeFile(catalogRepo / "packages" / "interfaces" / "rpinstalledfixture" /
    "repro.nim", FixtureInterface)
  discard git(catalogRepo, "init", "-q")
  discard git(catalogRepo, "config", "user.email", "t@example.invalid")
  discard git(catalogRepo, "config", "user.name", "Tester")
  discard git(catalogRepo, "config", "commit.gpgsign", "false")
  discard git(catalogRepo, "remote", "add", "origin",
    "https://ci-token@example.invalid/acme/reprobuild-packages.git")
  discard git(catalogRepo, "add", ".")
  discard git(catalogRepo, "commit", "-q", "-m", "catalog")
  let pinned = git(catalogRepo, "rev-parse", "HEAD")
  createDir(catalogRepo / "packages" / "interfaces" / "rpleaked")
  writeFile(catalogRepo / "packages" / "interfaces" / "rpleaked" / "repro.nim",
    "# not committed\n")

  # The release checkout the staging script runs in: it pins the catalog.
  let checkout = scratch / "release-checkout"
  createDir(checkout / ".github")
  writeFile(checkout / ".github" / "sibling-repos",
    "# the catalog\r\nreprobuild-packages=" & pinned & "\r\n")

  # The install prefix, holding the catalog lookup module where an installed
  # reprobuild's DSL lives.
  let prefix = scratch / "reprobuild-0.0.0-test"
  let installedModule = prefix / "share" / "repro" / "source" / CatalogModuleRel
  createDir(installedModule.parentDir)
  copyFile(RepoRoot / CatalogModuleRel, installedModule)

  test "the staging script ships the pinned catalog and names its revision":
    let (output, exitCode) = run("bash " & quoteShell(StageScript) & " " &
      quoteShell(prefix), cwd = checkout,
      env = childEnv([("REPROBUILD_PACKAGES_ROOT", catalogRepo)]))
    checkpoint(output)
    check exitCode == 0
    let staged = prefix / "share" / "repro" / "reprobuild-packages"
    check fileExists(staged / "packages" / "interfaces" / "rpinstalledfixture" /
      "repro.nim")
    check not dirExists(staged / "packages" / "interfaces" / "rpleaked")
    let marker = readFile(staged / "catalog-revision")
    check ("revision=" & pinned) in marker
    check "url=https://example.invalid/acme/reprobuild-packages\n" in marker
    check "ci-token" notin marker

  test "the installed lookup finds the shipped catalog with no workspace":
    let probeDir = scratch / "elsewhere"
    createDir(probeDir / "consumer")
    writeFile(probeDir / "probe.nim",
      Probe % installedModule.changeFileExt("").replace('\\', '/'))
    let (output, exitCode) = run("nim c -r --hints:off --warnings:off " &
      "--skipParentCfg:on --skipUserCfg:on --skipProjCfg:on " &
      quoteShell("--nimcache:" & (probeDir / "nimcache")) & " " &
      quoteShell(probeDir / "probe.nim"), cwd = probeDir, env = childEnv([]))
    checkpoint(output)
    check exitCode == 0
    let expected = (prefix / "share" / "repro" / "reprobuild-packages" /
      "packages" / "interfaces" / "rpinstalledfixture" / "repro").replace('\\', '/')
    var module = ""
    for line in output.splitLines():
      if line.startsWith("module="):
        module = line["module=".len .. ^1].strip().replace('\\', '/')
    check module.toLowerAscii() == expected.toLowerAscii()
    check ("revision=" & pinned) in output
    check "url=https://example.invalid/acme/reprobuild-packages" in output

  test "a checkout without the pinned commit is refused, naming what to fetch":
    let empty = scratch / "empty-catalog"
    createDir(empty)
    discard git(empty, "init", "-q")
    let otherPrefix = scratch / "other-prefix"
    let (output, exitCode) = run("bash " & quoteShell(StageScript) & " " &
      quoteShell(otherPrefix), cwd = checkout,
      env = childEnv([("REPROBUILD_PACKAGES_ROOT", empty)]))
    checkpoint(output)
    check exitCode != 0
    check pinned in output
    check "fetch that commit" in output

  removeDir(scratch)
