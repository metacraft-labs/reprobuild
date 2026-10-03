## A `uses:` of a package that moved to `reprobuild-packages`, compiled with
## no catalog that defines it, is a compile error that says where the catalog
## was looked for and how to provide one.
##
## Before this diagnostic the name simply stayed unresolved: the recipe
## compiled, the tool use lost its provisioning, and the failure surfaced
## later -- or never, under PATH provisioning -- as an error that named neither
## the catalog nor the move (reprobuild-specs/Provisioning-Contributions.md,
## "Catalog Lookup And Provisioning").
##
## Each case compiles a real consumer with the real `nim check` and the real
## `package` macro; nothing is mocked. `$REPROBUILD_PACKAGES_ROOT` selects the
## catalog, because when it is set it is the only place the lookup consults --
## which is what lets this test make the catalog absent on a machine that has
## one beside this checkout. The positive control points the same variable at
## the real catalog and must compile, so a failure of the first case is the
## missing catalog and not a broken compile setup.

import std/[compilesettings, os, osproc, strtabs, strutils, tempfiles,
  unittest]

import repro_project_dsl

const CompileSearchPaths = querySettingSeq(MultipleValueSetting.searchPaths)
  ## The module search paths this test was compiled with, which are exactly
  ## what the consumer's `import repro_project_dsl` needs.

const ConsumerSource = """
import repro_project_dsl

package movedPackageDiagnosticConsumer:
  defaultToolProvisioning "tarball"
  uses:
    "sqlite3 >=3"
"""

const DependencyConsumerSource = """
import repro_project_dsl

package movedPackageDependencyConsumer:
  defaultToolProvisioning "tarball"
  nativeBuildDeps:
    "sqlite3 >=3"
"""
  ## The same moved package named in a dependency list. The catalog is
  ## consulted for `nativeBuildDeps:` and `runtimeDeps:` as for `uses:`, so an
  ## unreachable catalog must be the same named error there, not a silent loss
  ## of the dependency's provisioning.

proc nimCheck(consumer, catalogRoot: string): tuple[output: string,
    exitCode: int] =
  var parts = @[findExe("nim").quoteShell, "check", "--hints:off",
    "--warnings:off", ("--nimcache:" & consumer.parentDir / "nimcache").quoteShell]
  for path in CompileSearchPaths:
    parts.add(("--path:" & path).quoteShell)
  parts.add(consumer.quoteShell)
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env[ReprobuildPackagesRootEnv] = catalogRoot
  # `execCmdEx`, not a hand-read `startProcess` pipe: on Windows a stream
  # `readAll` over the child's pipe stops at the first short read and returns
  # only the first line of the compiler's output.
  execCmdEx(parts.join(" "), options = {poStdErrToStdOut}, env = env)

proc realCatalogRoot(): string =
  let search = reprobuildPackagesSearch("sqlite3", currentSourcePath())
  if search.module.len == 0:
    raise newException(IOError,
      "no reprobuild-packages catalog defining sqlite3 is reachable from " &
      currentSourcePath() & ", so the positive control cannot run:\n" &
      describeReprobuildPackagesSearch(search) & "\n" &
      reprobuildPackagesRemedy())
  search.module.parentDir.parentDir.parentDir.parentDir

suite "a moved package with no catalog is a named compile error":
  let scratch = createTempDir("repro-moved-package-", "")
  let consumer = scratch / "consumer.nim"
  writeFile(consumer, ConsumerSource)

  test "no catalog: the error names the package, the places searched, and the remedy":
    let emptyCatalog = scratch / "empty-catalog"
    createDir(emptyCatalog)
    let (output, exitCode) = nimCheck(consumer, emptyCatalog)
    checkpoint(output)
    check exitCode != 0
    check "uses: \"sqlite3 >=3\" names `sqlite3`" in output
    check "no longer bundled with reprobuild's stdlib" in output
    check "packages/interfaces/sqlite3/repro.nim" in output
    check emptyCatalog in output
    check "it is set, so no other location was consulted" in output
    check "Provide the catalog" in output
    check ReprobuildPackagesRepositoryUrl in output
    check ".github/sibling-repos" in output

  test "a catalog path that does not exist is reported as such":
    let missing = scratch / "no-such-catalog"
    let (output, exitCode) = nimCheck(consumer, missing)
    checkpoint(output)
    check exitCode != 0
    check (missing & " ($" & ReprobuildPackagesRootEnv &
      "): no such directory") in output

  test "a dependency list naming a moved package gets the same error":
    let dependencyConsumer = scratch / "dependency_consumer.nim"
    writeFile(dependencyConsumer, DependencyConsumerSource)
    let emptyCatalog = scratch / "empty-catalog-deps"
    createDir(emptyCatalog)
    let (output, exitCode) = nimCheck(dependencyConsumer, emptyCatalog)
    checkpoint(output)
    check exitCode != 0
    check "nativeBuildDeps: \"sqlite3 >=3\" names `sqlite3`" in output
    check "no longer bundled with reprobuild's stdlib" in output
    check emptyCatalog in output
    check "Provide the catalog" in output

  test "positive control: the real catalog compiles the dependency consumer":
    let dependencyConsumer = scratch / "dependency_consumer.nim"
    writeFile(dependencyConsumer, DependencyConsumerSource)
    let (output, exitCode) = nimCheck(dependencyConsumer, realCatalogRoot())
    checkpoint(output)
    check exitCode == 0

  test "positive control: the real catalog compiles the same consumer":
    let (output, exitCode) = nimCheck(consumer, realCatalogRoot())
    checkpoint(output)
    check exitCode == 0

  removeDir(scratch)
