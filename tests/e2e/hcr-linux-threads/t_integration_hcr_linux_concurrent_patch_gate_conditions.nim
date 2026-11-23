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
##     reads its run condition before every run and reports runs outside the
##     calibrated envelope as "conditions not met" — never as a failure, and
##     never as a pass. Tested on `m4_verdict.gateVerdict` directly, with the
##     tallies the issue measured, each one TWICE: on a loaded host it must
##     not fail, and the identical tally on an unloaded host MUST fail, so the
##     conditions can only withhold a verdict, never hide one.
##
## Since 2026-11-23 it also tests the condition itself (`m4_conditions`): the
## CPU-set-scoped reading that replaced host `/proc/loadavg` over
## `countProcessors()`, the available-CPU count and where it came from, and the
## calibration record that decides which readings count -- including that an
## absent or pending record withholds the verdict with the reason "condition
## not yet calibrated on a dedicated host" and counts no run as evidence
## (reprobuild-pm `issues/2026-11-22-no-ci-host-meets-the-hlx-m4-gates-
## calibrated-load-conditions.md`).
##
## `allowed_mocks`: the verdict cases feed `gateVerdict` synthetic run records
## instead of fixture processes. That is the point of them, not a shortcut: the
## shapes the issue recorded are load-dependent and cannot be produced on
## demand — confining the fixture to one CPU, or saturating four CPUs with
## busy loops, left `tier1` at 18-22/24 (measured 2026-10-15) — and the
## property under test is what the verdict DOES with such a tally. Every
## record carries exactly the fields `runFixture` parses from a real fixture,
## with the fixture's own key names. The abort case runs the real fixture.
##
## The condition-reading cases run the production readers against REAL files:
## a directory tree laid out like `/proc` and `/sys` (status, cgroup, stat,
## schedstat, PSI, cpu.max, the online list), read through the same code paths
## that read the host's. That is a fixture, not a mock: the parsers and the
## path walk under test are the ones the gate uses, and the inputs are the
## kernel's own formats, copied from a 6.18 host. A tree is needed because the
## shapes under test -- an 8-CPU affinity slice of a 32-CPU host, a cpu.max
## quota on an ancestor, a schedstat version this parser does not know --
## cannot be produced on demand on the machine running the test. One seam is
## used: `sampleCondition`'s `wait` callback, which a case uses to advance the
## fixture's counters between the two snapshots instead of sleeping. It sleeps
## the real window too, so the elapsed time is the real monotonic clock's.
## The case "the condition is readable on this host" reads the real `/proc`.

import std/[json, math, os, strutils, tables, tempfiles, unittest]

import m4_verdict
import repro_test_support/reasoned_skip

const
  Runs = 24
  Publications = 8
  SampleRounds = 200
  Workers = 12
  Slots = 14
  Window = 0x5000'u64
  Calm = 0.5       # a reading well inside the synthetic envelope below
  Loaded = 5.5     # the issue's host: load 150-215 on 32 CPUs is 4.7-6.7
  JustOutside = 2.6  # outside the envelope, but only just
  ## A synthetic APPROVED record for the verdict cases. Its 2.0 is chosen so
  ## Calm / Loaded / JustOutside keep the roles they had under the retired
  ## load/CPU bound; it is not the gate's bound, which comes from
  ## `hlx_m4_calibration.json` and is pending a dedicated-host calibration.
  Calibrated = Calibration(calibrated: true, maxReading: 2.0,
    windowMs: DefaultWindowMs, recordPath: "<synthetic test record>",
    status: "calibrated", host: "synthetic", date: "2026-11-23",
    kernel: "6.18.55", cpuSet: "8-15", approvedBy: "test")
  BenchAffinity = "affinity 8-15 (8); cpu.max max on /system.slice/bench"

proc at(reading: float; cpus = 8.0): ConditionReading =
  ## A condition reading as the benchmark runner's slot would produce it.
  ConditionReading(value: reading, budget: CpuBudget(cpus: cpus,
    affinity: @[8, 9, 10, 11, 12, 13, 14, 15], quotaCpus: Inf,
    source: BenchAffinity))

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
  ArmRun(exitCode: 0, payload: p, faultSignal: -1, condition: at(load))

proc crashedAt(load: float; offset = 3; signal = 4): ArmRun =
  ArmRun(exitCode: 70, crashed: true, windowAddress: Window,
         faultPc: uint64(int64(Window) + offset), faultSignal: signal,
         condition: at(load))

proc strayExit(load: float; code = 139): ArmRun =
  ArmRun(exitCode: code, faultSignal: -1, condition: at(load),
         stderrText: "killed")

proc arm(mode: string; runs: seq[ArmRun];
         calibration = Calibrated): ArmResult =
  result.mode = mode
  for r in runs: result.add(r, calibration)

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
  SampleRun(exitCode: 0, payload: samplePayload(), condition: at(load))

proc verdictOf(sample = healthySample(); tier2 = healthyTier2();
               tier1 = healthyTier1(); noAdjust = healthyNoAdjust();
               torn = healthyTorn(); calibration = Calibrated): Verdict =
  gateVerdict(sample, tier2, tier1, noAdjust, torn, runs = Runs,
    publications = Publications, sampleRounds = SampleRounds, slots = Slots,
    workers = Workers, calibration = calibration)

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
      sample = SampleRun(exitCode: 0, payload: short, condition: at(Loaded)))
    expectFailedWith verdictOf(
      sample = SampleRun(exitCode: 0, payload: short, condition: at(Calm))),
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
    let v = gateVerdict([SampleRun(exitCode: 0, payload: wx, condition: at(Loaded)),
                         calm], healthyTier2(), healthyTier1(), healthyNoAdjust(),
      healthyTorn(), runs = Runs, publications = Publications,
      sampleRounds = SampleRounds, slots = Slots, workers = Workers,
      calibration = Calibrated)
    check v.conditionsMet
    expectFailedWith v, "the provider requested no writable+executable mapping"
    let died = gateVerdict([SampleRun(exitCode: 139, condition: at(Loaded)),
                            calm], healthyTier2(), healthyTier1(),
      healthyNoAdjust(), healthyTorn(), runs = Runs,
      publications = Publications, sampleRounds = SampleRounds,
      slots = Slots, workers = Workers, calibration = Calibrated)
    expectFailedWith died, "the sampling arm exited cleanly"
    expectFailedWith died, "the sampling arm produced a result"
    # Positive control: two clean attempts, the first loaded, pass.
    let clean = gateVerdict([healthySample(Loaded), calm], healthyTier2(),
      healthyTier1(), healthyNoAdjust(), healthyTorn(), runs = Runs,
      publications = Publications, sampleRounds = SampleRounds,
      slots = Slots, workers = Workers, calibration = Calibrated)
    check clean.conditionsMet
    check clean.failures(true).len == 0

  test "an arm stops at its attempt cap and reports the conditions it saw":
    var started = 0
    let starved = collectArm("tier1", Runs, Calibrated, proc (): ArmRun =
      inc started
      crashedAt(Loaded))
    check started == Runs * AttemptsPerRun
    check starved.measured.runs == 0
    check not starved.complete(Runs)
    let v = verdictOf(tier1 = starved)
    check not v.conditionsMet
    check "tier1: 0/24 runs" in v.conditionsReason
    var calm = 0
    let fed = collectArm("tier1", Runs, Calibrated, proc (): ArmRun =
      inc calm
      crashedAt(if calm mod 2 == 0: Calm else: Loaded))
    check fed.measured.runs == Runs
    check fed.all.runs == 2 * Runs

  test "the conditions reason attributes the load it saw, lowest as well as highest":
    ## A reason that reports only the HIGHEST reading cannot tell a host that
    ## was ambiently outside the envelope from one the gate's own 14 threads
    ## pushed outside it, and the two call for opposite remedies: a quieter
    ## host, or a condition that is not inflated by the measurement itself.
    ## That is not hypothetical. On the dedicated benchmark runner
    ## (`mcl-bench-001`, reprobuild run 44372733079, 2026-11-20) every arm
    ## reported `0/24 runs ... (highest 4.56-5.03)` and nothing in the lane's
    ## output said whether any attempt had started anywhere near 2.0.
    var readings = 0
    let spread = collectArm("tier1", Runs, Calibrated, proc (): ArmRun =
      inc readings
      crashedAt(if readings mod 2 == 0: JustOutside else: Loaded))
    check spread.measured.runs == 0
    check spread.maxReading == Loaded
    check spread.minReading == JustOutside
    check spread.minCpus == 8.0 and spread.maxCpus == 8.0
    check spread.cpuSource == BenchAffinity
    check spread.readings.len == Runs * AttemptsPerRun
    check spread.readings[0].condition.value == Loaded
    check not spread.readings[0].counted
    let v = verdictOf(
      sample = SampleRun(exitCode: 0, payload: samplePayload(),
                         condition: at(JustOutside)),
      tier1 = spread)
    checkpoint("reason: " & v.conditionsReason)
    check not v.conditionsMet
    # The whole phrase, not just the numbers: an arm's readings are only
    # attributable if they are reported with the arm that saw them.
    check "tier1: 0/" & $Runs & " runs started at reading <= 2.00 in " &
      $(Runs * AttemptsPerRun) & " attempts (lowest 2.60, highest 5.50; " &
      "8.00 CPUs from " & BenchAffinity & ")" in v.conditionsReason
    # The sample arm keeps every attempt too, and the attempt the conditional
    # sample checks judge is the LAST one -- so it reports both.
    check "sample: no run started at reading <= 2.00 in 1 attempts " &
      "(lowest 2.60, last 2.60; 8.00 CPUs from " & BenchAffinity & ")" in
      v.conditionsReason


suite "HLX-M4 gate verdict: the calibration record decides what counts":
  test "with no approved record nothing is counted and the verdict is withheld, with that reason":
    ## Until a dedicated-host calibration of the new condition is committed
    ## and approved, the calibrated checks must not be evaluated at all --
    ## not evaluated against a guessed bound, and not evaluated "for
    ## attribution" either, which would silently count uncalibrated runs.
    let pending = parseCalibration($(%*{
      "schemaId": CalibrationSchemaId, "measure": ConditionMeasure,
      "status": "pending", "windowMs": DefaultWindowMs,
      "maxReading": newJNull()}), "hlx_m4_calibration.json")
    check not pending.calibrated
    check "condition not yet calibrated on a dedicated host" in pending.reason
    # Even a reading of 0 -- a perfectly idle CPU set -- is not counted.
    check not pending.inConditions(0.0)
    proc healthy(cal: Calibration): Verdict =
      gateVerdict(SampleRun(exitCode: 0, payload: samplePayload(),
                            condition: at(0.0)),
        arm("tier2", times(Runs, survived(0.0)), cal),
        arm("tier1", times(20, crashedAt(0.0)) & times(4, survived(0.0)), cal),
        arm("tier2-noadjust", times(20, crashedAt(0.0)) &
          times(4, survived(0.0)), cal),
        arm("torn", times(Runs, crashedAt(0.0)), cal), runs = Runs,
        publications = Publications, sampleRounds = SampleRounds,
        slots = Slots, workers = Workers, calibration = cal)
    let v = healthy(pending)
    checkpoint("reason: " & v.conditionsReason)
    check not v.conditionsMet
    check v.conditionsReason.startsWith(
      "condition not yet calibrated on a dedicated host")
    check not v.gateFails()
    # The readings are still reported, arm by arm, with the CPU count.
    check "tier1: 0/" & $Runs & " runs started in " & $Runs &
      " attempts (lowest 0.00, highest 0.00; 8.00 CPUs from " &
      BenchAffinity & ")" in v.conditionsReason
    # Positive control: the same runs under an approved record pass.
    let approved = healthy(Calibrated)
    check approved.conditionsMet
    check approved.failures(true).len == 0

  test "with no approved record an unconditional failure still fails":
    let missing = loadCalibration(getTempDir() / "no-such-hlx-m4-record.json")
    check not missing.calibrated
    check "no calibration record at" in missing.reason
    let t2 = arm("tier2", times(Runs - 1, survived(0.0)) & @[crashedAt(0.0)],
                 missing)
    let v = verdictOf(tier2 = t2, calibration = missing)
    check not v.conditionsMet
    expectFailedWith v, "no tier-2 run faulted"

  test "with no approved record an arm starts only the runs it needs":
    let missing = loadCalibration(getTempDir() / "no-such-hlx-m4-record.json")
    var started = 0
    let a = collectArm("tier1", Runs, missing, proc (): ArmRun =
      inc started
      crashedAt(0.0))
    check started == Runs
    check a.all.runs == Runs
    check a.measured.runs == 0
    check missing.attemptCap(1) == 1
    check Calibrated.attemptCap(1) == AttemptsPerRun

  test "an approved record's bound is the one evaluated":
    let text = $(%*{
      "schemaId": CalibrationSchemaId, "measure": ConditionMeasure,
      "status": "calibrated", "maxReading": 0.75, "windowMs": 100,
      "host": "gpu-server-001-mcl-bench-001", "date": "2026-12-01",
      "kernel": "6.18.55", "cpuSet": "8-15", "approvedBy": "A. Reviewer"})
    let cal = parseCalibration(text, "record.json")
    checkpoint(cal.reason)
    check cal.calibrated
    check cal.maxReading == 0.75
    check cal.windowMs == 100
    check cal.inConditions(0.75)
    check not cal.inConditions(0.76)
    check not cal.inConditions(NaN)
    proc weak(load: float): ArmResult =
      arm("tier1", times(10, crashedAt(load)) & times(Runs - 10,
          survived(load)), cal)
    proc verdictAt(load: float): Verdict =
      gateVerdict(SampleRun(exitCode: 0, payload: samplePayload(),
                            condition: at(load)),
        arm("tier2", times(Runs, survived(load)), cal), weak(load),
        arm("tier2-noadjust", times(20, crashedAt(load)) &
          times(4, survived(load)), cal),
        arm("torn", times(Runs, crashedAt(load)), cal), runs = Runs,
        publications = Publications, sampleRounds = SampleRounds,
        slots = Slots, workers = Workers, calibration = cal)
    # Inside the record's envelope the weak control is evaluated, and fails.
    expectFailedWith verdictAt(0.5), "tier-1 fails often, not marginally"
    # Just outside it the same tally withholds the verdict instead.
    let outside = verdictAt(0.8)
    expectNotMetNotFailed outside
    check "at reading <= 0.75" in outside.conditionsReason

  test "a record is calibrated only when it is complete and approved":
    proc record(edit: proc (n: JsonNode)): Calibration =
      var n = %*{
        "schemaId": CalibrationSchemaId, "measure": ConditionMeasure,
        "status": "calibrated", "maxReading": 0.5, "windowMs": 100,
        "host": "h", "date": "d", "kernel": "k", "cpuSet": "8-15",
        "approvedBy": "someone"}
      edit(n)
      parseCalibration($n, "r.json")
    check record(proc (n: JsonNode) = discard).calibrated
    let unapproved = record(proc (n: JsonNode) = n.delete("approvedBy"))
    check not unapproved.calibrated
    check "lacks approvedBy" in unapproved.reason
    let other = record(proc (n: JsonNode) = n["measure"] = %"loadavg-per-cpu")
    check not other.calibrated
    check "is for measure" in other.reason
    let noBound = record(proc (n: JsonNode) = n["maxReading"] = newJNull())
    check not noBound.calibrated
    check "no finite non-negative maxReading" in noBound.reason
    let negative = record(proc (n: JsonNode) = n["maxReading"] = %(-0.5))
    check not negative.calibrated
    # Zero is a real envelope: only an uncontended CPU set counts.
    let zero = record(proc (n: JsonNode) = n["maxReading"] = %0)
    check zero.calibrated
    check zero.inConditions(0.0)
    check not zero.inConditions(0.001)
    let proposed = record(proc (n: JsonNode) = n["status"] = %"proposed")
    check not proposed.calibrated
    check "status \"proposed\"" in proposed.reason
    let garbage = parseCalibration("{not json", "g.json")
    check not garbage.calibrated
    check "is not JSON" in garbage.reason

  test "the committed record is either pending or complete":
    ## The gate reads this file. A record that is neither -- half-filled, or
    ## for another measure -- would withhold every verdict with a reason that
    ## names a defect in the tree rather than a host condition.
    let path = calibrationRecordPath(getCurrentDir() / "tests" / "e2e" /
      "hcr-linux-threads")
    require fileExists(path)
    let cal = loadCalibration(path)
    checkpoint(cal.reason)
    if cal.status == "calibrated":
      check cal.calibrated
    else:
      check cal.status == "pending"
      check not cal.calibrated
      check cal.reason.startsWith(
        "condition not yet calibrated on a dedicated host")

suite "HLX-M4 condition reading: kernel formats":
  test "CPU lists":
    check parseCpuList("0-3,8,10-11") == @[0, 1, 2, 3, 8, 10, 11]
    check parseCpuList("8-15\n") == @[8, 9, 10, 11, 12, 13, 14, 15]
    check parseCpuList("5") == @[5]
    check formatCpuList([8, 9, 10, 11, 12, 13, 14, 15]) == "8-15"
    check formatCpuList([0, 2, 3, 4, 9]) == "0,2-4,9"
    expect ValueError: discard parseCpuList("")
    expect ValueError: discard parseCpuList("3-1")
    expect ValueError: discard parseCpuList("a-b")
    check parseAllowedCpus("Name:\tx\nCpus_allowed:\tff00\n" &
      "Cpus_allowed_list:\t8-15\n") == @[8, 9, 10, 11, 12, 13, 14, 15]
    expect ValueError: discard parseAllowedCpus("Name:\tx\n")

  test "cpu.max":
    check parseCpuMax("max 100000\n") == Inf
    check parseCpuMax("200000 100000") == 2.0
    check parseCpuMax("150000 100000") == 1.5
    expect ValueError: discard parseCpuMax("max")
    expect ValueError: discard parseCpuMax("0 100000")
    expect ValueError: discard parseCpuMax("100000 0")
    expect ValueError: discard parseCpuMax("lots 100000")

  test "the cgroup v2 path":
    check parseCgroupV2Path("0::/system.slice/bench.service\n") ==
      "/system.slice/bench.service"
    check parseCgroupV2Path("12:cpu:/x\n0::/\n") == "/"
    expect ValueError: discard parseCgroupV2Path("12:cpu,cpuacct:/x\n")

  test "/proc/schedstat":
    let text = "version 17\ntimestamp 4382748789\n" &
      "cpu0 0 0 0 0 0 0 51352304586621 90833022640114 435385280\n" &
      "domain0 SMT 00000003 0 0 0\n" &
      "cpu1 0 0 0 0 0 0 100 200 3\n"
    let t = parseSchedstat(text)
    check t.len == 2
    check t[0].runNs == 51352304586621
    check t[0].waitNs == 90833022640114
    check t[1].runNs == 100 and t[1].waitNs == 200
    expect ValueError: discard parseSchedstat("version 99\ncpu0 0 0 0 0 0 0 1 2 3\n")
    expect ValueError: discard parseSchedstat("cpu0 0 0 0 0 0 0 1 2 3\n")
    expect ValueError: discard parseSchedstat("version 17\ncpu0 1 2\n")

  test "/proc/stat":
    let text = "cpu  114460326 28467754 49175482 89181558 5312207 1396876 " &
      "1290333 0 953678 6359\n" &
      "cpu0 2896925 700319 1566905 3507342 218663 47727 75599 0 32280 247\n" &
      "cpu1 10 20 30 9999 9999 40 50 60 0 0\n" &
      "intr 1 2 3\nctxt 99\n"
    let t = parseProcStatBusy(text, 100)
    check t.len == 2   # the aggregate `cpu` line is not a CPU
    # user + nice + system + irq + softirq + steal; idle and iowait are not.
    check t[1] == (10 + 20 + 30 + 40 + 50 + 60) * 10_000_000'i64
    check t[0] == (2896925'i64 + 700319 + 1566905 + 47727 + 75599 + 0) *
      10_000_000'i64
    expect ValueError: discard parseProcStatBusy("cpu0 1 2 3\n", 100)
    expect ValueError: discard parseProcStatBusy("intr 1\n", 100)
    expect ValueError: discard parseProcStatBusy(text, 0)

  test "PSI":
    check parsePressureSomeTotal(
      "some avg10=0.06 avg60=0.08 avg300=0.44 total=3067891754\n" &
      "full avg10=0.06 avg60=0.07 avg300=0.38 total=1756580926\n") ==
      3067891754'i64
    expect ValueError: discard parsePressureSomeTotal("full total=1\n")

  test "the reading counts only the affinity set, per available CPU":
    var before, after: Table[int, CpuCounters]
    for cpu in 0 ..< 32:
      before[cpu] = CpuCounters(busyNs: 1000, waitNs: 1000)
      # Outside the set: saturated. Inside it: half a task per CPU.
      after[cpu] =
        if cpu in 8 .. 15: CpuCounters(busyNs: 1000 + 40_000_000,
                                       waitNs: 1000 + 10_000_000)
        else: CpuCounters(busyNs: 1000 + 900_000_000, waitNs: 1000 + 900_000_000)
    let budget = CpuBudget(cpus: 8, affinity: @[8, 9, 10, 11, 12, 13, 14, 15])
    check abs(conditionValue(before, after, 100_000_000, budget) - 0.5) < 1e-9
    # A quota of 2 CPUs divides the same contention by 2, not 8.
    let quota = CpuBudget(cpus: 2, affinity: budget.affinity, quotaCpus: 2)
    check abs(conditionValue(before, after, 100_000_000, quota) - 2.0) < 1e-9
    var gap = after
    gap.del(12)
    expect ValueError: discard conditionValue(before, gap, 100_000_000, budget)
    var back = after
    back[9] = CpuCounters(busyNs: 0, waitNs: 0)
    expect ValueError: discard conditionValue(before, back, 100_000_000, budget)
    expect ValueError: discard conditionValue(before, after, 0, budget)
    expect ValueError: discard conditionValue(before, after, 100_000_000,
      CpuBudget(cpus: 0))
    # A CPU present in one source only is absent from the merge, and so a
    # gap the reading refuses rather than a CPU it counts as idle.
    var busy: Table[int, int64]
    var sched: Table[int, SchedstatCpu]
    busy[8] = 5; busy[9] = 6
    sched[8] = SchedstatCpu(runNs: 1, waitNs: 2)
    let merged = mergeCounters(busy, sched)
    check merged.len == 1
    check merged[8] == CpuCounters(busyNs: 5, waitNs: 2)

proc schedstatText(perCpu: proc (cpu: int): (int64, int64)): string =
  result = "version 17\ntimestamp 1\n"
  for cpu in 0 ..< 32:
    let (run, wait) = perCpu(cpu)
    result.add("cpu" & $cpu & " 0 0 0 0 0 0 " & $run & " " & $wait & " 1\n")
    result.add("domain0 SMT 00000003 0 0 0\n")

proc procStatText(busyTicks: proc (cpu: int): int64): string =
  ## `/proc/stat` at USER_HZ 100: all of a CPU's busy time as `user`, plus
  ## idle and iowait that must not count.
  result = "cpu  1 2 3 4 5 6 7 8 0 0\n"
  for cpu in 0 ..< 32:
    result.add("cpu" & $cpu & " " & $busyTicks(cpu) &
      " 0 0 777777 55555 0 0 0 0 0\n")
  result.add("intr 1\nctxt 2\nbtime 3\n")

proc writeTree(root: string; allowed = "8-15"; online = "0-31";
               cgroup = "/system.slice/bench.service";
               serviceMax = "max 100000"; sliceMax = "max 100000";
               schedstat = true) =
  ## A `/proc` + `/sys` tree as the benchmark runner's slot would see it:
  ## eight allowed CPUs of a 32-CPU host, a service cgroup under a slice.
  createDir(root / "proc" / "thread-self")
  createDir(root / "proc" / "self")
  createDir(root / "proc" / "pressure")
  createDir(root / "sys" / "devices" / "system" / "cpu")
  let cg = root / "sys" / "fs" / "cgroup"
  createDir(cg / cgroup)
  writeFile(root / "proc" / "thread-self" / "status",
    "Name:\tgate\nCpus_allowed:\tff00\nCpus_allowed_list:\t" & allowed & "\n")
  writeFile(root / "proc" / "self" / "cgroup", "0::" & cgroup & "\n")
  writeFile(root / "proc" / "loadavg", "64.00 60.00 50.00 3/9000 1234\n")
  writeFile(root / "proc" / "pressure" / "cpu",
    "some avg10=1.00 avg60=1.00 avg300=1.00 total=5000000\n" &
    "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")
  writeFile(root / "sys" / "devices" / "system" / "cpu" / "online", online & "\n")
  writeFile(cg / cgroup / "cpu.max", serviceMax & "\n")
  writeFile(cg / parentDir(cgroup) / "cpu.max", sliceMax & "\n")
  writeFile(cg / cgroup / "cpu.pressure",
    "some avg10=0.00 avg60=0.00 avg300=0.00 total=1000\n" &
    "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")
  writeFile(root / "proc" / "stat", procStatText(
    proc (cpu: int): int64 = 100'i64))
  if schedstat:
    writeFile(root / "proc" / "schedstat", schedstatText(
      proc (cpu: int): (int64, int64) = (1_000_000'i64, 1_000_000'i64)))

suite "HLX-M4 condition reading: a real /proc and /sys tree":
  test "the available CPUs are the affinity set, and their source is named":
    let root = createTempDir("hlx-m4-cond-", "")
    defer: removeDir(root)
    writeTree(root)
    let b = readCpuBudget(root / "proc", root / "sys")
    checkpoint(b.source & " " & b.error)
    check b.cpus == 8.0
    check b.affinity == @[8, 9, 10, 11, 12, 13, 14, 15]
    check b.quotaCpus == Inf
    check b.source == "affinity 8-15 (8); cpu.max max on " &
      "/system.slice/bench.service"
    # Host-wide attribution is the retired quantity: 64 / 32 CPUs.
    check readHostLoadPerCpu(root / "proc", root / "sys") == 2.0

  test "a cpu.max quota on an ancestor narrows the count":
    let root = createTempDir("hlx-m4-cond-", "")
    defer: removeDir(root)
    writeTree(root, sliceMax = "200000 100000")
    let b = readCpuBudget(root / "proc", root / "sys")
    checkpoint(b.source)
    check b.cpus == 2.0
    check b.quotaCgroup == "/system.slice"
    check b.source == "cpu.max 2.00 on /system.slice, narrower than " &
      "affinity 8-15 (8)"
    # A quota wider than the affinity set leaves the affinity in charge.
    writeFile(root / "sys" / "fs" / "cgroup" / "system.slice" / "cpu.max",
      "1600000 100000\n")
    let wide = readCpuBudget(root / "proc", root / "sys")
    check wide.cpus == 8.0
    check "cpu.max 16.00 on /system.slice" in wide.source

  test "the affinity set is intersected with the online CPUs":
    let root = createTempDir("hlx-m4-cond-", "")
    defer: removeDir(root)
    writeTree(root, online = "0-11")
    let b = readCpuBudget(root / "proc", root / "sys")
    check b.affinity == @[8, 9, 10, 11]
    check b.cpus == 4.0

  test "a reading over the window counts others on the set, not elsewhere":
    let root = createTempDir("hlx-m4-cond-", "")
    defer: removeDir(root)
    writeTree(root)
    let windowMs = 100
    let r = sampleCondition(windowMs, root / "proc", root / "sys",
      proc (ms: int) =
      # Advance the counters as the kernel would over `ms`: each CPU of the
      # set busy 30% of the window and tasks queued on it for 20% (half a
      # runnable task in all), and the CPUs outside it saturated, which must
      # not count. Then sleep the real window.
      let busyTicks = int64(ms) * 3 div 100      # 30% at USER_HZ 100
      let waitNs = int64(ms) * 1_000_000 div 5   # 20%
      writeFile(root / "proc" / "stat", procStatText(
        proc (cpu: int): int64 =
        if cpu in 8 .. 15: 100'i64 + busyTicks else: 100'i64 + 50 * busyTicks))
      writeFile(root / "proc" / "schedstat", schedstatText(
        proc (cpu: int): (int64, int64) =
        # Field 7 moves too, and must not count (it is credited at
        # switch-out; see `m4_conditions`).
        if cpu in 8 .. 15: (1_000_000'i64 + 99 * waitNs,
                            1_000_000'i64 + waitNs)
        else: (1_000_000'i64 + 50 * waitNs, 1_000_000'i64 + 50 * waitNs)))
      writeFile(root / "sys" / "fs" / "cgroup" / "system.slice" /
        "bench.service" / "cpu.pressure",
        "some avg10=0.00 avg60=0.00 avg300=0.00 total=" &
          $(1000 + ms * 100) & "\n")
      sleep(ms), clkTck = 100)
    checkpoint($toJson(r))
    check r.error == ""
    check r.windowNs >= int64(windowMs) * 1_000_000
    # 0.5 when the window is exactly `ms`; a little less as it overruns.
    check r.value > 0.25 and r.value <= 0.5
    check r.budget.cpus == 8.0
    # PSI attribution: 10 ms of `some` stall per 100 ms is 0.1.
    check r.cgroupCpuSome > 0.0 and r.cgroupCpuSome <= 0.1 + 1e-9
    check r.hostCpuSome == 0.0
    check r.hostLoadPerCpu == 2.0
    let j = toJson(r)
    check j["cpuSource"].getStr() == r.budget.source
    check j["affinity"].getStr() == "8-15"

  test "a lone busy task on each CPU of the set reads one task per CPU":
    ## The neighbour schedstat's field 7 cannot see: one busy task per CPU,
    ## never preempted, so neither field 7 nor field 8 moves during the
    ## window. `/proc/stat` still counts the CPU as busy throughout.
    let root = createTempDir("hlx-m4-cond-", "")
    defer: removeDir(root)
    writeTree(root)
    let r = sampleCondition(100, root / "proc", root / "sys",
      proc (ms: int) =
      writeFile(root / "proc" / "stat", procStatText(
        proc (cpu: int): int64 = 100'i64 + int64(ms) div 10))
      sleep(ms), clkTck = 100)
    checkpoint($toJson(r))
    check r.error == ""
    # 1.0 when the window is exactly 100 ms; a little less as it overruns.
    check r.value > 0.5 and r.value <= 1.0

  test "an unreadable input makes the reading +Inf, with the reason":
    let root = createTempDir("hlx-m4-cond-", "")
    defer: removeDir(root)
    writeTree(root, schedstat = false)
    let none = sampleCondition(1, root / "proc", root / "sys")
    check none.value == Inf
    check "schedstat" in none.error
    check toJson(none)["value"].kind == JNull
    writeTree(root)
    removeFile(root / "proc" / "stat")
    let noStat = sampleCondition(1, root / "proc", root / "sys")
    check noStat.value == Inf
    check "stat" in noStat.error
    writeTree(root)   # /proc/stat back; the cases below replace schedstat
    writeFile(root / "proc" / "schedstat", "version 99\ncpu8 0 0 0 0 0 0 1 2 3\n")
    let unknown = sampleCondition(1, root / "proc", root / "sys")
    check unknown.value == Inf
    check "version 99" in unknown.error
    # A CPU of the set with no counters.
    writeFile(root / "proc" / "schedstat",
      "version 17\ncpu8 0 0 0 0 0 0 1 2 3\n")
    let gap = sampleCondition(1, root / "proc", root / "sys")
    check gap.value == Inf
    check "cpu9" in gap.error
    # No affinity at all.
    writeTree(root)
    removeFile(root / "proc" / "thread-self" / "status")
    let blind = sampleCondition(1, root / "proc", root / "sys")
    check blind.value == Inf
    check blind.budget.cpus == 0.0
    check "affinity unreadable" in blind.budget.error
    check not Calibrated.inConditions(blind.value)

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

    test "a control fault that wrecked the stack pointer is still reported":
      # The crash arms die by executing a window's bytes as code, which can
      # leave `rsp` anywhere. Without an alternate signal stack the kernel
      # cannot push the fault handler's frame, the process dies 139 with no
      # HCR-M4-CRASH line, and `runFixture` aborts the whole gate: measured
      # for `tier1` in ten of twelve gate runs at load/CPU 4-7. Deterministic
      # here: the fixture faults with `rsp` = 0x1000.
      let repoRoot = getCurrentDir()
      let bodies = buildPatchBodies(repoRoot)
      let threadsBin = buildFixture(repoRoot, "hcr_lx_m4_threads.c",
                                    "m4_threads")
      let r = runFixture(threadsBin, ["fault-bad-stack", hex(bodies.a),
                                      hex(bodies.b), "2", "1", "0"])
      checkpoint(r.stderrText)
      check r.exitCode == CrashExitCode
      check r.crashed
      check r.faultSignal == 4

    test "the condition is readable on this host":
      ## The gate's host must be able to measure its condition; on one that
      ## cannot, every run would be outside it and the verdict withheld.
      let r = sampleCondition(10)
      checkpoint($toJson(r))
      check r.error == ""
      check r.value >= 0.0
      check r.value != Inf
      check not isNaN(r.value)
      check r.budget.cpus > 0.0
      check r.budget.affinity.len > 0
else:
  suite "HLX-M4 fixture: a §6.3 quiescence timeout is retried, counted and writes nothing":
    test "the HLX-M4 fixture is linux-x86_64-only":
      skip("the HLX-M4 fixture drives the Linux x86_64 HCR provider")
