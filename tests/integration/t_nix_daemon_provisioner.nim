## Test: Python Nix Evaluation Daemon & Client Provisioning Integration
##
## This test validates the full integration of the in-repo Python Nix evaluation
## daemon (`tools/reprobuild-nix-daemon/reprobuild-nix-daemon`) and the build
## engine client's `bakForeignProvision` execution flow.
##
## Scenarios Tested:
##   * Scenario 3.1: Cold Start and Materialisation
##     Spins up the daemon, executes the `bakForeignProvision` action for the local
##     flake, asserts that the output receipt is successfully created containing a valid
##     Nix store path, and ensures that the daemon exits successfully.
##   * Scenario 3.2: Provisioner-Reported Dependencies Capture
##     Asserts that the file paths read during flake evaluation (specifically `flake.nix`
##     and `flake.lock`) are returned as `provisionerReportedInputs` within the action
##     result's evidence, that `monitorReads` stays EMPTY (nothing observed this
##     action; it execs nothing), and that the evidence records
##     `evcForeignProvisionerReport` as the source. DA-1f.
##
## Testing Strategy:
##   * Pure, mock-free integration test running against the Python daemon shim
##     and the build engine's socket client logic.

import std/[unittest, os, osproc, streams, strutils, strtabs, tables,
  tempfiles, times]
import repro_core
import repro_core/dependency_gathering
import repro_build_engine
import repro_dev_env_engine
import repro_interface_artifacts
import repro_tool_profiles

const RepoMarker = "repro.nim"
const FixtureRelRoot = "tests/fixtures/nix-daemon-local-flake"
const FixtureSelector = ".#hello-sh"
const FixtureExecutable = "bin/reprobuild-nix-daemon-fixture"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc findNixDaemon(repoRoot: string): string =
  let envBin = getEnv("REPROBUILD_NIX_DAEMON_BIN")
  for candidate in [
    envBin,
    repoRoot / "build" / "reprobuild-nix-daemon",
    repoRoot / "tools" / "reprobuild-nix-daemon" / "reprobuild-nix-daemon",
    repoRoot.parentDir / "reprobuild-nix-daemon" / "build" /
      "reprobuild-nix-daemon"
  ]:
    if candidate.len == 0:
      continue
    if fileExists(candidate):
      when defined(posix):
        let perms = getFilePermissions(candidate)
        if fpUserExec notin perms and fpGroupExec notin perms and
            fpOthersExec notin perms:
          raise newException(IOError,
            "reprobuild-nix-daemon is not executable: " & candidate)
      return candidate
  raise newException(IOError,
    "reprobuild-nix-daemon missing; set REPROBUILD_NIX_DAEMON_BIN")

proc prepareFixtureRoot(repoRoot: string): string =
  let sourceRoot = repoRoot / FixtureRelRoot
  result = createTempDir("repro-nix-daemon-fixture-", "")
  copyFile(sourceRoot / "flake.nix", result / "flake.nix")
  copyFile(sourceRoot / "flake.lock", result / "flake.lock")
  for args in [
    "init -q",
    "add flake.nix flake.lock"
  ]:
    let (output, code) = execCmdEx("git -C " & quoteShell(result) & " " & args)
    if code != 0:
      raise newException(IOError,
        "failed to prepare Nix fixture git index: " & output)

when defined(posix):
  proc makeNonExecutableDaemonCandidate(): string =
    result = getTempDir() / ("reprobuild-nix-daemon-nonexec-" &
      $getCurrentProcessId())
    writeFile(result, "#!/bin/sh\necho should-not-run\n")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpGroupRead,
      fpOthersRead})

when defined(linux):
  from std/posix import nil

  # A SHARED HELPER UNDER CONCURRENT USE. The cases at the end of the suite
  # run the engine's real client (``executeBuiltinAction`` on a
  # ``bakForeignProvision`` action) against helpers on a private socket
  # directory, with a fake ``nix`` on PATH so a resolution costs milliseconds.

  const StressChildEnv = "REPRO_NIXD_STRESS_CHILD"
  const StressRequests = 12

  proc foreignProvisionAction(selector, receipt, cwd: string): BuildAction =
    BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakForeignProvision,
      id: "test.foreign.nix.shared." & receipt.extractFilename,
      argv: @["nix", selector],
      outputs: @[receipt],
      cwd: cwd,
      dependencyPolicy: DependencyGatheringPolicy(kind: dgAutomaticMonitor))

  if existsEnv(StressChildEnv):
    # One of several client PROCESSES (the helper is shared between
    # processes, not threads). Prints one line per request. Every request
    # names its own selector, so each one is a resolution the helper must
    # run rather than a cache hit.
    let workDir = getEnv(StressChildEnv)
    let tag = $getCurrentProcessId()
    for i in 0 ..< StressRequests:
      let receipt = workDir / ("receipt-" & tag & "-" & $i)
      let res = executeBuiltinAction(foreignProvisionAction(
        "fake#tool-" & tag & "-" & $i, receipt, workDir))
      if res.status == asSucceeded and dirExists(readFile(receipt).strip()):
        echo "OK"
      else:
        echo "FAIL ", res.stderr.strip().replace("\n", " | ")
    quit(0)

  type SharedHelperFixture = object
    root: string        ## scratch: fake nix, fake store, wrapper, pid files
    socketDir: string   ## short: sun_path is 108 bytes
    saved: seq[(string, string)]

  proc setEnvSaving(f: var SharedHelperFixture; key, value: string) =
    f.saved.add((key, getEnv(key, "\0unset")))
    putEnv(key, value)

  proc ownHelperPids(f: SharedHelperFixture): seq[int] =
    ## Helpers THIS fixture started: recorded by its wrapper, and still
    ## naming its private socket directory on their command line.
    for kind, path in walkDir(f.root / "pids"):
      let pid = try: parseInt(path.extractFilename) except ValueError: 0
      if pid <= 0:
        continue
      try:
        if f.socketDir in readFile("/proc/" & $pid & "/cmdline"):
          result.add(pid)
      except IOError, OSError:
        discard

  proc openSharedHelperFixture(startDelay = "0"; idleMs = 2_000):
      SharedHelperFixture =
    result.root = createTempDir("repro-nixd-shared-", "")
    result.socketDir = createTempDir("rnd-", "", "/tmp")
    let daemonPath = findNixDaemon(findRepoRoot())
    let fakeBin = result.root / "bin"
    createDir(fakeBin)
    createDir(result.root / "pids")
    createDir(result.root / "store")
    # Each resolution takes a moment, so requests are in flight when a
    # helper is stopped.
    writeFile(fakeBin / "nix", "#!/bin/sh\nfor last; do :; done\nsleep 0.2\n" &
      "d=" & quoteShell(result.root / "store") &
      "/$(printf %s \"$last\" | tr -c 'a-zA-Z0-9' '-')-$$\n" &
      "mkdir -p \"$d/bin\" && printf '%s\\n' \"$d\"\n")
    setFilePermissions(fakeBin / "nix", {fpUserRead, fpUserWrite, fpUserExec})
    let wrapper = result.root / "reprobuild-nix-daemon"
    writeFile(wrapper, "#!/bin/sh\necho $$ > " &
      quoteShell(result.root / "pids") & "/$$\nsleep " & startDelay &
      "\nexec " & quoteShell(daemonPath) & " \"$@\" --idle-exit-ms=" &
      $idleMs & "\n")
    setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
    result.setEnvSaving("PATH", fakeBin & PathSep & getEnv("PATH"))
    result.setEnvSaving("REPROBUILD_NIX_DAEMON_BIN", wrapper)
    result.setEnvSaving(NixDaemonSocketDirEnv, result.socketDir)
    result.setEnvSaving("USER", "repro-nixd-shared-" & $getCurrentProcessId())

  proc close(f: var SharedHelperFixture) =
    for pid in f.ownHelperPids():
      discard posix.kill(posix.Pid(pid), posix.SIGKILL)
    for i in countdown(f.saved.high, 0):
      let (key, value) = f.saved[i]
      if value == "\0unset": delEnv(key) else: putEnv(key, value)
    removeDir(f.root)
    removeDir(f.socketDir)

suite "Nix Evaluation Daemon and Foreign Provisioner Integration Tests":

  test "dev env repeated uses share acquisition but distinct selectors do not":
    let fixtureRoot = prepareFixtureRoot(findRepoRoot())
    defer: removeDir(fixtureRoot)
    let useDef = InterfaceToolUse(packageSelector: "sh", rawConstraint: "sh",
      nixProvisioning: @[InterfaceNixProvisioning(
        selector: FixtureSelector, executablePath: FixtureExecutable)])
    var other = useDef
    other.nixProvisioning = @[InterfaceNixProvisioning(
      selector: ".#different-sh", executablePath: FixtureExecutable)]
    let actions = devEnvNixProvisioningActions([useDef, useDef, other],
      tpmNix, fixtureRoot, fixtureRoot)
    check actions.len == 2
    check actions[0].id != actions[1].id
    check actions[0].outputs != actions[1].outputs
    check actions[0].argv == @["nix", FixtureSelector]
    let repeated = devEnvNixProvisioningActions([useDef, useDef],
      tpmNix, fixtureRoot, fixtureRoot)
    check repeated.len == 1
    check repeated[0].id == actions[0].id
    check devEnvNixProvisioningActions([useDef], tpmPathOnly,
      fixtureRoot, fixtureRoot).len == 0

  when defined(posix):
    test "production provisioner rejects non-executable REPROBUILD_NIX_DAEMON_BIN":
      let repoRoot = findRepoRoot()
      let fixtureRoot = prepareFixtureRoot(repoRoot)
      defer: removeDir(fixtureRoot)
      let sentinel = makeNonExecutableDaemonCandidate()
      defer: removeFile(sentinel)
      let previousDaemonBin = getEnv("REPROBUILD_NIX_DAEMON_BIN")
      putEnv("REPROBUILD_NIX_DAEMON_BIN", sentinel)
      defer: putEnv("REPROBUILD_NIX_DAEMON_BIN", previousDaemonBin)
      let previousUser = getEnv("USER")
      putEnv("USER", "repro-nix-nonexec-" & $getCurrentProcessId())
      defer: putEnv("USER", previousUser)

      let receiptFile = getTempDir() / ("reprobuild-nonexec-receipt-" &
        $getCurrentProcessId())
      if fileExists(receiptFile):
        removeFile(receiptFile)

      let action = BuildAction(
        governingLockIdentity: lockIdentityOutsideSolvedGraph(),
        kind: bakForeignProvision,
        id: "test.foreign.nix.nonexec-daemon",
        argv: @["nix", FixtureSelector],
        outputs: @[receiptFile],
        cwd: fixtureRoot,
        dependencyPolicy: DependencyGatheringPolicy(kind: dgAutomaticMonitor)
      )

      let res = executeBuiltinAction(action)
      check res.status == asFailed
      check "REPROBUILD_NIX_DAEMON_BIN exists but is not executable" in
        res.stderr
      check not fileExists(receiptFile)

    when defined(linux):
      test "failed daemon startup does not leak connection or process descriptors":
        # A real false process supplies the startup failure. Every connection
        # reaches the kernel; no mock daemon or socket is involved.
        let previousUser = getEnv("USER")
        let previousDaemon = getEnv("REPROBUILD_NIX_DAEMON_BIN")
        putEnv("USER", "repro-failed-start-" & $getCurrentProcessId())
        putEnv("REPROBUILD_NIX_DAEMON_BIN", findExe("false"))
        defer:
          putEnv("USER", previousUser)
          putEnv("REPROBUILD_NIX_DAEMON_BIN", previousDaemon)
        proc descriptorCount(): int =
          for entry in walkDir("/proc/self/fd"):
            inc result
        let before = descriptorCount()
        let action = BuildAction(
          governingLockIdentity: lockIdentityOutsideSolvedGraph(),
          kind: bakForeignProvision,
          id: "test.foreign.nix.failed-start",
          argv: @["nix", FixtureSelector],
          outputs: @[getTempDir() / "repro-failed-start-receipt"],
          cwd: findRepoRoot(),
          dependencyPolicy: DependencyGatheringPolicy(kind: dgAutomaticMonitor))
        for attempt in 0 .. 2:
          let res = executeBuiltinAction(action)
          check res.status == asFailed
          check "Failed to connect or spawn" in res.stderr
        check descriptorCount() == before

    test "direct all-output fallback strips provisioned loader paths":
      let repoRoot = findRepoRoot()
      let daemonPath = findNixDaemon(repoRoot)
      let tempRoot = createTempDir("repro-nix-direct-loader-env-", "")
      defer: removeDir(tempRoot)

      let shellPath = getEnv("SHELL")
      if not shellPath.startsWith("/nix/store/") or
          not fileExists(shellPath) or parentDir(shellPath).extractFilename != "bin":
        skip()
      else:
        let shellStore = parentDir(parentDir(shellPath))
        let executablePath = relativePath(shellPath, shellStore)
        let executableName = shellPath.extractFilename
        let fakeBin = tempRoot / "bin"
        let record = tempRoot / "nix-env.txt"
        createDir(fakeBin)
        let fakeNix = fakeBin / "nix"
        writeFile(fakeNix, @[
          "#!/bin/sh",
          "printf 'LD_LIBRARY_PATH=[%s]\\n' \"${LD_LIBRARY_PATH:-}\" >> " &
            quoteShell(record),
          "if printf '%s\\n' \"$*\" | grep -Fq '^*'; then",
          "  printf '%s\\n' " & quoteShell(shellStore),
          "else",
          "  printf '%s\\n' " & quoteShell(tempRoot),
          "fi",
          ""
        ].join("\n"))
        setFilePermissions(fakeNix, {fpUserRead, fpUserWrite, fpUserExec})

        let uniqueUser = "repro-nix-direct-loader-" & $getCurrentProcessId()
        # The client names the socket (``--socket-path``, keyed by the
        # helper's identity), so the wrapper passes its arguments through.
        let daemonWrapper = tempRoot / "reprobuild-nix-daemon"
        writeFile(daemonWrapper, "#!/bin/sh\nexec " & quoteShell(daemonPath) &
          " \"$@\"\n")
        setFilePermissions(daemonWrapper,
          {fpUserRead, fpUserWrite, fpUserExec})

        let previousPath = getEnv("PATH")
        let previousLoaderPath = getEnv("LD_LIBRARY_PATH")
        let previousDaemonBin = getEnv("REPROBUILD_NIX_DAEMON_BIN")
        let previousUser = getEnv("USER")
        putEnv("PATH", fakeBin & PathSep & previousPath)
        putEnv("LD_LIBRARY_PATH", tempRoot / "target-libraries")
        putEnv("REPROBUILD_NIX_DAEMON_BIN", daemonWrapper)
        putEnv("USER", uniqueUser)
        let socketPath = nixDaemonSocketPath(nixDaemonHelperKey(daemonWrapper))
        defer:
          putEnv("PATH", previousPath)
          if previousLoaderPath.len > 0:
            putEnv("LD_LIBRARY_PATH", previousLoaderPath)
          else:
            delEnv("LD_LIBRARY_PATH")
          putEnv("REPROBUILD_NIX_DAEMON_BIN", previousDaemonBin)
          putEnv("USER", previousUser)
          discard execCmd("pkill -f -u $USER " & quoteShell(socketPath) &
            " || true")
          removeFile(socketPath)

        var useDef = InterfaceToolUse(
          rawConstraint: "loader-fallback",
          packageSelector: "loader-fallback@1.0.0",
          executableName: executableName,
          location: SourceLocation(file: "fixture", line: 1))
        useDef.nixProvisioning = @[InterfaceNixProvisioning(
          packageName: "loader-fallback",
          selector: "fake#loader-fallback",
          executablePath: executablePath,
          packageId: "loader-fallback.1.0.0",
          lockIdentity: "fake#loader-fallback",
          location: SourceLocation(file: "fixture", line: 2))]

        let profile = resolveNixTool(useDef)
        check profile.resolvedExecutablePath == shellPath
        let recorded = readFile(record)
        check recorded.count("LD_LIBRARY_PATH=[]") == 2
        check "target-libraries" notin recorded

  test "Scenario 3.1 & 3.2: Cold start, resolution, and dependency tracking":
    let repoRoot = findRepoRoot()
    let fixtureRoot = prepareFixtureRoot(repoRoot)
    defer: removeDir(fixtureRoot)
    let daemonPath = findNixDaemon(repoRoot)
    let previousDaemonBin = getEnv("REPROBUILD_NIX_DAEMON_BIN")
    putEnv("REPROBUILD_NIX_DAEMON_BIN", daemonPath)
    defer: putEnv("REPROBUILD_NIX_DAEMON_BIN", previousDaemonBin)
    let previousUser = getEnv("USER")
    putEnv("USER", "repro-nix-provisioner-" & $getCurrentProcessId())
    defer: putEnv("USER", previousUser)

    # Assert daemon binary is built and present
    check fileExists(daemonPath)

    # Prepare build receipt path
    let receiptDir = repoRoot / "build" / "test-foreign"
    let receiptFile = receiptDir / "reprobuild.receipt"
    if fileExists(receiptFile):
      removeFile(receiptFile)
    createDir(receiptDir)

    # Setup the bakForeignProvision action. Use a lightweight package already
    # present in the dev shell; this verifies real materialization without
    # rebuilding the full repo package.
    let action = BuildAction(
      governingLockIdentity: lockIdentityOutsideSolvedGraph(),
      kind: bakForeignProvision,
      id: "test.foreign.nix.resolve",
      argv: @["nix", FixtureSelector],
      outputs: @[receiptFile],
      cwd: fixtureRoot,
      dependencyPolicy: DependencyGatheringPolicy(kind: dgAutomaticMonitor)
    )

    # Execute the builtin action (which spawns the daemon and performs socket query)
    let res = executeBuiltinAction(action)

    # Assert success status
    if res.status != asSucceeded:
      echo "=== Action Failed ==="
      echo "Stdout: ", res.stdout
      echo "Stderr: ", res.stderr
      echo "Reason: ", res.reason
      echo "====================="

    check res.status == asSucceeded
    check res.exitCode == 0

    # Verify receipt output contains a valid Nix store path
    check fileExists(receiptFile)
    let storePath = readFile(receiptFile).strip()
    check storePath.startsWith("/nix/store/")
    check fileExists(storePath / FixtureExecutable)
    checkpoint("Resolved store path: " & storePath)

    # Verify the daemon-reported dependencies carry the actual local flake
    # inputs used for resolution.
    #
    # DA-1f — THE CHANNEL IS `provisionerReportedInputs`, NOT `monitorReads`,
    # and the difference is the subject rather than a rename. These paths come
    # out of a JSON reply this process parsed; io-mon observed none of them
    # and could not have, because the action execs nothing — it opens a unix
    # socket and `reprobuild-nix-daemon` evaluates on its behalf. Putting them
    # in the monitor's channel made a derived peer attribution
    # indistinguishable from an observation, which is the shape
    # `reprobuild-specs/Dependency-Observation-Attribution.md` rule 7 forbids.
    # The report is kept — it is class-3 DERIVED attribution and strictly
    # better than anything a monitor could supply here — and it is named.
    let reads = res.evidence.provisionerReportedInputs
    check reads.len > 0

    var foundFlakeNix = false
    var foundFlakeLock = false
    for path in reads:
      if path == "flake.nix":
        foundFlakeNix = true
      if path == "flake.lock":
        foundFlakeLock = true

    check foundFlakeNix
    check foundFlakeLock
    checkpoint("Provisioner-reported dependencies: " & $reads)

    # THE OTHER HALF, AND THE ONE A RENAME WOULD NOT HAVE BOUGHT. The monitor
    # channel must be EMPTY: nothing observed this action, and the engine must
    # not claim otherwise. Re-pointing the assignment back at `monitorReads`
    # reddens here even though every assertion above would still pass.
    check res.evidence.monitorReads.len == 0
    # And the report says who filled it. A set that is populated but unmarked
    # is the state DA-1f found everywhere else in this engine.
    check evcForeignProvisionerReport in res.evidence.evidenceProvenance
    check evcMonitorCapture notin res.evidence.evidenceProvenance

    # Clean up receipt
    removeFile(receiptFile)

  when defined(linux):
    test "a helper slower to start than two seconds is waited for":
      # Measured on a host running a full suite (load ~180 on 32 cores): the
      # Python helper took 0.26-3.3 s from exec to listening. The client
      # waited a fixed 2 s and reported "Failed to connect or spawn
      # reprobuild-nix-daemon" for every slower start.
      var f = openSharedHelperFixture(startDelay = "3")
      defer: f.close()
      let receipt = f.root / "receipt-slow"
      let res = executeBuiltinAction(foreignProvisionAction("fake#slow",
        receipt, f.root))
      checkpoint(res.stderr)
      check res.status == asSucceeded
      check dirExists(readFile(receipt).strip())

    test "the helper socket is keyed by the helper's identity":
      # Every worktree, package and CI checkout resolves its own helper file,
      # and one socket per user let whichever started first answer for all
      # of them, older semantics included.
      let root = createTempDir("repro-nixd-key-", "")
      defer: removeDir(root)
      writeFile(root / "a", "#!/bin/sh\necho a\n")
      writeFile(root / "b", "#!/bin/sh\necho b\n")
      writeFile(root / "c", "#!/bin/sh\necho a\n")
      let keyA = nixDaemonHelperKey(root / "a")
      check keyA.len == 16
      check keyA == nixDaemonHelperKey(root / "c")
      check keyA != nixDaemonHelperKey(root / "b")
      check nixDaemonHelperKey(root / "missing") == ""
      let previousDir = getEnv(NixDaemonSocketDirEnv)
      putEnv(NixDaemonSocketDirEnv, root)
      defer: putEnv(NixDaemonSocketDirEnv, previousDir)
      check nixDaemonSocketPath(keyA).parentDir == root
      check keyA in nixDaemonSocketPath(keyA).extractFilename
      check nixDaemonSocketPath(keyA) != nixDaemonSocketPath(
        nixDaemonHelperKey(root / "b"))

    test "concurrent clients are served while helpers are stopped under them":
      # Several client processes share one helper while it is stopped by pid
      # (TERM, INT and KILL in turn) every few hundred milliseconds -- what a
      # suite runner does to the helper each time the case that started it
      # finishes, and what an agent stopping "its" helper does to everyone.
      var f = openSharedHelperFixture(idleMs = 400)
      defer: f.close()
      var children: seq[Process] = @[]
      for i in 0 ..< 4:
        var env = newStringTable(modeCaseSensitive)
        for key, value in envPairs():
          env[key] = value
        env[StressChildEnv] = f.root
        children.add(startProcess(getAppFilename(), env = env,
          options = {poStdErrToStdOut}))
      # Each helper is stopped once it has been up for 1.5-3.9 s -- the
      # lifetime of the case that happened to start it. A stopper that ends
      # every helper before it can finish a request leaves nothing that could
      # serve, which is not the situation being modelled.
      var signals = 0
      var firstSeen = initTable[int, float]()
      while true:
        var anyRunning = false
        for child in children:
          if child.running:
            anyRunning = true
        if not anyRunning:
          break
        sleep(100)
        let now = epochTime()
        for pid in f.ownHelperPids():
          if pid notin firstSeen:
            firstSeen[pid] = now
          elif now - firstSeen[pid] >= 1.5 + float(pid mod 4) * 0.8:
            let sig = [posix.SIGTERM, posix.SIGINT, posix.SIGKILL][signals mod 3]
            if posix.kill(posix.Pid(pid), sig) == 0:
              inc signals
      var ok = 0
      var failures: seq[string] = @[]
      for child in children:
        for line in child.outputStream.readAll().splitLines():
          if line == "OK":
            inc ok
          elif line.len > 0:
            failures.add(line)
        discard child.waitForExit()
        child.close()
      checkpoint("helpers signalled " & $signals & " times; failures: " &
        failures.join("\n"))
      check signals > 0
      check failures.len == 0
      check ok == 4 * StressRequests
