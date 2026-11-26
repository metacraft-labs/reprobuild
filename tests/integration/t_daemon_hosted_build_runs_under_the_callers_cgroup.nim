## A build routed to the per-user daemon runs its actions under the CALLER's
## cgroup, so a memory cap the caller runs under governs them.
##
## THE DEFECT THIS PINS: the daemon ran a routed build's actions outside
## the caller's memory cap. A build capped with
## ``systemd-run --user --scope -p MemoryMax=16G -- repro build …`` capped only
## the client: the daemon's forked worker, and every action under it, stayed
## in the daemon's own cgroup (a transient service with
## ``MemoryMax=infinity``), so the cap bound a process that used 1.1 GB while
## the build used tens of gigabytes. The fix moves the worker into the cgroup
## the kernel reports for the requesting peer before it runs anything.
##
## THE SHAPE OF THE CASE:
##
##   this test (cgroup T)
##     ├─ repro daemon serve --foreground        -> the daemon lands in T
##     └─ systemd-run --user --scope -p MemoryMax=3G   (a new scope, cgroup C)
##          └─ sh: record C, then exec repro build --daemon=require
##                 └─ (socket) the daemon's worker -> sh action:
##                      cat /proc/self/cgroup > build/cgroup.txt
##
## The action writes the cgroup it really ran in. The case requires it to be
## C -- the caller's scope, whose ``memory.max`` is the 3 GiB the caller asked
## for -- and not T, which is where it ran before the fix (measured: the
## unfixed daemon's action reported T and the first ``check`` below failed).
## The daemon log's ``cgroupPlacement=Moved`` names the arm that ran.
##
## ``--daemon=require`` makes a fallback to an in-process build an error
## rather than a quiet pass: a direct build would ALSO run in C, so without it
## the case could pass without the daemon having built anything.
##
## MOCK POLICY -- none: a real daemon, a real transient scope from the real
## user manager, a real cgroup v2 hierarchy, a real project build. The scope
## is transient and is collected by systemd when its last process exits; no
## persistent unit is registered. Where there is no user manager to ask, or
## no cgroup v2 hierarchy, the case is skipped with that reason: the property
## is about Linux cgroups and cannot be shown without them.

import std/[os, osproc, strtabs, strutils, tempfiles, times, unittest]

import repro_daemon_core
import repro_test_support
import repro_test_support/reasoned_skip

const
  BuildTimeoutMs = 600_000
    ## A cold recipe compile takes minutes on a loaded host; this bounds one
    ## build well inside the suite's per-test limit.
  CallerMemoryMax = 3 * 1024 * 1024 * 1024
    ## The caller's cap. Any value distinct from the test's own works; this
    ## one leaves a recipe compile plenty of room.
  ActionId = "caller-cgroup-probe"

type AssertionFailure = object of CatchableError

template ensure(cond: bool) =
  ## `require` without its `quit`, so the `defer` that stops the daemon runs.
  let ok = cond
  check ok
  if not ok:
    raise newException(AssertionFailure, "precondition failed: " &
      astToStr(cond))

proc repoRoot(): string = getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

proc cgroupOf(procCgroup: string): string =
  for line in procCgroup.splitLines():
    if line.startsWith("0::"):
      return line[3 .. ^1].strip()
  ""

proc cgroupRoot(): string =
  ## Where cgroup v2 is mounted ("" when it is not).
  for line in readFile("/proc/self/mountinfo").splitLines():
    let sep = line.find(" - ")
    if sep > 0 and line[sep + 3 .. ^1].startsWith("cgroup2 "):
      let fields = line[0 ..< sep].splitWhitespace()
      if fields.len >= 5:
        return fields[4]
  ""

proc hostSystemdRun(): seq[string] =
  ## The argv prefix that runs the HOST's ``systemd-run``. The dev shell
  ## exports ``LD_LIBRARY_PATH`` naming its own glibc, and the host binary
  ## then fails to load (``version `GLIBC_ABI_DT_X86_64_PLT' not found``), so
  ## the variable is dropped for that process alone; ``inScope`` gives the
  ## command inside the scope the value back.
  @["env", "-u", "LD_LIBRARY_PATH", "systemd-run"]

proc inScope(): seq[string] =
  ## The argv prefix inside the scope: this process's environment again.
  if existsEnv("LD_LIBRARY_PATH"):
    @["env", "LD_LIBRARY_PATH=" & getEnv("LD_LIBRARY_PATH")]
  else:
    @[]

proc userScopeUnavailable(): string =
  ## Why a transient user scope cannot be made here, or "".
  if findExe("systemd-run").len == 0:
    return "systemd-run is not installed"
  let (output, code) = execCmdEx(quoteShellCommand(hostSystemdRun() &
    @["--user", "--scope", "-q", "--", "true"]))
  if code != 0:
    return "systemd-run --user --scope does not work here (" &
      output.strip() & ")"
  ""

proc socketBound(path: string): bool =
  ## Nim's `fileExists` is false for a socket; `getFileInfo` is not.
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except CatchableError:
    false

proc startPrivateRunQuota(logFile: string):
    tuple[process: Process; env: seq[(string, string)]] =
  ## A `runquotad` of this case's own. A build reaches RunQuota whichever
  ## route it takes, and on a provisioned host the default endpoint is the
  ## host service's socket, which a test user may not be allowed to open
  ## (`Permission denied`); a private one, named with the private scope,
  ## keeps the case independent of how the host is provisioned. Same
  ## arrangement as `t_daemon_parent_prewarm_e2e`.
  let socket = runquotaSocketEndpoint("callercg-" & $getCurrentProcessId())
  let runquota = requireRunQuotaCliBin(repoRoot())
  let runquotad = requireRunQuotaDaemonBin(repoRoot())
  result.process = startProcess("/bin/sh", args = ["-c",
    "exec \"$0\" --socket \"$1\" >" & quoteShell(logFile) & " 2>&1",
    runquotad, socket], options = {})
  for _ in 0 ..< 300:
    if socketBound(socket):
      break
    sleep(100)
  doAssert socketBound(socket), "runquotad did not bind " & socket & "\n" &
    (if fileExists(logFile): readFile(logFile) else: "(no log)")
  result.env = @[
    ("RUNQUOTA_SOCKET", socket),
    ("RUNQUOTA_ENDPOINT_SCOPE", "private"),
    ("RUNQUOTA_BIN", runquota),
    ("RUNQUOTAD_BIN", runquotad),
  ]

proc writeProject(projectRoot: string) =
  ## One non-cacheable action that records the cgroup it runs in.
  createDir(projectRoot)
  let script = "set -eu\nmkdir -p build\ncat /proc/self/cgroup > " &
    "build/cgroup.txt\n"
  writeFile(projectRoot / "reprobuild.nim",
    "import repro_project_dsl\n\n" &
    "package callerCgroupProbe:\n" &
    "  uses:\n" &
    "    \"sh >=1\"\n\n" &
    "  executable shTool:\n" &
    "    name \"sh\"\n" &
    "    cli:\n" &
    "      subcmd \"-c\":\n" &
    "        pos args, seq[string], position = 0\n\n" &
    "    build:\n" &
    "      let action = buildAction(" & ActionId.escape() & ",\n" &
    "        callerCgroupProbe.executable(\"sh\").subcmd_2d_c(\n" &
    "          args = @[" & script.escape() & ", \"sh\"]),\n" &
    "        outputs = @[\"build/cgroup.txt\"],\n" &
    "        cacheable = false)\n" &
    "      defaultBuildAction(action)\n")

when defined(linux):
  suite "daemon-hosted build under the caller's cgroup":
    test "the daemon runs the actions of a capped caller inside its cap":
      let unavailable = userScopeUnavailable()
      if cgroupRoot().len == 0:
        skip("no cgroup v2 hierarchy is mounted")
      elif unavailable.len > 0:
        skip(unavailable)
      else:
        let base = createTempDir("repro-caller-cg-", "")
        let project = base / "project"
        let stateDir = base / "state"
        let logPath = stateDir / "logs" / "repro-daemon.log"
        let cacheRoot = base / "action-cache"
        let callerFile = base / "caller-cgroup.txt"
        let callerMemoryMaxFile = base / "caller-memory-max.txt"
        let endpoint = daemonSocketEndpoint("repro-caller-cg-" &
          $getCurrentProcessId())
        createDir(stateDir)
        createDir(cacheRoot)
        writeProject(project)
        let rq = startPrivateRunQuota(base / "runquotad.log")
        defer:
          if rq.process.running:
            rq.process.terminate()
          discard rq.process.waitForExit()
          rq.process.close()
          try: removeDir(rq.env[0][1].parentDir) except OSError: discard
        var env = rq.env & @[
          ("REPRO_DAEMON_ENDPOINT", endpoint),
          ("REPRO_DAEMON_STATE_DIR", stateDir),
          ("REPROBUILD_ACTION_CACHE_ROOT", cacheRoot),
          ("REPROBUILD_STORE_ROOT", base / "store"),
        ]
        # The recipe compile needs a Nim compiler, named explicitly as the
        # other provider-compiling integration tests do.
        if getEnv("REPRO_NIM_COMPILER").len == 0 and findExe("nim").len > 0:
          env.add(("REPRO_NIM_COMPILER", findExe("nim")))
        var envTable = newStringTable(modeCaseSensitive)
        for key, value in envPairs():
          envTable[key] = value
        for (key, value) in env:
          envTable[key] = value
        try: removeFile(endpoint) except OSError: discard
        let daemon = startProcess(publicReproBin(),
          args = @["daemon", "serve", "--foreground", "--endpoint", endpoint,
            "--state-dir", stateDir, "--log", logPath],
          workingDir = repoRoot(), env = envTable,
          options = {poStdErrToStdOut})
        defer:
          discard runShell(shellCommand(@[publicReproBin(), "daemon", "stop",
            "--endpoint", endpoint, "--state-dir", stateDir, "--log",
            logPath], env), repoRoot(), timeoutMs = 60_000)
          let deadline = epochTime() + 20.0
          while daemon.running and epochTime() < deadline:
            sleep(50)
          if daemon.running:
            daemon.terminate()
          discard daemon.waitForExit()
          daemon.close()
          try: removeFile(endpoint) except OSError: discard
          removeDir(base)
        let daemonLog = proc(): string =
          if fileExists(logPath): readFile(logPath) else: "(no daemon log)"
        let ready = epochTime() + 90.0
        while not queryUserDaemonStatus(endpoint).running and
            epochTime() < ready and daemon.running:
          sleep(50)
        ensure daemon.running
        let daemonCgroup = cgroupOf(readFile("/proc/" & $daemon.processID &
          "/cgroup"))
        checkpoint("daemon cgroup: " & daemonCgroup)

        # The caller: a fresh capped scope, recording its own cgroup, then
        # the build.
        let callerScript = "cat /proc/self/cgroup > " &
          quoteShell(callerFile) & " && cg=$(sed -n 's/^0:://p' " &
          "/proc/self/cgroup) && cat " & quoteShell(cgroupRoot()) &
          "\"$cg/memory.max\" > " & quoteShell(callerMemoryMaxFile) &
          " && exec \"$@\""
        let build = runShell(shellCommand(hostSystemdRun() & @[
          "--user", "--scope", "-q",
          "-p", "MemoryMax=" & $CallerMemoryMax, "--"] & inScope() & @[
          "/bin/sh", "-c", callerScript, "sh",
          publicReproBin(), "build", project,
          "--daemon=require",
          "--tool-provisioning=path",
          "--action-cache-root=" & cacheRoot,
          "--progress=quiet",
          "--log=summary"], env), repoRoot(), BuildTimeoutMs)
        checkpoint("build output:\n" & build.output)
        checkpoint("daemon log:\n" & daemonLog())
        ensure build.code == 0
        let callerCgroup = cgroupOf(readFile(callerFile))
        let actionCgroup = cgroupOf(readFile(project / "build" /
          "cgroup.txt"))
        checkpoint("caller cgroup: " & callerCgroup)
        checkpoint("action cgroup: " & actionCgroup)
        ensure callerCgroup.len > 0
        # The premise: the caller really is somewhere else than the daemon,
        # and really is capped.
        check callerCgroup != daemonCgroup
        check readFile(callerMemoryMaxFile).strip() == $CallerMemoryMax
        # THE PROPERTY: the action ran in the caller's cgroup, under its cap.
        check actionCgroup == callerCgroup
        check actionCgroup != daemonCgroup
        check daemonLog().contains("cgroupPlacement=Moved callerCgroup=" &
          callerCgroup)
else:
  suite "daemon-hosted build under the caller's cgroup":
    test "the daemon runs the actions of a capped caller inside its cap":
      skip("cgroups are a Linux facility; macOS and Windows callers have " &
        "no cgroup to honour")
