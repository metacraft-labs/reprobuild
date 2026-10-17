## Shared-Development-Services **§7.2** / L9's **F4** — THE IDENTIFIER THAT
## REACHES A CONSUMING SERVICE'S ARGV, AND WHICH REGISTRAR PUT IT THERE,
## MEASURED THROUGH A REAL `repro up`.
##
## F4, as L9 stated it: *"the minted client id reaches a consuming service's
## argv, asserted end to end through a real `repro up`."* L9 measured it NOT
## MET and recorded why — reprobuild's minter was a local digest, so
## "reprobuild's ledger and the launcher's real Zitadel applications remain
## two identifier spaces". §7.2 then settled who closes that: reprobuild owes
## the provenance, and the project owning the service owes the registrar.
##
## This file is the end-to-end half, in two runs of a real `repro up`:
##
##   **A — THE OFFLINE CONTROL.** No registrar program declared. The stack
##   still comes up, the consuming service still receives an identifier, and
##   that identifier is MARKED `development` all the way to the session file
##   the supervisor read it from. §7.2's fourth bullet is a requirement, not
##   a courtesy: "requiring one [an issuer] to bring a stack up would make
##   the offline path impossible. It is the *silence* that is wrong, not the
##   fallback." This case is the control that the fallback was not removed,
##   and that the silence was.
##
##   **B — THE ISSUER LANE.** A registrar program declared with
##   `REPRO_SERVICE_REGISTRAR`. The consuming service writes
##   `@issuer-minted:<member>@`, which refuses a development identifier by
##   construction, and the identifier that lands on its argv is byte-for-byte
##   the one the issuer's descriptor carries. The two identifier spaces L9
##   measured side by side are one space here.
##
## § WHAT IS REAL, AND IT IS ALMOST EVERYTHING
##
##   * a real workspace on a real filesystem, with a real
##     `.repro/workspace.toml` so `scope workspace` resolves by workspace
##     identity rather than by path;
##   * real projects whose real `repro.nim` recipes are compiled by the real
##     engine on each `repro up`;
##   * a real `repro daemon serve` in its own process, over its real socket;
##   * real `repro up` / `repro down` invocations, each a separate process;
##   * a real shared service: a detached `/bin/sh` that seeds, writes its
##     descriptor, and writes its readiness marker LAST — the ordering
##     §7.1 makes the registration's completion rule;
##   * a real consuming service, supervised by the session, whose argv this
##     test reads out of a file THAT SERVICE wrote. Not out of the session
##     metadata, not out of the plan: out of the process's own `"$@"`, which
##     is the only reading of "reaches a consuming service's argv" that
##     cannot be satisfied by bookkeeping.
##
## § THE ONE SUBSTITUTION, AND WHY IT IS THE HONEST ONE
##
## **Case B's issuer is a fixture, and its registrar program is a fixture of
## infra's.** There is no identity provider in this repository, by design —
## §7.2 settles that reprobuild ships no product registrar precisely because
## an issuer's management API is not a build tool's business. Booting the real
## one (Zitadel + its own Postgres + `initdb` + the org development TLS
## material) takes minutes and binds a port shared with every other developer
## in the workspace.
##
## So what case B proves is REPROBUILD'S HALF: a declared program is reached,
## its answer is validated, its provenance is carried through the store,
## through the session file, through `serviceSpecFromSummary` and onto a real
## child's argv. The other half — that infra's real registrar returns the
## client ids Zitadel actually minted — is proven in `infra` by
## `tests/unit/test-sso-register-relying-party.sh` against the real
## descriptor shape, and the registration itself is `register_rp()`'s in
## `infra/services/zitadel/dev-server.sh`, exercised by
## `infra/tests/zitadel-process-rehearsal.sh` against a real instance.
##
## The two halves meet at the protocol, and BOTH SIDES OF IT ARE EXERCISED BY
## REAL PROGRAMS: this file's fixture and infra's registrar answer the same
## `reprobuild.service-registrar-answer.v1`. What remains unmeasured anywhere
## is the single composition — infra's registrar driven by a real `repro up`
## against a real Zitadel — and that is stated rather than implied.
##
## § MOCK POLICY — NO MOCK OBJECTS, AND NONE MAY BE ADDED
##
## There is no test double in this file: no substituted type, no injected
## callback, no in-process stand-in. The fixtures are real programs
## (`/bin/sh` scripts) in a real tree, which is what every service in a
## developer's workspace is. The registrar is injected by `repro up` itself
## from the declared program, not by this test.

import std/[json, os, osproc, strtabs, streams, strutils, tempfiles,
    times, unittest]
when defined(linux):
  import std/posix          # kill / SIGTERM / SIGKILL for the teardown reap

import repro_cli_support/dev_session      # the two argv token families
import repro_cli_support/service_registrar  # the declared-program protocol
import repro_resources/readiness_edge    # the §7.2 provenance vocabulary
import repro_test_support

const
  OfflinePackage = "dss72offline"
  IssuerPackage = "dss72issuer"
  Activity = "sso"
  Member = "dss72-site"
  IssuerClientId = "394610871109772528"
    ## Shaped like Zitadel's (an 18-digit snowflake) and deliberately NOT
    ## 24 hex characters, which is what the development registrar's
    ## `blake3DomainDigest(...)[0 ..< 24]` produces. The two are
    ## distinguishable here by text as well as by stamp, which is what
    ## lets each case assert it did not get the other one's value.
  ChangedIssuerClientId = "394615916756821232"
    ## What the issuer answers in case C, after an operator deleted and
    ## re-created the application: Zitadel mints a NEW client id while the
    ## store still holds the old one.
  DevIdLength = 24

proc repoRootDir(): string = getCurrentDir()

proc writeExecutable(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc reproBinary(): string =
  requireBinary(repoRootDir() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  Dss72Case = object
    tempRoot: string
    workspaceRoot: string
    offlineProject: string
    issuerProject: string
    reproBin: string

proc recipe(packageName, identity, token: string): string =
  ## One activity, two services.
  ##
  ## `idp` is the SHARED one: it carries `instance:` (so the daemon owns
  ## it and the session does not start it), a `converge` point, and a
  ## readiness marker its own script writes LAST.
  ##
  ## `app` is the CONSUMER: an ordinary supervised service whose argv
  ## carries a minted-attribute token. It is the thing F4 is about.
  "import repro_project_dsl\n" &
  "\n" &
  "package " & packageName & ":\n" &
  "  devEnv:\n" &
  "    activity " & Activity & "():\n" &
  "      config:\n" &
  "        relyingParties: seq[string] = @[\"" & Member & "\"]\n" &
  "\n" &
  "      service idp:\n" &
  "        executable executableAtPath(\"/bin/sh\")\n" &
  "        args \"scripts/idp.sh\"\n" &
  "        identity stable \"" & identity & "\"\n" &
  "        scope workspace\n" &
  "        workingDirectory \".\"\n" &
  "        readiness fileExists(\"state/idp.ready\", timeoutMs = 60000)\n" &
  "        instance:\n" &
  "          lease delayed(3600)\n" &
  "        converge relyingParties\n" &
  "\n" &
  "      service app:\n" &
  "        executable executableAtPath(\"/bin/sh\")\n" &
  "        args \"scripts/app.sh\"\n" &
  "        args \"--client-id\"\n" &
  "        args \"" & token & "\"\n" &
  "        identity stable \"" & identity & ".app\"\n" &
  "        scope project\n" &
  "        workingDirectory \".\"\n" &
  "        readiness fileExists(\"state/app.ready\", timeoutMs = 60000)\n" &
  "\n" &
  "    enable " & Activity & "\n"

const
  PlainIdpScript = """#!/bin/sh
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
# WRITE THE REAL ARGV. This file is what the assertions read: the
# identifier as the consuming PROCESS received it, not as any of
# reprobuild's own records describe it.
mkdir -p state
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

proc prepareCase(): Dss72Case =
  result.tempRoot = createTempDir("repro-dss72-cli-", "")
  result.workspaceRoot = result.tempRoot / "ws"
  createDir(result.workspaceRoot / ".repro")
  writeFile(result.workspaceRoot / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n" &
    "\n[workspace]\nproject = \"dss72-integration\"\n")
  result.offlineProject = result.workspaceRoot / OfflinePackage
  result.issuerProject = result.workspaceRoot / IssuerPackage
  createDir(result.offlineProject)
  createDir(result.issuerProject)

  writeExecutable(result.offlineProject / "scripts" / "idp.sh",
    PlainIdpScript)
  writeExecutable(result.offlineProject / "scripts" / "app.sh", AppScript)
  writeFile(result.offlineProject / "repro.nim",
    recipe(OfflinePackage, "com.example.dss72.offline",
      MintedAttributeTokenPrefix & Member & MintedAttributeTokenSuffix))

  writeExecutable(result.issuerProject / "scripts" / "idp.sh",
    SeedingIdpScript.replace("MEMBER", Member)
      .replace("CLIENTID", IssuerClientId))
  writeExecutable(result.issuerProject / "scripts" / "app.sh", AppScript)
  writeExecutable(result.issuerProject / "scripts" / "registrar.sh",
    RegistrarScript)
  writeFile(result.issuerProject / "repro.nim",
    recipe(IssuerPackage, "com.example.dss72.issuer",
      IssuerMintedAttributeTokenPrefix & Member &
        MintedAttributeTokenSuffix))
  result.reproBin = reproBinary()

proc daemonEndpoint(c: Dss72Case): string =
  daemonSocketEndpoint(c.tempRoot.extractFilename)

proc daemonStateDir(c: Dss72Case): string = c.tempRoot / "daemon-state"
proc daemonLeaseRoot(c: Dss72Case): string = c.tempRoot / "lease-state"
proc daemonLogPath(c: Dss72Case): string =
  c.daemonStateDir / "logs" / "repro-daemon.log"

proc daemonArgs(c: Dss72Case): seq[string] =
  @["--endpoint", c.daemonEndpoint,
    "--state-dir", c.daemonStateDir,
    "--state-root", c.daemonLeaseRoot,
    "--log", c.daemonLogPath]

proc envFor(c: Dss72Case; registrarProgram = ""): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["REPROBUILD_SOURCE_ROOT"] = repoRootDir()
  result["REPRO_DAEMON_ENDPOINT"] = c.daemonEndpoint
  result["REPRO_DAEMON_STATE_DIR"] = c.daemonStateDir
  result["XDG_CACHE_HOME"] = c.tempRoot / "cache"
  result["HOME"] = c.tempRoot / "home"
  result["REPROBUILD_PROGRESS"] = "quiet"
  # §7.2's declared program. DELETED rather than set to "" for the
  # offline case: an empty value and an unset one must mean the same
  # thing, and the case that proves the offline path has to be the shape
  # a developer who never heard of the variable actually has.
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

proc runRepro(c: Dss72Case; cwd: string; args: openArray[string];
              registrarProgram = ""):
    tuple[exitCode: int; output: string] =
  runProgram(c.reproBin, args, cwd, c.envFor(registrarProgram))

proc stopDaemon(c: Dss72Case) =
  discard runProgram(c.reproBin, @["daemon", "stop"] & c.daemonArgs,
    repoRootDir(), c.envFor())
  try: removeFile(c.daemonEndpoint) except OSError, IOError: discard

proc waitForDaemonRunning(c: Dss72Case; timeoutSeconds = 60.0) =
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

proc startDaemon(c: Dss72Case): owned(Process) =
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

proc closeDaemon(c: Dss72Case; daemon: var owned(Process)) =
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
  ## `t_dss11_cross_process_contribution_reaches_the_instance.nim`'s twin
  ## of this proc gives at length: a pid is a HISTORICAL RECORD, not a
  ## handle, and between a process exiting and this teardown running the
  ## number can be reissued — to a nim compiler, to a parallel test's
  ## fixture, to a login shell. Killing by number alone turns a reap of a
  ## dead fixture into an attack on a live stranger.
  ##
  ## TWO WITNESSES, because this case's processes do not all name it the
  ## same way: the daemon and the session's HTTP child carry this case's
  ## directories in their argv, while a declared SERVICE instance is
  ## `sh scripts/idp.sh`, whose only link to the case is its working
  ## directory. Either is conclusive — no process outside this case can
  ## mention its `createTempDir` path.
  ##
  ## LINUX ONLY, and the `else` is a decision rather than a gap: both
  ## witnesses come from `/proc`. Answering `true` elsewhere would reap by
  ## unverified pid; this answers `false`, so on such a platform the
  ## teardown does what it did before and says so.
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

proc reapCaseProcesses(c: Dss72Case) =
  ## Reap whatever this case started and `repro down` did not stop.
  ##
  ## `repro down` is not enough, and that is measured rather than
  ## assumed: the sibling D-SS11 integration file leaked its fixture
  ## shells on every run until this sweep was added there, because
  ## `reapSession` signals only the pids a session PUBLISHED. The sweep
  ## is over `/proc`, so it also sees a grandchild a service forked.
  ##
  ## WHAT THIS IS NOT: a structural guarantee. It reads a process table
  ## at one instant, so a process that forks after the scan is missed.
  ## SIGTERM first, then a RE-CHECK, then SIGKILL — the re-check is not
  ## belt-and-braces: a pid that exited under the SIGTERM needs no
  ## SIGKILL, and if its number has been reissued the second signal is
  ## exactly the one that must not be sent.
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

proc sessionDirOf(project: string): string =
  project / ".repro" / "dev-env" / Activity / "session"

proc mintedRows(project: string): JsonNode =
  let path = sessionDirOf(project) / "shared-instance-registrations.json"
  doAssert fileExists(path), "no minted record at " & path
  parseJson(readFile(path)){"registrations"}

proc mintedRowFor(project, member: string): JsonNode =
  for row in mintedRows(project):
    if row{"member"}.getStr("") == member:
      return row
  nil

proc eventDetails(project, kind: string): seq[string] =
  result = @[]
  let path = sessionDirOf(project) / "events.jsonl"
  if not fileExists(path):
    return
  for line in readFile(path).splitLines():
    if line.strip().len == 0:
      continue
    let node = parseJson(line)
    if node{"kind"}.getStr("") == kind:
      result.add(node{"detail"}.getStr(""))

proc waitForFile(path: string; timeoutSeconds = 60.0): bool =
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    if fileExists(path):
      return true
    sleep(200)
  false

proc argvOf(project: string): seq[string] =
  let path = project / "state" / "app.argv"
  doAssert waitForFile(path),
    "the consuming service never wrote its argv at " & path
  result = @[]
  for line in readFile(path).splitLines():
    if line.len > 0:
      result.add(line)

proc isLowerHex(value: string): bool =
  result = value.len > 0
  for ch in value:
    if ch notin {'0' .. '9', 'a' .. 'f'}:
      return false

suite "§7.2 / F4 — the registrar's identifier reaches a consuming service's argv":
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
  var c: Dss72Case
  var daemon: owned(Process)

  setup:
    if not prepared:
      c = prepareCase()
      prepared = true
      daemon = c.startDaemon()

  defer:
    if prepared:
      discard c.runRepro(c.offlineProject,
        @["down", "--activity=" & Activity])
      discard c.runRepro(c.issuerProject,
        @["down", "--activity=" & Activity])
      c.closeDaemon(daemon)
      # REAP AFTER `closeDaemon` -- the daemon's own argv names this case's
      # tempRoot, so the sweep would otherwise kill it out from under the
      # graceful `repro down` calls above -- and BEFORE the tree is removed,
      # because the path is the identity witness.
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

  template offlineStackGetsMarkedDevelopmentId() =
    # The steps of case "A: with NO issuer configured the stack comes up on a MARKED development id".
    # THE OFFLINE CONTROL. §7.2 keeps the development registrar as the
    # default, so this must still work -- and it must no longer be silent.
    let up = c.runRepro(c.offlineProject, @["up", "--activity=" & Activity])
    checkpoint("offline up:\n" & up.output)
    check up.exitCode == 0

    # 1. THE STACK CAME UP, and the consuming service really ran: this is
    #    its own argv, written by the process itself.
    let argv = argvOf(c.offlineProject)
    checkpoint("argv: " & $argv)
    check argv.len == 2
    check argv[0] == "--client-id"
    # 2. IT RECEIVED THE DEVELOPMENT REGISTRAR'S IDENTIFIER -- 24 lower
    #    hex characters, which is what `blake3DomainDigest(...)[0 ..< 24]`
    #    produces -- and NOT the issuer-shaped id case B asserts.
    check argv[1].len == DevIdLength
    check isLowerHex(argv[1])
    check argv[1] != IssuerClientId

    # 3. THE MARK IS ON THE VALUE, in the session file the supervisor read
    #    it from. This is the clause: without it argv[1] above is "a
    #    well-formed identifier that no issuer has ever heard of",
    #    indistinguishable from the real thing.
    let row = mintedRowFor(c.offlineProject, Member)
    check row != nil
    check row{"mintedId"}.getStr("") == argv[1]
    check row{"provenance"}.getStr("") == $rprDevelopment

    # 4. WHICH REGISTRAR IS INSTALLED IS IN THE SESSION EVENT LOG, so
    #    "the login failed" and "this workspace never talked to an issuer"
    #    are one question rather than two.
    let installed = eventDetails(c.offlineProject, RegistrarInstalledEventKind)
    checkpoint("registrar.installed: " & $installed)
    check installed.len == 1
    check installed[0].contains("registrar=" & DevelopmentRegistrarName)
    check installed[0].contains("provenance=" & $rprDevelopment)
    # ...and `repro up` said so on its own output too.
    check up.output.contains(DevelopmentRegistrarName)

  template issuerIdLandsOnArgv() =
    # The steps of case "B: with the owning project's registrar declared, the ISSUER's id lands on argv".
    # F4's clause. The consuming service writes `@issuer-minted:`, which
    # a development identifier cannot satisfy, so a passing case here is
    # a case in which the value really did come from the registrar the
    # project supplied.
    let program = c.issuerProject / "scripts" / "registrar.sh"
    let up = c.runRepro(c.issuerProject, @["up", "--activity=" & Activity],
      registrarProgram = program)
    checkpoint("issuer up:\n" & up.output)
    check up.exitCode == 0

    let argv = argvOf(c.issuerProject)
    checkpoint("argv: " & $argv)
    check argv.len == 2
    # THE ASSERTION F4 ASKS FOR: the id on the consuming service's argv is
    # byte-for-byte the one the issuer's descriptor carries.
    check argv[1] == IssuerClientId
    # And it is NOT the development registrar's shape, which is the other
    # identifier space L9 measured.
    check argv[1].len != DevIdLength

    let row = mintedRowFor(c.issuerProject, Member)
    check row != nil
    check row{"mintedId"}.getStr("") == IssuerClientId
    check row{"provenance"}.getStr("") == $rprIssuer

    let installed = eventDetails(c.issuerProject, RegistrarInstalledEventKind)
    checkpoint("registrar.installed: " & $installed)
    check installed.len == 1
    check installed[0].contains("provenance=" & $rprIssuer)
    check installed[0].contains(program)
    # NOT the development registrar: a log that named both would leave the
    # reader unable to answer the question the line exists for.
    check not installed[0].contains(DevelopmentRegistrarName)

    # The registrar really was asked, through the real protocol, and its
    # request is still on disk for a developer to read.
    let request = sessionDirOf(c.issuerProject) / "registrar" /
      "registrar-request.json"
    check fileExists(request)
    let asked = parseJson(readFile(request))
    check asked{"schemaId"}.getStr("") == ServiceRegistrarRequestSchemaId
    check asked{"members"}[0].getStr("") == Member

  template changedIssuerIdIsRefused() =
    # The steps of case "C: the issuer changing a client id under a recorded one is REFUSED".
    # THE NEAR-MISS THIS CASE EXISTS FOR, AND IT ONLY EXISTS BECAUSE OF THE
    # FIX. L8 makes a registration byte-stable: a member that already has
    # one keeps it and the registrar is not asked again for it. §7.2 makes
    # the provenance a property of the installed registrar. Compose those
    # and a recorded row is reused and stamped `issuer` whatever the issuer
    # now says -- so an application deleted and re-created at the issuer
    # (which mints a NEW client id) would leave this workspace handing its
    # consumers the OLD one, under a stamp asserting the issuer minted it.
    #
    # Case B has already run against this instance, so the store holds a
    # row. Rewriting the descriptor is what an operator does at the issuer
    # without telling this workspace.
    let descriptor = c.issuerProject / "state" / "sso-dev.json"
    check fileExists(descriptor)
    writeFile(descriptor, readFile(descriptor).replace(IssuerClientId,
      ChangedIssuerClientId))
    let program = c.issuerProject / "scripts" / "registrar.sh"
    let up = c.runRepro(c.issuerProject, @["up", "--activity=" & Activity],
      registrarProgram = program)
    checkpoint("issuer up after the id changed:\n" & up.output)
    # REFUSED, not resolved either way: preferring the store would hand a
    # consumer a client id the issuer has replaced, and silently preferring
    # the issuer would rewrite a record L8 makes byte-stable on purpose.
    check up.exitCode != 0
    check up.output.contains("is recorded as `" & IssuerClientId & "`")
    check up.output.contains("now answers `" & ChangedIssuerClientId & "`")
    check up.output.contains("Refused rather than guessed")
    # The session file is rewritten with NO registration, which is the
    # pre-existing (and deliberate) behaviour of that write -- "a stale
    # file from a previous run would otherwise resolve a token the recipe
    # no longer declares". Asserted rather than glossed, because a reader
    # diagnosing this refusal will look for the row and should know it is
    # the STORE record, not this file, that still holds it.
    check mintedRowFor(c.issuerProject, Member) == nil

  template restoredIssuerConvergesAgain() =
    # The steps of case "C2: putting the issuer back makes the next converge succeed again".
    # The refusal must be recoverable by fixing the issuer, not a dead end
    # that needs the store deleted. With the descriptor back to what the
    # store recorded, the same command converges.
    let descriptor = c.issuerProject / "state" / "sso-dev.json"
    writeFile(descriptor, readFile(descriptor).replace(
      ChangedIssuerClientId, IssuerClientId))
    let program = c.issuerProject / "scripts" / "registrar.sh"
    let up = c.runRepro(c.issuerProject, @["up", "--activity=" & Activity],
      registrarProgram = program)
    checkpoint("issuer up after the id was put back:\n" & up.output)
    check up.exitCode == 0
    let row = mintedRowFor(c.issuerProject, Member)
    check row != nil
    check row{"mintedId"}.getStr("") == IssuerClientId
    check row{"provenance"}.getStr("") == $rprIssuer

  test "A: with NO issuer configured the stack comes up on a MARKED development id":
    offlineStackGetsMarkedDevelopmentId()

  test "B: with the owning project's registrar declared, the ISSUER's id lands on argv":
    issuerIdLandsOnArgv()

  test "C: the issuer changing a client id under a recorded one is REFUSED":
    issuerIdLandsOnArgv()
    changedIssuerIdIsRefused()

  test "C2: putting the issuer back makes the next converge succeed again":
    issuerIdLandsOnArgv()
    changedIssuerIdIsRefused()
    restoredIssuerConvergesAgain()
