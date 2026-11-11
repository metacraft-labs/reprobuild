## ``repro clean`` removes the outputs the project's build state owns, and
## nothing else.
##
## The verb works from ownership records, not from a directory sweep: every
## declared action output is an owned-effect claim in the provider-graph
## snapshot a build persists, and ``repro clean`` deletes exactly those
## claimed paths. So this test spawns the built ``repro`` binary against a
## real fixture project and checks both sides of that line:
##
##   * the declared output is gone after ``repro clean``, and ``--dry-run``
##     lists it without removing it;
##   * a file the user placed under the project, the project's sources, a file
##     under ``.repro/stats/`` and the provider-graph snapshot all survive.
##     ``.repro/`` also holds state the next build reuses, which is why a
##     blanket ``rm -rf .repro/`` is not a clean;
##   * the action cache survives too: the next ``--restore-cached-outputs``
##     build is an action-cache hit that restores the bytes rather than
##     re-executing the action.
##
## The fixture's one edge is ``fs.copyFile``, as in the S7 restore test: its
## declared output is the whole of its product, so the restore gate admits it
## and the fixture needs no toolchain beyond the provider compile the CLI does
## for any recipe. No mocks: the binary, the filesystem and the action cache
## are the real components under test.

import std/[json, os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip

const reproBinary =
  when defined(windows): "build/bin/repro.exe" else: "build/bin/repro"

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc q(value: string): string = quoteShell(value)

const PayloadBytes = "payload-bytes\n"

proc writeFixture(projRoot: string) =
  createDir(projRoot / "src")
  writeFile(projRoot / "src" / "payload.txt", PayloadBytes)
  writeFile(projRoot / "repro.nim", """
import repro_dsl_stdlib

package cleandemo:
  defaultToolProvisioning "path"
  build:
    let acts = @[fs.copyFile("src/payload.txt", "build/out/payload.txt",
      actionId = "copy_payload")]
    target("copy_payload", acts)
""")

type ActionOutcome = object
  found: bool
  status: string
  cacheDecision: string
  reason: string
  launched: bool

proc readOutcome(reportPath, actionId: string): ActionOutcome =
  let report = parseFile(reportPath)
  if not report.hasKey("actions"):
    return
  for item in report["actions"]:
    if item{"id"}.getStr() != actionId:
      continue
    return ActionOutcome(
      found: true,
      status: item{"status"}.getStr(),
      cacheDecision: item{"cacheDecision"}.getStr(),
      reason: item{"reason"}.getStr(),
      launched: item{"launched"}.getBool())

proc snapshotFiles(projRoot: string): seq[string] =
  ## The provider-graph snapshots the builds persisted: the ownership records
  ## ``repro clean`` reads, which it must leave in place.
  let buildRoot = projRoot / ".repro" / "build"
  if not dirExists(buildRoot):
    return
  for path in walkDirRec(buildRoot, yieldFilter = {pcFile}):
    if path.extractFilename == "provider-fragments.rbsz":
      result.add(path)

suite "repro clean":

  test "t_repro_clean_removes_owned_outputs_and_keeps_caches":
    let repoRoot = findRepoRoot()
    let reproAbs = repoRoot / reproBinary
    if not fileExists(reproAbs):
      skip("build/bin/repro not built; this case spawns the repro binary " &
        "(run `just build` first)")
    else:
      let scratch = getTempDir() / "t_repro_clean-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      let projRoot = scratch / "proj"
      let cacheRoot = scratch / "action-cache"
      writeFixture(projRoot)
      let outputPath = projRoot / "build" / "out" / "payload.txt"

      proc buildOnce(reportPath: string): tuple[code: int; output: string] =
        # ``--restore-cached-outputs`` stores payload-backed records, so the
        # build after the clean CAN be a cache hit; without it the default
        # in-place build keeps metadata-only records and would re-execute
        # whatever the clean removed. ``--no-runquota`` and ``--daemon=off``
        # keep the run in this process tree.
        let cmd = q(reproAbs) & " build " & q(projRoot / "repro.nim") &
          " --tool-provisioning=path --daemon=off --no-runquota" &
          " --log=quiet --progress=quiet --measure=none" &
          " --action-cache-root=" & q(cacheRoot) &
          " --restore-cached-outputs" &
          " --write-report=" & q(reportPath)
        let res = execCmdEx(cmd, workingDir = repoRoot)
        (code: res.exitCode, output: res.output)

      proc cleanOnce(extra = ""): tuple[code: int; output: string] =
        # Run from inside the project, the way a user types it, so the
        # default project root (the current directory) is what is exercised.
        let res = execCmdEx(q(reproAbs) & " clean" & extra,
          workingDir = projRoot)
        (code: res.exitCode, output: res.output)

      let (code1, out1) = buildOnce(scratch / "build1.json")
      checkpoint(out1)
      check code1 == 0
      check fileExists(outputPath)
      let snapshotsBefore = snapshotFiles(projRoot)
      check snapshotsBefore.len > 0

      # Content the clean does not own: a user's file beside the recipe, one
      # inside the output's own directory tree's parent, and one under the
      # derived stats store's root.
      let userNote = projRoot / "notes.txt"
      writeFile(userNote, "mine\n")
      let userBesideOutput = projRoot / "build" / "README.txt"
      createDir(userBesideOutput.parentDir)
      writeFile(userBesideOutput, "also mine\n")
      let statsFile = projRoot / ".repro" / "stats" / "keep.txt"
      createDir(statsFile.parentDir)
      writeFile(statsFile, "stats\n")

      # --dry-run lists the output and removes nothing.
      let (codeDry, outDry) = cleanOnce(" --dry-run")
      checkpoint(outDry)
      check codeDry == 0
      check ("would remove " & outputPath) in outDry
      check fileExists(outputPath)

      let (code2, out2) = cleanOnce()
      checkpoint(out2)
      check code2 == 0
      check ("removed " & outputPath) in out2
      check not fileExists(outputPath)

      check readFile(userNote) == "mine\n"
      check readFile(userBesideOutput) == "also mine\n"
      check readFile(statsFile) == "stats\n"
      check readFile(projRoot / "src" / "payload.txt") == PayloadBytes
      check fileExists(projRoot / "repro.nim")
      for snapshot in snapshotsBefore:
        check fileExists(snapshot)

      # A second clean finds nothing left to remove and still succeeds.
      let (code3, out3) = cleanOnce()
      checkpoint(out3)
      check code3 == 0
      check "repro clean: removed 0 output(s)" in out3

      # The action cache survived: the next build restores the output from
      # it instead of running the action again.
      let (code4, out4) = buildOnce(scratch / "build2.json")
      checkpoint(out4)
      check code4 == 0
      let after = readOutcome(scratch / "build2.json", "copy_payload")
      check after.found
      check after.status == "asCacheHit"
      check after.cacheDecision == "cdHit"
      check after.reason == "restored"
      check not after.launched
      check fileExists(outputPath)
      check readFile(outputPath) == PayloadBytes

  test "t_repro_clean_rejects_an_unknown_argument":
    let repoRoot = findRepoRoot()
    let reproAbs = repoRoot / reproBinary
    if not fileExists(reproAbs):
      skip("build/bin/repro not built; this case spawns the repro binary " &
        "(run `just build` first)")
    else:
      let res = execCmdEx(q(reproAbs) & " clean --everything")
      checkpoint(res.output)
      check res.exitCode == 2
      check "unsupported argument: --everything" in res.output
