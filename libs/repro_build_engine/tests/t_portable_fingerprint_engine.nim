## Cache-Scope P3.1 engine wiring: the engine computes each recorded action's
## portable fingerprint when — and only when — `BuildEngineConfig.portableRoots`
## is set, from the same filtered input set as the local record.
##
## The property that matters for sharing: the same action, run from two
## checkouts at DIFFERENT absolute paths, reports the SAME portable strong
## fingerprint (while its local record, being path-bearing, differs), and an
## input-content change moves it.

import std/[options, os, strutils, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_core/paths
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
             extraInput = ""; sharedRoot = ""): ActionResult =
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
  if sharedRoot.len > 0:
    config.actionCacheRoot = sharedRoot
  if portable:
    config.portableRoots = @[
      LogicalRoot(label: "project", path: projectRoot, kind: lrkTracked)]
  let run = runBuild(graph(@[action], newSeq[BuildPool]()), config)
  require run.results.len == 1
  require run.results[0].status in {asSucceeded, asCacheHit, asUpToDate}
  run.results[0]

suite "Cache-Scope P3.1 — engine records portable fingerprints":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
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
    # P3.2: the RESULT is named portably too, and identified by its bytes.
    check ra.portableOutputs.len == 1
    check ra.portableOutputs == rb.portableOutputs
    check ra.portableOutputs[0].path == "project:out/result.txt"
    check ra.portableOutputs[0].digest ==
      fileContentHex(a / "out" / "result.txt")

  test "P3.3: a memo recorded by one checkout is found from another":
    let shared = absolutePath(TmpDir / "shared-cache")
    let a = project("memo-a", "int main;\n")
    let b = project("memo-b-at/a/different/depth", "int main;\n")
    let ra = buildIn(a, TmpDir / "cache-ma", portable = true,
      sharedRoot = shared)
    require ra.portable
    # Checkout B has not built anything. Its lookup by portable weak
    # fingerprint recomputes the strong fingerprint from ITS files and finds
    # the record checkout A stored.
    let roots = @[LogicalRoot(label: "project", path: b, kind: lrkTracked)]
    let hit = lookupMemo(shared / "portable-memo", roots, ra.portableWeakHex)
    check hit.isSome
    check hit.get().strongHex == ra.portableStrongHex
    check hit.get().outputs == ra.portableOutputs
    # A checkout whose input differs does not.
    let c = project("memo-c", "int other;\n")
    let rootsC = @[LogicalRoot(label: "project", path: c, kind: lrkTracked)]
    check lookupMemo(shared / "portable-memo", rootsC,
      ra.portableWeakHex).isNone

  test "P3.4: a local cache hit yields the same portable record":
    let p = project("warm", "int main;\n")
    let cold = buildIn(p, TmpDir / "cache-warm", portable = true)
    require cold.portable
    require cold.launched
    # The warm run is served from the local action cache, never re-running
    # the action, and still derives the portable record from the hit.
    let warm = buildIn(p, TmpDir / "cache-warm", portable = true)
    check not warm.launched
    check warm.portable
    check warm.portableWeakHex == cold.portableWeakHex
    check warm.portableStrongHex == cold.portableStrongHex
    check warm.portableOutputs == cold.portableOutputs

  test "builtins with the same inputs but different payloads differ":
    # argv is empty for every builtin, so the portable identity has to carry
    # the rest of the static description: kind, payload, declared outputs.
    let p = project("builtins", "int main;\n")
    createDir(p / "out")
    proc writer(id, text, output: string): BuildAction =
      BuildAction(
        governingLockIdentity: lockIdentityOutsideSolvedGraph(),
        kind: bakWriteText, id: id, deps: @[],
        inputs: @[p / "src" / "main.c"], outputs: @[p / "out" / output],
        cwd: p, cacheable: true, actionCachePolicy: ffpTimestamp,
        weakFingerprint: fingerprintForPayload(id), builtinText: text)
    var config = defaultBuildEngineConfig(TmpDir / "cache-builtins")
    config.maxParallelism = 1
    config.portableRoots = @[
      LogicalRoot(label: "project", path: p, kind: lrkTracked)]
    let run = runBuild(graph(@[
      writer("t-one", "one\n", "one.txt"),
      writer("t-two", "two\n", "two.txt"),
      writer("t-same-output", "one\n", "three.txt")],
      newSeq[BuildPool]()), config)
    require run.results.len == 3
    for r in run.results:
      require r.portable
    check run.results[0].portableWeakHex != run.results[1].portableWeakHex
    check run.results[0].portableStrongHex != run.results[1].portableStrongHex
    # Same payload, different declared output: still different actions.
    check run.results[0].portableWeakHex != run.results[2].portableWeakHex

  test "an input-content change moves the portable strong fingerprint":
    let a = project("same-a", "int main;\n")
    let b = project("same-b", "int main(void);\n")
    let ra = buildIn(a, TmpDir / "cache-ca", portable = true)
    let rb = buildIn(b, TmpDir / "cache-cb", portable = true)
    check ra.portableWeakHex == rb.portableWeakHex
    check ra.portableStrongHex != rb.portableStrongHex

  test "P3.4: a declared output directory (an install prefix) is in the record":
    let p = project("prefix", "int main;\n")
    createDir(p / "prefix" / "bin")
    writeFile(p / "prefix" / "bin" / "tool", "tool bytes")
    let action = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakWriteText, id: "t-pfp-mirror", deps: @[],
      inputs: @[p / "src" / "main.c"],
      outputs: @[p / "out" / "mirror.stamp"],
      declaredOutputs: @[p / "prefix"],
      cwd: p, cacheable: true, actionCachePolicy: ffpTimestamp,
      weakFingerprint: fingerprintForPayload("t-pfp-mirror"),
      builtinText: "stamp\n")
    createDir(p / "out")
    var config = defaultBuildEngineConfig(TmpDir / "cache-prefix")
    config.maxParallelism = 1
    config.portableRoots = @[
      LogicalRoot(label: "project", path: p, kind: lrkTracked)]
    let run = runBuild(graph(@[action], newSeq[BuildPool]()), config)
    require run.results.len == 1
    let r = run.results[0]
    require r.portable
    var paths: seq[string] = @[]
    for output in r.portableOutputs:
      paths.add(output.path)
      if output.path == "project:prefix":
        check output.directory
        check output.digest == treeContentHex(p / "prefix")
    check "project:prefix" in paths
    check "project:out/mirror.stamp" in paths

  test "the monitor shim the engine injects is not an input":
    # Every monitored process loads the shim, so it is observed as a read;
    # it is the observation machinery, wherever this host keeps it.
    let a = project("shim", "int main;\n")
    let shim = absolutePath(TmpDir / "elsewhere" / "fake_monitor_shim.dll")
    createDir(shim.parentDir)
    writeFile(shim, "shim bytes")
    let saved = getEnv("REPRO_MONITOR_SHIM_LIB")
    putEnv("REPRO_MONITOR_SHIM_LIB", shim)
    defer:
      if saved.len > 0: putEnv("REPRO_MONITOR_SHIM_LIB", saved)
      else: delEnv("REPRO_MONITOR_SHIM_LIB")
    let r = buildIn(a, TmpDir / "cache-shim", portable = true,
      extraInput = shim)
    checkpoint(r.portableReason)
    check r.portable

  test "runquota's per-launch shell wrapper is not an input":
    let a = project("wrapper", "int main;\n")
    let wrapper = getTempDir() / "runquota-shell" /
      ("runquota-shell-t-pfp-" & $getCurrentProcessId() & ".sh")
    createDir(wrapper.parentDir)
    writeFile(wrapper, "echo staged program\n")
    defer: removeFile(wrapper)
    let r = buildIn(a, TmpDir / "cache-wrapper", portable = true,
      extraInput = wrapper)
    checkpoint(r.portableReason)
    check r.portable

  test "an input outside every logical root is reported, not shared":
    let a = project("outside", "int main;\n")
    let stray = absolutePath(TmpDir / "stray.cfg")
    writeFile(stray, "host specific\n")
    let r = buildIn(a, TmpDir / "cache-out", portable = true,
      extraInput = stray)
    check not r.portable
    check r.portableStrongHex == ""
    check "stray.cfg" in r.portableReason
