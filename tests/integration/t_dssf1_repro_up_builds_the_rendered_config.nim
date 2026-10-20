## Shared-Development-Services F1 (§4.8 / D-SS15), SECOND HALF, END TO
## END — A REAL `repro up` WRITES THE RENDERED CONFIGURATION BEFORE THE
## SERVICE THAT NAMES IT STARTS.
##
## THE DEFECT THIS FILE REPRODUCES AND CLOSES, quoted from §4.8: "Observed
## end to end: `repro up --activity sso` reported the session up, the
## daemon reported `Materialise ok`, and `etc/sso/` did not exist — *the
## path reached argv and the file never did.*" F1's actions channel made
## the action REACH the caller; it did not make anything build it, and
## §4.8 says so: "Reporting an action is not running it. Nothing in this
## change makes the dev session BUILD the reported edges, so F1's clause
## is not met by it ... the remaining half is for the dev session to
## order the reported actions before the services it launches."
##
## HOW THE ORDERING IS READ, AND WHY IT IS NOT A CLOCK. This file does not
## time the file's appearance against the service's spawn. The SERVICE
## ITSELF is the witness: its command is `sh -c` over a script that
## copies the file it was handed on argv, and its declared readiness is a
## marker the script touches only AFTER the copy succeeds under `set -e`.
## So the session reports `up` only if the consuming process found the
## file already there, and the copy's BYTES are then compared with the
## bytes the recipe rendered. If the action were reported and not built,
## the `cp` would fail, the marker would never appear, and `repro up`
## would exit non-zero — which is exactly the state this clause was open
## in.
##
## MOCKS: NONE. A real `build/bin/repro`, a real private daemon on a real
## unix socket with its own state dir and state root, a real project
## directory with a real `reprobuild.nim`, a real provider compile, a
## real dev-session supervisor and a real `sh` child. Nothing is stubbed.
##
## ISOLATION. `REPRO_DAEMON_ENDPOINT`, `REPRO_DAEMON_STATE_DIR` and the
## daemon's `--state-root` are per-run under one temp root, for the
## reason `t_l7_repro_up_converges_on_one_shared_instance.nim` records:
## without them the daemon's store would be the developer's live state.

import std/[os, osproc, strtabs, streams, strutils, tempfiles, times,
    unittest]

import repro_test_support

const
  PackageName = "dssf1up"
  ActivityName = "api"
  ServiceName = "api"
  ConfigRel = "etc/dssf1/consumed.yaml"
  ConfigText = "listen: 127.0.0.1:19643\nseeded: true\n"
  ObservedRel = ".repro/dssf1/observed.yaml"
  ReadyRel = ".repro/dssf1/ready"
  StateDirRel = ".repro/dssf1"
  ActionId = "fs-writeText-etc-2fdssf1-2fconsumed.yaml"
    ## `renderConfigFile`'s documented default id -- "a function of the
    ## path alone" -- with the separators percent-escaped by the id
    ## sanitiser. SPELLED OUT rather than derived, for the reason
    ## `dssf1_action_fixtures.nim` records: a derived expectation
    ## asserts whatever the implementation produced.

proc repoRootDir(): string = getCurrentDir()

proc reproBinary(): string =
  requireBinary(repoRootDir() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  UpCase = object
    tempRoot: string
    project: string
    reproBin: string

proc recipe(): string =
  ## THE RECIPE F1 SAID COULD NOT BE WRITTEN, as a real project file:
  ## the configuration is a build output and the service consumes it by
  ## reference on argv.
  ##
  ## The script is the measurement. `set -e` plus a `cp` of `$0` means
  ## the service CANNOT reach its readiness marker unless the rendered
  ## file was already on disk when it started -- `sh -c <script> <path>`
  ## puts the rendered path in `$0`.
  "import repro_project_dsl\n" &
  "\n" &
  "package " & PackageName & ":\n" &
  "  devEnv:\n" &
  "    activity " & ActivityName & "():\n" &
  "      service " & ServiceName & ":\n" &
  "        executable executableAtPath(\"/bin/sh\")\n" &
  "        args \"-c\", \"set -e; mkdir -p " & StateDirRel & "; " &
    "cp \\\"$0\\\" " & ObservedRel & "; touch " & ReadyRel & "; " &
    "trap 'exit 0' TERM INT; while :; do sleep 1; done\"\n" &
  "        args renderConfigFile(\"" & ConfigRel & "\",\n" &
  "          \"listen: 127.0.0.1:19643\\nseeded: true\\n\").path\n" &
  "        identity stable \"com.example.dssf1.up\"\n" &
  "        scope project\n" &
  "        stateDirectory \"" & StateDirRel & "\"\n" &
  "        readiness fileExists(\"" & ReadyRel & "\", timeoutMs = 60000)\n" &
  "\n" &
  "    enable " & ActivityName & "\n"

proc prepareCase(): UpCase =
  result.tempRoot = createTempDir("repro-dssf1-up-", "")
  result.project = result.tempRoot / "p1"
  createDir(result.project)
  writeFile(result.project / "reprobuild.nim", recipe())
  result.reproBin = reproBinary()

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
  c.stopDaemon()
  if not daemon.isNil:
    if daemon.running():
      daemon.terminate()
      discard daemon.waitForExit()
    daemon.close()

suite "F1 §4.8 — `repro up` builds the rendered configuration first":
  # Prepared in `setup`, NOT in the suite body. The body runs at
  # registration in every process this binary starts -- including
  # `--list` / `--list-json`, which only enumerates and is run from a
  # scratch working directory. Preparing there resolved
  # `<cwd>/build/bin/repro` and started a daemon just to print case
  # names: the defect `84e42788f` fixed for the five shared-instance
  # binaries, which this file still carried.
  #
  # Prepared PER CASE rather than once per process, so the replayed step
  # below starts from the same EMPTY tree whether the runner gives each
  # case its own process (it does) or one process runs every case. That
  # keeps the step's positive control -- both files absent -- meaningful
  # in both modes instead of asserting on a tree a previous case rendered.
  var prepared = false
  var c: UpCase
  var daemon: owned(Process)
  var upOutput = ""
  var upExit = -1

  setup:
    c = prepareCase()
    daemon = c.startDaemon()
    prepared = true
    upOutput = ""
    upExit = -1

  teardown:
    if prepared:
      prepared = false
      discard c.runRepro(@["down", "--activity", ActivityName])
      c.closeDaemon(daemon)
      try: removeDir(c.tempRoot) except OSError, IOError: discard

  # ONE PROCESS PER CASE. The suite runner executes every case in a process
  # of its own, and this suite body prepares a FRESH project and a fresh
  # daemon in each such process. The cases below are one scenario told in
  # steps: the first runs `repro up`, and every later one asserts on what
  # that run produced -- `upOutput` for the announcement, the project tree
  # for the rendered file and the consumer's copy of it.
  #
  # Run alone, a dependent case therefore read an EMPTY `upOutput` and an
  # unrendered tree, and failed on a fixture it never built. That is what
  # the full-suite run of 2026-10-19/20 measured at reprobuild-sds
  # 8f8e5e553: cases 2-5 FAILED (case 2 on
  # `upOutput.contains("built 1 dev-env action(s) ...")`, cases 3-5 on a
  # file that was never written) while case 1 passed, and the same binary
  # passed 5 of 5 whenever ONE process ran every case in order. The suite
  # indices show the split -- the passing case ran at 2634 while three of
  # the failures ran at 2591-2593.
  #
  # So each step is a template, and a dependent case REPLAYS the step its
  # state comes from, assertions and all, before running its own. This is
  # the pattern `t_dss11_cross_process_contribution_reaches_the_instance`
  # and its four shared-instance siblings already carry. Case names, order
  # and every assertion are unchanged; a failing prerequisite now fails the
  # dependent case at the PREREQUISITE's own assertion, rather than letting
  # it fail on a missing file that says nothing about why.

  template nothingIsOnDiskAndThenUpRuns() =
    # The step of case "the state F1 measured: nothing is on disk before
    # the session runs".
    #
    # POSITIVE CONTROL FOR EVERY EXTRACTION BELOW. Both files are
    # absent, so neither "the rendered file is there" nor "the service
    # saw it" can be satisfied by something this harness left behind.
    check not fileExists(c.project / ConfigRel)
    check not fileExists(c.project / ObservedRel)
    let outcome = c.runRepro(@["up", "--activity", ActivityName])
    upExit = outcome.exitCode
    upOutput = outcome.output
    checkpoint(upOutput)
    check upExit == 0

  test "the state F1 measured: nothing is on disk before the session runs":
    nothingIsOnDiskAndThenUpRuns()

  test "`repro up` reports building the action BEFORE starting anything":
    # Read off the CLI's own stderr. Not the only evidence -- the two
    # cases below read the filesystem and the consumer's own copy -- but
    # it is what attributes the file to this pass rather than to some
    # other writer.
    nothingIsOnDiskAndThenUpRuns()
    check upOutput.contains("built 1 dev-env action(s) before starting")
    check upOutput.contains(ActionId)

  test "the rendered file is on disk with the bytes the recipe declared":
    nothingIsOnDiskAndThenUpRuns()
    check fileExists(c.project / ConfigRel)
    check readFile(c.project / ConfigRel) == ConfigText

  test "AND THE SERVICE SAW IT: the consumer's own copy has those bytes":
    ## THE ORDERING CLAUSE, read from the consuming process rather than
    ## from a clock. `observed.yaml` is written by the `sh` child from
    ## the path it was handed on argv, before it touches the readiness
    ## marker the session waited on. Its existence is proof that the
    ## file was there when the service started; its CONTENT is proof
    ## that it was the rendered file and not an empty placeholder.
    nothingIsOnDiskAndThenUpRuns()
    check fileExists(c.project / ObservedRel)
    check readFile(c.project / ObservedRel) == ConfigText
    check fileExists(c.project / ReadyRel)

  test "a second `repro up` in the same project is still ordered and still green":
    ## The CACHED-EDGE path, which D-SS11 names as the hop that is "not
    ## optional": the second evaluation is answered from the dev-env
    ## ARTIFACT without re-running the provider, so an ordering edge
    ## that lived only on the provider wire would work once and
    ## silently never again. Measured by deleting both files and
    ## running `repro up` again.
    nothingIsOnDiskAndThenUpRuns()
    check c.runRepro(@["down", "--activity", ActivityName]).exitCode == 0
    removeFile(c.project / ConfigRel)
    removeFile(c.project / ObservedRel)
    removeFile(c.project / ReadyRel)
    check not fileExists(c.project / ConfigRel)
    let second = c.runRepro(@["up", "--activity", ActivityName])
    checkpoint(second.output)
    check second.exitCode == 0
    check second.output.contains("built 1 dev-env action(s) before starting")
    check readFile(c.project / ConfigRel) == ConfigText
    check readFile(c.project / ObservedRel) == ConfigText
