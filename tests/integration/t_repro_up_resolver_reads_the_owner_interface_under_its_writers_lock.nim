## A consumer's `repro up` reads the OWNER's lifted interface and its
## provenance stamp together, under the lock the owner's writer holds, so it
## never pairs an artifact with a stamp from a different lift.
##
## `Development-Environments-And-Control-API.md`, "Concurrent Activations Of
## One Project", rule 1 (the resolver locking rule), and reprobuild-pm issue
## 2026-10-25 "`repro up`'s shared-service checks read the dev-env interface
## after the edge lock is released".
##
## MOCKS: NONE. A real workspace with two real projects, a real private daemon
## on a real unix socket, real `repro up` / `repro shell` / `repro down`
## invocations, each compiling the real provider from the real recipe. The
## test itself only takes the owner's real `dev-env.lock` and, while holding
## it, puts the owner's directory in the state a dev-env edge leaves it in
## between publishing a re-extracted interface and stamping it: the NEW
## artifact beside the OLD stamp. That is the writer's own intermediate
## state, produced with the writer's own lock held, not a fake of it.
##
## WHAT DECIDES. The owner's recipe is edited (a comment line: the stamp is
## the content identity of the recipe's source closure, so it moves, while
## the lifted service does not) and re-lifted, so the artifact on disk and
## the recipe agree and the old stamp does not. With the old stamp put back
## under the lock:
##
##   * a resolver that reads by path without the lock pairs the new artifact
##     with the old stamp and refuses the attach as a STALE LIFT, at once,
##     while the lock is still held;
##   * a resolver that reads under the writer's lock waits for it. The test
##     sees it waiting, restores the stamp the writer would have written,
##     releases the lock, and the attach succeeds.
##
## SEEING THE WAITER. On Linux the consumer is observed BLOCKED on the
## owner's lock in `/proc/locks` (a `->` line on the lock file's inode), so
## the stamp is restored only after the consumer has demonstrably reached
## the resolver: the interleaving is deterministic. Other platforms have no
## portable view of a blocked `flock` waiter; there the test waits for the
## consumer's own dev-env to be ready and then a fixed dwell before
## releasing. That cannot make a correct build fail (a waiting resolver
## waits for as long as the lock is held), it only weakens the negative
## control there, and it is said here rather than implied.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, times,
    unittest]

import repro_dev_env_engine
import repro_interface_artifacts
import repro_test_support
import repro_test_support/fixture_processes

const
  OwnerPackage = "uprlockowner"
  ConsumerPackage = "uprlockconsumer"
  ServiceName = "idp"
  SharedIdentity = "com.example.uprlock.idp"
  ConvergedPoint = "relyingParties"
  OwnerMember = "uprlock-owner-rp"
  ConsumerMember = "uprlock-consumer-rp"
  OwnerActivity = "sso"
  ConsumerActivity = "stack"
    ## `--activity` is required: a `devEnv:` body's services are gated by
    ## their declaring activity (see
    ## `t_dss11_cross_process_contribution_reaches_the_instance`).
  WaitBoundSeconds = 600.0
    ## The consumer recompiles its provider before it reaches the resolver,
    ## tens of seconds on a warm host. Only bounds a broken run.
  NonLinuxDwellSeconds = 5.0

proc repoRootDir(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc writeExecutable(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc reproBinary(): string =
  requireBinary(repoRootDir() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  LockCase = object
    tempRoot: string
    workspaceRoot: string
    ownerProject: string
    consumerProject: string
    reproBin: string

proc ownerRecipe(): string =
  "import repro_project_dsl\n" &
  "\n" &
  "package " & OwnerPackage & ":\n" &
  "  devEnv:\n" &
  "    activity sso():\n" &
  "      config:\n" &
  "        " & ConvergedPoint & ": seq[string] = @[\"" & OwnerMember & "\"]\n" &
  "\n" &
  "      service " & ServiceName & ":\n" &
  "        executable executableAtPath(\"/bin/sh\")\n" &
  "        args \"scripts/idp.sh\"\n" &
  "        identity stable \"" & SharedIdentity & "\"\n" &
  "        scope workspace\n" &
  "        compatibility 1\n" &
  "        workingDirectory \".\"\n" &
  "        readiness fileExists(\"state/idp.ready\", timeoutMs = 60000)\n" &
  "        instance:\n" &
  "          lease delayed(3600)\n" &
  "        converge " & ConvergedPoint & "\n" &
  "\n" &
  "    enable sso\n"

proc consumerRecipe(): string =
  "import repro_project_dsl\n" &
  "\n" &
  "package " & ConsumerPackage & ":\n" &
  "  uses:\n" &
  "    \"" & OwnerPackage & "\"\n" &
  "\n" &
  "  devEnv:\n" &
  "    activity stack(sso: SharedServiceHandle[LiftedServiceHandle]):\n" &
  "      service app:\n" &
  "        executable executableAtPath(\"/bin/sh\")\n" &
  "        args \"scripts/app.sh\"\n" &
  "        identity stable \"com.example.uprlock.app\"\n" &
  "        scope project\n" &
  "        workingDirectory \".\"\n" &
  "        readiness fileExists(\"state/app.ready\", timeoutMs = 60000)\n" &
  "\n" &
  "    enable stack(sso = " & OwnerPackage & ".sso." & ServiceName &
    ".shared(\n" &
  "      " & ConvergedPoint & " = append(\"" & ConsumerMember & "\")))\n"

proc prepareCase(): LockCase =
  result.reproBin = reproBinary()
  result.tempRoot = createTempDir("repro-up-resolver-lock-", "")
  try:
    result.workspaceRoot = result.tempRoot / "ws"
    createDir(result.workspaceRoot / ".repro")
    writeFile(result.workspaceRoot / ".repro" / "workspace.toml",
      "schema = \"reprobuild.workspace.local.v1\"\n" &
      "\n[workspace]\nproject = \"uprlock-integration\"\n")
    result.ownerProject = result.workspaceRoot / OwnerPackage
    result.consumerProject = result.workspaceRoot / ConsumerPackage
    writeExecutable(result.ownerProject / "scripts" / "idp.sh",
      "#!/bin/sh\nmkdir -p state\ntouch state/idp.ready\n" &
      "trap 'exit 0' TERM INT\nwhile :; do sleep 1; done\n")
    writeExecutable(result.consumerProject / "scripts" / "app.sh",
      "#!/bin/sh\nmkdir -p state\ntouch state/app.ready\n" &
      "trap 'exit 0' TERM INT\nwhile :; do sleep 1; done\n")
    writeFile(result.ownerProject / "repro.nim", ownerRecipe())
    writeFile(result.consumerProject / "repro.nim", consumerRecipe())
  except CatchableError:
    removeDir(result.tempRoot)
    raise

proc daemonEndpoint(c: LockCase): string =
  daemonSocketEndpoint(c.tempRoot.extractFilename)

proc daemonStateDir(c: LockCase): string = c.tempRoot / "daemon-state"
proc daemonLeaseRoot(c: LockCase): string = c.tempRoot / "lease-state"
proc daemonLogPath(c: LockCase): string =
  c.daemonStateDir / "logs" / "repro-daemon.log"

proc daemonArgs(c: LockCase): seq[string] =
  @["--endpoint", c.daemonEndpoint,
    "--state-dir", c.daemonStateDir,
    "--state-root", c.daemonLeaseRoot,
    "--log", c.daemonLogPath]

proc envFor(c: LockCase): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["REPROBUILD_SOURCE_ROOT"] = repoRootDir()
  result["REPRO_DAEMON_ENDPOINT"] = c.daemonEndpoint
  result["REPRO_DAEMON_STATE_DIR"] = c.daemonStateDir
  # The CLI's own state store, isolated per case (see t_dss11).
  result["XDG_CACHE_HOME"] = c.tempRoot / "cache"
  result["HOME"] = c.tempRoot / "home"
  result["REPROBUILD_PROGRESS"] = "quiet"

proc runProgram(program: string; args: openArray[string]; cwd: string;
                env: StringTableRef): tuple[exitCode: int; output: string] =
  var process = startProcess(program, args = @args, workingDir = cwd,
    env = env, options = {poUsePath, poStdErrToStdOut})
  let output =
    if process.outputStream != nil: process.outputStream.readAll()
    else: ""
  let exitCode = process.waitForExit()
  process.close()
  (exitCode: exitCode, output: output)

proc runRepro(c: LockCase; cwd: string; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  runProgram(c.reproBin, args, cwd, c.envFor())

proc waitForDaemonRunning(c: LockCase; timeoutSeconds = 60.0) =
  let deadline = epochTime() + timeoutSeconds
  var last = ""
  while epochTime() < deadline:
    last = runProgram(c.reproBin, @["daemon", "status"] & c.daemonArgs,
      repoRootDir(), c.envFor()).output
    if last.contains("repro daemon: running"):
      return
    sleep(200)
  raise newException(OSError,
    "the daemon never reported running; last status was:\n" & last)

proc startDaemon(c: LockCase): owned(Process) =
  createDir(c.daemonStateDir)
  try: removeFile(c.daemonEndpoint) except OSError, IOError: discard
  result = startProcess(c.reproBin,
    args = @["daemon", "serve", "--foreground"] & c.daemonArgs,
    workingDir = repoRootDir(), env = c.envFor(),
    options = {poUsePath, poStdErrToStdOut})
  try:
    c.waitForDaemonRunning()
  except CatchableError:
    if result.running():
      result.terminate()
      discard result.waitForExit()
    result.close()
    raise

proc closeDaemon(c: LockCase; daemon: var owned(Process)) =
  try:
    discard runProgram(c.reproBin, @["daemon", "stop"] & c.daemonArgs,
      repoRootDir(), c.envFor())
    try: removeFile(c.daemonEndpoint) except OSError, IOError: discard
  finally:
    if not daemon.isNil:
      if daemon.running():
        daemon.terminate()
        discard daemon.waitForExit()
      daemon.close()

proc ownerInterfacePath(c: LockCase): string =
  ## The owner's dev-env interface: the first candidate the resolver
  ## enumerates (`.repro/dev-env/<segment>/` sorts before `.repro/build/`).
  var found: seq[string] = @[]
  for path in walkPattern(c.ownerProject / ".repro" / "dev-env" / "*" /
      "project-interface.rbsz"):
    found.add(path)
  if found.len != 1:
    raise newException(ValueError,
      "expected exactly one owner dev-env interface, found " & $found)
  found[0]

proc blockedWaiterOn(lockPath: string): bool =
  ## Linux only: whether `/proc/locks` lists a BLOCKED request (`->`) on
  ## `lockPath`'s inode. Format per proc(5): `N: -> FLOCK ADVISORY WRITE
  ## <pid> <maj>:<min>:<inode> <start> <end>`.
  when defined(linux):
    let inode = $getFileInfo(lockPath).id.file
    for line in readFile("/proc/locks").splitLines():
      if not line.contains("->"):
        continue
      for field in line.splitWhitespace():
        if field.count(':') == 2 and field.rsplit(':', 1)[1] == inode:
          return true
    false
  else:
    false

suite "a consumer's resolver reads the owner's interface under its writer's lock":
  var c: LockCase
  var daemon: owned(Process)
  var prepared = false

  teardown:
    if prepared:
      prepared = false
      try:
        discard c.runRepro(c.consumerProject,
          @["down", "--activity=" & ConsumerActivity])
        discard c.runRepro(c.ownerProject,
          @["down", "--activity=" & OwnerActivity])
      finally:
        try:
          c.closeDaemon(daemon)
        finally:
          try:
            reapFixtureProcesses(c.tempRoot)
          finally:
            try: removeDir(c.tempRoot) except OSError, IOError: discard

  setup:
    c = prepareCase()
    prepared = true
    daemon = c.startDaemon()

  test "an owner mid-lift is waited for, not read half-stamped":
    let ownerUp = c.runRepro(c.ownerProject,
      @["up", "--activity=" & OwnerActivity])
    checkpoint("owner up:\n" & ownerUp.output)
    require ownerUp.exitCode == 0

    let interfacePath = c.ownerInterfacePath()
    let stampPath = interfaceArtifactProvenancePath(interfacePath)
    let oldStamp = readFile(stampPath)

    # Move the owner's recipe identity without touching its service, and
    # re-lift it WITHOUT re-materialising: `repro shell` re-derives the
    # dev-env (re-extracting the interface and re-stamping it) and
    # converges nothing.
    writeFile(c.ownerProject / "repro.nim",
      ownerRecipe() & "# edited after the instance was materialised\n")
    let relift = c.runRepro(c.ownerProject,
      @["shell", "--activity=" & OwnerActivity, "--print-env=json"])
    checkpoint("owner re-lift:\n" & relift.output)
    require relift.exitCode == 0
    require c.ownerInterfacePath() == interfacePath
    let newStamp = readFile(stampPath)
    # Positive control: the edit moved the stamp, so the old one describes
    # a lift of a recipe that is no longer on disk.
    require newStamp != oldStamp

    let lockPath = devEnvEdgeLockPath(parentDir(interfacePath))
    var lock = acquireExclusiveFileLock(lockPath)
    var lockHeld = true
    var consumer: Process = nil
    let consumerLog = c.tempRoot / "consumer-up.log"
    defer:
      if lockHeld:
        try: writeFile(stampPath, newStamp) except IOError: discard
        releaseExclusiveFileLock(lock)
      if consumer != nil:
        if consumer.running():
          consumer.terminate()
        discard consumer.waitForExit()
        consumer.close()

    # The writer's intermediate state: the re-extracted artifact, and the
    # stamp of the lift before it.
    writeFile(stampPath, oldStamp)

    consumer = startProcess("/bin/sh",
      args = @["-c", "exec \"$0\" up --activity=" & ConsumerActivity &
        " > \"$1\" 2>&1", c.reproBin, consumerLog],
      workingDir = c.consumerProject, env = c.envFor(), options = {})

    let deadline = epochTime() + WaitBoundSeconds
    var readySince = 0.0
    var sawWaiter = false
    while consumer.running() and epochTime() < deadline:
      when defined(linux):
        if blockedWaiterOn(lockPath):
          sawWaiter = true
          break
      else:
        if readySince == 0.0 and fileExists(consumerLog) and
            readFile(consumerLog).contains("repro dev-env: ready"):
          readySince = epochTime()
        if readySince > 0.0 and epochTime() - readySince >=
            NonLinuxDwellSeconds:
          break
      sleep(100)

    let stillWaiting = consumer.running()
    if not stillWaiting:
      checkpoint("consumer up finished while the owner's writer held its " &
        "lock (exit " & $consumer.peekExitCode() & "):\n" &
        (if fileExists(consumerLog): readFile(consumerLog) else: ""))
    # A resolver that reads under the writer's lock cannot have finished.
    check stillWaiting
    when defined(linux):
      check sawWaiter

    # The writer finishes: it stamps the artifact and releases the lock.
    writeFile(stampPath, newStamp)
    releaseExclusiveFileLock(lock)
    lockHeld = false

    let exitCode = consumer.waitForExit()
    consumer.close()
    consumer = nil
    let output = readFile(consumerLog)
    checkpoint("consumer up (exit " & $exitCode & "):\n" & output)
    check exitCode == 0
    check not output.contains("THE LIFT IS STALE")
    check output.contains("." & ServiceName & ".shared()`")
    check output.contains("deposited 1 contribution for `" &
      ConsumerPackage & "`")
