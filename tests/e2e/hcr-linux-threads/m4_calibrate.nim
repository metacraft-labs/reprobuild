## Calibration driver for the HLX-M4 concurrency gate's run condition.
##
## The gate (`t_e2e_hcr_linux_concurrent_patch_no_torn_instruction.nim`)
## counts a fixture process as calibrated evidence only when the reading
## `m4_conditions.sampleCondition` takes before it starts is inside the
## envelope recorded in `hlx_m4_calibration.json`. This tool measures that
## envelope. It starts the gate's own fixture processes -- the same binary,
## built the same way, with the same arguments (`m4_fixture`) -- takes the
## same reading before each, and records (reading, available CPUs and their
## source, outcome) per run. It then buckets the runs by reading and proposes
## the envelope: the highest reading observed in the contiguous run of
## buckets, from the lowest up, in which BOTH negative controls still fault at
## the gate's required rate plus a margin, `torn` faults every time, `tier2`
## is clean every time and the sample arm completes every time.
##
## It PROPOSES; it never calibrates. The record it writes has
## `status = "proposed"` and no approver, which the gate refuses. A human
## reads the table, copies the record over `hlx_m4_calibration.json`, sets
## `status = "calibrated"` and `approvedBy`, and commits it: a bound is a
## spec decision (reprobuild-pm `spec/Test-Designs/Shared-Test-Design-
## Guidelines.md`, "Statistical Verdicts State Their Conditions").
##
## ONLY ON A DEDICATED HOST. A calibration measured on a host with other work
## on it describes that host's mix of interference, not the condition. Before
## each phase the tool takes a one-second reading with nothing of its own
## running and prints it beside the host-wide `/proc/loadavg` and
## `/proc/pressure/cpu`; if the reading exceeds `--max-idle-reading` it
## refuses to continue unless `--allow-non-dedicated` is given, and then
## stamps the record `status = "not-dedicated"`, which the gate also refuses.
##
## HOW TO RUN IT (from the reprobuild checkout root, inside its dev shell):
##
##   nim c --threads:on --hints:off \
##     --out:build/test-bin/hcr_m4_calibrate \
##     tests/e2e/hcr-linux-threads/m4_calibrate.nim
##   ./build/test-bin/hcr_m4_calibrate --runs=48 \
##     --phase=idle --phase=busy:4 --phase=busy:8 --phase=busy:16 \
##     --phase='cmd:nix build --rebuild nixpkgs#hello' ...
##
## or `just hcr_m4_calibrate <options>`, which does both. Over SSH on the
## benchmark host, run it inside the runner's slice so it gets the slot's CPU
## set (`systemd-run --scope -p AllowedCPUs=8-15 -p Nice=-20 ...` or the
## runner's own unit) -- the tool prints the CPU set and its source, so a run
## on the wrong set is visible. In GitHub Actions,
## `.github/workflows/hcr-m4-calibration.yml` (`workflow_dispatch`) runs it on
## `[linux, x64, benchmark]` and uploads the output directory.
##
## Phases (`--phase`, repeatable, in order; default `idle`):
##
##   idle          nothing added: the host's own state.
##   busy:K        K busy-loop processes, which inherit this process's CPU
##                 set and nice level, so they compete for exactly the CPUs
##                 the fixture uses. Explores the reading's range; note that
##                 busy loops do not reproduce memory-bandwidth or cache
##                 interference (see `m4_conditions`, "LIMITS").
##   cmd:<shell>   a shell command run in the background for the phase (for
##                 example a real build), started `--warmup-s` before the
##                 first reading and killed at the end of the phase.
##
## Output (`--out-dir`, default `build/hcr-m4-calibration/<UTC stamp>`):
## `runs.jsonl` (one `host` row per phase, one `run` row per process),
## `summary.txt` (the table printed to stdout) and
## `proposed-calibration.json`. `--summarize=FILE[,FILE...]` re-reads
## `runs.jsonl` files (several jobs' worth, say) and prints the table and
## proposal without running anything.

import std/[algorithm, json, math, os, osproc, posix, sequtils, strutils,
            times]

# The load phases deliberately spawn processes reprobuild does not control:
# busy loops and an operator-supplied command are the load being measured.
import repro_core/ambient_execution

import m4_conditions
import m4_fixture

const
  AllArms = ["sample", "tier2", "tier1", "tier2-noadjust", "torn"]
  DefaultBuckets = [0.05, 0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0]
  ## The gate's rule for a negative control: at least half its runs fault
  ## (`m4_verdict.armChecks`, "fails often, not marginally").
  RequiredControlRate = 0.5

type
  Options = object
    runs: int
    phases: seq[string]
    arms: seq[string]
    windowMs: int
    buckets: seq[float]
    margin: float
    minRuns: int
    outDir: string
    maxIdleReading: float
    allowNonDedicated: bool
    warmupS: int
    summarize: seq[string]

  Row = object
    phase, arm: string
    reading: float
    cpus: float
    cpuSource: string
    outcome: string ## fault / survived / clean / dirty / complete /
                    ## incomplete / error
    good: bool      ## the outcome the arm is calibrated to produce

proc usage() =
  echo """usage: hcr_m4_calibrate [--runs=N] [--phase=idle|busy:K|cmd:<shell>]...
       [--arms=a,b,...] [--window-ms=MS] [--buckets=e1,e2,...]
       [--margin=F] [--min-runs=N] [--out-dir=DIR]
       [--max-idle-reading=F] [--allow-non-dedicated] [--warmup-s=S]
       [--summarize=runs.jsonl[,...]]
See the header of tests/e2e/hcr-linux-threads/m4_calibrate.nim."""

proc parseOptions(): Options =
  result = Options(runs: 48, windowMs: DefaultWindowMs, margin: 0.10,
    minRuns: 24, maxIdleReading: 0.10, warmupS: 5,
    buckets: @DefaultBuckets, arms: @AllArms)
  for i in 1 .. paramCount():
    let arg = paramStr(i)
    let eq = arg.find('=')
    let key = if eq > 0: arg[0 ..< eq] else: arg
    let value = if eq > 0: arg[eq + 1 .. ^1] else: ""
    case key
    of "--runs": result.runs = parseInt(value)
    of "--phase": result.phases.add(value)
    of "--arms": result.arms = value.split(',')
    of "--window-ms": result.windowMs = parseInt(value)
    of "--buckets": result.buckets = value.split(',').mapIt(parseFloat(it))
    of "--margin": result.margin = parseFloat(value)
    of "--min-runs": result.minRuns = parseInt(value)
    of "--out-dir": result.outDir = value
    of "--max-idle-reading": result.maxIdleReading = parseFloat(value)
    of "--allow-non-dedicated": result.allowNonDedicated = true
    of "--warmup-s": result.warmupS = parseInt(value)
    of "--summarize": result.summarize = value.split(',')
    of "--help", "-h":
      usage()
      quit(0)
    else:
      usage()
      raise newException(ValueError, "unknown option " & arg)
  if result.phases.len == 0: result.phases = @["idle"]
  for arm in result.arms:
    if arm notin AllArms:
      raise newException(ValueError, "unknown arm " & arm)
  if result.runs <= 0 or result.windowMs <= 0 or result.minRuns <= 0:
    raise newException(ValueError, "--runs, --window-ms and --min-runs must be positive")
  result.buckets.sort()

# ---------------------------------------------------------------------------
# Host description and the dedicated-host check.
# ---------------------------------------------------------------------------

proc readTrim(path: string): string =
  try: readFile(path).strip() except CatchableError: "unreadable"

proc hostRow(phase: string; idle: ConditionReading; dedicated: bool): JsonNode =
  %*{"kind": "host", "phase": phase,
     "hostname": readTrim("/proc/sys/kernel/hostname"),
     "kernel": readTrim("/proc/sys/kernel/osrelease"),
     "date": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
     "loadavg": readTrim("/proc/loadavg"),
     "hostPressureCpu": readTrim("/proc/pressure/cpu"),
     "idleReading": toJson(idle), "dedicated": dedicated}

proc dedicatedCheck(phase: string; opts: Options): JsonNode =
  ## A one-second reading with nothing of ours running. Printed whatever it
  ## says, so a reviewer can see the host the numbers came from.
  let idle = sampleCondition(1000)
  let dedicated = idle.value <= opts.maxIdleReading
  result = hostRow(phase, idle, dedicated)
  echo "host ", result["hostname"].getStr(), ", kernel ",
    result["kernel"].getStr(), ", ", result["date"].getStr()
  echo "  CPU set: ", idle.budget.source, " -> ",
    formatFloat(idle.budget.cpus, ffDecimal, 2), " available CPUs"
  echo "  idle reading over 1 s: ",
    (if idle.value.classify == fcInf: "unreadable (" & idle.error & ")"
      else: formatFloat(idle.value, ffDecimal, 3)),
    " (limit ", opts.maxIdleReading, ")"
  echo "  host /proc/loadavg: ", result["loadavg"].getStr(),
    "  (attribution only; host-wide)"
  echo "  host /proc/pressure/cpu: ",
    result["hostPressureCpu"].getStr().replace("\n", " | ")
  echo "  cgroup cpu.pressure some over 1 s: ", idle.cgroupCpuSome
  if not dedicated:
    echo "  NOT DEDICATED: the CPU set is contended with nothing of ours " &
      "running. A calibration here describes this host's other work."

# ---------------------------------------------------------------------------
# Load phases.
# ---------------------------------------------------------------------------

type Load = object
  processes: seq[Process]

proc startLoad(phase: string; warmupS: int): Load =
  if phase == "idle":
    return
  if phase.startsWith("busy:"):
    let k = parseInt(phase["busy:".len .. ^1])
    for i in 0 ..< k:
      # Inherits this process's affinity and nice level: competes for the
      # same CPUs at the same priority as the fixture.
      result.processes.add(uncontrolledStartProcess("/bin/sh",
        args = ["-c", "while :; do :; done"], options = {}))
  elif phase.startsWith("cmd:"):
    # `setsid` so the whole command tree is one process group to kill.
    result.processes.add(uncontrolledStartProcess("setsid", args = ["/bin/sh", "-c",
      "exec >/dev/null 2>&1; " & phase["cmd:".len .. ^1]],
      options = {poUsePath}))
  else:
    raise newException(ValueError, "unknown phase " & phase)
  sleep(warmupS * 1000)

proc stopLoad(load: Load) =
  for p in load.processes:
    discard posix.kill(-Pid(p.processID), SIGTERM)
    discard posix.kill(Pid(p.processID), SIGTERM)
    discard p.waitForExit(5000)
    if p.running: p.kill()
    p.close()

# ---------------------------------------------------------------------------
# One run, classified the way the gate classifies it.
# ---------------------------------------------------------------------------

proc classify(arm: string; r: FixtureRun): (string, bool) =
  let p = r.payload
  proc pInt(key: string): int =
    if p != nil and p.hasKey(key): p[key].getInt() else: -1
  case arm
  of "tier1", "tier2-noadjust", "torn":
    if r.crashed and r.windowAddress != 0:
      let offset = int(r.faultPc.int64 - r.windowAddress.int64)
      if offset >= 0 and offset < 8: ("fault", true)
      else: ("fault-outside-window+" & $offset, false)
    elif r.crashed: ("fault-no-window", false)
    elif r.exitCode == 0: ("survived", false)
    else: ("stray-exit-" & $r.exitCode, false)
  of "tier2":
    let replaced = p != nil and p.hasKey("lastTextReplaced") and
      p["lastTextReplaced"].getBool()
    if r.exitCode == 0 and pInt("anomalies") == 0 and
        pInt("publicationsApplied") == M4Publications and
        pInt("wxRequestsRefused") == 0 and replaced:
      ("clean", true)
    else: ("dirty-exit-" & $r.exitCode, false)
  of "sample":
    if r.exitCode == 0 and pInt("quiesceRounds") == M4SampleRounds and
        pInt("quiesceFailures") == 0 and
        pInt("parkedObservations") ==
          M4SampleRounds * (M4Workers + M4ChaosThreads) and
        pInt("distinctWorkerTids") == M4Workers:
      ("complete", true)
    else: ("incomplete-exit-" & $r.exitCode, false)
  else: ("unknown-arm", false)

proc runOne(binary, arm, hexA, hexB: string; windowMs: int;
            phase: string): JsonNode =
  let condition = sampleCondition(windowMs)
  let count = if arm == "sample": M4SampleRounds else: M4Publications
  var outcome = "error"
  var good = false
  var exitCode = -1
  try:
    let r = runFixture(binary, [arm, hexA, hexB, $M4Workers, $count,
                                $M4ChaosThreads])
    (outcome, good) = classify(arm, r)
    exitCode = r.exitCode
  except IOError as e:
    outcome = "error: " & e.msg.splitLines()[0]
  %*{"kind": "run", "phase": phase, "arm": arm, "reading": toJson(condition),
     "exitCode": exitCode, "outcome": outcome, "good": good}

# ---------------------------------------------------------------------------
# The table and the proposal.
# ---------------------------------------------------------------------------

proc toRow(n: JsonNode): Row =
  let reading = n["reading"]
  Row(phase: n["phase"].getStr(), arm: n["arm"].getStr(),
      reading: if reading["value"].kind == JNull: Inf
               else: reading["value"].getFloat(),
      cpus: if reading["cpus"].kind == JNull: 0.0
            else: reading["cpus"].getFloat(),
      cpuSource: reading["cpuSource"].getStr(),
      outcome: n["outcome"].getStr(), good: n["good"].getBool())

proc missProbability(rate: float; runs = M4RunsPerArm): float =
  ## P(fewer than half of `runs` fault) for a control faulting at `rate`:
  ## how often the gate's ">= 50%" would miss on a host where that is the
  ## true rate (exact binomial).
  let need = (runs + 1) div 2
  for k in 0 ..< need:
    result += float(binom(runs, k)) * pow(rate, float(k)) *
      pow(1.0 - rate, float(runs - k))

proc bucketLabel(lo, hi: float): string =
  (if lo.classify == fcNegInf: "<= " else: "(" & formatFloat(lo, ffDecimal, 2) & ", ") &
    (if hi.classify == fcInf: "inf)" else: formatFloat(hi, ffDecimal, 2) &
      (if lo.classify == fcNegInf: "" else: "]"))

proc summarize(rows: seq[Row]; hosts: seq[JsonNode]; opts: Options):
    (string, JsonNode) =
  var text = ""
  template line(s: string) = text.add(s & "\n")
  let required = RequiredControlRate + opts.margin
  let edges = @[NegInf] & opts.buckets & @[Inf]
  line("HLX-M4 calibration of " & ConditionMeasure & ", window " &
    $opts.windowMs & " ms")
  var dedicated = hosts.len > 0
  for h in hosts:
    if not h["dedicated"].getBool(): dedicated = false
    line("  phase " & h["phase"].getStr() & ": host " &
      h["hostname"].getStr() & ", kernel " & h["kernel"].getStr() &
      ", idle reading " & $h["idleReading"]["value"] & ", CPU set " &
      h["idleReading"]["cpuSource"].getStr() & ", loadavg " &
      h["loadavg"].getStr())
  if not dedicated:
    line("  WARNING: not every phase passed the dedicated-host check; " &
      "this record cannot be calibrated as is.")
  let unreadable = rows.filterIt(it.reading.classify == fcInf).len
  if unreadable > 0:
    line("  " & $unreadable & " runs had an unreadable reading (outside " &
      "every bucket; the gate counts them outside the conditions)")
  line("")
  line("reading bucket      | tier1 faults     | tier2-noadjust   | torn faults | tier2 clean | sample complete")
  var buckets = newJArray()
  var envelope = -1.0
  var lowest = Inf
  var stopped = false
  var pooled: seq[Row]
  for b in 0 ..< edges.len - 1:
    let lo = edges[b]
    let hi = edges[b + 1]
    # An unreadable (+Inf) reading is in no bucket: the top bucket's upper
    # edge is +Inf, and without this an unreadable run could widen the
    # proposed envelope to infinity.
    let inBucket = rows.filterIt(it.reading.classify != fcInf and
      it.reading > lo and it.reading <= hi)
    proc tally(arm: string): (int, int) =
      let xs = inBucket.filterIt(it.arm == arm)
      (xs.filterIt(it.good).len, xs.len)
    var cells: seq[string]
    var qualifies = true
    var why: seq[string]
    var bucketJson = %*{"lo": (if lo.classify == fcNegInf: newJNull() else: %lo),
                        "hi": (if hi.classify == fcInf: newJNull() else: %hi)}
    for arm in ["tier1", "tier2-noadjust", "torn", "tier2", "sample"]:
      let (good, n) = tally(arm)
      bucketJson[arm] = %*{"good": good, "runs": n}
      let rate = if n > 0: float(good) / float(n) else: NaN
      var cell = $good & "/" & $n
      if n > 0: cell.add(" (" & $int(round(rate * 100)) & "%)")
      if arm in ["tier1", "tier2-noadjust"] and n > 0:
        cell.add(" miss " & formatFloat(missProbability(rate) * 100,
          ffDecimal, 1) & "%")
      cells.add(cell)
      if arm notin opts.arms: continue
      if n < opts.minRuns and arm != "sample":
        qualifies = false
        why.add(arm & " has " & $n & " < " & $opts.minRuns & " runs")
      elif n == 0:
        qualifies = false
        why.add("sample has no runs")
      elif arm in ["tier1", "tier2-noadjust"] and rate < required:
        qualifies = false
        why.add(arm & " rate " & formatFloat(rate, ffDecimal, 2) & " < " &
          formatFloat(required, ffDecimal, 2))
      elif arm in ["torn", "tier2", "sample"] and good != n:
        qualifies = false
        why.add(arm & " " & $good & "/" & $n)
    bucketJson["qualifies"] = %qualifies
    if inBucket.len > 0:
      buckets.add(bucketJson)
      line(alignLeft(bucketLabel(lo, hi), 19) & " | " &
        cells.mapIt(alignLeft(it, 16)).join(" | ") &
        (if qualifies: "" else: "   <- " & why.join("; ")))
    if not stopped and (inBucket.len > 0 or pooled.len > 0):
      if qualifies:
        pooled.add(inBucket)
        for r in inBucket:
          envelope = max(envelope, r.reading)
          lowest = min(lowest, r.reading)
      else:
        # An empty bucket ABOVE the measured ones stops the envelope too: a
        # bound must not span readings nobody measured. Empty buckets BELOW
        # the lowest reading do not: they are the CPU set being quieter than
        # it ever was during the calibration, which the record states as
        # `minReading` so a reviewer can judge it.
        stopped = true
  line("")
  var proposal = %*{
    "schemaId": CalibrationSchemaId, "measure": ConditionMeasure,
    "status": (if dedicated: "proposed" else: "not-dedicated"),
    "statusNote": "Written by m4_calibrate.nim. The gate refuses this " &
      "status. To adopt it: review the table, set status to \"calibrated\" " &
      "and approvedBy to the approving person, and commit it as " &
      "tests/e2e/hcr-linux-threads/" & CalibrationRecordName & ".",
    "windowMs": opts.windowMs,
    "maxReading": (if envelope >= 0: %envelope else: newJNull()),
    "minReading": (if envelope >= 0: %lowest else: newJNull()),
    "host": (if hosts.len > 0: hosts[0]["hostname"] else: %""),
    "date": (if hosts.len > 0: hosts[0]["date"] else: %""),
    "kernel": (if hosts.len > 0: hosts[0]["kernel"] else: %""),
    "cpuSet": (if hosts.len > 0: hosts[0]["idleReading"]["affinity"] else: %""),
    "availableCpus": (if hosts.len > 0: hosts[0]["idleReading"]["cpus"]
    else: newJNull()),
    "cpuSource": (if hosts.len > 0: hosts[0]["idleReading"]["cpuSource"]
    else: %""),
    "approvedBy": "",
    "requiredControlRate": RequiredControlRate, "margin": opts.margin,
    "minRunsPerBucket": opts.minRuns,
    "phases": hosts.mapIt(it["phase"]),
    "dedicatedHostCheck": hosts,
    "buckets": buckets}
  if envelope < 0:
    line("PROPOSED ENVELOPE: none. The lowest measured bucket does not " &
      "qualify, so no reading can be shown to keep the controls at >= " &
      $int(round(required * 100)) & "% (or the arms lack --min-runs runs).")
  else:
    var rates = newJObject()
    for arm in ["tier1", "tier2-noadjust", "torn", "tier2", "sample"]:
      let xs = pooled.filterIt(it.arm == arm)
      rates[arm] = %*{"good": xs.filterIt(it.good).len, "runs": xs.len}
    proposal["controlRates"] = rates
    proposal["runsPerArm"] = %(pooled.filterIt(it.arm == "tier1").len)
    line("PROPOSED ENVELOPE: reading <= " & formatFloat(envelope, ffDecimal, 3) &
      " (the highest reading observed in the qualifying buckets; lowest " &
      "measured " & formatFloat(lowest, ffDecimal, 3) & "; rates inside " &
      "it: " & $rates & ")")
  if not dedicated:
    line("NOT ADOPTABLE: the dedicated-host check failed; the record is " &
      "stamped \"not-dedicated\".")
  (text, proposal)

proc readRows(files: seq[string]): (seq[Row], seq[JsonNode]) =
  for f in files:
    for l in lines(f):
      if l.strip().len == 0: continue
      let n = parseJson(l)
      if n["kind"].getStr() == "host": result[1].add(n)
      elif n["kind"].getStr() == "run": result[0].add(toRow(n))

proc main(): int =
  let opts = parseOptions()
  if opts.summarize.len > 0:
    let (rows, hosts) = readRows(opts.summarize)
    let (text, proposal) = summarize(rows, hosts, opts)
    stdout.write(text)
    echo pretty(proposal)
    return 0
  let repoRoot = getCurrentDir()
  let outDir = if opts.outDir.len > 0: opts.outDir
    else: repoRoot / "build" / "hcr-m4-calibration" /
      now().utc.format("yyyyMMdd'T'HHmmss'Z'")
  createDir(outDir)
  let bodies = buildPatchBodies(repoRoot)
  let binary = buildFixture(repoRoot, "hcr_lx_m4_threads.c", "m4_threads")
  let hexA = hex(bodies.a)
  let hexB = hex(bodies.b)
  let jsonl = open(outDir / "runs.jsonl", fmWrite)
  defer: jsonl.close()
  var hosts: seq[JsonNode]
  var rows: seq[Row]
  for phase in opts.phases:
    echo "== phase ", phase
    let host = dedicatedCheck(phase, opts)
    if not host["dedicated"].getBool() and not opts.allowNonDedicated:
      stderr.writeLine("refusing to calibrate on a host that is not " &
        "dedicated (idle reading above --max-idle-reading); pass " &
        "--allow-non-dedicated to measure anyway, and the record will be " &
        "stamped not-dedicated")
      return 2
    hosts.add(host)
    jsonl.writeLine($host)
    let load = startLoad(phase, opts.warmupS)
    try:
      # Round-robin over the arms, so a drift in the host's state during the
      # phase lands on every arm alike instead of on whichever ran last.
      for i in 0 ..< opts.runs:
        for arm in opts.arms:
          let row = runOne(binary, arm, hexA, hexB, opts.windowMs, phase)
          jsonl.writeLine($row)
          jsonl.flushFile()
          rows.add(toRow(row))
        if (i + 1) mod 8 == 0:
          echo "  ", i + 1, "/", opts.runs, " rounds"
    finally:
      stopLoad(load)
  let (text, proposal) = summarize(rows, hosts, opts)
  stdout.write(text)
  writeFile(outDir / "summary.txt", text)
  writeFile(outDir / "proposed-calibration.json", pretty(proposal) & "\n")
  echo "wrote ", outDir / "runs.jsonl", ", summary.txt, proposed-calibration.json"
  0

when isMainModule:
  quit(main())
