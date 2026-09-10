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
##     `mrEventLoss` and not the `mrIpcConnect` it was derived from. Today
##     `monitorInterest` returns `FullInterest` unconditionally, so io-mon
##     always emits both; the shape becomes reachable the moment
##     `DependencyGatheringPolicy.captureIpc` — which already exists as
##     declared DSL surface — is narrowed.
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

suite "derived IPC trust: the daemons this process spawned":

  test "an action that talks only to a trusted daemon publishes, and a warm run hits":
    ## THE SYMPTOM, GONE — and measured as "publishes and is reused", not as a
    ## completeness enum, because the enum is not what rebuilt forever.
    if ccPath().len == 0:
      skip()
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
      trustDaemonWeSpawned(daemon.process, "ipctrust-daemon", tdcNoContent)
      check isLiveTrustedPid(processID(daemon.process))

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
    if ccPath().len == 0:
      skip()
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
    if ccPath().len == 0:
      skip()
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
    ## `unmonitoredSubtreeLossDetails` dedups on `pid:<peer>@<peerstart>` and
    ## emits the text of the FIRST NON-EXEMPT record per key. Which record that
    ## is differs between io-mon's run and the engine's recomputation, so the
    ## TEXT is not comparable across the two and only the KEY is.
    ##
    ## The capture: two connects to the SAME trusted peer, sharing one dedup
    ## key. The second carries a DUPLICATED `peerstart=` token — io-mon's
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
    let peer = selfAsTrustedDaemon("capture-daemon")
    check peer.identity.len > 0
    let plain = ipcConnectRecord(101, peer.pid, "/ipctrust/first.sock")
    let duplicated = ipcConnectRecord(202, peer.pid, "/ipctrust/second.sock",
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
    if findRunQuotaDaemonBin().len == 0:
      skip()
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
      # WHICH EARLY RETURN, STATED EXACTLY, because there are two and this
      # drives ONE of them. `startAutoRunQuotaIfNeeded` returns nil when
      # (1) `RUNQUOTA_SOCKET` is set AND reachable, or (2) the daemon is
      # reachable on `runquota_ipc.defaultEndpoint`. The first call left
      # `RUNQUOTA_SOCKET` pointing at the per-PID socket it bound, so what runs
      # below is (1).
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
    if ccPath().len == 0:
      skip()
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
