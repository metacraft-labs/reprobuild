## Deferred Item D2: ``<pkg>:<target>`` cross-project selector recognised.
##
## Two arms:
##
## 1. **Structural.** Read the CLI target-resolver source and assert it
##    contains the sibling-discovery codepath. This guards against
##    accidental removal of the cross-project recognition path even on
##    hosts where no sibling checkout exists to drive a behavioural
##    test.
##
## 2. **Behavioural**. Resolve the declared ``runquota`` workspace member
##    (including from a linked reprobuild worktree), then run
##    ``./build/bin/repro build runquota:runquotad --tool-provisioning=path
##    --daemon=off`` and assert it succeeds: no usage dump, exit 0, and
##    the sibling's ``../runquota/build/bin/runquotad`` artifact present
##    and non-empty afterwards.
##
##    ``looksLikeUsageDump`` is an ASSERTION here, not a classifier: it
##    fires ``check not …`` to name the specific pre-D2 regression shape,
##    and it can only ever turn a green into a red. It never reclassifies
##    a failure into a skip, and it does not stand in for the exit-code
##    assertion, which is made unconditionally. The arm that used to
##    accept any non-zero exit "as long as it isn't a usage dump" is
##    gone — under it, a selector that resolved and then built nothing was
##    indistinguishable from one that worked.
##
## The B0 ``t_b0_repro_build_runquota_daemon`` test already covers the
## end-to-end "binary is executable and responds to ``--version``"
## assertion; D2's job here is the structural-guard half so the
## resolver doesn't silently regress to the pre-D2 "usage dump" shape.

import std/[os, osproc, strutils, unittest]

import repro_test_support

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc looksLikeUsageDump(output: string): bool =
  ## The pre-D2 failure shape: the CLI's top-level dispatcher prints the
  ## full usage banner when it can't decode the command. These needles
  ## appear in every usage dump but not in legitimate engine diagnostics.
  for needle in [
    "usage: repro --version",
    "repro build [target[#name]",
    "repro graph [target[#name]",
    "repro show-conventions [--project=PATH]",
  ]:
    if needle in output:
      return true
  return false

suite "Deferred Item D2: <pkg>:<target> cross-project selector recognised":

  test "CLI resolver source contains sibling-discovery codepath":
    let reprobuildRoot = findRepoRoot()
    let resolverSource = reprobuildRoot / "libs" / "repro_cli_support" /
      "src" / "repro_cli_support.nim"
    check fileExists(resolverSource)

    # NON-VACUITY FIXTURE FOR THE TWO HELPERS THIS CASE RESTS ON.
    #
    # Without it, a stripper that returned the empty string and a counter
    # that always returned a large number would both leave the assertions
    # below green while measuring nothing — the "audit that always counts
    # zero" the campaign has already been bitten by once. The fixture spells
    # one instance of every bypass the review found, so this case reddens if
    # any of them stops being seen.
    const CounterFixture = """
proc findSiblingProjectFile*(name: string): string = ""   # definition
let a = findSiblingProjectFile(name)                      # f(a)
let b = root.findSiblingProjectFile(name)                 # a.f(b)
let c = find_sibling_project_file(name)                   # folded spelling
let d = root.findSiblingProjectFile name                  # command syntax
let e = myFindSiblingProjectFileHelper(name)              # NOT this one
echo "findSiblingProjectFile"                             # NOT a literal
# findSiblingProjectFile                                  # NOT a comment
"""
    let fixtureCode = nimSourceCodeOnly(CounterFixture)
    check countNimIdentifier(fixtureCode, "findSiblingProjectFile") == 5
    check countNimIdentifier(CounterFixture, "findSiblingProjectFile") == 7
    check countNimIdentifier(fixtureCode, "noSuchHelperAnywhere") == 0
    check countNimIdentifier(fixtureCode, "myFindSiblingProjectFileHelper") == 1

    # COMPUTED OVER CODE, NOT OVER PROSE — mode: CODE ONLY (comments AND
    # literals blanked). The needle is an identifier, which is always a code
    # spelling, and an identifier is exactly what a ``checkpoint`` string or
    # a doc comment can also contain.
    #
    # MEASURED (DA-8), and this one was LIVE rather than prospective: the
    # ``findSiblingProjectFile`` DEFINITION and ALL FIVE of its call sites
    # were renamed away, and this case stayed GREEN — the CLI carries three
    # ``##``/``#`` mentions of the name today, which satisfied both the
    # presence check and the ``>= 2`` count on their own. The comment that
    # used to sit here claimed the audit "cannot accidentally remove the
    # cross-project recognition"; removing it was precisely what it could not
    # see.
    let code = nimSourceCodeOnly(readFile(resolverSource))

    # COUNTED AS A WHOLE IDENTIFIER, FOLDED THE WAY NIM FOLDS IDENTIFIERS.
    # Stripping comments alone is necessary and not sufficient: a substring
    # count of ``"findSiblingProjectFile("`` is defeated by
    # ``root.findSiblingProjectFile selector`` (Nim has four call spellings
    # and only two carry a paren) and by ``find_sibling_project_file(...)``
    # (identifiers are case- and underscore-insensitive after the first
    # character). ``countNimIdentifier`` sees all of those and does not see a
    # longer name that merely contains this one.
    let mentions = countNimIdentifier(code, "findSiblingProjectFile")
    checkpoint "whole-identifier uses in code: " & $mentions

    # The helper must be DEFINED here, not merely named. Graded separately
    # from the count so "the proc is gone and something else spells its name"
    # cannot pass as "the proc is here".
    check "proc findSiblingProjectFile*(" in code

    # The qualified-selector arm must reach the sibling-discovery helper.
    # Without a call site the recognition path is dead code. The definition
    # accounts for one occurrence, so N call sites means N + 1 identifiers.
    check mentions >= 3

    # DELIBERATELY OVER RAW TEXT, and not part of the soundness argument
    # above: the feature tag lives only in the implementation comments, so
    # blanking comments would delete its subject. Kept apart from the code
    # assertions so it is never mistaken for one.
    check ("D2" in readFile(resolverSource))

  test "engine accepts runquota:runquotad without a usage dump":
    let reprobuildRoot = findRepoRoot()
    let runquotaCheckout = requireRunQuotaSourceRoot(reprobuildRoot)
    let reproBin = reprobuildRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    else:
      let runquotadBinary = runquotaCheckout / "build" / "bin" /
        addFileExt("runquotad", ExeExt)
      # Remove any stale artifact so the post-invocation check
      # measures whether THIS run produced the binary.
      if fileExists(runquotadBinary):
        removeFile(runquotadBinary)

      let args = @[
        reproBin.quoteShell,
        "build",
        "runquota:runquotad",
        "--tool-provisioning=path",
        "--daemon=off",
      ]
      let cmd = args.join(" ")
      checkpoint("running: " & cmd)
      let (output, exitCode) =
        execCmdEx(cmd, workingDir = reprobuildRoot)
      checkpoint("exit=" & $exitCode)
      # The pre-D2 failure shape, named first because it gives the
      # sharpest diagnosis: a usage dump means the CLI REJECTED
      # ``runquota:runquotad`` rather than resolving it.
      if looksLikeUsageDump(output) or exitCode != 0:
        checkpoint(output)
      check not looksLikeUsageDump(output)
      # And the build itself. Tolerating a non-zero exit here — the
      # former "MVP arm" — meant the only thing this case could ever
      # detect was the usage dump: a selector that resolved and then
      # failed to build anything reported exactly the same green as one
      # that built the sibling. D2's contract is that the qualified
      # selector reaches the sibling project and BUILDS it, so that is
      # what is asserted.
      check exitCode == 0
      if exitCode == 0:
        check fileExists(runquotadBinary)
        if fileExists(runquotadBinary):
          check getFileInfo(runquotadBinary).size > 0
