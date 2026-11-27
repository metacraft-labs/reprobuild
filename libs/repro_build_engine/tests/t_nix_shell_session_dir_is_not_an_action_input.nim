## A `nix print-dev-env` session directory is not part of an action's key.
##
## WHY. The captured dev shell runs
## `export NIX_BUILD_TOP="$(mktemp -d -t nix-shell.XXXXXX)"`, and points
## `TMPDIR`, `TMP`, `TEMP` and `TEMPDIR` at the same directory, every time it is
## sourced. An action whose process tree read one of them recorded the random
## directory as an observed environment input, so it missed in every new shell.
## Measured 2026-11-26 on codetracer's `stylus-*` edges:
## `cache-miss: input metadata changed: NIX_BUILD_TOP (1 candidate record
## considered)` (reprobuild-specs issue 2026-11-26-a-second-build-in-the-same-
## checkout-compiles-the-provider-again-on-both-edges).
##
## WHAT IS PINNED.
##
## * Reading one of those names whose value is a session directory, then
##   running again under ANOTHER session directory, hits.
## * The name still counts: set versus unset misses, and a deliberate
##   directory (`TMPDIR=/scratch/a` versus `/scratch/b`) misses.
## * A name outside the list (`HOME`) whose value happens to look like a
##   session directory is keyed by value, as before.
## * An action that READ A FILE under the session directory misses in the next
##   session: that file is a recorded input at its absolute path.
##
## The monitor's depfile is written by the test (as in
## `test_m10_observed_env_cache_key`), so the observed reads are exactly the
## ones each case names; the cache decision is the real `runBuild`'s.

import std/[os, tempfiles, unittest]

import repro_build_engine
import repro_core/scratch_env
import repro_local_store
import io_mon/[capabilities, types, writer]

proc fileRead(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
    osPid: 707, threadId: 707, path: path, detail: "")

proc envRead(name: string): MonitorRecord =
  MonitorRecord(kind: mrEnvRead, observationKind: moEnvRead,
    osPid: 707, threadId: 707, path: name,
    detail: "env-read source=getenv scope=name")

proc writeRmdf(path: string; records: seq[MonitorRecord]) =
  let raw = encodeCanonical(records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

type Scenario = object
  root, cacheRoot, workRoot, sourcePath, rmdfPath: string

proc setupScenario(name: string): Scenario =
  result.root = createTempDir("repro-nixshell-" & name, "")
  result.cacheRoot = result.root / "cache"
  result.workRoot = result.root / "work"
  result.sourcePath = result.workRoot / "src" / "input.txt"
  result.rmdfPath = result.root / "action.rdep"
  createDir(result.workRoot / "src")
  createDir(result.workRoot / "out")
  writeFile(result.sourcePath, "payload\n")

proc runOnce(scenario: Scenario; env: openArray[string]): BuildRunResult =
  var action = builtinAction(bakCopyFile, "produce",
    cwd = scenario.workRoot,
    inputs = ["src/input.txt"],
    outputs = ["out/product.txt"],
    cacheable = true,
    actionCachePolicy = ffpChecksum,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  action.monitorDepfile = scenario.rmdfPath
  action.env = @env
  runBuild(graph([action]), defaultBuildEngineConfig(scenario.cacheRoot))

proc observing(scenario: Scenario; names: openArray[string];
               files: openArray[string] = []) =
  var records = profileRecords(defaultHooksMonitorProfile()) &
    @[fileRead(scenario.sourcePath)]
  for file in files:
    records.add(fileRead(file))
  for name in names:
    records.add(envRead(name))
  writeRmdf(scenario.rmdfPath, records)

proc hit(run: BuildRunResult): bool =
  run.results[0].cacheDecision == cdHit and
    run.results[0].status in {asCacheHit, asUpToDate}

suite "a nix-shell session directory is not an action input":
  test "the session spelling is recognised, and only that":
    check isNixShellSessionDir("/tmp/nix-shell.Ab12Cd")
    check isNixShellSessionDir("/tmp/nix-shell.Ab12Cd/")
    check isNixShellSessionDir("/run/user/1003/nix-shell.x")
    check not isNixShellSessionDir("/tmp/nix-shell.")
    check not isNixShellSessionDir("nix-shell.Ab12Cd")
    check not isNixShellSessionDir("/tmp/nix-shell.abc/inner")
    check not isNixShellSessionDir("/scratch")
    check fingerprintedEnvValue("NIX_BUILD_TOP", "/tmp/nix-shell.a") ==
      fingerprintedEnvValue("NIX_BUILD_TOP", "/tmp/nix-shell.b")
    check fingerprintedEnvValue("HOME", "/tmp/nix-shell.a") ==
      "/tmp/nix-shell.a"

  test "NIX_BUILD_TOP and TMPDIR in a new session still hit":
    let scenario = setupScenario("session")
    defer: removeDir(scenario.root)
    observing(scenario, ["NIX_BUILD_TOP", "TMPDIR"])
    let first = runOnce(scenario, ["NIX_BUILD_TOP=/tmp/nix-shell.AAAAAA",
      "TMPDIR=/tmp/nix-shell.AAAAAA"])
    check first.results[0].status == asSucceeded
    let second = runOnce(scenario, ["NIX_BUILD_TOP=/tmp/nix-shell.BBBBBB",
      "TMPDIR=/tmp/nix-shell.BBBBBB"])
    checkpoint("second: " & $second.results[0].cacheDecision & " " &
      second.results[0].cacheMissReason)
    check second.hit

  test "set versus unset still misses":
    let scenario = setupScenario("unset")
    defer: removeDir(scenario.root)
    observing(scenario, ["NIX_BUILD_TOP"])
    discard runOnce(scenario, ["NIX_BUILD_TOP=/tmp/nix-shell.AAAAAA"])
    check not runOnce(scenario, []).hit

  test "a deliberate TMPDIR is keyed by its value":
    let scenario = setupScenario("deliberate")
    defer: removeDir(scenario.root)
    observing(scenario, ["TMPDIR"])
    discard runOnce(scenario, ["TMPDIR=/scratch/a"])
    check runOnce(scenario, ["TMPDIR=/scratch/a"]).hit
    check not runOnce(scenario, ["TMPDIR=/scratch/b"]).hit

  test "a name outside the list keeps its value":
    let scenario = setupScenario("other")
    defer: removeDir(scenario.root)
    observing(scenario, ["HOME"])
    discard runOnce(scenario, ["HOME=/tmp/nix-shell.AAAAAA"])
    check not runOnce(scenario, ["HOME=/tmp/nix-shell.BBBBBB"]).hit

  test "a file read under the session directory still misses":
    ## The safety argument, measured: the directory's CONTENT reaches the key
    ## through the file inputs, not through the variable.
    let scenario = setupScenario("file")
    defer: removeDir(scenario.root)
    let sessionA = scenario.root / "nix-shell.AAAAAA"
    let sessionB = scenario.root / "nix-shell.BBBBBB"
    createDir(sessionA)
    createDir(sessionB)
    writeFile(sessionA / "note", "a\n")
    writeFile(sessionB / "note", "b\n")
    observing(scenario, ["NIX_BUILD_TOP"], [sessionA / "note"])
    discard runOnce(scenario, ["NIX_BUILD_TOP=" & sessionA])
    # The next shell: the old session's directory is gone (nix-direnv and
    # the shell's own cleanup remove it), a new one holds a different file.
    removeDir(sessionA)
    observing(scenario, ["NIX_BUILD_TOP"], [sessionB / "note"])
    check not runOnce(scenario, ["NIX_BUILD_TOP=" & sessionB]).hit
