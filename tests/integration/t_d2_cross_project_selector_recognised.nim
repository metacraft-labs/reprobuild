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
## 2. **Behavioural** (skip-when-absent). When the sibling ``../runquota``
##    checkout AND ``./build/bin/repro`` are both present, run
##    ``./build/bin/repro build runquota:runquotad --tool-provisioning=path
##    --daemon=off`` and assert the invocation exits cleanly (no usage
##    dump). When exit code is 0, additionally assert the sibling's
##    ``../runquota/build/bin/runquotad`` artifact materialises.
##
## The B0 ``t_b0_repro_build_runquota_daemon`` test already covers the
## end-to-end "binary is executable and responds to ``--version``"
## assertion; D2's job here is the structural-guard half so the
## resolver doesn't silently regress to the pre-D2 "usage dump" shape.

import std/[os, osproc, strutils, unittest]

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

proc runquotaRoot(reprobuildRoot: string): string =
  reprobuildRoot.parentDir / "runquota"

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
    let body = readFile(resolverSource)
    # Structural guards — at least one of each must be present so a
    # future refactor can rename internals without breaking the test,
    # but cannot accidentally remove the cross-project recognition.
    check ("findSiblingProjectFile" in body)
    check ("D2" in body) # The implementation comments tag the feature.
    # The qualified-selector arm must reach the sibling-discovery
    # helper. Without this call site the recognition path is dead.
    # One call site (in ``parseAndResolveSelectors``) plus the proc
    # definition itself == 2 occurrences of ``findSiblingProjectFile``.
    check body.count("findSiblingProjectFile") >= 2

  test "engine accepts runquota:runquotad without a usage dump":
    let reprobuildRoot = findRepoRoot()
    let runquotaCheckout = runquotaRoot(reprobuildRoot)
    if not dirExists(runquotaCheckout):
      checkpoint("skipped — " & runquotaCheckout &
        " is missing (sibling runquota repo not present)")
      skip()
    else:
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
        # The pre-D2 failure shape: CLI rejection with usage dump. Even
        # when the run can't complete (tool-resolution / nim missing /
        # libclingo issues), the selector must NOT trigger a usage
        # dump — that's the D2 contract.
        check not looksLikeUsageDump(output)
        if exitCode == 0:
          # Stretch behavioural check — when the build actually
          # completed, the sibling artifact must exist.
          check fileExists(runquotadBinary)
          if fileExists(runquotadBinary):
            check getFileInfo(runquotadBinary).size > 0
        else:
          # MVP arm — exit code != 0 is acceptable as long as it's not
          # the pre-D2 usage-dump shape. Surface the output for triage.
          checkpoint(output)
