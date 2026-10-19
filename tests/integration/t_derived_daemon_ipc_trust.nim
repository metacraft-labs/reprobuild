## DA-2 — an action that talks to a daemon THIS PROCESS SPAWNED is complete;
## every other peer still downgrades.
##
## THE SYMPTOM THIS FILE EXISTS FOR. Dependency-Observation-Attribution.md
## opens on two symptoms, and this is the second: "an action that opens an IPC
## channel to a process outside its own monitored tree is graded
## `mcIncomplete`, so it never publishes a cache entry. It rebuilds every time,
## forever." io-mon already had the mechanism —
## `unmonitoredSubtreeLossDetails(records, trustedPeerPids)` — and reprobuild
## passed an empty set, which is why the symptom was total rather than
## occasional.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The daemon is a real process listening on a real socket; the client is a
## real C program performing a real `connect(2)` and a real `read(2)`; the peer
## pid the exemption turns on is the one the KERNEL reports through
## `SO_PEERCRED`, observed by the real io-mon shim inside the real monitored
## tree; the grading is the real `runBuild` scheduler and the real per-edge
## action cache. The defect class is "what does the engine do with a real
## kernel-attested peer identity", so a harness that supplied its own records
## or its own evidence would assert nothing about it.
##
## THREE CASES BUILD THEIR CAPTURE BY HAND, AND THAT IS NOT A MOCK — nothing is
## substituted for a collaborator; the io-mon fold, the loss classifier and the
## attribution are all the real ones, and what is supplied is the INPUT they
## read. It is supplied because the shapes those cases grade CANNOT BE PRODUCED
## BY A LIVE CAPTURE ON THIS HOST:
##
##   * "the connect record is absent" needs a capture that carries the injected
##     `mrEventLoss` and not the `mrIpcConnect` it was derived from. NO INTEREST
##     SET CAN PRODUCE THAT SHAPE ANY MORE, and that is a fact about io-mon
##     rather than about what this engine happens to ask for: DA-5 made
##     `mrIpcConnect` ungate-able (`categoryOf` answers `none` for it, as it does
##     for `mrExternalContent` and the META kinds), so the shim's gate cannot
##     drop it whatever `--interest` says. `DependencyGatheringPolicy.captureIpc`
##     — the route this file used to name as the way the shape becomes reachable
##     — is RETIRED for exactly that reason (DA-6), and DA-6's one remaining
##     narrowing is `ecAmbientReads`, which touches no kind this suite reads.
##     The shape is therefore unreachable by CONSTRUCTION and is supplied,
##     which is why these cases still have to exist: the code that handles an
##     absent connect record is reachable from a capture that simply made no
##     IPC connection, or one folded from a recognized `.iomon` report, and
##     "unreachable through interest" is not "unreachable".
##   * "two records share a dedup key" needs an `mrIpcConnect` carrying a
##     DUPLICATED `peerstart=` token. That token is io-mon's attacker-shaped
##     evidence: a cooperating shim never emits it, so a real run cannot make
##     one, and the whole point of the case is what happens when a hostile one
##     does.
##   * "a registration whose kernel identity has since changed" needs the SAME
##     capture folded twice, once against a live identity and once against a
##     stale one, with the peer alive across both folds. A fixture daemon
##     cannot be both — so the peer is THIS PROCESS, whose identity is the
##     kernel's real answer, and only the recorded identity is perturbed.
##
## The alternative to constructing them is not a better test, it is no test —
## and the first two are fail-OPEN paths, which is the class that must not be
## graded by reading the code.
##
## WHAT IS GRADED, AND WHY EACH CASE IS HERE
## ---------------------------------------------------------------------
##
## 1. THE POSITIVE, measured end to end rather than at the completeness field.
##    "Publishes" is the property the symptom is about, so the case runs the
##    edge, proves a record was written, runs it again and proves the warm run
##    HITS without launching. A case that only asserted `mcComplete` would pass
##    while the edge still rebuilt forever.
##
## 2. THE NEGATIVE, which matters more, and which is what keeps DA-2 from being
##    a suppression in disguise. The untrusted daemon is THE SAME BINARY,
##    serving THE SAME protocol, alive at the same time — it differs from the
##    trusted one in exactly one respect: this process did not register it.
##    That is the shape of "a daemon of the right name", and it must still
##    downgrade.
##
## 3. CLASS 4 IS UNEXEMPTIBLE. `SO_PEERCRED` yields a pid for AF_UNIX and 0 for
##    INET (io-mon `recordIpcConnect`), so a network peer is unattributable —
##    Dependency-Observation-Attribution.md §Class 4, rule 4. The case trusts
##    the INET daemon's pid EXPLICITLY and asserts the edge downgrades anyway,
##    because the guarantee is held by io-mon's `peer != 0` (io-mon
##    `src/io_mon/writer.nim:1992`) and not by anything reprobuild could choose
##    to honour. MEASURED (2026-09-10): a mutation adding every observed peer
##    pid — 0 included — to the trust set reddens case 2 and leaves this one
##    GREEN, which is the difference between the two stated as a number.
##
## 4. THE TRUST IS DERIVED, NOT DECLARED. Two properties, each with a positive
##    control so a green is not a vacuous green: a bare pid cannot be
##    registered at all (the API takes an `osproc.Process`, a value only a
##    spawner holds — asserted with `compiles`), and a pid whose kernel
##    identity no longer matches the one recorded at registration is dropped
##    before it can exempt anything. The second is the recycled-pid case: on
##    Linux the shim stamps no `peerstart` token on `mrIpcConnect`, so io-mon's
##    own (pid, start-time) test degrades to the bare pid for this record kind
##    and cannot make that distinction for us.
##
##    AND THE IDENTITY'S OWN PARSE, because everything above rests on it and its
##    failure mode is a FALSE ACCEPT rather than a conservative drop. See "the
##    /proc identity is parsed past a comm that contains spaces".
##
## 5. THE TWO FAIL-OPEN SHAPES IN THE RECOMPUTATION. The attribution re-runs
##    io-mon's own rule over the buffered `mrIpcConnect` records, and that
##    recomputation is NOT exact: it can be handed no records at all, and its
##    dedup key can be claimed by a different record than the one io-mon
##    emitted for. Each is graded with a positive control, so a green is not a
##    green produced by an engine that has stopped attributing anything. Both
##    were MEASURED as fail-open before the fix, at `mcComplete` with the
##    exemption counted.
##
## 6. THE PRODUCTION WIRING, which cases 1-5 never touch: they register by
##    hand, so they grade the mechanism and never the one call site that uses
##    it. The production-wiring case drives `startAutoRunQuotaIfNeeded` itself
##    — the spawn arm registers, and the warm arm provably does not, which is
##    the spawn-only constraint stated at that call site.
##
## 7. THE SECOND FOLD SITE. `collectEvidence` reaches the fold from TWO places:
##    the wrapped/hosted monitor arm every case above drives, and the
##    recognized-`.iomon`-report arm — an edge whose OWN COMMAND produces the
##    capture (the `ct test` shape) which the engine then consumes as that
##    edge's evidence. The two share one `MonitorPeerAttribution`, so the risk
##    was wiring rather than divergent logic; it was still a guard half of
##    production did not execute. MEASURED: emptying the trust set on that arm
##    alone reddened NOTHING in this suite until the last case existed.
##
##    Its capture is REAL and hand-built by nothing: the edge runs the io-mon
##    CLI over the same client, so the connect record, the peer pid and the
##    injected loss all come from the same kernel and the same shim as case 1's
##    — only the fold site differs. That case is also where "nothing is
##    suppressed" is checked against a file on disk: the capture the engine
##    graded is still there afterwards, still carrying both the `mrIpcConnect`
##    and the loss text, while the edge publishes.
##
## HAZARD THIS FIXTURE HAS TO RESPECT. `sockaddr_un.sun_path` is 108 bytes.
## A fixture root under a long `TMPDIR` pushes the socket path past it and the
## daemon fails to bind — which looks exactly like a real red. `makeFixture`
## refuses such a root loudly instead of producing one.
##
## PLATFORM CONTRACT — LINUX GRADES THE MECHANISM, EVERY OTHER HOST GRADES ITS
## REFUSAL. `reprobuild-pm/milestones/Dependency-Attribution.milestones.org`,
## DA-2's `:status:`, records the mechanism as "INERT on macOS ALWAYS
## (`processStartIdentity` is `when defined(linux)`, and an unre-validatable
## peer is refused)". That is a specified outcome, not a gap in this suite:
## without a kernel start-time identity a registration could never be
## re-validated at grading time, so `trustDaemonWeSpawned` registers nothing,
## `revalidatedTrustedDaemons` drops every fact, and an IPC loss is never
## forgiven. A case whose Linux outcome needs that identity therefore has TWO
## arms selected by `KernelIdentityHost`:
##
##   * on Linux, the original assertions, unchanged;
##   * everywhere else, the REFUSAL the milestone specifies, asserted as
##     concretely as the Linux outcome is — the edge does not publish and the
##     warm run re-launches, the registration is empty, the identity readers
##     answer "" for a LIVE pid. Never a skip and never a vacuous pass: a host
##     where the mechanism is inert must still prove it fails CLOSED.
##
## Cases that never needed a kernel identity (the unregistered-daemon negative,
## the `compiles` structural case) have one arm and are graded identically on
## every host. WHEN A NON-LINUX IDENTITY BACKEND LANDS (`proc_pidinfo` start
## time on macOS, say) `KernelIdentityHost` is the switch to flip, and every
## non-Linux arm below is then expected to go RED — that is how a re-grade of
## DA-2 for that platform finds every case it has to re-measure.

import std/[os, osproc, sequtils, sets, strutils, tempfiles, unittest]

import io_mon
import repro_build_engine
import repro_cli_support
import repro_core
import repro_hash
import repro_local_store
import repro_test_support

const RepoRootMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

var cachedMonitorTools: MonitorTools
var cachedMonitorToolsReady = false

proc monitorTools(repoRoot: string): MonitorTools =
  if not cachedMonitorToolsReady:
    cachedMonitorTools = prepareMonitorTools(repoRoot,
      repoRoot / "build" / "test-monitor-ipctrust", "ipctrust-monitor")
    putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
    cachedMonitorToolsReady = true
  cachedMonitorTools

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("derived-daemon-ipc-trust." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

const ReuseDecisions = {cdHit, cdHybridCutoff}

const KernelIdentityHost = defined(linux)
  ## Does this host publish the kernel start-time identity DA-2's trust is
  ## re-validated against? Mirrors the `when defined(linux)` arm of
  ## `processStartIdentity` (and of `processImagePath` / `processCommName` /
  ## `processEffectiveUid` beside it) — see the PLATFORM CONTRACT in the header.
  ## A runtime `if` on this constant, not a `when`, selects each case's arm, so
  ## BOTH arms are compiled on every host and a Linux arm cannot rot unseen on
  ## a macOS developer's machine.

proc ccPath(): string =
  result = findExe("cc")
  if result.len == 0:
    result = findExe("gcc")

## The daemon. `argv[1]` selects the transport, so the AF_UNIX and AF_INET arms
## differ ONLY in the address family — the thing `SO_PEERCRED` answers
## differently — and not in the program, the protocol, or the timing.
const DaemonSource = """
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>

int main(int argc, char **argv) {
  if (argc != 4) return 64;
  int listenFd;
  if (strcmp(argv[1], "unix") == 0) {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(argv[2]) >= sizeof addr.sun_path) return 65;
    strcpy(addr.sun_path, argv[2]);
    unlink(argv[2]);
    listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listenFd < 0) return 66;
    if (bind(listenFd, (struct sockaddr *)&addr, sizeof addr) != 0) return 67;
    if (listen(listenFd, 16) != 0) return 68;
    FILE *ready = fopen(argv[3], "w");
    if (!ready) return 69;
    fprintf(ready, "unix\n");
    fclose(ready);
  } else {
    struct sockaddr_in addr;
    socklen_t addrLen = sizeof addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (listenFd < 0) return 66;
    if (bind(listenFd, (struct sockaddr *)&addr, sizeof addr) != 0) return 67;
    if (getsockname(listenFd, (struct sockaddr *)&addr, &addrLen) != 0)
      return 70;
    if (listen(listenFd, 16) != 0) return 68;
    FILE *ready = fopen(argv[3], "w");
    if (!ready) return 69;
    fprintf(ready, "%d\n", (int)ntohs(addr.sin_port));
    fclose(ready);
  }
  for (;;) {
    int c = accept(listenFd, 0, 0);
    if (c < 0) continue;
    if (write(c, "x", 1) != 1) { close(c); continue; }
    close(c);
  }
}
"""

## The client — the whole monitored action. It connects, consumes one byte and
## appends a line to its log so "what ran" and "how many times" are observable
## out of band. It opens no file of its own besides that log.
const ClientSource = """
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>

int main(int argc, char **argv) {
  if (argc != 4) return 64;
  int fd;
  if (strcmp(argv[1], "unix") == 0) {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(argv[2]) >= sizeof addr.sun_path) return 65;
    strcpy(addr.sun_path, argv[2]);
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 66;
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) return 67;
  } else {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)atoi(argv[2]));
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 66;
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) return 67;
  }
  char b = 0;
  if (read(fd, &b, 1) != 1) return 68;
  close(fd);
  FILE *log = fopen(argv[3], "a");
  if (!log) return 69;
  fprintf(log, "talked to %s\n", argv[1]);
  fclose(log);
  return 0;
}
"""

## A process that does nothing but stay alive. Used only to own a `comm` — the
## kernel takes `comm` from the executable's basename, so the NAME this is
## compiled to is the whole point of it.
const SleeperSource = """
#include <unistd.h>

int main(void) {
  for (;;) sleep(60);
  return 0;
}
"""

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string
  binDir: string
  daemonPath: string
  clientPath: string
  logDir: string

type LiveDaemon = object
  process: Process
  address: string
    ## The socket path for the AF_UNIX arm, the decimal port for the INET one.
  stopped: bool

proc isVolatilePrefix(path: string): bool =
  ## Mirrors the engine's `isVolatileMonitorPath`. A fixture under one of these
  ## has every recorded path dropped before any arm sees it, which makes the
  ## whole suite vacuous in the quietest possible way.
  for prefix in ["/run", "/proc", "/sys", "/dev"]:
    if path == prefix or path.startsWith(prefix & "/"):
      return true
  false

proc nonVolatileTempBase(): string =
  result = getTempDir()
  if result.isVolatilePrefix():
    result = "/tmp"

proc compileC(source, output, workRoot, name: string) =
  let cc = ccPath()
  writeFile(workRoot / name, source)
  let res = execProcess(cc, args = ["-o", output, workRoot / name],
    options = {poStdErrToStdOut, poUsePath})
  if not fileExists(output):
    raise newException(OSError, "helper " & name & " was not produced: " & res)

proc makeFixture(): Fixture =
  let root = createTempDir("repro-ipctrust-", "", dir = nonVolatileTempBase())
  if root.isVolatilePrefix():
    raise newException(IOError,
      "fixture root " & root & " is under a volatile prefix the engine drops " &
      "from evidence; this suite cannot assert anything from there")
  let workRoot = root / "work"
  createDir(workRoot)
  let binDir = workRoot / "b"
  createDir(binDir)
  let logDir = workRoot / "o"
  createDir(logDir)
  result = Fixture(
    root: root,
    workRoot: workRoot,
    cacheRoot: root / "cache",
    binDir: binDir,
    daemonPath: binDir / "ipctrust_daemon",
    clientPath: binDir / "ipctrust_client",
    logDir: logDir)
  # `sockaddr_un.sun_path` is 108 bytes and a long `TMPDIR` silently exceeds
  # it. Refuse here, where the reason is legible, rather than in a `bind`
  # failure that reads like a real red.
  let probeSocket = workRoot / "d.sock"
  if probeSocket.len >= 108:
    raise newException(IOError,
      "fixture socket path is " & $probeSocket.len & " bytes, which will not " &
      "fit sockaddr_un.sun_path (108); use a shorter TMPDIR")
  compileC(DaemonSource, result.daemonPath, workRoot, "dmn.c")
  compileC(ClientSource, result.clientPath, workRoot, "cli.c")

proc logPath(f: Fixture; name: string): string = f.logDir / (name & ".log")

proc runCount(f: Fixture; name: string): int =
  let p = f.logPath(name)
  if not fileExists(p):
    return 0
  p.readFile.splitLines.countIt(it.strip().len > 0)

proc startDaemon(f: Fixture; mode, name: string): LiveDaemon =
  ## Start one daemon and wait until it is listening. The ready file is written
  ## AFTER `listen(2)` returns, so a client that sees it cannot race the bind.
  let readyPath = f.workRoot / (name & ".ready")
  removeFile(readyPath)
  let address =
    if mode == "unix": f.workRoot / (name & ".sock")
    else: ""
  result.process = startProcess(f.daemonPath,
    args = [mode, address, readyPath],
    options = {poStdErrToStdOut})
  var waited = 0
  while waited < 10_000:
    if fileExists(readyPath):
      let payload = readFile(readyPath).strip()
      if payload.len > 0:
        result.address = if mode == "unix": address else: payload
        return
    if not result.process.running:
      break
    sleep(20)
    waited += 20
  raise newException(OSError, "daemon " & name & " (" & mode &
    ") never became ready")

proc stopDaemon(daemon: var LiveDaemon) =
  if daemon.stopped or daemon.process == nil:
    return
  daemon.stopped = true
  try:
    daemon.process.terminate()
    discard daemon.process.waitForExit()
  except CatchableError:
    discard
  try:
    daemon.process.close()
  except CatchableError:
    discard

proc monitoredConfig(repoRoot, cacheRoot: string): BuildEngineConfig =
  let tools = monitorTools(repoRoot)
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.fallbackToRunQuotaBypass = true
  result.maxParallelism = 1'u32
  result.monitorCliPath = tools.monitorCliPath
  result.monitorCliArgs = tools.monitorCliArgs

proc clientEdge(f: Fixture; id, mode, address, logName: string): BuildAction =
  ## NOTE what is NOT here: no declared inputs, no tool ref. Under
  ## `dgAutomaticMonitor` this edge's evidence — and therefore its
  ## completeness — comes from the monitor and nowhere else.
  action(id, [f.clientPath, mode, address, f.logPath(logName)],
    cwd = f.workRoot,
    inputs = [],
    outputs = [],
    env = ["PATH=" & getEnv("PATH")],
    cacheable = true,
    weakFingerprint = weak(id),
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = automaticMonitorGatheringPolicy(),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc reportEdge(f: Fixture; repoRoot, id, address, logName,
                capturePath: string): BuildAction =
  ## THE OTHER FOLD SITE. An edge whose OWN COMMAND produces an `.iomon`
  ## capture, declared as a recognized dependency report, so the engine folds
  ## THAT FILE as the edge's evidence instead of monitoring the orchestrator
  ## (`repro_build_engine.collectEvidence`, the `IomonFormatName` branch).
  ##
  ## The command is the real io-mon CLI (`repro internal io monitor`) over the
  ## same client binary the wrapped cases use, so the capture is produced by
  ## the same shim, the same `SO_PEERCRED` answer and the same synthetic-loss
  ## injection — nothing here is constructed.
  ##
  ## `dgRecognizedFormat` is NOT in the engine's `MonitorPolicyKinds`, so this
  ## edge is NOT additionally wrapped in a monitor: the capture the engine
  ## grades is unambiguously the one the command wrote.
  let tools = monitorTools(repoRoot)
  var argv = @[tools.monitorCliPath]
  argv.add(tools.monitorCliArgs)
  argv.add(["--depfile", capturePath, "--",
    f.clientPath, "unix", address, f.logPath(logName)])
  action(id, argv,
    cwd = f.workRoot,
    inputs = [],
    outputs = [],
    env = ["PATH=" & getEnv("PATH"),
           "REPRO_MONITOR_SHIM_LIB=" & tools.shim],
    cacheable = true,
    weakFingerprint = weak(id),
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = DependencyGatheringPolicy(
      kind: dgRecognizedFormat,
      completeness: decComplete,
      recognizedReports: @[
        RecognizedDependencyReportSpec(
          formatName: DependencyFormatName(IomonFormatName),
          outputs: @[ExpectedDependencyFile(
            logicalName: "iomon", path: capturePath, required: true)],
          completeness: decComplete)]),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc publishedRecordExists(f: Fixture; edge: BuildAction): bool =
  var cache = openActionCache(f.cacheRoot / "action-cache")
  cache.readHotRecord(edge.weakFingerprint).found

proc attributionDiagnostics(res: ActionResult): seq[string] =
  res.evidence.diagnostics.filterIt(it.contains("ipc peer attributed"))

proc isLiveTrustedPid(pid: int): bool =
  ## Is `pid` a registration that STILL re-validates against the kernel? Asked
  ## through the same two calls `initMonitorPeerAttribution` makes — the
  ## registry, then the re-validation — rather than through a pid-set accessor
  ## of its own, so nothing exists here that production does not use.
  revalidatedTrustedDaemons(derivedTrustedDaemonRegistry()).anyIt(it.pid == pid)

# ---------------------------------------------------------------------------
# Hand-built captures — see the MOCK POLICY note in the header for why these
# two shapes cannot be produced by a live run, and what is (and is not) being
# substituted.
# ---------------------------------------------------------------------------

const LossWrapper =
  "unmonitored subtree/peer (un-injectable spawn child, SETEXEC into a " &
  "hardened image, or IPC connect to an out-of-tree breakaway daemon): "
    ## The text io-mon's `mergeFragments` wraps each subtree-loss entry in
    ## (io-mon `src/io_mon/writer.nim`). Restated here rather than imported
    ## from the engine ON PURPOSE: the engine's copy is what production parses,
    ## so a test that reused it would go green on a shared typo.

proc ipcLossRecord(clientPid, peerPid: int; peerStart, path: string):
    MonitorRecord =
  ## The synthetic `mrEventLoss` io-mon injects for one (c)-arm loss. The
  ## arguments are the four fields io-mon puts in the text, in its order.
  MonitorRecord(kind: mrEventLoss, observationKind: moEventLoss,
    detail: LossWrapper & "ipc peer outside monitored tree pid=" & $clientPid &
      " peer=" & $peerPid & " peerstart=" & peerStart & " path=" & path)

proc ipcConnectRecord(clientPid, peerPid: int; path: string;
                      detail = ""): MonitorRecord =
  ## One `mrIpcConnect`. io-mon carries the PEER pid in `childOsPid`; `detail`
  ## is where its identity tokens live.
  MonitorRecord(kind: mrIpcConnect, observationKind: moIpcConnect,
    osPid: uint64(clientPid), childOsPid: uint64(peerPid), path: path,
    detail: detail)

proc selfAsTrustedDaemon(name: string): TrustedDaemonPeer =
  ## A trust fact naming a process that is certainly alive and whose kernel
  ## identity certainly re-validates: this one. Using our own pid keeps the
  ## capture cases about the ATTRIBUTION rule instead of about keeping a
  ## fixture daemon alive across the fold.
  let pid = getCurrentProcessId()
  let identity = processStartIdentity(pid)
  TrustedDaemonPeer(pid: pid, identity: identity, name: name,
    contribution: tdcNoContent)

type FoldOutcome = object
  status: MonitorEvidenceStatus
  attributed: int
  diagnostics: seq[string]

proc foldCapture(records: openArray[MonitorRecord];
                 trusted: openArray[TrustedDaemonPeer]): FoldOutcome =
  ## Run the REAL engine fold over `records` with `trusted` registered, and
  ## report the three things DA-2 is graded on.
  var evidence: PathSetEvidence
  var seen: EvidenceSeenSets
  var attribution = initMonitorPeerAttribution(trusted)
  result.status = foldMonitorRecordsEvidence(records, "/nonexistent-cwd",
    evidence, seen, attribution)
  result.attributed = attribution.attributed
  result.diagnostics =
    evidence.diagnostics.filterIt(it.contains("ipc peer attributed"))

# ---------------------------------------------------------------------------
# The non-Linux arms — see the PLATFORM CONTRACT in the header. Each is the
# refusal one family of cases is specified to give, written once so the arms
# that share it cannot drift apart. Templates, so they expand into the case
# body that uses them and every `check` is attributed to that case.
# ---------------------------------------------------------------------------

template checkSpawnRegistersNothing(daemonProcess: Process) =
  ## DA-2's refusal at the registration: no kernel identity for the spawned
  ## pid, so `trustDaemonWeSpawned` records nothing and nothing re-validates.
  ## The pid is asserted LIVE first, so the empty identity is the host's
  ## answer for a running process and not the answer for a dead one.
  check daemonProcess.running
  check processStartIdentity(processID(daemonProcess)) == ""
  trustDaemonWeSpawned(daemonProcess, "ipctrust-daemon", tdcNoContent)
  check derivedTrustedDaemonRegistry().len == 0
  check not isLiveTrustedPid(processID(daemonProcess))

proc namesInertHostPeer(line: string; peerPid: int; peerPath: string): bool =
  ## Does io-mon's IPC-loss line name THIS daemon? On a host without kernel
  ## peer identity (PLATFORM CONTRACT) the socket PATH is the deterministic
  ## identifier: io-mon's macOS hook reads the peer pid through
  ## `LOCAL_PEERPID` best-effort, and records 0 when the kernel would not
  ## answer (`macos_interpose.recordIpcConnect`: "0 => unobtainable"). That
  ## was measured intermittently on aarch64-darwin, when the daemon had
  ## already closed the connection. So the line must carry this endpoint's
  ## `path=`, and its `peer=` must be this daemon's pid or the documented
  ## "unknown" 0, never some other process.
  "ipc peer outside monitored tree" in line and
    (line.endsWith(" path=" & peerPath) or
      (" path=" & peerPath & " ") in line) and
    ((" peer=" & $peerPid & " ") in line or " peer=0 " in line)

template checkIpcLossStands(f: Fixture; edge: BuildAction;
                            config: BuildEngineConfig; logName: string;
                            peerPid: int; peerPath: string) =
  ## THE SYMPTOM, STILL PRESENT — which is what the milestone specifies for a
  ## host DA-2 cannot reach. The edge runs, is NOT forgiven, does NOT publish,
  ## and the warm run LAUNCHES AGAIN. The loss is asserted to be the IPC peer
  ## loss naming this daemon (`namesInertHostPeer`: its socket `peerPath`, and
  ## `peerPid` or io-mon's "unknown" 0), so the downgrade is the one DA-2 would have
  ## forgiven and not some unrelated monitor failure that would make this arm
  ## green for the wrong reason.
  # Bound once: the arguments may be expressions, and a template would
  # otherwise re-evaluate them at every use.
  let theEdge = edge
  let theConfig = config
  let cold = runBuild(graph([theEdge]), theConfig)
  let c0 = cold.byId(theEdge.id)
  checkpoint("inert host, cold: status=" & $c0.status & " reason=" &
    c0.reason & " diagnostics=" & $c0.evidence.diagnostics)
  check c0.status == asSucceeded
  check c0.launched
  check f.runCount(logName) == 1
  check attributionDiagnostics(c0).len == 0
  check c0.evidence.diagnostics.anyIt(
    namesInertHostPeer(it, peerPid, peerPath))
  check not f.publishedRecordExists(theEdge)
  let warm = runBuild(graph([theEdge]), theConfig)
  let c1 = warm.byId(theEdge.id)
  checkpoint("inert host, warm: decision=" & $c1.cacheDecision &
    " launched=" & $c1.launched)
  check c1.cacheDecision notin ReuseDecisions
  check c1.launched
  check f.runCount(logName) == 2

template checkFoldForgivesNothing(records: openArray[MonitorRecord];
                                  peerPid: int) =
  ## The hand-built capture cases' refusal. The trust fact naming this
  ## process carries the identity the host reports — "" — and is dropped; so
  ## is one carrying a FORGED non-empty identity, which is what proves the
  ## refusal comes from the kernel-side re-read and not merely from the
  ## empty-field guard in `revalidatedTrustedDaemons`.
  let honest = selfAsTrustedDaemon("capture-daemon")
  check honest.pid == peerPid
  check honest.identity == ""
  var forged = honest
  forged.identity = "1"
  for trusted in [honest, forged]:
    let outcome = foldCapture(records, [trusted])
    checkpoint("inert host fold (identity='" & trusted.identity &
      "'): status=" & $outcome.status & " attributed=" & $outcome.attributed &
      " diagnostics=" & $outcome.diagnostics)
    check outcome.status == mesUnknownScopeLoss
    check outcome.attributed == 0
    check outcome.diagnostics.len == 0

suite "derived IPC trust: the daemons this process spawned":

  test "an action that talks only to a trusted daemon publishes, and a warm run hits":
    ## THE SYMPTOM, GONE — and measured as "publishes and is reused", not as a
    ## completeness enum, because the enum is not what rebuilt forever.
    ##
    ## NON-LINUX: the symptom is SPECIFIED TO REMAIN (DA-2 "INERT on macOS
    ## ALWAYS"), so that arm asserts it does — the spawn registers nothing,
    ## the edge does not publish, and the warm run launches again.
    if ccPath().len == 0:
      skip()
    elif not KernelIdentityHost:
      forgetDerivedTrustedDaemons()
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDaemon("unix", "trusted")
      defer: stopDaemon(daemon)
      checkSpawnRegistersNothing(daemon.process)
      let edge = f.clientEdge("ipctrust/trusted", "unix", daemon.address,
        "trusted")
      checkIpcLossStands(f, edge, monitoredConfig(repoRoot, f.cacheRoot),
        "trusted", processID(daemon.process), daemon.address)
    else:
      forgetDerivedTrustedDaemons()
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDaemon("unix", "trusted")
      defer: stopDaemon(daemon)
      # DERIVED: the pid comes from the spawn, through a `Process` value only a
      # spawner can hold. The class-3 branch is (a) — this daemon hands back one
      # byte it invented and reads no file on the client's behalf, which is the
      # `runquotad` shape ("contributes no content").
      trustDaemonWeSpawned(daemon.process, "ipctrust-daemon", tdcNoContent)
      check isLiveTrustedPid(processID(daemon.process))

      let edge = f.clientEdge("ipctrust/trusted", "unix", daemon.address,
        "trusted")
      let g = graph([edge])
      let config = monitoredConfig(repoRoot, f.cacheRoot)

      let first = runBuild(g, config)
      let r0 = first.byId(edge.id)
      checkpoint("first: status=" & $r0.status & " reason=" & r0.reason &
        " stderr=" & r0.stderr &
        " diagnostics=" & $r0.evidence.diagnostics)
      check r0.status == asSucceeded
      check r0.launched
      check f.runCount("trusted") == 1
      # The exemption is COUNTED and NAMED, per rule 3: an attribution that
      # left no trace would be indistinguishable from never having observed the
      # peer at all, and one that left only a count would tell an operator that
      # something was forgiven without saying what, or on whose authority.
      # Asserted on the real diagnostic and not on its length, because the
      # length is satisfied by any string at all.
      let attributed = attributionDiagnostics(r0)
      check attributed.len >= 1
      if attributed.len >= 1:
        checkpoint("diagnostic=" & attributed[0])
        check "ipc peer attributed to daemon 'ipctrust-daemon'" in attributed[0]
        check ("(pid " & $processID(daemon.process) & ")") in attributed[0]
        check "spawned by this process" in attributed[0]
        check ("Dependency-Observation-Attribution.md §Class 3 branch (a), " &
          "contributes no content to the action (DA-2); forgave: ") in
          attributed[0]
        # The forgiven loss is quoted VERBATIM, so the line an operator reads
        # carries the evidence as well as the verdict.
        check "forgave: ipc peer outside monitored tree pid=" in attributed[0]
        check ("peer=" & $processID(daemon.process)) in attributed[0]
      check f.publishedRecordExists(edge)

      let warm = runBuild(g, config)
      let r1 = warm.byId(edge.id)
      checkpoint("warm: decision=" & $r1.cacheDecision &
        " launched=" & $r1.launched)
      check r1.cacheDecision in ReuseDecisions
      check not r1.launched
      check f.runCount("trusted") == 1

  test "a live daemon this process did not register still downgrades":
    ## THE GUARANTEE, INTACT. Same binary, same protocol, same transport, alive
    ## at the same moment — and NOT registered. If this case ever goes green
    ## alongside case 1 under a change that only widens trust, DA-2 has become
    ## a false-complete generator.
    if ccPath().len == 0:
      skip()
    else:
      forgetDerivedTrustedDaemons()
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      var untrusted = f.startDaemon("unix", "untrusted")
      defer: stopDaemon(untrusted)
      # A SECOND daemon IS registered, so the trust set is non-empty and every
      # DA-2 code path is live. What must not happen is that trusting one
      # daemon exempts a different one.
      var trusted = f.startDaemon("unix", "other")
      defer: stopDaemon(trusted)
      trustDaemonWeSpawned(trusted.process, "ipctrust-daemon", tdcNoContent)
      check not isLiveTrustedPid(processID(untrusted.process))

      let edge = f.clientEdge("ipctrust/untrusted", "unix", untrusted.address,
        "untrusted")
      let g = graph([edge])
      let config = monitoredConfig(repoRoot, f.cacheRoot)

      let first = runBuild(g, config)
      let r0 = first.byId(edge.id)
      checkpoint("first: status=" & $r0.status & " reason=" & r0.reason &
        " diagnostics=" & $r0.evidence.diagnostics)
      check r0.status == asSucceeded
      check r0.launched
      check f.runCount("untrusted") == 1
      check attributionDiagnostics(r0).len == 0
      check not f.publishedRecordExists(edge)

      let warm = runBuild(g, config)
      let r1 = warm.byId(edge.id)
      checkpoint("warm: decision=" & $r1.cacheDecision &
        " launched=" & $r1.launched)
      check r1.cacheDecision notin ReuseDecisions
      check r1.launched
      check f.runCount("untrusted") == 2

  test "an INET peer is never trusted, even when its own pid is registered":
    ## CLASS 4, UNEXEMPTIBLE (rule 4). `SO_PEERCRED` yields no pid for an INET
    ## socket, so io-mon records `peer=0` and its exemption — which requires
    ## `peer != 0` — cannot fire whatever this process registers. The case
    ## registers the daemon ANYWAY, so what it measures is that the guarantee
    ## survives the most favourable configuration for breaking it.
    if ccPath().len == 0:
      skip()
    else:
      forgetDerivedTrustedDaemons()
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDaemon("inet", "inet")
      defer: stopDaemon(daemon)
      if KernelIdentityHost:
        trustDaemonWeSpawned(daemon.process, "ipctrust-daemon", tdcNoContent)
        check isLiveTrustedPid(processID(daemon.process))
      else:
        # The most favourable configuration is not reachable here: the
        # registration itself is refused (PLATFORM CONTRACT). What remains
        # graded below — the INET edge downgrades — is the same property.
        checkSpawnRegistersNothing(daemon.process)

      let edge = f.clientEdge("ipctrust/inet", "inet", daemon.address, "inet")
      let g = graph([edge])
      let config = monitoredConfig(repoRoot, f.cacheRoot)

      let first = runBuild(g, config)
      let r0 = first.byId(edge.id)
      checkpoint("first: status=" & $r0.status & " reason=" & r0.reason &
        " diagnostics=" & $r0.evidence.diagnostics)
      check r0.status == asSucceeded
      check r0.launched
      check f.runCount("inet") == 1
      check attributionDiagnostics(r0).len == 0
      check not f.publishedRecordExists(edge)

      let warm = runBuild(g, config)
      let r1 = warm.byId(edge.id)
      checkpoint("warm: decision=" & $r1.cacheDecision &
        " launched=" & $r1.launched)
      check r1.cacheDecision notin ReuseDecisions
      check r1.launched
      check f.runCount("inet") == 2

  test "a bare pid cannot be registered — the API takes proof of the spawn":
    ## The structural half of "derived, not declared", asserted against the
    ## compiler rather than against a comment: `trustDaemonWeSpawned` accepts an
    ## `osproc.Process`, a value a caller can only hold by having started the
    ## process it names. The positive control is what stops this being a green
    ## produced by a typo in the negative.
    check not compiles(trustDaemonWeSpawned(1234, "x", tdcNoContent))
    check compiles(trustDaemonWeSpawned(default(Process), "x", tdcNoContent))

  test "a recycled pid does not inherit trust":
    ## On Linux the shim stamps no `peerstart` token on `mrIpcConnect`, so
    ## io-mon's (pid, start-time) identity test degrades to the bare pid for
    ## this record kind. The engine therefore carries the identity itself —
    ## `/proc/<pid>/stat` field 22, read at registration — and re-reads it at
    ## grading time. Three arms on the helper: the identity that matches (the
    ## positive control, so the two refusals below are not vacuous), an identity
    ## that does not (a recycled pid, i.e. the number reused by a different
    ## process), and the registered daemon after it has exited and been reaped.
    ##
    ## AND TWO ARMS ON THE PRODUCTION PATH, because "re-reads it at grading
    ## time" is a claim about `initMonitorPeerAttribution` — the call the fold
    ## actually makes — and not about `revalidatedTrustedDaemons`, which is only
    ## the helper it delegates to. MEASURED (2026-09-10): deleting the
    ## `revalidatedTrustedDaemons` call from `initMonitorPeerAttribution`, so a
    ## stale identity reaches the trust set intact, reddened NOTHING in this
    ## suite until the last two arms existed. Grading the helper is not grading
    ## the wire.
    ##
    ## NON-LINUX: there is no identity to recycle, and the specified answer is
    ## that NOTHING is trusted rather than that a bare pid is. The arm asserts
    ## a live daemon reads as "", that a fact carrying ANY identity for it —
    ## the empty one or a forged one — is dropped by the helper, that the same
    ## holds on the production fold path, and that registration is refused.
    if ccPath().len == 0:
      skip()
    elif not KernelIdentityHost:
      forgetDerivedTrustedDaemons()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDaemon("unix", "recycle")
      defer: stopDaemon(daemon)
      let pid = processID(daemon.process)
      check daemon.process.running
      check processStartIdentity(pid) == ""
      for identity in ["", "1"]:
        check revalidatedTrustedDaemons(
          [TrustedDaemonPeer(pid: pid, identity: identity, name: "d",
            contribution: tdcNoContent)]).len == 0
      let selfPid = getCurrentProcessId()
      checkFoldForgivesNothing([
        ipcConnectRecord(4242, selfPid, "/ipctrust/recycled.sock"),
        ipcLossRecord(4242, selfPid, "", "/ipctrust/recycled.sock")], selfPid)
      checkSpawnRegistersNothing(daemon.process)
    else:
      forgetDerivedTrustedDaemons()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDaemon("unix", "recycle")
      defer: stopDaemon(daemon)
      let pid = processID(daemon.process)
      let identity = processStartIdentity(pid)
      checkpoint("pid=" & $pid & " identity=" & identity)
      check identity.len > 0

      check revalidatedTrustedDaemons(
        [TrustedDaemonPeer(pid: pid, identity: identity, name: "d",
          contribution: tdcNoContent)]).len == 1
      check revalidatedTrustedDaemons(
        [TrustedDaemonPeer(pid: pid, identity: identity & "9", name: "d",
          contribution: tdcNoContent)]).len == 0

      # THE PRODUCTION PATH. `foldCapture` runs the REAL fold, which builds its
      # trust through `initMonitorPeerAttribution`; the peer is this process, so
      # the live arm is a genuine kernel agreement rather than a fixture.
      let livePeer = selfAsTrustedDaemon("capture-daemon")
      check livePeer.identity.len > 0
      let capture = @[
        ipcConnectRecord(4242, livePeer.pid, "/ipctrust/recycled.sock"),
        ipcLossRecord(4242, livePeer.pid, "", "/ipctrust/recycled.sock")]

      # Positive control FIRST, so the refusal below cannot be a green produced
      # by a fold that has stopped attributing anything at all.
      let honoured = foldCapture(capture, [livePeer])
      checkpoint("live identity: status=" & $honoured.status &
        " attributed=" & $honoured.attributed)
      check honoured.status == mesComplete
      check honoured.attributed == 1

      # The same capture, the same pid, one changed byte of kernel identity —
      # which is exactly what a recycled pid looks like to the fold.
      var stalePeer = livePeer
      stalePeer.identity = livePeer.identity & "9"
      let refused = foldCapture(capture, [stalePeer])
      checkpoint("stale identity: status=" & $refused.status &
        " attributed=" & $refused.attributed)
      check refused.status == mesUnknownScopeLoss
      check refused.attributed == 0
      check refused.diagnostics.len == 0

      trustDaemonWeSpawned(daemon.process, "ipctrust-daemon", tdcNoContent)
      check isLiveTrustedPid(pid)
      stopDaemon(daemon)
      check not isLiveTrustedPid(pid)

  test "the /proc identity is parsed past a comm that contains spaces":
    ## THE IDENTITY'S OWN PARSE, and it is graded because its failure mode is a
    ## FALSE ACCEPT rather than the conservative drop every other refusal in
    ## this file produces.
    ##
    ## `/proc/<pid>/stat` field 2 is `comm`, in parentheses, taken from the
    ## executable's basename — so it can contain spaces, and a left-to-right
    ## `splitWhitespace()[21]` then reads field 21 (`itrealvalue`) instead of
    ## field 22 (`starttime`). `itrealvalue` is hard-zero on every modern
    ## kernel, so EVERY such process reports the same identity "0",
    ## `revalidatedTrustedDaemons` finds the kernel still agreeing about a pid
    ## the kernel has since handed to someone else, and a recycled pid inherits
    ## trust. That is the one thing `TrustedDaemonPeer.identity` exists to stop
    ## (Dependency-Observation-Attribution.md §"Derived beats declared" — a
    ## derived fact that cannot lie stops being derived the moment its parse
    ## does). `processStartIdentity` anchors on `rfind(')')` for exactly this
    ## reason; without a case, nothing says so.
    ##
    ## MEASURED (2026-09-10): replacing that anchor with
    ## `splitWhitespace()[21]` left all NINE other cases in this file green,
    ## and a real space-named pair then reported `0` and `0` where the anchored
    ## parse reports `3189084` and `3189205`.
    ##
    ## ASSERTED AS A DIFFERENCE BETWEEN TWO LIVE PROCESSES, because "these two
    ## identities are distinct" is precisely what the rejection needs and
    ## precisely what the miscount collapses. The normally-named pair is the
    ## control: the miscount leaves it correct, so a red on the spaced arm
    ## alone names the comm parse and not the helper.
    ##
    ## NON-LINUX: there is no `/proc/<pid>/stat` to parse, and the contract is
    ## FAIL-CLOSED — the readers answer "" rather than a guess, for a process
    ## that is demonstrably alive, under either name. A non-Linux reader that
    ## returned some constant for every pid would be exactly the false accept
    ## this case exists for, so the arm asserts emptiness, not mere agreement.
    if ccPath().len == 0:
      skip()
    elif not KernelIdentityHost:
      let f = makeFixture()
      defer: removeDir(f.root)
      let spacedBin = f.binDir / "ipc daemon"
      let plainBin = f.binDir / "ipcdaemon"
      compileC(SleeperSource, spacedBin, f.workRoot, "slp.c")
      copyFile(spacedBin, plainBin)
      setFilePermissions(plainBin, getFilePermissions(spacedBin))
      for binary in [plainBin, spacedBin]:
        let p = startProcess(binary, options = {poStdErrToStdOut})
        try:
          checkpoint("inert host, live sleeper " & binary.extractFilename &
            " pid=" & $processID(p))
          check p.running
          check processStartIdentity(processID(p)) == ""
          check processCommName(processID(p)) == ""
        finally:
          try:
            p.terminate()
            discard p.waitForExit()
            p.close()
          except CatchableError:
            discard
    else:
      let f = makeFixture()
      defer: removeDir(f.root)
      # The SAME program under two names, so the only difference between the
      # arms is the space the kernel copies into `comm`.
      let spacedBin = f.binDir / "ipc daemon"
      let plainBin = f.binDir / "ipcdaemon"
      compileC(SleeperSource, spacedBin, f.workRoot, "slp.c")
      copyFile(spacedBin, plainBin)
      setFilePermissions(plainBin, getFilePermissions(spacedBin))

      var live: seq[Process] = @[]
      defer:
        for p in live:
          try:
            p.terminate()
            discard p.waitForExit()
            p.close()
          except CatchableError:
            discard

      var identities: seq[seq[string]] = @[]
      for binary in [plainBin, spacedBin]:
        var pair: seq[string] = @[]
        for _ in 0 .. 1:
          let p = startProcess(binary, options = {poStdErrToStdOut})
          live.add(p)
          pair.add(processStartIdentity(processID(p)))
          # At least 25 clock ticks at the usual USER_HZ of 100, so the two
          # start times differ by construction rather than by luck.
          sleep(250)
        identities.add(pair)

      checkpoint("plain comm identities: " & $identities[0])
      checkpoint("spaced comm identities: " & $identities[1])
      check identities[0][0].len > 0
      check identities[0][1].len > 0
      check identities[0][0] != identities[0][1]
      check identities[1][0].len > 0
      check identities[1][1].len > 0
      check identities[1][0] != identities[1][1]

  test "a loss whose connect record the capture does not carry is not forgiven":
    ## FAIL-OPEN #1. The attribution decides a deferred loss by re-running
    ## io-mon's own function over the buffered `mrIpcConnect` records. Over an
    ## EMPTY record set that function returns an empty seq, so a rule phrased as
    ## "the text is no longer returned" forgives every loss in a capture that
    ## carries none — a blanket exemption produced by an ABSENCE of evidence.
    ##
    ## The rule is therefore phrased as a DIFFERENCE: a loss is forgiven only
    ## when its dedup key is accounted for by the buffered records AND the trust
    ## set is what removed it. An absent record is in neither answer.
    ##
    ## The positive control is the same loss with its record present. Without
    ## it this case would pass against an engine that had simply stopped
    ## attributing anything.
    if not KernelIdentityHost:
      # NON-LINUX (PLATFORM CONTRACT): with or without its connect record the
      # loss stands, because no trust fact re-validates. The with-record
      # capture is the Linux arm's positive control; here it is the refusal.
      let selfPid = getCurrentProcessId()
      let loss = ipcLossRecord(4242, selfPid, "", "/ipctrust/absent.sock")
      checkFoldForgivesNothing([loss], selfPid)
      checkFoldForgivesNothing(
        [ipcConnectRecord(4242, selfPid, "/ipctrust/absent.sock"), loss],
        selfPid)
    else:
      let peer = selfAsTrustedDaemon("capture-daemon")
      check peer.identity.len > 0
      let loss = ipcLossRecord(4242, peer.pid, "", "/ipctrust/absent.sock")

      let withoutRecord = foldCapture([loss], [peer])
      checkpoint("without connect record: status=" & $withoutRecord.status &
        " attributed=" & $withoutRecord.attributed)
      check withoutRecord.status == mesUnknownScopeLoss
      check withoutRecord.attributed == 0
      check withoutRecord.diagnostics.len == 0

      let withRecord = foldCapture(
        [ipcConnectRecord(4242, peer.pid, "/ipctrust/absent.sock"), loss], [peer])
      checkpoint("with connect record: status=" & $withRecord.status &
        " attributed=" & $withRecord.attributed &
        " diagnostics=" & $withRecord.diagnostics)
      check withRecord.status == mesComplete
      check withRecord.attributed == 1
      check withRecord.diagnostics.len == 1
      # Rule 3 — NAMED, not merely counted. The daemon and the §Class 3 branch
      # that let it be forgiven must both be in the line an operator reads,
      # because io-mon's own text identifies the peer by a bare pid and nothing
      # else (on Linux `recordIpcConnect` never sets `record.path`).
      check "capture-daemon" in withRecord.diagnostics[0]
      check "branch (a)" in withRecord.diagnostics[0]
      check ("pid " & $peer.pid) in withRecord.diagnostics[0]

  test "a colliding dedup key is not forgiven by another record's exemption":
    ## FAIL-OPEN #2, and the one the trust set cannot be blamed for.
    ## `unmonitoredSubtreeLossDetails` dedups on
    ## `pid:<peer>@<peerstart>|dest:<endpoint>` (the endpoint joined io-mon's key
    ## with endpoint-keyed daemon trust, so connects to DIFFERENT sockets no
    ## longer share a key) and emits the text of the FIRST NON-EXEMPT record per
    ## key. Which record that
    ## is differs between io-mon's run and the engine's recomputation, so the
    ## TEXT is not comparable across the two and only the KEY is.
    ##
    ## The capture: two connects to the SAME trusted peer AT THE SAME
    ## ENDPOINT, sharing one dedup key. The second carries a DUPLICATED `peerstart=` token — io-mon's
    ## attacker-controlled-evidence signal, which its rule fails CLOSED on and
    ## never exempts, trusted peer or not. io-mon (trusting nothing, as the
    ## merge does) flagged the FIRST record and dedup-suppressed the second, so
    ## the loss text names the first. The recomputation WITH the trust set
    ## exempts the first and flags the second, producing a DIFFERENT text for
    ## the same key — and a text-absence test reads that as "forgiven", which
    ## hands a clean grade to the one record io-mon refused to trust.
    ##
    ## Comparing keys closes it: the key is in both answers, so the trust set
    ## is not what removed it, so the loss stands.
    if not KernelIdentityHost:
      # NON-LINUX (PLATFORM CONTRACT): neither the collided capture nor its
      # uncollided control is forgiven, because no trust fact re-validates.
      let selfPid = getCurrentProcessId()
      let plain = ipcConnectRecord(101, selfPid, "/ipctrust/first.sock")
      let duplicated = ipcConnectRecord(202, selfPid, "/ipctrust/first.sock",
        detail = "peerstart=42 peerstart=42")
      let loss = ipcLossRecord(101, selfPid, "", "/ipctrust/first.sock")
      checkFoldForgivesNothing([plain, duplicated, loss], selfPid)
      checkFoldForgivesNothing([plain, loss], selfPid)
    else:
      let peer = selfAsTrustedDaemon("capture-daemon")
      check peer.identity.len > 0
      let plain = ipcConnectRecord(101, peer.pid, "/ipctrust/first.sock")
      let duplicated = ipcConnectRecord(202, peer.pid, "/ipctrust/first.sock",
        detail = "peerstart=42 peerstart=42")
      # What io-mon emitted: the FIRST record's text, under the shared key.
      let loss = ipcLossRecord(101, peer.pid, "", "/ipctrust/first.sock")

      let collided = foldCapture([plain, duplicated, loss], [peer])
      checkpoint("collided: status=" & $collided.status &
        " attributed=" & $collided.attributed &
        " diagnostics=" & $collided.diagnostics)
      check collided.status == mesUnknownScopeLoss
      check collided.attributed == 0
      check collided.diagnostics.len == 0

      # POSITIVE CONTROL — the identical capture with the duplicate-token record
      # removed IS forgiven. The two differ in exactly the record that collides,
      # so the red above is caused by the collision and by nothing else.
      let uncollided = foldCapture([plain, loss], [peer])
      checkpoint("uncollided: status=" & $uncollided.status &
        " attributed=" & $uncollided.attributed)
      check uncollided.status == mesComplete
      check uncollided.attributed == 1

  test "the real CLI spawn arm registers the daemon it started":
    ## THE PRODUCTION WIRING, which the cases above deliberately do not touch:
    ## they all register by hand, so they grade the MECHANISM and never the one
    ## call site that uses it. This drives `startAutoRunQuotaIfNeeded` — the
    ## real function, on its real spawn branch — and asserts the registration
    ## is there afterwards.
    ##
    ## `RUNQUOTA_SOCKET` is pointed at a path that does not exist so the branch
    ## is DETERMINISTIC rather than a property of how the host happens to be
    ## provisioned: both early returns test reachability, an absent socket is
    ## unreachable, and the spawn arm is taken. The function then overwrites
    ## `RUNQUOTA_SOCKET` with the per-PID socket it actually bound.
    ##
    ## NON-LINUX: the spawn arm is taken exactly as on Linux — the daemon is
    ## started and live — and its registration is REFUSED, because the pid has
    ## no kernel identity to re-validate (PLATFORM CONTRACT). The warm arm
    ## still adopts and still registers nothing, so the registry is empty
    ## after both calls rather than holding one entry.
    if findRunQuotaDaemonBin().len == 0:
      skip()
    elif not KernelIdentityHost:
      forgetDerivedTrustedDaemons()
      let scratch = createTempDir("repro-ipcwire-", "", dir = nonVolatileTempBase())
      defer: removeDir(scratch)
      let priorSocket = getEnv("RUNQUOTA_SOCKET", "")
      putEnv("RUNQUOTA_SOCKET", scratch / "no-such-runquota.sock")
      putEnv("REPROBUILD_AUTO_RUNQUOTA", "1")
      var daemon = startAutoRunQuotaIfNeeded(false)
      defer:
        releaseAutoRunQuotaProcess(daemon)
        putEnv("RUNQUOTA_SOCKET", priorSocket)
        forgetDerivedTrustedDaemons()
      check daemon != nil
      if daemon != nil:
        checkpoint("inert host, spawned runquotad pid=" & $processID(daemon))
        check daemon.running
        check processStartIdentity(processID(daemon)) == ""
        check not isLiveTrustedPid(processID(daemon))
      check derivedTrustedDaemonRegistry().len == 0
      # The warm arm (1), with its preconditions checked as on Linux, so the
      # empty registry below is the adopt early-return and not a second spawn.
      let publishedSocket = getEnv("RUNQUOTA_SOCKET", "")
      check publishedSocket.len > 0
      check publishedSocket != scratch / "no-such-runquota.sock"
      var adopted = startAutoRunQuotaIfNeeded(false)
      defer: releaseAutoRunQuotaProcess(adopted)
      check adopted == nil
      check derivedTrustedDaemonRegistry().len == 0
    else:
      forgetDerivedTrustedDaemons()
      let scratch = createTempDir("repro-ipcwire-", "", dir = nonVolatileTempBase())
      defer: removeDir(scratch)
      let priorSocket = getEnv("RUNQUOTA_SOCKET", "")
      putEnv("RUNQUOTA_SOCKET", scratch / "no-such-runquota.sock")
      putEnv("REPROBUILD_AUTO_RUNQUOTA", "1")
      var daemon = startAutoRunQuotaIfNeeded(false)
      defer:
        releaseAutoRunQuotaProcess(daemon)
        putEnv("RUNQUOTA_SOCKET", priorSocket)
        forgetDerivedTrustedDaemons()
      check daemon != nil

      let registry = derivedTrustedDaemonRegistry()
      checkpoint("registry=" & $registry.len & " daemonPid=" &
        $processID(daemon))
      check registry.len == 1
      if registry.len == 1:
        check registry[0].name == "runquotad"
        check registry[0].pid == processID(daemon)
        # Branch (a): `runquotad` grants leases and takes telemetry rows; it
        # serves no file content, so it is "contributes no content" and not
        # "serves class-1 content".
        check registry[0].contribution == tdcNoContent
      # And the registration is USABLE — re-validated against the kernel, which
      # is the form the fold consumes.
      check isLiveTrustedPid(processID(daemon))

      # A WARM ARM, asserted rather than assumed. A second call now finds the
      # daemon reachable on the socket the first one published, takes an early
      # return, and registers NOTHING — this milestone trusts only what it
      # spawned, and adopting a running daemon is declared attribution (DA-4).
      #
      # WHICH EARLY RETURN, STATED EXACTLY AND THEN ASSERTED, because there
      # are two and this drives ONE of them. `startAutoRunQuotaIfNeeded`
      # returns nil when (1) `RUNQUOTA_SOCKET` is set AND reachable, or (2) the
      # daemon is reachable on `runquota_ipc.defaultEndpoint`. The first call
      # left `RUNQUOTA_SOCKET` pointing at the per-PID socket it bound, so what
      # runs below is (1) — and the preconditions of (1) are checked here
      # rather than narrated, because the sentence naming the arm was the only
      # thing saying which arm this case reaches.
      let publishedSocket = getEnv("RUNQUOTA_SOCKET", "")
      checkpoint("RUNQUOTA_SOCKET after the spawn=" & publishedSocket)
      check publishedSocket.len > 0
      check publishedSocket != scratch / "no-such-runquota.sock"
      # Arm (1) needs the variable set AND the path answering, so the path has
      # to exist. NOT `fileExists`, which is `S_ISREG` and answers false for
      # every socket there is; `getFileInfo` stats whatever is there and
      # raises only when nothing is.
      var publishedSocketExists = false
      try:
        discard getFileInfo(publishedSocket)
        publishedSocketExists = true
      except OSError:
        publishedSocketExists = false
      check publishedSocketExists
      #
      # The two topologies the registration site calls out — a provisioned
      # POSIX host (`/run/runquota/runquotad.sock`) and Windows from build #2
      # (the per-user pipe, `RUNQUOTA_SOCKET` deliberately cleared) — take
      # (2) instead, and this case does NOT drive (2): reaching it needs a
      # daemon listening on the host-wide endpoint, i.e. a provisioned host,
      # which a test may not manufacture. What is graded here is the PROPERTY
      # both share — an adopted daemon is not registered — on the one early
      # return a test can reach deterministically. Do not read this case as
      # evidence about branch (2); read it as evidence that adoption and
      # registration are separate, which is what makes the reach claim at the
      # registration site checkable at all.
      var adopted = startAutoRunQuotaIfNeeded(false)
      defer: releaseAutoRunQuotaProcess(adopted)
      check adopted == nil
      check derivedTrustedDaemonRegistry().len == 1

  test "the recognized .iomon report arm is graded against the same trust":
    ## THE SECOND FOLD SITE, and the one every case above misses.
    ## `collectEvidence` folds monitor evidence from TWO places — the
    ## wrapped/hosted arm, and this one: an edge whose own command PRODUCES an
    ## `.iomon` capture that the engine consumes as that edge's evidence. Both
    ## share a single `MonitorPeerAttribution`, so the risk here is wiring and
    ## not divergent logic — which is exactly the class of defect a test is for,
    ## because wiring is what an edit drops. MEASURED: handing the report arm a
    ## fresh empty attribution reddened NOTHING in this file until this case
    ## existed.
    ##
    ## Both directions in one case, on the same fold site: the trusted daemon
    ## publishes, the unregistered one does not. Without the negative, "the arm
    ## is wired" would be indistinguishable from "the arm forgives everything".
    ##
    ## AND NOTHING IS SUPPRESSED. The capture is a file this case can read back
    ## AFTER the engine graded it, so the claim that DA-2 attributes rather than
    ## suppresses (Dependency-Observation-Attribution.md §"Attribution, not
    ## suppression") is checked against the bytes on disk: the `mrIpcConnect`
    ## and the injected loss text are both still there while the edge publishes.
    ##
    ## NON-LINUX: the same fold site, refusing. The capture on disk still
    ## carries the `mrIpcConnect` to the daemon's socket (with its pid, which
    ## io-mon reads best-effort through `LOCAL_PEERPID`, or 0 where the kernel
    ## would not answer) and the loss text — so the evidence DA-2 would
    ## attribute is present and the refusal is the engine's, per the PLATFORM
    ## CONTRACT — and the edge does not publish and re-launches warm.
    if ccPath().len == 0:
      skip()
    elif not KernelIdentityHost:
      forgetDerivedTrustedDaemons()
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDaemon("unix", "reported")
      defer: stopDaemon(daemon)
      let daemonPid = processID(daemon.process)
      checkSpawnRegistersNothing(daemon.process)

      let capturePath = f.workRoot / "rep.iomon"
      let edge = f.reportEdge(repoRoot, "ipctrust/report", daemon.address,
        "report", capturePath)
      let config = monitoredConfig(repoRoot, f.cacheRoot)
      let res = runBuild(graph([edge]), config)
      let r0 = res.byId(edge.id)
      checkpoint("inert host, report: status=" & $r0.status & " reason=" &
        r0.reason & " stderr=" & r0.stderr &
        " diagnostics=" & $r0.evidence.diagnostics)
      check r0.status == asSucceeded
      check f.runCount("report") == 1
      check fileExists(capturePath)
      check attributionDiagnostics(r0).len == 0
      check not f.publishedRecordExists(edge)
      var sawConnect = false
      var sawLoss = false
      if fileExists(capturePath):
        for record in streamMonitorDepFileRecords(capturePath,
            defaultMonitorDepFileReaderOptions()):
          # Keyed on the socket path, with the pid this daemon's or the
          # documented "unobtainable" 0 — see `namesInertHostPeer`.
          if record.kind == mrIpcConnect and record.path == daemon.address and
              record.childOsPid in [uint64(daemonPid), 0'u64]:
            sawConnect = true
          if record.kind == mrEventLoss and
              namesInertHostPeer(record.detail, daemonPid, daemon.address):
            sawLoss = true
      check sawConnect
      check sawLoss
      let warm = runBuild(graph([edge]), config)
      check warm.byId(edge.id).cacheDecision notin ReuseDecisions
      check warm.byId(edge.id).launched
      check f.runCount("report") == 2
    else:
      forgetDerivedTrustedDaemons()
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDaemon("unix", "reported")
      defer: stopDaemon(daemon)
      let daemonPid = processID(daemon.process)
      trustDaemonWeSpawned(daemon.process, "ipctrust-daemon", tdcNoContent)
      check isLiveTrustedPid(daemonPid)

      let capturePath = f.workRoot / "rep.iomon"
      let edge = f.reportEdge(repoRoot, "ipctrust/report", daemon.address,
        "report", capturePath)
      let config = monitoredConfig(repoRoot, f.cacheRoot)
      let res = runBuild(graph([edge]), config)
      let r0 = res.byId(edge.id)
      checkpoint("report: status=" & $r0.status & " reason=" & r0.reason &
        " stderr=" & r0.stderr &
        " diagnostics=" & $r0.evidence.diagnostics)
      check r0.status == asSucceeded
      check f.runCount("report") == 1
      check fileExists(capturePath)
      check attributionDiagnostics(r0).len >= 1
      check f.publishedRecordExists(edge)

      # ATTRIBUTION, NOT SUPPRESSION — read the graded capture back off disk.
      var sawConnect = false
      var sawLoss = false
      if fileExists(capturePath):
        for record in streamMonitorDepFileRecords(capturePath,
            defaultMonitorDepFileReaderOptions()):
          if record.kind == mrIpcConnect and
              record.childOsPid == uint64(daemonPid):
            sawConnect = true
          if record.kind == mrEventLoss and
              "ipc peer outside monitored tree" in record.detail and
              ("peer=" & $daemonPid) in record.detail:
            sawLoss = true
      check sawConnect
      check sawLoss

      # THE NEGATIVE, on the SAME arm. A second daemon, same binary, same
      # protocol, alive at the same moment — and never registered.
      var stranger = f.startDaemon("unix", "stranger")
      defer: stopDaemon(stranger)
      check not isLiveTrustedPid(processID(stranger.process))
      # "ALIVE AT THE SAME MOMENT" IS ASSERTED HERE AND NOT ONLY ARRANGED. It
      # was arranged — the trusted daemon's `stopDaemon` is deferred, so it is
      # still running at this line — but an arrangement is not an observation,
      # and without this the negative below is equally consistent with "the
      # trusted daemon has since died and the trust set is simply empty now".
      # That is a weaker fact than the one this arm is for, which is that ONE
      # fold discriminates between TWO simultaneously live peers.
      check isLiveTrustedPid(daemonPid)
      let strangerCapture = f.workRoot / "str.iomon"
      let strangerEdge = f.reportEdge(repoRoot, "ipctrust/report-untrusted",
        stranger.address, "stranger", strangerCapture)
      let res2 = runBuild(graph([strangerEdge]), config)
      let r2 = res2.byId(strangerEdge.id)
      checkpoint("stranger: status=" & $r2.status & " reason=" & r2.reason &
        " diagnostics=" & $r2.evidence.diagnostics)
      check r2.status == asSucceeded
      check f.runCount("stranger") == 1
      check attributionDiagnostics(r2).len == 0
      check not f.publishedRecordExists(strangerEdge)
