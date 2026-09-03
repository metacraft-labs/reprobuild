## Windows-Build-Correctness M10 — the whole chain, with nothing synthetic in
## it.
##
## `test_m10_observed_env_cache_key.nim` drives the consumer with records the
## test wrote itself. That is fast and hermetic and it is blind to the one
## thing this milestone is actually about: whether the SHIM's records, as they
## really come off a monitored process, reach the action cache and change its
## answer. io-mon's own `tests/windows/README.md` states the rule for the
## producer side -- "synthetic fragments are not enough" -- and it applies just
## as directly to the consumer.
##
## So this test runs a REAL monitored process, uses the REAL depfile it
## produced, and asserts on the cache decision of a real `runBuild`.
##
## The monitored program is `where.exe`, which ships with Windows and whose
## behaviour genuinely depends on the variables it reads: it resolves a command
## name by walking `PATH` and trying each `PATHEXT` suffix. Measured under the
## M10 shim it records exactly `PATH` and `PATHEXT` and nothing else -- which
## is also a small demonstration that the capture is the program's OBSERVED
## environment rather than its whole environment. A `cmd /c ver`, by contrast,
## records NO environment read at all: cmd maintains its own copy of the block
## taken straight from the PEB, which is the residual the profile's warning
## names.
##
## The test SKIPS LOUDLY rather than passing quietly when the shim or
## `where.exe` is absent: a skip that looks like a pass is the same failure
## shape as a monitoring failure that reports success.

# WHY THIS IS A `when` AND NOT A `{.error.}`
#
# There is no non-Windows analogue of this test: it drives the real
# `where.exe` under the real M10 shim. But `repro_tests.nim` declares one
# build edge per source UNCONDITIONALLY, so `repro build .#test-builds`
# compiles this file on every host -- and a `{.error.}` here does not skip
# the test, it fails the whole suite build. Measured on Linux at this head:
# 1442 of 1443 actions succeeded and this one source took the build down,
# which is also why no complete tree existed to regenerate the M0 inventory
# from.
#
# The repository's convention for a Windows-only test is
# `libs/repro_peer_cache/tests/t_n7_multicast_windows_smoke.nim`: compile
# everywhere, register cases only on Windows. Off Windows the binary then
# carries no protocol marker, and the suite inventory records it as
# `no-protocol-support` -- an entry that contributes zero cases and is
# visible as such, rather than coverage silently imputed from a source scan.
when defined(windows):
  import std/[os, strutils, tempfiles, unittest]

  import repro_build_engine
  import repro_core
  import repro_local_store
  import io_mon
  import io_mon/fs_snoop
  import io_mon/types

  const WhereExe = r"C:\Windows\System32\where.exe"

  proc shimAvailable(): bool =
    try:
      findShimLibrary().len > 0
    except CatchableError:
      false

  type Scenario = object
    root: string
    cacheRoot: string
    workRoot: string
    sourcePath: string
    rmdfPath: string

  proc setupScenario(name: string): Scenario =
    result.root = createTempDir("repro-m10-live-" & name, "")
    result.cacheRoot = result.root / "cache"
    result.workRoot = result.root / "work"
    result.sourcePath = result.workRoot / "src" / "input.txt"
    result.rmdfPath = result.root / "action.rdep"
    createDir(result.workRoot / "src")
    createDir(result.workRoot / "out")
    writeFile(result.sourcePath, "payload\n")

  proc captureWhereEnvReads(scenario: Scenario): seq[string] =
    ## Run `where cmd` under the real shim, write its depfile where the action
    ## will read it, and return the environment variables it was observed
    ## reading.
    var request = FsSnoopRequest(
      command: @[WhereExe, "cmd"],
      depFilePath: scenario.rmdfPath,
      captureChildStdio: true)
    let res = runMonitored(request)
    doAssert res.exitCode == 0,
      "where.exe cmd exited " & $res.exitCode &
        "; this run cannot test the observed-environment path"
    # The run must also be COMPLETE. A capture that graded incomplete would take
    # the action down a monitor-loss path and the cache decision below would be
    # about that instead of about the environment.
    doAssert res.completeness == mcComplete,
      "the monitored where.exe run graded incomplete"
    result = @[]
    for r in res.records:
      if r.kind == mrEnvRead:
        result.add r.path.toUpperAscii

  proc scenarioAction(scenario: Scenario; env: openArray[string]): BuildAction =
    ## A cacheable action carrying the REAL depfile. Its identity comes from its
    ## id alone (`builtinAction` derives the weak fingerprint from it), so `env`
    ## cannot re-key the action -- only the observed-environment machinery can
    ## turn a hit into a miss.
    result = builtinAction(bakCopyFile, "produce",
      cwd = scenario.workRoot,
      inputs = ["src/input.txt"],
      outputs = ["out/product.txt"],
      cacheable = true,
      actionCachePolicy = ffpChecksum,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    result.monitorDepfile = scenario.rmdfPath
    result.env = @env

  proc runOnce(scenario: Scenario; env: openArray[string]): BuildRunResult =
    runBuild(graph([scenarioAction(scenario, env)]),
      defaultBuildEngineConfig(scenario.cacheRoot))

  suite "M10 live: a real shim capture reaches the action cache":

    test "where.exe's observed PATH read invalidates the action when PATH moves":
      # A skip is announced, never silent: a skip that reads as a pass is the
      # same failure shape as a monitoring failure that reports success.
      if not fileExists(WhereExe):
        checkpoint("SKIPPED: " & WhereExe & " is absent on this host")
      elif not shimAvailable():
        checkpoint("SKIPPED: no io-mon shim found; build it into build/lib " &
          "or set REPRO_MONITOR_SHIM_LIB")
      else:
       let scenario = setupScenario("path")
       defer: removeDir(scenario.root)

       # 1. The producer half, live. `where` resolves a command by walking PATH
       #    and PATHEXT, and the shim must have seen both.
       let observed = captureWhereEnvReads(scenario)
       checkpoint("observed environment reads: " & observed.join(","))
       check "PATH" in observed
       check "PATHEXT" in observed

       # 2. The consumer half. Same PATH twice: a hit, which is the direction an
       #    implementation that always invalidates would fail.
       let first = runOnce(scenario,
         ["PATH=C:\\one;C:\\two", "PATHEXT=.COM;.EXE"])
       check first.results[0].status == asSucceeded
       let second = runOnce(scenario,
         ["PATH=C:\\one;C:\\two", "PATHEXT=.COM;.EXE"])
       check second.results[0].status in {asCacheHit, asUpToDate}
       check second.results[0].cacheDecision == cdHit

       # 3. PATH moves. `where` would resolve a different command, so the action
       #    must RE-RUN rather than serve what it produced under the old PATH.
       #    This is the false-cache-hit the capability gap allowed, closed.
       let third = runOnce(scenario,
         ["PATH=C:\\three;C:\\four", "PATHEXT=.COM;.EXE"])
       check third.results[0].cacheDecision != cdHit
       check third.results[0].status notin {asCacheHit, asUpToDate}

    test "a variable where.exe never read does not invalidate it":
      ## The other direction, on the same live capture. An action's environment
      ## is large and almost none of it is an input; if the capture put the whole
      ## environment into the key, changing `TMP` would re-run the world.
      if not fileExists(WhereExe) or not shimAvailable():
        checkpoint("SKIPPED: where.exe or the io-mon shim is unavailable")
      else:
       let scenario = setupScenario("unrelated")
       defer: removeDir(scenario.root)
       let observed = captureWhereEnvReads(scenario)
       check "IOMON_M10_UNRELATED" notin observed

       let first = runOnce(scenario,
         ["PATH=C:\\one", "PATHEXT=.EXE", "IOMON_M10_UNRELATED=before"])
       check first.results[0].status == asSucceeded
       let second = runOnce(scenario,
         ["PATH=C:\\one", "PATHEXT=.EXE", "IOMON_M10_UNRELATED=after"])
       check second.results[0].status in {asCacheHit, asUpToDate}
       check second.results[0].cacheDecision == cdHit
