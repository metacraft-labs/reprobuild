## The HLX-M4 concurrency gate's verdict must not depend on host load.
##
## Issue: reprobuild-pm `issues/2026-09-26-hcr-concurrent-patch-gate-verdict-
## depends-on-host-load.md`. On a 32-CPU host at load 150-215 the gate
## `e2e_hcr_linux_concurrent_patch_no_torn_instruction` failed about half its
## runs, in five different shapes, while the safety property it exists for
## held in every run. A red there could not be told apart from a regression.
##
## The fix has two halves, and this file tests both:
##
##   * A §6.3 quiescence timeout is a DEFINED outcome. The fixture now retries
##     it (bounded), counts it, and checks it wrote nothing, instead of
##     silently dropping a publication the harness then found missing. Tested
##     against the real fixture with a deadline no process can meet.
##   * The negative controls' crash rates are calibrated statistics. The gate
##     reads the host condition before every run and reports runs outside the
##     calibrated envelope as "conditions not met" — never as a failure, and
##     never as a pass. Tested on `m4_verdict.gateVerdict` directly, with the
##     tallies the issue measured, each one TWICE: on a loaded host it must
##     not fail, and the identical tally on an unloaded host MUST fail, so the
##     conditions can only withhold a verdict, never hide one.
##
## `allowed_mocks`: the verdict cases feed `gateVerdict` synthetic run records
## instead of fixture processes. That is the point of them, not a shortcut: the
## shapes the issue recorded are load-dependent and cannot be produced on
## demand — confining the fixture to one CPU, or saturating four CPUs with
## busy loops, left `tier1` at 18-22/24 (measured 2026-10-15) — and the
## property under test is what the verdict DOES with such a tally. Every
## record carries exactly the fields `runFixture` parses from a real fixture,
## with the fixture's own key names. The abort case runs the real fixture.

import std/[json, math, os, strutils, unittest]

import m4_verdict
import repro_test_support/reasoned_skip

const
  Runs = 24
  Publications = 8
  SampleRounds = 200
  Workers = 12
  Slots = 14
  Window = 0x5000'u64
  Calm = 0.5       # load/CPU well inside the calibrated envelope
  Loaded = 5.5     # the issue's host: load 150-215 on 32 CPUs is 4.7-6.7

proc payload(publications = Publications; aborts = 0; abandoned = 0;
             abortWrites = 0; other = 0; anomalies = 0; adjust = 3;
             nested = 1; wx = 0; textReplaced = true): JsonNode =
  %*{"publicationsApplied": publications, "anomalies": anomalies,
     "quiesceAdjustCount": adjust, "quiesceNestedAdjustCount": nested,
     "wxRequestsRefused": wx, "quiesceAborts": aborts,
     "quiesceBlockedAborts": 0, "quiesceAbortWrites": abortWrites,
     "quiesceAbandoned": abandoned, "quiesceOtherFailures": other,
     "lastTextReplaced": textReplaced}

proc survived(load: float; p = payload()): ArmRun =
  ArmRun(exitCode: 0, payload: p, faultSignal: -1, loadPerCpu: load)

proc crashedAt(load: float; offset = 3; signal = 4): ArmRun =
  ArmRun(exitCode: 70, crashed: true, windowAddress: Window,
         faultPc: uint64(int64(Window) + offset), faultSignal: signal,
         loadPerCpu: load)

proc strayExit(load: float; code = 139): ArmRun =
  ArmRun(exitCode: code, faultSignal: -1, loadPerCpu: load,
         stderrText: "killed")

proc arm(mode: string; runs: seq[ArmRun]): ArmResult =
  result.mode = mode
  for r in runs: result.add(r)

proc times(n: int; r: ArmRun): seq[ArmRun] =
  for i in 0 ..< n: result.add(r)

## The milestone's measured healthy shape: tier2 0/24, tier1 and
## tier2-noadjust ~20/24, torn 24/24, all faults at window+3.
proc healthyTier2(load = Calm): ArmResult = arm("tier2", times(Runs, survived(load)))
proc healthyTier1(load = Calm): ArmResult =
  arm("tier1", times(20, crashedAt(load)) & times(4, survived(load)))
proc healthyNoAdjust(load = Calm): ArmResult =
  arm("tier2-noadjust", times(20, crashedAt(load)) & times(4, survived(load)))
proc healthyTorn(load = Calm): ArmResult = arm("torn", times(Runs, crashedAt(load)))

proc samplePayload(rounds = SampleRounds; failures = 0): JsonNode =
  %*{"quiesceRounds": rounds, "quiesceFailures": failures,
     "quiesceAbortWrites": 0, "quiesceOtherFailures": 0,
     "parkedObservations": rounds * Slots, "parkedPcInWindow": 180,
     "parkedPcInSled": 400, "distinctWorkerTids": Workers,
     "chaosSignalsDelivered": 1000, "membarrierSyncCore": true,
     "wxRequestsRefused": 0}

proc healthySample(load = Calm): SampleRun =
  SampleRun(exitCode: 0, payload: samplePayload(), loadPerCpu: load)

proc verdictOf(sample = healthySample(); tier2 = healthyTier2();
               tier1 = healthyTier1(); noAdjust = healthyNoAdjust();
               torn = healthyTorn()): Verdict =
  gateVerdict(sample, tier2, tier1, noAdjust, torn, runs = Runs,
    publications = Publications, sampleRounds = SampleRounds, slots = Slots,
    workers = Workers)

proc gateFails(v: Verdict): bool =
  ## What the gate does with a verdict: unconditional failures always fail;
  ## conditional ones fail only when the conditions held.
  v.failures(includeConditional = v.conditionsMet).len > 0

template expectNotMetNotFailed(v: Verdict) =
  checkpoint("unconditional failures: " & $v.failures(false))
  check not v.conditionsMet
  check v.conditionsReason.len > 0
  check not v.gateFails()

template expectFailedWith(v: Verdict; message: string) =
  checkpoint("conditionsMet " & $v.conditionsMet & "; failures " &
    $v.failures(true))
  check v.gateFails()
  check message in v.failures(includeConditional = v.conditionsMet)

suite "HLX-M4 gate verdict: conditions are reported apart from failures":
  test "the verdict is the full check list, with the unconditional subset pinned":
    let v = verdictOf()
    var unconditional = 0
    for c in v.checks:
      if not c.conditional: inc unconditional
    check v.checks.len == GateCheckCount
    check unconditional == GateUnconditionalCheckCount

  test "positive control: the milestone's healthy shape passes on a calm host":
    let v = verdictOf()
    checkpoint($v.failures(true))
    check v.conditionsMet
    check v.failures(includeConditional = true).len == 0
    check not v.gateFails()

  test "shape 1: a publication lost to repeated quiescence timeouts":
    # Issue: `tier2.publications was 191`, `Runs * Publications was 192`.
    proc lost(load: float): ArmResult =
      arm("tier2", times(Runs - 1, survived(load)) &
        @[survived(load, payload(publications = Publications - 1,
                                 aborts = 8, abandoned = 1))])
    expectNotMetNotFailed verdictOf(tier2 = lost(Loaded),
      tier1 = healthyTier1(Loaded), noAdjust = healthyNoAdjust(Loaded),
      torn = healthyTorn(Loaded), sample = healthySample(Loaded))
    # The same loss on a calm host is a quiescence regression.
    expectFailedWith verdictOf(tier2 = lost(Calm)),
      "every tier-2 run published everything it was asked to"
    # And a timeout the fixture RETRIED costs nothing: §6.3 is an outcome.
    let retried = arm("tier2", times(Runs, survived(Calm,
      payload(aborts = 1))))
    let v = verdictOf(tier2 = retried)
    check v.conditionsMet
    check v.failures(true).len == 0

  test "shape 2: the sample arm did not quiesce every round":
    let short = samplePayload(rounds = SampleRounds - 1, failures = 1)
    expectNotMetNotFailed verdictOf(
      sample = SampleRun(exitCode: 0, payload: short, loadPerCpu: Loaded))
    expectFailedWith verdictOf(
      sample = SampleRun(exitCode: 0, payload: short, loadPerCpu: Calm)),
      "every sampling round reached quiescence"

  test "shape 3: the negative controls died less than half the time":
    # Issue: tier1 10/24, tier2-noadjust 18/24 and 11/24.
    proc weak(mode: string; crashes: int; load: float): ArmResult =
      arm(mode, times(crashes, crashedAt(load)) &
        times(Runs - crashes, survived(load)))
    expectNotMetNotFailed verdictOf(tier1 = weak("tier1", 10, Loaded))
    expectNotMetNotFailed verdictOf(
      noAdjust = weak("tier2-noadjust", 11, Loaded))
    expectFailedWith verdictOf(tier1 = weak("tier1", 10, Calm)),
      "tier-1 fails often, not marginally"
    expectFailedWith verdictOf(noAdjust = weak("tier2-noadjust", 11, Calm)),
      "the adjustment's removal fails often, not marginally"

  test "shape 4: a torn run faulted outside the 8-byte window":
    # Issue: `torn run 12 faulted at window+220, outside the 8-byte window`.
    proc stray(load: float): ArmResult =
      arm("torn", times(Runs - 1, crashedAt(load)) &
        @[crashedAt(load, offset = 220, signal = 11)])
    expectNotMetNotFailed verdictOf(torn = stray(Loaded))
    expectFailedWith verdictOf(torn = stray(Calm)),
      "torn: every fault landed INSIDE the 8-byte window"

  test "shape 5: a negative-control run exited without a crash record":
    proc withStray(load: float): ArmResult =
      arm("tier2-noadjust", times(19, crashedAt(load)) &
        times(4, survived(load)) & @[strayExit(load)])
    expectNotMetNotFailed verdictOf(noAdjust = withStray(Loaded))
    expectFailedWith verdictOf(noAdjust = withStray(Calm)),
      "tier2-noadjust: no run exited non-zero without an rc-70 crash record"

  test "a loaded run is excluded, not counted, when the arm can still complete":
    # 24 calm runs plus a loaded one that lost a publication: the arm has its
    # 24 measured runs, so the conditions held and the verdict is real.
    let mixed = arm("tier2", times(Runs, survived(Calm)) &
      @[survived(Loaded, payload(publications = 7, aborts = 8, abandoned = 1))])
    let v = verdictOf(tier2 = mixed)
    check v.conditionsMet
    check v.failures(true).len == 0
    check mixed.all.runs == Runs + 1
    check mixed.measured.runs == Runs

suite "HLX-M4 gate verdict: what is never conditional":
  test "a tier-2 crash fails the gate on any host":
    let t2 = arm("tier2", times(Runs - 1, survived(Loaded)) &
      @[crashedAt(Loaded)])
    let v = verdictOf(tier2 = t2, sample = healthySample(Loaded))
    check not v.conditionsMet
    expectFailedWith v, "no tier-2 run faulted"

  test "a tier-2 stray exit or third value fails the gate on any host":
    let stray = arm("tier2", times(Runs - 1, survived(Loaded)) &
      @[strayExit(Loaded)])
    expectFailedWith verdictOf(tier2 = stray),
      "tier2: no run exited non-zero without an rc-70 crash record"
    let third = arm("tier2", times(Runs - 1, survived(Loaded)) &
      @[survived(Loaded, payload(anomalies = 3))])
    expectFailedWith verdictOf(tier2 = third),
      "no tier-2 run observed a third return value"

  test "a negative control that never crashed fails the gate on any host":
    let toothless = arm("tier1", times(Runs, survived(Loaded)))
    expectFailedWith verdictOf(tier1 = toothless),
      "tier-1 publication fails under concurrent execution"
    let noTorn = arm("torn", times(Runs, survived(Loaded)))
    expectFailedWith verdictOf(torn = noTorn),
      "the non-atomic publication was detected at least once"

  test "a quiescence abort that changed the window fails the gate on any host":
    let wrote = arm("tier2", times(Runs - 1, survived(Loaded)) &
      @[survived(Loaded, payload(aborts = 1, abortWrites = 1))])
    expectFailedWith verdictOf(tier2 = wrote),
      "tier2: no quiescence abort changed the publication window"
    let refused = arm("tier2", times(Runs - 1, survived(Loaded)) &
      @[survived(Loaded, payload(other = 1))])
    expectFailedWith verdictOf(tier2 = refused),
      "tier2: no quiescence was refused for a reason other than a timeout"

  test "a retried sample attempt's unconditional failure is not forgotten":
    # The gate starts `sample` again when an attempt started outside the
    # conditions. A loaded attempt that asked for W+X, or died, is a
    # regression on any host, and a clean calm retry must not erase it.
    var wx = samplePayload()
    wx["wxRequestsRefused"] = %1
    let calm = healthySample(Calm)
    let v = gateVerdict([SampleRun(exitCode: 0, payload: wx, loadPerCpu: Loaded),
                         calm], healthyTier2(), healthyTier1(), healthyNoAdjust(),
      healthyTorn(), runs = Runs, publications = Publications,
      sampleRounds = SampleRounds, slots = Slots, workers = Workers)
    check v.conditionsMet
    expectFailedWith v, "the provider requested no writable+executable mapping"
    let died = gateVerdict([SampleRun(exitCode: 139, loadPerCpu: Loaded),
                            calm], healthyTier2(), healthyTier1(),
      healthyNoAdjust(), healthyTorn(), runs = Runs,
      publications = Publications, sampleRounds = SampleRounds,
      slots = Slots, workers = Workers)
    expectFailedWith died, "the sampling arm exited cleanly"
    expectFailedWith died, "the sampling arm produced a result"
    # Positive control: two clean attempts, the first loaded, pass.
    let clean = gateVerdict([healthySample(Loaded), calm], healthyTier2(),
      healthyTier1(), healthyNoAdjust(), healthyTorn(), runs = Runs,
      publications = Publications, sampleRounds = SampleRounds,
      slots = Slots, workers = Workers)
    check clean.conditionsMet
    check clean.failures(true).len == 0

  test "an arm stops at its attempt cap and reports the conditions it saw":
    var started = 0
    let starved = collectArm("tier1", Runs, proc (): ArmRun =
      inc started
      crashedAt(Loaded))
    check started == Runs * AttemptsPerRun
    check starved.measured.runs == 0
    check not starved.complete(Runs)
    let v = verdictOf(tier1 = starved)
    check not v.conditionsMet
    check "tier1: 0/24 runs" in v.conditionsReason
    var calm = 0
    let fed = collectArm("tier1", Runs, proc (): ArmRun =
      inc calm
      crashedAt(if calm mod 2 == 0: Calm else: Loaded))
    check fed.measured.runs == Runs
    check fed.all.runs == 2 * Runs

when defined(linux) and defined(amd64):
  import m4_fixture

  suite "HLX-M4 fixture: a §6.3 quiescence timeout is retried, counted and writes nothing":
    test "a deadline nobody can meet is an abort on every attempt, never a lost write":
      let repoRoot = getCurrentDir()
      let bodies = buildPatchBodies(repoRoot)
      let threadsBin = buildFixture(repoRoot, "hcr_lx_m4_threads.c",
                                    "m4_threads")
      # 1 ns: no thread group parks that fast, so every attempt times out and
      # the outcome is deterministic. The nested-frame scan is switched off
      # because it is irrelevant to abort accounting and, on kernel 6.18,
      # crashes the handler (reprobuild-pm issues/2026-10-13-hcr-linux-thread-
      # fixtures-segfault-after-reboot-onto-kernel-6-18.md).
      putEnv("HCR_M4_QUIESCE_TIMEOUT_NS", "1")
      putEnv("HCR_M4_DISABLE_NESTED_SCAN", "1")
      defer:
        delEnv("HCR_M4_QUIESCE_TIMEOUT_NS")
        delEnv("HCR_M4_DISABLE_NESTED_SCAN")
      const Rounds = 8
      const Attempts = 8   # QUIESCE_ATTEMPTS in the fixture
      for mode in ["sample", "tier2"]:
        let r = runFixture(threadsBin, [mode, hex(bodies.a), hex(bodies.b),
                                        "12", $Rounds, "2"])
        checkpoint(mode & ": " & r.stderrText)
        check r.exitCode == 0
        require r.payload != nil
        let p = r.payload
        checkpoint($p)
        # Every attempt of every round was an abort, and was retried.
        check p["quiesceAborts"].getInt() == Rounds * Attempts
        check p["quiesceAbandoned"].getInt() == Rounds
        check p["quiesceFailures"].getInt() == Rounds
        check p["quiesceRounds"].getInt() == 0
        # §6.3: the provider wrote nothing — the window is unchanged after
        # every abort, and no publication was made without quiescence.
        check p["quiesceAbortWrites"].getInt() == 0
        check p["publicationsApplied"].getInt() == 0
        check p["quiesceOtherFailures"].getInt() == 0

    test "the host condition is readable":
      let load = hostLoadPerCpu()
      checkpoint("load/CPU " & $load)
      check load >= 0.0
      check load != Inf
      check not isNaN(load)
else:
  suite "HLX-M4 fixture: a §6.3 quiescence timeout is retried, counted and writes nothing":
    test "the HLX-M4 fixture is linux-x86_64-only":
      skip("the HLX-M4 fixture drives the Linux x86_64 HCR provider")
