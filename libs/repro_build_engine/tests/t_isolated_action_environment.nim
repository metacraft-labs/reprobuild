## An action launched with `isolateHostEnvironment` sees its declared
## environment and nothing the engine inherited (Dev-Env-Warm-Entry.md §2).
##
## The provider-compile edge inherited whatever shell started `repro`, and its
## monitor recorded `PATH`, `TERM`, `LANG` and more by value, so a caller with
## a different shell recompiled the provider. The fix is to launch such an
## edge from the environment the engine composed and nothing else. These cases
## grade that launch through the engine's real direct-launch path (the one
## `repro build` takes with RunQuota bypassed), with a real `sh` child
## recording what it actually received, as out-of-band evidence.
##
##   1. An INHERITING action (the default) still sees a variable that only the
##      engine's process holds. The historical behaviour is unchanged.
##   2. An ISOLATED action does not see it, and does see what it declares.
##   3. For an isolated action, a host-only variable is not an input: changing
##      it does not re-run the edge.
##   4. Isolation is keyed. The inheriting fingerprint is unchanged (so no
##      existing record moves), and the isolated one differs from it.
##   5. An isolated action still receives the host's OS-essential variables
##      (`HostEssentialEnvNames`), exactly as an action under an allowlisted
##      environment does. Isolation first shipped without them, and on
##      Windows a process with no `SystemRoot` cannot create a socket: the
##      provider-compile edge's `repro` helper died initialising with "An
##      operation was attempted on something that is not a socket", so no
##      recipe could be compiled. The case reads the child's own view of
##      `SystemRoot` (Windows) / `HOME` (POSIX) by value.
##
## MOCKS: none. Real processes and a real action cache in a temp directory.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_build_engine
import repro_hash
import repro_local_store

const
  ReuseDecisions = {cdHit, cdHybridCutoff}
  HostOnlyVar = "REPRO_TEST_HOST_ONLY_ENV"
  DeclaredVar = "REPRO_TEST_ISOLATED_DECLARED_ENV"

proc weak(name: string): ContentDigest =
  weakFingerprintFromText(name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

type Fixture = object
  root, workRoot, cacheRoot, runLogPath: string

proc makeFixture(): Fixture =
  let root = createTempDir("repro-isolated-env-", "")
  let workRoot = root / "work"
  createDir(workRoot / "src")
  createDir(workRoot / "out")
  writeFile(workRoot / "src" / "fixture.txt", "fixture\n")
  Fixture(root: root, workRoot: workRoot, cacheRoot: root / "cache",
    runLogPath: workRoot / "out" / "runs.log")

proc runLines(f: Fixture): seq[string] =
  if fileExists(f.runLogPath):
    for line in readFile(f.runLogPath).splitLines():
      if line.strip().len > 0:
        result.add(line)

proc edge(sh, workRoot: string; isolate: bool): BuildAction =
  ## Records the host-only and declared variables as the CHILD saw them.
  ## `sh` builtins only, so an isolated child needs no PATH.
  action("env/isolated",
    [sh, "-c",
     "printf '%s|%s\\n' \"${" & HostOnlyVar & "-unset}\" \"${" &
       DeclaredVar & "-unset}\" >> out/runs.log; " &
     "printf 'run.stamp: src/fixture.txt\\n' > out/run.d"],
    cwd = workRoot,
    inputs = ["src/fixture.txt"],
    outputs = [],
    depfile = "out/run.d",
    cacheable = true,
    weakFingerprint = weak("env/isolated"),
    actionCachePolicy = ffpHybrid,
    env = [DeclaredVar & "=declared"],
    isolateHostEnvironment = isolate,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

const EssentialVar =
  when defined(windows): "SYSTEMROOT"
  else: "HOME"
    ## One name from `HostEssentialEnvNames` that every host has. Spelled in
    ## capitals on Windows because that is how the MSYS `sh` the probe runs
    ## exposes `SystemRoot`; Windows environment names are case-insensitive.

proc essentialEdge(sh, workRoot: string): BuildAction =
  ## An isolated action that records what it received for `EssentialVar`.
  action("env/isolated-essential",
    [sh, "-c",
     "printf '%s\\n' \"${" & EssentialVar & "-unset}\" >> out/runs.log; " &
     "printf 'run.stamp: src/fixture.txt\\n' > out/run.d"],
    cwd = workRoot,
    inputs = ["src/fixture.txt"],
    outputs = [],
    depfile = "out/run.d",
    cacheable = true,
    weakFingerprint = weak("env/isolated-essential"),
    actionCachePolicy = ffpHybrid,
    isolateHostEnvironment = true,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc directConfig(cacheRoot: string): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 1'u32

suite "isolated action environment":
  let sh = findExe("sh")

  test "1. an inheriting action still sees the engine's own environment":
    if sh.len == 0:
      skip("no sh on PATH to run the probe action")
    else:
      putEnv(HostOnlyVar, "leaks")
      defer: delEnv(HostOnlyVar)
      let f = makeFixture()
      defer: removeDir(f.root)
      let run = runBuild(graph([edge(sh, f.workRoot, isolate = false)]),
        directConfig(f.cacheRoot))
      check run.byId("env/isolated").status == asSucceeded
      check f.runLines() == @["leaks|declared"]

  test "2. an isolated action sees only what it declares":
    if sh.len == 0:
      skip("no sh on PATH to run the probe action")
    else:
      putEnv(HostOnlyVar, "leaks")
      defer: delEnv(HostOnlyVar)
      let f = makeFixture()
      defer: removeDir(f.root)
      let run = runBuild(graph([edge(sh, f.workRoot, isolate = true)]),
        directConfig(f.cacheRoot))
      check run.byId("env/isolated").status == asSucceeded
      check f.runLines() == @["unset|declared"]

  test "3. a host-only variable is not an input of an isolated action":
    if sh.len == 0:
      skip("no sh on PATH to run the probe action")
    else:
      let f = makeFixture()
      defer: removeDir(f.root)
      let config = directConfig(f.cacheRoot)
      let g = graph([edge(sh, f.workRoot, isolate = true)])
      putEnv(HostOnlyVar, "first")
      defer: delEnv(HostOnlyVar)
      check runBuild(g, config).byId("env/isolated").launched
      putEnv(HostOnlyVar, "second")
      let warm = runBuild(g, config).byId("env/isolated")
      check warm.cacheDecision in ReuseDecisions
      check not warm.launched
      check f.runLines().len == 1

  test "4. isolation is keyed, and an inheriting key does not move":
    let base = weak("env/isolated")
    check keyedOnEnvironmentIsolation(base, false) == base
    check keyedOnEnvironmentIsolation(base, true) != base
    let f = makeFixture()
    defer: removeDir(f.root)
    let inheriting = edge("/bin/sh", f.workRoot, isolate = false)
    let isolated = edge("/bin/sh", f.workRoot, isolate = true)
    check inheriting.weakFingerprint != isolated.weakFingerprint

  test "5. an isolated action still receives the host's OS-essential variables":
    if sh.len == 0:
      skip("no sh on PATH to run the probe action")
    else:
      let expected = getEnv(EssentialVar)
      require expected.len > 0
      let f = makeFixture()
      defer: removeDir(f.root)
      let run = runBuild(graph([essentialEdge(sh, f.workRoot)]),
        directConfig(f.cacheRoot))
      check run.byId("env/isolated-essential").status == asSucceeded
      check f.runLines() == @[expected]
