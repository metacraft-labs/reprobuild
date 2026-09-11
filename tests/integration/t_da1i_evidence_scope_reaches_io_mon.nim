## DA-1i — `repro build --evidence=reads-only` really reaches io-mon, and the
## capture that comes back really says so.
##
## The unit file `libs/repro_build_engine/tests/t_da1i_evidence_scope.nim`
## grades the CONSUMER half: given a capture that states a scope, which
## consumers trust it. It cannot grade the PRODUCER half, because producing a
## genuinely narrowed capture needs a real monitored process tree, a real
## injected shim, and io-mon's real host — and a fixture that hand-wrote the
## stamp would assert that this test can write a string.
##
## So this file asserts the other end of the same contract, and it asserts it
## three times over, because the flag crosses three boundaries and any one of
## them can swallow it silently:
##
##   1. THE CLI HONOURS `--evidence`. `repro internal io monitor --evidence
##      reads-only` drops the failed lookups and stamps the depfile; the same
##      command under `--evidence full` keeps them and stamps nothing (io-mon
##      does not stamp `esFull`, because "not stated" has always meant exactly
##      full scope and stamping it would change the bytes of every capture
##      that exists).
##   2. THE SHIM IS TOLD. The monitored child sees `REPRO_MONITOR_EVIDENCE`
##      set to what was asked for. This is the variable an engine CANNOT
##      usefully set itself: io-mon's `childEnv` writes it last, after the
##      caller's env and after the injected pairs, which is exactly how the
##      INTEREST request was silently discarded on this path once already
##      (Engine-Threadpool FINDING 2).
##   3. THE ENGINE FORWARDS IT. A real `runBuild` over a real monitored action
##      with `BuildEngineConfig.evidenceScope = esReadsOnly` produces a
##      depfile stamped `reads-only`, and the same action under the default
##      produces one that is not.
##
## AND THE COUNTS MOVE IN THE RIGHT DIRECTION, which is the claim that makes
## the flag more than a label. The fixture command below deliberately does
## both halves of the distinction: it READS a file that exists and it LOOKS
## FOR one that does not. Under `full` both are recorded. Under `reads-only`
## the read survives and the failed lookup is gone — which is the whole
## mechanism, and the whole hazard: a file ADDED at that absent path later
## will not invalidate the action, because nothing recorded that anyone went
## looking there.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED. Every
## assertion drives the graph-built `repro` binary, the graph-built monitor
## shim, io-mon's real host and real depfile reader, the real `runBuild`
## scheduler, a real `/bin/sh`, and real files in a real temporary directory.
## The defect class under test IS the path from a CLI flag to a recorded
## observation; a harness that supplied its own depfile would assert nothing
## about it.

import std/[os, osproc, streams, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_test_support
import io_mon/[types, reader]

const RepoRootMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

var cachedMonitorTools: MonitorTools
var cachedMonitorToolsReady = false

proc monitorTools(repoRoot: string): MonitorTools =
  if not cachedMonitorToolsReady:
    cachedMonitorTools = prepareMonitorTools(repoRoot,
      repoRoot / "build" / "test-monitor-da1i", "da1i-monitor")
    putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
    cachedMonitorToolsReady = true
  cachedMonitorTools

## The fixture command, and every part of it is load-bearing.
##
## `cat present.txt` is a lookup that SUCCEEDS — it must survive both scopes,
## because a scope that dropped reads would not be `reads-only`, it would be
## broken. `[ -e absent.txt ]` is a lookup that FAILS — the class `reads-only`
## exists to drop. `|| true` keeps the shell's exit status at 0 so the action
## succeeds either way and the test is grading evidence, not exit codes.
const FixtureScript =
  "cat present.txt > /dev/null; [ -e absent.txt ] || true"

const AbsentName = "absent.txt"
const PresentName = "present.txt"

proc makeWorkRoot(): string =
  result = createTempDir("repro-da1i-", "")
  writeFile(result / PresentName, "present\n")
  # `absent.txt` is deliberately NOT created. The whole point is a lookup
  # that finds nothing.

proc pathsNaming(dep: MonitorDepFile; needle: string): int =
  for record in dep.records:
    if record.path.contains(needle):
      inc result

proc runMonitorCli(tools: MonitorTools; workRoot, depPath: string;
                   evidenceArgs: seq[string];
                   script = FixtureScript):
                   tuple[code: int, output: string] =
  ## One spawn of the real `repro internal io monitor`, over the real fixture
  ## command, in the fixture's own directory.
  let args = tools.monitorCliArgs & @["--depfile", depPath] & evidenceArgs &
    @["--", "/bin/sh", "-c", script]
  let process = startProcess(tools.monitorCliPath, workingDir = workRoot,
    args = args, options = {poStdErrToStdOut})
  let output = process.outputStream.readAll()
  let code = process.waitForExit()
  process.close()
  if code != 0:
    echo "`", tools.monitorCliPath, " ", args.join(" "), "` exited ", code,
      ":\n", output
  (code, output)

suite "DA-1i the evidence scope reaches io-mon":

  test "the CLI drops failed lookups under reads-only and keeps reads":
    ## Boundary 1, and the record-count claim. Two runs of ONE command; the
    ## only thing that differs is the flag.
    let repoRoot = findRepoRoot()
    let tools = monitorTools(repoRoot)
    let workRoot = makeWorkRoot()
    defer: removeDir(workRoot)

    let fullPath = workRoot / "full.iomon"
    let narrowPath = workRoot / "narrow.iomon"
    check runMonitorCli(tools, workRoot, fullPath,
      @["--evidence", "full"]).code == 0
    check runMonitorCli(tools, workRoot, narrowPath,
      @["--evidence", "reads-only"]).code == 0
    check fileExists(fullPath)
    check fileExists(narrowPath)

    let full = readMonitorDepFile(fullPath)
    let narrow = readMonitorDepFile(narrowPath)

    # THE STAMPS. `reads-only` is stated; `full` is deliberately not, because
    # an unstamped capture has always meant exactly full scope and stamping it
    # would change the profile-detail bytes of every capture that exists.
    if not narrow.observedEvidenceScopeStated:
      echo "a capture taken under `--evidence reads-only` did not state its ",
        "scope. An unstamped narrowing reads as FULL evidence to every ",
        "consumer, which is the false-complete this whole milestone closes."
    check narrow.observedEvidenceScopeStated
    check narrow.observedEvidenceScope == esReadsOnly
    check narrow.observedEvidenceScopeToken == "reads-only"
    check full.observedEvidenceScopeStated == false
    check effectiveObservedEvidenceScope(full) == esFull

    # THE DIRECTION. Not merely "different": the narrowed capture must be
    # SMALLER, and smaller by exactly the class it claims to drop.
    if narrow.records.len >= full.records.len:
      echo "reads-only recorded ", narrow.records.len,
        " records and full recorded ", full.records.len,
        ". The flag is being parsed and stamped but is not reaching the ",
        "record filter."
    check narrow.records.len < full.records.len

    # THE READ SURVIVES. A scope that dropped successful lookups too would
    # satisfy the count assertion above while being a different, broken thing.
    if pathsNaming(full, PresentName) == 0:
      echo "the full capture does not name `", PresentName,
        "`, so this fixture is not observing what it thinks it is and the ",
        "comparison below grades nothing."
    check pathsNaming(full, PresentName) > 0
    check pathsNaming(narrow, PresentName) > 0

    # THE FAILED LOOKUP IS GONE, and this is the hazard in one assertion: the
    # absent path is in the full record and in no part of the narrowed one, so
    # creating a file there later cannot invalidate a reads-only action.
    if pathsNaming(full, AbsentName) == 0:
      echo "the full capture does not name `", AbsentName,
        "`, so the fixture never performed a failed lookup and the drop ",
        "assertion below is vacuous."
    check pathsNaming(full, AbsentName) > 0
    if pathsNaming(narrow, AbsentName) != 0:
      echo "the reads-only capture still names `", AbsentName,
        "` ", pathsNaming(narrow, AbsentName),
        " time(s). The failed-lookup filter is not running."
    check pathsNaming(narrow, AbsentName) == 0

  test "the monitored child is told the scope through io-mon's own variable":
    ## Boundary 2. `REPRO_MONITOR_EVIDENCE` is the channel the SHIM reads, and
    ## it is io-mon's to write: `childEnv` sets it last, so a host that tried
    ## to seed it would be overwritten. Asserting the child's view is how we
    ## know the flag survived the hop rather than being parsed and dropped.
    let repoRoot = findRepoRoot()
    let tools = monitorTools(repoRoot)
    let workRoot = makeWorkRoot()
    defer: removeDir(workRoot)
    let seenPath = workRoot / "seen.txt"
    let script = "printf %s \"$REPRO_MONITOR_EVIDENCE\" > " &
      quoteShell(seenPath)
    check runMonitorCli(tools, workRoot, workRoot / "env.iomon",
      @["--evidence", "reads-only"], script).code == 0
    check fileExists(seenPath)
    let seen = if fileExists(seenPath): readFile(seenPath) else: ""
    if seen != "reads-only":
      echo "the monitor was asked for `reads-only` and told its child `",
        seen, "`. The `--evidence` flag is not reaching io-mon's `childEnv`."
    check seen == "reads-only"

suite "DA-1i the engine forwards the operator's scope":

  test "a monitored build under esReadsOnly writes a stamped capture":
    ## Boundary 3 — the whole path, from `BuildEngineConfig.evidenceScope` to
    ## a recorded observation, through the argv the engine composes.
    ##
    ## `monitorHosting` is left at its shipped default, so this exercises the
    ## WRAPPED path — a second `repro internal io monitor` process in between
    ## — which is the path every shipped configuration takes and therefore the
    ## one that must not lose the request.
    let repoRoot = findRepoRoot()
    let tools = monitorTools(repoRoot)
    let workRoot = makeWorkRoot()
    defer: removeDir(workRoot)

    proc buildUnder(scope: EvidenceScope; tag: string): MonitorDepFile =
      let cacheRoot = workRoot / ("cache-" & tag)
      var config = defaultBuildEngineConfig(cacheRoot)
      config.bypassRunQuota = true
      config.fallbackToRunQuotaBypass = true
      config.maxParallelism = 1'u32
      config.monitorCliPath = tools.monitorCliPath
      config.monitorCliArgs = tools.monitorCliArgs
      config.evidenceScope = scope
      let act = action("da1i/" & tag,
        ["/bin/sh", "-c", FixtureScript],
        cwd = workRoot,
        inputs = [PresentName],
        outputs = [],
        cacheable = true,
        weakFingerprint = weakFingerprintFromText("da1i." & tag),
        dependencyPolicy = automaticMonitorGatheringPolicy(),
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let res = runBuild(graph([act]), config)
      check res.results.len == 1
      if res.results[0].status != asSucceeded:
        echo "the monitored fixture action did not succeed under ", scope,
          ": status=", res.results[0].status,
          " reason=", res.results[0].reason
      check res.results[0].status == asSucceeded
      # A BUILD MUST NOT REFUSE ITS OWN CAPTURES. The requirement this build
      # applies when it READS a capture is derived from the same config field
      # that decided how the capture was TAKEN, so a `reads-only` run accepts
      # what it just recorded — and a `full` run does too. Getting the two
      # sides from one place is what makes that true; asserting it here is what
      # catches a future change that sets them apart, which would turn every
      # narrowed build into a build that publishes nothing at all.
      for diagnostic in res.results[0].evidence.diagnostics:
        if diagnostic.contains("is not trusted"):
          echo "the ", tag, " build refused its OWN capture: ", diagnostic
        check not diagnostic.contains("is not trusted")
      let depPath = res.results[0].monitorDepfilePath
      if depPath.len == 0 or not fileExists(depPath):
        echo "no monitor depfile was produced for the ", tag,
          " build (path=`", depPath, "`); nothing below is grading the flag."
      check depPath.len > 0
      check fileExists(depPath)
      readMonitorDepFile(depPath)

    let narrow = buildUnder(esReadsOnly, "narrow")
    let full = buildUnder(esFull, "full")

    if not narrow.observedEvidenceScopeStated:
      echo "the engine ran a build under `esReadsOnly` and io-mon wrote a ",
        "capture that states no scope. The engine's request is being ",
        "discarded between `BuildEngineConfig.evidenceScope` and the ",
        "monitor — the same discard the INTEREST axis shipped with."
    check narrow.observedEvidenceScopeStated
    check narrow.observedEvidenceScope == esReadsOnly
    check full.observedEvidenceScopeStated == false

    # And the narrowing took effect on the RECORDS, not only on the label.
    check pathsNaming(full, AbsentName) > 0
    check pathsNaming(narrow, AbsentName) == 0
    check pathsNaming(narrow, PresentName) > 0
