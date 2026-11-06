## A consumer's interface extraction records nothing that names where the
## consumer lies, or what an earlier run left in the temporary directory —
## Hermetic-Builds-And-Path-Independence.md §"Per-computation output
## directories", location-free generated files (owner decision 2026-11-03).
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The test drives the real ``build/bin/repro`` binary as a subprocess against
## real recipes in real temporary directories, with real Nim compiles, a real
## action cache and a real store.
##
## The defect, as measured 2026-11-03 at reprobuild ``32361e5639``
## (reprobuild-pm issue 2026-10-14-sibling-import-shims-in-tmpdir-make-
## consumer-recipe-compiles-miss-every-run.md): a recipe that consumes a
## workspace sibling through ``uses:`` is compiled through one generated shim
## per sibling (``usesImportCode``). The extraction wrote them under the real
## ``$TMPDIR/repro-sibling-shims/c_<FNV of the consumer's absolute path>_…/``
## and recorded them as inputs, so the same recipe bytes at another absolute
## location, or the same location after the temporary directory was wiped,
## could never be served from the cache.
##
## Here one workspace (a consumer and the sibling it ``uses:``) exists at two
## absolute locations. It is built at the first, then at the second, then at
## the first again, and ``TMPDIR`` is deleted and recreated empty before each
## later build, as ``scripts/run_tests.sh`` does at the start of every run.
## Each later build must be served by the first build's interface
## computation: no new computation directory appears under
## ``recipe-compiles/interface/``. The shim itself must sit in the
## computation's own scratch, named by selector, with nothing under
## ``TMPDIR``.
##
## ``TMPDIR`` keeps its PATH across the builds, as the runner's per-checkout
## slot does. Its path is still observed (the C compiler probes it, measured
## 2026-11-04: a different ``TMPDIR`` path is a different computation), which
## is not what this test is about.
##
## Out-of-band corroboration: "served" is read from the action cache's
## directory tree, not from the CLI's own report.

import std/[algorithm, os, osproc, strtabs, strutils, unittest]

const ProducerName = "locfreeprod"

const ProducerSource = """
import repro_project_dsl

package locfreeprod:
  build:
    discard
"""

const ConsumerSource = """
import repro_project_dsl

package locfreeconsumer:
  uses:
    "locfreeprod"
  build:
    discard
"""

proc reproBinary(repoRoot: string): string =
  repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)

proc runBuildCli(reproBin, projectRoot, actionCacheRoot, tmpDir: string):
    tuple[output: string; exitCode: int] =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  for name in ["TMPDIR", "TMP", "TEMP"]:
    env[name] = tmpDir
  let res = execCmdEx(quoteShellCommand([
    reproBin, "build",
    "--daemon=off",
    "--tool-provisioning=path",
    "--action-cache-root=" & actionCacheRoot,
    "--progress=quiet",
    "--log=actions",
    projectRoot / "repro.nim"]), env = env)
  (output: res.output, exitCode: res.exitCode)

proc computationDirs(actionCacheRoot, kind: string): seq[string] =
  ## Every computation directory of every identity of `kind`: the
  ## directories under `<identity>/` other than `staging/`.
  let root = actionCacheRoot / "recipe-compiles" / kind
  if not dirExists(root):
    return
  for identityKind, identity in walkDir(root):
    if identityKind != pcDir:
      continue
    for entryKind, entry in walkDir(identity):
      if entryKind == pcDir and extractFilename(entry) != "staging":
        result.add(entry)
  result.sort()

proc shimsUnder(dir: string): seq[string] =
  if not dirExists(dir):
    return
  for path in walkDirRec(dir):
    if extractFilename(path).startsWith("repro_sib_"):
      result.add(path)
  result.sort()

proc writeWorkspace(wsRoot: string) =
  createDir(wsRoot / ProducerName)
  writeFile(wsRoot / ProducerName / "repro.nim", ProducerSource)
  createDir(wsRoot / "consumer")
  writeFile(wsRoot / "consumer" / "repro.nim", ConsumerSource)

suite "interface extraction sibling shims are location-free":

  test "the same recipe at another path, after a TMPDIR wipe, is served from the cache":
    let repoRoot = getCurrentDir()
    let reproBin = reproBinary(repoRoot)
    if not fileExists(reproBin):
      # Never a silent pass: without the real CLI this test says nothing.
      checkpoint("missing " & reproBin & "; run `just build` first")
      fail()
    else:
      # A short root: the provider compile's argv is part of its key.
      let tempRoot = "/tmp/rb-locfree-" & $getCurrentProcessId()
      # Everything a build writes lies OUTSIDE `tempRoot`, which is an
      # ancestor of both workspaces: the compiles observe its listing, so an
      # entry appearing there between builds would be a new computation.
      let actionCacheRoot = tempRoot & "-ac"
      let tmpDir = tempRoot & "-tmp"
      for dir in [tempRoot, actionCacheRoot, tmpDir]:
        removeDir(dir)
      defer:
        for dir in [tempRoot, actionCacheRoot, tmpDir]:
          removeDir(dir)
      createDir(actionCacheRoot)
      # Both locations exist before the first build, for the same reason.
      let wsA = tempRoot / "a" / "ws"
      let wsB = tempRoot / "b" / "ws"
      writeWorkspace(wsA)
      writeWorkspace(wsB)

      # --- Location A: cold. ---------------------------------------------
      createDir(tmpDir)
      let a1 = runBuildCli(reproBin, wsA / "consumer", actionCacheRoot,
        tmpDir)
      if a1.exitCode != 0: checkpoint(a1.output)
      check a1.exitCode == 0
      let afterA = computationDirs(actionCacheRoot, "interface")
      checkpoint("after A: " & $afterA)
      check afterA.len >= 1
      # The consumer's shim is in its computation's own scratch, named by
      # selector, and includes the sibling it resolved.
      var consumerShims: seq[string] = @[]
      for dir in afterA:
        consumerShims.add(shimsUnder(dir))
      checkpoint("shims after A: " & $consumerShims)
      check consumerShims.len == 1
      if consumerShims.len == 1:
        check extractFilename(consumerShims[0]) ==
          "repro_sib_" & ProducerName & ".nim"
        check extractFilename(parentDir(consumerShims[0])) == "sibling-shims"
        check (wsA / ProducerName / "repro.nim") in readFile(consumerShims[0])
      # Nothing under the temporary directory: the location-keyed directory
      # the shims used to live in is not created at all.
      check not dirExists(tmpDir / "repro-sibling-shims")
      check shimsUnder(tmpDir).len == 0

      # --- Location B, TMPDIR wiped: served from A's record. -------------
      removeDir(tmpDir)
      createDir(tmpDir)
      let b1 = runBuildCli(reproBin, wsB / "consumer", actionCacheRoot,
        tmpDir)
      if b1.exitCode != 0: checkpoint(b1.output)
      check b1.exitCode == 0
      let afterB = computationDirs(actionCacheRoot, "interface")
      checkpoint("after B: " & $afterB)
      check afterB == afterA
      check shimsUnder(tmpDir).len == 0

      # --- Back at A, TMPDIR wiped again: still served. ------------------
      removeDir(tmpDir)
      createDir(tmpDir)
      let a2 = runBuildCli(reproBin, wsA / "consumer", actionCacheRoot,
        tmpDir)
      if a2.exitCode != 0: checkpoint(a2.output)
      check a2.exitCode == 0
      check computationDirs(actionCacheRoot, "interface") == afterA
      check shimsUnder(tmpDir).len == 0

      # --- The served artifact names no other location. -------------------
      # B was served A's computation, so what it received must have been
      # rebased onto B.
      let artifactB = wsB / "consumer" / ".repro" / "build" / "repro" /
        "project-interface.rbsz"
      check fileExists(artifactB)
      if fileExists(artifactB):
        check (tempRoot / "a") notin readFile(artifactB)

      # --- Soundness, and this test's positive control. -------------------
      # The shims are not recorded, so what keeps a served interface honest
      # is the recorded read of the file a shim includes. Editing the sibling
      # at B must be a new computation; that also shows the directory count
      # above can see a miss.
      removeDir(tmpDir)
      createDir(tmpDir)
      writeFile(wsB / ProducerName / "repro.nim",
        ProducerSource & "# edited\n")
      let b2 = runBuildCli(reproBin, wsB / "consumer", actionCacheRoot,
        tmpDir)
      if b2.exitCode != 0: checkpoint(b2.output)
      check b2.exitCode == 0
      let afterEdit = computationDirs(actionCacheRoot, "interface")
      checkpoint("after the sibling edit: " & $afterEdit)
      check afterEdit.len == afterA.len + 1
