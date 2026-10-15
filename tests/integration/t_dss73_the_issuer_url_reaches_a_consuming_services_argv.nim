## Shared-Development-Services **§7.3** — THE RUNNING INSTANCE'S ISSUER URL ON
## A CONSUMING SERVICE'S REAL ARGV, MEASURED THROUGH A REAL `repro up`.
##
## §7.3's decision:
##
## > **The issuer URL is a computed attribute OF THE INSTANCE, reached by the
## > same mechanism as the minted client id. It does not become a field on the
## > handle.**
##
## > The handle is resolved at **expansion**, and the issuer URL does not exist
## > then. It is a property of a *running* instance — which port it bound,
## > which hostname the selected environment gave it. A field on an
## > expansion-time value would have to be either empty or a guess.
##
## This file is the end-to-end half of that, and the fixture is built so that
## the "which port it bound" clause is literally true: the identity provider
## binds `('127.0.0.1', 0)` and lets the OS choose. **No recipe, no
## environment file and no line of this test knows that port before the
## instance is running**, so an implementation that resolved the issuer URL at
## expansion — from a handle field, from a configurable, from anything knowable
## before the process existed — cannot pass this file by any route.
##
## § THE READBACK, AND WHY IT IS NOT THE TOKEN'S OWN INPUT
##
## The weak version of this assertion compares the argv against the same
## descriptor the registrar read, which proves only that a string was copied
## twice. So case A **asks the live instance what it is serving**: it takes the
## URL off the consuming process's own argv, opens an HTTP connection to it, and
## reads the issuer out of the running identity provider's `/issuer` endpoint —
## from a variable in that process's own memory, over a real socket. The
## assertion is that the two agree. A stale URL, a guessed URL or a URL from a
## previous run fails it, because nothing answers at the other end.
##
## § WHAT IS REAL, AND IT IS ALMOST EVERYTHING
##
##   * a real workspace on a real filesystem, with a real `.repro/workspace.toml`;
##   * real projects whose real `repro.nim` recipes the real engine compiles;
##   * a real `repro daemon serve` in its own process, over its real socket;
##   * real `repro up` / `repro down` invocations, each a separate process;
##   * a real shared service: a real `python3` HTTP server that binds an
##     EPHEMERAL port, writes its descriptor, and writes its readiness marker
##     LAST — the ordering §7.1 makes the registration's completion rule;
##   * a real registrar program of the shape
##     `infra/scripts/sso-register-relying-party.sh` has, reached through the
##     real two-file protocol;
##   * a real consuming service whose argv this test reads out of a file THAT
##     SERVICE wrote — out of the process's own `"$@"`, which is the only
##     reading of "reaches a consuming service's argv" that cannot be satisfied
##     by bookkeeping;
##   * a real HTTP request to the real instance, for the readback.
##
## § THE ONE SUBSTITUTION, AND WHY IT IS THE HONEST ONE
##
## The issuer is a fixture, as it is in the §7.2 sibling file
## (`t_dss72_the_registrar_reaches_a_services_argv.nim`) and for the same
## reason: there is no identity provider in this repository by design, and
## booting the real one (Zitadel + its own Postgres + `initdb` + the org
## development TLS material) takes minutes and binds a port shared with every
## other developer in the workspace.
##
## What this file proves is REPROBUILD'S HALF: an attribute of a running
## instance, reported by the project's registrar, recorded on the instance's
## own durable record, carried into a second document, concretized late, and
## landing on a real child's argv — where it is confirmed against the instance
## itself. What remains unmeasured anywhere is the single composition of
## infra's registrar driven by a real `repro up` against a real Zitadel, and
## that is stated rather than implied.
##
## § MOCK POLICY — NO MOCK OBJECTS, AND NONE MAY BE ADDED
##
## There is no test double in this file: no substituted type, no injected
## callback, no in-process stand-in. The fixtures are real programs (a
## `/bin/sh` script, a `python3` server) in a real tree, which is what every
## service in a developer's workspace is. The registrar is injected by `repro
## up` itself from the declared program, not by this test.

import std/[httpclient, json, os, osproc, strtabs, streams, strutils,
    tempfiles, times, unittest]
when defined(linux):
  import std/posix          # kill / SIGTERM / SIGKILL for the teardown reap

import repro_cli_support/dev_session      # the three argv token families
import repro_cli_support/service_registrar  # the declared-program protocol
import repro_resources/readiness_edge    # IssuerAttributeName, the provenance
import repro_resources/service_registry  # the DURABLE record, read directly
import repro_resources/state_store       # ...through the real state store
import repro_test_support

const
  IssuerPackage = "dss73issuer"
  OfflinePackage = "dss73offline"
  Activity = "sso"
  Member = "dss73-site"
  IssuerClientId = "394615916756821232"
    ## Shaped like Zitadel's (an 18-digit snowflake) and deliberately NOT
    ## 24 hex characters, which is what the development registrar's
    ## `blake3DomainDigest(...)[0 ..< 24]` produces.
  ChangedIssuerClientId = "394615916756821999"
    ## What the issuer answers after the application was deleted and
    ## re-created there -- a DIFFERENT snowflake under a member this
    ## workspace has already recorded. §7.2's case C refusal fires on
    ## exactly this, and case D below composes it with an address move.
  IssuerToken = InstanceAttributeTokenPrefix & IssuerAttributeName &
    MintedAttributeTokenSuffix
  ClientIdToken = IssuerMintedAttributeTokenPrefix & Member &
    MintedAttributeTokenSuffix

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
  Dss73Case = object
    tempRoot: string
    workspaceRoot: string
    issuerProject: string
    offlineProject: string
    reproBin: string

proc recipe(packageName, identity: string): string =
  ## One activity, two services.
  ##
  ## `idp` is the SHARED one: `instance:`, a `converge` point, and a
  ## readiness marker its own process writes LAST.
  ##
  ## `app` is the CONSUMER, and its argv is §9.3's corrected worked
  ## example verbatim — one token of each family, both concretized late.
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
  "        args \"--issuer\"\n" &
  "        args \"" & IssuerToken & "\"\n" &
  "        args \"--client-id\"\n" &
  "        args \"" & ClientIdToken & "\"\n" &
  "        identity stable \"" & identity & ".app\"\n" &
  "        scope project\n" &
  "        workingDirectory \".\"\n" &
  "        readiness fileExists(\"state/app.ready\", timeoutMs = 60000)\n" &
  "\n" &
  "    enable " & Activity & "\n"

const
  IdpServer = """
# THE IDENTITY PROVIDER FIXTURE. It binds an EPHEMERAL port -- the OS
# chooses, nothing on disk predicts it -- and that is the whole point of
# this file: the issuer URL cannot be known before this process exists,
# so it cannot be a field on an expansion-time handle.
#
# The ordering is `infra/services/zitadel/dev-server.sh`'s: bind, seed,
# write the descriptor carrying the issuer's own client ids AND its own
# issuer URL, and write the readiness marker LAST -- so anything that
# `dependsOn` this service starts against a fully configured instance
# rather than a merely listening one (§7.1).
import http.server, json, os, pathlib, sys

MEMBER = sys.argv[1]
CLIENT_ID = sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/issuer":
            # ANSWERED FROM THIS PROCESS'S OWN MEMORY, which is what
            # makes the test's readback a question to the INSTANCE
            # rather than a second reading of the descriptor.
            body = ISSUER.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
ISSUER = "http://127.0.0.1:%d" % server.server_address[1]

state = pathlib.Path("state")
state.mkdir(parents=True, exist_ok=True)
(state / "sso-dev.json").write_text(json.dumps(
    {"issuer": ISSUER, "clients": {MEMBER: CLIENT_ID}}) + "\n")
# THE MARKER IS LAST.
(state / "idp.ready").write_text("")
server.serve_forever()
"""
  AppScript = """#!/bin/sh
# WRITE THE REAL ARGV. This file is what the assertions read: the
# values as the consuming PROCESS received them, not as any of
# reprobuild's own records describe them.
mkdir -p state
printf '%s\n' "$@" > state/app.argv
touch state/app.ready
trap 'exit 0' TERM INT
while :; do sleep 1; done
"""
  RegistrarScript = """#!/bin/sh
# A registrar of the shape `infra/scripts/sso-register-relying-party.sh`
# has: read the request, look each requested member up in the descriptor
# the running service wrote, answer with the ISSUER's client id, claim
# `issuer` provenance -- AND, per §7.3, report what the instance IS.
#
# It is the registrar that reports the issuer URL because it is the one
# component that has actually spoken to the running instance. The
# rejected alternatives are named in
# `t_dss73_the_registrar_answer_reports_the_instance.nim`'s header.
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
issuer="$(jq -r '.issuer // ""' "$descriptor")"
[ -n "$issuer" ] || { echo "the descriptor names no issuer" >&2; exit 1; }
rows="[]"
for member in $(jq -r '.members[]? // empty' "$request"); do
  id="$(jq -r --arg n "$member" '.clients[$n] // ""' "$descriptor")"
  [ -n "$id" ] || { echo "the issuer has no registration for $member" >&2; exit 1; }
  rows="$(jq -c --arg m "$member" --arg c "$id" '. + [{member: $m, clientId: $c}]' <<EOF
$rows
EOF
)"
done
jq -n --argjson regs "$rows" --arg iss "$issuer" \
  '{schemaId: "reprobuild.service-registrar-answer.v1",
    provenance: "issuer",
    registrations: $regs,
    instanceAttributes: {issuer: $iss}}' > "$answer"
"""

proc idpShim(python3: string): string =
  ## The client id is `IssuerClientId` UNLESS `state/client-id` exists, in
  ## which case the next instance answers whatever that file holds. Case D
  ## needs an instance that has BOTH rebound to a new port AND changed the
  ## member's registration -- which is what an operator who deleted and
  ## re-created the application at the issuer leaves behind -- and the two
  ## have to happen in ONE converge for the ordering to be under test.
  ## Absent, this is byte-for-byte the shape cases A, B and C run.
  "#!/bin/sh\n" &
  "cid=" & IssuerClientId & "\n" &
  "[ -f state/client-id ] && cid=\"$(cat state/client-id)\"\n" &
  "exec " & python3 & " scripts/idp.py " & Member & " \"$cid\"\n"

proc prepareCase(): Dss73Case =
  let python3 = findExe("python3")
  doAssert python3.len > 0, "this test needs a real python3 on PATH"
  result.tempRoot = createTempDir("repro-dss73-cli-", "")
  result.workspaceRoot = result.tempRoot / "ws"
  createDir(result.workspaceRoot / ".repro")
  writeFile(result.workspaceRoot / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n" &
    "\n[workspace]\nproject = \"dss73-integration\"\n")
  result.issuerProject = result.workspaceRoot / IssuerPackage
  result.offlineProject = result.workspaceRoot / OfflinePackage
  for project in [result.issuerProject, result.offlineProject]:
    createDir(project)
    writeExecutable(project / "scripts" / "idp.sh", idpShim(python3))
    writeFile(project / "scripts" / "idp.py", IdpServer)
    writeExecutable(project / "scripts" / "app.sh", AppScript)
  writeExecutable(result.issuerProject / "scripts" / "registrar.sh",
    RegistrarScript)
  writeFile(result.issuerProject / "repro.nim",
    recipe(IssuerPackage, "com.example.dss73.issuer"))
  writeFile(result.offlineProject / "repro.nim",
    recipe(OfflinePackage, "com.example.dss73.offline"))
  result.reproBin = reproBinary()

proc daemonEndpoint(c: Dss73Case): string =
  daemonSocketEndpoint(c.tempRoot.extractFilename)

proc daemonStateDir(c: Dss73Case): string = c.tempRoot / "daemon-state"
proc daemonLeaseRoot(c: Dss73Case): string = c.tempRoot / "lease-state"
proc daemonLogPath(c: Dss73Case): string =
  c.daemonStateDir / "logs" / "repro-daemon.log"

proc daemonArgs(c: Dss73Case): seq[string] =
  @["--endpoint", c.daemonEndpoint,
    "--state-dir", c.daemonStateDir,
    "--state-root", c.daemonLeaseRoot,
    "--log", c.daemonLogPath]

proc envFor(c: Dss73Case; registrarProgram = ""): StringTableRef =
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
  # thing, and the case that proves the offline refusal has to be the
  # shape a developer who never heard of the variable actually has.
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

proc runRepro(c: Dss73Case; cwd: string; args: openArray[string];
              registrarProgram = ""):
    tuple[exitCode: int; output: string] =
  runProgram(c.reproBin, args, cwd, c.envFor(registrarProgram))

proc stopDaemon(c: Dss73Case) =
  discard runProgram(c.reproBin, @["daemon", "stop"] & c.daemonArgs,
    repoRootDir(), c.envFor())
  try: removeFile(c.daemonEndpoint) except OSError, IOError: discard

proc waitForDaemonRunning(c: Dss73Case; timeoutSeconds = 60.0) =
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

proc startDaemon(c: Dss73Case): owned(Process) =
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

proc closeDaemon(c: Dss73Case; daemon: var owned(Process)) =
  c.stopDaemon()
  if not daemon.isNil:
    if daemon.running():
      daemon.terminate()
      discard daemon.waitForExit()
    daemon.close()

proc belongsToThisCase(pid: int; tempRoot: string): bool =
  ## Does this pid still look like something THIS CASE started?
  ##
  ## Asked before every signal, for the reason the §7.2 sibling file's
  ## twin of this proc gives at length: a pid is a HISTORICAL RECORD, not
  ## a handle, and between a process exiting and this teardown running
  ## the number can be reissued. Killing by number alone turns a reap of
  ## a dead fixture into an attack on a live stranger.
  ##
  ## TWO WITNESSES: the daemon and the session's HTTP child carry this
  ## case's directories in their argv, while a declared SERVICE instance
  ## is `sh scripts/idp.sh`, whose only link to the case is its working
  ## directory. Either is conclusive.
  ##
  ## LINUX ONLY, and the `else` is a decision rather than a gap: both
  ## witnesses come from `/proc`.
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

proc reapCaseProcesses(c: Dss73Case) =
  ## Reap whatever this case started and `repro down` did not stop.
  ##
  ## `repro down` is not enough, and that is measured rather than
  ## assumed: `reapSession` signals only the pids a session PUBLISHED,
  ## so a service's grandchild (this case's `python3`, forked from
  ## `sh scripts/idp.sh`) is not among them.
  ##
  ## WHAT THIS IS NOT: a structural guarantee. It reads a process table
  ## at one instant, so a process that forks after the scan is missed.
  ## SIGTERM first, then a RE-CHECK, then SIGKILL -- the re-check is not
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

proc sessionRecord(project: string): JsonNode =
  let path = sessionDirOf(project) / "shared-instance-registrations.json"
  doAssert fileExists(path), "no session record at " & path
  parseJson(readFile(path))

proc attributeRowFor(project, name: string): JsonNode =
  let rows = sessionRecord(project){InstanceAttributesField}
  if rows.isNil:
    return nil
  for row in rows:
    if row{"name"}.getStr("") == name:
      return row
  nil

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

proc flagValue(argv: seq[string]; flag: string): string =
  for i in 0 ..< argv.len - 1:
    if argv[i] == flag:
      return argv[i + 1]
  ""

proc instanceAddressFrom(upOutput: string): string =
  ## The instance's store address, taken from what `repro up` PRINTED.
  ##
  ## Parsed rather than reconstructed on purpose. Rebuilding it here would
  ## mean this test computing a workspace hash and a scope spelling of its
  ## own, and then asserting against its own arithmetic -- the failure mode
  ## where a test and the code agree because they share a bug. The engine
  ## names the address it used; this reads that.
  for line in upOutput.splitLines():
    let marker = " at service:"
    let at = line.find(marker)
    if at < 0:
      continue
    var address = line[at + 4 .. ^1]
    # `Materialise at <address> pid N with M holder` / `...; 0 holders remain`
    for tail in [" pid ", ";", " with "]:
      let cut = address.find(tail)
      if cut >= 0:
        address = address[0 ..< cut]
    return address.strip()
  ""

proc durableRecordOf(c: Dss73Case; instanceAddress: string):
    ServiceRegistrationSet =
  ## THE DURABLE RECORD -- the one a consumer in ANOTHER session reads --
  ## through the real state store, not the session file.
  ##
  ## The root is `$HOME/.cache/repro/state` (`defaultUserStateStoreRoot`),
  ## and this case's `HOME` is its own temp directory, so this is the store
  ## the `repro up` child actually wrote.
  let root = c.tempRoot / "home" / ".cache" / "repro" / "state"
  let address = instanceAddress & ServiceRegistrationsAddressSuffix
  let store = openStateStore(root)
  doAssert store.hasStateRecord(address),
    "no durable registration record at " & address & " under " & root
  let rec = store.readStateRecord(address)
  decodeServiceRegistrations(address, rec.attrsTypeId, rec.attrsJson)

proc durableAttribute(set: ServiceRegistrationSet; name: string): string =
  for attr in set.attributes:
    if attr.name == name:
      return attr.value
  ""

proc descriptorIssuer(project: string): string =
  ## What the RUNNING instance wrote about itself, read from its own
  ## descriptor. Case D needs the new address from a source that is not the
  ## durable record under test.
  parseJson(readFile(project / "state" / "sso-dev.json")){"issuer"}.getStr("")

proc askTheInstance(issuerUrl: string): string =
  ## THE READBACK. Open a real HTTP connection to the URL the consuming
  ## PROCESS was given and ask the instance what it is serving. Nothing
  ## answers at a stale, guessed or expansion-time URL, which is what
  ## makes this the assertion §7.3 needs rather than a second reading of
  ## the descriptor the registrar already read.
  var client = newHttpClient(timeout = 10_000)
  try:
    result = client.getContent(issuerUrl & "/issuer").strip()
  finally:
    client.close()

suite "§7.3 — the instance's issuer URL reaches a consuming service's argv":
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
  var c: Dss73Case
  var daemon: owned(Process)

  setup:
    if not prepared:
      c = prepareCase()
      prepared = true
      daemon = c.startDaemon()

  defer:
    if prepared:
      discard c.runRepro(c.issuerProject,
        @["down", "--activity=" & Activity])
      discard c.runRepro(c.offlineProject,
        @["down", "--activity=" & Activity])
      c.closeDaemon(daemon)
      # REAP AFTER `closeDaemon` -- the daemon's own argv names this case's
      # tempRoot, so the sweep would otherwise kill it out from under the
      # graceful `repro down` calls above -- and BEFORE the tree is removed,
      # because the path is the identity witness.
      c.reapCaseProcesses()
      try: removeDir(c.tempRoot) except OSError, IOError: discard

  test "A: the URL on argv is the one the RUNNING instance is serving":
    let program = c.issuerProject / "scripts" / "registrar.sh"
    let up = c.runRepro(c.issuerProject, @["up", "--activity=" & Activity],
      registrarProgram = program)
    checkpoint("issuer up:\n" & up.output)
    check up.exitCode == 0

    # 1. THE CONSUMING SERVICE REALLY RAN, and this is its own argv.
    let argv = argvOf(c.issuerProject)
    checkpoint("argv: " & $argv)
    check argv.len == 4
    let issuerOnArgv = argv.flagValue("--issuer")
    checkpoint("--issuer: " & issuerOnArgv)

    # 2. IT IS NOT THE TOKEN, which is what this lane did before §7.3 was
    #    implemented: the text matched no prefix and was passed through
    #    verbatim, so the service's `--issuer` was the literal
    #    `@instance-attribute:issuer@`.
    check issuerOnArgv != IssuerToken
    check not issuerOnArgv.contains("@")
    check issuerOnArgv.len > 0

    # 3. IT IS A URL NOBODY COULD HAVE KNOWN AT EXPANSION. The port is the
    #    OS's choice at bind time; no recipe, no environment and no line of
    #    this file names it.
    check issuerOnArgv.startsWith("http://127.0.0.1:")
    let port = issuerOnArgv.rsplit(':', maxsplit = 1)[1]
    check port.len > 0
    for ch in port:
      check ch in {'0' .. '9'}

    # 4. THE READBACK: the instance itself, over a real socket, agrees.
    #    This is the assertion that distinguishes "a string was copied
    #    twice" from "the consumer is pointed at the running instance".
    let served = askTheInstance(issuerOnArgv)
    checkpoint("the instance serves: " & served)
    check served == issuerOnArgv

    # 5. THE MINTED ID IS UNAFFECTED, and §9.3's corrected example is
    #    satisfied in both halves at once.
    check argv.flagValue("--client-id") == IssuerClientId

    # 6. THE ROW IS STAMPED in the session document the supervisor read it
    #    from, and names the registrar that reported it. Without this,
    #    the value above is a URL nobody claimed.
    let row = attributeRowFor(c.issuerProject, IssuerAttributeName)
    check row != nil
    check row{"value"}.getStr("") == issuerOnArgv
    check row{"provenance"}.getStr("") == $rprIssuer
    check row{"registrar"}.getStr("").contains(program)

    # 7. `repro up` SAID OUT LOUD how many attributes it recorded. A read
    #    that silently found nothing is this campaign's own defect class.
    check up.output.contains("1 instance attribute recorded: " &
      IssuerAttributeName)

  test "B: offline, the attribute REFUSES BY NAME and the service never starts":
    # §7.2 keeps the development registrar as the default, and it reports
    # no attributes -- it speaks to no issuer, so it knows no issuer URL.
    # There is deliberately no permissive spelling of
    # `@instance-attribute:` (a guessed URL is not a usable development
    # credential), so a recipe that asks for one offline must be REFUSED
    # BY NAME rather than handed an empty string or the token's own text.
    let up = c.runRepro(c.offlineProject, @["up", "--activity=" & Activity])
    checkpoint("offline up:\n" & up.output)
    check up.exitCode != 0

    # THE REFUSAL NAMES THE ATTRIBUTE, THE SERVICE AND WHAT WOULD SUPPLY
    # IT -- the three things §7.1 asks of an early read and §7.3 of an
    # absent one.
    check up.output.contains("`" & IssuerAttributeName & "`")
    check up.output.contains("NOT AVAILABLE")
    check up.output.contains(ServiceRegistrarProgramEnvVar)
    check up.output.contains("development registrar reports none")

    # AND THE SERVICE NEVER RAN. The refusal is at argv concretization,
    # before the child is spawned, so there is no process holding a URL
    # nobody wrote -- which is the outcome the whole refusal exists for.
    check not fileExists(c.offlineProject / "state" / "app.argv")

    # The instance itself DID come up and DID mint its client id: the
    # offline path is intact and it is only the attribute that refuses.
    # Asserted so that a future change which "fixed" this case by
    # breaking the offline converge would redden here.
    check fileExists(c.offlineProject / "state" / "idp.ready")
    let rows = sessionRecord(c.offlineProject){"registrations"}
    check rows != nil
    check rows.len == 1
    check rows[0]{"provenance"}.getStr("") == $rprDevelopment
    # ...and NO attribute row was written, which is the fact the refusal
    # above is reporting.
    check attributeRowFor(c.offlineProject, IssuerAttributeName) == nil
    check up.output.contains("0 instance attributes recorded")

  test "C: a RESTARTED instance's new URL replaces the old one on argv":
    # THE ANTI-STALENESS PROPERTY, END TO END. The instance is taken down
    # and brought up again; it binds a DIFFERENT ephemeral port, so the
    # issuer URL legitimately moves. A lane that reused the stored
    # attribute the way it reuses a minted client id would point the
    # consumer at a port nothing is listening on -- the `dev-server.sh`
    # descriptor defect, which is what the replace-wholesale rule closes.
    let program = c.issuerProject / "scripts" / "registrar.sh"
    let firstUrl = argvOf(c.issuerProject).flagValue("--issuer")
    check firstUrl.len > 0

    let down = c.runRepro(c.issuerProject,
      @["down", "--activity=" & Activity])
    checkpoint("down:\n" & down.output)
    # `repro down` RELEASES THE HOLDER AND DOES NOT STOP THE INSTANCE --
    # the lease is `delayed(3600)`, which is exactly what a `stable`,
    # state-owning service wants (D-SS5). So the restart is `repro up
    # --replace`, "a takeover ... in the project that DECLARES the
    # service", which is the only spelling that materialises a new
    # process under the same key. Nothing here reaps by pid: this case's
    # tempRoot is in the DAEMON's argv too, and the sweep would take the
    # daemon down with it.
    removeFile(c.issuerProject / "state" / "idp.ready")
    removeFile(c.issuerProject / "state" / "app.argv")
    removeFile(c.issuerProject / "state" / "app.ready")

    let up = c.runRepro(c.issuerProject,
      @["up", "--replace", "--activity=" & Activity],
      registrarProgram = program)
    checkpoint("second up:\n" & up.output)
    check up.exitCode == 0
    let secondUrl = argvOf(c.issuerProject).flagValue("--issuer")
    checkpoint("first: " & firstUrl & "  second: " & secondUrl)
    # A different port, and the consumer followed it.
    check secondUrl != firstUrl
    check askTheInstance(secondUrl) == secondUrl
    # The MINTED ID did not move, which is the other half of the
    # asymmetry: mint-once for the credential, replace for the address.
    check argvOf(c.issuerProject).flagValue("--client-id") == IssuerClientId

  test "D: a REFUSED registration does not leave the OLD url on the record":
    # ───────────────────────────────────────────────────────────────────
    # THE ORDERING, ASSERTED. §7.3's attribute reconcile runs BEFORE the
    # registration reconcile, and until this case that was program order
    # with nothing holding it: swapping the two statements back left
    # every other test in this repository green.
    #
    # It is provoked by COMPOSING the two case Cs. §7.2's case C makes
    # the registration reconcile REFUSE -- the issuer answers a client id
    # under a member this workspace already recorded. §7.3's case C above
    # makes the address MOVE -- the instance rebinds to a new ephemeral
    # port. Neither alone can see the ordering: a converge that only
    # refuses writes no new address, and a converge that only moves does
    # not refuse. One converge that does BOTH separates them, because the
    # two orders then disagree about what is left on the record:
    #
    #   attributes first (the fix) -- the NEW url is written, then the
    #     registrations refuse. The record names the instance that is
    #     actually up.
    #   registrations first -- the refusal raises before the attribute is
    #     written, and the record still names the port the PREVIOUS run
    #     bound. Nothing is listening there. A consumer in another
    #     session reads it and is pointed at a dead address, which is the
    #     `dev-server.sh` descriptor defect reconstructed one lane over.
    #
    # And it is the DURABLE record that is read, not the session file.
    # The session file is rewritten on a refusal anyway; the record is
    # what crosses to another session, so it is the only place where
    # staleness is reachable by someone who did not run this command.
    let program = c.issuerProject / "scripts" / "registrar.sh"

    # 1. WHAT THE PREVIOUS RUN LEFT: the url case C's instance reported,
    #    on the consuming process's argv and on the durable record. The
    #    two agreeing here is what makes step 5 a measurement of the
    #    ordering rather than of the parser.
    let prevUrl = argvOf(c.issuerProject).flagValue("--issuer")
    check prevUrl.startsWith("http://127.0.0.1:")

    let down = c.runRepro(c.issuerProject,
      @["down", "--activity=" & Activity])
    checkpoint("down:\n" & down.output)
    let address = instanceAddressFrom(down.output)
    checkpoint("instance address: " & address)
    check address.startsWith("service:")
    check address.endsWith("com.example.dss73.issuer")
    check durableAttribute(c.durableRecordOf(address),
      IssuerAttributeName) == prevUrl

    # 2. THE ISSUER CHANGES THE REGISTRATION, and the instance rebinds in
    #    the same breath -- one converge, both facts new.
    writeFile(c.issuerProject / "state" / "client-id",
      ChangedIssuerClientId)
    removeFile(c.issuerProject / "state" / "idp.ready")
    removeFile(c.issuerProject / "state" / "app.argv")
    removeFile(c.issuerProject / "state" / "app.ready")

    let up = c.runRepro(c.issuerProject,
      @["up", "--replace", "--activity=" & Activity],
      registrarProgram = program)
    checkpoint("converge that moved AND refused:\n" & up.output)

    # 3. THE REGISTRATION REALLY DID REFUSE. Without this the case would
    #    pass vacuously on any converge that merely succeeded.
    check up.exitCode != 0
    check up.output.contains("is recorded as `" & IssuerClientId & "`")
    check up.output.contains("now answers `" & ChangedIssuerClientId & "`")
    check up.output.contains("Refused rather than guessed")

    # 4. THE ADDRESS REALLY DID MOVE, read from the instance's OWN
    #    descriptor -- a source that is not the record under test.
    let newUrl = descriptorIssuer(c.issuerProject)
    checkpoint("prev: " & prevUrl & "  new: " & newUrl)
    check newUrl.startsWith("http://127.0.0.1:")
    check newUrl != prevUrl

    # 5. THE ASSERTION. The durable record names the instance that is up,
    #    not the one that was. REDDENS if the two reconcile statements
    #    are swapped back.
    let after = c.durableRecordOf(address)
    check durableAttribute(after, IssuerAttributeName) == newUrl
    check durableAttribute(after, IssuerAttributeName) != prevUrl

    # 6. AND THE REFUSAL STILL REFUSED: the recorded registration is
    #    untouched, so the two halves of the record disagree on purpose
    #    -- a current address beside the client id the issuer has
    #    replaced. That is the state a developer must be able to read,
    #    and `repro up` named both facts above.
    check after.registrations.len == 1
    check after.registrations[0].mintedId == IssuerClientId
