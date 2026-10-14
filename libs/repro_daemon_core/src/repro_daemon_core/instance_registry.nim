## Shared-Development-Services L7 (spec §4.5) — the DAEMON-HOSTED half of
## the instance registry: the one registry object the daemon owns, the
## real process-liveness probe, materialisation, and the two request
## handler bodies.
##
## § WHY THIS IS A SEPARATE MODULE FROM `repro_resources/service_registry`
##
## The same reason `lease_registry.nim` is separate from
## `repro_resources/lease`: the POLICY is a pure function of its
## arguments and belongs in the resource lane, and the daemon module is
## where that policy meets a process table, a socket and a log. Two
## things specifically cannot live in `repro_resources`:
##
##   * the liveness probe. `writerLiveness` lives in THIS library, and
##     this library depends on `repro_resources`, so the dependency can
##     only run this way. `ServiceInstanceRegistry.probe` is the
##     injection point and `serviceInstanceLivenessProbe` below is the
##     real function wrapped for it. Nothing is mocked: the probe the
##     daemon installs and the probe the tests install are the same
##     `writerLiveness`.
##   * starting and stopping a process. §4.5 makes `up` "converge, not
##     start", and the thing that converges has to be able to start the
##     instance when it is absent. That is a daemon capability, and
##     `repro_resources` deliberately has none.
##
## § WHY THE DAEMON SPAWNS, RATHER THAN THE CLIENT
##
## Both were tried on paper and only one is race-free. If `repro up`
## materialised the instance itself it would need two round trips —
## "is there one?" then "here is the one I started" — and two `repro up`
## runs that both observed "no instance" would both start one. The
## daemon decides and materialises inside ONE request, so the decision
## and the registration cannot be separated by another client's.
##
## The spawned process is DETACHED (`poDaemon`), which is what makes the
## gate's daemon-restart clause meaningful: the instance outlives the
## daemon that started it, is found again by the rebuild, and is neither
## orphaned nor double-started. It also means the daemon holds no
## `Process` handle for it after a restart, so stopping it is a SIGNAL to
## the recorded pid rather than `Process.terminate` — see
## `stopServiceInstanceProcess`.
##
## § `uncontrolledStartProcess`, AND WHY IT IS THE RIGHT CALL HERE
##
## The ambient-execution linter asks for a typed execution profile or an
## explicit `uncontrolledStartProcess`. A shared development service's
## argv is author-declared in a recipe and reaches here as data; there is
## no execution profile for it, and inventing one would be inventing a
## surface L7's gate does not ask for. This is the same shape the
## dev-session supervisor already has for a declared service
## (`dev_session.nim`'s `startService`), and the explicit spelling is the
## point: the call site says that the binary is not one reprobuild
## provisioned.
##
## § TEST-DOUBLE POLICY
##
## Nothing here is mocked and nothing may be. The registry is the real
## one over a real `StateStore`; the probe is the real `writerLiveness`;
## the materialised instance is a real detached child process; the stop
## is a real signal.

import std/[options, os, osproc, strutils, tables, times]

import repro_core
import repro_core/ambient_execution # uncontrolledStartProcess
import repro_resources # StateStore / lease policy
import repro_resources/service_registry
import repro_resources/service_identity

import ./lease_registry # policyFromTtlSeconds / scope root
import ./protocol
import ./writer_identity

export service_registry

when defined(posix):
  # Imported SELECTIVELY. A bare `import std/posix` brings in a second
  # `Time` and makes every `times.Time` in this module ambiguous.
  from std/posix import kill, waitpid, Pid, SIGTERM, SIGKILL, WNOHANG,
    ECHILD, errno, strerror

const
  ServiceInstanceStopGraceMs* = 3000
    ## How long `stopServiceInstanceProcess` waits after SIGTERM before
    ## escalating. The same grace `dev_session.nim` gives a declared
    ## service (`DevSessionServiceStopGraceMs`), and deliberately the
    ## same number: a service does not become more or less patient
    ## because the thing stopping it is the daemon.

proc reapIfOurOwnChild(pid: int): ServiceInstanceLiveness =
  ## `waitpid(pid, WNOHANG)`, interpreted:
  ##
  ##   * `pid`  — it had exited and this call just reaped it: DEAD.
  ##   * `0`    — it is our child and has not exited: LIVE.
  ##   * `-1` with `ECHILD` — not our child at all (the usual case after
  ##     a daemon restart): UNKNOWN here, and the caller falls through to
  ##     `writerLiveness`, which answers exactly.
  ##
  ## WHY THIS EXISTS, AND IT IS NOT AN OPTIMISATION. `poDaemon` puts the
  ## materialised instance in its own SESSION but does not reparent it:
  ## it stays a child of the daemon. A child that has exited and has not
  ## been waited on is a ZOMBIE, and a zombie still has a
  ## `/proc/<pid>/stat` with its original start time — so
  ## `writerLiveness` correctly answers `wlLive` for it, because the
  ## question it answers is "is that pid still the same process", and it
  ## is. Measured while writing L7's registry suite: a stopped instance
  ## read as live through two signals and a grace period, because nothing
  ## had reaped it.
  ##
  ## So the registry asks a slightly different question first — "is this
  ## process still RUNNING" — and reaping is how a parent asks it. The
  ## side effect is the one the daemon owes its children anyway: without
  ## it, every service instance the daemon ever started accumulates as a
  ## zombie until the daemon exits.
  when defined(posix):
    if pid <= 0:
      return silUnknown
    var status: cint = 0
    let waited = waitpid(Pid(pid), status, WNOHANG)
    if waited == Pid(pid):
      silDead
    elif waited == Pid(0):
      silLive
    else:
      silUnknown
  else:
    silUnknown

proc serviceInstanceLivenessProbe*(): ServiceInstanceLivenessProbe =
  ## The REAL probe, wrapped for injection. `writerLiveness`'s three
  ## answers map one-to-one onto `ServiceInstanceLiveness`, including the
  ## asymmetry: `wlUnknown` becomes `silUnknown`, which the registry
  ## treats as live.
  ##
  ## An empty `processIdentity` is `silUnknown` and NOT `silDead`. A
  ## record written by a path that did not establish an identity must not
  ## cause its instance to be dropped; dropping it is how a live process
  ## becomes an orphan and the next `repro up` starts a second one.
  ##
  ## BOTH SOURCES ARE ASKED, AND THE IDENTITY IS VALIDATED FIRST.
  ## `writerLiveness` is the one source that can tell a RECYCLED pid from
  ## the original — it compares the boot id and the process start time —
  ## and `reapIfOurOwnChild` is the one source that can tell a ZOMBIE
  ## from a running process. Neither answers the other's question, so the
  ## order is the whole design, and it is `writerLiveness` first:
  ##
  ##   * `wlDead` — the recorded process is provably not there, either
  ##     because the pid is gone or because the pid now belongs to a
  ##     DIFFERENT process. Answer `silDead` and ask `waitpid` nothing.
  ##   * `wlUnknown` — no identity was established. `silUnknown`, i.e.
  ##     treated as live.
  ##   * `wlLive` — same boot, same pid, same start stamp: the recorded
  ##     process really is this pid. ONLY NOW is `waitpid` meaningful,
  ##     and it is the only thing that can say the confirmed process has
  ##     exited and is lingering as a zombie.
  ##
  ## WHY THE ORDER IS NOT INTERCHANGEABLE, measured rather than reasoned:
  ## `waitpid(pid, WNOHANG)` answers about a PID, not about an identity.
  ## A pid recycled onto a DIFFERENT, still-running child of this same
  ## daemon — a second service instance, or a provider session — answers
  ## `0`, which the old order returned as `silLive` for the OLD record,
  ## and `writerLiveness` was then never consulted. The registry would
  ## have kept a dead instance's record alive on the strength of an
  ## unrelated child, and the next `repro up` would have attached a
  ## consumer to a handle on nothing.
  ##
  ## It also removes a side effect that was never ours to have. `waitpid`
  ## REAPS, so asking it about a recycled pid would have consumed the
  ## exit status of that other child — stealing a wait the code that
  ## started it is entitled to. Validating the identity first means
  ## `waitpid` is only ever asked about the process the record actually
  ## names.
  ##
  ## The zombie case is unaffected, which is the point of keeping both: a
  ## zombie keeps its `/proc/<pid>/stat` and its original start time, so
  ## `writerLiveness` answers `wlLive` for it and the `waitpid` below
  ## then reaps it and answers `silDead`.
  result = proc (processIdentity: string): ServiceInstanceLiveness =
    if processIdentity.strip().len == 0:
      return silUnknown
    case writerLiveness(processIdentity)
    of wlDead: silDead
    of wlUnknown: silUnknown
    of wlLive:
      let decoded = decodeWriterIdentity(processIdentity)
      if decoded.isSome:
        let reaped = reapIfOurOwnChild(decoded.get.pid)
        if reaped != silUnknown:
          return reaped
      silLive

proc serviceInstanceStoreRoot*(scope: DaemonLeaseScope;
                               overrideRoot = ""): string =
  ## The registry's store root. The SAME root the lease registry and the
  ## reaper tick use, because §4.5's rebuild source IS the lease records:
  ## two roots would mean the reaper swept a store the registry did not
  ## read. It is literally `leaseStoreRootForScope`, called rather than
  ## re-derived.
  ##
  ## IT TAKES A SCOPE AND AN OVERRIDE RATHER THAN A `UserDaemonConfig`,
  ## for the reason `lease_registry.nim`'s own handler bodies do:
  ## `UserDaemonConfig` is declared in `runtime.nim`, which imports this
  ## module, so naming the type here would be a module cycle. The two
  ## fields `runtime.nim` passes are exactly the two
  ## `daemonLeaseScope` / `config.leaseStoreRoot` already give the lease
  ## handler.
  leaseStoreRootForScope(scope, overrideRoot)

proc openDaemonServiceInstanceRegistry*(scope: DaemonLeaseScope;
                                        overrideRoot = ""):
    tuple[registry: ServiceInstanceRegistry;
          report: ServiceRegistryRebuildReport] =
  ## Open and rebuild the registry this daemon serves.
  openServiceInstanceRegistryReporting(
    serviceInstanceStoreRoot(scope, overrideRoot),
    serviceInstanceLivenessProbe())

proc describeRebuild*(report: ServiceRegistryRebuildReport): string =
  ## One line for the daemon log. Written as a proc so the log line and a
  ## test's assertion read the same numbers.
  "service instance registry rebuilt: recovered=" & $report.recovered &
  " droppedDead=" & $report.droppedDead &
  " skipped=" & $report.skipped &
  " unnamedKeepHolderRisks=" & $report.unnamedKeepHolderRisks

# ---------------------------------------------------------------------------
# Materialise / stop.
# ---------------------------------------------------------------------------

type
  ServiceInstanceStart* = object
    ## What `materialiseServiceInstanceProcess` observed. §4.5:
    ## materialisation is VERIFIED, not declared, so the answer is not
    ## just "here is a pid" but "here is a pid that was still running at
    ## the end of the grace window" — or "it died, and this is why".
    process*: ServiceInstanceProcess
      ## The instance to register. When `exitedEarly` is true its `pid`
      ## is 0 and its `processIdentity` empty, deliberately: there is
      ## nothing to register, and a caller that registered it anyway
      ## would record a process nothing can find rather than a dead pid
      ## a later probe might confuse with a recycled one.
    exitedEarly*: bool
      ## The child exited inside the grace window.
    exitedPid*: int
      ## The pid the child had, for the diagnostic only. 0 when it is
      ## still running (the pid is then `process.pid`).
    exitCode*: int
      ## Shell-style exit status (`128 + signal` for a signal death), as
      ## `osproc.peekExitCode` reports it. Meaningful only when
      ## `exitedEarly`.
    outputPath*: string
      ## The file the child's stdout and stderr were written to.
    graceMs*: int
      ## The grace window that was applied, for the diagnostic.

const
  ServiceInstanceStartGraceMs* = 500
    ## §4.5: how long a freshly spawned instance is OBSERVED before the
    ## daemon answers `ok: true`. The question it answers is only "did it
    ## die immediately" — a missing interpreter, a bad flag, a port
    ## already bound, an instant crash all exit within a few tens of
    ## milliseconds — and NOT "is it ready", which is §7.1's readiness
    ## concern and deliberately not re-implemented here. Short, because
    ## a healthy instance pays the whole window on every materialise
    ## (only a dying one ends it early); long enough that a loaded host
    ## still sees a `sh` that fails at once. Overridable per call
    ## (`startGraceMs` / `graceMs`) so a test can pass its own.

  ServiceInstanceOutputTailLines* = 20
    ## How many trailing lines of the output log an early-exit diagnostic
    ## quotes.
  ServiceInstanceOutputTailBytes* = 4096
    ## ...and the byte cap on the same quote, so a child that printed one
    ## enormous line cannot turn a `repro up` refusal into megabytes.

  ServiceInstanceStartPollMs = 25
    ## The poll interval inside the grace window. Small, because a dying
    ## child ends the window as soon as it is SEEN to have exited.

  ServiceInstanceLauncherName = "reprobuild-service-launcher"
    ## The launcher shell's `$0`. It is the name the shell prefixes its
    ## own error messages with ("<name>: line 1: <cmd>: not found"), so it
    ## is a name that says what failed rather than the log path, which
    ## would read as if the LOG had been the missing file.

  ServiceInstanceExecScript =
    "exec </dev/null >>\"$1\" 2>&1; shift; exec \"$@\""
    ## The POSIX launcher, run as
    ## `/bin/sh -c <this> <launcherName> <logPath> <argv...>`.
    ##
    ## WHY A SHELL, AND WHY IT IS SOUND. `std/osproc.startProcess` can
    ## only give the child pipes or the daemon's own streams — it cannot
    ## open a FILE for it — and the daemon's streams are a socket and a
    ## log nobody reads. The first `exec` (no command) makes the three
    ## redirections permanent for the shell: stdin from `/dev/null` (not
    ## a closed pipe, which a service reading stdin would see as an
    ## error or EOF race), stdout appended to the log, stderr to the
    ## same place. The second `exec` REPLACES the shell with the service
    ## — same pid, same start time — so the pid the daemon records, the
    ## `processIdentity` built from it, and the pid `stop` signals are
    ## all the service itself, never a wrapper. A command that cannot be
    ## run makes the shell print its own "not found" to the LOG and exit
    ## 127, which is exactly the diagnostic §4.5 wants surfaced.
    ##
    ## NOTHING IS INTERPOLATED. The log path is `$1` and the argv is
    ## `"$@"` after a `shift`: both arrive as positional parameters, so no path or
    ## argument is ever parsed as shell syntax, whatever it contains.
    ##
    ## `posix_spawn` with file actions plus `POSIX_SPAWN_SETSID` was the
    ## alternative. It would avoid the shell, but it means binding the
    ## file-action API by hand, re-implementing `osproc`'s PATH lookup
    ## and error reporting, and losing `osproc.Process` — whose
    ## `peekExitCode` is what the grace window below relies on. The
    ## shell is the same `/bin/sh` `osproc` itself uses for
    ## `poEvalCommand`, and costs one `exec`.

proc readServiceInstanceOutputTail*(path: string;
    maxLines = ServiceInstanceOutputTailLines;
    maxBytes = ServiceInstanceOutputTailBytes): string =
  ## The last `maxLines` lines of `path`, capped at `maxBytes`. Never
  ## raises: this feeds a diagnostic, and a diagnostic that failed
  ## because the log could not be read would hide the failure it was
  ## written to explain. An unreadable log says so in its place.
  var text = ""
  try:
    var f: File
    if not open(f, path, fmRead):
      return "<the output log could not be opened>"
    defer: f.close()
    let size = f.getFileSize()
    let start = max(0'i64, size - int64(maxBytes))
    f.setFilePos(start)
    text = f.readAll()
    if start > 0:
      # The first line is probably cut mid-way; drop it rather than quote
      # half a sentence as if it were the start of one.
      let nl = text.find('\n')
      if nl >= 0 and nl + 1 < text.len:
        text = text[nl + 1 .. ^1]
  except CatchableError as err:
    return "<the output log could not be read: " & err.msg & ">"
  var lines = text.strip(leading = false, trailing = true).splitLines()
  if lines.len > maxLines:
    lines = lines[lines.len - maxLines .. ^1]
  lines.join("\n")

proc quoteCommandForDiagnostic(command: seq[string]): string =
  ## The argv as a reader can paste it, for diagnostics only. Never fed
  ## to a shell: the launcher passes argv positionally.
  var parts: seq[string] = @[]
  for part in command:
    parts.add(quoteShell(part))
  parts.join(" ")

proc describeEarlyServiceInstanceExit*(start: ServiceInstanceStart;
                                       address: string): string =
  ## §4.5's early-exit diagnostic: the address, the command, the exit
  ## status, the log path and the log's tail — enough that the failure is
  ## diagnosable from `repro up`'s output alone, without opening a file.
  let tail = readServiceInstanceOutputTail(start.outputPath)
  "the instance at `" & address & "` exited within its " &
    $start.graceMs & " ms start grace window with exit status " &
    $start.exitCode & " (pid " & $start.exitedPid & ", command: " &
    quoteCommandForDiagnostic(start.process.command) &
    "), so it was NOT registered and nothing is running there. " &
    # Exit status 0 is the signature of a command that daemonises itself
    # (forks into the background and lets the parent return), which the
    # daemon cannot track: the pid it would record is the parent that
    # just exited. Said explicitly, because "exit status 0" otherwise
    # reads as a success the daemon wrongly refused.
    (if start.exitCode == 0:
       "A command that forks into the background and exits cannot be " &
       "tracked; run the service in the foreground. "
     else: "") &
    "Its output is in " & start.outputPath &
    (if tail.strip().len > 0:
       "; last lines:\n" & tail
     else:
       "; it wrote nothing.")

proc writeOutputLogHeader(outputPath: string; command: seq[string];
                          workingDir: string) =
  ## Create the log's directory and START THE FILE AFRESH with one header
  ## line.
  ##
  ## TRUNCATE, NOT APPEND, and the header says when. The file is per
  ## instance ADDRESS, so a previous incarnation's output is from a
  ## process that has already been stopped (the takeover path stops it
  ## before materialising) or has died. Appending would let the early-exit
  ## diagnostic quote the OLD process's last lines when the new one wrote
  ## nothing — a confidently wrong explanation — and would grow without
  ## bound across restarts. The shell then APPENDS (`>>`) below this
  ## header, so the header is kept.
  ##
  ## Written by the daemon BEFORE the spawn, so an unwritable state root
  ## is a clear `IOError` here rather than a shell that fails to open its
  ## redirection and exits with an obscure status.
  createDir(parentDir(outputPath))
  writeFile(outputPath,
    "# reprobuild: materialising service instance at " &
    $now().utc & " in " & workingDir & ": " &
    quoteCommandForDiagnostic(command) & "\n")

proc materialiseServiceInstanceProcess*(command: seq[string];
    workingDir: string;
    outputPath: string;
    graceMs = ServiceInstanceStartGraceMs): ServiceInstanceStart =
  ## Start the instance, detached, with its output going to `outputPath`
  ## (normally `serviceInstanceOutputLogPath(storeRoot, key)`), capture
  ## the identity that recognises it again after this daemon is gone,
  ## and OBSERVE it for `graceMs` before reporting it started.
  ##
  ## `poDaemon` is what detaches it. Without it the child dies with the
  ## daemon, and the gate's "a daemon restart recovering the registry"
  ## clause would be measuring a registry whose every instance had just
  ## been killed.
  ##
  ## An early exit is RETURNED (`exitedEarly`), not raised: it is an
  ## expected outcome with structured facts the caller needs (the exit
  ## status, the log path), not a failure of this function. A failure to
  ## spawn at all — an unwritable log, `/bin/sh` absent — still raises.
  if command.len == 0:
    raise newException(ServiceRegistryError,
      "a service instance cannot be materialised from an empty command")
  if outputPath.len == 0:
    raise newException(ServiceRegistryError,
      "a service instance needs an output log path; see " &
      "`serviceInstanceOutputLogPath`")
  when defined(posix):
    if command[0].startsWith("-"):
      # `exec -x` would be read by some `/bin/sh`s as an option to
      # `exec` itself rather than as the program to run.
      raise newException(ServiceRegistryError,
        "a service instance command cannot begin with `-`: " &
        quoteCommandForDiagnostic(command))
  writeOutputLogHeader(outputPath, command, workingDir)
  result = ServiceInstanceStart(outputPath: outputPath, graceMs: graceMs,
    exitCode: -1)
  when defined(posix):
    # The pipes `startProcess` still creates for stdio are replaced by
    # the launcher's redirections before the service runs, so nothing
    # the service writes reaches them; closing our ends below is safe.
    #
    # `poStdErrToStdOut` is deliberately NOT passed here: the launcher
    # merges the two streams into the log itself, and with that option
    # `osproc`'s POSIX `close` closes the shared stdout/stderr descriptor
    # TWICE — the second time on a number another thread may already
    # have reused (reprobuild-pm issue
    # `2026-10-09-osproc-close-double-close-in-threaded-reprobuild-code`).
    var process = uncontrolledStartProcess("/bin/sh",
      workingDir = workingDir,
      args = @["-c", ServiceInstanceExecScript, ServiceInstanceLauncherName,
        outputPath] & command,
      options = {poDaemon})
  else:
    # NAMED LIMITATION, not silent: outside POSIX there is no `/bin/sh`
    # launcher, `startProcess` cannot redirect to a file, and the
    # output still goes to a pipe that is closed below. The grace-window
    # liveness check DOES apply. The log says so, so an operator who
    # opens it is not left wondering why it is empty.
    try:
      let f = open(outputPath, fmAppend)
      defer: f.close()
      f.writeLine("# reprobuild: capturing a service instance's output " &
        "is not implemented on this platform; this file receives nothing " &
        "further.")
    except CatchableError:
      discard
    var process = uncontrolledStartProcess(command[0],
      workingDir = workingDir,
      args = (if command.len > 1: command[1 .. ^1] else: @[]),
      options = {poUsePath, poDaemon, poStdErrToStdOut})
  let pid = process.processID
  # The identity is taken IMMEDIATELY, while the pid is certainly ours:
  # until it is reaped, it cannot be recycled onto another process.
  let identity = encodeWriterIdentity(WriterIdentity(
    bootId: currentWriterIdentity().bootId,
    pid: pid,
    startStamp: processStartStamp(pid)))
  try:
    # §4.5's GRACE WINDOW. Polled through the `Process` handle rather
    # than through `writerLiveness`, because while we still hold the
    # handle the parent can ask `waitpid` directly — which also yields
    # the exit STATUS the diagnostic must name, and reaps the child so a
    # dead one is not left behind as a zombie.
    var waited = 0
    while true:
      let code = process.peekExitCode()
      if code != -1:
        result.exitedEarly = true
        result.exitCode = code
        break
      if waited >= graceMs:
        break
      let step = min(ServiceInstanceStartPollMs, graceMs - waited)
      sleep(step)
      waited.inc(step)
  finally:
    # The handle is still closed, and deliberately — for the reason it
    # always was. A detached child that is still running is not this
    # process's to wait on, and holding the handle would make the
    # daemon's own exit path try. Later liveness questions go through the
    # recorded `processIdentity` (and `reapIfOurOwnChild`), which work
    # equally for a daemon that never held a handle.
    process.close()
  if result.exitedEarly:
    result.exitedPid = pid
    result.process = ServiceInstanceProcess(pid: 0, processIdentity: "",
      command: command, workingDir: workingDir, outputLog: outputPath)
  else:
    result.process = ServiceInstanceProcess(
      pid: pid,
      processIdentity: identity,
      command: command,
      workingDir: workingDir,
      outputLog: outputPath)

proc stopServiceInstanceProcess*(process: ServiceInstanceProcess;
                                 graceMs = ServiceInstanceStopGraceMs):
    tuple[stopped: bool; detail: string] =
  ## SIGTERM, wait up to `graceMs`, then SIGKILL. A signal rather than
  ## `Process.terminate` because the daemon that stops an instance is
  ## usually not the daemon that started it — see this module's header.
  ##
  ## The liveness check between the two signals is the SAME
  ## `writerLiveness` triple the registry uses, so a recycled pid is
  ## never signalled: if the recorded process is already gone, this
  ## reports stopped and sends nothing further.
  if process.pid <= 0:
    return (stopped: false,
      detail: "the record carries no pid, so nothing could be signalled")
  let probe = serviceInstanceLivenessProbe()
  if probe(process.processIdentity) == silDead:
    return (stopped: true,
      detail: "pid " & $process.pid & " was already gone")
  when defined(posix):
    if kill(Pid(process.pid), SIGTERM) != 0'i32:
      return (stopped: false,
        detail: "SIGTERM to pid " & $process.pid & " failed: " &
          $strerror(errno))
    var waited = 0
    while waited < graceMs:
      if probe(process.processIdentity) == silDead:
        return (stopped: true,
          detail: "pid " & $process.pid & " exited on SIGTERM after " &
            $waited & " ms")
      sleep(50)
      waited.inc(50)
    discard kill(Pid(process.pid), SIGKILL)
    waited = 0
    while waited < graceMs:
      if probe(process.processIdentity) == silDead:
        return (stopped: true,
          detail: "pid " & $process.pid & " exited on SIGKILL after " &
            $graceMs & " ms of SIGTERM grace")
      sleep(50)
      waited.inc(50)
    (stopped: false,
      detail: "pid " & $process.pid & " survived SIGTERM and SIGKILL")
  else:
    # NAMED, not silent. A Windows daemon can recover the registry and
    # can refuse a `--replace`, but it cannot stop a recovered instance
    # whose `Process` handle died with the previous daemon. Returning
    # `stopped = false` with this sentence keeps the record in place, so
    # the instance is not forgotten while still running.
    (stopped: false,
      detail: "stopping a detached service instance by pid is not " &
        "implemented on this platform; pid " & $process.pid &
        " is still running and its record is kept")

# ---------------------------------------------------------------------------
# §4.5's "an instance is reaped when its last lease lapses" — THE DAEMON'S
# HALF OF IT.
#
# `repro_resources/service_registry` registers a DECLINING reap handler for
# `ServiceInstanceTypeId` at module init, because that library cannot stop a
# process. This is the one that can. It is installed around the daemon's
# wall-clock reap tick and restores the declining handler afterwards, so a
# sweep run by anything else in this process still declines by name instead
# of silently removing a record whose process is still running.
#
# ## WHY IT IS INSTALLED AROUND THE TICK RATHER THAN AT MODULE INIT
#
# Because the handler has to reach the DAEMON'S registry object, and that
# object is a local in `runUserDaemonForeground`. A module-init handler
# could stop the process and let the sweep remove the record, and the
# daemon's in-memory `entries` table would still hold the address — so the
# next `repro up` for that key would find the entry, take L6's attach path
# and hand a consumer a handle on a process that had just been killed.
# §4.5's registry is authoritative in memory, so the in-memory half has to
# be dropped in the same operation. A pointer to the live registry is how
# that happens without `repro_resources` learning what a daemon is.
#
# The pointer is only ever dereferenced inside the installed handler, and
# the handler is uninstalled before the frame holding the registry can go
# away — `installServiceInstanceReapHandler` is paired with
# `uninstallServiceInstanceReapHandler` on every path, including the
# error path, by the one caller (`runScopedLeaseReapTick`).
# ---------------------------------------------------------------------------

proc serviceInstanceReapHandler*(registry: ptr ServiceInstanceRegistry):
    ReapHandler =
  ## The real handler: stop the recorded process, then drop the in-memory
  ## entry. Returning `destroyed = true` is what lets the sweep remove
  ## the record, so a stop that FAILED keeps the record — the same rule
  ## `applyServiceRelease` follows, and for the same reason: a key with
  ## no record and a process still running is the orphan the rebuild
  ## cannot see.
  result = proc (rec: ResourceStateRecord): ReapHandlerOutcome =
    let record =
      try:
        decodeServiceInstanceAttrs(rec.address, rec.attrsTypeId,
          rec.attrsJson)
      except CatchableError as err:
        # The same policy `rebuildServiceInstanceRegistry` applies to an
        # undecodable record (`srrSkippedUndecodable`): REPORT it and
        # leave it alone. Removing a record this build cannot read would
        # discard an instance a future build can.
        return ReapHandlerOutcome(destroyed: false, wasPresent: true,
          detail: "the instance record could not be decoded, so the " &
            "process it names could not be identified and nothing was " &
            "stopped: " & err.msg)
    let probe = serviceInstanceLivenessProbe()
    let wasRunning = probe(record.process.processIdentity) != silDead
    let stop = stopServiceInstanceProcess(record.process)
    if not stop.stopped:
      return ReapHandlerOutcome(destroyed: false, wasPresent: wasRunning,
        detail: "the instance's last lease has lapsed and its process " &
          "could not be stopped: " & stop.detail &
          ". Its record is KEPT, so it is still registered and still " &
          "attachable rather than becoming a process nothing names.")
    if registry != nil:
      # The IN-MEMORY half. The sweep removes the record from the store
      # it is sweeping; this drops the entry so the daemon stops
      # answering `repro up` with an instance it has just killed.
      registry[].forgetServiceInstanceEntry(rec.address)
    ReapHandlerOutcome(destroyed: true, wasPresent: wasRunning,
      detail: stop.detail)

proc installServiceInstanceReapHandler*(
    registry: ptr ServiceInstanceRegistry) =
  ## Install the real handler for the duration of one sweep.
  registerReapHandler(ServiceInstanceTypeId,
    serviceInstanceReapHandler(registry))

proc uninstallServiceInstanceReapHandler*() =
  ## Put the DECLINING handler back — not `unregisterReapHandler`. With
  ## no handler at all the generic path would reconstruct an instance
  ## record and raise about a missing attrs marshaller, which is the
  ## condition `service_registry`'s declining handler exists to replace
  ## with a true sentence.
  installDecliningServiceInstanceReapHandler()

# ---------------------------------------------------------------------------
# The two handler bodies.
# ---------------------------------------------------------------------------

proc startForConverge(registry: ServiceInstanceRegistry;
                       key: ServiceInstanceKey;
                       request: DaemonServiceConvergeRequest;
                       startGraceMs: int):
    tuple[start: ServiceInstanceStart; failure: string] =
  ## The materialisation BOTH converge paths share — the plain
  ## `scoMaterialise` and the `--replace` takeover's replacement — so the
  ## two cannot drift into verifying differently. `failure` is empty only
  ## when the instance was started AND was still running at the end of
  ## the grace window; otherwise it is the sentence to answer with, and
  ## the caller must not register anything.
  try:
    let outputPath = serviceInstanceOutputLogPath(registry.storeRoot, key)
    result.start = materialiseServiceInstanceProcess(request.command,
      (if request.workingDir.len > 0: request.workingDir
       else: getCurrentDir()),
      outputPath, startGraceMs)
  except CatchableError as err:
    result.failure = "the instance at `" & serviceInstanceAddress(key) &
      "` could not be started: " & err.msg
    return
  if result.start.exitedEarly:
    result.failure = describeEarlyServiceInstanceExit(result.start,
      serviceInstanceAddress(key))

proc materialisedNotice(address: string; process: ServiceInstanceProcess):
    string =
  ## The success diagnostic: where the instance's output goes, so the log
  ## is discoverable from `repro up`'s output as well as from the record.
  "materialised `" & address & "` as pid " & $process.pid &
    "; its stdout and stderr are written to " & process.outputLog

proc applyServiceConverge*(registry: var ServiceInstanceRegistry;
                           request: DaemonServiceConvergeRequest;
                           now: Time = getTime();
                           startGraceMs = ServiceInstanceStartGraceMs):
    DaemonServiceConvergeResponse =
  ## The `udkServiceConverge` handler body: resolve the key, decide, and
  ## — on `scoMaterialise` — start the instance and register it, all
  ## inside this one request.
  ##
  ## §4.5: MATERIALISATION IS VERIFIED, NOT DECLARED. On both materialise
  ## paths the spawned child is observed for `startGraceMs`; one that
  ## exits inside it is answered `ok: false` with the early-exit
  ## diagnostic and is NOT registered — no in-memory entry, no store
  ## record, no pid — so the next converge decides `Materialise` again
  ## instead of attaching a consumer to a process that is not there.
  let key =
    try:
      decodeServiceInstanceKey(request.keyJson)
    except CatchableError as err:
      return DaemonServiceConvergeResponse(ok: false,
        outcome: outcomeWord(scoRefuseUnknownHolders),
        diagnostic: "the converge request's instance key could not be " &
          "decoded, so no instance was resolved and nothing was " &
          "started: " & err.msg)
  let snapshot =
    try:
      decodeServiceInterfaceSnapshot(request.snapshotJson)
    except CatchableError as err:
      return DaemonServiceConvergeResponse(ok: false,
        outcome: outcomeWord(scoRefuseUnknownHolders),
        diagnostic: "the converge request's interface snapshot could not " &
          "be decoded, so the attach decision could not be made and " &
          "nothing was started: " & err.msg)
  # §4.3's SAME-GENERATION PRECONDITION, as the CLIENT established it.
  #
  # Decoded rather than defaulted, and the decoder's answer for an empty
  # or unrecognised field is `sagUnknownProvenance` -- a refusal naming
  # the re-lift -- never `sagFresh`. There is deliberately no branch here
  # that substitutes a fresh answer when the field is absent: that
  # substitution is the silent attach §4.3 was written from.
  let generation =
    decodeServiceArtifactGenerationCheck(request.generationJson)
  let decision =
    try:
      convergeServiceInstance(registry, key, snapshot, request.holderId,
        generation, policyFromTtlSeconds(request.ttlSeconds), now,
        replace = request.replace, force = request.force)
    except CatchableError as err:
      return DaemonServiceConvergeResponse(ok: false,
        outcome: outcomeWord(scoRefuseUnknownHolders),
        diagnostic: "the service instance registry refused the request: " &
          err.msg)
  result = DaemonServiceConvergeResponse(ok: true,
    outcome: outcomeWord(decision.outcome),
    diagnostic: decision.diagnostic,
    address: decision.address,
    hadInstance: decision.hadInstance,
    holderSetRecoverable: decision.holderRecovery == hrTotal,
    holders: decision.holdersKnown,
    # Shared-Development-Services D-SS11 (§4.6): what the instance this
    # decision resolved to DECLARES.
    #
    # From the REGISTRY ENTRY's own persisted snapshot when an instance
    # was present, and from the REQUEST's snapshot otherwise. The
    # distinction is the whole of the version-skew case: when the
    # running instance was built from an older definition, the request's
    # snapshot is the newer one and answering with it would make the
    # skew undetectable -- a contribution to a point only the newer
    # definition converges would be accepted and then ignored by the
    # instance, which is the silent drop §4.6 exists to refuse.
    contributionPoints:
      (if decision.hadInstance:
         contributionPointsOf(registry.entries[decision.address]
           .record.snapshot)
       else: contributionPointsOf(snapshot)))
  if decision.outcome == scoMaterialise:
    if request.command.len == 0:
      # Refused rather than registered without a process. An instance
      # entry naming no process would be recovered by every later
      # rebuild as "live, liveness unknown" and never stop.
      return DaemonServiceConvergeResponse(ok: false,
        outcome: outcomeWord(scoMaterialise),
        address: decision.address,
        diagnostic: "no instance is running at `" & decision.address &
          "` and the request carried no command to materialise one with")
    let started = startForConverge(registry, key, request, startGraceMs)
    if started.failure.len > 0:
      return DaemonServiceConvergeResponse(ok: false,
        outcome: outcomeWord(scoMaterialise),
        address: decision.address,
        diagnostic: started.failure)
    let process = started.start.process
    let entry = recordMaterialisedInstance(registry, key, snapshot, process,
      request.holderId, policyFromTtlSeconds(request.ttlSeconds), now)
    result.pid = int32(process.pid)
    result.diagnostic = materialisedNotice(decision.address, process)
    result.holders = @[request.holderId]
    result.holderSetRecoverable = entry.holderRecovery == hrTotal
    return
  if decision.outcome in {scoReplace, scoForcedOverOtherHolders}:
    # The takeover: stop what is running, forget it, then materialise
    # this definition under the same key. Done in this order so a failed
    # stop leaves the OLD record in place rather than a key with no
    # instance and a process nobody names.
    let existing = registry.lookupServiceInstance(key)
    if existing.isSome:
      let stop = stopServiceInstanceProcess(existing.get.record.process)
      if not stop.stopped:
        return DaemonServiceConvergeResponse(ok: false,
          outcome: outcomeWord(decision.outcome),
          address: decision.address,
          hadInstance: true,
          holderSetRecoverable: decision.holderRecovery == hrTotal,
          holders: decision.holdersKnown,
          diagnostic: "the replace decision was " &
            outcomeWord(decision.outcome) &
            " but the running instance could not be stopped: " &
            stop.detail & ". Its record is kept, so it is still " &
            "registered and still attachable.")
      registry.forgetServiceInstance(decision.address)
    if request.command.len == 0:
      return DaemonServiceConvergeResponse(ok: false,
        outcome: outcomeWord(decision.outcome),
        address: decision.address,
        diagnostic: "the instance at `" & decision.address &
          "` was stopped, and the request carried no command to " &
          "materialise its replacement with")
    let started = startForConverge(registry, key, request, startGraceMs)
    if started.failure.len > 0:
      # The old instance is already stopped and forgotten, and the
      # replacement is not running: the key now names NOTHING, and the
      # answer says so rather than reporting a takeover that left no
      # instance behind.
      return DaemonServiceConvergeResponse(ok: false,
        outcome: outcomeWord(decision.outcome),
        address: decision.address,
        diagnostic: "the previous instance was stopped and its " &
          "replacement did not start: " & started.failure)
    let process = started.start.process
    discard recordMaterialisedInstance(registry, key, snapshot, process,
      request.holderId, policyFromTtlSeconds(request.ttlSeconds), now)
    result.pid = int32(process.pid)
    result.holders = @[request.holderId]
    result.diagnostic =
      (if result.diagnostic.len > 0: result.diagnostic & " " else: "") &
      materialisedNotice(decision.address, process)
    return
  if convergeAttached(decision.outcome):
    let entry = registry.lookupServiceInstance(key)
    if entry.isSome:
      result.pid = int32(entry.get.record.process.pid)
      result.holders = @[]
      for holder in entry.get.instance.holders:
        result.holders.add(holder.consumerId)

proc applyServiceRelease*(registry: var ServiceInstanceRegistry;
                          request: DaemonServiceReleaseRequest;
                          now: Time = getTime()):
    DaemonServiceReleaseResponse =
  ## The `udkServiceRelease` handler body: drop this project's holder,
  ## and stop the instance only when it was the last.
  let key =
    try:
      decodeServiceInstanceKey(request.keyJson)
    except CatchableError as err:
      return DaemonServiceReleaseResponse(ok: false,
        outcome: outcomeWord(srlRefuseUnknownHolders),
        diagnostic: "the release request's instance key could not be " &
          "decoded, so no holder was dropped and nothing was stopped: " &
          err.msg)
  let decision =
    try:
      releaseServiceInstance(registry, key, request.holderId, now)
    except CatchableError as err:
      return DaemonServiceReleaseResponse(ok: false,
        outcome: outcomeWord(srlRefuseUnknownHolders),
        diagnostic: "the service instance registry refused the release: " &
          err.msg)
  result = DaemonServiceReleaseResponse(ok: true,
    outcome: outcomeWord(decision.outcome),
    diagnostic: decision.diagnostic,
    address: decision.address,
    holderSetRecoverable: decision.holderRecovery == hrTotal,
    remainingHolders: decision.remainingHolders)
  if decision.outcome != srlReleasedLastHolder:
    return
  let stop = stopServiceInstanceProcess(decision.record.process)
  result.stoppedPid = int32(decision.record.process.pid)
  result.stopDetail = stop.detail
  if not stop.stopped:
    # The record is NOT forgotten. A key with no record and a process
    # still running is the orphan the rebuild cannot see; keeping the
    # record means the next rebuild finds it, and the next `repro up`
    # attaches to it rather than starting a second one.
    result.ok = false
    result.diagnostic =
      "this was the last holder of `" & decision.address &
      "`, and the instance could not be stopped: " & stop.detail &
      ". Its record is KEPT, so it is still registered and still " &
      "attachable rather than becoming a process nothing names."
    return
  registry.forgetServiceInstance(decision.address)
