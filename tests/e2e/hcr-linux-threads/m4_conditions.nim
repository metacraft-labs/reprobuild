## The run condition of the HLX-M4 concurrency gate
## (`e2e_hcr_linux_concurrent_patch_no_torn_instruction`): what it measures,
## how many CPUs it divides by, and the calibration record that says which
## readings count as calibrated evidence.
##
## WHY THIS REPLACED `/proc/loadavg` / `countProcessors()`. The gate used to be
## judged by the host's 1-minute load average over the host's online CPUs.
## Both halves are host-wide. On the dedicated benchmark runner (cgroup
## `AllowedCPUs = 8-15` on gpu-server-001) the reading described the GPU
## host's whole run queue, not the eight CPUs the fixture's threads were
## allowed to run on, and over the ~230 s the gate takes the 1-minute average
## converged on the gate's OWN fifteen threads per fixture process -- worth
## 1.9 of the 2.0 envelope inside an 8-CPU slot. No host in the fleet met it
## (reprobuild-pm `issues/2026-11-22-no-ci-host-meets-the-hlx-m4-gates-
## calibrated-load-conditions.md`).
##
## WHAT IS MEASURED NOW: CONTENTION BY OTHERS ON THE CPU SET THE GATE MAY USE.
##
##   reading = sum over c in A of (d busy[c] + d run_delay[c])
##             ---------------------------------------------
##                       d wall-clock  x  N
##
## taken over a short window (`DefaultWindowMs`) IMMEDIATELY BEFORE each
## fixture process starts, while the gate itself is blocked in a sleep:
##
##   * `busy` is the per-CPU non-idle time of `/proc/stat` (user + nice +
##     system + irq + softirq + steal of each `cpu<N>` line, in USER_HZ
##     ticks; proc(5)) -- the time some task occupied that CPU. `run_delay`
##     is the per-CPU "time spent waiting to run" total of `/proc/schedstat`
##     (field 8 of each `cpu<N>` line, nanoseconds; kernel
##     `Documentation/scheduler/sched-stats.rst`,
##     https://docs.kernel.org/scheduler/sched-stats.html) -- the time tasks
##     spent runnable but queued behind another. Their sum over a window,
##     divided by the window, is the average number of runnable tasks on that
##     CPU -- a load figure, but per CPU and over the window, not a host-wide
##     exponential average. Both files are world-readable; the schedstat
##     counters need CONFIG_SCHEDSTATS (which also provides the file) but not
##     the `kernel.sched_schedstats` sysctl.
##   * Why not schedstat's own "time spent running" (field 7, `rq_cpu_time`):
##     the kernel credits it when a task is switched OUT, so a single busy
##     task alone on a CPU -- the commonest neighbour -- adds nothing for as
##     long as nothing preempts it, then a lump of seconds. Measured
##     2026-11-23 on kernel 6.18 (32 CPUs, one busy loop pinned to one CPU,
##     thirty 100 ms windows): field 7 + field 8 read 0.00 in 24 windows and
##     1.7-8.3 in the rest; `/proc/stat` busy + field 8 read 1.10-1.26 in
##     every one. `run_delay` is also credited at a switch (when the waiting
##     task gets the CPU), but a queued task gets it within a scheduler slice,
##     so it stays smooth: two busy loops on one CPU read 1.95-2.05 in every
##     window.
##   * `A` is the CPU set the process may run on: the affinity mask the kernel
##     reports for the reading thread (`Cpus_allowed_list` of
##     `/proc/thread-self/status`, proc(5) -- the mask sched_getaffinity(2)
##     returns, which inherits the cgroup's `cpuset.cpus.effective`),
##     intersected with the online CPUs, as sched_getaffinity(2) does.
##   * `N` is the CPUs actually AVAILABLE to the process: the size of `A`, or
##     the tightest `cpu.max` quota/period on the cgroup v2 path from the
##     process's cgroup to the root, whichever is smaller
##     (https://docs.kernel.org/admin-guide/cgroup-v2.html#cpu-interface-files).
##
## Why this window and not the fixture's own run: the gate's own threads are
## not running during it (the gate is blocked in `sleep`, and the previous
## fixture process has been reaped), so the reading cannot be moved by the
## gate's own load -- the self-inflation that made the load-average condition
## unsatisfiable. It is read BEFORE the process starts, so it is independent of
## the outcome (the rule's second part). And it is scoped to the CPUs the
## fixture's threads compete for, so a busy neighbour on CPUs the gate cannot
## use does not count, and one on its CPUs does.
##
## Why not the job's own cgroup `cpu.pressure`. PSI on the gate's cgroup is
## recorded beside the reading (attribution only) but is not the condition: a
## cgroup's PSI counts only stalls of the cgroup's OWN tasks, so while the
## gate is idle it cannot see a neighbour at all, and while the fixture runs
## it counts the fixture's own fifteen threads queueing behind each other
## (measured 2026-11-22, issue above). The idle-window per-CPU reading is the
## form of "pressure scoped to the CPU set" that answers the question the
## calibration asks: was the CPU set contended by somebody else.
##
## LIMITS, stated so nobody reads more into the number than it holds:
##
##   * It is a snapshot of the `DefaultWindowMs` before a run, not of the run.
##     A neighbour that starts mid-run is missed, as it was by the old
##     reading; one that is bursty at a period longer than the window is seen
##     on some runs and not others. The gate starts hundreds of processes, so
##     the arm-level distribution is what the calibration buckets.
##   * `/proc/stat` is in USER_HZ ticks (10 ms at the usual 100), so each
##     CPU's busy delta over a 100 ms window is quantised to 0.1; averaged
##     over the set the error shrinks, but a bound finer than that on a small
##     set is not measurable.
##   * It counts CPU time only. Memory-bandwidth, cache, SMT-sibling and
##     interrupt interference are not CPU run-queue time, and the 2026-11-22
##     investigation found the negative controls' degradation under real build
##     load is NOT explained by run-queue wait. Hence the bound is not
##     inferred from that investigation: it must come from a calibration of
##     THIS quantity under the load the gate actually meets, on a dedicated
##     host (`m4_calibrate.nim`).
##   * When `cpu.max` makes `N` smaller than `A`, the numerator still sums
##     every CPU of `A`, so the reading overstates contention. That can only
##     withhold a verdict, never admit a run that should not count.
##   * An SMT sibling outside `A` is invisible to it.
##
## UNREADABLE IS OUTSIDE. Any input that cannot be read or parsed -- no
## `/proc/stat` or `/proc/schedstat`, an unrecognised schedstat version, an
## affinity CPU with no `cpu<N>` line in either, no CPUs available -- makes
## the reading +Inf, and the reason is kept in `ConditionReading.error`. A
## host this cannot measure never has its runs counted as calibrated
## evidence.
##
## THE BOUND IS DATA, NOT CODE. Which readings count is decided by the
## committed calibration record `hlx_m4_calibration.json` next to this file,
## not by a constant: recalibration is a data change a reviewer can read in
## one diff, with the host, kernel, CPU set, run counts and control rates the
## bound was measured with. Until a record with `status = "calibrated"` and a
## named approver exists, NO run is inside the conditions and the gate
## withholds its verdict with the reason "condition not yet calibrated on a
## dedicated host" -- it never counts an uncalibrated run as evidence.
##
## Everything here is std-only and pure over a filesystem root, so it is
## tested against real files (`t_integration_hcr_linux_concurrent_patch_gate_
## conditions.nim`) and used by both the gate and the calibration driver.

import std/[json, math, monotimes, os, posix, strutils, tables, times]

const
  ## The identity of the measured quantity. A calibration record names it, and
  ## a record for a different quantity (or a later revision of this one) is
  ## refused: a bound is only meaningful for the quantity it was measured on.
  ConditionMeasure* = "hlx-m4.cpuset-runnable-per-available-cpu.v1"
  ## The window the reading is taken over before every fixture process. A
  ## calibration record carries the window it was measured with; the gate uses
  ## the record's, so the two cannot drift apart.
  DefaultWindowMs* = 100
  CalibrationSchemaId* = "reprobuild.hcr.hlx-m4.calibration.v1"
  CalibrationRecordName* = "hlx_m4_calibration.json"
  ## `/proc/schedstat` versions whose `cpu<N>` line layout this parser knows:
  ## 15 (kernel 4.x-6.5), 16 and 17 (6.6+) all keep run time and run delay at
  ## fields 7 and 8. A later version is treated as unreadable until checked.
  ## (Only field 8 enters the reading; see the module header for field 7.)
  KnownSchedstatVersions* = [15, 16, 17]

type
  CpuBudget* = object
    ## The CPUs available to the process, and where that number came from.
    cpus*: float         ## min(affinity count, quota); 0 when unknown
    affinity*: seq[int]  ## the affinity set, intersected with online
    quotaCpus*: float    ## tightest cpu.max quota/period; Inf when none
    quotaCgroup*: string ## the cgroup whose cpu.max binds; "" when none
    source*: string      ## human-readable: which input decided `cpus`
    error*: string       ## why `cpus` is 0, when it is

  ConditionReading* = object
    ## One reading of the condition, plus attribution-only context.
    value*: float          ## the condition; +Inf when unreadable
    budget*: CpuBudget
    windowNs*: int64       ## the measured window
    hostLoadPerCpu*: float ## /proc/loadavg 1-min / online CPUs (attribution)
    cgroupCpuSome*: float  ## d cgroup cpu.pressure some / window; -1 unknown
    hostCpuSome*: float    ## d /proc/pressure/cpu some / window; -1 unknown
    error*: string         ## why `value` is +Inf, when it is

  SchedstatCpu* = object
    runNs*, waitNs*: int64 ## fields 7 and 8 of a `/proc/schedstat` cpu line

  CpuCounters* = object
    ## One CPU's inputs to the reading, both cumulative nanoseconds.
    busyNs*: int64 ## `/proc/stat` non-idle time
    waitNs*: int64 ## `/proc/schedstat` run delay

  Calibration* = object
    ## The committed calibration record, reduced to what the gate needs.
    calibrated*: bool  ## true only for a complete, approved record
    maxReading*: float ## the measured envelope; meaningful when calibrated
    windowMs*: int
    recordPath*: string
    status*: string    ## the record's own status field
    reason*: string    ## why not calibrated, when not
    host*, date*, kernel*, cpuSet*, approvedBy*: string

# ---------------------------------------------------------------------------
# Pure parsers. Each raises ValueError on malformed input; the readers below
# turn that into an unreadable (+Inf) reading.
# ---------------------------------------------------------------------------

proc parseCpuList*(text: string): seq[int] =
  ## A kernel CPU list ("0-3,8,10-11"), as in `Cpus_allowed_list` and
  ## `/sys/devices/system/cpu/online` (Documentation/admin-guide/cputopology).
  let trimmed = text.strip()
  if trimmed.len == 0:
    raise newException(ValueError, "empty CPU list")
  for part in trimmed.split(','):
    let item = part.strip()
    let dash = item.find('-')
    if dash < 0:
      result.add(parseInt(item))
    else:
      let lo = parseInt(item[0 ..< dash])
      let hi = parseInt(item[dash + 1 .. ^1])
      if lo < 0 or hi < lo:
        raise newException(ValueError, "bad CPU range " & item)
      for cpu in lo .. hi:
        result.add(cpu)
  for cpu in result:
    if cpu < 0:
      raise newException(ValueError, "negative CPU in " & trimmed)

proc formatCpuList*(cpus: openArray[int]): string =
  ## The inverse of `parseCpuList`, for diagnostics ("8-15").
  var i = 0
  while i < cpus.len:
    var j = i
    while j + 1 < cpus.len and cpus[j + 1] == cpus[j] + 1:
      inc j
    if result.len > 0: result.add(',')
    result.add($cpus[i])
    if j > i: result.add('-' & $cpus[j])
    i = j + 1

proc parseAllowedCpus*(statusText: string): seq[int] =
  ## `Cpus_allowed_list:` from a `/proc/<pid>/status` (proc(5)).
  for line in statusText.splitLines():
    if line.startsWith("Cpus_allowed_list:"):
      return parseCpuList(line["Cpus_allowed_list:".len .. ^1])
  raise newException(ValueError, "no Cpus_allowed_list line")

proc parseCgroupV2Path*(procCgroupText: string): string =
  ## The unified-hierarchy path from `/proc/self/cgroup` (the `0::` line,
  ## cgroups(7)). Raises when the process has no cgroup v2 membership.
  for line in procCgroupText.splitLines():
    if line.startsWith("0::"):
      return line[3 .. ^1].strip()
  raise newException(ValueError, "no cgroup v2 (0::) line")

proc parseCpuMax*(text: string): float =
  ## `cpu.max` is "$MAX $PERIOD", where $MAX is "max" for no limit
  ## (cgroup-v2.rst, "cpu.max"). Returns the quota in CPUs; +Inf for "max".
  let fields = text.splitWhitespace()
  if fields.len != 2:
    raise newException(ValueError, "cpu.max is not \"$MAX $PERIOD\": " &
      text.strip())
  let period = parseFloat(fields[1])
  if period <= 0:
    raise newException(ValueError, "cpu.max period is not positive")
  if fields[0] == "max":
    return Inf
  let quota = parseFloat(fields[0])
  if quota <= 0:
    raise newException(ValueError, "cpu.max quota is not positive")
  quota / period

proc parseSchedstat*(text: string): Table[int, SchedstatCpu] =
  ## The per-CPU run-time and run-delay totals of `/proc/schedstat`.
  var version = -1
  for line in text.splitLines():
    if line.startsWith("version "):
      version = parseInt(line["version ".len .. ^1].strip())
      if version notin KnownSchedstatVersions:
        raise newException(ValueError,
          "unrecognised /proc/schedstat version " & $version)
    elif line.startsWith("cpu"):
      if version < 0:
        raise newException(ValueError, "/proc/schedstat has no version line")
      let fields = line.splitWhitespace()
      # cpu<N> f1 .. f9: f7 = time running (rq_cpu_time), f8 = time waiting
      # (run_delay), both in nanoseconds.
      if fields.len < 10:
        raise newException(ValueError, "short schedstat line: " & line)
      let cpu = parseInt(fields[0][3 .. ^1])
      result[cpu] = SchedstatCpu(runNs: parseBiggestInt(fields[7]),
                                 waitNs: parseBiggestInt(fields[8]))
  if version < 0:
    raise newException(ValueError, "/proc/schedstat has no version line")

proc parseProcStatBusy*(text: string; clkTck: int): Table[int, int64] =
  ## The per-CPU non-idle time of `/proc/stat`, in nanoseconds: user + nice +
  ## system + irq + softirq + steal (proc(5); `guest` is already inside
  ## `user`, and `idle` / `iowait` are idle). `clkTck` is USER_HZ, the unit
  ## of those fields (`sysconf(_SC_CLK_TCK)`). The aggregate `cpu` line is
  ## skipped.
  if clkTck <= 0:
    raise newException(ValueError, "USER_HZ is not positive")
  for line in text.splitLines():
    if not line.startsWith("cpu") or line.len < 4 or line[3] notin Digits:
      continue
    let fields = line.splitWhitespace()
    # cpu<N> user nice system idle iowait irq softirq steal [guest guest_nice]
    if fields.len < 9:
      raise newException(ValueError, "short /proc/stat line: " & line)
    let cpu = parseInt(fields[0][3 .. ^1])
    var ticks = 0'i64
    for i in [1, 2, 3, 6, 7, 8]:
      ticks += parseBiggestInt(fields[i])
    result[cpu] = ticks * 1_000_000_000'i64 div int64(clkTck)
  if result.len == 0:
    raise newException(ValueError, "/proc/stat has no cpu<N> lines")

proc mergeCounters*(busy: Table[int, int64];
                    schedstat: Table[int, SchedstatCpu]):
                    Table[int, CpuCounters] =
  ## The CPUs present in both sources. A CPU missing from either is left out,
  ## which `conditionValue` reports when it is in the affinity set.
  for cpu, busyNs in busy:
    if cpu in schedstat:
      result[cpu] = CpuCounters(busyNs: busyNs, waitNs: schedstat[cpu].waitNs)

proc parsePressureSomeTotal*(text: string): int64 =
  ## The cumulative `some` stall time, microseconds, of a PSI file
  ## (Documentation/accounting/psi.rst).
  for line in text.splitLines():
    if line.startsWith("some "):
      for field in line.splitWhitespace():
        if field.startsWith("total="):
          return parseBiggestInt(field["total=".len .. ^1])
  raise newException(ValueError, "no `some ... total=` in PSI text")

proc conditionValue*(before, after: Table[int, CpuCounters];
                     elapsedNs: int64; budget: CpuBudget): float =
  ## The condition from two counter snapshots (formula in the module
  ## header). Raises when a CPU of the affinity set is missing from either
  ## snapshot, when a counter went backwards, or when nothing is available to
  ## divide by.
  if elapsedNs <= 0:
    raise newException(ValueError, "empty measurement window")
  if budget.cpus <= 0 or budget.affinity.len == 0:
    raise newException(ValueError, "no CPUs available: " & budget.error)
  var busyNs = 0'i64
  for cpu in budget.affinity:
    if cpu notin before or cpu notin after:
      raise newException(ValueError,
        "no /proc/stat or /proc/schedstat line for cpu" & $cpu)
    let dBusy = after[cpu].busyNs - before[cpu].busyNs
    let dWait = after[cpu].waitNs - before[cpu].waitNs
    if dBusy < 0 or dWait < 0:
      raise newException(ValueError, "a CPU counter went backwards on cpu" &
        $cpu)
    busyNs += dBusy + dWait
  float(busyNs) / float(elapsedNs) / budget.cpus

# ---------------------------------------------------------------------------
# Readers over a filesystem root, so tests can point them at fixture trees.
# ---------------------------------------------------------------------------

proc readCpuBudget*(procRoot = "/proc"; sysRoot = "/sys"): CpuBudget =
  ## The CPUs available to the calling thread. Never raises: an unreadable
  ## affinity leaves `cpus = 0` with `error` set; an unreadable cgroup leaves
  ## the quota at +Inf (unconstrained), which is what the absence of a cgroup
  ## v2 limit means.
  result.quotaCpus = Inf
  try:
    let statusPath =
      if fileExists(procRoot / "thread-self" / "status"):
        procRoot / "thread-self" / "status"
      else: procRoot / "self" / "status"
    var allowed = parseAllowedCpus(readFile(statusPath))
    try:
      let online = parseCpuList(readFile(
        sysRoot / "devices" / "system" / "cpu" / "online"))
      var kept: seq[int]
      for cpu in allowed:
        if cpu in online: kept.add(cpu)
      allowed = kept
    except CatchableError:
      discard # no online list: the affinity mask alone
    result.affinity = allowed
  except CatchableError as e:
    result.error = "affinity unreadable: " & e.msg
    result.source = result.error
    return
  var quotaNote = "no cgroup v2"
  try:
    let rel = parseCgroupV2Path(readFile(procRoot / "self" / "cgroup"))
    let base = sysRoot / "fs" / "cgroup"
    var dir = rel
    quotaNote = "cpu.max max on " & rel
    while true:
      let file = base / dir / "cpu.max"
      if fileExists(file):
        let quota = parseCpuMax(readFile(file))
        if quota < result.quotaCpus:
          result.quotaCpus = quota
          result.quotaCgroup = if dir.len == 0: "/" else: dir
      if dir.len == 0 or dir == "/":
        break
      dir = parentDir(dir)
      if dir == ".": dir = ""
  except CatchableError as e:
    quotaNote = "cgroup unreadable (" & e.msg & ")"
    result.quotaCpus = Inf
    result.quotaCgroup = ""
  let affinityCount = float(result.affinity.len)
  if result.affinity.len == 0:
    result.error = "affinity set is empty after intersecting with online CPUs"
    result.cpus = 0
  elif result.quotaCpus < affinityCount:
    result.cpus = result.quotaCpus
  else:
    result.cpus = affinityCount
  let affinityText = "affinity " & formatCpuList(result.affinity) & " (" &
    $result.affinity.len & ")"
  if result.quotaCgroup.len > 0:
    let quotaText = "cpu.max " & formatFloat(result.quotaCpus, ffDecimal, 2) &
      " on " & result.quotaCgroup
    result.source =
      if result.quotaCpus < affinityCount: quotaText & ", narrower than " &
        affinityText
      else: affinityText & "; " & quotaText
  else:
    result.source = affinityText & "; " & quotaNote

proc readHostLoadPerCpu*(procRoot = "/proc"; sysRoot = "/sys"): float =
  ## Attribution only: the host-wide 1-minute load over online CPUs, the
  ## quantity the gate used to be judged by. +Inf when unreadable.
  try:
    let load = parseFloat(readFile(procRoot / "loadavg").splitWhitespace()[0])
    let online = parseCpuList(readFile(
      sysRoot / "devices" / "system" / "cpu" / "online"))
    load / float(online.len)
  except CatchableError:
    Inf

proc cgroupPressurePath(procRoot, sysRoot: string): string =
  try:
    sysRoot / "fs" / "cgroup" /
      parseCgroupV2Path(readFile(procRoot / "self" / "cgroup")) / "cpu.pressure"
  except CatchableError:
    ""

proc readPsiSome(path: string): int64 =
  ## -1 when unreadable.
  if path.len == 0: return -1
  try: parsePressureSomeTotal(readFile(path))
  except CatchableError: -1

proc psiFraction(before, after, elapsedNs: int64): float =
  if before < 0 or after < before or elapsedNs <= 0: -1.0
  else: float(after - before) * 1000.0 / float(elapsedNs)

proc defaultSleep(ms: int) = sleep(ms)

proc hostClkTck*(): int =
  ## USER_HZ, the unit of `/proc/stat` (sysconf(3) `_SC_CLK_TCK`); 0 when the
  ## call fails, which `parseProcStatBusy` refuses.
  max(0, int(sysconf(SC_CLK_TCK)))

proc readCpuCounters*(procRoot: string; clkTck: int): Table[int, CpuCounters] =
  ## One snapshot of both sources. `/proc/stat` is read first and
  ## `/proc/schedstat` immediately after, so the two describe the same
  ## instant to within the cost of two small reads.
  let busy = parseProcStatBusy(readFile(procRoot / "stat"), clkTck)
  mergeCounters(busy, parseSchedstat(readFile(procRoot / "schedstat")))

proc sampleCondition*(windowMs = DefaultWindowMs; procRoot = "/proc";
                      sysRoot = "/sys";
                      wait: proc (ms: int) {.closure.} = nil;
                      clkTck = 0): ConditionReading =
  ## Take one reading: snapshot, block for `windowMs`, snapshot again. Call it
  ## immediately before starting a fixture process, with no fixture running.
  ## `wait` defaults to `sleep`; it exists so a test can change the fixture
  ## tree between the two snapshots and observe the arithmetic on real files.
  ## `clkTck` is `/proc/stat`'s unit; 0 means this host's USER_HZ.
  result.value = Inf
  result.cgroupCpuSome = -1
  result.hostCpuSome = -1
  result.hostLoadPerCpu = readHostLoadPerCpu(procRoot, sysRoot)
  result.budget = readCpuBudget(procRoot, sysRoot)
  let ticks = if clkTck > 0: clkTck else: hostClkTck()
  let cgroupPsi = cgroupPressurePath(procRoot, sysRoot)
  let hostPsi = procRoot / "pressure" / "cpu"
  try:
    let cgBefore = readPsiSome(cgroupPsi)
    let hostBefore = readPsiSome(hostPsi)
    let before = readCpuCounters(procRoot, ticks)
    let start = getMonoTime()
    if wait == nil: defaultSleep(windowMs) else: wait(windowMs)
    let after = readCpuCounters(procRoot, ticks)
    let elapsed = inNanoseconds(getMonoTime() - start)
    let cgAfter = readPsiSome(cgroupPsi)
    let hostAfter = readPsiSome(hostPsi)
    result.windowNs = elapsed
    result.cgroupCpuSome = psiFraction(cgBefore, cgAfter, elapsed)
    result.hostCpuSome = psiFraction(hostBefore, hostAfter, elapsed)
    result.value = conditionValue(before, after, elapsed, result.budget)
  except CatchableError as e:
    result.value = Inf
    result.error = e.msg

proc finiteOrNull*(x: float): JsonNode =
  ## A float as JSON. Infinity and NaN are not representable in JSON (std/json
  ## would write a bare `inf`), so they become null; the reading's `error`
  ## says why, where there is one.
  if x.classify in {fcInf, fcNegInf, fcNan}: newJNull() else: %x

proc toJson*(reading: ConditionReading): JsonNode =
  ## The per-run evidence record. An unreadable value is written as null
  ## beside its error.
  proc num(x: float): JsonNode = finiteOrNull(x)
  %*{"value": num(reading.value), "cpus": num(reading.budget.cpus),
     "cpuSource": reading.budget.source,
     "affinity": formatCpuList(reading.budget.affinity),
     "windowNs": reading.windowNs,
     "hostLoadPerCpu": num(reading.hostLoadPerCpu),
     "cgroupCpuSome": reading.cgroupCpuSome,
     "hostCpuSome": reading.hostCpuSome, "error": reading.error}

# ---------------------------------------------------------------------------
# The calibration record.
# ---------------------------------------------------------------------------

proc calibrationRecordPath*(caseDir: string): string =
  caseDir / CalibrationRecordName

proc parseCalibration*(text, path: string): Calibration =
  ## A record counts only when it is complete and approved. Anything else --
  ## a pending record, a missing field, a different measure, a malformed file
  ## -- is "not calibrated" with the reason, which the gate turns into a
  ## withheld verdict, never into counted evidence.
  result.recordPath = path
  result.windowMs = DefaultWindowMs
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError as e:
    result.reason = "calibration record " & path & " is not JSON: " & e.msg
    return
  proc str(key: string): string =
    if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
      node[key].getStr()
    else: ""
  if node.kind != JObject or str("schemaId") != CalibrationSchemaId:
    result.reason = "calibration record " & path & " is not a " &
      CalibrationSchemaId & " record"
    return
  if str("measure") != ConditionMeasure:
    result.reason = "calibration record " & path & " is for measure \"" &
      str("measure") & "\", not " & ConditionMeasure
    return
  if node.hasKey("windowMs") and node["windowMs"].kind == JInt and
      node["windowMs"].getInt() > 0:
    result.windowMs = node["windowMs"].getInt()
  result.status = str("status")
  result.host = str("host")
  result.date = str("date")
  result.kernel = str("kernel")
  result.cpuSet = str("cpuSet")
  result.approvedBy = str("approvedBy")
  if result.status != "calibrated":
    result.reason = "condition not yet calibrated on a dedicated host (" &
      path & " has status \"" & result.status & "\")"
    return
  let bound = if node.hasKey("maxReading"): node["maxReading"] else: nil
  # Zero is a legitimate envelope (only an uncontended CPU set counts);
  # negative, infinite or NaN is not a measurement.
  if bound == nil or bound.kind notin {JFloat, JInt} or
      not (bound.getFloat() >= 0.0) or bound.getFloat().classify == fcInf:
    result.reason = "calibration record " & path &
      " says calibrated but has no finite non-negative maxReading"
    return
  var missing: seq[string]
  for (name, value) in [("host", result.host), ("date", result.date),
                        ("kernel", result.kernel), ("cpuSet", result.cpuSet),
                        ("approvedBy", result.approvedBy)]:
    if value.len == 0: missing.add(name)
  if not (node.hasKey("windowMs") and node["windowMs"].kind == JInt):
    missing.add("windowMs")
  if missing.len > 0:
    result.reason = "calibration record " & path &
      " says calibrated but lacks " & missing.join(", ")
    return
  result.maxReading = bound.getFloat()
  result.calibrated = true

proc loadCalibration*(path: string): Calibration =
  if not fileExists(path):
    return Calibration(recordPath: path, windowMs: DefaultWindowMs,
      reason: "condition not yet calibrated on a dedicated host (no " &
        "calibration record at " & path & ")")
  try:
    parseCalibration(readFile(path), path)
  except CatchableError as e:
    Calibration(recordPath: path, windowMs: DefaultWindowMs,
      reason: "calibration record " & path & " is unreadable: " & e.msg)

proc inConditions*(calibration: Calibration; reading: float): bool =
  ## A run counts as calibrated evidence only under an approved record and
  ## inside its envelope. NaN compares false, so it is outside too.
  calibration.calibrated and reading <= calibration.maxReading

proc describe*(calibration: Calibration): string =
  ## The condition as the gate's reason states it.
  if calibration.calibrated:
    "HLX-M4 condition " & ConditionMeasure & " <= " &
      formatFloat(calibration.maxReading, ffDecimal, 2) & " over " &
      $calibration.windowMs & " ms, calibrated on " & calibration.host & " (" &
      calibration.cpuSet & ", kernel " & calibration.kernel & ", " &
      calibration.date & ", approved by " & calibration.approvedBy & ")"
  else:
    # The reason itself leads the verdict's `conditionsReason`; repeating it
    # here would print it twice on one line.
    "HLX-M4 condition " & ConditionMeasure & ", no approved calibration " &
      "record at " & calibration.recordPath
