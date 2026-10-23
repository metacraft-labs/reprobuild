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

import repro_resources/service_registry
import repro_resources/state_store
import repro_test_support
import repro_test_support/fixture_processes

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
    "    activity ordinary():\n" &
    "      service ordinaryApp:\n" &
    "        executable executableAtPath(\"/bin/sh\")\n" &
    "        args \"scripts/app.sh\"\n" &
    "        identity stable \"com.example.dss11.ordinary\"\n" &
    "        scope project\n" &
    "        workingDirectory \".\"\n" &
    "        readiness fileExists(\"state/app.ready\", timeoutMs = 60000)\n" &
    "    enable ordinary\n" &
    "\n" &
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
  # Every case owns a fresh workspace and daemon, whether run alone or as
  # part of the whole binary. Setup stays lazy so --list/--list-json never
  # resolves the engine or starts a daemon. Register cleanup before daemon
  # startup so a startup failure also removes this case's fixture.
  setup:
    let c = prepareCase()
    var daemon: owned(Process)
    defer:
      discard c.runRepro(c.consumerProject,
        @["down", "--activity=" & ConsumerActivity])
      discard c.runRepro(c.ownerProject,
        @["down", "--activity=" & OwnerActivity])
      c.closeDaemon(daemon)
      # REAP WHAT `repro down` DID NOT STOP: it does not stop everything a
      # session started. `repro_test_support/fixture_processes` records the
      # measured leak and the witnesses that decide what is signalled.
      # Before the tree is removed, and after the daemon is closed.
      # Before the removal because the identity witness is the path: a
      # process whose cwd has been deleted still answers, but the argv
      # witness is the stronger of the two and reading it is free while
      # the tree exists. After `closeDaemon` because the daemon's own argv
      # names this case's `tempRoot`, so the sweep would otherwise kill
      # the daemon out from under the graceful `repro down` calls above.
      # The reap raises when something outlives SIGKILL; the tree is
      # removed either way.
      try:
        reapFixtureProcesses(c.tempRoot)
      finally:
        try: removeDir(c.tempRoot) except OSError, IOError: discard

    daemon = c.startDaemon()

  # Each scenario replays every prerequisite against its own fresh fixture,
  # retaining the prerequisite's assertions. Whole-binary and isolated runs
  # therefore test the same transitions without inheriting an earlier case's
  # registrations, edited recipes or event log.

  test "an unselected resolver cannot break an ordinary activity":
    # No owner instance is started. Its lifted declaration is real, so
    # selecting the resolver below must refuse specifically for the
    # absent instance, while an unrelated selection must succeed.
    let lifted = c.runRepro(c.ownerProject,
      @["shell", "--activity=" & OwnerActivity, "--print-env=json"])
    checkpoint(lifted.output)
    if lifted.exitCode != 0:
      # Raising preserves the fixture's deferred cleanup. `require`
      # terminates the process before those defers can stop its daemon.
      raise newException(IOError, "owner interface lift failed:\n" & lifted.output)
    for attempt in 0 .. 1:
      let ordinary = c.runRepro(c.consumerProject,
        @["up", "--activity=ordinary"])
      checkpoint("ordinary up #" & $attempt & ":\n" & ordinary.output)
      check ordinary.exitCode == 0
      check ordinary.output.contains("session ")
      check not ordinary.output.contains(".shared()`")
      let stopped = c.runRepro(c.consumerProject,
        @["down", "--activity=ordinary"])
      checkpoint(stopped.output)
      check stopped.exitCode == 0
    let selected = consumerUp(c)
    checkpoint("selected resolver:\n" & selected.output)
    check selected.exitCode != 0
    check selected.output.contains("no instance is running")
    check selected.output.contains(".shared()`")

    # Positive control: the same ordinary activity with only the
    # resolver's enable removed also succeeds on an unfixed tree.
    writeFile(c.consumerProject / "repro.nim",
      consumerRecipe("").split("    enable stack")[0])
    let control = c.runRepro(c.consumerProject,
      @["up", "--activity=ordinary"])
    checkpoint("resolver removed:\n" & control.output)
    check control.exitCode == 0
    discard c.runRepro(c.consumerProject, @["down", "--activity=ordinary"])

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
    # prerequisite step left it, so the ONE thing that changed between a
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
    # prerequisite step left on it.
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
