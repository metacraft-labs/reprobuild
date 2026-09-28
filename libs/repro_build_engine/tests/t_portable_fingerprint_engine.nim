## Cache-Scope P3.1 engine wiring: the engine computes each recorded action's
## portable fingerprint when — and only when — `BuildEngineConfig.portableRoots`
## is set, from the same filtered input set as the local record.
##
## The property that matters for sharing: the same action, run from two
## checkouts at DIFFERENT absolute paths, reports the SAME portable strong
## fingerprint (while its local record, being path-bearing, differs), and an
## input-content change moves it.

import std/[os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_hash
import repro_local_store

let TmpDir = "build/test-tmp/t_portable_fingerprint_engine-" &
  testCaseScratchSlug()

proc fingerprintForPayload(payload: string): ContentDigest =
  casDigest(payload.toOpenArrayByte(0, payload.high),
            domain = hdActionFingerprint)

proc project(parent: string; source: string): string =
  result = absolutePath(TmpDir / parent / "proj")
  createDir(result / "src")
  writeFile(result / "src" / "main.c", source)

proc buildIn(projectRoot, cacheRoot: string; portable: bool;
             extraInput = ""): ActionResult =
  var inputs = @[projectRoot / "src" / "main.c"]
  if extraInput.len > 0:
    inputs.add(extraInput)
  let action = BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakWriteText,
    id: "t-pfp-write",
    deps: @[],
    inputs: inputs,
    outputs: @[projectRoot / "out" / "result.txt"],
    cwd: projectRoot,
    cacheable: true,
    actionCachePolicy: ffpTimestamp,
    weakFingerprint: fingerprintForPayload("t-pfp-write"),
    builtinText: "built\n")
  createDir(projectRoot / "out")
  var config = defaultBuildEngineConfig(cacheRoot)
  config.maxParallelism = 1
  if portable:
    config.portableRoots = @[
      LogicalRoot(label: "project", path: projectRoot, kind: lrkTracked)]
  let run = runBuild(graph(@[action], newSeq[BuildPool]()), config)
  require run.results.len == 1
  require run.results[0].status == asSucceeded
  run.results[0]

suite "Cache-Scope P3.1 — engine records portable fingerprints":

  setup:
    if dirExists(TmpDir):
      removeDir(TmpDir)
    createDir(TmpDir)

  test "off by default: no portable identity without portableRoots":
    let p = project("off", "int main;\n")
    let r = buildIn(p, TmpDir / "cache-off", portable = false)
    check not r.portable
    check r.portableStrongHex == ""

  test "two checkouts at different absolute paths agree":
    let a = project("a", "int main;\n")
    let b = project("somewhere-much-longer/elsewhere", "int main;\n")
    check a != b
    let ra = buildIn(a, TmpDir / "cache-a", portable = true)
    let rb = buildIn(b, TmpDir / "cache-b", portable = true)
    check ra.portable
    check rb.portable
    check ra.portableStrongHex.len == 64
    check ra.portableWeakHex == rb.portableWeakHex
    check ra.portableStrongHex == rb.portableStrongHex

  test "an input-content change moves the portable strong fingerprint":
    let a = project("same-a", "int main;\n")
    let b = project("same-b", "int main(void);\n")
    let ra = buildIn(a, TmpDir / "cache-ca", portable = true)
    let rb = buildIn(b, TmpDir / "cache-cb", portable = true)
    check ra.portableWeakHex == rb.portableWeakHex
    check ra.portableStrongHex != rb.portableStrongHex

  test "an input outside every logical root is reported, not shared":
    let a = project("outside", "int main;\n")
    let stray = absolutePath(TmpDir / "stray.cfg")
    writeFile(stray, "host specific\n")
    let r = buildIn(a, TmpDir / "cache-out", portable = true,
      extraInput = stray)
    check not r.portable
    check r.portableStrongHex == ""
    check "stray.cfg" in r.portableReason
