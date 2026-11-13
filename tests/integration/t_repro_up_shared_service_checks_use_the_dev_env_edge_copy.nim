## `repro up` must take every shared-service fact from the copy of the project
## interface that its dev-env edge decoded under the edge lock, never from the
## shared `project-interface.rbsz` that a concurrent activation of the same
## project may replace once that lock is released.
##
## `Development-Environments-And-Control-API.md`, "Concurrent Activations Of
## One Project", rule 1, and reprobuild-pm issue 2026-10-25 "`repro up`'s
## shared-service checks read the dev-env interface after the edge lock is
## released".
##
## MOCKS: NONE. The real CLI, a real private daemon on a real unix socket with
## its own state dir and state root, a real recipe, a real provider compile and
## real `sh` service instances. The only thing the fixture adds is a
## rendezvous INSIDE the first shared instance's own command, which turns the
## timing window into a deterministic interleaving.
##
## THE WINDOW. `repro up` converges the shared instances its recipe declares
## one after another, after its dev-env edge has returned and released
## `<outDir>/dev-env.lock`, and it waits for each instance's declared
## readiness before it turns to the next one. The recipe declares two shared
## services. Whichever instance the daemon starts first holds its readiness
## until the test releases it, so run A is parked between its two converges:
##
##   * while A is parked, the test edits the recipe to drop the typed
##     `service` block of the OTHER service (the one A has not converged yet)
##     and runs `repro exec` in the same project (run B). B takes the
##     released edge lock and re-extracts the interface into the same shared
##     file. A positive control decodes that file and requires the other
##     service to be gone from it;
##   * the test then releases the first instance, and A converges the other
##     service. Its dev-env artifact (decoded under the lock) still declares
##     it, so A must lift its fingerprint, identity and scope from the
##     interface it extracted with that artifact. Read by path, the
##     interface is B's, which does not declare the service, and A fails.
##
## The edit leaves the dev-env artifact's own service declarations alone (the
## `servicePlaceholder`s stay), so the only thing that differs between A's
## extraction and B's is the interface that `repro up` lifts from.
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, times,
    typedthreads, unittest]

import repro_interface_artifacts
import repro_test_support
import repro_test_support/fixture_processes

const
  PackageName = "upedgecopy"
  Services = ["alpha", "beta"]
  RendezvousBoundSeconds = 600
    ## How long the first instance holds its readiness at most. Run B
    ## recompiles the provider for the edited recipe, which is tens of
    ## seconds on a warm host; the bound only has to outlast that.
  ReadinessTimeoutMs = 900_000
    ## Longer than the rendezvous bound, so that `repro up`'s readiness wait
    ## is never what ends the hold.

proc repoRootDir(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRootDir() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  UpCase = object
    tempRoot: string
    project: string
    rendezvous: string
    reproBin: string

proc serviceScript(rendezvous: string): string =
  ## Every shared instance runs this script with its service name as `$1`.
  ## The FIRST one to start (an atomic `mkdir`) records its name and holds
  ## its readiness marker until the test writes `release`; every later one
  ## is ready at once. Which service the daemon starts first is not this
  ## test's business, so the test reads it back instead of assuming it.
  "#!/bin/sh\n" &
  "rv=" & quoteShell(rendezvous) & "\n" &
  "if mkdir \"$rv/first\" 2>/dev/null; then\n" &
  "  printf '%s' \"$1\" > \"$rv/first-name.tmp\"\n" &
  "  mv \"$rv/first-name.tmp\" \"$rv/first-name\"\n" &
  "  i=0\n" &
  "  while [ ! -e \"$rv/release\" ] && [ \"$i\" -lt " &
    $(RendezvousBoundSeconds * 10) & " ]; do\n" &
  "    sleep 0.1\n" &
  "    i=$((i + 1))\n" &
  "  done\n" &
  "fi\n" &
  "touch \"$rv/$1.ready\"\n" &
  "trap 'exit 0' TERM INT\n" &
  "while :; do sleep 1; done\n"

proc recipe(c: UpCase; typedServices: openArray[string]): string =
  ## Two shared services, each declared through both channels a shared
  ## service has today (see `t_l7_repro_up_converges_on_one_shared_instance`):
  ## the typed `service` block is what the interface lift lowers -- the
  ## fingerprint, identity and scope `repro up` reads -- and the `devEnv:`
  ## `servicePlaceholder` carries the command and the `instance` block.
  ## `typedServices` names the typed blocks to emit; the placeholders are
  ## always emitted.
  result = "import repro_project_dsl\n" &
    "\n" &
    "package " & PackageName & ":\n" &
    "  executable svcBin:\n" &
    "    build:\n" &
    "      output(\"bin/svc\")\n" &
    "\n"
  for name in typedServices:
    result.add "  service " & name & ":\n" &
      "    executable svcBin\n" &
      "    identity stable \"com.example.upedgecopy." & name & "\"\n" &
      "    scope project\n" &
      "    compatibility 1\n" &
      "\n"
  result.add "  devEnv:\n" &
    "    activity \"default\"\n"
  for name in Services:
    let metadata = %*{
      "schemaId": "reprobuild.dev-session.service.v1",
      "command": ["sh", c.rendezvous / "svc.sh", name],
      "cwd": ".",
      "readiness": {"kind": "fileExists",
        "path": c.rendezvous / (name & ".ready"),
        "timeoutMs": ReadinessTimeoutMs},
      "instance": {"environment": "dev", "lease": "delayed",
        "ttlSeconds": 3600}}
    result.add "    servicePlaceholder \"" & name & "\",\n" &
      "      metadata = \"\"\"" & $metadata & "\"\"\",\n" &
      "      activities = [\"default\"]\n"

proc prepareCase(): UpCase =
  result.reproBin = reproBinary()
  result.tempRoot = createTempDir("repro-up-edge-copy-", "")
  try:
    result.project = result.tempRoot / "p"
    result.rendezvous = result.tempRoot / "rendezvous"
    createDir(result.project)
    createDir(result.rendezvous)
    writeFile(result.rendezvous / "svc.sh", serviceScript(result.rendezvous))
    writeFile(result.project / "reprobuild.nim", result.recipe(Services))
  except CatchableError:
    removeDir(result.tempRoot)
    raise

proc daemonEndpoint(c: UpCase): string =
  daemonSocketEndpoint(c.tempRoot.extractFilename)

proc daemonStateDir(c: UpCase): string = c.tempRoot / "daemon-state"
proc daemonLeaseRoot(c: UpCase): string = c.tempRoot / "lease-state"
proc daemonLogPath(c: UpCase): string =
  c.daemonStateDir / "logs" / "repro-daemon.log"

proc daemonArgs(c: UpCase): seq[string] =
  @["--endpoint", c.daemonEndpoint,
    "--state-dir", c.daemonStateDir,
    "--state-root", c.daemonLeaseRoot,
    "--log", c.daemonLogPath]

proc envFor(c: UpCase): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["REPROBUILD_SOURCE_ROOT"] = repoRootDir()
  result["REPRO_DAEMON_ENDPOINT"] = c.daemonEndpoint
  result["REPRO_DAEMON_STATE_DIR"] = c.daemonStateDir

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

proc runRepro(c: UpCase; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  runProgram(c.reproBin, args, c.project, c.envFor())

proc stopDaemon(c: UpCase) =
  discard runProgram(c.reproBin, @["daemon", "stop"] & c.daemonArgs,
    repoRootDir(), c.envFor())
  try: removeFile(c.daemonEndpoint) except OSError, IOError: discard

proc waitForDaemonRunning(c: UpCase; timeoutSeconds = 60.0) =
  let deadline = epochTime() + timeoutSeconds
  var last = ""
  while epochTime() < deadline:
    let status = runProgram(c.reproBin,
      @["daemon", "status"] & c.daemonArgs, repoRootDir(), c.envFor())
    last = status.output
    if last.contains("repro daemon: running"):
      return
    sleep(200)
  raise newException(OSError,
    "the daemon never reported running; last status was:\n" & last)

proc startDaemon(c: UpCase): owned(Process) =
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

proc closeDaemon(c: UpCase; daemon: var owned(Process)) =
  try:
    c.stopDaemon()
  finally:
    if not daemon.isNil:
      if daemon.running():
        daemon.terminate()
        discard daemon.waitForExit()
      daemon.close()

type
  OutputDrain = object
    ## Run A's merged stdout/stderr, read to its end on a thread of its own
    ## while the test drives run B. Read only after A exits, A could block on
    ## a full pipe while the test waits for its rendezvous.
    stream: Stream
    output: string

proc drain(target: ptr OutputDrain) {.thread.} =
  ## Read `target.stream` to its end. The main thread does not touch
  ## `target` again until it has joined this thread.
  {.cast(gcsafe).}:
    target.output = target.stream.readAll()

proc liftedServiceNames(interfacePath: string): seq[string] =
  for service in readInterfaceArtifact(interfacePath).projectInterface.
      publicServices:
    result.add(service.name)

suite "`repro up` converges shared services from the edge's interface copy":
  var c: UpCase
  var daemon: owned(Process)
  var prepared = false

  teardown:
    if prepared:
      prepared = false
      # Release the rendezvous whatever happened, so no instance is left
      # holding it while teardown stops everything.
      try: writeFile(c.rendezvous / "release", "") except IOError: discard
      try:
        discard c.runRepro(@["down"])
      finally:
        try:
          c.closeDaemon(daemon)
        finally:
          try:
            let survivors = fixtureProcessIds(c.tempRoot)
            checkpoint("case-owned processes alive after `repro down` and " &
              "closeDaemon: " & $survivors)
            reapFixtureProcesses(c.tempRoot)
            check fixtureProcessIds(c.tempRoot).len == 0
          finally:
            try: removeDir(c.tempRoot) except OSError, IOError: discard

  setup:
    # Registration also runs for --list/--list-json; only an executed case
    # allocates the project or starts a daemon.
    c = prepareCase()
    prepared = true
    daemon = c.startDaemon()

  test "a concurrent re-extraction between two converges does not reach repro up":
    var a = startProcess(c.reproBin, args = @["up"], workingDir = c.project,
      env = c.envFor(), options = {poUsePath, poStdErrToStdOut})
    var aDrain = OutputDrain(stream: a.outputStream)
    var aThread: Thread[ptr OutputDrain]
    createThread(aThread, drain, addr aDrain)
    var aJoined = false
    defer:
      if not aJoined:
        try: writeFile(c.rendezvous / "release", "") except IOError: discard
        joinThread(aThread)
        discard a.waitForExit()
        a.close()

    # Wait for the first instance to park run A between its two converges.
    let deadline = epochTime() + float(RendezvousBoundSeconds)
    while not fileExists(c.rendezvous / "first-name") and a.running() and
        epochTime() < deadline:
      sleep(100)
    if not fileExists(c.rendezvous / "first-name"):
      writeFile(c.rendezvous / "release", "")
      joinThread(aThread)
      aJoined = true
      checkpoint("run A (exit " & $a.waitForExit() & "):\n" & aDrain.output)
      a.close()
    require fileExists(c.rendezvous / "first-name")
    let first = readFile(c.rendezvous / "first-name").strip()
    require first in Services
    let other = if first == Services[0]: Services[1] else: Services[0]
    checkpoint("the daemon started `" & first & "` first; `" & other &
      "` is converged after the rendezvous")

    # Run B: the same project and activity, re-extracting the interface into
    # the same shared file once A has released the edge lock.
    writeFile(c.project / "reprobuild.nim", c.recipe([first]))
    let b = c.runRepro(@["exec", c.project, "--", "sh", "-c", "exit 0"])
    checkpoint("run B (exit " & $b.exitCode & "):\n" & b.output)
    require b.exitCode == 0

    # Positive control: B really replaced the interface A's edge extracted,
    # so a by-path read in A would now see the service gone.
    var interfaces: seq[string] = @[]
    for path in walkPattern(c.project / ".repro" / "dev-env" / "*" /
        "project-interface.rbsz"):
      interfaces.add(path)
    require interfaces.len > 0
    for path in interfaces:
      let names = liftedServiceNames(path)
      checkpoint(path & " lifts " & $names)
      require first in names
      require other notin names

    writeFile(c.rendezvous / "release", "")
    joinThread(aThread)
    aJoined = true
    let aExit = a.waitForExit()
    a.close()
    checkpoint("run A (exit " & $aExit & "):\n" & aDrain.output)

    check aExit == 0
    check fileExists(c.rendezvous / (first & ".ready"))
    check fileExists(c.rendezvous / (other & ".ready"))
    var otherConverged = false
    for line in aDrain.output.splitLines():
      if line.contains("service `" & other & "` ") and
          line.contains(" at service:"):
        otherConverged = true
    check otherConverged
