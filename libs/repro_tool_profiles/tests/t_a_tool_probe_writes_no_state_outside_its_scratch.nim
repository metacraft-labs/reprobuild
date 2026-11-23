## A tool's version probe writes no state outside the probe's own scratch.
##
## The defect: resolving `nimble` runs `nimble --version` as its version
## probe, and `nimble --version` is not read-only. It loads
## `$NIMBLE_DIR/nimbledata2.json` (default `~/.nimble/nimbledata2.json`) and
## rewrites it in place, truncating it first. Every `repro exec` in a dev
## environment that declares nimble therefore rewrote the host's package
## ledger, and a concurrent nimble that read the file during the rewrite saw
## it empty and failed with `nimbledata2.json(1, 0) Error: { expected`.
##
## The fixture stands in for nimble with a script that does what nimble does
## to its ledger: it writes `nimbledata2.json` under `$NIMBLE_DIR`, or under
## `$HOME/.nimble` when `NIMBLE_DIR` is unset, and prints a version banner.
## It is resolved through the public PATH-only resolver, so the probe runs
## through the same `configuredProbes` / `runProbe` path every adapter uses.
##
## What is asserted:
##
##   * control: the same script, resolved under a name with no probe-table
##     entry, DOES write the host ledger, so the fixture witnesses the defect;
##   * resolving it as `nimble` with `NIMBLE_DIR` unset leaves `~/.nimble`
##     untouched, the probe still passes and reports the version, the
##     directory the probe wrote into is gone afterwards, and its path does
##     not reach the recorded (fingerprinted) output, which real nimble
##     echoes as `Info: Using the environment variable: NIMBLE_DIR='<dir>'`;
##   * with `NIMBLE_DIR` set by the caller, the probe does not write there
##     either.
##
## Falsifiable: drop `scratchStateEnv` from the nimble entry in
## `configuredProbes`, or stop `runProbe` applying it, and the second and
## third cases fail on the host ledger existing.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_tool_profiles
import repro_test_support/reasoned_skip

const FakeNimble = """#!/bin/sh
dir="${NIMBLE_DIR:-$HOME/.nimble}"
mkdir -p "$dir"
printf '{"version":"0.1.0","reverseDeps":{}}' > "$dir/nimbledata2.json"
[ -n "$SEEN_STATE_DIRS" ] && echo "$dir" >> "$SEEN_STATE_DIRS"
echo "state-dir: $dir"   # nimble echoes NIMBLE_DIR the same way
echo "nimble v0.22.2 compiled at 2026-01-01 00:00:00"
"""

proc writeFake(binDir, name: string) =
  createDir(binDir)
  let path = binDir / name
  writeFile(path, FakeNimble)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc stateDirReported(output: string): string =
  for line in output.splitLines:
    if line.startsWith("state-dir: "):
      return line["state-dir: ".len .. ^1]

proc versionProbe(profile: PathOnlyToolProfile): ToolProbeResult =
  for probe in profile.probes:
    if probe.spec.kind == tpkVersion:
      return probe
  raise newException(AssertionDefect, "the profile carries no version probe")

suite "a tool's version probe writes no state outside its scratch":
  var root, home, binDir, savedHome, savedNimbleDir: string
  var hadNimbleDir = false

  setup:
    root = createTempDir("t-probe-scratch-state-", "")
    home = root / "home"
    binDir = root / "bin"
    createDir(home)
    savedHome = getEnv("HOME")
    hadNimbleDir = existsEnv("NIMBLE_DIR")
    savedNimbleDir = getEnv("NIMBLE_DIR")
    putEnv("HOME", home)
    delEnv("NIMBLE_DIR")
    putEnv("SEEN_STATE_DIRS", root / "seen-state-dirs")

  teardown:
    putEnv("HOME", savedHome)
    if hadNimbleDir: putEnv("NIMBLE_DIR", savedNimbleDir)
    else: delEnv("NIMBLE_DIR")
    delEnv("SEEN_STATE_DIRS")
    removeDir(root)

  test "control: a probe with no scratch entry writes the host ledger":
    when defined(windows):
      skip("the nimble stand-in is a POSIX shell script")
    else:
      writeFake(binDir, "ledger-writer")
      let profile = resolvePathOnlyTool(InterfaceToolUse(
        packageSelector: "ledger-writer", executableName: "ledger-writer"),
        pathValue = binDir)
      let probe = versionProbe(profile)
      checkpoint(probe.output)
      check probe.exitCode == 0
      check fileExists(home / ".nimble" / "nimbledata2.json")

  test "the nimble version probe leaves ~/.nimble untouched":
    when defined(windows):
      skip("the nimble stand-in is a POSIX shell script")
    else:
      writeFake(binDir, "nimble")
      let profile = resolvePathOnlyTool(InterfaceToolUse(
        packageSelector: "nimble", executableName: "nimble"),
        pathValue = binDir)
      let probe = versionProbe(profile)
      checkpoint(probe.output)
      check probe.exitCode == 0
      check "nimble v0.22.2" in probe.output
      check not dirExists(home / ".nimble")
      # The fresh state directory's path never reaches the recorded output,
      # which is fingerprinted: a second resolution records the same bytes.
      check stateDirReported(probe.output) == "<probe-state>"
      let again = versionProbe(resolvePathOnlyTool(InterfaceToolUse(
        packageSelector: "nimble", executableName: "nimble"),
        pathValue = binDir))
      check again.output == probe.output
      check versionFromProbeOutput(probe.output) == "0.22.2"
      # The directory the probe wrote into is gone, and was not under HOME.
      let used = readFile(root / "seen-state-dirs").splitLines()
      check used.len >= 2
      for dir in used:
        if dir.len > 0:
          check not dir.startsWith(home)
          check not dirExists(dir)

  test "a caller's NIMBLE_DIR is not written by the probe either":
    when defined(windows):
      skip("the nimble stand-in is a POSIX shell script")
    else:
      writeFake(binDir, "nimble")
      let callerDir = home / "caller-nimble-dir"
      createDir(callerDir)
      putEnv("NIMBLE_DIR", callerDir)
      let profile = resolvePathOnlyTool(InterfaceToolUse(
        packageSelector: "nimble", executableName: "nimble"),
        pathValue = binDir)
      let probe = versionProbe(profile)
      checkpoint(probe.output)
      check probe.exitCode == 0
      check not fileExists(callerDir / "nimbledata2.json")
      check not dirExists(home / ".nimble")
