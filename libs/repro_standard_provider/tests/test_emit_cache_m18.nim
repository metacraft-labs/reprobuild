## M18 verification: convention emit-time fingerprint cache.
##
## Direct unit-level coverage for the ``emit_cache.nim`` helper plus a
## stronger guarantee at the Nim-convention level: invoking
## ``nimEmitFragment`` twice in a row with unchanged sources must NOT
## re-run ``nim c --compileOnly``. We probe this by measuring the
## ``last write`` timestamp of the nimcache manifest: a cache hit leaves
## the manifest untouched; a miss (subprocess fired) rewrites it.
##
## The convention-level case requires ``nim`` on PATH (same condition
## the e2e harness expects). When ``nim`` is missing, the convention
## case is skipped — the emit-cache helper tests still run.

import std/[os, strutils, unittest]

import repro_provider_runtime
import repro_standard_provider/convention
import repro_standard_provider/conventions/emit_cache
import repro_standard_provider/conventions/nim as nim_convention

const
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  FixtureRoot = MetacraftRoot / "reprobuild-examples" / "nim" / "binary"
  FixtureEntry = "nim_binary_example"

proc dummyRequest(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "standardProvider.root",
    entryPointBodyHash: "test-body-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

suite "emit_cache helper (M18)":

  test "fingerprint stable on identical inputs":
    let f1 = computeEmitCacheFingerprint([
      textInput("tool:nim"),
      fileInput(currentSourcePath()),
      textInput("flag:release"),
    ])
    let f2 = computeEmitCacheFingerprint([
      textInput("tool:nim"),
      fileInput(currentSourcePath()),
      textInput("flag:release"),
    ])
    check f1 == f2
    check f1.startsWith("repro-emit-cache-v")

  test "fingerprint sensitive to file-content change":
    let scratch = getTempDir() / "test_emit_cache_file_change"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    let f = scratch / "src.txt"
    writeFile(f, "alpha")
    let before = computeEmitCacheFingerprint([fileInput(f)])
    writeFile(f, "beta")
    let after = computeEmitCacheFingerprint([fileInput(f)])
    check before != after
    removeDir(scratch)

  test "fingerprint stable across file-set reordering":
    # The helper sorts file inputs internally — declaration order must
    # not affect the fingerprint or the cache becomes order-sensitive
    # noise.
    let scratch = getTempDir() / "test_emit_cache_order"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    let a = scratch / "a.txt"
    let b = scratch / "b.txt"
    writeFile(a, "a-content")
    writeFile(b, "b-content")
    let order1 = computeEmitCacheFingerprint([fileInput(a), fileInput(b)])
    let order2 = computeEmitCacheFingerprint([fileInput(b), fileInput(a)])
    check order1 == order2
    removeDir(scratch)

  test "fingerprint sensitive to text-input change":
    let f1 = computeEmitCacheFingerprint([textInput("alpha")])
    let f2 = computeEmitCacheFingerprint([textInput("beta")])
    check f1 != f2

  test "emitCacheIsUsable round-trip":
    let scratch = getTempDir() / "test_emit_cache_roundtrip"
    if dirExists(scratch):
      removeDir(scratch)
    createDir(scratch)
    let output = scratch / "result.txt"
    writeFile(output, "output content")
    let inputs = @[textInput("k1"), textInput("k2")]
    let fp = computeEmitCacheFingerprint(inputs)
    # Miss: sidecar not yet written.
    check not emitCacheIsUsable(scratch, "test", fp, [output])
    writeEmitCacheFingerprint(scratch, "test", fp)
    # Hit after write.
    check emitCacheIsUsable(scratch, "test", fp, [output])
    # Required output disappearing turns into a miss.
    removeFile(output)
    check not emitCacheIsUsable(scratch, "test", fp, [output])
    writeFile(output, "back")
    check emitCacheIsUsable(scratch, "test", fp, [output])
    # Fingerprint mismatch turns into a miss.
    let differentFp = computeEmitCacheFingerprint(@[textInput("k1"),
      textInput("DIFFERENT")])
    check not emitCacheIsUsable(scratch, "test", differentFp, [output])
    removeDir(scratch)

proc nimConventionAvailable(): bool =
  if not fileExists(FixtureRoot / "reprobuild.nim"):
    return false
  let conv = nim_convention.nimConvention()
  let request = dummyRequest(FixtureRoot)
  conv.recognize(FixtureRoot, request)

suite "nim convention M18 — emit-cache short-circuits nim c --compileOnly":

  test "second emit re-uses cached nimcache manifest without re-running nim c":
    # Probe: invoke the convention's emitFragment back-to-back with no
    # source changes between calls. The headline M18 contract is that
    # the SECOND emit doesn't fire ``nim c --compileOnly`` — we verify
    # by snapshotting the manifest's last-modified time before+after
    # the second call. Equal mtimes prove the file wasn't rewritten,
    # which means the subprocess didn't run.
    if not nimConventionAvailable():
      checkpoint "fixture or nim toolchain missing — skipping"
      skip()
    else:
      let conv = nim_convention.nimConvention()
      let request = dummyRequest(FixtureRoot)
      let scratchEntry = FixtureRoot / ".repro" / "build" / FixtureEntry
      let nimcacheDir = scratchEntry / "nimcache"
      let manifestPath = nimcacheDir / (FixtureEntry & ".json")
      # Wipe the entry's scratch so the test is hermetic.
      if dirExists(scratchEntry):
        removeDir(scratchEntry)
      discard conv.emitFragment(FixtureRoot, request)
      check fileExists(manifestPath)
      let firstMtime = getLastModificationTime(manifestPath)
      # Sleep a beat so a subprocess re-write would have a measurably
      # different mtime. 1.5 s exceeds NTFS's standard 1-second mtime
      # resolution.
      sleep(1500)
      # Second emit: warm. With the M18 emit cache the subprocess MUST
      # NOT fire, so the manifest mtime must be unchanged.
      discard conv.emitFragment(FixtureRoot, request)
      check fileExists(manifestPath)
      let secondMtime = getLastModificationTime(manifestPath)
      check secondMtime == firstMtime
      # Sanity: the M18 sidecar exists.
      let sidecar = nimcacheDir /
        "nim-c-compileonly.repro-emit-fingerprint"
      check fileExists(sidecar)

  test "source-file edit invalidates cache and re-runs nim c":
    # Negative case: when ``.nim`` source files actually change, the
    # cache miss MUST fire the subprocess. We synthesise the change by
    # touching a throwaway ``.nim`` file under the fixture's ``src/``
    # subdirectory and confirming the manifest gets re-written.
    if not nimConventionAvailable():
      checkpoint "fixture or nim toolchain missing — skipping"
      skip()
    else:
      let conv = nim_convention.nimConvention()
      let request = dummyRequest(FixtureRoot)
      let scratchEntry = FixtureRoot / ".repro" / "build" / FixtureEntry
      let nimcacheDir = scratchEntry / "nimcache"
      let manifestPath = nimcacheDir / (FixtureEntry & ".json")
      if dirExists(scratchEntry):
        removeDir(scratchEntry)
      discard conv.emitFragment(FixtureRoot, request)
      check fileExists(manifestPath)
      let firstMtime = getLastModificationTime(manifestPath)
      sleep(1500)
      # Drop a throwaway extra source file under src/ that the
      # convention will pick up as a fingerprint input.
      let extra = FixtureRoot / "src" / "extra_m18_probe.nim"
      writeFile(extra, "## extra_m18_probe\n")
      try:
        discard conv.emitFragment(FixtureRoot, request)
        let secondMtime = getLastModificationTime(manifestPath)
        # Cache miss must have re-rewritten the manifest — mtimes must
        # differ.
        check secondMtime != firstMtime
      finally:
        if fileExists(extra):
          removeFile(extra)
