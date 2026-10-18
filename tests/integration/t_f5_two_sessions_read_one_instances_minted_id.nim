## Shared-Development-Services **L9 F5** — TWO SEPARATE SESSIONS READ ONE
## INSTANCE'S MINTED IDENTIFIER, AND §7.2's STAMP SURVIVES THE CROSSING.
##
## § THE BLOCKER THIS FILE CLOSES
##
## L9's F4 drawer measured it exactly, at reprobuild `f927919fa`: *"The
## minted-attribute lane is SESSION-LOCAL. `substituteMintedAttributes`
## resolves a token out of `readSharedInstanceMintedAttributes(config.outDir)`;
## the only writer of that file is `convergeSharedServiceInstances` in the SAME
## `repro up`, into the same `<project>/.repro/dev-env/<activity>/session/`. So
## the consumer must live in the session that converged the instance."* A
## consuming service declared in a second product's own recipe, asking for a
## member the shared instance had **already minted**, was refused — and F5, the
## product recipe migration and §9's "declared once" were all blocked behind
## that one reader.
##
## § WHAT EACH CASE MEASURES
##
##   **1 — THE INSTANCE IS NOT RUNNING.** The owner's interface is lifted (so
##   the resolver has an identity, a scope and a fingerprint) and NO instance
##   is materialised. The consumer's `repro up` must refuse BY NAME and start
##   nothing. This case is first on purpose: it is the one that would pass
##   vacuously if the later cases had already left an instance running.
##
##   **2 — TWO SESSIONS, ONE INSTANCE, THE SAME BYTES.** The owner's `repro
##   up`, with the issuer's registrar program installed, mints the member. A
##   SECOND project's `repro up` — a different process, a different project
##   root, a different `.repro/dev-env/.../session/`, and NO registrar
##   installed — reaches the same identifier, and both consuming services'
##   REAL argv carry it. The comparison is byte equality between two files
##   written by two supervised processes in two sessions.
##
##   **4 — `repro down` TAKES THE CROSSED ROWS WITH IT.** A near-miss found
##   by probing this reader, in the same class as the one L9's review found in
##   `infra`'s `dev-server.sh`: a file that names a stopped instance's
##   identifiers and that nothing removed. See the case's own comment for why
##   it is a HAZARD and not a live defect, which is the honest distinction.
##
##   **3 — THE §7.2 STAMP SURVIVES THE CROSSING.** A second instance is
##   converged with NO registrar, so its rows are stamped `development`. From
##   the second session, `@issuer-minted:<member>@` must still be REFUSED, and
##   the refusal must name `development` — not merely fail. Then the same
##   project, the same instance and the same member with `@minted:` must
##   RESOLVE. That pair is the control that the refusal is the STAMP's doing
##   and not the crossing's: a cross-session reader that lost the stamp would
##   be strictly worse than the refusal it replaces, and it would pass a test
##   that only checked that `@issuer-minted:` failed.
##
## § WHAT IS REAL
##
##   * a real workspace on a real filesystem, with a real
##     `.repro/workspace.toml` so `scope workspace` resolves by workspace
##     identity rather than by path;
##   * four real projects whose real `repro.nim` recipes are compiled by the
##     real engine on every invocation;
##   * a real `repro daemon serve` in its own process, over its real socket;
##   * real `repro up` / `repro down` / `repro shell` invocations, each a
##     separate process;
##   * a real shared service — a detached `/bin/sh` that seeds, writes its
##     descriptor and writes its readiness marker LAST, the ordering §7.1
##     makes the registration's completion rule;
##   * the real CLI state store on disk, read back through the real
##     `decodeServiceRegistrations`, as the evidence that the stamp is DURABLE
##     and not only in the minting process's memory;
##   * two real consuming services, each supervised by its own session, whose
##     argv these assertions read out of a file THAT SERVICE wrote — out of
##     the process's own `"$@"`, which is the only reading of "two sessions
##     read the same identifier" that cannot be satisfied by bookkeeping.
##
## § MOCKS: NONE, AND THE ONE SUBSTITUTION NAMED
##
## There is no test double, stub, fake or monkey-patch anywhere in this file.
## Per `AGENTS.md` the one substitution is named instead: **the issuer is a
## fixture, and so is its registrar program.** There is no identity provider
## in this repository by design — §7.2 settles that reprobuild ships no
## product registrar, because an issuer's management API is not a build tool's
## business — and booting the real one (Zitadel, its own PostgreSQL, `initdb`,
## the org development TLS material) takes minutes and binds a port shared
## with every other developer in the workspace. `infra`'s
## `tests/integration-real/sso-issuer-minted-argv.sh` is where a real Zitadel
## answers; this file is reprobuild's half, and its fixture registrar is of
## exactly that script's shape: it reads the descriptor the running service
## wrote, answers the identifier out of it, and claims `issuer` provenance.
## The registration MINTER is injected by `repro up` itself and not by this
## test.

import std/[json, options, os, osproc, strtabs, streams, strutils, tempfiles,
    times, unittest]
when defined(linux):
  import std/posix          # kill / SIGTERM / SIGKILL for the teardown reap

import repro_cli_support/dev_session      # the two argv token families
import repro_cli_support/service_registrar  # the declared-program protocol
import repro_resources/service_registry
import repro_resources/state_store
import repro_test_support

const
  IssuerOwner = "f5issuerowner"
  IssuerConsumer = "f5issuerconsumer"
  DevOwner = "f5devowner"
  DevConsumer = "f5devconsumer"
  Activity = "sso"
  ConsumerActivity = "stack"
  ServiceName = "idp"
  ConvergedPoint = "relyingParties"
  Member = "https://f5-site.example.test:8443/callback"
    ## A member of the SHAPE a relying party really has, colons and all.
    ## Deliberately not a bare word: L9's review proved
    ## `dev_session.nim`'s registered-member LIST filters keys for `':'
    ## notin key`, so a realistic member is excluded from the diagnostic
    ## — and a fixture with a colon-free member cannot see it. The lookup
    ## itself is keyed on the whole string and is unaffected, which is
    ## what this member being here measures.
  ConsumerMember = "https://f5-consumer.example.test:8443/callback"
  IssuerClientId = "394610871109772528"
    ## Shaped like Zitadel's (an 18-digit snowflake) and deliberately NOT
    ## 24 hex characters, which is what the development registrar's
    ## `blake3DomainDigest(...)[0 ..< 24]` produces. The two are
    ## distinguishable by TEXT as well as by stamp here, which is what
    ## lets each case assert it did not get the other one's value.
  DevIdLength = 24

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
  F5Case = object
    tempRoot: string
    workspaceRoot: string
    issuerOwner: string
    issuerConsumer: string
    devOwner: string
    devConsumer: string
    reproBin: string

proc ownerRecipe(packageName, identity: string; seeding: bool): string =
  ## The OWNER's recipe: one typed `service` block carrying the identity,
  ## the scope, the command, the readiness probe, the `instance:` block
  ## and the `converge` point, plus ONE consuming service of its own.
  ##
  ## The owner's own consumer is what makes case 2 a comparison between
  ## TWO sessions rather than an assertion about one: the identifier has
  ## to arrive on an argv in the session that converged the instance AND
  ## on an argv in a session that did not, and the two have to be the
  ## same bytes.
  "import repro_project_dsl\n" &
  "\n" &
  "package " & packageName & ":\n" &
  "  devEnv:\n" &
  "    activity " & Activity & "():\n" &
  "      config:\n" &
  "        " & ConvergedPoint & ": seq[string] = @[\"" & Member & "\"]\n" &
  "\n" &
  "      service " & ServiceName & ":\n" &
  "        executable executableAtPath(\"/bin/sh\")\n" &
  "        args \"scripts/idp.sh\"\n" &
  "        identity stable \"" & identity & "\"\n" &
  "        scope workspace\n" &
  "        compatibility 1\n" &
  "        workingDirectory \".\"\n" &
  "        readiness fileExists(\"state/idp.ready\", timeoutMs = 60000)\n" &
  "        instance:\n" &
  "          lease delayed(3600)\n" &
  "        converge " & ConvergedPoint & "\n" &
  "\n" &
  "      service ownerApp:\n" &
  "        executable executableAtPath(\"/bin/sh\")\n" &
  "        args \"scripts/app.sh\"\n" &
  "        args \"--client-id\"\n" &
  "        args \"" &
    (if seeding: IssuerMintedAttributeTokenPrefix
     else: MintedAttributeTokenPrefix) & Member &
    MintedAttributeTokenSuffix & "\"\n" &
  "        identity stable \"" & identity & ".ownerApp\"\n" &
  "        scope project\n" &
  "        workingDirectory \".\"\n" &
  "        readiness fileExists(\"state/app.ready\", timeoutMs = 60000)\n" &
  "\n" &
  "    enable " & Activity & "\n"

proc consumerRecipe(packageName, ownerPackage, token: string): string =
  ## The CONSUMER's recipe. It declares NO shared service of its own: it
  ## resolves the owner's with `<package>.<activity>.<service>.shared(...)`
  ## at its own `enable` site, and its ONE supervised service's argv
  ## carries a minted-attribute token for a member the OWNER contributed.
  ##
  ## IT NAMES NO HOSTNAME, NO PORT AND NO IDENTIFIER. Everything it knows
  ## about the instance comes through the resolver, which is the whole
  ## point of F5: the second product does not learn the first product's
  ## deployment.
  "import repro_project_dsl\n" &
  "\n" &
  "package " & packageName & ":\n" &
  "  uses:\n" &
  "    \"" & ownerPackage & "\"\n" &
  "\n" &
  "  devEnv:\n" &
  "    activity " & ConsumerActivity &
    "(sso: SharedServiceHandle[LiftedServiceHandle]):\n" &
  "      service consumerApp:\n" &
  "        executable executableAtPath(\"/bin/sh\")\n" &
  "        args \"scripts/app.sh\"\n" &
  "        args \"--client-id\"\n" &
  "        args \"" & token & "\"\n" &
  "        identity stable \"com.example.f5." & packageName & ".app\"\n" &
  "        scope project\n" &
  "        workingDirectory \".\"\n" &
  "        readiness fileExists(\"state/app.ready\", timeoutMs = 60000)\n" &
  "\n" &
  "    enable " & ConsumerActivity & "(sso = " & ownerPackage & "." &
    Activity & "." & ServiceName & ".shared(\n" &
  "      " & ConvergedPoint & " = append(\"" & ConsumerMember & "\")))\n"

const
  PlainIdpScript = """#!/bin/sh
# The OFFLINE owner's service. It writes NO descriptor, because no
# registrar will read one: this instance's rows are minted by the CLI's
# own development registrar and stamped `development`.
mkdir -p state
touch state/idp.ready
trap 'exit 0' TERM INT
while :; do sleep 1; done
"""
  SeedingIdpScript = """#!/bin/sh
# The shape `infra/services/zitadel/dev-server.sh` has: seed, write the
# descriptor carrying the issuer's own client ids, and write the readiness
# marker LAST -- so anything ordered on this service's readiness starts
# against a fully seeded instance rather than a merely listening one.
mkdir -p state
sleep 1
cat > state/sso-dev.json <<JSON
{"issuer": "https://login.example.test:19443",
 "clients": {"MEMBER": "CLIENTID"}}
JSON
touch state/idp.ready
trap 'exit 0' TERM INT
while :; do sleep 1; done
"""
  AppScript = """#!/bin/sh
# WRITE THE REAL ARGV. These files are what the assertions read: the
# identifier as the consuming PROCESS received it, not as any of
# reprobuild's own records describe it.
#
# The previous run's file is removed FIRST. A stale argv file read as this
# run's is this campaign's own defect class, and the fix belongs in the
# writer as well as in the reader.
mkdir -p state
rm -f state/app.argv
printf '%s\n' "$@" > state/app.argv
touch state/app.ready
trap 'exit 0' TERM INT
while :; do sleep 1; done
"""
  RegistrarScript = """#!/bin/sh
# A registrar of the shape `infra/scripts/sso-register-relying-party.sh`
# has: read the request, look each requested member up in the descriptor
# the running service wrote, answer with the ISSUER's client id and claim
# `issuer` provenance. It speaks to no issuer itself -- the service's own
# seeding path did the registration, which is what §7.2 means by reusing
# the existing seeding path.
set -eu
answer=""
request=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --answer) answer="$2"; shift 2 ;;
    --request) request="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
descriptor="$(dirname "$0")/../state/sso-dev.json"
[ -f "$descriptor" ] || { echo "no descriptor at $descriptor" >&2; exit 1; }
# `for ... in $(jq)` and not a `while read` pipeline: a pipeline runs its
# body in a SUBSHELL, so `rows` would be discarded on every iteration and
# the answer would carry one row or none. The members here contain no
# whitespace, which is what makes word splitting safe.
rows="[]"
for member in $(jq -r '.members[]? // empty' "$request"); do
  id="$(jq -r --arg n "$member" '.clients[$n] // ""' "$descriptor")"
  [ -n "$id" ] || { echo "the issuer has no registration for $member" >&2; exit 1; }
  rows="$(jq -c --arg m "$member" --arg c "$id" '. + [{member: $m, clientId: $c}]' <<EOF
$rows
EOF
)"
done
jq -n --argjson regs "$rows" \
  '{schemaId: "reprobuild.service-registrar-answer.v1",
    provenance: "issuer",
    registrations: $regs}' > "$answer"
"""

proc prepareCase(): F5Case =
  result.tempRoot = createTempDir("repro-f5-cli-", "")
  result.workspaceRoot = result.tempRoot / "ws"
  createDir(result.workspaceRoot / ".repro")
  writeFile(result.workspaceRoot / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n" &
    "\n[workspace]\nproject = \"f5-integration\"\n")
  result.issuerOwner = result.workspaceRoot / IssuerOwner
  result.issuerConsumer = result.workspaceRoot / IssuerConsumer
  result.devOwner = result.workspaceRoot / DevOwner
  result.devConsumer = result.workspaceRoot / DevConsumer
  for project in [result.issuerOwner, result.issuerConsumer,
                  result.devOwner, result.devConsumer]:
    createDir(project)
    writeExecutable(project / "scripts" / "app.sh", AppScript)

  writeExecutable(result.issuerOwner / "scripts" / "idp.sh",
    SeedingIdpScript.replace("MEMBER", Member)
      .replace("CLIENTID", IssuerClientId))
  writeExecutable(result.issuerOwner / "scripts" / "registrar.sh",
    RegistrarScript)
  writeFile(result.issuerOwner / "repro.nim",
    ownerRecipe(IssuerOwner, "com.example.f5.issuer", seeding = true))
  writeFile(result.issuerConsumer / "repro.nim",
    consumerRecipe(IssuerConsumer, IssuerOwner,
      IssuerMintedAttributeTokenPrefix & Member &
        MintedAttributeTokenSuffix))

  writeExecutable(result.devOwner / "scripts" / "idp.sh", PlainIdpScript)
  writeFile(result.devOwner / "repro.nim",
    ownerRecipe(DevOwner, "com.example.f5.dev", seeding = false))
  writeFile(result.devConsumer / "repro.nim",
    consumerRecipe(DevConsumer, DevOwner,
      IssuerMintedAttributeTokenPrefix & Member &
        MintedAttributeTokenSuffix))
  result.reproBin = reproBinary()

proc daemonEndpoint(c: F5Case): string =
  daemonSocketEndpoint(c.tempRoot.extractFilename)

proc daemonStateDir(c: F5Case): string = c.tempRoot / "daemon-state"
proc daemonLeaseRoot(c: F5Case): string = c.tempRoot / "lease-state"
proc daemonLogPath(c: F5Case): string =
  c.daemonStateDir / "logs" / "repro-daemon.log"

proc daemonArgs(c: F5Case): seq[string] =
  @["--endpoint", c.daemonEndpoint,
    "--state-dir", c.daemonStateDir,
    "--state-root", c.daemonLeaseRoot,
    "--log", c.daemonLogPath]

proc envFor(c: F5Case; registrarProgram = ""): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["REPROBUILD_SOURCE_ROOT"] = repoRootDir()
  result["REPRO_DAEMON_ENDPOINT"] = c.daemonEndpoint
  result["REPRO_DAEMON_STATE_DIR"] = c.daemonStateDir
  # The CLI's own state store, which is where the registration set and the
  # cross-process contribution set live. Isolated per case so this test
  # never reads or writes the developer's `$HOME/.cache/repro` — and
  # SHARED between the two projects, which is the lane F5 crosses on:
  # §4.4 keys a shared instance's state by its identity, so one root and
  # two project roots is the whole mechanism.
  result["XDG_CACHE_HOME"] = c.tempRoot / "cache"
  result["HOME"] = c.tempRoot / "home"
  result["REPROBUILD_PROGRESS"] = "quiet"
  # §7.2's declared program. DELETED rather than set to "" for the offline
  # case: an empty value and an unset one must mean the same thing, and
  # the case that proves the offline path has to be the shape a developer
  # who never heard of the variable actually has.
  if registrarProgram.len > 0:
    result[ServiceRegistrarProgramEnvVar] = registrarProgram
  elif result.hasKey(ServiceRegistrarProgramEnvVar):
    result.del(ServiceRegistrarProgramEnvVar)

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

proc runRepro(c: F5Case; cwd: string; args: openArray[string];
              registrarProgram = ""):
    tuple[exitCode: int; output: string] =
  runProgram(c.reproBin, args, cwd, c.envFor(registrarProgram))

proc stopDaemon(c: F5Case) =
  discard runProgram(c.reproBin, @["daemon", "stop"] & c.daemonArgs,
    repoRootDir(), c.envFor())
  try: removeFile(c.daemonEndpoint) except OSError, IOError: discard

proc waitForDaemonRunning(c: F5Case; timeoutSeconds = 60.0) =
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

proc startDaemon(c: F5Case): owned(Process) =
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

proc closeDaemon(c: F5Case; daemon: var owned(Process)) =
  c.stopDaemon()
  if not daemon.isNil:
    if daemon.running():
      daemon.terminate()
      discard daemon.waitForExit()
    daemon.close()

proc belongsToThisCase(pid: int; tempRoot: string): bool =
  ## Does this pid still look like something THIS CASE started?
  ##
  ## The reasoning is
  ## `t_dss11_cross_process_contribution_reaches_the_instance.nim`'s
  ## `belongsToThisCase` verbatim in substance: a pid is a HISTORICAL
  ## RECORD, not a handle, so it is checked against TWO witnesses — this
  ## case's own `createTempDir` path in the process's argv, or as its
  ## working directory — before any signal is sent. Killing by number
  ## alone turns a reap of a dead fixture into an attack on a live
  ## stranger. Linux only, because both witnesses come from `/proc`;
  ## elsewhere it answers false and the teardown does what it did before
  ## this sweep existed.
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

proc reapCaseProcesses(c: F5Case) =
  ## Reap whatever this case started and `repro down` did not stop.
  ##
  ## NOT A STRUCTURAL GUARANTEE: it is a teardown sweep over a process
  ## table read at one instant, so a process that forks after the scan is
  ## missed. It is an assertion that this file cleans up the leak
  ## D-SS11's review measured (12 orphaned session-http processes and 4
  ## orphaned fixture shells accumulated over its runs), not a proof that
  ## nothing can leak.
  when defined(linux):
    proc caseOwnedPids(): seq[int] =
      result = @[]
      for kind, path in walkDir("/proc"):
        if kind != pcDir:
          continue
        var pid = 0
        try: pid = parseInt(path.extractFilename)
        except ValueError: continue
        if pid <= 0 or pid == getCurrentProcessId():
          continue
        if belongsToThisCase(pid, c.tempRoot):
          result.add(pid)
    for signal in [SIGTERM, SIGKILL]:
      let pids = caseOwnedPids()   # re-read before EACH round
      if pids.len == 0:
        break
      for pid in pids:
        discard posix.kill(Pid(pid), signal)
      sleep(300)

proc cliStateStoreRoot(c: F5Case): string =
  ## The CLI's own state store for this case: `$HOME/.cache/repro/state`
  ## under the substituted `HOME`. It is NOT the daemon's, whose records
  ## are under its `--state-root`; both are inside this case's throwaway
  ## tree, so neither is the developer's.
  c.tempRoot / "home" / ".cache" / "repro" / "state"

proc registrationSets(c: F5Case): seq[ServiceRegistrationSet] =
  ## Every registration set in the CLI's store, decoded by the real codec
  ## out of the real records the CLI wrote.
  ##
  ## FOUND BY ADDRESS SUFFIX rather than by a predicted filename: the
  ## store hashes an address into a filename, and a predicted path that
  ## went stale would make every assertion below pass vacuously.
  result = @[]
  let root = c.cliStateStoreRoot
  if not dirExists(root):
    return
  for rec in openStateStore(root).listStateRecords():
    if rec.address.endsWith(ServiceRegistrationsAddressSuffix):
      result.add(decodeServiceRegistrations(rec.address, rec.attrsTypeId,
        rec.attrsJson))

proc registrationFor(c: F5Case; identity, member: string):
    Option[ServiceRegistration] =
  ## The durable row for `member` on the instance whose key carries
  ## `identity`. `none` when no such row exists, which the caller
  ## distinguishes from an empty identifier rather than conflating with
  ## it.
  for value in c.registrationSets:
    if identity notin value.address:
      continue
    for reg in value.registrations:
      if reg.member == member:
        return some(reg)
  none(ServiceRegistration)

proc sessionDirOf(project, activity: string): string =
  project / ".repro" / "dev-env" / activity / "session"

proc mintedRowsOf(project, activity: string): JsonNode =
  ## This session's `shared-instance-registrations.json`, as JSON. An
  ## ABSENT file is an empty array rather than a raise: "the consumer's
  ## session has no such file" is one of the things these cases measure.
  let path = sessionDirOf(project, activity) / "shared-instance-registrations.json"
  if not fileExists(path):
    return newJArray()
  let rows = parseJson(readFile(path)){"registrations"}
  if rows.isNil: newJArray() else: rows

proc argvOf(project: string): seq[string] =
  ## The argv the supervised consuming service in `project` actually
  ## received, as it wrote it.
  let path = project / "state" / "app.argv"
  if not fileExists(path):
    raise newException(IOError, "the consuming service wrote no argv at " &
      path)
  result = @[]
  for line in readFile(path).splitLines():
    if line.len > 0:
      result.add(line)

proc clientIdFromArgv(project: string): string =
  ## The value after `--client-id` on that service's real argv.
  let argv = argvOf(project)
  for i in 0 ..< argv.len - 1:
    if argv[i] == "--client-id":
      return argv[i + 1]
  raise newException(ValueError,
    "no `--client-id` on the argv of " & project & ": " & $argv)

suite "L9 F5 — two sessions read one instance's minted identifier":
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
  var c: F5Case
  var daemon: owned(Process)

  setup:
    if not prepared:
      c = prepareCase()
      prepared = true
      daemon = c.startDaemon()

  defer:
    if prepared:
      for project in [c.issuerConsumer, c.devConsumer]:
        discard c.runRepro(project,
          @["down", "--activity=" & ConsumerActivity])
      for project in [c.issuerOwner, c.devOwner]:
        discard c.runRepro(project, @["down", "--activity=" & Activity])
      c.closeDaemon(daemon)
      # REAP BEFORE THE TREE IS REMOVED and AFTER the daemon is closed: the
      # daemon's own argv names this case's `tempRoot`, so an earlier sweep
      # would kill it out from under the graceful `repro down` calls.
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

  template resolverRefusesWithoutInstance() =
    # The steps of case "the instance is not running: the resolver refuses by name".
    # The owner's interface is LIFTED and no instance is materialised.
    # `repro shell --print-env=json` re-derives the owner's dev-env --
    # and so writes its project-interface artifact -- WITHOUT converging
    # any shared instance; converging is `repro up` / `repro dev`.
    let lift = c.runRepro(c.issuerOwner,
      @["shell", "--activity=" & Activity, "--print-env=json"])
    checkpoint("owner lift (no converge):\n" & lift.output)
    check lift.exitCode == 0

    let refused = c.runRepro(c.issuerConsumer,
      @["up", "--activity=" & ConsumerActivity])
    checkpoint("consumer up (no instance):\n" & refused.output)
    check refused.exitCode == 1
    # NAMED, and at the resolver's own call site. Both halves matter: the
    # daemon says what is absent, and the resolver says why it cannot
    # supply it.
    check refused.output.contains("no instance is running at")
    check refused.output.contains("com.example.f5.issuer")
    check refused.output.contains(
      "A resolver ATTACHES to an instance and cannot materialise one")
    check refused.output.contains("repro.nim:")
    # NOT AN EMPTY VALUE: nothing was read, nothing was substituted, and
    # the consuming service was never started.
    check not fileExists(c.issuerConsumer / "state" / "app.argv")
    check mintedRowsOf(c.issuerConsumer, ConsumerActivity).len == 0
    # And the read step was never reached, so it said nothing.
    check not refused.output.contains("minted attribute")

  template twoSessionsReadSameMintedId() =
    # The steps of case "two separate sessions read one instance's minted id, same bytes".
    # STEP 1 -- the OWNER's session. One process, with the issuer's
    # registrar program installed. It converges the instance, the
    # registrar answers out of the descriptor the running service wrote,
    # and the owner's OWN consuming service receives the identifier.
    let ownerUp = c.runRepro(c.issuerOwner,
      @["up", "--activity=" & Activity],
      registrarProgram = c.issuerOwner / "scripts" / "registrar.sh")
    checkpoint("issuer owner up:\n" & ownerUp.output)
    check ownerUp.exitCode == 0
    let ownerClientId = clientIdFromArgv(c.issuerOwner)
    check ownerClientId == IssuerClientId

    # THE STAMP IS DURABLE, not only in the minting process. This is the
    # record the second session reads, so it is asserted directly rather
    # than inferred from the second session succeeding.
    let durable = c.registrationFor("com.example.f5.issuer", Member)
    check durable.isSome
    check durable.get.mintedId == IssuerClientId
    check durable.get.provenance == rprIssuer
    check durable.get.registrar.startsWith("external:")

    # STEP 2 -- the CONSUMER's session. A DIFFERENT process, a different
    # project root, a different session directory, and NO registrar
    # installed: it attaches, it does not mint.
    let consumerUp = c.runRepro(c.issuerConsumer,
      @["up", "--activity=" & ConsumerActivity])
    checkpoint("issuer consumer up:\n" & consumerUp.output)
    check consumerUp.exitCode == 0
    # The read is SAID OUT LOUD, with the instance address and the count.
    check consumerUp.output.contains("read 1 minted attribute from instance")
    check consumerUp.output.contains("com.example.f5.issuer")

    # THE CLAUSE: the same bytes, on two real argvs, written by two
    # supervised processes in two sessions.
    let consumerClientId = clientIdFromArgv(c.issuerConsumer)
    check consumerClientId == IssuerClientId
    check consumerClientId == ownerClientId
    # And it is NOT the development identifier, which is what it would be
    # if the consumer's session had minted its own.
    check consumerClientId.len != DevIdLength

    # The stamp crossed WITH the value: the consumer's own session file
    # says `issuer`, which is what `@issuer-minted:` in its recipe asked
    # for and what the next case proves is refusable.
    let rows = mintedRowsOf(c.issuerConsumer, ConsumerActivity)
    check rows.len == 1
    check rows[0]{"member"}.getStr("") == Member
    check rows[0]{"mintedId"}.getStr("") == IssuerClientId
    check rows[0]{"provenance"}.getStr("") == $rprIssuer
    # The two sessions are genuinely two: the consumer's session
    # directory is its own, and the owner's still holds the owner's rows.
    check sessionDirOf(c.issuerConsumer, ConsumerActivity) !=
      sessionDirOf(c.issuerOwner, Activity)
    check mintedRowsOf(c.issuerOwner, Activity).len == 1

  template developmentStampSurvivesCrossing() =
    # The steps of case "the §7.2 stamp survives the crossing: a development id is refused".
    # A SECOND instance, converged with NO registrar, so every row it
    # mints is stamped `development` by the CLI's own default registrar.
    let devOwnerUp = c.runRepro(c.devOwner, @["up", "--activity=" & Activity])
    checkpoint("dev owner up:\n" & devOwnerUp.output)
    check devOwnerUp.exitCode == 0
    check devOwnerUp.output.contains("provenance " & $rprDevelopment)
    let devDurable = c.registrationFor("com.example.f5.dev", Member)
    check devDurable.isSome
    check devDurable.get.provenance == rprDevelopment
    let devId = devDurable.get.mintedId
    check devId.len == DevIdLength
    check devId != IssuerClientId

    # FROM THE SECOND SESSION, `@issuer-minted:` MUST STILL REFUSE. The
    # crossing delivered the row -- the resolver says so -- and the point
    # of use refused it on the stamp.
    let refused = c.runRepro(c.devConsumer,
      @["up", "--activity=" & ConsumerActivity])
    checkpoint("dev consumer up (@issuer-minted:):\n" & refused.output)
    check refused.exitCode != 0
    check refused.output.contains("read 1 minted attribute from instance")
    # IT NAMES THE PROVENANCE IT FOUND. Not merely "refused": a reader
    # that lost the stamp would refuse too, as `unstamped`, and this
    # assertion is what tells the two apart.
    check refused.output.contains("carries provenance `" &
      $rprDevelopment & "`")
    check refused.output.contains("DEVELOPMENT identifier")
    check refused.output.contains(IssuerMintedAttributeTokenPrefix & Member)
    # The development identifier did NOT reach the service.
    check not fileExists(c.devConsumer / "state" / "app.argv")

    # THE CONTROL, and it is the half that makes the refusal mean
    # something: the SAME project, the SAME instance and the SAME member
    # with `@minted:` -- which accepts whichever registrar is installed
    # -- RESOLVES, and resolves to the development identifier.
    #
    # `repro down` first. The refused run left a supervisor that reported
    # `failed`, and a second `repro up` contending with it would measure
    # the contention rather than the token.
    discard c.runRepro(c.devConsumer,
      @["down", "--activity=" & ConsumerActivity])
    writeFile(c.devConsumer / "repro.nim",
      consumerRecipe(DevConsumer, DevOwner,
        MintedAttributeTokenPrefix & Member & MintedAttributeTokenSuffix))
    let accepted = c.runRepro(c.devConsumer,
      @["up", "--activity=" & ConsumerActivity])
    checkpoint("dev consumer up (@minted:):\n" & accepted.output)
    check accepted.exitCode == 0
    check clientIdFromArgv(c.devConsumer) == devId
    let rows = mintedRowsOf(c.devConsumer, ConsumerActivity)
    check rows.len == 1
    check rows[0]{"provenance"}.getStr("") == $rprDevelopment

  template downRemovesCrossedRows() =
    # The steps of case "`repro down` removes the crossed rows a pure consumer read".
    # A NEAR-MISS OF THIS CHANGE'S OWN, found by probing it, and in the exact
    # class L9's review found in `infra`: `cleanup()` removed the readiness
    # marker and not the descriptor, so a product read a dead issuer's client
    # ids after a `down`. This session's minted record is the same shape — it
    # names identifiers of an instance this project has just stopped holding.
    #
    # A HAZARD AND NOT A LIVE DEFECT, and the difference is stated rather than
    # blurred: no RUN reads a stale table, because every `repro up` rewrites
    # it before the supervisor starts (a pure consumer has it REMOVED by
    # `convergeSharedServiceInstances`' no-declarations arm and then re-merged
    # by the resolver). What the removal closes is the window between a `down`
    # and the next `up`, in which the file on disk describes an instance that
    # may already be gone.
    #
    # THE PLACEMENT IS THE LOAD-BEARING PART. A pure consumer takes no holder
    # and therefore has NO LEDGER, so a removal placed after
    # `releaseSharedServiceInstances`' `ledger.entries.len == 0` early return
    # would be dead code for exactly the sessions this reader was built for.
    # This case is a PURE CONSUMER, which is what makes it able to see that.
    let before = mintedRowsOf(c.issuerConsumer, ConsumerActivity)
    check before.len == 1
    check before[0]{"mintedId"}.getStr("") == IssuerClientId
    let down = c.runRepro(c.issuerConsumer,
      @["down", "--activity=" & ConsumerActivity])
    checkpoint("issuer consumer down:\n" & down.output)
    check down.exitCode == 0
    check mintedRowsOf(c.issuerConsumer, ConsumerActivity).len == 0
    check not fileExists(sessionDirOf(c.issuerConsumer, ConsumerActivity) /
      "shared-instance-registrations.json")

  test "the instance is not running: the resolver refuses by name":
    resolverRefusesWithoutInstance()

  test "two separate sessions read one instance's minted id, same bytes":
    twoSessionsReadSameMintedId()

  test "the §7.2 stamp survives the crossing: a development id is refused":
    developmentStampSurvivesCrossing()

  test "`repro down` removes the crossed rows a pure consumer read":
    twoSessionsReadSameMintedId()
    downRemovesCrossedRows()
