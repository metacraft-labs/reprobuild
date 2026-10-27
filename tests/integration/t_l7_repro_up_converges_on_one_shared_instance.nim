## Shared-Development-Services L7 (§4.5) — `repro up` and `repro down`,
## through the REAL CLI against a REAL daemon, in three real project
## directories of one real workspace.
##
## MOCKS: NONE. This file drives `build/bin/repro` as a child process
## against three project directories on the real filesystem, each with a
## real `reprobuild.nim` whose typed `service` block declares `identity
## stable` / `scope workspace` and whose `devEnv:` body declares the same
## service to the dev-session supervisor with an `instance` block. The
## daemon is a real `repro daemon serve --foreground` on a real unix
## socket, with its own `--state-dir`, its own `--state-root` and its own
## log; the shared instance is a real `sh` process that really runs until
## it is really signalled. Nothing is stubbed and nothing is faked.
##
## WHAT THIS FILE IS FOR, AND WHAT IT IS NOT FOR. This is the gate's
## end-to-end clause: that the registry is reached THROUGH `repro up` and
## `repro down` and not only through its own functions. The registry's
## own exhaustive gate — all six orders of three consumers, §4.5's rule 1
## on a record the real store wrote, the dead-process and undecodable
## record paths — is
## `libs/repro_resources/tests/t_l7_instance_registry_converges_in_any_order.nim`,
## which runs in seconds because it does not compile a provider. Here a
## single cold `repro up` spends about 40 s in `repro dev-env` on this
## host, so this file runs TWO orders over three projects whose provider
## compile is warm after the first, and says which clauses it covers.
##
## ISOLATION. `REPRO_DAEMON_ENDPOINT`, `REPRO_DAEMON_STATE_DIR` and the
## daemon's `--state-root` are all per-run, under one temp root. The
## `--state-root` is load-bearing and not hygiene theatre: without it the
## daemon's lease store would be `$HOME/.cache/repro/state`, i.e. the
## developer's live state, which the campaign's working agreement forbids
## for every instance-identity experiment.

import std/[json, os, osproc, sequtils, strtabs, streams, strutils, tempfiles,
    times,
    unittest]

import repro_test_support

const
  SharedIdentity = "com.example.l7.integration.sso"
  ServiceName = "sso"

proc repoRootDir(): string = getCurrentDir()

proc reproBinary(): string =
  ## Test-Fixtures-In-Build-Graph M1: `repro` is a build-graph artifact
  ## (`reprobuild.apps.repro` -> `build/bin/repro`). Asserted to exist
  ## rather than rebuilt at test runtime.
  requireBinary(repoRootDir() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc writeExecutable(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

type
  L7Case = object
    tempRoot: string
    workspaceRoot: string
    projects: seq[string]
    reproBin: string

proc recipeFor(packageName: string): string =
  ## A real recipe declaring ONE service twice over, which is the current
  ## shape of the surface and is stated here rather than hidden:
  ##
  ## * the typed `service` block carries the IDENTITY, the SCOPE and the
  ##   interface — it is what the lift lowers, and what `repro up` reads
  ##   the instance key and the §4.3 fingerprint from;
  ## * the `devEnv:` `servicePlaceholder` carries the COMMAND and the
  ##   `instance` block — it is the only channel the dev-session
  ##   supervisor reads.
  ##
  ## The duplication is the plumbing gap L7 hands on: nothing routes a
  ## typed `service` block into `DevEnvArtifact.services`, so the two
  ## channels have to be declared separately and the service NAME is what
  ## joins them. The milestone drawer records it; it is not a property of
  ## the design.
  "import repro_project_dsl\n" &
  "\n" &
  "package " & packageName & ":\n" &
  "  executable ssoBin:\n" &
  "    build:\n" &
  "      output(\"bin/sso\")\n" &
  "\n" &
  "  service " & ServiceName & ":\n" &
  "    executable ssoBin\n" &
  "    identity stable \"" & SharedIdentity & "\"\n" &
  "    scope workspace\n" &
  "    compatibility 1\n" &
  "\n" &
  "  devEnv:\n" &
  "    activity \"default\"\n" &
  "    servicePlaceholder \"" & ServiceName & "\",\n" &
  "      metadata = \"\"\"" &
    "{\"schemaId\":\"reprobuild.dev-session.service.v1\"," &
    "\"command\":[\"sh\",\"scripts/sso.sh\"],\"cwd\":\".\"," &
    "\"readiness\":{\"kind\":\"fileExists\",\"path\":\"state/sso.ready\"," &
    "\"timeoutMs\":5000}," &
    "\"instance\":{\"environment\":\"dev\",\"lease\":\"delayed\"," &
    "\"ttlSeconds\":3600}}" & "\"\"\",\n" &
  "      activities = [\"default\"]\n"

proc prepareCase(): L7Case =
  result.tempRoot = createTempDir("repro-l7-cli-", "")
  result.workspaceRoot = result.tempRoot / "ws"
  createDir(result.workspaceRoot / ".repro")
  # A REAL workspace manifest, so `scope workspace` resolves to the
  # workspace IDENTITY rather than degrading to the checkout path. The
  # degradation is correct behaviour and L4 measures it; here it would
  # make the test measure the degradation instead of the registry.
  writeFile(result.workspaceRoot / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n" &
    "\n[workspace]\nproject = \"l7-integration\"\n")
  for i in 1 .. 3:
    let project = result.workspaceRoot / ("p" & $i)
    createDir(project)
    writeExecutable(project / "scripts" / "sso.sh",
      "#!/bin/sh\n" &
      "mkdir -p state\n" &
      "printf 'sso-start %s\\n' \"$$\" >> state/sso.log\n" &
      "touch ../sso.ready\n" &
      "trap 'printf \"sso-stop\\n\" >> state/sso.log; rm -f ../sso.ready; exit 0' TERM INT\n" &
      "while :; do sleep 1; done\n")
    # Every holder observes the SAME instance's readiness. A per-project
    # marker would only be written in the materialising owner's cwd, so
    # another holder would correctly refuse its absent local marker.
    writeFile(project / "reprobuild.nim", recipeFor("l7p" & $i).replace(
      "\"path\":\"state/sso.ready\"",
      "\"path\":" & $(%(result.workspaceRoot / "sso.ready"))))
    result.projects.add(project)
  result.reproBin = reproBinary()

# ---------------------------------------------------------------------------
# The daemon.
# ---------------------------------------------------------------------------

proc daemonEndpoint(c: L7Case): string =
  daemonSocketEndpoint(c.tempRoot.extractFilename)

proc daemonStateDir(c: L7Case): string = c.tempRoot / "daemon-state"
proc daemonLeaseRoot(c: L7Case): string = c.tempRoot / "lease-state"
proc daemonLogPath(c: L7Case): string =
  c.daemonStateDir / "logs" / "repro-daemon.log"

proc daemonArgs(c: L7Case): seq[string] =
  @["--endpoint", c.daemonEndpoint,
    "--state-dir", c.daemonStateDir,
    "--state-root", c.daemonLeaseRoot,
    "--log", c.daemonLogPath]

proc envFor(c: L7Case): StringTableRef =
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

proc runRepro(c: L7Case; cwd: string; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  runProgram(c.reproBin, args, cwd, c.envFor())

proc stopDaemon(c: L7Case) =
  discard runProgram(c.reproBin, @["daemon", "stop"] & c.daemonArgs,
    repoRootDir(), c.envFor())
  try: removeFile(c.daemonEndpoint) except OSError, IOError: discard

proc waitForDaemonRunning(c: L7Case; timeoutSeconds = 60.0) =
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
    "the daemon never reported running; last status was:\n" & last &
    "\nlog:\n" &
    (if fileExists(c.daemonLogPath): readFile(c.daemonLogPath) else: "(none)"))

proc startDaemon(c: L7Case): owned(Process) =
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

proc closeDaemon(c: L7Case; daemon: var owned(Process)) =
  c.stopDaemon()
  if not daemon.isNil:
    if daemon.running():
      daemon.terminate()
      discard daemon.waitForExit()
    daemon.close()

# ---------------------------------------------------------------------------
# Reading what happened.
# ---------------------------------------------------------------------------

proc convergeLine(output: string): string =
  ## The one `repro up` line that reports the converge outcome. Parsed
  ## rather than inferred, and the test ALSO cross-checks the pid against
  ## the operating system (`processAlive`) and the holder count against
  ## the ledger on disk, so no assertion rests on this string alone.
  for line in output.splitLines():
    if line.contains("service `" & ServiceName & "` ") and
        line.contains(" at service:"):
      return line
  ""

proc outcomeWordOf(line: string): string =
  let marker = "service `" & ServiceName & "` "
  let start = line.find(marker)
  if start < 0: return ""
  let rest = line[start + marker.len .. ^1]
  let space = rest.find(' ')
  if space < 0: rest else: rest[0 ..< space]

proc fieldAfter(line, label: string): string =
  let at = line.find(label & " ")
  if at < 0: return ""
  let rest = line[at + label.len + 1 .. ^1]
  let space = rest.find(' ')
  if space < 0: rest.strip() else: rest[0 ..< space].strip()

proc holderCountOf(line: string): int =
  ## The `with N holder(s)` field of a `repro up` converge line.
  let at = line.find("with ")
  if at < 0: return -1
  let rest = line[at + 5 .. ^1]
  let space = rest.find(' ')
  if space < 0: return -1
  try: parseInt(rest[0 ..< space]) except ValueError: -1

proc remainingCountOf(line: string): int =
  ## The `; N holder(s) remain` field of a `repro down` release line.
  let at = line.find("; ")
  if at < 0: return -1
  let rest = line[at + 2 .. ^1]
  let space = rest.find(' ')
  if space < 0: return -1
  try: parseInt(rest[0 ..< space]) except ValueError: -1

proc processAlive(pid: int): bool =
  ## An independent reading of the one fact that matters most: is the
  ## instance's process still there. Taken from the OS rather than from
  ## the daemon, so "the instance is still running" is not the daemon's
  ## own claim repeated back.
  when defined(linux):
    dirExists("/proc/" & $pid)
  else:
    runProgram("/bin/sh", @["-c", "kill -0 " & $pid & " 2>/dev/null"],
      repoRootDir(), nil).exitCode == 0

proc ledgerPath(project: string): string =
  project / ".repro" / "dev-env" / "default" / "session" /
    "shared-instances.json"

proc up(c: L7Case; project: string; extra: openArray[string] = []):
    tuple[exitCode: int; output: string] =
  runRepro(c, project, @["up"] & @extra)

proc down(c: L7Case; project: string):
    tuple[exitCode: int; output: string] =
  runRepro(c, project, @["down"])

proc downEveryProject(c: L7Case) =
  for project in c.projects:
    discard c.down(project)

proc checkGatedReadiness(c: L7Case; project: string): string =
  let eventsPath = parentDir(ledgerPath(project)) / "events.jsonl"
  var process = startProcess(c.reproBin, args = @["up"],
    workingDir = project, env = c.envFor(),
    options = {poUsePath, poStdErrToStdOut})
  defer:
    if process.running():
      process.terminate()
      discard process.waitForExit()
    process.close()
  var waiting = false
  while process.running():
    if fileExists(eventsPath):
      waiting = readFile(eventsPath).contains("service.readiness.waiting")
    if waiting or not process.running(): break
    sleep(50)
  check waiting
  check process.running()
  check not fileExists(project / "state" / "sso.ready")
  if fileExists(eventsPath):
    check not readFile(eventsPath).contains("session.up")
  # Release even on failure so teardown cannot strand an instance.
  createDir(project / "state")
  writeFile(project / "state" / "release", "ready\n")
  let output = process.outputStream.readAll()
  checkpoint(output)
  check process.waitForExit() == 0
  check fileExists(project / "state" / "sso.ready")
  require fileExists(eventsPath)
  result = readFile(eventsPath)

suite "L7 §4.5 — `repro up` in three projects converges on one instance":
  # Prepared on the first case's `setup`, NOT in the suite body. The suite
  # body runs at registration, in every process this binary starts --
  # including `--list` / `--list-json`, which only enumerates and is run
  # from a scratch working directory. Preparing here made enumeration
  # resolve `<cwd>/build/bin/repro` (raising from any other directory, so
  # no case was listed) and start a daemon just to print case names. The
  # runner executes each case in its own process, so a case still prepares
  # the fixture and starts the daemon exactly once, and the deferred
  # cleanup below still runs in that process -- only if a case prepared.
  var prepared = false
  var c: L7Case
  var daemon: owned(Process)

  setup:
    if not prepared:
      c = prepareCase()
      prepared = true
      daemon = c.startDaemon()

  defer:
    if prepared:
      downEveryProject(c)
      c.closeDaemon(daemon)
      try: removeDir(c.tempRoot) except OSError, IOError: discard

  test "two orders, each ending with one instance, one pid and three holders":
    ## The gate's headline clause through the CLI: "`repro up` run in
    ## three project directories of one workspace in each of several
    ## orders, every order ending with exactly one instance and three
    ## holders". TWO orders here and all six in the registry's own gate —
    ## see this file's header for the cost that bounds it.
    let orders = @[@[0, 1, 2], @[2, 0, 1]]
    for order in orders:
      checkpoint("order: " & $order)
      var addresses: seq[string] = @[]
      var pids: seq[string] = @[]
      var outcomes: seq[string] = @[]
      var holderCounts: seq[int] = @[]
      for index in order:
        let result = c.up(c.projects[index])
        checkpoint(result.output)
        check result.exitCode == 0
        let line = convergeLine(result.output)
        check line.len > 0
        outcomes.add(outcomeWordOf(line))
        addresses.add(fieldAfter(line, "at"))
        pids.add(fieldAfter(line, "pid"))
        holderCounts.add(holderCountOf(line))
      # EXACTLY ONE materialisation per order, whatever the order.
      check outcomes.count("Materialise") == 1
      check outcomes[0] == "Materialise"
      check outcomes.count("AttachSilently") == 2
      # ONE instance: one address and one pid across all three.
      check addresses[0].len > 0
      check addresses[1] == addresses[0]
      check addresses[2] == addresses[0]
      check pids[1] == pids[0]
      check pids[2] == pids[0]
      check addresses[0].contains(SharedIdentity)
      check addresses[0].contains(":workspace:")
      check addresses[0].contains(":dev:")
      # THREE holders, counted up as each project arrives.
      check holderCounts == @[1, 2, 3]
      # The process really is running, read from the OS.
      check processAlive(parseInt(pids[0]))
      # And every project recorded its own holder in its own ledger.
      for index in order:
        let ledger = parseJson(readFile(ledgerPath(c.projects[index])))
        check ledger{"holderId"}.getStr("").contains(
          c.projects[index].extractFilename)
        check ledger{"instances"}.len == 1
        check ledger{"instances"}[0]{"address"}.getStr("") == addresses[0]
      # Tear the order down so the next one starts from nothing, and
      # check the teardown itself on the way through.
      var remaining: seq[int] = @[]
      for index in order:
        let result = c.down(c.projects[index])
        checkpoint(result.output)
        check result.exitCode == 0
        remaining.add(remainingCountOf(convergeLine(result.output)))
      check remaining == @[2, 1, 0]
      check not processAlive(parseInt(pids[0]))

  test "a `repro down` in one project leaves the instance for the other two":
    ## The gate's middle clauses, asserted on the PROCESS rather than on
    ## the daemon's report: after the first release the pid is still
    ## alive, after the second it is still alive, and only after the
    ## third is it gone.
    for project in c.projects:
      check c.up(project).exitCode == 0
    let line = convergeLine(c.up(c.projects[0]).output)
    let pid = parseInt(fieldAfter(line, "pid"))
    check processAlive(pid)
    let first = c.down(c.projects[0])
    checkpoint(first.output)
    check first.exitCode == 0
    check outcomeWordOf(convergeLine(first.output)) == "DroppedHolder"
    check processAlive(pid)
    let second = c.down(c.projects[1])
    check outcomeWordOf(convergeLine(second.output)) == "DroppedHolder"
    check processAlive(pid)
    let last = c.down(c.projects[2])
    checkpoint(last.output)
    check outcomeWordOf(convergeLine(last.output)) == "ReleasedLastHolder"
    check not processAlive(pid)
    # The ledger is removed once every holder it recorded was released,
    # so a second `repro down` releases nothing rather than refusing.
    check not fileExists(ledgerPath(c.projects[2]))

  test "a daemon restart recovers the registry, and the next `repro up` attaches":
    ## The gate's last clause end to end: two projects up, the daemon
    ## STOPPED and started again, and the third project's `repro up`
    ## attaching to the SAME pid with three holders — so the two
    ## pre-restart holders came back from the on-disk store, nothing was
    ## orphaned and nothing was double-started.
    let firstLine = convergeLine(c.up(c.projects[0]).output)
    check outcomeWordOf(firstLine) == "Materialise"
    let pid = parseInt(fieldAfter(firstLine, "pid"))
    let secondLine = convergeLine(c.up(c.projects[1]).output)
    check holderCountOf(secondLine) == 2
    c.closeDaemon(daemon)
    check processAlive(pid) # the instance outlives its daemon
    daemon = c.startDaemon()
    let log = readFile(c.daemonLogPath)
    check log.contains("service instance registry rebuilt: recovered=1")
    check log.contains("unnamedKeepHolderRisks=0")
    let thirdLine = convergeLine(c.up(c.projects[2]).output)
    checkpoint(thirdLine)
    check outcomeWordOf(thirdLine) == "AttachSilently"
    check fieldAfter(thirdLine, "pid") == $pid
    check holderCountOf(thirdLine) == 3
    downEveryProject(c)
    check not processAlive(pid)

  test "`repro up --replace` refuses while another project holds the instance":
    ## §4.3's takeover, reached through the CLI now that there is a
    ## registry to resolve against — and refused, naming the holder,
    ## because another project's lease is live. The instance is NOT
    ## stopped, which is the whole point of the refusal.
    check c.up(c.projects[0]).exitCode == 0
    let line = convergeLine(c.up(c.projects[1]).output)
    let pid = parseInt(fieldAfter(line, "pid"))
    let refusal = c.up(c.projects[1], @["--replace"])
    checkpoint(refusal.output)
    check refusal.exitCode == 1
    check refusal.output.contains("refusing `repro up --replace`")
    check refusal.output.contains(c.projects[0].extractFilename)
    check refusal.output.contains("`--force` to replace")
    # Nothing was taken over: the instance is still the same process.
    check processAlive(pid)
    let after = convergeLine(c.up(c.projects[1]).output)
    check fieldAfter(after, "pid") == $pid
    downEveryProject(c)

  test "`repro up --force` without `--replace` is refused, not ignored":
    ## At the base commit `478abb590` this parsed cleanly and did
    ## nothing: `--force` was recorded for every dev-session command and
    ## read only by `repro down`. Driven through the CLI because that is
    ## where the silent drop was.
    let result = c.up(c.projects[0], @["--force"])
    check result.exitCode == 1
    check result.output.contains("--force has no effect on `repro up`")
    check result.output.contains("without --replace")
    # And `--replace` is refused by `down`, which takes nothing over.
    let onDown = runRepro(c, c.projects[0], @["down", "--replace"])
    check onDown.exitCode == 1
    check onDown.output.contains("unsupported down flag: --replace")


  test "a shared service without registrations refuses an unsatisfied probe":
    let project = c.projects[0]
    discard c.down(project)
    defer: discard c.down(project)
    for marker in ["sso.ready", "release"]:
      if fileExists(project / "state" / marker):
        removeFile(project / "state" / marker)
    let eventsPath = parentDir(ledgerPath(project)) / "events.jsonl"
    if fileExists(eventsPath): removeFile(eventsPath)
    writeFile(project / "reprobuild.nim",
      recipeFor("l7p1").replace("\"timeoutMs\":5000", "\"timeoutMs\":300"))
    writeExecutable(project / "scripts" / "sso.sh",
      "#!/bin/sh\ntrap 'exit 0' TERM INT\nwhile :; do sleep 1; done\n")
    let response = c.up(project)
    checkpoint(response.output)
    check response.exitCode == 1
    check response.output.contains("readiness probe (fileExists")
    check not response.output.contains(" up http://")
    check not fileExists(project / "state" / "sso.ready")
    require fileExists(eventsPath)
    let events = readFile(eventsPath)
    check events.contains("service.readiness.waiting")
    check events.contains("service.readiness.timeout")
    check not events.contains("session.up")

  test "a shared service without registrations completes only after its probe":
    let project = c.projects[0]
    discard c.down(project)
    defer: discard c.down(project)
    for marker in ["sso.ready", "release"]:
      if fileExists(project / "state" / marker):
        removeFile(project / "state" / marker)
    let eventsPath = parentDir(ledgerPath(project)) / "events.jsonl"
    if fileExists(eventsPath): removeFile(eventsPath)
    writeFile(project / "reprobuild.nim", recipeFor("l7p1"))
    # The test controls the readiness gate rather than inferring readiness
    # from a sleep: the real service cannot write its marker until released.
    writeExecutable(project / "scripts" / "sso.sh",
      "#!/bin/sh\nmkdir -p state\ntrap 'exit 0' TERM INT\n" &
      "while [ ! -f state/release ]; do sleep 0.05; done\n" &
      "touch state/sso.ready\nwhile :; do sleep 1; done\n")
    let events = checkGatedReadiness(c, project)
    check events.contains("service.readiness.satisfied")
    check events.find("service.readiness.satisfied") < events.find("session.up")


  test "an attached shared service without registrations rechecks readiness":
    let project = c.projects[0]
    discard c.down(project)
    defer: discard c.down(project)
    for marker in ["sso.ready", "release"]:
      if fileExists(project / "state" / marker):
        removeFile(project / "state" / marker)
    writeFile(project / "reprobuild.nim",
      recipeFor("l7p1").replace("\"timeoutMs\":5000", "\"timeoutMs\":300"))
    writeExecutable(project / "scripts" / "sso.sh",
      "#!/bin/sh\nmkdir -p state\ntouch state/sso.ready\n" &
      "trap 'exit 0' TERM INT\nwhile :; do sleep 1; done\n")
    let first = c.up(project)
    checkpoint(first.output)
    require first.exitCode == 0
    let firstLine = convergeLine(first.output)
    require outcomeWordOf(firstLine) == "Materialise"
    let pid = parseInt(fieldAfter(firstLine, "pid"))
    require fileExists(project / "state" / "sso.ready")
    removeFile(project / "state" / "sso.ready")
    check processAlive(pid)
    let eventsPath = parentDir(ledgerPath(project)) / "events.jsonl"
    if fileExists(eventsPath): removeFile(eventsPath)
    let attached = c.up(project)
    checkpoint(attached.output)
    check outcomeWordOf(convergeLine(attached.output)) == "AttachSilently"
    check fieldAfter(convergeLine(attached.output), "pid") == $pid
    check attached.exitCode == 1
    check attached.output.contains("readiness probe (fileExists")
    check not attached.output.contains(" up http://")
    check processAlive(pid)
    require fileExists(eventsPath)
    let events = readFile(eventsPath)
    check events.contains("service.readiness.timeout")
    check not events.contains("session.up")


  test "unreachable failed sessions release holders with and without force":
    # Fail REAL startup after convergence took a holder: the session cannot
    # concretize an unavailable instance attribute. Its HTTP child shuts down
    # while failed metadata and the authoritative holder ledger remain.
    let owner = c.projects[0]
    let started = c.up(owner)
    checkpoint(started.output)
    require started.exitCode == 0
    let pid = parseInt(fieldAfter(convergeLine(started.output), "pid"))
    defer:
      # A negative-control run must also clean the process the broken down
      # command strands. This signal is teardown only, after every oracle.
      if processAlive(pid):
        discard runProgram("sh", @["-c", "kill -TERM " & $pid],
          c.workspaceRoot, c.envFor())
        for attempt in 0 ..< 100:
          if not processAlive(pid): break
          sleep(50)
    for index in 1 .. 2:
      let project = c.projects[index]
      writeFile(project / "reprobuild.nim",
        readFile(project / "reprobuild.nim") &
        "    servicePlaceholder \"consumer\",\n" &
        "      metadata = \"\"\"{\"command\":[\"sh\",\"@instance-attribute:unavailable@\"]}\"\"\",\n" &
        "      activities = [\"default\"]\n")
      let failed = c.up(project)
      checkpoint(failed.output)
      require failed.exitCode == 1
      require failed.output.contains("instance attribute `unavailable` is NOT AVAILABLE")
      require holderCountOf(convergeLine(failed.output)) == index + 1
      require fileExists(ledgerPath(project))
      let metadataPath = parentDir(ledgerPath(project)) / "session.json"
      let metadata = parseJson(readFile(metadataPath))
      require metadata{"status"}.getStr() == "failed"
      require metadata{"httpBind"}.getStr().len > 0
      let httpPid = metadata{"httpPid"}.getInt()
      require httpPid > 0
      let deadline = epochTime() + 60.0
      while processAlive(httpPid) and epochTime() < deadline: sleep(50)
      require not processAlive(httpPid)
    for index in 1 .. 2:
      let project = c.projects[index]
      let args = if index == 1: @["down"]
                 else: @["down", "--force", "--stop-timeout=100"]
      let stopped = c.runRepro(project, args)
      checkpoint(stopped.output)
      # A stop error stays an error, including the force-file timeout.
      check stopped.exitCode == 1
      if index == 1:
        check stopped.output.toLowerAscii().contains("refused")
      else:
        check stopped.output.contains("HTTP stop failed; wrote stop request file")
        check stopped.output.contains("did not stop:")
      check outcomeWordOf(convergeLine(stopped.output)) == "DroppedHolder"
      check remainingCountOf(convergeLine(stopped.output)) == 3 - index
      check not fileExists(ledgerPath(project))
      check processAlive(pid)
    # The daemon's last-holder result independently proves both releases
    # reached its real lease store; deleting only the local ledgers fails it.
    let last = c.down(owner)
    checkpoint(last.output)
    check last.exitCode == 0
    check outcomeWordOf(convergeLine(last.output)) == "ReleasedLastHolder"
    check remainingCountOf(convergeLine(last.output)) == 0
    check not processAlive(pid)
