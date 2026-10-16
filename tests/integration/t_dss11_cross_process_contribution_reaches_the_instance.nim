## Shared-Development-Services D-SS11 (§4.6) — A CONSUMER IN A DIFFERENT
## PROCESS CONTRIBUTES TO A SHARED INSTANCE, AND THE CONTRIBUTION IS
## PRESENT ON THAT INSTANCE.
##
## This is the clause the whole decision exists for, and the one L9
## measured as absent: "a consumer in a *different process* has no way
## to reach them ... So the lane is intra-process, and a cross-repo
## `contribute:` would compile, look wired, and do nothing -- this
## document's own dominant defect class."
##
## Everything here is real and nothing is in-process:
##
##   * a real workspace on a real filesystem, with a real
##     `.repro/workspace.toml` so `scope workspace` resolves to the
##     workspace IDENTITY rather than degrading to a checkout path;
##   * two real projects, an OWNER whose recipe declares the shared
##     service with a `converge` point and a CONSUMER whose recipe
##     resolves it with `<package>.<activity>.<service>.shared(point =
##     append(...))` at its own `enable` site;
##   * a real `repro daemon serve` in its own process, reached over its
##     real socket;
##   * real `repro up` / `repro down` invocations, each a separate
##     process, each compiling the real provider from the real recipe;
##   * the real registration set on disk, read back as JSON, as the
##     evidence that the contribution is PRESENT on the instance.
##
## MOCKS: NONE. There is no test double anywhere in this file. The one
## injected function in the lane -- the registration MINTER -- is
## injected by `repro up` itself, not by this test, and it is the CLI's
## own deterministic placeholder; L8's drawer records that reprobuild has
## no OIDC client and why.
##
## THE NEGATIVE CONTROL IS A SECOND POINT, NOT AN ABSENCE. The owner
## declares TWO `config:` collections and converges only one of them.
## The consumer's contribution to the converged point must land; a
## contribution to the un-converged one must be REFUSED by name. Without
## the second point, "the contribution landed" would pass for an
## implementation that deposited every contribution against every point.
##
## THE SKEW CASE IS MEASURED, NOT SIMULATED. The instance is
## materialised from the owner's recipe as it stands, the owner's recipe
## is then edited to converge the second point and RE-LIFTED with `repro
## dev-env` -- without re-materialising -- and the consumer, which now
## compiles against the newer interface, is run again. Its contribution
## to the newly-declared point must be refused, because the RUNNING
## instance was built from the older definition. §4.6: "a contribution to
## an absent point is the refusing row, not the warning row".

import std/[options, os, osproc, strtabs, streams, strutils, tempfiles,
    times, unittest]
when defined(linux):
  import std/posix          # kill / SIGTERM / SIGKILL for the teardown reap

import repro_resources/service_registry
import repro_resources/state_store
import repro_test_support

const
  OwnerPackage = "dss11owner"
  ConsumerPackage = "dss11consumer"
  ServiceName = "idp"
  SharedIdentity = "com.example.dss11.idp"
  ConvergedPoint = "relyingParties"
  UnconvergedPoint = "fixtureUsers"
  OwnerMember = "dss11-owner-rp"
  ConsumerMember = "dss11-consumer-rp"
  SecondConsumerMember = "dss11-consumer-rp-2"
  SkewMember = "dss11-consumer-fixture-user"

proc repoRootDir(): string = getCurrentDir()

proc writeExecutable(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc reproBinary(): string =
  ## `repro` is a build-graph artifact (`reprobuild.apps.repro` ->
  ## `build/bin/repro`). Asserted to exist rather than rebuilt at test
  ## runtime.
  requireBinary(repoRootDir() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  Dss11Case = object
    tempRoot: string
    workspaceRoot: string
    ownerProject: string
    consumerProject: string
    reproBin: string

proc ownerRecipe(convergeSecondPoint: bool): string =
  ## The OWNER's recipe: one typed `service` block carrying the
  ## identity, the scope, the command, the readiness probe, the
  ## `instance:` block and the `converge` points. No
  ## `servicePlaceholder` -- L9's four setters are what made that
  ## possible, and the absence is load-bearing here because
  ## `mergeTypedServiceFacts` routes an ACTIVITY's typed services and
  ## nothing else.
  ##
  ## `relyingParties` carries the owner's OWN member as its `config:`
  ## DEFAULT, which is a `coReplace` at `epDefault` -- the LOWEST rung --
  ## chosen so that a consumer's `append` adds to it rather than being
  ## discarded by it. An `environment` binding would be a `replace` at
  ## `epOverride` and would discard every later append.
  result =
    "import repro_project_dsl\n" &
    "\n" &
    "package " & OwnerPackage & ":\n" &
    "  devEnv:\n" &
    "    activity sso():\n" &
    "      config:\n" &
    "        " & ConvergedPoint & ": seq[string] = @[\"" & OwnerMember &
      "\"]\n" &
    "        " & UnconvergedPoint & ": seq[string]\n" &
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
    "        converge " & ConvergedPoint
  if convergeSecondPoint:
    result.add(", " & UnconvergedPoint)
  result.add("\n\n    enable sso\n")

proc consumerRecipe(extraContribution: string): string =
  ## The CONSUMER's recipe. It names no hostname, binds no configurable
  ## and writes no `contribute:` section: its contribution is an
  ## ARGUMENT of the resolver call at its own `enable` site, which is
  ## what §4.6 decided.
  result =
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
    "        identity stable \"com.example.dss11.app\"\n" &
    "        scope project\n" &
    "        workingDirectory \".\"\n" &
    "        readiness fileExists(\"state/app.ready\", timeoutMs = 60000)\n" &
    "\n" &
    "    enable stack(sso = " & OwnerPackage & ".sso." & ServiceName &
      ".shared(\n" &
    "      " & ConvergedPoint & " = append("
  var members = "\"" & ConsumerMember & "\""
  result.add(members)
  if extraContribution.len > 0:
    result.add(")," & "\n      " & extraContribution)
  else:
    result.add(")")
  result.add("))\n")

proc prepareCase(): Dss11Case =
  result.tempRoot = createTempDir("repro-dss11-cli-", "")
  result.workspaceRoot = result.tempRoot / "ws"
  createDir(result.workspaceRoot / ".repro")
  writeFile(result.workspaceRoot / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n" &
    "\n[workspace]\nproject = \"dss11-integration\"\n")
  result.ownerProject = result.workspaceRoot / OwnerPackage
  result.consumerProject = result.workspaceRoot / ConsumerPackage
  createDir(result.ownerProject)
  createDir(result.consumerProject)
  writeExecutable(result.ownerProject / "scripts" / "idp.sh",
    "#!/bin/sh\n" &
    "mkdir -p state\n" &
    "printf 'idp-start %s\\n' \"$$\" >> state/idp.log\n" &
    "touch state/idp.ready\n" &
    "trap 'printf \"idp-stop\\n\" >> state/idp.log; exit 0' TERM INT\n" &
    "while :; do sleep 1; done\n")
  writeExecutable(result.consumerProject / "scripts" / "app.sh",
    "#!/bin/sh\n" &
    "mkdir -p state\n" &
    "touch state/app.ready\n" &
    "trap 'exit 0' TERM INT\n" &
    "while :; do sleep 1; done\n")
  writeFile(result.ownerProject / "repro.nim", ownerRecipe(false))
  writeFile(result.consumerProject / "repro.nim", consumerRecipe(""))
  result.reproBin = reproBinary()

proc daemonEndpoint(c: Dss11Case): string =
  daemonSocketEndpoint(c.tempRoot.extractFilename)

proc daemonStateDir(c: Dss11Case): string = c.tempRoot / "daemon-state"
proc daemonLeaseRoot(c: Dss11Case): string = c.tempRoot / "lease-state"
proc daemonLogPath(c: Dss11Case): string =
  c.daemonStateDir / "logs" / "repro-daemon.log"

proc daemonArgs(c: Dss11Case): seq[string] =
  @["--endpoint", c.daemonEndpoint,
    "--state-dir", c.daemonStateDir,
    "--state-root", c.daemonLeaseRoot,
    "--log", c.daemonLogPath]

proc envFor(c: Dss11Case): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["REPROBUILD_SOURCE_ROOT"] = repoRootDir()
  result["REPRO_DAEMON_ENDPOINT"] = c.daemonEndpoint
  result["REPRO_DAEMON_STATE_DIR"] = c.daemonStateDir
  # The CLI's own state store, which is where the registration set and
  # the cross-process contribution set live. Isolated per case so this
  # test never reads or writes the developer's `$HOME/.cache/repro`.
  result["XDG_CACHE_HOME"] = c.tempRoot / "cache"
  result["HOME"] = c.tempRoot / "home"
  # The progress bar writes thousands of carriage-returned frames into a
  # captured pipe, which makes a failure's `checkpoint` unreadable. Only
  # the rendering is suppressed.
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

proc runRepro(c: Dss11Case; cwd: string; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  runProgram(c.reproBin, args, cwd, c.envFor())

const
  OwnerActivity = "sso"
  ConsumerActivity = "stack"
    ## `--activity` is REQUIRED on every invocation here, and that is a
    ## property of the surface rather than a convenience: a `devEnv:`
    ## body's services are gated by their declaring activity
    ## (`activityRecordIsActive`), so `repro up` with nothing selected
    ## reaches an artifact with NO services and therefore no shared
    ## instance to converge. Measured on the first run of this file: the
    ## owner's `repro up` reported `session.up` with "0 ms of declared
    ## service readiness timeouts" and printed no converge line at all.

proc ownerUp(c: Dss11Case): tuple[exitCode: int; output: string] =
  c.runRepro(c.ownerProject, @["up", "--activity=" & OwnerActivity])

proc consumerUp(c: Dss11Case): tuple[exitCode: int; output: string] =
  c.runRepro(c.consumerProject, @["up", "--activity=" & ConsumerActivity])

proc stopDaemon(c: Dss11Case) =
  discard runProgram(c.reproBin, @["daemon", "stop"] & c.daemonArgs,
    repoRootDir(), c.envFor())
  try: removeFile(c.daemonEndpoint) except OSError, IOError: discard

proc waitForDaemonRunning(c: Dss11Case; timeoutSeconds = 60.0) =
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

proc startDaemon(c: Dss11Case): owned(Process) =
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

proc closeDaemon(c: Dss11Case; daemon: var owned(Process)) =
  c.stopDaemon()
  if not daemon.isNil:
    if daemon.running():
      daemon.terminate()
      discard daemon.waitForExit()
    daemon.close()

proc belongsToThisCase(pid: int; tempRoot: string): bool =
  ## Does this pid still look like something THIS CASE started?
  ##
  ## Asked before every signal, for the reason
  ## `tests/e2e/dev-env/t_e2e_repro_dev_sessions.nim`'s
  ## `belongsToSession` gives at length: a pid is a HISTORICAL RECORD,
  ## not a handle. Between a process exiting and this teardown running,
  ## the number can be reissued -- to a nim compiler, to a parallel
  ## test's fixture, to a login shell. Killing by number alone turns a
  ## reap of a dead fixture into an attack on a live stranger, and
  ## SIGKILL gives the stranger no say. This host runs CI jobs
  ## concurrently with developer trees, so that is not hypothetical.
  ##
  ## TWO WITNESSES, because this case's processes do not all name it the
  ## same way. The daemon and the `__repro-dev-session-http` child carry
  ## this case's own directories in their argv (`--endpoint`,
  ## `--state-dir`, `--project-root`); a declared SERVICE instance is
  ## `sh scripts/idp.sh`, which names nothing at all -- its only link to
  ## the case is its WORKING DIRECTORY, which the materialiser sets to
  ## the project root. Requiring argv alone would leave every service
  ## process behind, which is the leak this reap exists to close.
  ##
  ## `tempRoot` is this case's own `createTempDir` path, so either
  ## witness is conclusive: no process outside this case can mention it.
  ##
  ## LINUX ONLY, and the `else` branch is a decision rather than a gap --
  ## the same decision, for the same measured reason, that
  ## `belongsToSession` records. Both witnesses come from `/proc`, which
  ## no other platform has. Answering `true` elsewhere would reap by
  ## unverified pid; answering `false` would leak with certainty. This
  ## returns false, so on a platform where the identity cannot be
  ## checked the teardown does what it did before this change and says
  ## so, rather than signalling numbers it cannot vouch for.
  when defined(linux):
    let cmdline =
      try: readFile("/proc/" & $pid & "/cmdline")
      except CatchableError: ""
    if cmdline.len > 0 and cmdline.contains(tempRoot):
      return true
    try:
      let cwd = expandSymlink("/proc/" & $pid & "/cwd")
      cwd == tempRoot or cwd.startsWith(tempRoot & "/")
    except CatchableError:
      false
  else:
    false

proc reapCaseProcesses(c: Dss11Case) =
  ## Reap whatever this case started and `repro down` did not stop.
  ##
  ## WHY THIS IS NEEDED AND `repro down` IS NOT ENOUGH. Two recorded
  ## findings of this campaign meet here: `repro down` cannot stop a
  ## `repro dev` session, and `reapSession` is best-effort because it
  ## signals only the pids a session PUBLISHED. The observable result
  ## was that this file's `defer` -- `repro down` twice, then close the
  ## daemon -- left its fixture service shells running: a review of
  ## D-SS11 had to kill 12 orphaned `repro-dev-session-http` processes
  ## and 4 orphaned `idp.sh` loops accumulated over its runs. Each run
  ## of this file leaked, and every later run inherited them.
  ##
  ## SO THE SWEEP IS OVER `/proc`, NOT OVER RECORDED PIDS, and that is
  ## the one way it improves on `reapSession` rather than copying it. A
  ## pid-record walk cannot see a process the session never recorded --
  ## a grandchild a service forked, or a service whose pid was not
  ## written before its supervisor died -- which is precisely the
  ## residue `reapSession`'s own header admits it leaves. Every process
  ## this case started is under this case's `tempRoot` by argv or by
  ## cwd, so the path is a complete witness where a pid list is not.
  ##
  ## WHAT THIS IS NOT: a structural guarantee. It is a teardown sweep
  ## over a process table read at one instant, so a process that forks
  ## after the scan is missed, and the real fix is for a session to stop
  ## what it started on the way out. It is an assertion that the leak
  ## this file was observed to cause is cleaned up, not a proof that
  ## nothing can leak.
  ##
  ## SIGTERM FIRST, THEN A RE-CHECK, THEN SIGKILL. The re-check is not
  ## belt-and-braces: a pid that exited under the SIGTERM needs no
  ## SIGKILL, and if its number has already been reissued the second
  ## signal is exactly the one that must not be sent.
  when defined(linux):
    proc caseOwnedPids(): seq[int] =
      result = @[]
      for kind, path in walkDir("/proc"):
        if kind != pcDir:
          continue
        let name = path.extractFilename
        var pid = 0
        try: pid = parseInt(name)
        except ValueError: continue
        if pid <= 0 or pid == getCurrentProcessId():
          continue
        if belongsToThisCase(pid, c.tempRoot):
          result.add(pid)
    # `posix.kill` rather than a `kill(1)` command string: the signal is
    # sent by this process, with no shell in the path. That is the
    # in-tree idiom (`t_declared_daemon_ipc_trust.nim`,
    # `t_thin_client_refuses_to_exec_itself.nim`) and it keeps this
    # teardown clear of `scripts/check_shell_command_strings.sh`'s
    # subject -- a shell operator inside a command string that Windows
    # never hands to a shell.
    for signal in [SIGTERM, SIGKILL]:
      let pids = caseOwnedPids()   # re-read before EACH round
      if pids.len == 0:
        break
      for pid in pids:
        discard posix.kill(Pid(pid), signal)
      sleep(300)

proc cliStateStoreRoot(c: Dss11Case): string =
  ## The CLI's own state store for this case: `$HOME/.cache/repro/state`
  ## under the substituted `HOME`.
  ##
  ## IT IS NOT THE DAEMON'S. The daemon's instance records are under its
  ## `--state-root`, and these two roots being different is a measured
  ## property of this tree -- it is the reason the declared contribution
  ## points travel on the daemon's converge RESPONSE rather than being
  ## read out of a store by the client. Both roots are inside this
  ## case's throwaway tree, so neither is the developer's.
  c.tempRoot / "home" / ".cache" / "repro" / "state"

proc recordWithSuffix(c: Dss11Case; suffix: string):
    Option[ResourceStateRecord] =
  ## The one record in the CLI's store whose address ends with `suffix`.
  ##
  ## FOUND BY ADDRESS rather than by a predicted filename: the store
  ## hashes an address into a filename, and a predicted path that went
  ## stale would make every assertion below pass vacuously. The caller
  ## asserts there is exactly one.
  let root = c.cliStateStoreRoot
  if not dirExists(root):
    return none(ResourceStateRecord)
  var found: seq[ResourceStateRecord] = @[]
  for rec in openStateStore(root).listStateRecords():
    if rec.address.endsWith(suffix):
      found.add(rec)
  if found.len > 1:
    raise newException(ValueError,
      "expected at most one record ending in `" & suffix & "` under " &
      root & ", found " & $found.len)
  if found.len == 0: none(ResourceStateRecord) else: some(found[0])

proc registrationSet(c: Dss11Case): ServiceRegistrationSet =
  ## The instance's registration set, decoded by the real codec out of
  ## the real record the CLI wrote.
  let rec = recordWithSuffix(c, ServiceRegistrationsAddressSuffix)
  if rec.isNone:
    raise newException(ValueError,
      "no registration record under " & c.cliStateStoreRoot)
  decodeServiceRegistrations(rec.get.address, rec.get.attrsTypeId,
    rec.get.attrsJson)

proc contributionSet(c: Dss11Case): ServiceContributionSet =
  let rec = recordWithSuffix(c, ServiceContributionsAddressSuffix)
  if rec.isNone:
    raise newException(ValueError,
      "no contribution record under " & c.cliStateStoreRoot)
  decodeServiceContributions(rec.get.address, rec.get.attrsTypeId,
    rec.get.attrsJson)

proc mintedFor(value: ServiceRegistrationSet; member: string): string =
  mintedIdFor(value, member)

proc contributorFor(value: ServiceRegistrationSet; member: string): string =
  for reg in value.registrations:
    if reg.member == member:
      return reg.contributor
  ""

proc memberCount(value: ServiceRegistrationSet): int =
  value.registrations.len

suite "D-SS11 §4.6 — a consumer in another process contributes to the instance":
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
  var c: Dss11Case
  var daemon: owned(Process)

  setup:
    if not prepared:
      c = prepareCase()
      prepared = true
      daemon = c.startDaemon()

  defer:
    if prepared:
      discard c.runRepro(c.consumerProject,
        @["down", "--activity=" & ConsumerActivity])
      discard c.runRepro(c.ownerProject,
        @["down", "--activity=" & OwnerActivity])
      c.closeDaemon(daemon)
      # REAP BEFORE THE TREE IS REMOVED, and after the daemon is closed.
      # Before the removal because the identity witness is the path: a
      # process whose cwd has been deleted still answers, but the argv
      # witness is the stronger of the two and reading it is free while
      # the tree exists. After `closeDaemon` because the daemon's own argv
      # names this case's `tempRoot`, so the sweep would otherwise kill
      # the daemon out from under the graceful `repro down` calls above.
      c.reapCaseProcesses()
      try: removeDir(c.tempRoot) except OSError, IOError: discard

  # ONE PROCESS PER CASE. The suite runner executes every case in a process
  # of its own (`--run "<suite>::<case>"`), and each such process prepares a
  # FRESH fixture and daemon in `setup` above. The cases below are one
  # scenario told in steps, and a later step asserts on state an earlier
  # step created -- so each step is a template, and a case first REPLAYS the
  # earlier steps its state depends on, assertions and all, then runs its
  # own. Run alone, a case therefore measures exactly what it measured as
  # part of the sequence; a prerequisite step that fails fails the dependent
  # case too, at that step's own assertion, rather than letting it pass or
  # fail on a fixture it never built.

  template ownerAppliesTheConsumersContribution() =
    # The steps of case "the owner materialises, the consumer attaches and deposits, the owner applies".
    # STEP 1 -- the owner's `repro up` materialises the instance and
    # registers its own member. One process.
    let ownerFirst = ownerUp(c)
    checkpoint("owner up #1:\n" & ownerFirst.output)
    check ownerFirst.exitCode == 0
    check ownerFirst.output.contains("service `" & ServiceName & "` ")
    check ownerFirst.output.contains(SharedIdentity)
    let afterOwner = c.registrationSet
    check memberCount(afterOwner) == 1
    let ownerMinted = mintedFor(afterOwner, OwnerMember)
    check ownerMinted.len > 0
    # The owner's own member is attributed to THE PORT, not to the owner
    # package, and that is correct rather than a gap: it comes from the
    # `config:` DEFAULT, which `recordContributionPointRaw` seeds as a
    # `coReplace` at `epDefault` with `package: ""` -- L8's "the empty
    # string means the port itself -- a construction default". Measured
    # here rather than assumed, because the consumer's member below IS
    # attributed to a package and the contrast is the evidence that
    # attribution is carried rather than filled in.
    check contributorFor(afterOwner, OwnerMember) == ""
    # The consumer's member is NOT there yet. This is the measurement
    # that makes step 3 mean something.
    check mintedFor(afterOwner, ConsumerMember).len == 0

    # STEP 2 -- the consumer's `repro up`, a DIFFERENT process, resolves
    # the owner's service, attaches to the running instance and deposits
    # its contribution.
    let consumerUpResult = consumerUp(c)
    checkpoint("consumer up:\n" & consumerUpResult.output)
    check consumerUpResult.exitCode == 0
    # The resolver reports AT ITS OWN CALL SITE, which is §4.6's
    # requirement by name.
    check consumerUpResult.output.contains("repro.nim:")
    check consumerUpResult.output.contains("." & ServiceName & ".shared()`")
    check consumerUpResult.output.contains("deposited 1 contribution for `" &
      ConsumerPackage & "`")
    # The deposit is on disk, attributed, and keyed by the instance.
    let rows = c.contributionSet.contributions
    check rows.len == 1
    check rows[0].point == ConvergedPoint
    check rows[0].contributor == ConsumerPackage
    check rows[0].operation == "coAppend"
    check rows[0].precedence == "epSet"
    check rows[0].members == @[ConsumerMember]
    check rows[0].site.contains("repro.nim:")
    # The consumer did NOT materialise a second instance, and its
    # contribution is not registered yet: the owner applies it when it
    # converges.
    check mintedFor(c.registrationSet, ConsumerMember).len == 0

    # STEP 3 -- the owner converges again, a THIRD process, and applies
    # the contribution. THIS IS THE CLAUSE.
    let ownerSecond = ownerUp(c)
    checkpoint("owner up #2:\n" & ownerSecond.output)
    check ownerSecond.exitCode == 0
    check ownerSecond.output.contains(
      "applying 1 contributed member from 1 cross-process contribution")
    let applied = c.registrationSet
    check memberCount(applied) == 2
    check mintedFor(applied, ConsumerMember).len > 0
    # Attributed to the CONSUMER, not to the owner that converged it.
    check contributorFor(applied, ConsumerMember) == ConsumerPackage
    # L8's byte-identical property, with the second consumer arriving
    # THROUGH THE RESOLVER: the owner's own registration is untouched.
    check mintedFor(applied, OwnerMember) == ownerMinted

  template secondMemberLandsWithoutReminting() =
    # The steps of case "a second member from the same consumer lands without re-minting the first".
    # The same consumer's recipe grows a member. Its deposit REPLACES its
    # own rows and leaves the owner's registration byte-identical.
    let before = c.registrationSet
    let ownerMinted = mintedFor(before, OwnerMember)
    let consumerMinted = mintedFor(before, ConsumerMember)
    check ownerMinted.len > 0
    check consumerMinted.len > 0
    writeFile(c.consumerProject / "repro.nim", "import repro_project_dsl\n" &
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
      "        identity stable \"com.example.dss11.app\"\n" &
      "        scope project\n" &
      "        workingDirectory \".\"\n" &
      "        readiness fileExists(\"state/app.ready\", timeoutMs = 60000)\n" &
      "\n" &
      "    enable stack(sso = " & OwnerPackage & ".sso." & ServiceName &
        ".shared(\n" &
      "      " & ConvergedPoint & " = append(\"" & ConsumerMember &
        "\", \"" & SecondConsumerMember & "\")))\n")
    let consumerAgain = consumerUp(c)
    checkpoint("consumer up #2:\n" & consumerAgain.output)
    check consumerAgain.exitCode == 0
    check consumerAgain.output.contains("replacing 1")
    let ownerThird = ownerUp(c)
    checkpoint("owner up #3:\n" & ownerThird.output)
    check ownerThird.exitCode == 0
    check ownerThird.output.contains("applying 2 contributed members")
    let applied = c.registrationSet
    check memberCount(applied) == 3
    check mintedFor(applied, OwnerMember) == ownerMinted
    check mintedFor(applied, ConsumerMember) == consumerMinted
    check mintedFor(applied, SecondConsumerMember).len > 0
    check contributorFor(applied, SecondConsumerMember) == ConsumerPackage

  template staleLiftIsRefused() =
    # The steps of case "the owner's definition moved and its artifact did not: a STALE LIFT".
    # Shared-Development-Services §4.3's SAME-GENERATION PRECONDITION,
    # measured END TO END THROUGH THE REAL CLI, against a real owner
    # whose recipe has just been edited.
    #
    # THIS CASE EXISTS BECAUSE THE NEXT ONE USED TO CONFLATE TWO THINGS.
    # The skew case below edits the owner's recipe and does NOT re-lift,
    # so before the precondition existed the consumer's resolver read an
    # artifact describing the OLD definition -- and §4.3's table, reading
    # only that artifact, said nothing. H6 recorded exactly that: the
    # attach reported `AttachSilently` and the refusal came entirely from
    # the point-level check. With the precondition in place the stale
    # artifact is caught FIRST, which is what the clause is for, and the
    # two refusals are now separable: this case is the stale one, and the
    # next re-lifts so that the point-level one is what fires.
    # ONLY the owner's recipe moves. The consumer's is left exactly as the
    # previous case left it, so the ONE thing that changed between a
    # passing `consumerUp` and this one is the owner's definition having
    # moved out from under its artifact.
    writeFile(c.ownerProject / "repro.nim", ownerRecipe(true))
    let stale = consumerUp(c)
    checkpoint("consumer up (stale lift):\n" & stale.output)
    check stale.exitCode == 1
    check stale.output.contains("THE LIFT IS STALE")
    # It NAMES the artifact it read, the source that moved, and the
    # command to re-run -- §4.3's "naming what to re-run".
    check stale.output.contains("project-interface.rbsz")
    check stale.output.contains("repro.nim (edited)")
    check stale.output.contains("Re-run `repro dev-env` in the project " &
      "that declares `" & OwnerPackage & "`")
    # And it is a REFUSAL, so NOTHING was deposited and nothing dropped:
    # the instance's contribution set still holds exactly what the
    # previous case left on it.
    check c.contributionSet.contributions.len == 1
    check memberCount(c.registrationSet) == 3

  template undeclaredPointIsRefused() =
    # The steps of case "a contribution to a point the RUNNING instance does not declare is refused".
    # THE VERSION-SKEW CASE, measured rather than simulated.
    #
    # The instance is still the one materialised from the owner's recipe
    # as it was, which converges ONE point. The owner's recipe is then
    # edited to converge TWO, and the instance is NOT re-materialised.
    #
    # The consumer then compiles CLEAN against the newer definition, and
    # it does so through the real machinery rather than by arrangement:
    # the consumer's `uses: "dss11owner"` reaches the producer by the
    # WORKSPACE-SIBLING import route, so the consumer's own provider
    # compile expands the owner's recipe as it stands NOW and the
    # generated declaration const carries both points. The running
    # instance's registry entry still carries the snapshot it was
    # materialised with.
    #
    # That is exactly the skew §4.6 names, and the refusal has to come
    # from what the INSTANCE declares. §4.6: "a contribution to an
    # absent point is the refusing row, not the warning row, because the
    # consumer asked for something the instance cannot do."
    writeFile(c.ownerProject / "repro.nim", ownerRecipe(true))
    # RE-LIFT THE OWNER, AND DO NOT RE-MATERIALISE IT. Added when §4.3's
    # same-generation precondition landed, and it is what makes this case
    # measure the point-level refusal rather than the stale-lift one --
    # the case above is the stale-lift half, deliberately separate.
    #
    # `repro shell` re-derives the owner's dev-env (and so re-lifts its
    # interface artifact and re-records its provenance) WITHOUT
    # converging any shared instance: converging is `repro up` / `repro
    # dev`. So after this the owner's artifact describes the NEW
    # definition, the RUNNING instance still carries the snapshot it was
    # materialised with, and that is precisely the skew §4.6 names.
    let relift = c.runRepro(c.ownerProject,
      @["shell", "--activity=" & OwnerActivity, "--print-env=json"])
    checkpoint("owner re-lift (no re-materialise):\n" & relift.output)
    check relift.exitCode == 0
    writeFile(c.consumerProject / "repro.nim",
      consumerRecipe(UnconvergedPoint & " = append(\"" & SkewMember &
        "\")"))
    let skew = consumerUp(c)
    checkpoint("consumer up (skew):\n" & skew.output)
    check skew.exitCode == 1
    check skew.output.contains("contributes to `" & UnconvergedPoint & "`")
    check skew.output.contains("declares no such contribution point")
    check skew.output.contains("refusing row, not the warning row")
    # NOTHING WAS DEPOSITED and nothing was dropped: the refusal is
    # total for that resolver, so the instance's contribution set still
    # holds only what was accepted before.
    let rows = c.contributionSet.contributions
    check rows.len == 1
    var skewPresent = false
    for row in rows:
      for member in row.members:
        if member == SkewMember:
          skewPresent = true
    check not skewPresent
    # And the registration set is unchanged, so the refusal did not
    # withdraw what was already registered.
    check mintedFor(c.registrationSet, SkewMember).len == 0
    check memberCount(c.registrationSet) == 3

  test "the owner materialises, the consumer attaches and deposits, the owner applies":
    ownerAppliesTheConsumersContribution()

  test "a second member from the same consumer lands without re-minting the first":
    ownerAppliesTheConsumersContribution()
    secondMemberLandsWithoutReminting()

  test "the owner's definition moved and its artifact did not: a STALE LIFT":
    ownerAppliesTheConsumersContribution()
    secondMemberLandsWithoutReminting()
    staleLiftIsRefused()

  test "a contribution to a point the RUNNING instance does not declare is refused":
    ownerAppliesTheConsumersContribution()
    secondMemberLandsWithoutReminting()
    undeclaredPointIsRefused()
