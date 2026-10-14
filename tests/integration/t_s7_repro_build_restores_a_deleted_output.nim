## S7 — a real ``repro build`` stores output blobs and restores a deleted
## output, and the same build without the flag does neither.
##
## This is the end-to-end half of S7. The engine could already restore — S5
## proved that at the ``runBuild`` level — but no ``repro build`` invocation
## could reach the configuration that does, so the property had no
## user-visible effect. Every one of the CLI's ``BuildEngineConfig``
## constructions hard-coded ``rebuildMissingOutputsOnCacheHit: true``, and
## six of seven also hard-coded ``deferLocalOutputBlobs: true``. Measured
## consequence on the reference host: all 181 published records were
## ``opkMetadataOnly`` with ``blobSize = 0``, and a clean checkout with a
## fully warm cache rebuilt everything.
##
## So this test spawns the built ``repro`` binary rather than calling the
## engine, and it asserts on both halves of the switch:
##
##   * WITH ``--restore-cached-outputs``: the CAS under the run's own
##     ``--action-cache-root`` gains the edge's output bytes, and after the materialized
##     output is deleted the next build reports ``asCacheHit`` / ``cdHit``
##     / ``reason=restored`` with the bytes back on disk.
##   * WITHOUT it: the CAS does not hold them (metadata-only records), and the
##     next build after the same deletion RE-RUNS the action.
##
## The negative half is not decoration. A test that only asserted the
## restore would pass equally well against a build that stored blobs
## unconditionally — which is the change S7 explicitly refused to make,
## because on a filesystem without working block cloning every stored
## artefact is a second full copy of the build tree (measured on this host:
## NTFS 3 761 037 312 bytes of volume for 3 758 227 776 bytes of logical
## data, against ReFS's 528 515 072 for the same set).
##
## The fixture's one edge is ``fs.copyFile``. That is deliberate: its
## declared output is the whole of its product, so it is exactly the shape
## the engine's restore gate is meant to admit, and it needs no toolchain
## beyond the provider compile the CLI does for any recipe.

import std/[json, os, osproc, strutils, unittest]

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

proc casHoldsPayload(actionCacheRoot: string): bool =
  ## Whether the run's CAS holds the fixture edge's OWN output bytes.
  ##
  ## Not "whether the CAS holds any blob": the recipe-relative interface
  ## extraction the CLI runs for every recipe stores its outputs' payloads in
  ## the same CAS whatever this flag says (its output directory is shared by
  ## records of different observed environments, so a record has to be able
  ## to restore its own bytes there — reprobuild-specs issues/2026-10-12-
  ## interface-extraction-variants-of-one-recipe-overwrite-each-others-
  ## outputs.md). A blob count then reads > 0 in both halves, which made the
  ## positive half vacuous and the negative half wrong. What this test is
  ## about is the BUILD edge's payload, and the CAS stores blobs raw, so look
  ## for its bytes.
  let blobs = actionCacheRoot / "cas" / "blake3"
  if not dirExists(blobs):
    return false
  for path in walkDirRec(blobs, yieldFilter = {pcFile}):
    if getFileSize(path) == PayloadBytes.len and readFile(path) == PayloadBytes:
      return true

proc writeFixture(projRoot: string) =
  createDir(projRoot / "src")
  writeFile(projRoot / "src" / "payload.txt", PayloadBytes)
  writeFile(projRoot / "repro.nim", """
import repro_dsl_stdlib

package s7demo:
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

suite "S7 repro build reaches the CAS-restore configuration":

  test "t_s7_repro_build_restores_a_deleted_output":
    let repoRoot = findRepoRoot()
    let reproAbs = repoRoot / reproBinary
    if not fileExists(reproAbs):
      checkpoint("skipped — repro binary not built")
      skip()
    else:
      let scratch = getTempDir() / "t_s7_restore-" & $getCurrentProcessId()
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      proc buildOnce(projRoot, cacheRoot, reportPath: string;
                     restore: bool): tuple[code: int; output: string] =
        var cmd = q(reproAbs) & " build " & q(projRoot / "repro.nim") &
          " --tool-provisioning=path --daemon=off --no-runquota" &
          " --log=quiet --progress=quiet --measure=none" &
          " --action-cache-root=" & q(cacheRoot) &
          " --write-report=" & q(reportPath)
        if restore:
          cmd.add(" --restore-cached-outputs")
        # ``--no-runquota`` and ``--daemon=off`` keep the run in this
        # process tree: a daemon-hosted build would run under the
        # environment the daemon was started with, which is a different
        # question from the one this test asks.
        let res = execCmdEx(cmd, workingDir = repoRoot)
        (code: res.exitCode, output: res.output)

      # ------------------------------------------------------------------
      # WITH the flag: blobs stored, deleted output restored.
      # ------------------------------------------------------------------
      let onProj = scratch / "on"
      let onCache = scratch / "cache-on"
      writeFixture(onProj)
      let outputPath = onProj / "build" / "out" / "payload.txt"

      let (code1, out1) = buildOnce(onProj, onCache, scratch / "on1.json",
        restore = true)
      checkpoint(out1)
      check code1 == 0
      check fileExists(outputPath)
      # Nothing to restore FROM unless the payload is in the CAS. This is
      # the assertion that failed for all 181 records before S7.
      check casHoldsPayload(onCache)

      removeFile(outputPath)
      check not fileExists(outputPath)

      let (code2, out2) = buildOnce(onProj, onCache, scratch / "on2.json",
        restore = true)
      checkpoint(out2)
      check code2 == 0
      let restored = readOutcome(scratch / "on2.json", "copy_payload")
      check restored.found
      check restored.status == "asCacheHit"
      check restored.cacheDecision == "cdHit"
      check restored.reason == "restored"
      check not restored.launched
      # A status flag is not a restore. The bytes are.
      check fileExists(outputPath)
      check readFile(outputPath) == "payload-bytes\n"

      # ------------------------------------------------------------------
      # WITHOUT the flag: no payloads, and the same deletion re-runs.
      # ------------------------------------------------------------------
      let offProj = scratch / "off"
      let offCache = scratch / "cache-off"
      writeFixture(offProj)
      let offOutput = offProj / "build" / "out" / "payload.txt"

      let (code3, out3) = buildOnce(offProj, offCache, scratch / "off1.json",
        restore = false)
      checkpoint(out3)
      check code3 == 0
      check fileExists(offOutput)
      check not casHoldsPayload(offCache)

      removeFile(offOutput)
      let (code4, out4) = buildOnce(offProj, offCache, scratch / "off2.json",
        restore = false)
      checkpoint(out4)
      check code4 == 0
      let rerun = readOutcome(scratch / "off2.json", "copy_payload")
      check rerun.found
      check rerun.cacheDecision == "cdMiss"
      check rerun.launched
      check fileExists(offOutput)
