## The verdict of the HLX-M4 concurrency gate
## (`e2e_hcr_linux_concurrent_patch_no_torn_instruction`), kept apart from the
## processes that produce its inputs so the decision itself can be tested.
##
## WHY THE GATE NEEDS CONDITIONS AT ALL. Three of its five arms (`tier1`,
## `tier2-noadjust`, `torn`) are negative controls: they MUST crash, and the
## first two must crash in at least half their runs. That is a statistical
## claim, and on a host whose run queue was 4.7-6.7 times its CPU count it
## stopped holding — `tier1` 10/24 where the milestone measured 18-21/24 — with
## the safety property (`tier2` 0/24 crashes, no third value) intact in every
## run (reprobuild-pm `issues/2026-09-26-hcr-concurrent-patch-gate-verdict-
## depends-on-host-load.md`). Loosening the 50% bound would make the controls
## mean less, so the bound stays; instead the gate states the host condition it
## was calibrated under, measures it before every run, and reports a run
## measured outside it as NOT EVIDENCE rather than as a failure.
##
## WHAT IS NEVER CONDITIONAL. Anything that would be a real regression however
## loaded the host: a `tier2` crash, stray exit or third value; a writable and
## executable mapping; a §6.3 quiescence abort that changed the window; a
## quiescence refusal other than a timeout (or the census's misreading of
## one, which the fixture retries); a negative control that never crashed at
## all. These are evaluated over EVERY run, measured inside the conditions or
## not, so excluding a run can only ever withhold a verdict, never hide one.
##
## Design: `reprobuild-pm/spec/HCR/Linux-ELF-Provider.md` §6.3 (a quiescence
## timeout is a defined outcome) and the HLX-M4 gate's "Conditions" note in
## `HCR-Linux-ELF-Provider.milestones.org`.

import std/[json, strutils]

const
  ## The host condition the negative-control thresholds were calibrated under:
  ## the 1-minute load average divided by the CPU count, read immediately
  ## BEFORE each fixture process starts. Read before, not during, so the
  ## reading cannot depend on how the run turned out — a crashing run and a
  ## surviving one are classified by the same number, and excluding runs
  ## cannot bias the crash rate of what remains.
  ##
  ## The bound is the envelope MEASURED to hold, not an extrapolation: every
  ## arm met its thresholds at up to this ratio (32-CPU x86_64 host, kernel
  ## 6.18.55, 2026-10-15; see the milestone's Conditions note), and the
  ## failures in the issue above were all at 4.7-6.7. Raise it only with a
  ## measurement at the new ratio.
  MaxLoadPerCpu* = 2.0
  ## How many fixture processes an arm may start while collecting its runs
  ## inside the conditions. A host that stays outside them for this many
  ## attempts produces "conditions not met", not a failure.
  AttemptsPerRun* = 3
  ## The size of the verdict's check list, and how many of its checks are
  ## asserted whatever the conditions. Pinned so the gate can assert it is
  ## evaluating the whole list (trap 4c): a check that silently fell out of
  ## `gateVerdict` would otherwise shrink the gate without reddening it.
  GateCheckCount* = 46
  GateUnconditionalCheckCount* = 22

type
  ArmRun* = object
    ## One fixture process, reduced to what the verdict needs.
    exitCode*: int
    crashed*: bool          ## rc 70 AND an `HCR-M4-CRASH` record
    windowAddress*: uint64  ## 0 when the fixture died before announcing it
    faultPc*: uint64
    faultSignal*: int
    stderrText*: string
    payload*: JsonNode      ## nil when the process printed no result
    loadPerCpu*: float      ## host load / CPUs, read before the process started

  ArmTally* = object
    runs*, crashes*, anomalies*, publications*, adjust*, nested*: int
    wxRefused*, textReplacedRuns*, payloads*: int
    strayExits*: seq[int]
    inWindowFaults*, outOfWindowFaults*, missingWindow*: int
    faultOffsets*, faultSignals*: seq[int]
    quiesceAborts*, quiesceBlockedAborts*, quiesceAbortWrites*: int
    quiesceAbandoned*: int
    quiesceOtherFailures*: int
    notes*: seq[string]     ## per-run diagnostics, for checkpoints

  ArmResult* = object
    mode*: string
    all*: ArmTally          ## every run the arm started
    measured*: ArmTally     ## only the runs started inside the conditions
    maxLoadPerCpu*: float   ## the highest reading among the runs started

  Check* = object
    message*: string
    ok*: bool
    conditional*: bool      ## meaningful only for runs inside the conditions

  Verdict* = object
    checks*: seq[Check]
    conditionsMet*: bool
    conditionsReason*: string ## why not, when not; names the arm and readings

proc inConditions*(loadPerCpu: float): bool =
  loadPerCpu <= MaxLoadPerCpu

proc intField(payload: JsonNode; key: string): int =
  ## A missing key reads as 0. Every key read here is printed unconditionally
  ## by the fixture, so a 0 from a missing key can only make a count look
  ## SMALLER — which the checks that use it treat as a failure, never a pass.
  if payload != nil and payload.hasKey(key): payload[key].getInt() else: 0

proc add*(tally: var ArmTally; run: ArmRun; index: int) =
  tally.runs += 1
  if run.exitCode != 0:
    if run.crashed:
      # Exit code 70 AND a crash record. Both, not either: a die-before-output
      # wearing the right code is indistinguishable from a fault otherwise.
      tally.crashes += 1
      if run.windowAddress == 0'u64:
        tally.missingWindow += 1
      else:
        let offset = int(run.faultPc.int64 - run.windowAddress.int64)
        tally.faultOffsets.add(offset)
        tally.faultSignals.add(run.faultSignal)
        # Design §6.1 point 4 is a thread resuming at a byte offset INSIDE the
        # eight bytes the publication overwrites. A crash anywhere else is a
        # different bug and must not satisfy an arm built to show this one.
        if offset >= 0 and offset < 8:
          tally.inWindowFaults += 1
        else:
          tally.outOfWindowFaults += 1
          tally.notes.add("run " & $index & " faulted at window+" & $offset &
            ", outside the 8-byte window, signal " & $run.faultSignal)
    else:
      tally.strayExits.add(run.exitCode)
      tally.notes.add("run " & $index & " exited " & $run.exitCode &
        " without an rc-70 crash record: " & run.stderrText)
  if run.payload != nil:
    let p = run.payload
    tally.payloads += 1
    tally.anomalies += p.intField("anomalies")
    tally.publications += p.intField("publicationsApplied")
    tally.adjust += p.intField("quiesceAdjustCount")
    tally.nested += p.intField("quiesceNestedAdjustCount")
    tally.wxRefused += p.intField("wxRequestsRefused")
    tally.quiesceAborts += p.intField("quiesceAborts")
    tally.quiesceBlockedAborts += p.intField("quiesceBlockedAborts")
    tally.quiesceAbortWrites += p.intField("quiesceAbortWrites")
    tally.quiesceAbandoned += p.intField("quiesceAbandoned")
    tally.quiesceOtherFailures += p.intField("quiesceOtherFailures")
    if p.hasKey("lastTextReplaced") and p["lastTextReplaced"].getBool():
      tally.textReplacedRuns += 1

proc add*(arm: var ArmResult; run: ArmRun) =
  let index = arm.all.runs
  arm.all.add(run, index)
  if run.loadPerCpu > arm.maxLoadPerCpu:
    arm.maxLoadPerCpu = run.loadPerCpu
  if inConditions(run.loadPerCpu):
    arm.measured.add(run, index)

proc complete*(arm: ArmResult; runs: int): bool =
  arm.measured.runs >= runs

proc collectArm*(mode: string; runs: int;
                 runOnce: proc (): ArmRun {.closure.}): ArmResult =
  ## Start fixture processes until `runs` of them were started inside the
  ## conditions, or `runs * AttemptsPerRun` were started in all. Runs outside
  ## the conditions are KEPT in `all`, so their unconditional outcomes still
  ## count.
  result.mode = mode
  while result.measured.runs < runs and
      result.all.runs < runs * AttemptsPerRun:
    result.add(runOnce())

type
  SampleRun* = object
    exitCode*: int
    payload*: JsonNode
    loadPerCpu*: float

proc sampleChecks*(attempts: openArray[SampleRun];
                   rounds, slots, workers: int): seq[Check] =
  ## The `sample` arm: no patching, quiescence used to MEASURE how often a hot
  ## thread's PC is inside the publication window. The gate starts it up to
  ## `AttemptsPerRun` times, until one starts inside the conditions, and
  ## `attempts` holds every one it started, in order.
  ##
  ## Whether every round could quiesce is a scheduling question, so those
  ## checks are conditional and judged on the attempt the gate kept: the last
  ## one. That the process ran, that the host has SYNC_CORE, that no abort
  ## changed text and that nothing asked for W+X are not conditional, and they
  ## are judged over EVERY attempt — a loaded attempt that asked for a
  ## writable+executable mapping must not be forgotten because the host was
  ## busy and the arm was started again.
  template add(text: string; holds: bool; isConditional = false) =
    result.add(Check(message: text, ok: holds, conditional: isConditional))
  template everyAttempt(condition: untyped): bool =
    var holds = attempts.len > 0
    for attempt {.inject.} in attempts:
      let s {.inject.} = attempt.payload
      if not (condition):
        holds = false
    holds
  add "the sampling arm exited cleanly", everyAttempt(attempt.exitCode == 0)
  add "the sampling arm produced a result", everyAttempt(s != nil)
  add "no sampling abort changed the publication window",
    everyAttempt(s.intField("quiesceAbortWrites") == 0)
  add "no sampling round was refused for a reason other than a timeout",
    everyAttempt(s.intField("quiesceOtherFailures") == 0)
  add "the host has SYNC_CORE",
    everyAttempt(s != nil and s.hasKey("membarrierSyncCore") and
      s["membarrierSyncCore"].getBool())
  # W^X: the provider's raw `mprotect`/`mmap` refuse a writable+executable
  # request without issuing it and count it, so this is its whole surface.
  add "the provider requested no writable+executable mapping",
    everyAttempt(s != nil and s.hasKey("wxRequestsRefused") and
      s.intField("wxRequestsRefused") == 0)
  let s = if attempts.len > 0: attempts[^1].payload else: nil
  # A §6.3 timeout is retried by the fixture; a round is lost only when it
  # timed out QUIESCE_ATTEMPTS times in a row. On an overloaded host that is
  # the host; inside the conditions it is a quiescence regression.
  add "every sampling round reached quiescence",
    s.intField("quiesceRounds") == rounds, true
  add "no sampling round failed to quiesce",
    s.intField("quiesceFailures") == 0, true
  # Complete-dump rule: the observation count must equal rounds x slots, not
  # merely be positive. A truncated sample would satisfy every threshold.
  add "the parked-observation dump is complete",
    s.intField("parkedObservations") == rounds * slots, true
  add "threads really were caught inside the publication window",
    s.intField("parkedPcInWindow") > 0, true
  add "threads really were caught inside the sled",
    s.intField("parkedPcInSled") >= s.intField("parkedPcInWindow"), true
  add "all twelve workers ran", s.intField("distinctWorkerTids") == workers, true
  add "the signal storm delivered", s.intField("chaosSignalsDelivered") > 0, true

proc armChecks*(tier2, tier1, noAdjust, torn: ArmResult;
                runs, publications: int): seq[Check] =
  template add(text: string; holds: bool; isConditional = false) =
    result.add(Check(message: text, ok: holds, conditional: isConditional))

  # -- every failing run failed the way we claim it did -------------------
  # A count of crashes is only evidence about §6.1 point 4 if each one is that
  # fault. For the negative controls this is judged over the runs inside the
  # conditions; for tier2 over every run, because ANY tier2 fault is the
  # regression this gate exists to catch.
  for (name, arm) in {"tier1": tier1, "tier2-noadjust": noAdjust,
                      "torn": torn}:
    let t = arm.measured
    add name & ": no run exited non-zero without an rc-70 crash record",
      t.strayExits.len == 0, true
    add name & ": every faulting run announced its publication window",
      t.missingWindow == 0, true
    add name & ": every fault landed INSIDE the 8-byte window",
      t.outOfWindowFaults == 0, true
    add name & ": in-window faults account for every crash",
      t.inWindowFaults == t.crashes, true
  add "tier2: no run exited non-zero without an rc-70 crash record",
    tier2.all.strayExits.len == 0
  add "tier2: every faulting run announced its publication window",
    tier2.all.missingWindow == 0
  add "tier2: every fault landed INSIDE the 8-byte window",
    tier2.all.outOfWindowFaults == 0
  add "tier2: in-window faults account for every crash",
    tier2.all.inWindowFaults == tier2.all.crashes

  # -- §6.3: a quiescence abort is a defined outcome, and it writes nothing --
  for (name, arm) in {"tier2": tier2, "tier2-noadjust": noAdjust}:
    add name & ": no quiescence abort changed the publication window",
      arm.all.quiesceAbortWrites == 0
    add name & ": no quiescence was refused for a reason other than a timeout",
      arm.all.quiesceOtherFailures == 0

  # -- the positive control -----------------------------------------------
  # If a non-atomic publication of the same word does not kill the process,
  # nothing below discriminates and the green arms are vacuous. That the
  # control fired at all is never conditional; that it fired every time is
  # judged inside the conditions.
  add "the non-atomic publication was detected at least once",
    torn.all.crashes > 0
  add "EVERY non-atomic publication was detected (positive control)",
    torn.measured.crashes == torn.measured.runs and torn.measured.runs > 0, true

  # -- tier 1 is unsafe ------------------------------------------------------
  # `> 0` over every run: a harness that lost its teeth crashes no run on any
  # host. `>= 50%` is the calibrated rate, judged inside the conditions.
  add "tier-1 publication fails under concurrent execution",
    tier1.all.crashes > 0
  add "tier-1 fails often, not marginally",
    tier1.measured.crashes * 2 >= tier1.measured.runs and
      tier1.measured.runs > 0, true

  # -- the IP adjustment is load-bearing -------------------------------------
  add "removing the §6.2 step 6 IP adjustment restores the failure",
    noAdjust.all.crashes > 0
  add "the adjustment's removal fails often, not marginally",
    noAdjust.measured.crashes * 2 >= noAdjust.measured.runs and
      noAdjust.measured.runs > 0, true

  # -- the shippable configuration, over EVERY run ---------------------------
  add "no tier-2 run faulted", tier2.all.crashes == 0
  add "no tier-2 publication requested a writable+executable mapping",
    tier2.all.wxRefused == 0
  add "no tier-2 run observed a third return value", tier2.all.anomalies == 0
  # Every run that printed a result published by page replacement. Counted
  # over the runs inside the conditions, where every run must print one.
  add "every tier-2 run published by page replacement",
    tier2.measured.runs > 0 and tier2.measured.payloads == tier2.measured.runs and
      tier2.measured.textReplacedRuns == tier2.measured.runs, true
  # A §6.3 timeout is retried by the fixture, so inside the conditions every
  # publication must still go through: a round abandoned after repeated
  # timeouts on a host that is NOT overloaded is a quiescence regression.
  add "every tier-2 run published everything it was asked to",
    tier2.measured.runs > 0 and
      tier2.measured.publications == tier2.measured.runs * publications, true
  # The mechanism ENGAGED. A quiescence that adjusted nothing would pass the
  # checks above for free, which is this campaign's dominant failure mode.
  add "the IP adjustment engaged at least once", tier2.all.adjust > 0
  add "the nested-signal-frame adjustment engaged at least once",
    tier2.all.nested > 0

proc conditionsReason(arms: openArray[ArmResult]; runs: int;
                      samples: openArray[SampleRun]): string =
  var parts: seq[string]
  if samples.len == 0:
    parts.add("sample: never started")
  elif not inConditions(samples[^1].loadPerCpu):
    parts.add("sample: no run started at load/CPU <= " & $MaxLoadPerCpu &
      " in " & $samples.len & " attempts (last " &
      formatFloat(samples[^1].loadPerCpu, ffDecimal, 2) & ")")
  for arm in arms:
    if not arm.complete(runs):
      parts.add(arm.mode & ": " & $arm.measured.runs & "/" & $runs &
        " runs started at load/CPU <= " & $MaxLoadPerCpu & " in " &
        $arm.all.runs & " attempts (highest " &
        formatFloat(arm.maxLoadPerCpu, ffDecimal, 2) & ")")
  parts.join("; ")

proc gateVerdict*(samples: openArray[SampleRun];
                  tier2, tier1, noAdjust, torn: ArmResult;
                  runs, publications, sampleRounds, slots,
                  workers: int): Verdict =
  ## Every check, conditional or not, plus whether the conditions held. The
  ## caller asserts the unconditional checks always and the conditional ones
  ## only when `conditionsMet`; otherwise it reports the case as not having
  ## met its conditions, which the suite counts apart from a failure.
  ## `samples` is every `sample` attempt the gate started, in order; the last
  ## is the one the conditional sample checks judge.
  result.checks = sampleChecks(samples, sampleRounds, slots, workers) &
    armChecks(tier2, tier1, noAdjust, torn, runs, publications)
  result.conditionsReason = conditionsReason(
    [tier2, tier1, noAdjust, torn], runs, samples)
  result.conditionsMet = result.conditionsReason.len == 0

proc gateVerdict*(sample: SampleRun; tier2, tier1, noAdjust, torn: ArmResult;
                  runs, publications, sampleRounds, slots,
                  workers: int): Verdict =
  ## The verdict for a gate that started the `sample` arm once.
  gateVerdict([sample], tier2, tier1, noAdjust, torn, runs, publications,
    sampleRounds, slots, workers)

proc failures*(verdict: Verdict; includeConditional: bool): seq[string] =
  for check in verdict.checks:
    if not check.ok and (includeConditional or not check.conditional):
      result.add(check.message)
