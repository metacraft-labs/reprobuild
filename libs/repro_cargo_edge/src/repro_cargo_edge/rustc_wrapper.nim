## The rustc wrapper: reports each compiled unit's totals to RunQuota and
## otherwise gets out of the way.
##
## Cargo runs `$RUSTC_WRAPPER rustc <args>` for every unit it compiles
## (https://doc.rust-lang.org/cargo/reference/config.html#buildrustc-wrapper).
## This program runs `rustc <args>` and, when it runs inside a leased action,
## records what that compile cost under a key naming the unit
## (`rustc_args.statsKeyOf`), so RunQuota learns the shape of each crate's
## compile and the next build can be sized by it.
##
## THE CONTRACT, in the order it is enforced:
##
## 1. It NEVER changes the command line, the environment or the standard
##    streams of the compiler. The arguments rustc receives are the ones cargo
##    gave, byte for byte; the child inherits the three standard streams and
##    the environment as they are. A wrapper that normalised, reordered or
##    dropped an argument would change what is built; `test_rqe_cg3_wrapper_
##    is_transparent` compares the argument lines and the final binaries with
##    and without it.
## 2. Anything it cannot do, it does not do, and runs the compiler unchanged:
##    no daemon, no parent lease (`RUNQUOTA_PARENT_LEASE`), a daemon that
##    predates sub-leases, a refused or slow sub-lease, a failed report. It
##    never takes a HOST lease: the compile already runs inside its action's
##    grant, and a second claim on the host would count one piece of work
##    twice and could wait behind its own parent.
## 3. It exits as the compiler did: the same exit code, or the same signal
##    (it re-raises it on itself), so cargo sees what rustc did.
##
## THE COST. Totals are what `wait4` returns when the wrapper reaps the
## compiler (CPU time, largest resident set), so measuring adds no sampling.
## With the client-side `profiles` or `tree-sampling` measurement switched on
## (`RUNQUOTA_MEASUREMENT`, RunQuota's own switch) the compile is launched
## through `runquota_process`, which takes the CPU profile within the budget
## the overhead gate sets; without them the wrapper blocks in `wait4` and adds a few
## round trips to a local socket and nothing else.

import std/[os, options, strutils]
when defined(posix):
  import std/posix
else:
  import std/osproc

import runquota_client
import runquota_core
import runquota_core/cpu_profile
import runquota_core/measurement
import runquota_exec
import runquota_process
import runquota_protocol
import ./[plan_run, record_mode, rustc_args, wrapper_env]

const
  WrapperLogEnv* = "REPRO_RUSTC_WRAPPER_LOG"
    ## A file the wrapper appends one line to per unit it saw: the crate and
    ## whether it was reported, or why it was not. Off unless set; it is how
    ## a report that did not arrive is told from one that was never taken.
  WrapperClientName = "repro-rustc-wrapper"
  WrapperClientVersion = "0.1"
  SubLeaseCpuMilli = 1'u32
    ## What a unit's sub-lease holds of its parent's CPU: one thousandth of a
    ## slot. The wrapper reports; it does not size, and it must not wait for
    ## capacity. More compiles can run at once than the action's width (cargo
    ## pipelines a crate's code generation behind the metadata its dependents
    ## wait for, so a unit's rustc outlives its token), and a whole-slot
    ## sub-lease would queue behind them, and lose the report, for the
    ## seconds they take.
  SubLeaseMemoryBytes = 4096'u64
    ## And of its parent's memory, for the same reason.
  SubLeaseWaitPolls = 40
    ## 40 polls of 50 ms. A sub-lease that cannot be granted within two
    ## seconds is abandoned and the compile runs unreported: the compiler
    ## never waits on a measurement for longer than that.

proc noteOutcome(crate, outcome: string) =
  ## `REPRO_RUSTC_WRAPPER_LOG`: one line, `<crate>\t<outcome>`.
  let path = getEnv(WrapperLogEnv)
  if path.len == 0: return
  try:
    var log = open(path, fmAppend)
    log.writeLine crate & "\t" & outcome
    log.close()
  except CatchableError:
    discard

proc realCommand*(args: seq[string]; inner: string): seq[string] =
  ## The command to run: `args` as cargo gave them (`rustc <rustc args>`),
  ## behind the project's own wrapper when it had one.
  if inner.len > 0: @[inner] & args else: args

when defined(posix):
  proc executeInPlace(command: seq[string]): int =
    ## `execvp` the command. Returns only on failure.
    let argv = allocCStringArray(command)
    discard execvp(command[0].cstring, argv)
    let failure = osErrorMsg(osLastError())
    stderr.writeLine WrapperClientName & ": cannot run " & command[0] & ": " &
      failure
    127

  proc mirrorStatus(status: cint): int =
    ## End the way the compiler ended: its exit code, or its signal.
    if WIFSIGNALED(status):
      let signal = WTERMSIG(status)
      stdout.flushFile()
      stderr.flushFile()
      var dflt: Sigaction
      dflt.sa_handler = SIG_DFL
      discard sigemptyset(dflt.sa_mask)
      discard sigaction(signal, dflt, nil)
      discard kill(getpid(), signal)
      return 128 + int(signal)
    int(WEXITSTATUS(status))
else:
  proc executeInPlace(command: seq[string]): int =
    try:
      let process = startProcess(command[0], args = command[1 .. ^1],
        options = {poUsePath, poParentStreams})
      result = process.waitForExit()
      process.close()
    except CatchableError as err:
      stderr.writeLine WrapperClientName & ": cannot run " & command[0] &
        ": " & err.msg
      result = 127

type
  WrapperRun* = object
    ## What the wrapper did, for tests: whether the unit was reported.
    reported*: bool

when defined(posix):
  proc elapsedMillis(startNs: int64): uint64 =
    ## Milliseconds since `startNs` on the monotonic clock.
    var now: Timespec
    discard clock_gettime(CLOCK_MONOTONIC, now)
    let ns = int64(now.tv_sec) * 1_000_000_000'i64 + int64(now.tv_nsec)
    uint64(max(0'i64, (ns - startNs) div 1_000_000'i64))

  proc monotonicNanos(): int64 =
    var now: Timespec
    discard clock_gettime(CLOCK_MONOTONIC, now)
    int64(now.tv_sec) * 1_000_000_000'i64 + int64(now.tv_nsec)

  proc timevalMicros(value: Timeval): uint64 =
    uint64(max(0'i64, int64(value.tv_sec))) * 1_000_000'u64 +
      uint64(max(0'i64, int64(value.tv_usec)))

  proc forkAndWait(command: seq[string]; lease: var RunQuotaLease;
                   crate: string): int =
    ## Run the compiler as a child, reporting under `lease`, and return the
    ## wrapper's own exit code (or end it by the compiler's signal).
    ##
    ## `fork`+`exec` and a blocking `wait4`: the compiler is not delayed by
    ## a poll interval, and the kernel hands over the CPU totals with the
    ## status.
    let argv = allocCStringArray(command)
    let startedAt = monotonicNanos()
    let pid = fork()
    if pid < 0:
      stderr.writeLine WrapperClientName & ": fork failed: " &
        osErrorMsg(osLastError())
      return 127
    if pid == 0:
      discard execvp(command[0].cstring, argv)
      # Only the child gets here, and only when exec failed.
      let message = WrapperClientName & ": cannot run " & command[0] & "\n"
      discard write(2, message.cstring, message.len)
      exitnow(127)
    try:
      lease.markRunning(childProcessId = uint64(pid))
    except CatchableError:
      discard
    var status: cint = 0
    var usage: Rusage
    while wait4(pid, addr status, 0, addr usage) < 0:
      if errno != EINTR:
        # Not our child any more (something reaped it): nothing to report.
        try: lease.finish(outcome = cancelled()) except CatchableError: discard
        try: lease.release() except CatchableError: discard
        return 127
    let maxRss = uint64(max(0'i64, int64(usage.ru_maxrss)))
    let totals = FinishTotals(known: true,
      cpuUserMicros: timevalMicros(usage.ru_utime),
      cpuSysMicros: timevalMicros(usage.ru_stime),
      # `ru_maxrss` is KiB on Linux and bytes on macOS (getrusage(2)).
      maxRssBytes: (when defined(macosx): maxRss else: maxRss * 1024'u64),
      majorPageFaults: uint64(max(0'i64, int64(usage.ru_majflt))),
      durationMillis: elapsedMillis(startedAt))
    let outcome =
      if WIFSIGNALED(status): crashed(uint32(WTERMSIG(status)))
      elif WEXITSTATUS(status) != 0: failed(uint32(WEXITSTATUS(status)))
      else: succeeded()
    try:
      lease.finish(outcome = outcome, peakMemoryBytes = totals.maxRssBytes,
        processCount = 1, totals = totals)
      lease.release()
    except CatchableError as err:
      noteOutcome(crate, "unreported: finish failed: " & err.msg)
    mirrorStatus(status)

  proc launcherRun(command: seq[string]; lease: var RunQuotaLease;
                   crate: string): int =
    ## The compile through `runquota_process`, for the measurements that need
    ## the launcher (CPU profile, tree sampling): it samples the tree while
    ## it waits, within the overhead gate's budget, and the totals and the profile
    ## travel with the finish. Streams are inherited, never captured.
    var child: LaunchedProcess
    try:
      child = launchProcess(commandSpec(command, stdio = inheritStdio,
        createProcessGroup = false))
    except CatchableError as err:
      stderr.writeLine WrapperClientName & ": cannot run " & command[0] &
        ": " & err.msg
      try: lease.finish(outcome = launchFailed()) except CatchableError: discard
      try: lease.release() except CatchableError: discard
      return 127
    try:
      lease.markRunning(childProcessId = child.info.processId)
    except CatchableError:
      discard
    let completion = child.waitForCompletion()
    child.close()
    try:
      lease.finish(outcome = finishOutcome(completion),
        peakMemoryBytes = completion.peakResidentMemoryBytes,
        processCount = completion.processCount,
        totals = completion.totals, cpuProfile = completion.cpuProfile,
        sizing = completion.finishSizing())
      lease.release()
    except CatchableError as err:
      noteOutcome(crate, "unreported: finish failed: " & err.msg)
    if completion.signaled:
      var dflt: Sigaction
      dflt.sa_handler = SIG_DFL
      discard sigemptyset(dflt.sa_mask)
      discard sigaction(cint(completion.signal), dflt, nil)
      discard kill(getpid(), cint(completion.signal))
      return 128 + completion.signal
    if completion.exited: completion.exitCode else: 1

  proc reportedRun(command: seq[string]; unit: RustcUnit;
                   parent: LeaseId; ran: var bool): int =
    ## The reporting path. `ran` becomes true once the compiler has been
    ## started, so the caller never starts it a second time.
    var client: RunQuotaClient
    try:
      client = connectDefault()
    except CatchableError as err:
      noteOutcome(unit.crateName, "unreported: no daemon: " & err.msg)
      return 0
    var session: RunQuotaSession
    var lease: RunQuotaLease
    try:
      session = client.registerSession(WrapperClientName, WrapperClientVersion)
      lease = session.requestSubLeaseWaiting(parent,
        "rustc " & unit.crateName, statsKeyOf(unit),
        milliCpu(SubLeaseCpuMilli), milliCpu(SubLeaseCpuMilli),
        bytes(SubLeaseMemoryBytes),
        maxPolls = SubLeaseWaitPolls)
      lease.markStarting()
    except CatchableError as err:
      # No sub-lease: nothing is held, the compiler runs unreported.
      noteOutcome(unit.crateName, "unreported: no sub-lease: " & err.msg)
      try: session.closeSession() except CatchableError: discard
      client.close()
      return 0
    ran = true
    let switched = clientMeasurements()
    let viaLauncher = measureProfiles in switched or
      measureTreeSampling in switched
    noteOutcome(unit.crateName,
      if viaLauncher: "reported: through the launcher" else: "reported")
    result =
      if viaLauncher: launcherRun(command, lease, unit.crateName)
      else: forkAndWait(command, lease, unit.crateName)
    try: session.closeSession() except CatchableError: discard
    client.close()

proc runRecordMode(args: seq[string]): int =
  ## Record mode (see `record_mode`): the stub, a recorded unit, or a probe
  ## passed through. It never reaches the reporting path below.
  try:
    discard recordDir()
  except RecordModeError as err:
    stderr.writeLine WrapperClientName & ": record mode: " & err.msg
    return 1
  if isStubImage([getAppFilename(), paramStr(0)]):
    return runRecordStub(@[paramStr(0)] & args)
  if args.len == 0:
    stderr.writeLine WrapperClientName & ": record mode: no rustc command"
    return 1
  var expanded: seq[string]
  try:
    expanded = expandArgFiles(args[1 .. ^1])
  except RecordModeError as err:
    stderr.writeLine WrapperClientName & ": record mode: " & err.msg
    return 1
  case recordLineKind(expanded)
  of rlUnit:
    var crate = ""
    for i, arg in expanded:
      if arg == "--crate-name" and i + 1 < expanded.len: crate = expanded[i + 1]
      elif arg.startsWith("--crate-name="): crate = arg["--crate-name=".len .. ^1]
    noteOutcome(crate, "recorded")
    recordUnit(@[args[0]] & expanded, getAppFilename())
  of rlProbe:
    # It compiles nothing, and cargo needs its answer. The line runs as
    # cargo gave it (unexpanded), behind the project's own wrapper if any.
    executeInPlace(realCommand(args, getEnv(InnerWrapperEnv)))

proc runWrapper*(args: seq[string]): int =
  ## `args` are cargo's: the rustc path and its arguments. Returns the exit
  ## code to end with; it does not return when the compiler is exec'd in place.
  ##
  ## In record mode (`record_mode.RecordDirEnv` set) this image is also the
  ## build-script stub, which cargo runs under a build script's name, and a
  ## compile unit is recorded instead of compiled. Record mode returns before
  ## the reporting path: it never connects to RunQuota, takes no sub-lease
  ## and starts no measurement, whatever `RUNQUOTA_MEASUREMENT` says, because
  ## there is no compile to measure.
  if args.len > 0 and args[0] == PlanRunFlag and not recordModeOn():
    # The record-only graph-production edge's process (`plan_run`). Cargo
    # runs the wrapper with a rustc path first, never with this flag; inside
    # a record run (the switch set) the flag is not honoured, so a unit can
    # never start a nested record run.
    return runPlanCommand(args[1 .. ^1])
  if recordModeOn():
    when defined(windows):
      stderr.writeLine WrapperClientName & ": record mode is not supported " &
        "on Windows: drive-letter paths are not yet rewritten against the " &
        "logical roots"
      return 1
    else:
      return runRecordMode(args)
  if args.len == 0:
    stderr.writeLine "usage: " & WrapperClientName & " <rustc> [rustc args...]"
    return 2
  let command = realCommand(args, getEnv(InnerWrapperEnv))
  when defined(posix):
    let parsed = rustcUnitOf(args[1 .. ^1])
    let parent = parentLeaseFromEnvironment()
    if parsed.isUnit and parent.isSome:
      var ran = false
      let code = reportedRun(command, parsed.unit, parent.get(), ran)
      if ran:
        return code
  executeInPlace(command)
