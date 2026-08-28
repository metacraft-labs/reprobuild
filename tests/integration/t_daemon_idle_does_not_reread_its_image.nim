## Regression cover for an IDLE dev-mode daemon burning a third of a core.
##
## Observed on a `repro-daemon` that had outlived the builds which spawned it
## and was sampled long afterwards with no client attached at all:
##
##   * 194 CPU ticks per 5 s  = 38.8% of one core, sustained
##   * 2_682 `read` syscalls per 5 s = 536/s
##   * 174_282_848 bytes read per 5 s ~= 35 MB/s, sustained
##   * exactly ONE thread, state `S`, `wchan` `do_sys_poll`
##   * exactly FIVE open fds: 2x the log, the lock file, /dev/null, and the
##     LISTENER socket -- no connected client, so no session was streaming
##
## Reproduced under a daemon spawned for the purpose, and pinned with
## `strace -e trace=openat,read,poll`:
##
##   21 x openat("<source image>", O_RDONLY|O_CLOEXEC)  in ~8 s
##   8_849 x read(fd) -- 425 of 65536 bytes + 1 of 61880 + 1 of 0 per open,
##          which is exactly the 27_914_680-byte daemon image
##   18 x poll([{fd=4, POLLIN}], 1, 250) = 0 (Timeout)
##
## The mechanism is `restartCandidateReady`
## (`libs/repro_daemon_core/src/repro_daemon_core/runtime.nim`): the dev
## self-restart poll ran `imageDigestHex(sourceImagePath)` on EVERY pass of
## the accept loop, i.e. at the 250 ms `REPRO_DAEMON_DEV_RESTART_POLL_MS`
## cadence, forever. `fileDigestHex` streams the whole image through a
## 64 KiB buffer, so each pass cost one full re-read of a ~28 MB binary --
## roughly 3 re-reads a second of a file that had not changed since the
## daemon started, purely to re-derive a hash it already had.
##
## The gate below is deliberately NOT a CPU-percentage assertion: those are
## flaky by construction on a shared runner. It asserts on the two things
## the defect produced that legitimate idling cannot -- bytes read and read
## syscalls issued over a fixed idle window -- and it scales the byte budget
## to the size of the image itself, so the invariant reads as what it is:
##
##   an idle daemon must not re-read its own image, not even once.
##
## Pre-fix this window sees ~8 full copies of the image; post-fix it sees
## none. Both numbers are taken from the kernel's own counters in
## `/proc/<pid>/io`, which need no ptrace and cost the daemon nothing.
##
## No mocks: this drives the REAL `repro` binary as a REAL daemon process in
## the REAL dev-restart configuration. The defect lived in the interaction
## between the poll cadence, the digest helper and the filesystem, and any
## stub of those would have hidden it.

import std/[os, osproc, strutils, tempfiles, times, unittest]

import repro_daemon_core
import repro_test_support

const
  IdleWindowSeconds = 3.0
    ## Long enough that the pre-fix loop takes ~8 passes through the image
    ## and short enough to stay cheap. The budgets below are not tuned to
    ## this number; they are "essentially nothing" either way.
  MaxIdleReadSyscalls = 400
    ## Pre-fix: ~536/s, i.e. ~1_600 in this window (and ~3_600 on a host
    ## fast enough to hit the full 250 ms cadence). Post-fix the loop issues
    ## no reads of its own at all; the allowance covers status-file and
    ## lease-store bookkeeping with a wide margin.

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

proc daemonEndpoint(tempRoot: string): string =
  daemonSocketEndpoint(tempRoot.extractFilename)

proc daemonStateDir(tempRoot: string): string =
  tempRoot / "state"

proc daemonLogPath(tempRoot: string): string =
  daemonStateDir(tempRoot) / "logs" / "repro-daemon.log"

proc daemonLog(tempRoot: string): string =
  if fileExists(daemonLogPath(tempRoot)): readFile(daemonLogPath(tempRoot))
  else: "(no daemon log at " & daemonLogPath(tempRoot) & ")"

proc waitForRunning(tempRoot: string; timeoutSeconds: float): bool =
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    if queryUserDaemonStatus(daemonEndpoint(tempRoot)).running:
      return true
    sleep(25)
  false

proc startDevDaemon(tempRoot: string): owned(Process) =
  ## Start the real daemon in the real dev-restart configuration.
  ##
  ## `--source-exe` points at the same image the daemon is running, so
  ## `runningDevImagePath` resolves to it too and the source hash equals the
  ## running hash. That is the STEADY STATE this gate is about: the daemon
  ## has nothing to restart onto and must therefore do no work. Pointing it
  ## anywhere else would make the daemon legitimately restart mid-test.
  createDir(daemonStateDir(tempRoot))
  try: removeFile(daemonEndpoint(tempRoot)) except OSError: discard
  result = startProcess(publicReproBin(),
    args = @["daemon", "serve", "--foreground",
      "--endpoint", daemonEndpoint(tempRoot),
      "--state-dir", daemonStateDir(tempRoot),
      "--log", daemonLogPath(tempRoot),
      "--dev", "--source-exe", publicReproBin()],
    workingDir = repoRoot(),
    options = {poUsePath, poStdErrToStdOut})
  if not waitForRunning(tempRoot, 60.0):
    checkpoint(daemonLog(tempRoot))
    if result.running():
      result.terminate()
      discard result.waitForExit()
    result.close()
    raise newException(IOError,
      "dev daemon under test never became ready at " & daemonEndpoint(tempRoot))

proc closeDaemon(daemon: var owned(Process); tempRoot: string) =
  if not daemon.isNil:
    if daemon.running():
      daemon.terminate()
      discard daemon.waitForExit()
    daemon.close()
  try: removeFile(daemonEndpoint(tempRoot)) except OSError: discard

when defined(linux):
  type IoCounters = object
    readSyscalls: int64
    bytesRead: int64

  proc readIoCounters(pid: int): IoCounters =
    ## The kernel's own per-process counters. `rchar` counts bytes returned
    ## by read-family syscalls whether or not they came from the page cache
    ## -- which matters here, because the defect re-read a hot file and did
    ## almost no block I/O at all (467 KB of `read_bytes` against 2.1 TB of
    ## `rchar` on the daemon originally observed).
    for line in lines("/proc" / $pid / "io"):
      let parts = line.split(": ")
      if parts.len != 2: continue
      case parts[0]
      of "syscr": result.readSyscalls = parseBiggestInt(parts[1])
      of "rchar": result.bytesRead = parseBiggestInt(parts[1])
      else: discard

  proc soleChild(pid: int): int =
    ## `build/bin/repro` may be a wrapper that execs or forks the real
    ## image. Follow a single-child chain so the counters come from the
    ## process that actually runs the accept loop.
    let path = "/proc" / $pid / "task" / $pid / "children"
    if not fileExists(path): return 0
    let kids = readFile(path).splitWhitespace()
    if kids.len == 1: return parseInt(kids[0])
    0

  proc accountingPid(daemon: Process): int =
    result = daemon.processID
    var guard = 0
    while guard < 8:
      let child = soleChild(result)
      if child == 0: break
      result = child
      inc guard

suite "Idle daemon costs approximately nothing":
  test "integration_idle_dev_daemon_does_not_reread_its_own_image":
    when not defined(linux):
      skip()
    else:
      let imageSize = getFileSize(publicReproBin())
      check imageSize > 0

      let tempRoot = createTempDir("repro-daemon-idle", "")
      var daemon: owned(Process)
      defer:
        closeDaemon(daemon, tempRoot)
        removeDir(tempRoot)
      daemon = startDevDaemon(tempRoot)
      let pid = accountingPid(daemon)

      # Let startup settle: the daemon legitimately digests its image ONCE
      # at `initDevRestartState` and writes a status file. The window below
      # measures the steady state, not the boot.
      sleep(600)

      let before = readIoCounters(pid)
      let startedAt = epochTime()
      sleep(int(IdleWindowSeconds * 1000))
      let elapsed = epochTime() - startedAt
      let after = readIoCounters(pid)

      # If the daemon died mid-window the counters are meaningless.
      check daemon.running()
      check queryUserDaemonStatus(daemonEndpoint(tempRoot)).running

      let bytesRead = after.bytesRead - before.bytesRead
      let readSyscalls = after.readSyscalls - before.readSyscalls
      checkpoint("idle window " & $int(elapsed * 1000) & "ms: bytesRead=" &
        $bytesRead & " (" & $(bytesRead div max(imageSize, 1)) &
        " x the " & $imageSize & "-byte image) readSyscalls=" &
        $readSyscalls)

      # THE invariant. Nothing changed on disk, no client connected, and the
      # daemon already knows its own image's digest -- so it has no reason to
      # read even one copy of it. Pre-fix this is ~8 copies.
      if bytesRead >= imageSize:
        checkpoint(daemonLog(tempRoot))
      check bytesRead < imageSize

      # The syscall-count half of the same statement, so a future defect
      # that re-reads something small at high frequency is caught too.
      if readSyscalls > MaxIdleReadSyscalls:
        checkpoint(daemonLog(tempRoot))
      check readSyscalls <= MaxIdleReadSyscalls
