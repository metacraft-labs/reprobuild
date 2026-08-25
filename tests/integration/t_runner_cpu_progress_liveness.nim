## ``repro_test_runner`` decides "is this test still alive?" from FORWARD
## PROGRESS, not from silence.
##
## The defect this pins
## --------------------
## The D6 deadline was a pure idle-*output* heuristic: a case that emitted
## nothing for ``--test-timeout`` seconds was SIGKILLed and reported
## ``IDLE TIMEOUT``. Silence is not a hang. A test starved of CPU by fifteen
## sibling workers — or by unrelated load on this shared CI runner — is quiet
## while making real progress, and the heuristic cannot tell it apart from a
## deadlock. Measured consequence: a full-suite run at 16 workers killed 28
## cases at ~600 s, and seven tests that PASS at one worker FAILED at sixteen
## while merely running ~3x slower. The heuristic manufactured failures out of
## parallelism.
##
## The fix adds a second progress signal — cumulative CPU consumed by the
## test's process group, read from ``/proc/<pid>/stat`` — and kills only when
## BOTH signals are flat. A starved-but-running test advances CPU; a
## deadlocked one does not.
##
## Progress-based liveness alone would then let a *livelock* run forever
## (reprobuild has a real one: ``t_stackable_hooks_extracted_process_tree``
## spun at 94% CPU for 19 hours). So the absolute ceiling of
## ``AbsoluteTimeoutMultiplier × --test-timeout`` is not a backstop any more,
## it is the only rule that can end a spinner — and it must stay
## distinguishable in the log from the no-progress rule.
##
## Three real arms, one runner invocation, ``--test-timeout=6``
## (⇒ absolute ceiling 24 s):
##
##   1. ``t_cpu_liveness_working``  — prints once, then a CHILD burns CPU
##      silently for 12 s while the group leader waits. Silent for 2x the idle
##      window. MUST PASS. Under the old output-only rule this was killed at
##      6 s. The work is in a child on purpose: it also pins the requirement
##      that the CPU signal covers the whole process group, not just the
##      leader — the shape every heavy test in this suite actually has.
##   2. ``t_cpu_liveness_wedged``   — prints once, then sleeps 120 s consuming
##      no CPU. MUST still be killed on the no-progress deadline, with the
##      observed CPU advance below the progress threshold. This arm is the
##      regression guard: the fix must not make hangs survivable.
##   3. ``t_cpu_liveness_livelock`` — prints once, then spins forever. The CPU
##      signal says "alive" indefinitely, so ONLY the absolute ceiling can end
##      it. MUST be killed at ~24 s and MUST be reported as
##      ``ABSOLUTE TIMEOUT``, not ``IDLE TIMEOUT``. Under the old rule it died
##      at 6 s with the wrong label.
##
## MOCKS: none, and none are justifiable here. Every claim this file makes is
## about how the runner reads the operating system's own accounting of real
## processes: real ``fork``/``exec`` through the runner's process-group
## supervisor, real ``/proc`` CPU counters, real SIGTERM/SIGKILL escalation,
## real summary JSON. A mocked clock or a mocked CPU sampler would assert only
## that the arithmetic in this file matches the arithmetic in the runner, and
## would have been equally green before the fix — which is exactly the failure
## mode that let the original heuristic ship.
##
## The fixtures are compiled at run time (as ``t_d6_runner_test_timeout.nim``
## already does). That is a known wart tracked by the "graph-owned test
## artifacts" milestone; it is not new debt introduced here.

import std/[json, os, osproc, strutils, times, unittest]

const RepoMarker = "repro.nim"

const IdleWindowSec = 6
  ## Short enough to keep the whole file under a minute, long enough that
  ## process spawn and Nim runtime start-up cannot be mistaken for the
  ## measured behaviour. The runner derives its absolute ceiling from this:
  ## 4 x 6 = 24 s.

const AbsoluteCeilingSec = IdleWindowSec * 4

const WorkingBurnSec = 12
  ## > IdleWindowSec (so output-only liveness kills it) and comfortably
  ## < AbsoluteCeilingSec (so the ceiling does not).

const WorkingFixtureSource = """
import std/[os, osproc, times]
# Re-exec of self: the work happens in a CHILD of the case's process-group
# leader, and the leader itself sits in waitpid consuming nothing. That shape
# is deliberate. It is how nearly every heavy test in this suite actually
# spends its time (nim, cc, repro, daemons), and it means the runner's
# liveness signal has to sum the whole process GROUP. A signal that read only
# the leader would see a flat zero here and kill a perfectly healthy test.
if paramCount() >= 1 and paramStr(1) == "burn":
  let deadline = epochTime() + """ & $WorkingBurnSec & """.0
  var acc = 0.0
  var i = 0
  while epochTime() < deadline:
    acc += float(i mod 7) * 1.000001
    i = (i + 1) mod 1_000_000
  # ``acc`` is consumed so -d:release cannot delete the loop.
  quit(if acc < 0.0: 1 else: 0)
echo "cpu-liveness working fixture: a child burns CPU; this leader only waits"
stdout.flushFile()
let child = startProcess(getAppFilename(), args = ["burn"],
  options = {poParentStreams})
let code = child.waitForExit()
child.close()
quit(code)
"""

const WedgedFixtureSource = """
import std/os
echo "cpu-liveness wedged fixture: no output and no CPU from here on"
stdout.flushFile()
sleep(120_000)
quit(0)
"""

const LivelockFixtureSource = """
echo "cpu-liveness livelock fixture: spinning forever, always 'making progress'"
stdout.flushFile()
var acc = 0.0
var i = 0
while true:
  acc += float(i mod 7) * 1.000001
  i = (i + 1) mod 1_000_000
  if acc < 0.0:
    quit(1)
"""

type
  CaseFindings = object
    found: bool
    status: string
    durationMs: int
    stdout: string

  RunFindings = object
    wallSec: float
    runnerOut: string
    runnerExit: int
    entries: int
    working: CaseFindings
    wedged: CaseFindings
    livelock: CaseFindings

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc compileFixture(src, bin, source: string) =
  writeFile(src, source)
  let cmd = "nim c -d:release --hints:off --warnings:off --out:" &
    quoteShell(bin) & " " & quoteShell(src)
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    raise newException(IOError,
      "fixture compile failed (exit " & $exitCode & "):\n" & output)
  if not fileExists(bin):
    raise newException(IOError, "fixture binary missing after compile: " & bin)

proc resolveRunner(repoRoot, tmpDir: string): string =
  ## Prefer the runner ``scripts/run_tests.sh`` builds. When it is absent
  ## (the suite is being driven by ``ct-test-runner``), build a private copy
  ## rather than skipping: a skip here would leave the whole defect
  ## unguarded, and the binary is the thing under test.
  ##
  ## The private copy deliberately does NOT write to ``build/bin`` — on Linux
  ## overwriting a running executable fails with ETXTBSY, and this very test
  ## may be executing under that binary.
  let canonical = repoRoot / "build" / "bin" /
    addFileExt("repro_test_runner", ExeExt)
  if fileExists(canonical):
    return canonical
  let src = repoRoot / "tools" / "test-runner" / "repro_test_runner.nim"
  if not fileExists(src):
    raise newException(IOError, "runner source missing: " & src)
  let bin = tmpDir / addFileExt("repro_test_runner_private", ExeExt)
  let cmd = "nim c -d:release --threads:on --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(tmpDir / "nimcache") &
    " --out:" & quoteShell(bin) & " " & quoteShell(src)
  let (output, exitCode) = execCmdEx(cmd)
  if exitCode != 0:
    raise newException(IOError,
      "could not build a private repro_test_runner (exit " & $exitCode &
      "):\n" & output)
  bin

proc numberAfter(text, key: string): float =
  ## Pull the float that follows ``key`` in the runner's evidence line, e.g.
  ## ``group-cpu=12.34s`` -> 12.34. Returns NaN-ish -1.0 when absent so a
  ## caller can assert on presence separately.
  let at = text.find(key)
  if at < 0:
    return -1.0
  var idx = at + key.len
  var digits = ""
  while idx < text.len and (text[idx] in {'0' .. '9', '.', '-'}):
    digits.add(text[idx])
    inc idx
  if digits.len == 0:
    return -1.0
  try:
    parseFloat(digits)
  except ValueError:
    -1.0

proc readCase(tests: JsonNode; stem: string): CaseFindings =
  for entry in tests:
    if entry{"binary_stem"}.getStr() == stem:
      result.found = true
      result.status = entry{"status"}.getStr()
      result.durationMs = entry{"duration_ms"}.getInt()
      result.stdout = entry{"stdout"}.getStr()
      return

proc runFixtures(): RunFindings =
  let repoRoot = findRepoRoot()
  let tmpDir = getTempDir() / "reprobuild_runner_cpu_progress_liveness"
  if dirExists(tmpDir):
    removeDir(tmpDir)
  createDir(tmpDir)
  defer:
    try:
      removeDir(tmpDir)
    except CatchableError:
      discard

  let binDir = tmpDir / "bin"
  createDir(binDir)
  let runnerBin = resolveRunner(repoRoot, tmpDir)

  for (stem, source) in {
      "t_cpu_liveness_working": WorkingFixtureSource,
      "t_cpu_liveness_wedged": WedgedFixtureSource,
      "t_cpu_liveness_livelock": LivelockFixtureSource}.items:
    compileFixture(tmpDir / (stem & ".nim"), binDir / addFileExt(stem, ExeExt),
      source)

  let summaryPath = tmpDir / "summary.json"
  let runnerCmd = @[
    quoteShell(runnerBin),
    "--no-build",
    "--threads=1",
    "--test-timeout=" & $IdleWindowSec,
    "--bin-dir=" & quoteShell(binDir),
    "--summary-json=" & quoteShell(summaryPath),
    "--results-dir=" & quoteShell(tmpDir / "results"),
  ].join(" ")

  let t0 = epochTime()
  let (runnerOut, runnerExit) = execCmdEx(runnerCmd)
  result.wallSec = epochTime() - t0
  result.runnerOut = runnerOut
  result.runnerExit = runnerExit

  if not fileExists(summaryPath):
    raise newException(IOError,
      "runner produced no summary at " & summaryPath & " (exit " &
      $runnerExit & "):\n" & runnerOut)
  let summary = parseFile(summaryPath)
  let tests = summary{"tests"}
  if tests.isNil or tests.kind != JArray:
    raise newException(IOError,
      "summary lacks a ``tests`` array: " & summary.pretty())
  result.entries = tests.len
  result.working = readCase(tests, "t_cpu_liveness_working")
  result.wedged = readCase(tests, "t_cpu_liveness_wedged")
  result.livelock = readCase(tests, "t_cpu_liveness_livelock")

# One runner invocation feeds all three behavioural arms; spawning it once
# per ``test`` block would triple a ~45 s cost for no extra evidence.
#
# It is memoised behind a proc rather than computed at module scope on
# purpose: this binary is protocol-aware, so the runner executes it a second
# time as ``--list-json`` during discovery. Work at module scope would run the
# whole 45 s fixture sweep inside that probe, blow the probe budget, and get
# the binary silently downgraded to whole-binary execution.
var cachedFindings: RunFindings
var findingsReady = false

proc findings(): RunFindings =
  if not findingsReady:
    cachedFindings = runFixtures()
    findingsReady = true
  cachedFindings

suite "repro_test_runner liveness is progress-based, not silence-based":

  test "structural: the runner reads process-group CPU as a liveness signal":
    let repoRoot = findRepoRoot()
    let runnerSrc = repoRoot / "tools" / "test-runner" /
      "repro_test_runner.nim"
    check fileExists(runnerSrc)
    let text = readFile(runnerSrc)
    # The signal itself, and the fact that it is read from the kernel's own
    # accounting rather than inferred from the output stream.
    check "processGroupCpuSeconds" in text
    check "/proc" in text
    check "cpuProgressThresholdSec" in text
    # "Unavailable" must be a distinct third state from "measured zero",
    # otherwise a host without the signal declares every test deadlocked.
    check "CpuUnavailable" in text
    # Both kill rules must exist and be separately labelled.
    check "IDLE TIMEOUT" in text
    check "ABSOLUTE TIMEOUT" in text
    check "AbsoluteTimeoutMultiplier" in text

  test "a silent but CPU-consuming test is NOT killed by the idle deadline":
    let f = findings()
    checkpoint("runner exit=" & $f.runnerExit & " wall=" &
      formatFloat(f.wallSec, ffDecimal, 1) & "s")
    check f.entries == 3
    check f.working.found
    checkpoint("working: status=" & f.working.status & " duration=" &
      $f.working.durationMs & "ms stdout=" & f.working.stdout)
    # The load-bearing assertion. The fixture is silent for 12 s with a 6 s
    # idle window; output-only liveness kills it at 6 s and reports FAIL.
    check f.working.status == "PASS"
    # And it really did run to completion rather than being short-circuited:
    # a PASS at 2 s would mean the fixture never burned anything.
    check f.working.durationMs >= (WorkingBurnSec - 2) * 1000
    check f.working.durationMs < AbsoluteCeilingSec * 1000

  test "a silent test consuming no CPU is still killed, with the numbers":
    let f = findings()
    check f.wedged.found
    checkpoint("wedged: status=" & f.wedged.status & " duration=" &
      $f.wedged.durationMs & "ms")
    checkpoint("wedged stdout: " & f.wedged.stdout)
    check f.wedged.status == "FAIL"
    check "IDLE TIMEOUT after " & $IdleWindowSec & "s without output" in
      f.wedged.stdout
    check "SIGKILLed" in f.wedged.stdout
    # It must die on the no-progress rule, not by running into the ceiling.
    check "ABSOLUTE TIMEOUT" notin f.wedged.stdout
    check f.wedged.durationMs < AbsoluteCeilingSec * 1000

    # The diagnostic must carry the observed numbers, so a timeout in a CI
    # log is diagnosable without a live process to inspect.
    check "elapsed=" in f.wedged.stdout
    check "group-cpu=" in f.wedged.stdout
    check "cpu-since-last-progress=" in f.wedged.stdout
    check "last-output-age=" in f.wedged.stdout

    # And those numbers must actually describe a wedge: the CPU advance the
    # runner measured has to be below the threshold it compared against.
    let advance = numberAfter(f.wedged.stdout,
      "cpu-since-last-progress=")
    let threshold = numberAfter(f.wedged.stdout,
      "cpu-progress-threshold=")
    checkpoint("wedged cpu advance=" & $advance & " threshold=" & $threshold)
    check threshold > 0.0
    check advance >= 0.0
    check advance < threshold
    let outputAge = numberAfter(f.wedged.stdout, "last-output-age=")
    check outputAge >= IdleWindowSec.float

  test "a CPU-burning livelock is killed by the absolute ceiling, and says so":
    let f = findings()
    check f.livelock.found
    checkpoint("livelock: status=" & f.livelock.status & " duration=" &
      $f.livelock.durationMs & "ms")
    checkpoint("livelock stdout: " & f.livelock.stdout)
    check f.livelock.status == "FAIL"
    # A spinner satisfies the CPU-progress signal forever. Only the ceiling
    # can end it, and the message must name that rule — a run that reports
    # IDLE TIMEOUT here is one where the CPU signal is not being consulted.
    check "ABSOLUTE TIMEOUT after " & $AbsoluteCeilingSec & "s" in
      f.livelock.stdout
    check "IDLE TIMEOUT" notin f.livelock.stdout
    check "SIGKILLed" in f.livelock.stdout
    # It survived well past the 6 s idle window precisely because it was
    # making CPU progress.
    check f.livelock.durationMs >= (AbsoluteCeilingSec - 4) * 1000
    check f.livelock.durationMs < (AbsoluteCeilingSec + 30) * 1000
    let groupCpu = numberAfter(f.livelock.stdout, "group-cpu=")
    checkpoint("livelock group cpu=" & $groupCpu)
    # It really was burning: at ~24 s of spin this is ~24 s of CPU. The
    # bound is deliberately loose so a loaded host cannot flake it, while
    # still being unreachable by the wedged fixture's ~0.00 s.
    check groupCpu > 3.0
