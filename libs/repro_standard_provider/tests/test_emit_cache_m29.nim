## M29 Part A verification: convention emit-time fingerprint cache now
## folds the tool's reported version into the cache key.
##
## The bug pre-M29: ``nim``/``cargo``/``go`` resolve from ``PATH`` to a
## stable absolute path on a typical developer host. When the user
## upgrades the toolchain in place (the canonical case: ``choosenim
## update stable`` swaps the bytes behind the existing ``nim`` shim;
## a system package manager refreshes ``go`` to a new minor; ``rustup
## update`` rewires ``cargo``'s shim) the absolute path stays the same
## but the produced compile output diverges. The M18 fingerprint sidecar
## had no way to notice — it folded only the exe path + sources — so
## stale per-tool nimcache / cargo metadata / go list output got served
## as a cache hit, producing build artefacts compiled against a
## phantom-old toolchain semantic.
##
## The M29 fix: ``toolVersionInput`` runs ``<tool> --version`` (or
## ``go version`` for Go) once per emit process and folds the captured
## text into the M18 fingerprint via a ``textInput``. Same-path-
## different-version-output flips the fingerprint and triggers a clean
## cache miss + re-run.
##
## These tests directly exercise the helper (no toolchain dependency)
## by:
##   1. Building a small shell/cmd-script "fake tool" on disk whose
##      ``--version`` output we control.
##   2. Probing it, mutating the script body, resetting the process
##      cache, re-probing — checking the fingerprint changed.
##   3. Asserting the missing-tool sentinel (``ToolVersionProbeUnknown``)
##      is stable so cache misses on broken toolchains still hit a
##      reproducible slot.

import std/[os, strutils, unittest]

import repro_standard_provider/conventions/emit_cache

const
  ScratchRoot = "test_emit_cache_m29_scratch"

proc writeFakeTool(scratch, name, versionOutput: string): string =
  ## Materialise a tiny "fake tool" on disk whose ``--version`` argv
  ## prints the supplied text. We use a ``.cmd`` shim on Windows (where
  ## ``execCmdEx`` goes through cmd.exe) and a hashbang shell script
  ## elsewhere. The shim ignores any additional argv and always exits 0.
  when defined(windows):
    let path = scratch / (name & ".cmd")
    # ``@echo off`` keeps cmd from echoing the script body; the lines
    # printed to stdout become our captured ``--version`` output.
    var body = "@echo off\r\n"
    for line in versionOutput.splitLines():
      body.add("echo " & line & "\r\n")
    body.add("exit /b 0\r\n")
    writeFile(path, body)
    path
  else:
    let path = scratch / name
    var body = "#!/usr/bin/env bash\n"
    for line in versionOutput.splitLines():
      body.add("echo '" & line.replace("'", "'\\''") & "'\n")
    body.add("exit 0\n")
    writeFile(path, body)
    discard execShellCmd("chmod +x " & quoteShell(path))
    path

proc setupScratch(): string =
  ## Fresh per-test scratch dir + clean process-local version cache.
  ## Pulled into a helper so each ``test`` block can shadow ``scratch``
  ## without colliding with a setup-block binding (unittest's setup
  ## injects its locals into the same scope as the test body).
  resetToolVersionCache()
  result = getTempDir() / ScratchRoot
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc teardownScratch() =
  resetToolVersionCache()
  let scratch = getTempDir() / ScratchRoot
  if dirExists(scratch):
    removeDir(scratch)

suite "tool version fingerprinting (M29 Part A)":

  test "missing tool returns the sentinel":
    let scratch = setupScratch()
    defer: teardownScratch()
    let missing = scratch / "definitely-not-on-path.exe"
    check toolVersionFingerprint(missing) == ToolVersionProbeUnknown
    check toolVersionFingerprint("") == ToolVersionProbeUnknown

  test "fake tool's --version output is captured verbatim":
    let scratch = setupScratch()
    defer: teardownScratch()
    let toolPath = writeFakeTool(scratch, "faketool-v1",
      "FakeTool 1.0.0 (build abc123)")
    let fp = toolVersionFingerprint(toolPath)
    check fp != ToolVersionProbeUnknown
    check "FakeTool 1.0.0" in fp

  test "version change invalidates the cache":
    let scratch = setupScratch()
    defer: teardownScratch()
    let toolPath = writeFakeTool(scratch, "faketool-v2",
      "FakeTool 1.0.0")
    let fpA = toolVersionFingerprint(toolPath)
    # The result is process-cached: a same-path probe SHOULD return the
    # cached value even when the on-disk binary changes mid-process.
    # Real upgrade flows don't hit this case (one emit per process) but
    # we verify the cache contract explicitly.
    discard writeFakeTool(scratch, "faketool-v2", "FakeTool 2.0.0")
    let fpCached = toolVersionFingerprint(toolPath)
    check fpA == fpCached
    # Now drop the cache (simulating "next emit process") and re-probe.
    resetToolVersionCache()
    let fpB = toolVersionFingerprint(toolPath)
    check fpA != fpB
    check "FakeTool 1.0.0" in fpA
    check "FakeTool 2.0.0" in fpB

  test "toolVersionInput labels the input with the tool basename":
    let scratch = setupScratch()
    defer: teardownScratch()
    let toolPath = writeFakeTool(scratch, "labelprobe",
      "LabelProbe 0.1")
    let input = toolVersionInput(toolPath)
    # The label exists to make the sidecar self-documenting on visual
    # inspection. We only verify the basename token is present — the
    # full layout is internal.
    let fingerprintBlob = computeEmitCacheFingerprint(@[input])
    check "labelprobe" in fingerprintBlob
    check "LabelProbe 0.1" in fingerprintBlob

  test "version output changes the convention-level fingerprint":
    # This is the headline contract: a "same-path-different-version"
    # upgrade DOES move the convention's emit-cache fingerprint. We
    # build a fingerprint over a constant text input + the
    # toolVersionInput, and verify swapping the fake tool's body
    # produces a different overall fingerprint.
    let scratch = setupScratch()
    defer: teardownScratch()
    let toolPath = writeFakeTool(scratch, "convprobe", "ConvProbe 1.0")
    let before = computeEmitCacheFingerprint(@[
      textInput("project-root:" & scratch),
      textInput("cmd:fake convention dispatch"),
      toolVersionInput(toolPath),
    ])
    resetToolVersionCache()
    discard writeFakeTool(scratch, "convprobe", "ConvProbe 2.0")
    let after = computeEmitCacheFingerprint(@[
      textInput("project-root:" & scratch),
      textInput("cmd:fake convention dispatch"),
      toolVersionInput(toolPath),
    ])
    check before != after
    check "ConvProbe 1.0" in before
    check "ConvProbe 2.0" in after

  test "custom version args (e.g. ``go version``) work":
    # Go's CLI uses ``go version`` (no dash) for its banner.
    # ``toolVersionInput`` accepts a custom argv tail.
    let scratch = setupScratch()
    defer: teardownScratch()
    when defined(windows):
      # Build a cmd shim that prints different output for ``version`` vs
      # ``--version`` so we can verify the helper passes the right argv.
      let path = scratch / "argsprobe.cmd"
      writeFile(path,
        "@echo off\r\n" &
        "if \"%1\"==\"version\" (\r\n" &
        "  echo VERSION-SUBCMD-OK\r\n" &
        "  exit /b 0\r\n" &
        ")\r\n" &
        "echo VERSION-DASHDASH-OK\r\n" &
        "exit /b 0\r\n")
    else:
      let path = scratch / "argsprobe"
      writeFile(path,
        "#!/usr/bin/env bash\n" &
        "if [ \"$1\" = \"version\" ]; then\n" &
        "  echo 'VERSION-SUBCMD-OK'\n" &
        "  exit 0\n" &
        "fi\n" &
        "echo 'VERSION-DASHDASH-OK'\n" &
        "exit 0\n")
      discard execShellCmd("chmod +x " & quoteShell(path))
    let probePath =
      when defined(windows): scratch / "argsprobe.cmd"
      else: scratch / "argsprobe"
    let withDefault = toolVersionFingerprint(probePath)
    check "VERSION-DASHDASH-OK" in withDefault
    resetToolVersionCache()
    let withSubcmd = toolVersionFingerprint(probePath, ["version"])
    check "VERSION-SUBCMD-OK" in withSubcmd

suite "tool version fingerprint integrates with M18 emit-cache version":

  test "EmitCacheVersion advanced past v1 (sidecar layout change)":
    # M29 bumps the layout: v1 sidecars (pre-M29) must miss against v2
    # fingerprints. Hard-asserting the version float prevents an
    # accidental revert.
    check EmitCacheVersion != "1"
    let fp = computeEmitCacheFingerprint(@[textInput("any")])
    check fp.startsWith("repro-emit-cache-v" & EmitCacheVersion)
