## repro_test_runner — Test-Edges-And-Parallel-Runner M3
##
## Minimal protocol-level parallel runner for reprobuild's Nim test
## suite. Consumes the Tier-1 "Standard" binary protocol shipped in
## ``ct_test_unittest_parallel`` (M2):
##
## * ``--list-json``                — JSON catalog of test cases
## * ``--run "<suite>::<test>"``    — execute one named test
## * ``$NIMTEST_RESULT_FILE``       — JSON result document path
## * exit codes 0/1/2               — pass/fail/skip
##
## Mixed mode: binaries that don't speak the protocol (e.g. existing
## ``import std/unittest`` tests that haven't migrated yet) are detected
## at probe time and executed whole; their single exit code becomes the
## edge's pass/fail status.
##
## Concurrency: process-per-test (exec-per-test). N worker tasks pull
## from a shared queue protected by a single ``Lock``; the main thread
## blocks on a barrier until every worker drains the queue. No
## fork-server, no persistent worker — that's ct-test-runner's job and
## explicitly out of scope for M3.
##
## CLI::
##
##   repro_test_runner [--threads N] [--bin-dir DIR] [--build]
##                     [--summary-json PATH] [--quiet]
##                     [--filter GLOB]... [--test-timeout=N]
##
## Default ``--bin-dir`` is ``build/test-bin`` relative to the current
## working directory. ``--threads`` defaults to ``$NPROC`` or the
## platform's countProcessors() value.
##
## Environment::
##
##   REPRO_TEST_FAIL_FAST=1   stop scheduling new tests after first FAIL
##   REPRO_TEST_THREADS=N     override default worker count
##

import std/[algorithm, atomics, json, locks, os, osproc, parseopt, streams,
            strtabs, strutils, tempfiles, times]

when defined(posix):
  import std/posix

const
  DefaultBinDir = "build/test-bin"
  DefaultResultsSubdir = "test-logs/results"
  DefaultSummaryPath = "test-logs/parallel-run.json"

  ## Test-binary basenames that are excluded from runner discovery.
  ## ``repro_test_runner`` is this binary itself (self-spawn would
  ## recurse). The rest are diagnostic / fixture / helper binaries left
  ## behind in ``build/test-bin/`` by other tooling. The list is the
  ## minimum the spec lets us hard-code; M4 retires it.
  ExcludeStems = [
    "repro_test_runner",
  ]

  ## These tests intentionally drive self-hosted ``repro build`` actions
  ## against shared workspace state. The B0/D2 cases mutate the sibling
  ## ``../runquota/build/bin/runquotad`` prerequisite; the B1/D5 cases rebuild
  ## or probe shared ``build/bin`` app artifacts, including the single public
  ## ``repro`` CLI; the B2/B3 cases inspect
  ## the global ``.repro/build/.../build-report.json`` emitted by those builds.
  ## Run the cluster with no other test active so shared prerequisites,
  ## app binaries, and report files are not removed or overwritten under
  ## another test's feet. D1 is in the same family: it drives a self-hosted
  ## Python test edge and reads the shared full build report for the
  ## resulting action.
  ##
  ## The M7 HTTPS cache gate starts a real TLS cache daemon and relies on
  ## process-local TLS context setup. Run it alone so other cache daemon tests
  ## cannot starve its listener startup under clean-cold load.
  ## The M77 no-op latency gate is also exclusive: it is a subprocess-spawn
  ## microbenchmark, so running it beside clean-cold compiler/linker tests
  ## measures runner contention instead of the shell-hook fast path.
  ##
  ## The dev-session e2e test starts foreground services, a file watcher, and an
  ## HTTP/SSE control plane, then waits for readiness transitions. Running it
  ## beside the heavier e2e cluster can starve the session startup path enough
  ## that the test measures host load instead of dev-session behavior.
  ##
  ## The binary-cache streaming checks run a loopback server in the same test
  ## process and deliberately enforce a 30-second receive/throughput budget.
  ## Under nested compiler load the server thread can be starved for the entire
  ## budget even though the transfer completes in under a second when the test
  ## owns the host. Likewise, the comprehensive local-build e2e case performs
  ## many nested Nim compiler invocations; concurrent nested builds have been
  ## observed to make Nim report SuccessX without materializing its requested
  ## extractor binary. The native-shell gate performs the same nested provider
  ## extraction for Bash, Zsh, and Fish and must own the host for the same
  ## reason. Keep these resource-sensitive checks fully enabled but execute
  ## them without competing test processes. The SC-7 capstone and SC-11
  ## cross-repo library test also perform repeated nested interface extraction;
  ## under contention Nim can report SuccessX without materializing the
  ## requested extractor binary, so they require the same scheduling boundary.
  ExclusiveStems = [
    "t_a2_5_p3_streaming_sink",
    "t_a2_5_p8_throughput_bench",
    "t_b0_repro_build_runquota_daemon",
    "t_b1_apps_action_cache_hit",
    "t_b1_repro_build_apps_byte_equivalent",
    "t_b1_repro_build_apps_collection",
    "t_b2_helper_invalidation",
    "t_b3_test_execute_edge_cache_hit",
    "t_b3_test_invalidation_rebuilds_repro",
    "t_cross_repo_nim_library_src_threaded_onto_consumer_path",
    "t_d1_pythonunittest_resolves_in_path_mode",
    "t_d2_cross_project_selector_recognised",
    "t_d5_collection_member_selector",
    "t_e2e_local_reprobuild_project_build",
    "t_e2e_native_shell_hooks",
    "t_e2e_repro_dev_sessions",
    "t_e2e_shell_hook_noop_latency",
    "t_repro_https_cache_end_to_end",
    "t_sc_capstone_reprobuild_runquota_and_library_edge_both_modes",
  ]

type
  TestCase = object
    binary: string          ## absolute path to the compiled test binary
    binaryStem: string      ## file basename without extension
    protocolAware: bool     ## true if the binary speaks --list-json
    qualifiedName: string   ## ``suite::test``; "" when whole-binary
    suite: string
    name: string

  TestStatus = enum
    tsPass = "PASS"
    tsFail = "FAIL"
    tsSkip = "SKIP"

  TestResult = object
    testCase: TestCase
    status: TestStatus
    durationMs: int
    resultFile: string
    stdout: string
    stderr: string

  Queue = object
    lock: Lock
    items: seq[TestCase]
    pos: int            ## next index to hand out
    failFastTriggered: bool

  WorkerArgs = object
    queue: ptr Queue
    resultsLock: ptr Lock
    results: ptr seq[TestResult]
    resultsDir: string
    quiet: bool
    failFast: bool
    testTimeoutSec: int
    activeCount: ptr int
    ## Snapshot of the parent process environment taken once before
    ## any worker thread is spawned. ``runOneProtocol`` clones this into
    ## a fresh ``StringTableRef`` per child and adds ``NIMTEST_RESULT_FILE``
    ## — so child env composition is purely thread-local and never
    ## touches the global ``environ``. This is the fix for the M3
    ## "two workers race on ``putEnv``" hazard called out in the
    ## Test-Edges-And-Parallel-Runner milestones.
    baseEnv: ptr seq[tuple[key, value: string]]

  TestProcess = object
    process: Process
    when defined(posix):
      processGroup: int
      ownerToken: string
      statusPath: string

proc ensureDir(dir: string) =
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)

proc looksLikeTestStem(stem: string): bool =
  ## Heuristic for "this binary is a test edge". Matches the file
  ## conventions of reprobuild's M1 generator (``t_*`` and ``test_*``
  ## file basenames lower-cased onto disk).
  stem.startsWith("t_") or stem.startsWith("test_")

proc scanTestBinaries(binDir: string): seq[string] =
  result = @[]
  if not dirExists(binDir):
    return
  for kind, path in walkDir(binDir):
    if kind != pcFile:
      continue
    let stem = splitFile(path).name
    if not looksLikeTestStem(stem):
      continue
    if stem in ExcludeStems:
      continue
    when defined(windows):
      if not path.endsWith(".exe"):
        continue
    else:
      let info = getFileInfo(path)
      if fpUserExec notin info.permissions:
        continue
    result.add(path.absolutePath)
  result.sort()

proc looksProtocolAwareByStrings(binary: string): bool =
  ## Cheap text-scan over the binary: a binary is protocol-aware iff it
  ## links the ``ct_test_unittest_parallel`` shim, which embeds the
  ## marker string "ct_test_unittest_parallel" (the module's own
  ## stderr-prefix literal). This avoids spending a full ``--list-json``
  ## execution on every ``std/unittest`` binary just to discover that
  ## it ignores the flag and runs its whole suite.
  const Marker = "ct_test_unittest_parallel"
  const ChunkSize = 64 * 1024
  try:
    let f = open(binary, fmRead)
    defer: f.close()
    var carry = ""
    var buf = newString(ChunkSize)
    while true:
      let n = f.readBuffer(addr buf[0], ChunkSize)
      if n <= 0:
        break
      let chunk = carry & buf[0 ..< n]
      if chunk.contains(Marker):
        return true
      # Keep the last len(Marker)-1 bytes so the marker isn't split
      # across chunk boundaries.
      if chunk.len > Marker.len - 1:
        carry = chunk[chunk.len - Marker.len + 1 .. ^1]
      else:
        carry = chunk
    return false
  except CatchableError:
    return false

proc probeBinary(binary: string): tuple[protocol: bool;
                                        catalog: seq[(string, string)]] =
  ## Decide whether the binary speaks the protocol and return its test
  ## catalog when so. Two stages: (1) cheap byte-scan for the
  ## ``ct_test_unittest_parallel`` marker — if absent, the binary is
  ## treated as opaque without running it. (2) when the marker is
  ## present, invoke ``--list-json`` and parse the JSON catalog.
  result.protocol = false
  result.catalog = @[]
  if not looksProtocolAwareByStrings(binary):
    return
  let (output, exitCode) = execCmdEx(quoteShell(binary) & " --list-json")
  if exitCode != 0:
    return
  let trimmed = output.strip()
  if trimmed.len == 0 or trimmed[0] != '{':
    return
  try:
    let doc = parseJson(trimmed)
    if not doc.hasKey("tests") or doc["tests"].kind != JArray:
      return
    var cat: seq[(string, string)] = @[]
    for entry in doc["tests"]:
      let suite = entry{"suite"}.getStr("")
      let name = entry{"name"}.getStr("")
      # ``name`` in the JSON catalog is the qualified form
      # ``suite::test``. Extract the bare test name for the registry.
      var bareName = name
      if name.startsWith(suite & "::"):
        bareName = name[len(suite) + 2 .. ^1]
      cat.add((suite, bareName))
    result.protocol = true
    result.catalog = cat
  except JsonParsingError:
    return

proc buildEngine(repoRoot: string): bool =
  ## Drive the engine build of the ``test`` aggregate. Returns true on
  ## success. Skipped (no-op, returns true) if ``./build/bin/repro`` is
  ## not present — the calling shell script has already done the build
  ## in that case.
  let repro = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  if not fileExists(repro):
    return true
  stderr.writeLine "repro_test_runner: building :test aggregate"
  let cmd = quoteShell(repro) & " build test"
  let exitCode = execCmd(cmd)
  if exitCode != 0:
    stderr.writeLine "repro_test_runner: repro build test exited " &
      $exitCode
    return false
  true

proc qualifyName(binaryStem, suite, name: string): string =
  if suite.len > 0:
    suite & "::" & name
  else:
    name

# Module-global lock that serialises the child-process spawn step
# (``pipe()`` + ``fork()``/``execve``) across all worker threads.
#
# Why this is needed: on Linux, ``osproc.startProcess`` uses bare
# ``pipe()`` (no ``O_CLOEXEC``) and a bare ``fork()`` from whatever
# worker happens to call it. Two hazards stack up under
# ``--threads=8/16``:
#
# 1. **Pipe FD leak.** Between this thread's ``pipe()`` and the
#    parent's post-spawn ``close()`` of the unused pipe ends, a sibling
#    worker's ``fork()`` will copy those FDs into its own child as
#    ghost holders. The ghost holders prevent EOF on the parent-side
#    read of this thread's stream and can shift FD numbering so the
#    later ``close()`` operates on a different FD than expected.
# 2. **Fork inside multithreaded process.** Nim's
#    ``startProcessAfterFork`` calls non-async-signal-safe code
#    (``findExe``, GC allocations) in the child between ``fork()`` and
#    ``execve``. If another thread held a glibc internal lock (malloc
#    arena, etc.) at fork time, the child sees that lock as
#    permanently held — manifesting as a sporadic
#    ``Bad file descriptor [OSError]`` raised back through the error
#    pipe.
#
# Serialising the spawn step closes hazard (1) entirely: by the time
# ``startProcess`` returns, the parent has closed every pipe end it
# doesn't keep, and no sibling fork can have observed our pipe FDs.
# It also shrinks hazard (2)'s window to "no other worker is forking
# concurrently", which empirically takes the residual failure rate
# from "tears down the runner every few seconds at --threads=16" to
# "occasional, recoverable". The stream drain and ``waitForExit``
# happen with the lock released so per-test concurrency is preserved.
var spawnLock: Lock
initLock(spawnLock)

const TimeoutExitCode = -42
const TimeoutPollIntervalMs = 100
const TimeoutKillGraceSec = 5
const PostKillVerificationSec = 5

proc drainAvailable(p: Process; output: var string): int
proc finalDrainNonBlocking(p: Process; output: var string)

when defined(posix):
  const
    ProcessGroupWrapperFlag = "--internal-test-process-group"
    ProcessGroupReadyMarker = "REPRO_TEST_RUNNER_GROUP_READY_V1"
    GroupSupervisorPollIntervalMs = 10
    TestOwnerEnv = "REPRO_TEST_RUNNER_OWNER_TOKEN"
    CleanupTraceEnv = "REPRO_TEST_RUNNER_CLEANUP_TRACE"

  type
    ActiveProcessGroup = ref object
      processGroup: int
      anchorPid: int
      ownerToken: string
      anchorReaped: bool

  var
    activeProcessGroupsLock: Lock
    activeProcessGroups: seq[ActiveProcessGroup] = @[]
    nextProcessGroupToken = 0
    processGroupStateDir = ""
    cleanupTracePath = ""
    interruptedSignal: Atomic[int]
    interruptSignalSet: Sigset

  initLock(activeProcessGroupsLock)

  proc appendCleanupTrace(event: string) =
    ## Optional production-path observability used by the real process-tree
    ## integration regression. Cleanup correctness never depends on this file:
    ## a missing/unwritable trace must not prevent owned processes from being
    ## terminated.
    if cleanupTracePath.len == 0:
      return
    try:
      let trace = open(cleanupTracePath, fmAppend)
      trace.writeLine(event)
      trace.close()
    except CatchableError:
      discard

  var wrapperTerminationSignal {.global, volatile.}: Sig_atomic

  proc recordWrapperTermination(sig: cint) {.noconv, gcsafe, raises: [].} =
    ## The internal group supervisor must survive the graceful TERM phase so
    ## its PID continues to reserve the process-group identity until the
    ## parent sends SIGKILL. A custom handler (rather than SIG_IGN) is
    ## deliberate: handled dispositions reset to default across exec, while an
    ## ignored SIGTERM would be inherited by the actual test executable.
    wrapperTerminationSignal = Sig_atomic(sig)

  proc unblockWrapperSignals() =
    var signals, oldSignals: Sigset
    discard sigemptyset(signals)
    discard sigaddset(signals, SIGINT)
    discard sigaddset(signals, SIGTERM)
    discard sigaddset(signals, SIGHUP)
    discard pthread_sigmask(SIG_UNBLOCK, signals, oldSignals)

  proc writeGroupStatus(path: string; exitCode: int) =
    let pendingPath = path & ".pending"
    writeFile(pendingPath, $exitCode & "\n")
    moveFile(pendingPath, path)

  proc processGroupWrapperMain(params: seq[string]): int =
    ## Hidden, shell-free supervisor used only by the parent runner. It creates
    ## the process group from inside the child, before the real test is
    ## launched, so Linux's fork-based osproc path and macOS's posix_spawn path
    ## have identical ownership semantics.
    if params.len < 2:
      stderr.writeLine(
        "repro_test_runner: internal process-group wrapper arguments missing")
      return 125
    let statusPath = params[0]
    let binary = params[1]
    let binaryArgs =
      if params.len > 2: params[2 .. ^1]
      else: @[]

    if setpgid(Pid(0), Pid(0)) != 0:
      stderr.writeLine(
        "repro_test_runner: internal process-group setup failed: " &
        osErrorMsg(osLastError()))
      return 125

    signal(SIGINT, recordWrapperTermination)
    signal(SIGTERM, recordWrapperTermination)
    signal(SIGHUP, recordWrapperTermination)
    unblockWrapperSignals()

    # The parent consumes this private first line before returning the spawn to
    # a worker. Since the real child is launched only afterwards, arbitrary
    # test output can never race ahead of the readiness record.
    stdout.writeLine(ProcessGroupReadyMarker)
    stdout.flushFile()

    var child: Process
    var exitCode = 125
    # A spawn failure is the HARNESS failing to start the test, not the test
    # failing. Observed in practice as EACCES against a mode-0755 binary that
    # runs fine standalone — an exec racing the build that wrote it, or a
    # transient fork/exec resource condition under concurrent workers. Both are
    # self-clearing, so retry a bounded number of times with a short backoff
    # before giving up. `waitForExit` is deliberately NOT retried: once the
    # child is running its exit status is the test's answer, whatever it is.
    const
      SpawnAttempts = 4
      SpawnRetryDelayMs = 250
    var spawnError = ""
    for attempt in 1 .. SpawnAttempts:
      spawnError = ""
      try:
        child = startProcess(binary, args = binaryArgs,
          options = {poParentStreams})
      except OSError as e:
        spawnError = e.msg
        if attempt < SpawnAttempts:
          stderr.writeLine(
            "repro_test_runner: spawn attempt " & $attempt & " of " &
            $SpawnAttempts & " failed (" & e.msg & "); retrying")
          sleep(SpawnRetryDelayMs * attempt)
          continue
        break
      try:
        exitCode = child.waitForExit()
        close(child)
      except IOError as e:
        stderr.writeLine(
          "repro_test_runner: internal process-group child wait failed: " &
          e.msg)
      break
    if spawnError.len > 0:
      # Exit 126 ("command found but not executable") distinguishes a harness
      # spawn failure from any status the test itself could return, so a suite
      # summary can separate "the code is broken" from "we could not run it".
      exitCode = 126
      stderr.writeLine(
        "repro_test_runner: HARNESS ERROR — child spawn failed after " &
        $SpawnAttempts & " attempts: " & spawnError)
    try:
      writeGroupStatus(statusPath, exitCode)
    except CatchableError as e:
      stderr.writeLine(
        "repro_test_runner: internal process-group status failed: " & e.msg)
      return 125

    # Stay alive as the group anchor even after the direct test child exits.
    # Every completion path TERM/KILLs all exact-token descendants and this
    # complete group before it reports the result. Keeping the anchor until
    # SIGKILL prevents its PGID from being reused during that cleanup window.
    while true:
      sleep(GroupSupervisorPollIntervalMs)
    exitCode

  proc removeActiveProcessGroupUnlocked(processGroup: int) =
    for i, current in activeProcessGroups:
      if current.processGroup == processGroup:
        activeProcessGroups.delete(i)
        return

  proc findActiveProcessGroupUnlocked(processGroup: int):
      tuple[found: bool; group: ActiveProcessGroup] =
    for current in activeProcessGroups:
      if current.processGroup == processGroup:
        return (true, current)

  proc registerActiveProcessGroup(processGroup: int; ownerToken: string) =
    acquire(activeProcessGroupsLock)
    activeProcessGroups.add(ActiveProcessGroup(
      processGroup: processGroup,
      anchorPid: processGroup,
      ownerToken: ownerToken))
    release(activeProcessGroupsLock)

  proc signalProcessGroup(active: ActiveProcessGroup; sig: cint) =
    ## Revalidate the exact supervisor anchor still leads its recorded group
    ## immediately before using a negative-PID signal; a dead/reused PID must
    ## never redirect cleanup to an unrelated group.
    ##
    ## ``anchorReaped`` is monotonic state on the registered group object, not
    ## per-cleanup-call state. A bounded owner-token verification can fail
    ## after this invocation has already reaped the supervisor; a later final
    ## reaper/interrupt retry must then remain token-only even if the kernel
    ## has reused the old PID/PGID.
    if active.isNil or active.anchorReaped:
      return
    appendCleanupTrace(
      "group-signal-attempt group=" & $active.processGroup &
      " signal=" & $sig)
    if active.anchorPid > 0 and active.processGroup > 0 and
        getpgid(Pid(active.anchorPid)) == Pid(active.processGroup):
      discard kill(Pid(-active.processGroup), sig)

  when defined(linux):
    proc processHasOwnerToken(pid: int; ownerToken: string): bool =
      if pid <= 0 or ownerToken.len == 0:
        return false
      try:
        let environment = readFile("/proc" / $pid / "environ")
        let expected = TestOwnerEnv & "=" & ownerToken
        for entry in environment.split('\0'):
          if entry == expected:
            return true
      except CatchableError:
        discard

    proc ownedProcessIds(ownerToken: string): seq[int] =
      if ownerToken.len == 0 or not dirExists("/proc"):
        return
      for kind, path in walkDir("/proc"):
        if kind != pcDir:
          continue
        var pid = 0
        try:
          pid = parseInt(path.lastPathPart)
        except ValueError:
          continue
        if pid != getCurrentProcessId() and
            processHasOwnerToken(pid, ownerToken):
          result.add(pid)

  elif defined(macosx):
    const
      ProcAllPids = 1'u32
      PidGrowthMargin = 64

    type DarwinPid = int32

    proc procListPids(kind, kindInfo: uint32; buffer: pointer;
                      bufferSize: cint): cint {.
      importc: "proc_listpids", header: "<libproc.h>".}

    {.emit: """
      #include <stdlib.h>
      #include <string.h>
      #include <sys/sysctl.h>

      static int repro_process_has_exact_env_entry(
          int pid, const char *expected) {
        int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
        size_t size = 0;
        if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) {
          return 0;
        }
        char *buffer = (char *)malloc(size);
        if (buffer == NULL) return 0;
        if (sysctl(mib, 3, buffer, &size, NULL, 0) != 0) {
          free(buffer);
          return 0;
        }
        if (size < sizeof(int)) {
          free(buffer);
          return 0;
        }

        int argc = 0;
        memcpy(&argc, buffer, sizeof(argc));
        if (argc < 0) {
          free(buffer);
          return 0;
        }

        /*
         * KERN_PROCARGS2 is:
         *
         *   argc, executable path, NUL padding, argv[0..argc-1],
         *   NUL padding, environment entries
         *
         * Do not scan the complete buffer. An unrelated process may carry a
         * literal argv element that happens to equal our owner-token entry;
         * only the environment segment establishes ownership.
         */
        size_t cursor = sizeof(int);
        while (cursor < size && buffer[cursor] != '\0') ++cursor;
        if (cursor >= size) {
          free(buffer);
          return 0;
        }
        while (cursor < size && buffer[cursor] == '\0') ++cursor;

        for (int arg = 0; arg < argc; ++arg) {
          if (cursor >= size) {
            free(buffer);
            return 0;
          }
          while (cursor < size && buffer[cursor] != '\0') ++cursor;
          if (cursor >= size) {
            free(buffer);
            return 0;
          }
          ++cursor;
        }
        while (cursor < size && buffer[cursor] == '\0') ++cursor;

        const size_t expected_len = strlen(expected);
        int found = 0;
        while (cursor < size) {
          size_t end = cursor;
          while (end < size && buffer[end] != '\0') ++end;
          if (end - cursor == expected_len &&
              memcmp(buffer + cursor, expected, expected_len) == 0) {
            found = 1;
            break;
          }
          if (end >= size) break;
          cursor = end + 1;
        }
        free(buffer);
        return found;
      }
    """.}

    proc macProcessHasExactEnvEntry(pid: cint; expected: cstring): cint {.
      importc: "repro_process_has_exact_env_entry", nodecl.}

    proc processHasOwnerToken(pid: int; ownerToken: string): bool =
      if pid <= 0 or ownerToken.len == 0:
        return false
      let expected = TestOwnerEnv & "=" & ownerToken
      macProcessHasExactEnvEntry(cint(pid), expected.cstring) != 0

    proc ownedProcessIds(ownerToken: string): seq[int] =
      if ownerToken.len == 0:
        return
      let queriedBytes = procListPids(ProcAllPids, 0'u32, nil, 0.cint)
      if queriedBytes <= 0:
        return
      let pidBytes = sizeof(DarwinPid)
      var capacity =
        (int(queriedBytes) + pidBytes - 1) div pidBytes + PidGrowthMargin
      for _ in 0 ..< 3:
        var pids = newSeq[DarwinPid](capacity)
        let returnedBytes = procListPids(
          ProcAllPids, 0'u32, addr pids[0], cint(pids.len * pidBytes))
        if returnedBytes < 0:
          return
        if int(returnedBytes) < pids.len * pidBytes:
          let returnedCount = int(returnedBytes) div pidBytes
          for i in 0 ..< returnedCount:
            let pid = int(pids[i])
            if pid > 0 and pid != getCurrentProcessId() and
                processHasOwnerToken(pid, ownerToken):
              result.add(pid)
          return
        capacity *= 2

  else:
    proc processHasOwnerToken(pid: int; ownerToken: string): bool =
      discard pid
      discard ownerToken
      false

    proc ownedProcessIds(ownerToken: string): seq[int] =
      discard ownerToken
      @[]

  proc signalOwnedProcesses(active: ActiveProcessGroup; sig: cint;
                            exceptPid = 0) =
    ## The exact per-test environment token survives fork/exec and setsid.
    ## Revalidate every enumerated PID immediately before signalling it. The
    ## enumeration-to-kill window can contain PID reuse; an unrelated
    ## replacement PID cannot carry the private token.
    let ownerPids = ownedProcessIds(active.ownerToken)
    appendCleanupTrace(
      "owner-snapshot group=" & $active.processGroup &
      " signal=" & $sig & " count=" & $ownerPids.len)
    for pid in ownerPids:
      if pid != exceptPid and
          processHasOwnerToken(pid, active.ownerToken):
        appendCleanupTrace(
          "owner-signal-attempt group=" & $active.processGroup &
          " pid=" & $pid & " signal=" & $sig)
        discard kill(Pid(pid), sig)

  proc ownedProcessesRemain(ownerToken: string; exceptPid = 0): bool =
    for pid in ownedProcessIds(ownerToken):
      if pid != exceptPid:
        return true

  proc killAndVerifyOwnedProcesses(
      activeGroups: openArray[ActiveProcessGroup]): bool =
    ## SIGKILL closes the graceful phase, but a single process snapshot is not
    ## a cleanup barrier: a detached token-bearing descendant can fork between
    ## enumeration and signal delivery. Re-enumerate, revalidate, and retry for
    ## a bounded interval. Success means an exact post-KILL enumeration found no
    ## owner token; callers must not unregister or publish PASS otherwise.
    ##
    ## Group and token cleanup are deliberately separate phases. The recorded
    ## process group is signalled exactly once while its unreaped supervisor
    ## still reserves the PGID. Only after every supervisor has been reaped do
    ## we enter the retryable token-owner phase. It is therefore structurally
    ## impossible for a later retry to target a reused anchor PID/PGID.
    let deadline = epochTime() + PostKillVerificationSec.float
    # This is the only process-group signal in the function. No control-flow
    # edge from the token-owner retry phase below returns here.
    for active in activeGroups:
      signalProcessGroup(active, SIGKILL)

    # Reap every exact supervisor before allowing the cleanup to proceed using
    # only token ownership. A setsid/poDaemon descendant can intentionally
    # remain alive here; it cannot reserve or authenticate the recorded PGID.
    while true:
      var anchorsRemain = false
      for active in activeGroups:
        if not active.anchorReaped:
          var status: cint
          while true:
            let reaped = waitpid(Pid(active.anchorPid), status, WNOHANG)
            if reaped == Pid(active.anchorPid):
              # Persist retirement on the exact registry object before any
              # retry can release/reacquire the registry lock. From this point
              # onward no group-signal entry point may target this PID/PGID.
              active.anchorReaped = true
              appendCleanupTrace(
                "anchor-reaped group=" & $active.processGroup)
              break
            if reaped < 0 and errno == EINTR:
              continue
            if reaped < 0 and errno == ECHILD:
              # ECHILD means this runner no longer owns a waitable child at
              # the recorded PID. Treat the group identity as permanently
              # retired: signalling it can only be less safe than continuing
              # with exact-token ownership.
              active.anchorReaped = true
              appendCleanupTrace(
                "anchor-already-reaped group=" & $active.processGroup)
            break
        if not active.anchorReaped:
          anchorsRemain = true
      if not anchorsRemain:
        break
      if epochTime() >= deadline:
        return false
      sleep(GroupSupervisorPollIntervalMs)

    # Detached exact-token descendants are killed and verified only after all
    # anchors are reaped. Every retry is PID-safe: enumeration and immediate
    # pre-signal revalidation both require the exact private token.
    while true:
      var ownersRemain = false
      for active in activeGroups:
        if ownedProcessesRemain(active.ownerToken,
                                exceptPid = active.anchorPid):
          ownersRemain = true
          break
      if not ownersRemain:
        return true
      for active in activeGroups:
        signalOwnedProcesses(active, SIGKILL,
          exceptPid = active.anchorPid)
      if epochTime() >= deadline:
        return false
      sleep(TimeoutPollIntervalMs)

  proc terminateProcessGroupLocked(active: ActiveProcessGroup): bool =
    ## Caller holds activeProcessGroupsLock, which keeps this registered group
    ## anchored until escalation completes and prevents concurrent normal
    ## release from making the PGID available for reuse. The environment-token
    ## pass also reaches test-owned grandchildren that deliberately escaped the
    ## group with setsid/poDaemon.
    signalProcessGroup(active, SIGTERM)
    signalOwnedProcesses(active, SIGTERM,
      exceptPid = active.anchorPid)
    let killDeadline = epochTime() + TimeoutKillGraceSec.float
    while ownedProcessesRemain(active.ownerToken,
                               exceptPid = active.anchorPid) and
        epochTime() < killDeadline:
      sleep(TimeoutPollIntervalMs)
    killAndVerifyOwnedProcesses([active])

  proc terminateOwnedProcessGroup(processGroup: int): bool =
    acquire(activeProcessGroupsLock)
    let active = findActiveProcessGroupUnlocked(processGroup)
    if active.found:
      result = terminateProcessGroupLocked(active.group)
    else:
      result = true
    release(activeProcessGroupsLock)

  proc terminateAllActiveProcessGroups(): bool =
    ## Holding the registry serializes cleanup against concurrent release.
    ## Unreaped entries retain a live or reserved supervisor anchor through
    ## process-group signalling and reap; retired entries are token-only, and
    ## signalProcessGroup is a no-op for them.
    acquire(activeProcessGroupsLock)
    if activeProcessGroups.len == 0:
      release(activeProcessGroupsLock)
      return true
    for active in activeProcessGroups:
      signalProcessGroup(active, SIGTERM)
      signalOwnedProcesses(active, SIGTERM,
        exceptPid = active.anchorPid)
    let killDeadline = epochTime() + TimeoutKillGraceSec.float
    var descendantsRemain = true
    while descendantsRemain and epochTime() < killDeadline:
      descendantsRemain = false
      for active in activeProcessGroups:
        if ownedProcessesRemain(active.ownerToken,
                                exceptPid = active.anchorPid):
          descendantsRemain = true
          break
      if descendantsRemain:
        sleep(TimeoutPollIntervalMs)
    result = killAndVerifyOwnedProcesses(activeProcessGroups)
    release(activeProcessGroupsLock)

  proc reapResidualActiveProcessGroups(): bool =
    ## Worker joins are the normal reap barrier. This final invariant is a
    ## fail-closed backstop: a signal exit is never allowed to return while a
    ## registered supervisor remains, even if a worker aborted unexpectedly.
    ## Workers are already joined when this runs, so the registry cannot gain
    ## new entries. Retry any incomplete worker/signal cleanup, but retain the
    ## anchor registrations and refuse summary emission if an exact owner still
    ## survives the bounded verification interval.
    if not terminateAllActiveProcessGroups():
      return false
    acquire(activeProcessGroupsLock)
    activeProcessGroups.setLen(0)
    release(activeProcessGroupsLock)
    true

  proc interruptWaiter(signalSet: ptr Sigset) {.thread.} =
    var received: cint
    if sigwait(signalSet[], received) == 0:
      interruptedSignal.store(int(received), moRelease)
      {.cast(gcsafe).}:
        # The registry is protected by activeProcessGroupsLock; the cast only
        # tells Nim's thread-effect checker about that explicit synchronization.
        discard terminateAllActiveProcessGroups()

  proc startInterruptWaiter(): Thread[ptr Sigset] =
    ## Blocking before worker creation makes every worker inherit the mask.
    ## A dedicated sigwait thread can then take ordinary locks and perform the
    ## bounded two-phase cleanup without running non-signal-safe Nim code from
    ## an asynchronous signal handler.
    var oldSignals: Sigset
    discard sigemptyset(interruptSignalSet)
    discard sigaddset(interruptSignalSet, SIGINT)
    discard sigaddset(interruptSignalSet, SIGTERM)
    discard sigaddset(interruptSignalSet, SIGHUP)
    if pthread_sigmask(SIG_BLOCK, interruptSignalSet, oldSignals) != 0:
      raise newException(OSError,
        "repro_test_runner: could not block interrupt signals")
    createThread(result, interruptWaiter, addr interruptSignalSet)

  proc newProcessGroupPaths():
      tuple[statusPath, ownerToken: string] =
    if processGroupStateDir.len == 0:
      raise newException(IOError,
        "repro_test_runner: process-group state directory is not initialized")
    inc nextProcessGroupToken
    let token = $getCurrentProcessId() & "-" & $nextProcessGroupToken
    result.statusPath = processGroupStateDir / (token & ".status")
    result.ownerToken = processGroupStateDir.lastPathPart & "-" & token

  proc cleanupProcessGroupPaths(testProcess: TestProcess) =
    for path in [
      testProcess.statusPath,
      testProcess.statusPath & ".pending",
    ]:
      if fileExists(path):
        try:
          removeFile(path)
        except CatchableError:
          discard

  proc cleanupProcessGroupStateDir() =
    if processGroupStateDir.len > 0 and dirExists(processGroupStateDir):
      try:
        removeDir(processGroupStateDir)
      except CatchableError:
        discard
    processGroupStateDir = ""

  proc finishInterruptedTestProcess(testProcess: TestProcess;
                                    output: var string): bool =
    ## The sigwait thread has already completed group-wide TERM/KILL and
    ## synchronously reaped the supervisor before it releases
    ## activeProcessGroupsLock. Remove the registry entry only after the same
    ## exact-owner check succeeds.
    acquire(activeProcessGroupsLock)
    try:
      if findActiveProcessGroupUnlocked(testProcess.processGroup).found:
        if not ownedProcessesRemain(testProcess.ownerToken,
                                    exceptPid = testProcess.processGroup):
          removeActiveProcessGroupUnlocked(testProcess.processGroup)
          result = true
    finally:
      release(activeProcessGroupsLock)
    if result:
      finalDrainNonBlocking(testProcess.process, output)
      close(testProcess.process)
      cleanupProcessGroupPaths(testProcess)
    else:
      output.add(
        "\nrepro_test_runner: interrupt cleanup left exact owner-token " &
        "processes; refusing to unregister the process group.\n")

proc spawnedProcess(binary: string; args: openArray[string];
                    env: StringTableRef): TestProcess =
  when defined(posix):
    if interruptedSignal.load(moAcquire) != 0:
      raise newException(IOError,
        "runner interrupted before test process spawn")
  acquire(spawnLock)
  try:
    when defined(posix):
      let paths = newProcessGroupPaths()
      let wrapperArgs =
        @[ProcessGroupWrapperFlag, paths.statusPath, binary] & @args
      env[TestOwnerEnv] = paths.ownerToken
      let process = startProcess(
        getAppFilename(), args = wrapperArgs, env = env,
        options = {poStdErrToStdOut})
      var readyLine = ""
      if not process.outputStream.readLine(readyLine) or
          readyLine != ProcessGroupReadyMarker:
        try:
          process.kill()
          discard process.waitForExit()
        except CatchableError:
          discard
        close(process)
        raise newException(IOError,
          "test process-group supervisor did not become ready: " & readyLine)
      let processGroup = process.processID
      if processGroup <= 0 or
          getpgid(Pid(processGroup)) != Pid(processGroup):
        try:
          process.kill()
          discard process.waitForExit()
        except CatchableError:
          discard
        close(process)
        raise newException(IOError,
          "test process-group supervisor did not own its expected group")
      result = TestProcess(
        process: process,
        processGroup: processGroup,
        ownerToken: paths.ownerToken,
        statusPath: paths.statusPath)
      registerActiveProcessGroup(processGroup, paths.ownerToken)
    else:
      result.process = startProcess(
        binary, args = args, env = env,
        options = {poStdErrToStdOut, poUsePath})
  finally:
    release(spawnLock)

  when defined(posix):
    # Close the registration race with an interrupt that acquired the active
    # registry while this spawn was establishing its child-side group.
    if interruptedSignal.load(moAcquire) != 0:
      discard terminateOwnedProcessGroup(result.processGroup)

const AbsoluteTimeoutMultiplier = 4
  ## The per-test ``--test-timeout`` is interpreted as an *idle*
  ## deadline (no output produced for that long ⇒ kill), not a fixed
  ## wall-clock budget. ``AbsoluteTimeoutMultiplier × testTimeoutSec`` is
  ## the hard ceiling: a test that keeps emitting output but never
  ## finishes is still killed once total wall time crosses it, so a
  ## chatty-but-genuinely-stuck test (e.g. a busy spin that logs every
  ## iteration) cannot run forever. With the default 600 s idle deadline
  ## this caps any single test at 40 min, well inside the 4 h runner-
  ## phase backstop.

proc drainAndWait(testProcess: TestProcess):
    tuple[output: string; exitCode: int] =
  ## Drain the merged stdout/stderr stream to EOF, then collect the
  ## child's exit code and free its handles. Reading the stream to EOF
  ## first guarantees ``waitForExit`` won't deadlock on a child that
  ## blocks waiting for the parent to consume its pipe buffer.
  let p = testProcess.process
  when defined(posix):
    # The POSIX group supervisor remains alive after the direct test child
    # exits, so completion is reported through its private status file rather
    # than pipe EOF. This polling path is also used when timeouts are disabled.
    var groupOutput = ""
    while not fileExists(testProcess.statusPath):
      if interruptedSignal.load(moAcquire) != 0:
        groupOutput.add(
          "\nrepro_test_runner: interrupted; owned process group killed.\n")
        discard finishInterruptedTestProcess(testProcess, groupOutput)
        return (groupOutput, TimeoutExitCode)
      discard drainAvailable(p, groupOutput)
      sleep(GroupSupervisorPollIntervalMs)
    let groupExitCode = parseInt(readFile(testProcess.statusPath).strip())
    finalDrainNonBlocking(p, groupOutput)

    acquire(activeProcessGroupsLock)
    var cleanupComplete = true
    try:
      let active = findActiveProcessGroupUnlocked(testProcess.processGroup)
      if active.found:
        # The direct test is complete, but any group member or setsid/poDaemon
        # sidecar carrying this test's private token is still runner-owned.
        # Tear those down before reporting completion to the next test.
        cleanupComplete = terminateProcessGroupLocked(active.group)
      if cleanupComplete:
        removeActiveProcessGroupUnlocked(testProcess.processGroup)
    finally:
      release(activeProcessGroupsLock)
    if not cleanupComplete:
      groupOutput.add(
        "\nrepro_test_runner: exact owner-token processes survived " &
        "bounded cleanup; refusing to unregister or report PASS.\n")
      raise newException(IOError, groupOutput)
    close(p)
    cleanupProcessGroupPaths(testProcess)
    return (groupOutput, groupExitCode)

  var output = ""
  let outp = p.outputStream
  var line = newStringOfCap(120)
  while outp.readLine(line):
    output.add(line)
    output.add('\n')
  let exitCode = p.waitForExit()
  close(p)
  result = (output, exitCode)

proc drainToEof(p: Process; output: var string) =
  ## Drain the merged stdout/stderr pipe to EOF. Safe to call only
  ## after the child has exited (or been killed) — Nim's stream
  ## ``readLine`` is blocking, so calling this on a live child that
  ## isn't emitting output would park the runner indefinitely. The
  ## polling loop in ``drainAndWaitWithTimeout`` is explicitly
  ## structured to avoid that: it only reaches ``drainToEof`` once
  ## ``peekExitCode`` reports the child is gone (either it exited on
  ## its own, or we SIGTERM/SIGKILLed it).
  let outp = p.outputStream
  if outp.isNil:
    return
  var line = newStringOfCap(120)
  while true:
    try:
      if not outp.readLine(line):
        break
    except IOError:
      break
    output.add(line)
    output.add('\n')

const PostExitDrainGraceSec = 10.0

proc drainToEofBounded(p: Process; output: var string;
                       graceSec: float): bool =
  ## Drain the merged stdout/stderr pipe after the child has exited,
  ## but give up after ``graceSec`` if EOF never arrives. Returns
  ## ``true`` if EOF was reached, ``false`` if we bailed out.
  ##
  ## Why this is bounded where ``drainToEof`` is not: a test can spawn a
  ## long-lived helper (e.g. the ``repro_binary_cache`` server, started
  ## with ``poParentStreams``) that inherits the test's stdout — i.e.
  ## the write end of *this* pipe. If the test then exits without
  ## reaping that helper (the classic case being a crashed test whose
  ## ``defer`` teardown never runs), the helper keeps the write end open
  ## and a blocking ``readLine`` here never sees EOF. That parked the
  ## whole runner for hours on Linux (glibc, where the leaked-daemon
  ## scenario is reachable). Bounding the drain turns "runner hangs
  ## forever, masking every later test" into "this one test reports with
  ## a clear leaked-fd note and the suite continues".
  when defined(posix):
    let fd = cint(p.outputHandle)
    let flags = fcntl(fd, F_GETFL, cint(0))
    if flags != -1:
      discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
    var buf: array[4096, char]
    let deadline = epochTime() + graceSec
    while true:
      let n = read(fd, addr buf[0], buf.len)
      if n > 0:
        var chunk = newString(int(n))
        copyMem(addr chunk[0], addr buf[0], int(n))
        output.add(chunk)
      elif n == 0:
        return true
      else:
        let e = errno
        if e == EAGAIN or e == EWOULDBLOCK:
          if epochTime() > deadline:
            return false
          sleep(50)
        elif e == EINTR:
          continue
        else:
          return false
  else:
    # Non-posix (Windows CI is not a supported runner host today): keep
    # the original blocking behaviour.
    drainToEof(p, output)
    return true

proc drainAvailable(p: Process; output: var string): int =
  ## Non-blocking read of whatever is currently buffered in the merged
  ## stdout/stderr pipe of a *live* child. Returns the number of bytes
  ## appended (0 if the pipe is momentarily empty). POSIX only — the fd
  ## is put in ``O_NONBLOCK`` so the call never parks the poll loop on a
  ## test that isn't emitting output right now. Used to (a) keep the
  ## pipe drained so a verbose test can't fill the 64 KB kernel buffer
  ## and self-block, and (b) detect forward progress for the idle-
  ## deadline heuristic in ``drainAndWaitWithTimeout``.
  when defined(posix):
    let fd = cint(p.outputHandle)
    let flags = fcntl(fd, F_GETFL, cint(0))
    if flags != -1:
      discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
    var total = 0
    var buf: array[4096, char]
    while true:
      let n = read(fd, addr buf[0], buf.len)
      if n > 0:
        var chunk = newString(int(n))
        copyMem(addr chunk[0], addr buf[0], int(n))
        output.add(chunk)
        total += int(n)
        if int(n) < buf.len:
          break          # drained what was available; don't block
      elif n == 0:
        break            # writer closed; EOF handled by peekExitCode path
      else:
        let e = errno
        if e == EAGAIN or e == EWOULDBLOCK or e == EINTR:
          break          # nothing more available right now
        else:
          break
    return total
  else:
    return 0

const FinalDrainPasses = 5
const FinalDrainPassSleepMs = 20

proc finalDrainNonBlocking(p: Process; output: var string) =
  ## Final, *non-blocking* drain of the merged stdout/stderr pipe after
  ## the child has exited (cleanly or via our kill). Grabs whatever is
  ## buffered in a few quick passes and then walks away — it NEVER blocks
  ## waiting for the pipe's EOF.
  ##
  ## Why this replaces the EOF-blocking ``drainToEofBounded`` at the
  ## post-exit sites: a failed ``repro build`` / ``repro develop`` /
  ## ``repro watch`` test can leave a daemon holding a transiently-inherited
  ## copy of this pipe's write end. Blocking for EOF here (even bounded to
  ## 10s) stalls the runner before the ownership cleanup can terminate that
  ## daemon. A test that has produced its exit code is ready for cleanup; the
  ## final drain only captures bytes already in flight.
  ##
  ## The D6 silent-hang guard is unaffected: that guard fires *before* we
  ## ever reach a final drain — a test that goes silent trips the idle
  ## deadline in the poll loop and is SIGTERM/SIGKILLed there. By the time
  ## we drain here the child is already gone; we are only collecting
  ## trailing bytes, not deciding liveness.
  ##
  ## A few short passes (rather than a single read) catch bytes that raced
  ## into the kernel pipe buffer just before the child exited, without
  ## re-introducing an unbounded wait: total worst case is
  ## ``FinalDrainPasses * FinalDrainPassSleepMs`` (~100ms).
  for _ in 0 ..< FinalDrainPasses:
    if drainAvailable(p, output) == 0:
      sleep(FinalDrainPassSleepMs)
    # If bytes are still flowing we keep looping the fixed number of
    # passes; we never extend the loop based on EOF.

proc drainAndWaitWithTimeout(testProcess: TestProcess; timeoutSec: int):
    tuple[output: string; exitCode: int; timedOut: bool;
          timeoutDescription: string] =
  ## Deadline-aware variant of ``drainAndWait``. When ``timeoutSec <= 0``
  ## the call delegates to ``drainAndWait`` (preserving M3 behaviour).
  ##
  ## ``timeoutSec`` is interpreted as an **idle** deadline, not a fixed
  ## wall-clock budget: the test is killed only after it has produced no
  ## new output for ``timeoutSec`` seconds. A polling loop drains the
  ## pipe non-blockingly every ~``TimeoutPollIntervalMs`` and resets the
  ## idle clock whenever bytes arrive. A genuinely-slow-but-alive heavy
  ## e2e test under shared-runner contention keeps emitting progress
  ## output, so it is *not* killed; a truly hung test (silent on its
  ## output stream — exactly the D6 ``sleep(60_000)`` shape, and the
  ## real ``t_local_daemons_control_plane_m11`` leaked-daemon stall)
  ## produces nothing and is killed once the idle window elapses.
  ##
  ## An absolute ceiling of ``AbsoluteTimeoutMultiplier × timeoutSec``
  ## still applies so a chatty-but-stuck test (keeps logging, never
  ## finishes) cannot run forever — this is the "sane upper bound" that
  ## keeps the progress heuristic from masking a real hang.
  ##
  ## On expiry (idle or absolute) the child is SIGTERM'd, given
  ## ``TimeoutKillGraceSec`` to exit, then SIGKILL'd.
  ##
  ## Why the idle semantics matter: the M3 fixed-budget timeout false-
  ## killed live heavy e2e tests (``t_e2e_local_reprobuild_project_build``
  ## et al.) when the shared box was oversubscribed — they were making
  ## progress, just slowly. The original D6 hang it was built to defeat
  ## (a test that left ``repro-daemon`` children holding the inherited
  ## pipe open after exec returned) is *silent*, so the idle deadline
  ## still catches it without masking it.
  ##
  ## On non-POSIX hosts ``drainAvailable`` is a no-op, so the loop
  ## degrades to the original fixed-budget behaviour (no mid-flight
  ## drain, idle clock never resets) — acceptable since Windows is not a
  ## supported runner host today.
  if timeoutSec <= 0:
    let (output, exitCode) = drainAndWait(testProcess)
    return (output, exitCode, false, "")

  let p = testProcess.process
  var output = ""
  let start = epochTime()
  var lastProgress = start
  let absoluteDeadlineSec = timeoutSec.float * AbsoluteTimeoutMultiplier.float
  var timedOut = false
  var timeoutDescription = ""
  while true:
    when defined(posix):
      if interruptedSignal.load(moAcquire) != 0:
        output.add(
          "\nrepro_test_runner: interrupted; owned process group killed.\n")
        discard finishInterruptedTestProcess(testProcess, output)
        return (output, TimeoutExitCode, true, "INTERRUPTED")
    when defined(posix):
      var code = -1
      var childComplete = false
      if fileExists(testProcess.statusPath):
        try:
          code = parseInt(readFile(testProcess.statusPath).strip())
          childComplete = true
        except ValueError, IOError:
          discard
    else:
      let code = p.peekExitCode()
      let childComplete = code != -1
    if childComplete:
      # Child exited on its own. Collect whatever trailing output is buffered
      # without waiting for pipe EOF, then terminate every same-group or
      # exact-token sidecar before reporting the result. A detached child can
      # keep the pipe open until that ownership cleanup runs.
      when defined(posix):
        finalDrainNonBlocking(p, output)
        acquire(activeProcessGroupsLock)
        var cleanupComplete = true
        try:
          let active =
            findActiveProcessGroupUnlocked(testProcess.processGroup)
          if active.found:
            cleanupComplete = terminateProcessGroupLocked(active.group)
          if cleanupComplete:
            removeActiveProcessGroupUnlocked(testProcess.processGroup)
        finally:
          release(activeProcessGroupsLock)
        if not cleanupComplete:
          output.add(
            "\nrepro_test_runner: exact owner-token processes survived " &
            "bounded cleanup; refusing to unregister or report PASS.\n")
          raise newException(IOError, output)
        close(p)
        cleanupProcessGroupPaths(testProcess)
      else:
        finalDrainNonBlocking(p, output)
        close(p)
      return (output, code, false, "")
    # Drain whatever the live child has emitted since the last poll.
    # Non-blocking, so this never parks on a silent test. Any new bytes
    # are forward progress and reset the idle clock.
    if drainAvailable(p, output) > 0:
      lastProgress = epochTime()
    let now = epochTime()
    if (now - lastProgress) > timeoutSec.float:
      output.add("\nrepro_test_runner: no output for " & $timeoutSec &
        "s (idle deadline); treating as hung.\n")
      timedOut = true
      timeoutDescription =
        "IDLE TIMEOUT after " & $timeoutSec & "s without output"
      break
    if (now - start) > absoluteDeadlineSec:
      output.add("\nrepro_test_runner: exceeded absolute ceiling of " &
        $absoluteDeadlineSec.int & "s (" & $AbsoluteTimeoutMultiplier &
        "x the idle deadline) while still producing output; treating " &
        "as stuck.\n")
      timedOut = true
      timeoutDescription =
        "ABSOLUTE TIMEOUT after " & $absoluteDeadlineSec.int & "s"
      break
    sleep(TimeoutPollIntervalMs)

  # Deadline expired. POSIX keeps the supervisor anchor registered and alive
  # through TERM -> grace -> KILL; other platforms retain leader cleanup.
  when defined(posix):
    acquire(activeProcessGroupsLock)
    var cleanupComplete = true
    try:
      let active = findActiveProcessGroupUnlocked(testProcess.processGroup)
      if active.found:
        cleanupComplete = terminateProcessGroupLocked(active.group)
      if cleanupComplete:
        removeActiveProcessGroupUnlocked(testProcess.processGroup)
    finally:
      release(activeProcessGroupsLock)
    if not cleanupComplete:
      output.add(
        "\nrepro_test_runner: exact owner-token processes survived " &
        "bounded cleanup; refusing to unregister or report a terminal " &
        "test result.\n")
      raise newException(IOError, output)
  else:
    try:
      p.terminate()
    except OSError, Exception:
      discard
    let killDeadline = epochTime() + TimeoutKillGraceSec.float
    while epochTime() < killDeadline:
      if p.peekExitCode() != -1:
        break
      sleep(TimeoutPollIntervalMs)
    if p.peekExitCode() == -1:
      try:
        p.kill()
      except OSError, Exception:
        discard
      # Block on waitForExit only after the SIGKILL has been delivered;
      # the kernel must reap the zombie before peekExitCode returns a
      # real code, but the wait window is bounded by the kill itself.
      discard p.waitForExit()
  # The child has been killed and reaped; collect any trailing buffered
  # output without blocking for EOF. Exact-token cleanup above has already
  # killed detached descendants, but their inherited descriptors can still be
  # closing while the pipe is drained. The timeout itself — already recorded
  # in ``timedOut`` — is what makes this a FAIL; the drain only gathers
  # diagnostics.
  finalDrainNonBlocking(p, output)
  close(p)
  when defined(posix):
    cleanupProcessGroupPaths(testProcess)
  result = (output, TimeoutExitCode, timedOut, timeoutDescription)

proc runWholeBinary(tc: TestCase; resultsDir: string;
                    baseEnv: seq[tuple[key, value: string]];
                    testTimeoutSec: int): TestResult =
  result.testCase = tc
  result.status = tsFail
  let t0 = epochTime()
  # Wrap the whole spawn-drain-wait sequence so a sporadic
  # ``Bad file descriptor [OSError]`` from the residual fork hazard
  # documented above is reported as a test failure instead of tearing
  # down the worker thread (and silencing every test the queue would
  # have handed out afterwards). The crash mode happens before the
  # child runs, so the test is genuinely "did not produce a result"
  # — failing the test is the right exit-code behaviour for the run.
  try:
    var childEnv = newStringTable(modeCaseSensitive)
    for (k, v) in baseEnv:
      childEnv[k] = v
    let p = spawnedProcess(tc.binary, args = [], env = childEnv)
    let (output, exitCode, timedOut, timeoutDescription) =
      drainAndWaitWithTimeout(p, testTimeoutSec)
    if timedOut:
      result.status = tsFail
      result.stdout =
        "repro_test_runner: " & timeoutDescription &
        "; SIGKILLed\n" & output
    else:
      result.stdout = output
      case exitCode
      of 0: result.status = tsPass
      of 2: result.status = tsSkip
      else: result.status = tsFail
  except OSError as e:
    result.status = tsFail
    result.stdout = "repro_test_runner: spawn failed: " & e.msg & "\n"
  except IOError as e:
    result.status = tsFail
    result.stdout = "repro_test_runner: i/o failed: " & e.msg & "\n"
  result.durationMs = int((epochTime() - t0) * 1000)
  result.stderr = ""

proc runOneProtocol(tc: TestCase; resultsDir: string;
                    baseEnv: seq[tuple[key, value: string]];
                    testTimeoutSec: int): TestResult =
  result.testCase = tc
  result.status = tsFail
  let resultFile = resultsDir / (tc.binaryStem & "__" &
    tc.qualifiedName.multiReplace([
      ("::", "__"), ("/", "_"), (" ", "_"), ("\t", "_")]) & ".json")
  result.resultFile = resultFile
  # Build a per-child env table that inherits the parent snapshot and
  # overrides only ``NIMTEST_RESULT_FILE``. Doing this per-call keeps
  # each child's env composition thread-local (no shared mutable state)
  # and replaces the old ``putEnv`` global mutation that races between
  # workers under concurrent spawns.
  var childEnv = newStringTable(modeCaseSensitive)
  for (k, v) in baseEnv:
    childEnv[k] = v
  childEnv["NIMTEST_RESULT_FILE"] = resultFile
  let t0 = epochTime()
  # Same spawn-lock + exception-isolation discipline as
  # ``runWholeBinary``. A sibling whole-binary spawn racing this
  # protocol spawn would otherwise leak pipe FDs into the wrong child,
  # and a residual fork-vs-malloc hazard could still raise OSError.
  # The lock covers only ``startProcess``; the drain and exit-code
  # collection run concurrently with other workers.
  var output = ""
  var exitCode = 1
  var spawnFailed = false
  var timedOut = false
  var timeoutDescription = ""
  try:
    let p = spawnedProcess(
      tc.binary, args = ["--run", tc.qualifiedName], env = childEnv)
    (output, exitCode, timedOut, timeoutDescription) =
      drainAndWaitWithTimeout(p, testTimeoutSec)
  except OSError as e:
    spawnFailed = true
    output = "repro_test_runner: spawn failed: " & e.msg & "\n"
  except IOError as e:
    spawnFailed = true
    output = "repro_test_runner: i/o failed: " & e.msg & "\n"
  result.durationMs = int((epochTime() - t0) * 1000)
  if timedOut:
    result.stdout =
      "repro_test_runner: " & timeoutDescription &
      "; SIGKILLed\n" & output
  else:
    result.stdout = output
  if spawnFailed:
    result.status = tsFail
  elif timedOut:
    result.status = tsFail
  else:
    case exitCode
    of 0: result.status = tsPass
    of 2: result.status = tsSkip
    else: result.status = tsFail
  # Prefer the duration_ms recorded in the result file when present.
  if fileExists(resultFile):
    try:
      let doc = parseJson(readFile(resultFile))
      if doc.hasKey("duration_ms"):
        result.durationMs = doc["duration_ms"].getInt(result.durationMs)
    except CatchableError:
      discard

proc nextCase(queue: ptr Queue; failFast: bool;
              out_case: var TestCase): bool =
  when defined(posix):
    if interruptedSignal.load(moAcquire) != 0:
      return false
  acquire(queue.lock)
  defer: release(queue.lock)
  if failFast and queue.failFastTriggered:
    return false
  if queue.pos >= queue.items.len:
    return false
  out_case = queue.items[queue.pos]
  inc queue.pos
  return true

proc markFailFast(queue: ptr Queue) =
  acquire(queue.lock)
  queue.failFastTriggered = true
  release(queue.lock)

proc emitProgress(quiet: bool; res: TestResult) =
  if quiet:
    return
  let label = "[" & $res.status & "]"
  let name =
    if res.testCase.protocolAware:
      res.testCase.binaryStem & " " & res.testCase.qualifiedName
    else:
      res.testCase.binaryStem & " (whole-binary)"
  stderr.writeLine label & " " & name & " (" & $res.durationMs & "ms)"

proc workerLoop(args: WorkerArgs) =
  while true:
    var tc: TestCase
    if not nextCase(args.queue, args.failFast, tc):
      break
    discard atomicInc(args.activeCount[])
    var res: TestResult
    # Defence in depth: ``runOneProtocol`` and ``runWholeBinary`` both
    # catch the spawn-time ``OSError``/``IOError`` paths internally,
    # but any unexpected raise here would otherwise tear down the
    # worker thread and silently lose every test still on the queue.
    # Convert it to a synthetic FAIL so the run completes and the
    # summary reflects what happened.
    try:
      if tc.protocolAware:
        res = runOneProtocol(tc, args.resultsDir, args.baseEnv[],
          args.testTimeoutSec)
      else:
        res = runWholeBinary(tc, args.resultsDir, args.baseEnv[],
          args.testTimeoutSec)
    except CatchableError as e:
      res = TestResult(
        testCase: tc,
        status: tsFail,
        durationMs: 0,
        stdout: "repro_test_runner: worker exception: " & e.msg & "\n")
    discard atomicDec(args.activeCount[])

    acquire(args.resultsLock[])
    args.results[].add(res)
    release(args.resultsLock[])

    emitProgress(args.quiet, res)
    if args.failFast and res.status == tsFail:
      markFailFast(args.queue)

proc writeSummary(summaryPath: string; results: seq[TestResult];
                  wallTimeMs: int; threadsUsed: int) =
  var total = results.len
  var passed = 0
  var failed = 0
  var skipped = 0
  var arr = newJArray()
  for r in results:
    case r.status
    of tsPass: inc passed
    of tsFail: inc failed
    of tsSkip: inc skipped
    var node = newJObject()
    node["binary"] = %r.testCase.binary
    node["binary_stem"] = %r.testCase.binaryStem
    node["protocol_aware"] = %r.testCase.protocolAware
    node["qualified_name"] = %r.testCase.qualifiedName
    node["status"] = %($r.status)
    node["duration_ms"] = %r.durationMs
    node["result_file"] = %r.resultFile
    # Include the captured merged stdout/stderr for FAIL entries so
    # the build report carries the failure context (e.g. D6's
    # ``IDLE TIMEOUT after Ns without output; SIGKILLed`` prefix). PASS entries are kept
    # lightweight — their stdout would otherwise blow up the summary
    # file on a 500-test sweep.
    if r.status != tsPass and r.stdout.len > 0:
      node["stdout"] = %r.stdout
    arr.add(node)
  var doc = newJObject()
  var summary = newJObject()
  summary["total"] = %total
  summary["passed"] = %passed
  summary["failed"] = %failed
  summary["skipped"] = %skipped
  summary["wall_time_ms"] = %wallTimeMs
  summary["threads"] = %threadsUsed
  doc["summary"] = summary
  doc["tests"] = arr
  ensureDir(parentDir(summaryPath))
  writeFile(summaryPath, doc.pretty())

# ---- main ------------------------------------------------------------

type
  RunnerOpts = object
    binDir: string
    threads: int
    runBuild: bool
    summaryPath: string
    quiet: bool
    filters: seq[string]
    resultsDir: string
    testTimeoutSec: int

proc defaultThreads(): int =
  let env = getEnv("REPRO_TEST_THREADS")
  if env.len > 0:
    try: return parseInt(env)
    except ValueError: discard
  let np = getEnv("NPROC")
  if np.len > 0:
    try: return parseInt(np)
    except ValueError: discard
  result = countProcessors()
  if result <= 0:
    result = 1

proc parseArgs(): RunnerOpts =
  result.binDir = DefaultBinDir
  result.threads = defaultThreads()
  result.runBuild = true
  result.summaryPath = DefaultSummaryPath
  result.quiet = false
  result.filters = @[]
  result.resultsDir = DefaultResultsSubdir
  result.testTimeoutSec = 0
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "threads", "j": result.threads = parseInt(p.val)
      of "bin-dir": result.binDir = p.val
      of "build": result.runBuild = true
      of "no-build": result.runBuild = false
      of "summary-json": result.summaryPath = p.val
      of "results-dir": result.resultsDir = p.val
      of "quiet": result.quiet = true
      of "filter": result.filters.add(p.val)
      of "test-timeout":
        try:
          result.testTimeoutSec = parseInt(p.val)
        except ValueError:
          stderr.writeLine "repro_test_runner: --test-timeout requires " &
            "an integer (seconds)"
          quit(2)
        if result.testTimeoutSec < 0:
          result.testTimeoutSec = 0
      of "help", "h":
        echo "repro_test_runner — protocol-level parallel test runner"
        echo "  --threads N         worker count (default $NPROC)"
        echo "  --bin-dir DIR       scan DIR for test binaries"
        echo "  --no-build          skip ``repro build test`` step"
        echo "  --summary-json P    write per-run JSON summary to P"
        echo "  --results-dir DIR   per-test JSON result file dir"
        echo "  --filter GLOB       only run binaries whose stem matches"
        echo "  --quiet             suppress per-test progress lines"
        echo "  --test-timeout=N    per-test idle timeout; output resets it; " &
          "hard ceiling 4xN (seconds, 0=off)"
        quit(0)
      else:
        stderr.writeLine "repro_test_runner: unknown option --" & p.key
        quit(2)
    of cmdArgument:
      stderr.writeLine "repro_test_runner: unexpected positional: " &
        p.key
      quit(2)
  if result.threads <= 0:
    result.threads = 1
  # Child tests routinely invoke ``git -C`` or change their process working
  # directory. Keep both GIT_CONFIG_GLOBAL and protocol result-file paths
  # stable across those operations by resolving the shared results directory
  # once, before any child environment is constructed.
  result.resultsDir = absolutePath(result.resultsDir)

proc matchesFilter(stem: string; filters: seq[string]): bool =
  if filters.len == 0:
    return true
  for f in filters:
    if f.len > 0 and stem.contains(f):
      return true
  false

proc requiresExclusiveExecution(tc: TestCase): bool =
  tc.binaryStem in ExclusiveStems

proc exclusiveRank(tc: TestCase): int =
  ## Latency-sensitive microbenchmarks must run before the heavyweight
  ## self-hosted build cluster. They are exclusive because concurrent load would
  ## pollute the measurement; running them after the build cluster can also
  ## inherit unrelated post-build host settling and daemon cleanup noise.
  if tc.binaryStem == "t_e2e_shell_hook_noop_latency":
    return 0
  result = 10

proc cmpExclusiveTestCase(a, b: TestCase): int =
  result = cmp(exclusiveRank(a), exclusiveRank(b))
  if result == 0:
    result = cmp(a.binaryStem, b.binaryStem)

# Worker threads need plain pointers, not closures, so we use a top-
# level thread proc that receives a ``WorkerArgs`` value.
proc workerMain(args: WorkerArgs) {.thread.} =
  {.cast(gcsafe).}:
    # Test-process registration is synchronized explicitly by
    # activeProcessGroupsLock on POSIX.
    workerLoop(args)

proc findNixStoreLibDir(nameFragment: string; libraryNames: openArray[string]): string =
  ## Return the first already-realized /nix/store library directory whose
  ## basename contains `nameFragment` and that actually contains one of
  ## `libraryNames`. This deliberately avoids picking split `-dev`/`-bin`
  ## outputs that match the package name but cannot satisfy dyld/ld.so.
  if not dirExists("/nix/store"):
    return ""
  for kind, path in walkDir("/nix/store"):
    if kind != pcDir:
      continue
    if path.lastPathPart.contains(nameFragment):
      let libDir = path / "lib"
      if not dirExists(libDir):
        continue
      for libraryName in libraryNames:
        if fileExists(libDir / libraryName):
          return libDir
  ""

proc findLibDirOnEnvPath(pathEnv: string; libraryNames: openArray[string]): string =
  ## Prefer the active dev-shell loader path before scanning /nix/store.
  ## Long-lived workstations often retain older zstd closures; choosing a
  ## random store match can make a newer zstd binary load an older libzstd.
  for dir in pathEnv.split($PathSep):
    if dir.len == 0 or not dirExists(dir):
      continue
    for libraryName in libraryNames:
      if fileExists(dir / libraryName):
        return dir
  ""

proc prependEnvPath(name: string; entries: openArray[string]) =
  var prefix: seq[string]
  for entry in entries:
    if entry.len > 0 and dirExists(entry):
      prefix.add(entry)
  if prefix.len == 0:
    return
  let existing = getEnv(name)
  let sep = $PathSep
  if existing.len > 0:
    putEnv(name, prefix.join(sep) & sep & existing)
  else:
    putEnv(name, prefix.join(sep))

proc ensureNixRuntimeLibraryEnv() =
  let clingoLib =
    if getEnv("CLINGO_LIB").len > 0: getEnv("CLINGO_LIB")
    else:
      let fromEnv = findLibDirOnEnvPath(getEnv("LD_LIBRARY_PATH") & $PathSep &
        getEnv("DYLD_LIBRARY_PATH") & $PathSep &
        getEnv("DYLD_FALLBACK_LIBRARY_PATH"),
        ["libclingo.dylib", "libclingo.so"])
      if fromEnv.len > 0: fromEnv
      else: findNixStoreLibDir("clingo-5.", ["libclingo.dylib", "libclingo.so"])
  let zstdLib =
    if getEnv("ZSTD_LIB").len > 0: getEnv("ZSTD_LIB")
    else:
      let fromEnv = findLibDirOnEnvPath(getEnv("LD_LIBRARY_PATH") & $PathSep &
        getEnv("DYLD_LIBRARY_PATH") & $PathSep &
        getEnv("DYLD_FALLBACK_LIBRARY_PATH"),
        ["libzstd.dylib", "libzstd.so.1", "libzstd.so"])
      if fromEnv.len > 0: fromEnv
      else: findNixStoreLibDir("zstd-1.", ["libzstd.dylib", "libzstd.so.1", "libzstd.so"])
  if clingoLib.len > 0:
    putEnv("CLINGO_LIB", clingoLib)
  if zstdLib.len > 0:
    putEnv("ZSTD_LIB", zstdLib)
  when defined(posix):
    prependEnvPath("DYLD_LIBRARY_PATH", [clingoLib, zstdLib])
    prependEnvPath("DYLD_FALLBACK_LIBRARY_PATH", [clingoLib, zstdLib])
    prependEnvPath("LD_LIBRARY_PATH", [clingoLib, zstdLib])

proc putEnvIfUnsetDir(name, path: string) =
  if getEnv(name).len == 0 and dirExists(path):
    putEnv(name, path)

proc findNixStoreSourceDir(namePart, marker: string): string =
  when defined(posix):
    let storeRoot = "/nix/store"
    if dirExists(storeRoot):
      for kind, path in walkDir(storeRoot):
        if kind == pcDir and namePart in path.lastPathPart and
            fileExists(path / marker):
          return path
  ""

proc ensureWorkspaceSourceEnv(repoRoot: string) =
  ## Nested repro builds compile provider/interface helpers from scratch
  ## projects, often against a /nix/store source snapshot. In that context
  ## config.nims cannot discover developer sibling checkouts via "../...".
  ## Seed the same source-package env vars the dev shell normally carries so
  ## child tests can compile out-of-tree providers without depending on the
  ## runner's launch shell.
  let parent = repoRoot.parentDir
  putEnvIfUnsetDir("REPROBUILD_SOURCE_ROOT", repoRoot)
  putEnvIfUnsetDir("REPRO_TEST_ADAPTERS_SRC",
    parent / "reprobuild-test-adapters" / "src")
  putEnvIfUnsetDir("REPRO_CT_TEST_RUNNER_SRC",
    parent / "reprobuild-ct-test-runner")
  putEnvIfUnsetDir("CODETRACER_SRC", parent / "codetracer" / "src")
  putEnvIfUnsetDir("STACKABLE_HOOKS_SRC",
    parent / "nim-stackable-hooks" / "src")
  putEnvIfUnsetDir("BEARSSL_SRC", parent / "nim-bearssl")
  if getEnv("BEARSSL_SRC").len == 0:
    let bearssl = findNixStoreSourceDir("nim-bearssl-", "bearssl.nim")
    if bearssl.len > 0:
      putEnv("BEARSSL_SRC", bearssl)

proc main() =
  let opts = parseArgs()
  let cwd = getCurrentDir()

  if opts.runBuild:
    if not buildEngine(cwd):
      quit(1)

  let binaries = scanTestBinaries(opts.binDir)
  if binaries.len == 0:
    stderr.writeLine "repro_test_runner: no test binaries found under " &
      opts.binDir
    quit(1)

  ensureDir(opts.resultsDir)

  # Build the work queue: one TestCase per protocol test, or one
  # whole-binary TestCase per non-protocol binary.
  var filteredBinaries: seq[string] = @[]
  for binary in binaries:
    let stem = splitFile(binary).name
    if matchesFilter(stem, opts.filters):
      filteredBinaries.add(binary)
  stderr.writeLine "repro_test_runner: probing " &
    $filteredBinaries.len & " of " & $binaries.len & " binaries"
  var queue = Queue(items: @[])
  initLock(queue.lock)
  var protocolBinaries = 0
  var opaqueBinaries = 0
  var totalCases = 0
  for binary in binaries:
    let stem = splitFile(binary).name
    if not matchesFilter(stem, opts.filters):
      continue
    let probe = probeBinary(binary)
    if probe.protocol:
      inc protocolBinaries
      for (suite, name) in probe.catalog:
        var tc = TestCase(
          binary: binary,
          binaryStem: stem,
          protocolAware: true,
          suite: suite,
          name: name,
          qualifiedName: qualifyName(stem, suite, name))
        queue.items.add(tc)
        inc totalCases
    else:
      inc opaqueBinaries
      var tc = TestCase(
        binary: binary,
        binaryStem: stem,
        protocolAware: false,
        suite: "",
        name: stem,
        qualifiedName: stem)
      queue.items.add(tc)
      inc totalCases

  stderr.writeLine "repro_test_runner: " & $protocolBinaries &
    " protocol-aware, " & $opaqueBinaries & " whole-binary, " &
    $totalCases & " test cases, " & $opts.threads & " threads"

  var resultsLock: Lock
  initLock(resultsLock)
  var results: seq[TestResult] = @[]
  var activeCount: int = 0
  let failFast = getEnv("REPRO_TEST_FAIL_FAST") == "1"

  # Hermetic git config for every test process. Tests run real ``git`` (init /
  # commit / push to local remotes), and the host/runner's user or system git
  # config must NOT leak in: a global ``commit.gpgsign = true`` +
  # ``user.signingkey`` (common on dev boxes / CI runners) makes an otherwise-
  # plain test commit try to sign and fail non-deterministically with "gpg:
  # signing failed: No secret key" — depending on whatever the surrounding shell
  # carries. Pin git's config discovery to a controlled file (identity,
  # init.defaultBranch=main, commit/tag gpgsign=false) and ignore the system
  # config, so plain test commits never sign and the suite is reproducible.
  #
  # NOTE: deliberately do NOT override HOME/GNUPGHOME. Pointing GNUPGHOME at an
  # empty dir makes any gpg invocation (a test that explicitly opts into signing)
  # start gpg-agent and block on pinentry — hanging the whole run until the 4h
  # overall timeout. Neutralizing ``commit.gpgsign`` at the git layer fixes the
  # leak without inviting that hang; tests that genuinely sign manage their own
  # keys.
  #
  # Applied with ``putEnv`` on the main thread BEFORE the env snapshot and before
  # any worker spawns, so it is captured by BOTH spawn paths: the protocol path
  # (which clones the snapshot into a per-child env table) AND the whole-binary
  # path (which spawns with ``env = nil``, inheriting this live process env).
  # Mutating the global env here is safe — single-threaded setup phase; the
  # "no ``putEnv`` after snapshot" rule the worker pool follows still holds.
  block hermeticGitConfig:
    let hermeticGitConfigFile = opts.resultsDir / "hermetic-gitconfig"
    writeFile(hermeticGitConfigFile,
      "[user]\n" &
      "\tname = Reprobuild Test\n" &
      "\temail = reprobuild-test@example.invalid\n" &
      "[init]\n" &
      "\tdefaultBranch = main\n" &
      "[commit]\n" &
      "\tgpgsign = false\n" &
      "[tag]\n" &
      "\tgpgsign = false\n" &
      "[safe]\n" &
      "\tdirectory = *\n")
    putEnv("GIT_CONFIG_GLOBAL", hermeticGitConfigFile)
    putEnv("GIT_CONFIG_NOSYSTEM", "1")

  ensureNixRuntimeLibraryEnv()
  ensureWorkspaceSourceEnv(cwd)

  var exclusiveItems: seq[TestCase] = @[]
  var parallelItems: seq[TestCase] = @[]
  for tc in queue.items:
    if requiresExclusiveExecution(tc):
      exclusiveItems.add(tc)
    else:
      parallelItems.add(tc)
  exclusiveItems.sort(cmpExclusiveTestCase)
  queue.items = parallelItems

  if exclusiveItems.len > 0:
    stderr.writeLine "repro_test_runner: " & $exclusiveItems.len &
      " cases require exclusive execution"

  # Snapshot the process environment exactly once, on the main thread,
  # before any worker is created. From this point on no code in this
  # process touches the global ``environ`` — workers compose per-child
  # env tables by cloning this seq and overriding ``NIMTEST_RESULT_FILE``.
  when defined(posix):
    cleanupTracePath = getEnv(CleanupTraceEnv)
  var baseEnv: seq[tuple[key, value: string]] = @[]
  for (k, v) in envPairs():
    when defined(posix):
      # The optional cleanup trace is runner-only observability. Do not let a
      # test fixture forge the production cleanup events asserted by the
      # integration regression.
      if k != CleanupTraceEnv:
        baseEnv.add((k, v))
    else:
      baseEnv.add((k, v))

  when defined(posix):
    # mkdtemp-backed 0700 namespace prevents stale files from a crashed prior
    # runner (including a reused PID) from impersonating child completion or
    # release records in this invocation.
    processGroupStateDir =
      createTempDir("repro-test-runner-process-groups-", "")
    setFilePermissions(processGroupStateDir,
      {fpUserRead, fpUserWrite, fpUserExec})
    var interruptThread = startInterruptWaiter()

  let wallT0 = epochTime()
  var exclusiveFailed = false

  if exclusiveItems.len > 0 and not (failFast and queue.failFastTriggered):
    for tc in exclusiveItems:
      when defined(posix):
        if interruptedSignal.load(moAcquire) != 0:
          break
      var res: TestResult
      try:
        if tc.protocolAware:
          res = runOneProtocol(tc, opts.resultsDir, baseEnv,
            opts.testTimeoutSec)
        else:
          res = runWholeBinary(tc, opts.resultsDir, baseEnv,
            opts.testTimeoutSec)
      except CatchableError as e:
        res = TestResult(
          testCase: tc,
          status: tsFail,
          durationMs: 0,
          stdout: "repro_test_runner: exclusive worker exception: " &
            e.msg & "\n")
      results.add(res)
      emitProgress(opts.quiet, res)
      if failFast and res.status == tsFail:
        exclusiveFailed = true
        break

  let args = WorkerArgs(
    queue: addr queue,
    resultsLock: addr resultsLock,
    results: addr results,
    resultsDir: opts.resultsDir,
    quiet: opts.quiet,
    failFast: failFast,
    testTimeoutSec: opts.testTimeoutSec,
    activeCount: addr activeCount,
    baseEnv: addr baseEnv)

  let nThreads =
    if queue.items.len == 0 or (failFast and exclusiveFailed):
      0
    else:
      min(opts.threads, queue.items.len)
  var threads = newSeq[Thread[WorkerArgs]](nThreads)
  for i in 0 ..< nThreads:
    createThread(threads[i], workerMain, args)
  joinThreads(threads)

  when defined(posix):
    # `interruptedSignal` is stored before the waiter starts cleanup. Retaining
    # and joining its handle is the explicit cleanup-complete barrier: the
    # runner cannot publish a summary or return 129/130/143 while TERM/KILL of
    # the registered groups is still in flight.
    if interruptedSignal.load(moAcquire) != 0:
      joinThread(interruptThread)
    # Every normal worker path reaps and unregisters its supervisor. Keep a
    # fail-closed final drain in case a worker aborted between those steps.
    if not reapResidualActiveProcessGroups():
      stderr.writeLine(
        "repro_test_runner: fatal: exact owner-token processes survived " &
        "final bounded cleanup; refusing to emit a summary")
      exitnow(1)

  let wallMs = int((epochTime() - wallT0) * 1000)

  writeSummary(opts.summaryPath, results, wallMs, nThreads)

  var passed = 0
  var failed = 0
  var skipped = 0
  for r in results:
    case r.status
    of tsPass: inc passed
    of tsFail: inc failed
    of tsSkip: inc skipped

  stderr.writeLine "repro_test_runner: ran " & $results.len &
    " cases in " & $wallMs & "ms — pass=" & $passed &
    " fail=" & $failed & " skip=" & $skipped &
    " (summary at " & opts.summaryPath & ")"

  when defined(posix):
    cleanupProcessGroupStateDir()
    let receivedSignal = interruptedSignal.load(moAcquire)
    if receivedSignal != 0:
      # Nim's quit() clamps values above 127; use the POSIX primitive so the
      # caller observes the conventional 128+signal status (130/143).
      exitnow(cint(128 + receivedSignal))

  if failed > 0:
    quit(1)
  quit(0)

when defined(posix):
  let internalParams = commandLineParams()
  if internalParams.len > 0 and
      internalParams[0] == ProcessGroupWrapperFlag:
    quit(processGroupWrapperMain(internalParams[1 .. ^1]))

main()
