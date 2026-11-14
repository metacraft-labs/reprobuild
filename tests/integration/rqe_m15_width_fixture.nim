## Shared pieces of the sized-action cases: a private `runquotad`
## of a chosen width, a wrapper that logs when each child process starts and
## ends, and the arithmetic that turns the log into a peak concurrency.
##
## NOTHING HERE IS A MOCK. The daemon is the real `runquotad`, started on an
## endpoint the case owns. The logging wrapper stands in front of the real
## `rustc` or C compiler, runs it unchanged and only records when it ran:
## it observes the build tool the way a process monitor would, and asks
## nothing of the tool (it is installed through the tool's own, documented
## wrapper hook).

import std/[algorithm, os, osproc, strutils]

import repro_test_support

type
  PrivateDaemon* = object
    process*: owned(Process)
    socket*: string

  Event = tuple[at: int64, delta: int]

proc pathPresent(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc startPrivateDaemon*(repoRoot: string; cpuMilli: int): PrivateDaemon =
  ## A `runquotad` with a `cpuMilli` budget on a fresh private endpoint,
  ## published to this process (and so to every `repro` it starts) through
  ## `RUNQUOTA_SOCKET`.
  let daemonBin = requireRunQuotaDaemonBin(repoRoot)
  let socketPath = runquotaSocketEndpoint(
    "repro-m15-rq-" & $getCurrentProcessId())
  # The endpoint belongs to the user running the case, whatever account a
  # host's own RunQuota service runs as.
  putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", $cpuMilli,
    "--memory-bytes", "34359738368",
    # A test daemon stays out of the host-wide observation store.
    "--no-write-stats"
  ], options = {poUsePath, poStdErrToStdOut})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 1200:
    if pathPresent(socketPath):
      return PrivateDaemon(process: daemon, socket: socketPath)
    if not daemon.running:
      break
    sleep(25)
  daemon.terminate()
  discard daemon.waitForExit()
  daemon.close()
  raise newException(OSError, "runquotad socket did not appear: " &
    socketPath)

proc stop*(daemon: var PrivateDaemon) =
  ## Ends the daemon this case started (its own process handle, never a
  ## lookup by name).
  daemon.process.terminate()
  discard daemon.process.waitForExit()
  daemon.process.close()
  delEnv("RUNQUOTA_SOCKET")
  delEnv("RUNQUOTA_ENDPOINT_SCOPE")
  if pathPresent(daemon.socket):
    removeFile(daemon.socket)

proc writeLoggingWrapper*(path, logPath, selector: string;
                          realTool: string; holdSeconds = "0.4") =
  ## A POSIX shell wrapper for a compiler. It runs `realTool "$@"` for a
  ## call whose argument line (a space on each side, arguments joined by one
  ## space) contains `selector` (the call that does the work: a crate's
  ## compile for rustc, an object compile for a C compiler) and
  ## records `S <pid> <ns>` before and `E <pid> <ns>` after it. The call is
  ## held for `holdSeconds` first, so that processes the tool starts
  ## together overlap in time and a width above the grant can be seen. Any
  ## other call (a version probe, the link) is handed straight to the tool.
  ##
  ## `realTool` is given as `"$1"` shifted off for a wrapper cargo invokes as
  ## `wrapper rustc args...`, or an absolute path for a compiler named
  ## directly.
  # The action's PATH may carry only the tools it declared, so the wrapper
  # names the two helpers it uses by absolute path.
  let dateBin = quoteShell(findExe("date", followSymlinks = false))
  let sleepBin = quoteShell(findExe("sleep", followSymlinks = false))
  let script = "#!/bin/sh\n" &
    (if realTool == "$1": "real=\"$1\"; shift\n"
     else: "real=" & quoteShell(realTool) & "\n") &
    "case \" $* \" in\n" &
    "  *\"" & selector & "\"*) ;;\n" &
    "  *) exec \"$real\" \"$@\" ;;\n" &
    "esac\n" &
    "echo \"S $$ $(" & dateBin & " +%s%N)\" >> " & quoteShell(logPath) & "\n" &
    sleepBin & " " & holdSeconds & "\n" &
    "\"$real\" \"$@\"\n" &
    "status=$?\n" &
    "echo \"E $$ $(" & dateBin & " +%s%N)\" >> " & quoteShell(logPath) & "\n" &
    "exit $status\n"
  writeFile(path, script)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc peakConcurrency*(logPath: string): tuple[peak, started, ended: int] =
  ## The most children that were running at once, from the wrapper's log.
  ## An end sorts before a start at the same instant, so back-to-back
  ## processes are not counted as overlapping.
  var events: seq[Event]
  if fileExists(logPath):
    for line in readFile(logPath).splitLines:
      let parts = line.splitWhitespace
      if parts.len == 0:
        continue
      # A line that is not `S|E <pid> <ns>` means the wrapper could not run
      # one of its helpers; counting around it would hide that.
      if parts.len != 3 or parts[0] notin ["S", "E"]:
        raise newException(ValueError, "malformed wrapper log line: " & line)
      let at = parseBiggestInt(parts[2])
      if parts[0] == "S":
        events.add((at: int64(at), delta: 1))
        inc result.started
      elif parts[0] == "E":
        events.add((at: int64(at), delta: -1))
        inc result.ended
  events.sort(proc (a, b: Event): int =
    if a.at != b.at: cmp(a.at, b.at) else: cmp(a.delta, b.delta))
  var running = 0
  for event in events:
    running += event.delta
    result.peak = max(result.peak, running)
