## A recipe that imports the stdlib module of a package that moved to
## `reprobuild-packages` gets a compile error that names the new home and the
## remedy, not "cannot open file".
##
## reprobuild-specs issues/2026-09-30-moving-a-package-out-of-the-stdlib-
## breaks-recipes-that-import-it.md: agent-harbor's `repro.nim` imports
## `repro_dsl_stdlib/packages/prek` and `.../shfmt` by path. When those
## modules were deleted the recipe stopped with "cannot open file", which
## names neither the move nor what to do. Each moved module now leaves a
## one-release stub (`MovedPackageImportStubs`) that fails with the remedy.
##
## The stub must not change what a `uses:` line does: it is not a package
## definition and not on the bundled selector list, so `uses: "<name>"` still
## reaches the catalog. The positive control proves that with the real
## catalog.
##
## Every case compiles a real consumer with the real `nim check`; nothing is
## mocked. `$REPROBUILD_PACKAGES_ROOT` selects the catalog because, when set,
## it is the only place the lookup consults.

import std/[compilesettings, os, osproc, strtabs, strutils, tempfiles,
  unittest]

import repro_project_dsl

const CompileSearchPaths = querySettingSeq(MultipleValueSetting.searchPaths)
  ## The module search paths this test was compiled with, which are exactly
  ## what the consumer's imports need.

const StdlibPackagesDir = currentSourcePath().parentDir.parentDir.parentDir /
  "libs" / "repro_dsl_stdlib" / "src" / "repro_dsl_stdlib" / "packages"

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
  # `readAll` over the child's pipe stops at the first short read.
  execCmdEx(parts.join(" "), options = {poStdErrToStdOut}, env = env)

proc realCatalogRoot(selector: string): string =
  let search = reprobuildPackagesSearch(selector, currentSourcePath())
  if search.module.len == 0:
    raise newException(IOError,
      "no reprobuild-packages catalog defining " & selector &
      " is reachable from " & currentSourcePath() &
      ", so the positive control cannot run:\n" &
      describeReprobuildPackagesSearch(search) & "\n" &
      reprobuildPackagesRemedy())
  search.module.parentDir.parentDir.parentDir.parentDir

suite "importing a moved stdlib module names the new home":
  let scratch = createTempDir("repro-moved-module-import-", "")

  test "every stub is a moved package, and none is a package definition":
    check MovedPackageImportStubs.len > 0
    for name in MovedPackageImportStubs:
      checkpoint name
      check name in MovedToReprobuildPackages
      let stub = StdlibPackagesDir / (name & ".nim")
      check fileExists(stub)
      if fileExists(stub):
        let text = readFile(stub)
        check "package " & name & ":" notin text
        check "{.error:" in text

  for name in MovedPackageImportStubs:
    test "a direct import of repro_dsl_stdlib/packages/" & name &
        " fails with the remedy":
      let consumer = scratch / ("imports_" & name & ".nim")
      writeFile(consumer, "import repro_project_dsl\n" &
        "import repro_dsl_stdlib/packages/" & name & "\n\n" &
        "package movedModuleImporter:\n" &
        "  uses:\n" &
        "    \"" & name & "\"\n")
      let (output, exitCode) = nimCheck(consumer, realCatalogRoot(name))
      checkpoint(output)
      check exitCode != 0
      check ("repro_dsl_stdlib/packages/" & name &
        " moved to reprobuild-packages") in output
      check ("packages/interfaces/" & name & "/repro.nim") in output
      check ("drop the import and rely on uses: \"" & name & "\"") in output
      check "cannot open file" notin output

    test "positive control: uses: \"" & name &
        "\" without the import still resolves from the catalog":
      let consumer = scratch / ("uses_" & name & ".nim")
      writeFile(consumer, "import repro_project_dsl\n\n" &
        "package movedModuleUser:\n" &
        "  uses:\n" &
        "    \"" & name & "\"\n")
      let (output, exitCode) = nimCheck(consumer, realCatalogRoot(name))
      checkpoint(output)
      check exitCode == 0

  removeDir(scratch)
