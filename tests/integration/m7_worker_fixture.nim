## Shared fixture for the Distributed-Execution M7 worker tests: a REAL
## worker daemon (`repro daemon serve --peer-cache=lan://…&worker=1`), an
## in-process orchestrator node, the evidence sink as its own process, a git
## fixture repository with uncommitted edits, and builders for the snapshot
## manifest and graph descriptor the orchestrator publishes.
##
## Not a test file (no `t_` prefix); imported by the M7 integration tests.
##
## MOCK POLICY — none. The worker is the shipped daemon binary with the
## worker role, the orchestrator is a production `PeerCacheHost`, the sink is
## the shipped `repro-evidence-sink`, the repository is a real git
## repository, and every tree id is computed by git itself (and checked
## against the worker's native computation).

import std/[asyncdispatch, options, os, osproc, sets, strtabs, strutils,
            tables, tempfiles, times, unittest]

import blake3

import repro_cas_store
import repro_peer_cache
import repro_test_support
import repro_workspace_snapshot
import repro_distributed_worker
import repro_cli_support/peer_cache_wiring

import ../../libs/repro_peer_cache/tests/m7_test_pki

export m7_test_pki
export peer_cache_wiring

type
  WorkerDaemon* = object
    node*: TestNode
    endpoint*: string
    stateDir*: string
    logPath*: string
    cacheRoot*: string
    process*: Process

  FixtureRepo* = object
    dir*: string
    cache*: string
      ## A bare clone: the worker's repository cache.
    baseCommit*: string

  Orchestrator* = object
    node*: TestNode
    host*: PeerCacheHost
    cacheRoot*: string
    published*: ref HashSet[BlobDigest]
      ## What this orchestrator published for its goals — exactly what a
      ## worker may fetch back over the orchestrator's connection (FLOW-1:
      ## the worker never dials the orchestrator).

proc publicReproBin*(): string =
  repoRootDir() / "build" / "bin" / addFileExt("repro", ExeExt)

proc git(dir: string; args: varargs[string]): string =
  let res = execCmdEx(quoteShellCommand(@["git", "-C", dir] & @args))
  if res.exitCode != 0:
    raise newException(IOError, "git " & args.join(" ") & " failed: " &
      res.output)
  res.output.strip()

proc makeFixtureRepo*(base: string; files: openArray[(string, string)]):
    FixtureRepo =
  ## A committed repository and a bare clone the worker reads base commits
  ## from.
  result.dir = base / "repo"
  createDir(result.dir)
  discard git(result.dir, "init", "-q", "-b", "main")
  discard git(result.dir, "config", "user.email", "m7@example.invalid")
  discard git(result.dir, "config", "user.name", "M7 Fixture")
  for (rel, content) in files:
    createDir((result.dir / rel).parentDir)
    writeFile(result.dir / rel, content)
    if rel.endsWith(".sh"):
      setFilePermissions(result.dir / rel, {fpUserRead, fpUserWrite,
        fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  discard git(result.dir, "add", "-A")
  discard git(result.dir, "commit", "-q", "-m", "base")
  result.baseCommit = git(result.dir, "rev-parse", "HEAD")
  result.cache = base / "repo-cache.git"
  discard execCmdEx(quoteShellCommand(["git", "clone", "-q", "--bare",
    result.dir, result.cache]))

proc gitTreeOfWorktree*(repo: FixtureRepo): string =
  ## The TC-8 content id of the working tree, computed by GIT in a temporary
  ## index (the user's index untouched): `read-tree HEAD`, `add -A`,
  ## `write-tree`.
  let index = repo.dir.parentDir / ".m7-tmp-index"
  defer: (try: removeFile(index) except OSError: discard)
  let env = "GIT_INDEX_FILE=" & quoteShell(index) & " "
  for cmd in ["git -C " & quoteShell(repo.dir) & " read-tree HEAD",
              "git -C " & quoteShell(repo.dir) & " add -A"]:
    let res = execCmdEx(env & cmd)
    if res.exitCode != 0: raise newException(IOError, res.output)
  let res = execCmdEx(env & "git -C " & quoteShell(repo.dir) & " write-tree")
  if res.exitCode != 0: raise newException(IOError, res.output)
  res.output.strip()

proc toBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc snapshotOf*(repo: FixtureRepo; repoId: string;
                 modified: openArray[string];
                 deleted: openArray[string] = []):
    tuple[manifest: WorkspaceSnapshotManifest; blobs: seq[seq[byte]]] =
  ## The manifest for the working tree (with `modified` paths edited or
  ## added and `deleted` removed relative to the base commit), and the blob
  ## bytes the worker will fetch.
  var snap = RepoSnapshot(repoId: repoId, baseCommitSha: repo.baseCommit,
    gitTreeSha1: gitTreeOfWorktree(repo))
  for rel in modified:
    let bytes = toBytes(readFile(repo.dir / rel))
    let exec = fpUserExec in getFilePermissions(repo.dir / rel)
    snap.modified.add(ModifiedFileEntry(relPath: rel,
      mode: (if exec: ModeExecutable else: ModeRegular),
      gitOid: gitBlobOid(bytes), blake3Digest: blake3.digest(bytes),
      size: uint64(bytes.len)))
    result.blobs.add(bytes)
  for rel in deleted:
    snap.deleted.add(rel)
  snap.sortedEntries()
  result.manifest = WorkspaceSnapshotManifest(schema: ManifestSchema,
    primaryRepo: snap)

proc newOrchestrator*(base: string; node: TestNode; workerPort: int;
                      sinkEndpoint = ""; workerAddress = "127.0.0.1";
                      bindSpec = ""; cidr = "127.0.0.0/8";
                      profile = tpHardened): Orchestrator =
  ## An in-process production node, seeded with the worker. Its trust
  ## profile must be the worker's (a trusted node presents its pinned
  ## host key, a hardened one a one-hour leaf).
  result.node = node
  result.cacheRoot = base / (node.name & "-cache")
  createDir(result.cacheRoot)
  var cfg = tlsConfig(node, seeds = @[initEndpoint(workerAddress,
    Port(workerPort))], evidence = sinkEndpoint, bindSpec = bindSpec,
    cidr = cidr, profile = profile)
  result.host = startPeerCacheHost(cfg, node.identity.hostId,
    cacheRoot = result.cacheRoot)
  result.published = new(HashSet[BlobDigest])
  result.published[] = initHashSet[BlobDigest]()

proc publish*(o: Orchestrator; bytes: seq[byte]): array[32, byte] =
  ## Puts `bytes` into the orchestrator's CAS (served over the content
  ## plane) and records it as published for the goals that follow.
  var cas = openCasStore(o.cacheRoot)
  defer: cas.close()
  result = bytes(cas.casPut(bytes))
  o.published[].incl(blobDigestFromBytes(result))

proc hydrationSet*(o: Orchestrator): HydrationSet =
  HydrationSet(digests: o.published[], reader: localReaderFor(o.host.storages))

proc pump*(ms: int) =
  let deadline = epochTime() + ms.float / 1000.0
  while epochTime() < deadline:
    try: poll(20) except ValueError: sleep(20)

proc reachGoal*(o: Orchestrator; worker: PeerId;
                req: ReachGoalRequest): GoalReply =
  ## Sends one ReachGoal, paced to the receiver's declared rate for the
  ## message (`boundary.Vocabulary[bmReachGoal]`: 2/s) — a test that sends
  ## faster is refused `rate`, which is the limiter working, not the case
  ## under test.
  pump(600)
  result = waitFor o.host.client.requestReachGoal(worker, encodeRequest(req),
    o.hydrationSet(), timeoutMs = 300_000)
  if result.kind == grkRefused:
    checkpoint("ReachGoal " & req.requestId & " refused by the gate: class " &
      $result.refusal.refusalClass & ": " & result.refusal.reason)

# ---------------------------------------------------------------------------
# The worker daemon.
# ---------------------------------------------------------------------------

proc newWorkerDaemon*(base: string; node: TestNode): WorkerDaemon =
  result.node = node
  result.endpoint = daemonSocketEndpoint("repro-m7-" & node.name & "-" &
    $getCurrentProcessId())
  result.stateDir = node.root / "state"
  result.logPath = result.stateDir / "logs" / "repro-daemon.log"
  result.cacheRoot = node.root / "action-cache"
  createDir(result.stateDir)
  createDir(result.cacheRoot)

proc daemonEnv*(d: WorkerDaemon): seq[(string, string)] =
  result = @[
    ("REPRO_DAEMON_ENDPOINT", d.endpoint),
    ("REPRO_DAEMON_STATE_DIR", d.stateDir),
    ("REPROBUILD_ACTION_CACHE_ROOT", d.cacheRoot),
    ("REPROBUILD_STORE_ROOT", d.node.root / "store"),
    ("XDG_STATE_HOME", d.node.xdgState)]

proc daemonLog*(d: WorkerDaemon): string =
  if fileExists(d.logPath): readFile(d.logPath)
  else: "(no daemon log at " & d.logPath & ")"

proc readKeyValues(path: string): Table[string, string] =
  result = initTable[string, string]()
  if not fileExists(path):
    return
  for line in readFile(path).splitLines():
    let eq = line.find('=')
    if eq > 0:
      result[line[0 ..< eq]] = line[eq + 1 .. ^1]

proc status*(d: WorkerDaemon): Table[string, string] =
  readKeyValues(d.stateDir / "peer-cache.status")

proc statusInt*(d: WorkerDaemon; key: string): int =
  try: parseInt(d.status().getOrDefault(key, "0")) except ValueError: 0

proc peerCacheEndpoint*(d: WorkerDaemon): string =
  let path = d.stateDir / "peer-cache-endpoint"
  if fileExists(path): readFile(path).strip() else: ""

proc peerCachePort*(d: WorkerDaemon): int =
  let text = d.peerCacheEndpoint()
  let colon = text.rfind(':')
  if colon < 0: return 0
  try: parseInt(text[colon + 1 .. ^1]) except ValueError: 0

proc startWorkerDaemon*(d: var WorkerDaemon; peerCacheSpec: string;
                        expectStart = true) =
  ## Starts `repro daemon serve` with `peerCacheSpec` and waits for its peer
  ## cache to come up (or, with `expectStart = false`, for the daemon to log
  ## its refusal).
  try: removeFile(d.endpoint) except OSError: discard
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  for (key, value) in daemonEnv(d):
    env[key] = value
  d.process = startProcess(publicReproBin(),
    args = @["daemon", "serve", "--foreground", "--endpoint", d.endpoint,
             "--state-dir", d.stateDir, "--log", d.logPath,
             "--peer-cache", peerCacheSpec],
    workingDir = repoRootDir(), env = env,
    options = {poUsePath, poStdErrToStdOut, poParentStreams})
  let deadline = epochTime() + 90.0
  while epochTime() < deadline:
    # The endpoint file appears when the peer cache binds; the service
    # (and the worker role) has finished starting when its start line is
    # in the log.
    if expectStart and d.peerCachePort() > 0 and
        "peer-cache started" in d.daemonLog():
      return
    if not expectStart and "background service failed to start" in d.daemonLog():
      return
    if not d.process.running:
      break
    sleep(50)
  if expectStart:
    checkpoint(d.node.name & " daemon log:\n" & d.daemonLog())
    raise newException(IOError, "worker daemon " & d.node.name &
      " did not start its peer cache")

proc stopWorkerDaemon*(d: var WorkerDaemon) =
  if d.process.isNil:
    return
  discard runShell(shellCommand(@[publicReproBin(), "daemon", "stop",
    "--endpoint", d.endpoint, "--state-dir", d.stateDir,
    "--log", d.logPath], daemonEnv(d)), repoRootDir())
  let deadline = epochTime() + 20.0
  while d.process.running and epochTime() < deadline:
    sleep(50)
  if d.process.running:
    d.process.terminate()
  discard d.process.waitForExit()
  d.process.close()
  d.process = nil
  try: removeFile(d.endpoint) except OSError: discard

proc workerSpec*(sink: SinkProcess; reposFile: string; heartbeatMs = 300;
                 extra = ""; cidr = "127.0.0.0/8"; signer = ""): string =
  ## The `lan://` spec of a HARDENED worker: TLS, the worker role, the
  ## sink, the repository caches (and the certificate signer when given).
  ## Loopback-bound (no `bind=`) unless `extra` says otherwise.
  "lan://" & cidr & "?tls=1&worker=1&profile=hardened&evidence=" &
    sink.endpoint & "&repos=" & reposFile & "&heartbeat=" & $heartbeatMs &
    (if signer.len > 0: "&signer=" & signer else: "") & extra

proc hardenedWorkerHere*(): bool =
  ## Trust profiles (2026-10-20): the HARDENED profile refuses macOS and
  ## Windows workers until a VM-grade lease boundary exists for them (an M8
  ## deliverable), so a hardened worker case runs on Linux only; elsewhere it
  ## is `[platform N/A]` and the trusted case covers the host.
  defined(linux)

const HardenedWorkerNA* = "[platform N/A] the hardened profile refuses " &
  "macOS and Windows workers until a VM-grade lease boundary exists (M8); " &
  "this host's worker is covered by the trusted-profile case"

proc trustedWorkerSpec*(reposFile: string; extra = "";
                        cidr = "127.0.0.0/8"): string =
  ## The `lan://` spec of a TRUSTED worker (the default profile, so no
  ## `profile=` at all): TLS with pinned host keys, the worker role, the
  ## repository caches. No sink and no signer — detections go to the
  ## execution record and the local log, the requester signs.
  "lan://" & cidr & "?tls=1&worker=1&repos=" & reposFile & extra

proc detectionLog*(d: WorkerDaemon): string =
  ## The trusted worker's local detection log: one allow-listed line per
  ## detection or heartbeat (`<unix seconds> <category> <detector>
  ## <trigger> k=v …`, `evidence_record.appendLocalLog`).
  let path = d.stateDir / "worker" / "detections.log"
  if fileExists(path): readFile(path) else: ""

proc casBlobPath*(d: WorkerDaemon; digest: array[32, byte]): string =
  ## Where the worker's CAS (its action-cache root) keeps `digest`.
  openCasStoreReadOnly(d.cacheRoot).casPath(toContentHash(digest))

proc fetchExecutionRecord*(o: Orchestrator; worker: PeerId;
                           digest: array[32, byte]): seq[byte] =
  ## The execution record a response names, fetched by its digest from the
  ## worker's CAS over the orchestrator's connection (BLAKE3-verified by
  ## the content plane).
  let got = waitFor o.host.client.requestFetchFrom(worker,
    blobDigestFromBytes(digest))
  if got.isSome: got.get() else: @[]

proc waitConnected*(o: Orchestrator; worker: PeerId; d: WorkerDaemon;
                    timeoutSeconds = 30.0): bool =
  ## The orchestrator's connection to the worker is up. The worker never
  ## dials back (FLOW-1): it hydrates over this very connection.
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    o.host.tick(50)
    if o.host.client.isConnected(worker):
      return true
  false

proc ccPath*(): string =
  result = findExe("cc")
  if result.len == 0:
    result = findExe("clang")
