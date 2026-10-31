## An installed ENGINE looks a profile's package reference up in the catalog
## its release ships, wherever the release was built.
##
## reprobuild-specs/Provisioning-Contributions.md §Profile Package References,
## step 2: the lookup reaches "the one beside the reprobuild sources (for an
## installed reprobuild, the catalog its release ships)"; §Lookup step 4: for
## an installed reprobuild that checkout is `<prefix>/share/repro/source`, so
## the catalog at `<prefix>/share/repro/reprobuild-packages` is found.
##
## The defect (reprobuild-pm issue 2026-10-27-installed-repro-profile-package-
## lookup-never-reaches-the-shipped-catalog): step 4 took the reprobuild tree
## from `currentSourcePath()`, a compile-time constant. A recipe compile
## compiles the lookup from the installed `share/repro/source`, so it was
## right there; but the home planner (`catalogPackagesFor`) and
## `repro home export` (`reachableReprobuildPackagesRoots`) run the copy
## compiled INTO the engine, and that names the release job's checkout. On a
## user's machine every catalog-only profile package was then "unknown".
## `repro disk`'s `diskoCompilerRoot` had the same flaw.
##
## How the installed engine is reproduced. This test executable plays the
## engine: it links the same lookup code, and the parent COPIES it into a
## fixture `<prefix>/bin/` and runs it as a child, so the operating system's
## own answer to "where is my image" is the anchor, as it is for the real
## `reprobuild[.exe]`. The copy's compile-time source path is this checkout,
## which the copy does not run from -- exactly the released engine's situation
## on a machine without the release job's checkout. The prefix's catalog is
## staged by `scripts/release/stage_release_catalog.sh`, the script the release
## legs run (through `stage_release_sources.sh`), from a git repository pinned
## by a fixture `.github/sibling-repos`. Every `REPROBUILD_*` variable and
## `$REPRO_PUBLIC_CLI_PATH` are removed from the child's environment and its
## working directory is outside any reprobuild tree or catalog.
##
## The fixture package name (`rpengineshippedfixture`) exists in no real
## catalog, so the catalog beside THIS checkout (a workspace sibling on a
## developer host) can never satisfy it: before the fix the copied image
## reported it missing, which this test was run to confirm.
##
## Negative controls: the same copy with the shipped catalog deleted reports
## the name missing and its search names the probed
## `<prefix>/share/repro/reprobuild-packages`; a copy in a prefix without
## `share/repro/source` consults no source-tree catalog at all (not this
## checkout's); `$REPROBUILD_PACKAGES_ROOT` naming an empty catalog still wins
## over the shipped one.
##
## Mocks: none. Real directories, a real git catalog, the real staging script,
## a real copied executable and real child processes.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

from repro_core/paths import extendedPath
from repro_core/process_streams import drainStream
from repro_core/source_root import CompiledSourceRoot, InstalledSourceRootSubdir,
  PublicCliPathEnvVar, runningImageIsUnder
import repro_project_dsl/reprobuild_packages_catalog
from repro_cli_support/disk import diskoCompilerRoot

const ChildFlag = "--installed-catalog-child"
const Fixture = "rpengineshippedfixture"
const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
const StageScript = RepoRoot / "scripts" / "release" / "stage_release_catalog.sh"

const FixtureInterface = """
import repro_project_dsl

package rpengineshippedfixture:
  provisioning:
    tarball url = "https://example.invalid/rpengineshippedfixture-1.0.zip",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip",
      executablePath = "rpengineshippedfixture",
      packageId = "rpengineshippedfixture@1.0",
      lockIdentity = "tarball:rpengineshippedfixture@1.0:sha256:0000000000000000000000000000000000000000000000000000000000000000"
"""

if paramCount() == 2 and paramStr(1) == ChildFlag:
  # The anchor the engine passes: the profile's own source file.
  let anchor = paramStr(2)
  let search = reprobuildPackagesSearch(Fixture, anchor)
  echo "MODULE=", search.module
  for root in reachableReprobuildPackagesRoots(anchor):
    echo "REACHABLE=", root
  echo "DISK_ROOT=", diskoCompilerRoot()
  echo "SEARCH-BEGIN"
  echo describeReprobuildPackagesSearch(search)
  echo "SEARCH-END"
  quit(0)

proc run(command: string; cwd: string; env: StringTableRef):
    tuple[output: string, exitCode: int] =
  execCmdEx(command, options = {poStdErrToStdOut, poUsePath},
    workingDir = cwd, env = env)

proc git(repo: string; args: varargs[string]): string =
  var command = "git -C " & quoteShell(repo)
  for arg in args:
    command.add(" " & quoteShell(arg))
  let (output, exitCode) = execCmdEx(command)
  doAssert exitCode == 0, command & "\n" & output
  output.strip()

proc scrubbedEnv(extra: openArray[(string, string)] = []): StringTableRef =
  ## The caller's environment without any variable that selects a reprobuild
  ## tree or a catalog, so only the image's location can.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    let upper = key.toUpperAscii()
    if upper.startsWith("REPROBUILD_") or upper == PublicCliPathEnvVar or
        upper == "REPRO_BOOTSTRAP_SOURCE_ENV":
      continue
    result[key] = value
  for (key, value) in extra:
    result[key] = value

proc touch(path: string) =
  createDir(path.parentDir)
  writeFile(path, "")

proc makeSourceTree(prefix: string) =
  ## The markers the source-root resolver and `diskoCompilerRoot` check under
  ## `<prefix>/share/repro/source`.
  let source = prefix / InstalledSourceRootSubdir
  touch(source / "libs" / "repro_project_dsl" / "src" / "repro_project_dsl.nim")
  createDir(source / "libs" / "repro_profile" / "src")

type ChildRun = object
  exitCode: int
  output: string
  module: string
  reachable: seq[string]
  diskRoot: string
  search: string

proc runChild(exe, cwd, anchor: string; env: StringTableRef): ChildRun =
  let p = startProcess(exe, workingDir = cwd, args = [ChildFlag, anchor],
    env = env, options = {poStdErrToStdOut})
  result.output = drainStream(p.outputStream)
  result.exitCode = p.waitForExit()
  p.close()
  var inSearch = false
  for line in result.output.splitLines():
    if line == "SEARCH-BEGIN": inSearch = true
    elif line == "SEARCH-END": inSearch = false
    elif inSearch: result.search.add(line.replace('\\', '/') & "\n")
    elif line.startsWith("MODULE="): result.module = line["MODULE=".len .. ^1]
    elif line.startsWith("REACHABLE="):
      result.reachable.add(line["REACHABLE=".len .. ^1])
    elif line.startsWith("DISK_ROOT="):
      result.diskRoot = line["DISK_ROOT=".len .. ^1]

proc copyImage(prefix: string): string =
  ## This executable, copied to `<prefix>/bin/` as an installed engine lives.
  result = prefix / "bin" / extractFilename(getAppFilename())
  createDir(result.parentDir)
  copyFile(getAppFilename(), result)
  inclFilePermissions(result, {fpUserExec})

proc slashed(path: string): string =
  ## One separator, so a path built with `/` matches one the lookup joined
  ## (`InstalledSourceRootSubdir` is spelled with `/` on every host).
  path.replace('\\', '/')

proc same(a, b: string): bool =
  ## Windows paths compare case-insensitively and with either separator.
  slashed(a).toLowerAscii() == slashed(b).toLowerAscii()

const BuildCheckoutCatalogProbe =
  slashed(CompiledSourceRoot.parentDir / "reprobuild-packages") & " ("
  ## How the search report would list the catalog beside the checkout this
  ## image was compiled in, had it been consulted.

suite "an installed engine reaches the catalog its release ships":
  let scratch = createTempDir("repro-engine-catalog-", "")
  # The child's anchor walks up from under the scratch directory (lookup step
  # 2). Inside the workspace that walk would reach the workspace's own
  # `reprobuild-packages` sibling, and no case below would test anything.
  doAssert not slashed(scratch).toLowerAscii().startsWith(
    slashed(CompiledSourceRoot.parentDir).toLowerAscii() & "/"),
    "the scratch directory " & scratch & " lies inside the workspace " &
    CompiledSourceRoot.parentDir & "; point TMPDIR/TEMP outside it"

  # The catalog repository; its one commit defines the fixture.
  let catalogRepo = scratch / "catalog-src"
  createDir(catalogRepo / "packages" / "interfaces" / Fixture)
  writeFile(catalogRepo / "packages" / "interfaces" / Fixture / "repro.nim",
    FixtureInterface)
  discard git(catalogRepo, "init", "-q")
  discard git(catalogRepo, "config", "user.email", "t@example.invalid")
  discard git(catalogRepo, "config", "user.name", "Tester")
  discard git(catalogRepo, "config", "commit.gpgsign", "false")
  discard git(catalogRepo, "add", ".")
  discard git(catalogRepo, "commit", "-q", "-m", "catalog")
  let pinned = git(catalogRepo, "rev-parse", "HEAD")

  # The release checkout the staging script runs in: it pins the catalog.
  let releaseCheckout = scratch / "release-checkout"
  createDir(releaseCheckout / ".github")
  writeFile(releaseCheckout / ".github" / "sibling-repos",
    "reprobuild-packages=" & pinned & "\n")

  # Where the child runs and what it anchors on: no reprobuild tree and no
  # `reprobuild-packages` above it.
  let elsewhere = scratch / "elsewhere"
  createDir(elsewhere / "profile")
  let anchor = elsewhere / "profile" / "home.nim"
  writeFile(anchor, "")

  proc stagePrefix(name: string; withCatalog: bool): string =
    result = scratch / name
    makeSourceTree(result)
    if withCatalog:
      let (output, exitCode) = run("bash " & quoteShell(StageScript) & " " &
        quoteShell(result), cwd = releaseCheckout,
        env = scrubbedEnv([("REPROBUILD_PACKAGES_ROOT", catalogRepo)]))
      checkpoint(output)
      doAssert exitCode == 0, output

  test "precondition: this image was built in, and runs from, a checkout " &
      "whose workspace the copies do not run from":
    # The copies below are the released engine's situation only because their
    # compile-time source path names a tree they are not under.
    check runningImageIsUnder(CompiledSourceRoot)
    check not slashed(scratch).toLowerAscii().startsWith(
      slashed(CompiledSourceRoot.parentDir).toLowerAscii() & "/")

  test "the copied engine finds the shipped catalog under its install prefix":
    let prefix = stagePrefix("reprobuild-installed", withCatalog = true)
    let shipped = prefix / "share" / "repro" / "reprobuild-packages"
    require fileExists(shipped / "packages" / "interfaces" / Fixture /
      "repro.nim")
    let r = runChild(copyImage(prefix), elsewhere, anchor, scrubbedEnv())
    checkpoint(r.output)
    check r.exitCode == 0
    check same(r.module,
      shipped / "packages" / "interfaces" / Fixture / "repro")
    var reachesShipped = false
    for root in r.reachable:
      if same(root, shipped): reachesShipped = true
    check reachesShipped
    # `repro disk` compiles a hardware.nim against the same shipped tree.
    check same(r.diskRoot, prefix / InstalledSourceRootSubdir)
    # The checkout the copy was compiled in is not consulted.
    check BuildCheckoutCatalogProbe notin r.search

  test "negative control: with the shipped catalog deleted the name is " &
      "missing, and the search names where it looked":
    let prefix = stagePrefix("reprobuild-no-catalog", withCatalog = true)
    let shipped = prefix / "share" / "repro" / "reprobuild-packages"
    removeDir(shipped)
    let r = runChild(copyImage(prefix), elsewhere, anchor, scrubbedEnv())
    checkpoint(r.output)
    check r.exitCode == 0
    check r.module == ""
    check r.reachable.len == 0
    check (slashed(shipped) & " (beside the reprobuild sources") in r.search
    check "no such directory" in r.search

  test "negative control: a prefix without share/repro/source consults no " &
      "source-tree catalog, not even the build checkout's":
    let prefix = scratch / "reprobuild-bare"
    let r = runChild(copyImage(prefix), elsewhere, anchor, scrubbedEnv())
    checkpoint(r.output)
    check r.exitCode == 0
    check r.module == ""
    check "beside the reprobuild sources" notin r.search
    check BuildCheckoutCatalogProbe notin r.search

  test "$REPROBUILD_PACKAGES_ROOT still wins over the shipped catalog":
    let prefix = stagePrefix("reprobuild-overridden", withCatalog = true)
    let empty = scratch / "empty-catalog"
    createDir(empty)
    let r = runChild(copyImage(prefix), elsewhere, anchor,
      scrubbedEnv([(ReprobuildPackagesRootEnv, empty)]))
    checkpoint(r.output)
    check r.exitCode == 0
    check r.module == ""
    check "it is set, so no other location was consulted" in r.search
    check "beside the reprobuild sources" notin r.search

  test "the engine in its build checkout still reaches the catalog beside " &
      "that checkout":
    # Not copied: this image runs from `build/test-bin` under the checkout it
    # was compiled in, as a developer's `build/bin/reprobuild` does.
    let r = runChild(getAppFilename(), elsewhere, anchor, scrubbedEnv())
    checkpoint(r.output)
    check r.exitCode == 0
    check (BuildCheckoutCatalogProbe & "beside the reprobuild sources " &
      slashed(CompiledSourceRoot) & ")") in r.search
    check same(r.diskRoot, CompiledSourceRoot)

  removeDir(scratch)
