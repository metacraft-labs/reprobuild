## The worker's `ReachGoal` receiver — Distributed-Execution M7.
##
## Runs AFTER the receiver gate (`repro_peer_cache/boundary.nim`) admitted
## the frame for a caller holding the `orchestrator` role, and does, in
## order, what makes the request a vocabulary entry rather than a command:
##
##   1. decode the request strictly;
##   2. HYDRATE the graph descriptor and the snapshot manifest by their
##      BLAKE3 digests (the fetcher verifies the bytes) and validate both;
##   3. materialize the snapshot into a fresh execution lease and verify its
##      `git-tree-sha1` (`repro_workspace_snapshot`);
##   4. `checkDerivation`: the named node is in the descriptor, the
##      descriptor is bound to that very tree, and every argv or input path
##      the request claims derives from them;
##   5. run the DESCRIPTOR node's argv in the lease (`lease.nim`) — the
##      request's argv is never executed;
##   6. collect the declared outputs into the CAS;
##   7. if a certificate was asked for and the node passed, RE-VERIFY the
##      worktree's tree id (the goal may have rewritten a tracked file) and
##      only then hand the issuance to the signer, which lives outside the
##      lease. A changed tree yields no certificate and a detection.
##
## Every refusal, every lease detection and every withheld certificate is
## recorded with the caller's verified host id — in BOTH profiles in the
## goal's execution record and the worker's local detection log, and in the
## HARDENED profile also at the evidence sink (`DetectionReporter`), lease
## detections the moment the supervisor reports them, not when the lease
## ends (threat model G21). A trusted worker has no sink.
##
## Distributed-Execution M7 review fixes:
##
## * the descriptor, manifest and blobs are fetched with the `BlobFetcher`
##   the caller's connection provides — over the connection the CALLER
##   opened, never by dialling it (FLOW-1, threat model D4);
## * a worker whose evidence is not leaving the host executes nothing
##   (`evidenceHealthy`, fail closed — threat model G28);
## * a certificate is withheld when the goal tripped a detector that
##   withholds one (threat model G32): in the HARDENED profile any lease
##   report; in the TRUSTED profile the plan's DET triggers only
##   (`execution_record.blocksCertificate`) — a macOS `fs-denied` is
##   recorded, not disqualifying;
## * `repro develop` SIBLINGS (Distributed-Execution M1 review fix,
##   2026-10-22): each sibling the manifest names is materialized and
##   verified against its own `gitTreeSha1` (a pool lease, or a fresh
##   checkout without a pool) under `<lease>/siblings/<siblingDirName>`,
##   beside the worktree, and exposed to the action read-only and
##   executable as `REPRO_DEVELOP_SIBLINGS` (`LeaseSpec.siblingsDir`). A
##   certificate binds the primary tree only (`content` is one
##   `git-tree-sha1`), so while siblings are present NO certificate is
##   issued: the goal's execution record carries
##   `certificate-withheld-develop-siblings` (which withholds signing in
##   both profiles, `blocksCertificate`) and the response says why. M2 binds
##   the siblings into certification and lifts this (G32);
## * the signer is not on this host (EDGE-5, threat model D5): the issuer
##   asks the certificate signer, which holds the signing CA.
##
## TRUST PROFILES (operator decision 2026-10-20; threat model §3a). Both
## profiles run steps 1-7 above — the derivation check, the lease, outputs
## read without following symlinks, the re-verification of the tree — and
## every goal writes an EXECUTION RECORD into the worker's CAS
## (`execution_record.nim`; its digest is in the response) holding the
## argv, the inputs, the outputs, the isolation level and every detection.
## Every detection also goes to the worker's local detection log. Then:
##
## * TRUSTED (default): the worker signs nothing. The REQUESTER (or a
##   designated publisher) signs the test certificate after it verified the
##   response, the tree and the execution record
##   (`repro_cli_support.requesterSignVerifiedGoal` — no production command
##   calls it yet; M2's remote goal driver wires it). No evidence sink is
##   required (`evidenceHealthy` is nil).
## * HARDENED: detections also go to the append-only evidence sink, the
##   worker refuses goals while its evidence cannot leave, and certificates
##   come from the off-worker certificate signer.
##
## A lease runs in its own SLOT, and on Linux each slot is its own
## subordinate uid. A node's network is exactly the operator-declared
## destinations the NODE names (`GraphNode.egress`); none named, none
## given. A declared impure action publishes its outputs only when each
## matches the digest it declared (`impure-output-mismatch` otherwise).
##
## INPUT ARTIFACTS (review fix, 2026-10-20). A node may name input nodes
## (`GraphNode.inputNodes`); the request then carries their outputs by
## digest (`ReachGoalRequest.inputArtifacts`, checked by `checkDerivation`
## against the descriptor). The worker hydrates each (BLAKE3-verified),
## writes it under `<lease>/inputs/<node>/<path>` — beside the worktree, not
## in it — and the lease mounts that directory read-only and EXECUTABLE
## (`LeaseSpec.inputsDir`, `REPRO_LEASE_INPUTS`): a test node runs the binary
## a build node produced, while the writable worktree, /tmp and /dev/shm
## stay noexec.

import std/[asyncdispatch, monotimes, options, os, strutils, tables, times]

import blake3
when defined(posix):
  import std/posix
  var O_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

import repro_peer_cache/[boundary, evidence_record, snapshot_blobs, types]
import repro_workspace_snapshot

import ./execution_record
import ./graph_descriptor
import ./lease
import ./reach_goal

type
  BlobFetcher* = proc(digest: array[32, byte]): Future[Option[seq[byte]]]
    {.gcsafe, closure.}
    ## A content-plane fetch by BLAKE3 digest; returns only verified bytes.
  OutputStore* = proc(bytes: seq[byte]): array[32, byte] {.gcsafe, closure.}
    ## Puts an output blob into the worker's CAS and returns its digest.

  CertificateRequest* = object
    content*: string
      ## `git-tree-sha1:<hex>` — re-verified immediately before this call.
    project*: string
    platform*: string
    target*: string
    commands*: seq[seq[string]]
    baseCommit*: string
    callerHost*: string

  CertificateIssuer* = proc(req: CertificateRequest): Future[tuple[ok: bool;
      certificate, reason: string]] {.gcsafe, closure.}
    ## Obtains a signed `test-certificate.v1` for a goal whose tree was
    ## re-verified. The worker holds no signing credential: production asks
    ## the certificate signer (`signer.nim`), outside the worker's zone.

  WorkerConfig* = object
    leaseRoot*: string
    metaRoot*: string
      ## Lease supervisor output; must not be under `leaseRoot`.
    repoCaches*: seq[(string, string)]
      ## `repoId` -> local repository cache holding the base commits.
    fetchRemotes*: seq[(string, string)]
      ## `repoId` -> the remote (URL or path) a base commit missing from its
      ## repository cache is fetched from (the worktree pool's
      ## `fetchRemotes`; the daemon's `repos=` file, third column).
      ## Operator configuration, never a request field.
    platform*: string
    readRoots*: seq[string]
    closureRoots*: seq[string]
    hidePaths*: seq[string]
    egress*: seq[EgressDestination]
    pathEnv*: string
      ## `PATH` inside the lease.
    timeoutMs*: int
    layers*: set[LeaseLayer]
    cgroups*: LeaseCgroups
      ## Per-lease memory and process limits, when available (G31).
    profile*: TrustProfile
      ## `tpTrusted` (default) or `tpHardened`; see the module doc.
    workerHost*: string
      ## This worker's host id, for the execution record.
    detectionLogPath*: string
      ## The local detection log (one allow-listed line per detection,
      ## owner-only, rotated and deleted — `evidence_record.appendLocalLog`,
      ## EVID-6); "" = none.
    recordIndexPath*: string
      ## Where the worker lists the execution records it stored (`<unix
      ## seconds> <digest>` per line, owner-only), so
      ## `sweepExecutionRecords` can delete them from the CAS once past
      ## `ExecutionRecordRetentionSeconds` (EVID-6); "" = none.
    leaseSlots*: int
      ## Concurrent leases (each its own slot, and on Linux its own
      ## subordinate uid); 0 = `DefaultLeaseSlots`. The canary lease uses
      ## the slot after the last.
    worktreePoolRoot*: string
      ## Distributed-Execution M1: the worktree pool (`repro_workspace_snapshot/
      ## pool`) — base worktrees per repository, kept outside every lease;
      ## each goal's worktree is a copy-on-write clone of one, with the
      ## snapshot's delta applied and its tree verified. "" = check the base
      ## commit out afresh for every goal (`materializeRepoSnapshot`).

  WorkerReceiver* = ref object
    config*: WorkerConfig
    fetchBlob*: BlobFetcher
    storeOutput*: OutputStore
    issuer*: CertificateIssuer
    reporter*: DetectionReporter
    storeRecord*: OutputStore
      ## Stores an execution record (owner-only in production); nil = use
      ## `storeOutput`.
    evidenceHealthy*: proc(): bool {.gcsafe, closure.}
      ## Whether evidence is leaving the host; nil = assume it is. While
      ## false every goal is refused (`goal-evidence-unavailable`).
    goalsRefused*: int
    goalsExecuted*: int
    certificatesIssued*: int
    certificatesWithheld*: int
    executionRecords*: int
    leaseCounter: int
    slots: seq[bool]
    pool*: WorktreePool
      ## Created from `config.worktreePoolRoot` (nil without one).
    materializations*: int
      ## Snapshots materialized and verified (primary and siblings).
    lastMaterializeMs*: float
      ## Wall time of the last one, from the goal's arrival: hydrating the
      ## descriptor, the manifest and the snapshot's blobs, then every
      ## repository's materialization and verification.

const
  DefaultLeaseSlots* = 16
  WorkerDetectors* = ["goal-receiver", "lease-supervisor",
                      "certificate-issuance"]
  ProbedWorkerDetectors* = ["lease-supervisor"]
    ## Heartbeat only after a canary lease proved them working
    ## (`runCanaryLease`; threat model G22).

proc newWorkerReceiver*(config: WorkerConfig; fetchBlob: BlobFetcher;
                        storeOutput: OutputStore;
                        issuer: CertificateIssuer = nil;
                        reporter: DetectionReporter = nil): WorkerReceiver =
  var cfg = config
  if cfg.layers == {}:
    cfg.layers = DefaultLeaseLayers
  if cfg.metaRoot.startsWith(cfg.leaseRoot & "/") or cfg.metaRoot == cfg.leaseRoot:
    raise newException(ValueError,
      "lease supervisor output must live outside the lease root")
  if cfg.leaseSlots <= 0:
    cfg.leaseSlots = DefaultLeaseSlots
  result = WorkerReceiver(config: cfg, fetchBlob: fetchBlob,
    storeOutput: storeOutput, issuer: issuer, reporter: reporter,
    slots: newSeq[bool](cfg.leaseSlots))
  if cfg.worktreePoolRoot.len > 0:
    result.pool = newWorktreePool(cfg.worktreePoolRoot)
    for (id, remote) in cfg.fetchRemotes:
      result.pool.fetchRemotes[id] = remote

proc acquireSlot(r: WorkerReceiver): int =
  for i in 0 ..< r.slots.len:
    if not r.slots[i]:
      r.slots[i] = true
      return i
  -1

proc releaseSlot(r: WorkerReceiver; slot: int) =
  if slot >= 0 and slot < r.slots.len:
    r.slots[slot] = false

proc canarySlot*(r: WorkerReceiver): int = r.config.leaseSlots

proc hex32(d: array[32, byte]): string =
  const H = "0123456789abcdef"
  result = newString(64)
  for i, b in d:
    result[2 * i] = H[int(b) shr 4]
    result[2 * i + 1] = H[int(b) and 0xf]

type
  GoalLog = ref object
    ## The detections of one goal, for its execution record.
    detections: seq[RecordedDetection]

proc fieldOf(fields: openArray[(string, string)]; key: string): string =
  for (k, v) in fields:
    if k == key: return v
  ""

proc report(r: WorkerReceiver; detector, trigger: string;
            fields: openArray[(string, string)]; payload: seq[byte] = @[];
            log: GoalLog = nil) =
  ## A detection: into the goal's execution record (`log`), into the local
  ## detection log, and — when a reporter is wired (the hardened profile's
  ## evidence sink) — off the host. Payload bytes never go to the local log
  ## or the record (they can carry the developer's source).
  if not log.isNil:
    var detail = fieldOf(fields, "reason")
    if detail.len == 0: detail = fieldOf(fields, "destination")
    if detail.len == 0: detail = fieldOf(fields, "path")
    log.detections.add(RecordedDetection(detector: detector,
      trigger: trigger, detail: detail,
      operation: fieldOf(fields, "operation")))
  let record = newEvidenceRecord(ecDetection, detector, trigger, fields,
    payload)
  if r.config.detectionLogPath.len > 0:
    # EVID-6 (trusted profile's local store): allow-listed fields only,
    # owner-only, rotated and deleted on schedule — `appendLocalLog`.
    appendLocalLog(r.config.detectionLogPath, localLogEntry(record))
  if r.reporter.isNil:
    return
  try:
    r.reporter(record)
  except CatchableError:
    discard

proc writeRecord(r: WorkerReceiver; rec: ExecutionRecord): array[32, byte] =
  ## Stores `rec` in the worker's CAS; its digest names it in the response.
  ## The digest is also listed in the record index, so the record is
  ## deleted once past its retention (EVID-6).
  let store = if r.storeRecord.isNil: r.storeOutput else: r.storeRecord
  if store.isNil:
    return default(array[32, byte])
  try:
    result = store(encodeExecutionRecord(rec))
    inc r.executionRecords
  except CatchableError:
    return default(array[32, byte])
  if r.config.recordIndexPath.len > 0:
    appendRecordIndex(r.config.recordIndexPath, result)

proc callerOf(c: CallerIdentity): string =
  if c.authenticated: $c.hostId else: "anonymous@" & c.address

proc baseRecord(r: WorkerReceiver; caller: CallerIdentity;
                req: ReachGoalRequest): ExecutionRecord =
  ExecutionRecord(schema: ExecutionRecordSchema, profile: $r.config.profile,
    workerHost: r.config.workerHost, caller: callerOf(caller),
    requestId: req.requestId, goalNode: req.goalNode,
    descriptorDigest: hex32(req.graphDescriptorDigest),
    snapshotDigest: hex32(req.snapshotManifestDigest),
    startedAtMs: int64(epochTime() * 1000))

proc refuse(r: WorkerReceiver; caller: CallerIdentity; req: ReachGoalRequest;
            trigger, reason: string; payload: seq[byte];
            extra: openArray[(string, string)] = [];
            rec: ExecutionRecord = ExecutionRecord();
            log: GoalLog = nil): ReachGoalResponse =
  inc r.goalsRefused
  var fields = @[("peer", callerOf(caller)), ("goalNode", req.goalNode),
    ("descriptorDigest", hex32(req.graphDescriptorDigest)),
    ("snapshotDigest", hex32(req.snapshotManifestDigest)),
    ("reason", reason)]
  for f in extra: fields.add(f)
  let goalLog = if log.isNil: GoalLog() else: log
  r.report("goal-receiver", trigger, fields, payload, goalLog)
  var record = if rec.schema.len > 0: rec else: r.baseRecord(caller, req)
  record.status = "refused"
  record.trigger = trigger
  record.detections = goalLog.detections
  record.endedAtMs = int64(epochTime() * 1000)
  ReachGoalResponse(requestId: req.requestId, status: gsRefused,
    trigger: trigger, reason: reason, profile: $r.config.profile,
    executionRecordDigest: r.writeRecord(record))

const
  MaxOutputBytes* = 512 * 1024 * 1024
    ## The largest declared output the worker reads back into its CAS (the
    ## same bound the snapshot manifest puts on one blob).

proc nonDirectoryParent*(root, rel: string): string =
  ## "" when every EXISTING parent of `rel` beneath `root` is a real
  ## directory; otherwise the first component that is a symlink or not a
  ## directory. An absent component is fine: nothing resolves through it.
  ##
  ## Why it matters: the daemon reads declared outputs, and the lease's
  ## output directories become Landlock/Seatbelt rules, OUTSIDE the lease.
  ## The worktree is attacker-shaped (a snapshot may carry a mode-120000
  ## entry; the goal itself can create symlinks), so a path that resolves
  ## through a symlink could name the daemon's keys.
  let parts = rel.split('/')
  var cur = root
  for i in 0 ..< parts.high:
    cur = cur / parts[i]
    when defined(posix):
      var st: Stat
      if lstat(cur.cstring, st) == 0:
        if S_ISLNK(st.st_mode) or not S_ISDIR(st.st_mode):
          return cur
    else:
      if symlinkExists(cur): return cur
  ""

type
  OutputRead* = object
    present*, ok*: bool
    bytes*: seq[byte]
    reason*: string

proc readDeclaredOutput*(worktree, rel: string): OutputRead =
  ## Reads a declared output WITHOUT following a symlink anywhere on its
  ## path: every parent must be a real directory, the file itself is opened
  ## `O_NOFOLLOW` and must be a regular file of at most `MaxOutputBytes`.
  ## Absent is not an error (`present = false`); anything else that is not
  ## a regular file is refused with a reason. Runs after the lease ended
  ## (on Linux every lease process died with its pid namespace).
  let bad = nonDirectoryParent(worktree, rel)
  if bad.len > 0:
    return OutputRead(present: true, reason: "a parent of declared output " &
      rel & " is a symlink or not a directory: " & bad)
  let path = worktree / rel
  when defined(posix):
    var st: Stat
    if lstat(path.cstring, st) != 0:
      return OutputRead()
    if S_ISLNK(st.st_mode) or not S_ISREG(st.st_mode):
      return OutputRead(present: true, reason: "declared output " & rel &
        " is not a regular file (the daemon never reads through a symlink " &
        "or a special file)")
    let fd = posix.open(path.cstring, O_RDONLY or O_NOFOLLOW or O_CLOEXEC)
    if fd < 0:
      return OutputRead(present: true, reason: "cannot open declared output " &
        rel & ": " & $strerror(errno))
    defer: discard posix.close(fd)
    var fst: Stat
    if fstat(fd, fst) != 0 or not S_ISREG(fst.st_mode):
      return OutputRead(present: true, reason: "declared output " & rel &
        " changed type while it was opened")
    if int64(fst.st_size) > MaxOutputBytes:
      return OutputRead(present: true, reason: "declared output " & rel &
        " exceeds " & $MaxOutputBytes & " bytes")
    var bytes = newSeq[byte](int(fst.st_size))
    var got = 0
    while got < bytes.len:
      let n = posix.read(fd, addr bytes[got], bytes.len - got)
      if n < 0:
        if errno == EINTR: continue
        return OutputRead(present: true, reason: "reading declared output " &
          rel & " failed: " & $strerror(errno))
      if n == 0: break
      got += n
    bytes.setLen(got)
    OutputRead(present: true, ok: true, bytes: bytes)
  else:
    # Windows: no O_NOFOLLOW, so the same rule by attributes — the file
    # must be a regular file that is not a reparse point (a symlink or a
    # junction), and every parent was checked above. The worker reads it
    # after the job object ended (every process of the lease is dead), so
    # nothing in the lease can swap it between the check and the read.
    if not fileExists(path) and not symlinkExists(path):
      return OutputRead()
    if symlinkExists(path):
      return OutputRead(present: true, reason: "declared output " & rel &
        " is a symlink or reparse point (the daemon never reads through one)")
    let info = try: getFileInfo(path, followSymlink = false)
               except OSError: return OutputRead(present: true,
                 reason: "cannot stat declared output " & rel)
    if info.kind != pcFile:
      return OutputRead(present: true, reason: "declared output " & rel &
        " is not a regular file")
    if info.size > MaxOutputBytes:
      return OutputRead(present: true, reason: "declared output " & rel &
        " exceeds " & $MaxOutputBytes & " bytes")
    let text = try: readFile(path)
               except IOError: return OutputRead(present: true,
                 reason: "reading declared output " & rel & " failed")
    var bytes = newSeq[byte](text.len)
    if text.len > 0: copyMem(addr bytes[0], unsafeAddr text[0], text.len)
    OutputRead(present: true, ok: true, bytes: bytes)

proc repoCacheFor(r: WorkerReceiver; repoId: string): string =
  for (id, path) in r.config.repoCaches:
    if id == repoId: return path
  ""

proc workerOwnedEnv*(leaseDir, pathEnv: string): seq[(string, string)] =
  ## The variables the WORKER sets in every lease; a descriptor cannot
  ## override them (`PATH` stays inside the closure, `HOME` and the temp
  ## directories inside the lease). Windows adds what a Win32 process needs
  ## to start at all — `SystemRoot` and `windir` (the loader, Winsock and
  ## crypto look them up) — and points `TEMP`/`TMP` into the lease.
  result = @[("HOME", leaseDir / "home"), ("TMPDIR", leaseDir / "tmp"),
             ("PATH", pathEnv), ("LANG", "C")]
  when defined(windows):
    let sysRoot = getEnv("SystemRoot", getEnv("windir", "C:\\Windows"))
    result.add(("SystemRoot", sysRoot))
    result.add(("windir", sysRoot))
    result.add(("TEMP", leaseDir / "tmp"))
    result.add(("TMP", leaseDir / "tmp"))

proc isWorkerOwned*(owned: seq[(string, string)]; name: string): bool =
  ## Windows environment names are case-insensitive (`path` IS `PATH`).
  for (k, _) in owned:
    when defined(windows):
      if cmpIgnoreCase(k, name) == 0: return true
    else:
      if k == name: return true
  false

proc leaseSpecFor(r: WorkerReceiver; leaseId: string; node: GraphNode;
                  worktree: string; egress: seq[EgressDestination];
                  slot: int; inputsDir = "", siblingsDir = ""): LeaseSpec =
  let leaseDir = r.config.leaseRoot / leaseId
  var outputDirs: seq[string] = @[]
  for o in node.outputs:
    let d = (worktree / o).parentDir
    if d notin outputDirs: outputDirs.add(d)
  var env = workerOwnedEnv(leaseDir, r.config.pathEnv)
  # The worker owns those: a descriptor cannot point PATH outside the
  # closure or HOME/TMPDIR outside the lease. Its other variables follow.
  let owned = env
  for kv in node.env:
    if not owned.isWorkerOwned(kv[0]):
      env.add(kv)
  LeaseSpec(leaseId: leaseId, leaseRoot: r.config.leaseRoot,
    leaseDir: leaseDir, metaDir: r.config.metaRoot / leaseId,
    cwd: (if node.cwd.len > 0: worktree / node.cwd else: worktree),
    argv: node.argv, env: env, readRoots: r.config.readRoots,
    closureRoots: r.config.closureRoots, outputDirs: outputDirs,
    hidePaths: r.config.hidePaths, egress: egress,
    layers: r.config.layers, timeoutMs: r.config.timeoutMs, slot: slot,
    inputsDir: inputsDir, siblingsDir: siblingsDir,
    memfdNoexec: r.config.profile == tpHardened)

proc openSiblingTree(root: string) =
  ## The develop siblings are bound read-only into the lease and stay the
  ## daemon's files (on Linux the lease runs as another uid): directories
  ## searchable and files readable by everyone, executables executable.
  when defined(posix):
    let dirPerms = {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead,
      fpGroupExec, fpOthersRead, fpOthersExec}
    setFilePermissions(root, dirPerms)
    for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
      if symlinkExists(path):
        continue
      if dirExists(path):
        setFilePermissions(path, dirPerms)
      else:
        var perms = getFilePermissions(path) + {fpUserRead, fpGroupRead,
          fpOthersRead}
        if fpUserExec in perms:
          perms.incl({fpGroupExec, fpOthersExec})
        setFilePermissions(path, perms)

proc handleReachGoal*(r: WorkerReceiver; caller: CallerIdentity;
                      payload: seq[byte];
                      fetchBlob: BlobFetcher = nil): Future[ReachGoalResponse]
                      {.async.} =
  ## See the module doc. `fetchBlob` hydrates over the caller's own
  ## connection; nil = the receiver's default fetcher.
  let fetch = if fetchBlob.isNil: r.fetchBlob else: fetchBlob
  let goalArrived = getMonoTime()
  let log = GoalLog()
  var req: ReachGoalRequest
  try:
    req = decodeRequest(payload)
  except CatchableError as err:
    return r.refuse(caller, req, "goal-schema-invalid", err.msg, payload,
      log = log)
  var rec = r.baseRecord(caller, req)
  if not r.evidenceHealthy.isNil and not r.evidenceHealthy():
    # Fail closed (G28, hardened profile): nothing runs while its evidence
    # could not leave.
    return r.refuse(caller, req, "goal-evidence-unavailable",
      "the evidence sink is unreachable; this worker executes nothing " &
      "until its evidence leaves the host again", payload, rec = rec,
      log = log)
  # 2. Hydrate.
  let descBytes = await fetch(req.graphDescriptorDigest)
  if descBytes.isNone:
    return r.refuse(caller, req, "goal-descriptor-unbound",
      "the graph descriptor could not be hydrated by its digest", payload,
      rec = rec, log = log)
  var desc: GraphCacheDescriptor
  try:
    desc = decodeDescriptor(descBytes.get())
  except CatchableError as err:
    return r.refuse(caller, req, "goal-schema-invalid",
      "malformed graph descriptor: " & err.msg, payload, rec = rec, log = log)
  let badDesc = validateDescriptor(desc)
  if badDesc.len > 0:
    return r.refuse(caller, req, "goal-schema-invalid", badDesc, payload,
      rec = rec, log = log)
  if desc.platform != r.config.platform:
    return r.refuse(caller, req, "goal-descriptor-unbound",
      "descriptor platform " & desc.platform & " is not this worker's " &
      r.config.platform, payload, rec = rec, log = log)
  let manBytes = await fetch(req.snapshotManifestDigest)
  if manBytes.isNone:
    return r.refuse(caller, req, "goal-descriptor-unbound",
      "the snapshot manifest could not be hydrated by its digest", payload,
      rec = rec, log = log)
  var snap: WorkspaceSnapshotManifest
  try:
    snap = decodeManifest(manBytes.get())
  except CatchableError as err:
    return r.refuse(caller, req, "goal-schema-invalid",
      "malformed snapshot manifest: " & err.msg, payload, rec = rec, log = log)
  let badSnap = validateManifest(snap)
  if badSnap.len > 0:
    return r.refuse(caller, req, "goal-schema-invalid", badSnap, payload,
      rec = rec, log = log)
  rec.snapshotContentId = contentIdOf(snap)
  if desc.snapshotContentId != contentIdOf(snap):
    return r.refuse(caller, req, "goal-descriptor-unbound",
      "the descriptor was evaluated from " & desc.snapshotContentId &
      " but the snapshot is " & contentIdOf(snap), payload, rec = rec,
      log = log)
  let cache = r.repoCacheFor(snap.primaryRepo.repoId)
  if cache.len == 0:
    return r.refuse(caller, req, "goal-descriptor-unbound",
      "this worker holds no repository cache for '" &
      snap.primaryRepo.repoId & "'", payload, rec = rec, log = log)
  for sib in snap.developSiblings:
    if r.repoCacheFor(sib.repoId).len == 0:
      return r.refuse(caller, req, "goal-descriptor-unbound",
        "this worker holds no repository cache for repro develop sibling '" &
        sib.repoId & "'", payload, rec = rec, log = log)
  # 3. Materialize into a fresh lease and verify the tree.
  inc r.leaseCounter
  let leaseId = "g" & $getCurrentProcessId() & "-" & $r.leaseCounter & "-" &
    $int64(epochTime() * 1000)
  let worktree = r.config.leaseRoot / leaseId / "wt"
  let siblingsRoot =
    if snap.developSiblings.len > 0: r.config.leaseRoot / leaseId / "siblings"
    else: ""
  createDir(r.config.leaseRoot / leaseId)
  # Fetch exactly the snapshot's modified blobs first (asynchronously, each
  # BLAKE3-verified), so materialization itself never blocks the dispatcher.
  # They stay in memory: the worker's own stores never hold a snapshot's
  # uncommitted source (EVID-6). A repository's base pack (the requester's
  # unpushed history) is fetched only when this worker lacks its base
  # commit.
  let rr0 = r
  let needsPack = proc(repo: RepoSnapshot): bool {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      let c = rr0.repoCacheFor(repo.repoId)
      if c.len == 0:
        false
      elif rr0.pool.isNil:
        cacheNeedsBasePack(c, repo)
      else:
        rr0.pool.needsBasePack(c, repo)
  let hydrated = await fetchSnapshotBlobs(snap,
    proc(d: array[32, byte]): Future[Option[seq[byte]]] {.gcsafe.} =
      fetch(d), needsPack)
  let blobReader = proc(d: Blake3Digest): Option[seq[byte]] {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      if hydrated.blobs.hasKey(d): some(hydrated.blobs[d])
      else: none(seq[byte])
  var slot = -1
  var spec = LeaseSpec(leaseId: leaseId, leaseRoot: r.config.leaseRoot,
    leaseDir: r.config.leaseRoot / leaseId, metaDir: r.config.metaRoot / leaseId,
    layers: {})
  proc dropLease() =
    discard cleanupLease(spec)
    r.releaseSlot(slot)
    # The supervisor's output (the goal's stdout/stderr, its reports) can
    # carry uncommitted source (asset 3); everything the response needs has
    # been read by now, so it is not retained (EVID-6).
    try: removeDir(spec.metaDir) except OSError: discard
  var mat: MaterializeResult
  try:
    if r.pool.isNil:
      mat = materializeRepoSnapshot(cache, snap.primaryRepo, worktree,
        blobReader)
      if mat.ok and siblingsRoot.len > 0:
        createDir(siblingsRoot)
        for sib in snap.developSiblings:
          let sm = materializeRepoSnapshot(r.repoCacheFor(sib.repoId), sib,
            siblingsRoot / siblingDirName(sib.repoId), blobReader)
          if not sm.ok:
            mat = MaterializeResult(worktree: worktree,
              reason: "repro develop sibling " & sib.repoId & ": " & sm.reason)
            break
    else:
      let rr1 = r
      let all = r.pool.materializeWorkspaceSnapshot(snap,
        proc(id: string): string {.gcsafe, closure.} =
          {.cast(gcsafe).}: rr1.repoCacheFor(id),
        worktree, siblingsRoot, blobReader)
      mat = all.primary
      if not all.ok:
        mat.ok = false
        mat.reason = all.reason
    if mat.ok and siblingsRoot.len > 0:
      openSiblingTree(siblingsRoot)
  except CatchableError as err:
    # A snapshot whose entries collide with the base tree (a file where the
    # base has a directory, …) raises from the filesystem calls. It is still
    # a refusal of THIS request, with its lease removed and its evidence
    # sent, never a leaked directory and a bare "worker error".
    dropLease()
    return r.refuse(caller, req, "goal-descriptor-unbound",
      "the snapshot could not be materialized: " & err.msg, payload,
      rec = rec, log = log)
  if not mat.ok:
    dropLease()
    return r.refuse(caller, req, "goal-descriptor-unbound",
      "snapshot verification failed: " & mat.reason, payload, rec = rec,
      log = log)
  rec.treeBefore = mat.observedTree
  inc r.materializations
  r.lastMaterializeMs = float((getMonoTime() - goalArrived).inMicroseconds) /
    1000.0
  # 4. Derivation.
  let verdict = checkDerivation(req, desc, snap, mat.tracked)
  if not verdict.ok:
    dropLease()
    return r.refuse(caller, req, verdict.trigger, verdict.reason, payload,
      [("argv", req.claimedArgv.join(" ")),
       ("path", req.claimedInputs.join(" "))], rec = rec, log = log)
  let node = desc.nodes[verdict.nodeIndex]
  rec.argv = node.argv
  rec.cwd = node.cwd
  rec.egress = node.egress
  rec.impure = node.impure
  # An output whose directory resolves through a symlink in the verified
  # tree would turn into a lease rule (read/exec on Linux and macOS) on
  # wherever that symlink points. Refused before anything runs.
  for o in node.outputs:
    let bad = nonDirectoryParent(worktree, o)
    if bad.len > 0:
      dropLease()
      return r.refuse(caller, req, "goal-path-outside-snapshot",
        "declared output " & o & " resolves through a symlink or a " &
        "non-directory in the snapshot: " & bad, payload,
        [("path", o)], rec = rec, log = log)
  # The node's network: exactly the operator-declared destinations it
  # names; none named, none given.
  var leaseEgress: seq[EgressDestination] = @[]
  for name in node.egress:
    var found = false
    for d in r.config.egress:
      if d.name == name:
        leaseEgress.add(d)
        found = true
        break
    if not found:
      dropLease()
      return r.refuse(caller, req, "goal-schema-invalid",
        "node '" & node.id & "' declares egress destination '" & name &
        "', which this worker's operator did not declare", payload,
        rec = rec, log = log)
  # Input artifacts: the outputs of declared input nodes, hydrated by
  # digest (the fetcher verifies BLAKE3), written beside the worktree and
  # mounted read-only and executable for the action.
  var inputsDir = ""
  if req.inputArtifacts.len > 0:
    inputsDir = r.config.leaseRoot / leaseId / "inputs"
    for a in req.inputArtifacts:
      let bytes = await fetch(a.digest)
      if bytes.isNone or bytes.get().len > MaxOutputBytes:
        dropLease()
        return r.refuse(caller, req, "goal-descriptor-unbound",
          "input artifact " & a.node & ":" & a.path & " could not be " &
          "hydrated by its digest", payload, [("path", a.path)], rec = rec,
          log = log)
      let dest = inputsDir / a.node / a.path
      try:
        createDir(dest.parentDir)
        writeFile(dest, bytes.get())
        setFilePermissions(dest, {fpUserRead, fpUserWrite, fpUserExec,
          fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
      except CatchableError as err:
        dropLease()
        return r.refuse(caller, req, "goal-descriptor-unbound",
          "input artifact " & a.node & ":" & a.path & " could not be " &
          "materialized: " & err.msg, payload, [("path", a.path)], rec = rec,
          log = log)
      rec.inputArtifacts.add(RecordedInput(node: a.node, path: a.path,
        digest: recordHex(a.digest)))
    # Directories: searchable and readable by the lease user, never
    # writable by it (Linux binds the tree read-only besides).
    for d in walkDirRec(inputsDir, yieldFilter = {pcDir}):
      setFilePermissions(d, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
    setFilePermissions(inputsDir, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  slot = r.acquireSlot()
  if slot < 0:
    dropLease()
    return ReachGoalResponse(requestId: req.requestId, status: gsFailed,
      reason: "every lease slot of this worker is busy",
      profile: $r.config.profile)
  # 5. Execute the descriptor's argv in the lease, its detections recorded
  # (and, hardened, leaving the host) as they happen (G21).
  spec = r.leaseSpecFor(leaseId, node, worktree, leaseEgress, slot,
    inputsDir, siblingsRoot)
  for (k, _) in spec.env: rec.envNames.add(k)
  let cg = leaseCgroupFor(r.config.cgroups, leaseId)
  if not cg.ok:
    dropLease()
    return ReachGoalResponse(requestId: req.requestId, status: gsFailed,
      reason: "the lease's cgroup could not be created",
      profile: $r.config.profile)
  spec.cgroupPath = cg.path
  let rr = r
  let peerName = callerOf(caller)
  let nodeId = node.id
  let onReport = proc(rep: LeaseReport) {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      var fields = @[("peer", peerName), ("leaseId", leaseId),
        ("goalNode", nodeId), ("destination", rep.detail),
        ("operation", rep.syscall), ("pid", $rep.pid)]
      if rep.count > 0: fields.add(("count", $rep.count))
      rr.report("lease-supervisor", rep.kind, fields, log = log)
  var outcome: LeaseOutcome
  try:
    outcome = await runLease(spec, onReport)
  except CatchableError as err:
    outcome = LeaseOutcome(error: "the execution lease failed: " & err.msg)
  removeLeaseCgroup(cg.path)
  rec.isolation = outcome.isolation
  var resp = ReachGoalResponse(requestId: req.requestId,
    treeBefore: mat.observedTree, leaseReports: int32(outcome.reports.len),
    profile: $r.config.profile, isolation: outcome.isolation)
  if not outcome.started:
    dropLease()
    resp.status = gsFailed
    resp.reason = "the execution lease could not be set up: " & outcome.error
    rec.status = "failed"
    rec.detections = log.detections
    rec.endedAtMs = int64(epochTime() * 1000)
    resp.executionRecordDigest = r.writeRecord(rec)
    return resp
  inc r.goalsExecuted
  resp.stderrTail = outcome.stderr
  resp.exitCode = int32(outcome.exitCode)
  rec.exitCode = outcome.exitCode
  rec.timedOut = outcome.timedOut
  resp.status = if outcome.exitCode == 0 and not outcome.timedOut: gsCompleted
                else: gsFailed
  if outcome.timedOut:
    resp.reason = "the goal exceeded its time limit"
  # 6. Outputs — read by the DAEMON, outside the lease, so never through a
  # symlink: a goal that plants `out/x -> <state>/host-ca.key` must not get
  # the daemon to put its keys into the CAS it serves.
  var collected: seq[(string, seq[byte])] = @[]
  for o in node.outputs:
    let got = readDeclaredOutput(worktree, o)
    if not got.present:
      continue
    if not got.ok:
      r.report("goal-receiver", "goal-output-not-regular",
        [("peer", callerOf(caller)), ("leaseId", leaseId),
         ("goalNode", node.id), ("path", o), ("reason", got.reason)],
        log = log)
      resp.status = gsFailed
      resp.reason = got.reason
      continue
    collected.add((o, got.bytes))
  # A declared impure action (fixed-output): every output must match the
  # digest it declared, or nothing it produced is published.
  if node.impure:
    for (path, want) in node.fixedOutputs:
      var have = ""
      for (p, bytes) in collected:
        if p == path: have = recordHex(blake3.digest(bytes))
      if have != recordHex(want):
        r.report("goal-receiver", "impure-output-mismatch",
          [("peer", callerOf(caller)), ("leaseId", leaseId),
           ("goalNode", node.id), ("path", path),
           ("reason", "declared " & recordHex(want) & ", produced " &
             (if have.len > 0: have else: "nothing"))], log = log)
        resp.status = gsFailed
        resp.reason = "impure action output " & path &
          " does not match its declared digest"
    if resp.status != gsCompleted:
      collected.setLen(0)
  for (o, bytes) in collected:
    let digest =
      if r.storeOutput.isNil: default(array[32, byte])
      else: r.storeOutput(bytes)
    resp.outputs.add(GoalOutput(path: o, digest: digest,
      size: uint64(bytes.len)))
    rec.outputs.add(RecordedOutput(path: o, digest: recordHex(digest),
      size: uint64(bytes.len)))
  # 7. Re-verify the tree, then certify — the hardened worker through the
  # signer, the trusted one by leaving it to the requester.
  let after = reverifyTree(worktree, mat.tracked, snap.primaryRepo.gitTreeSha1,
    mat.gitlinks)
  resp.treeAfter = after.observed
  rec.treeAfter = after.observed
  if not after.ok:
    # The tree changed under the goal: a DET trigger in both profiles,
    # whether or not a certificate was asked for.
    r.report("certificate-issuance", "certificate-tree-mismatch",
      [("peer", callerOf(caller)), ("goalNode", node.id),
       ("expectedTree", snap.primaryRepo.gitTreeSha1),
       ("observedTree", after.observed), ("leaseId", leaseId)], log = log)
  if snap.developSiblings.len > 0:
    # A certificate's content is the primary tree alone; it cannot vouch
    # for the siblings this goal ran with. Recorded in the execution record
    # (which withholds signing in both profiles) until M2 binds siblings
    # into certification.
    r.report("certificate-issuance", DevelopSiblingsWithheld,
      [("peer", callerOf(caller)), ("goalNode", node.id),
       ("leaseId", leaseId), ("count", $snap.developSiblings.len),
       ("reason", "the snapshot names " & $snap.developSiblings.len &
         " repro develop sibling(s); a certificate binds the primary " &
         "tree only (M2 binds siblings)")], log = log)
  var blocking: seq[LeaseReport] = @[]
  for rep in outcome.reports:
    if blocksCertificate(rep.kind, rep.detail,
        hardened = r.config.profile == tpHardened):
      blocking.add(rep)
  if req.issueCertificate and resp.status == gsCompleted:
    if not after.ok:
      inc r.certificatesWithheld
      resp.reason = "no certificate: the worktree's tree changed during the " &
        "goal (" & snap.primaryRepo.gitTreeSha1 & " -> " & after.observed & ")"
    elif snap.developSiblings.len > 0:
      inc r.certificatesWithheld
      resp.reason = "no certificate: the snapshot names " &
        $snap.developSiblings.len & " repro develop sibling(s), which a " &
        "certificate cannot bind yet (M2)"
    elif not node.isTest:
      resp.reason = "no certificate: node '" & node.id & "' is not a test node"
    elif blocking.len > 0:
      # The goal tripped a detector that withholds a certificate (G32):
      # whatever its exit code, it did not run the way an honest test does,
      # and a certificate would vouch that it did. HARDENED: any lease
      # report; TRUSTED: the plan's DET triggers only (a Seatbelt file
      # denial is recorded, not disqualifying).
      inc r.certificatesWithheld
      r.report("certificate-issuance", "certificate-withheld-detections",
        [("peer", callerOf(caller)), ("goalNode", node.id),
         ("leaseId", leaseId), ("count", $blocking.len),
         ("reason", "the lease reported " & blocking[0].kind)],
        log = log)
      resp.reason = "no certificate: the goal's lease reported " &
        $blocking.len & " disqualifying detection(s), first " &
        blocking[0].kind & " " & blocking[0].detail
    elif r.config.profile == tpTrusted:
      resp.reason = "certificate: trusted profile — the requester signs " &
        "after verifying this response and its execution record"
    elif r.issuer.isNil:
      resp.reason = "no certificate: this worker has no certificate signer"
    else:
      let issued = await r.issuer(CertificateRequest(
        content: contentIdOf(snap), project: desc.project,
        platform: r.config.platform, target: node.id,
        commands: @[node.argv], baseCommit: snap.primaryRepo.baseCommitSha,
        callerHost: callerOf(caller)))
      if issued.ok:
        inc r.certificatesIssued
        resp.certificate = issued.certificate
      else:
        inc r.certificatesWithheld
        resp.reason = "no certificate: " & issued.reason
  rec.status = $resp.status
  rec.detections = log.detections
  rec.endedAtMs = int64(epochTime() * 1000)
  resp.executionRecordDigest = r.writeRecord(rec)
  dropLease()
  return resp

proc workerHandlerFor*(r: WorkerReceiver): proc(caller: CallerIdentity;
    payload: seq[byte]; fetch: BlobFetcher): Future[seq[byte]]
    {.gcsafe, closure.} =
  ## The encoded-response form the peer-cache server's `workerHandler`
  ## wraps. `fetch` reaches back over the caller's own connection.
  let rr = r
  result = proc(caller: CallerIdentity; payload: seq[byte];
                fetch: BlobFetcher): Future[seq[byte]] {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      let fut = newFuture[seq[byte]]("worker.handle")
      let inner = rr.handleReachGoal(caller, payload, fetch)
      inner.addCallback(proc() =
        if inner.failed:
          fut.complete(encodeResponse(ReachGoalResponse(status: gsFailed,
            reason: "worker error: " & inner.error.msg)))
        else:
          fut.complete(encodeResponse(inner.read())))
      fut

proc runCanaryLease*(r: WorkerReceiver; counter: int): Future[tuple[ok: bool;
    reason: string]] {.async.} =
  ## DET-5 for the lease supervisor (threat model G22): a heartbeat from the
  ## daemon proves only that the daemon lives. This runs a real lease, with
  ## the production layers, whose action executes a copy of /bin/sh from
  ## its own temporary directory — outside the closure — and succeeds only
  ## when the supervisor reported that `exec-outside-closure` back. The
  ## worker heartbeats `lease-supervisor` on success; a supervisor whose
  ## detection path is dead goes SILENT at the sink.
  let leaseId = "canary-" & $getCurrentProcessId() & "-" & $counter
  let leaseDir = r.config.leaseRoot / leaseId
  var spec = LeaseSpec(leaseId: leaseId, leaseRoot: r.config.leaseRoot,
    leaseDir: leaseDir, metaDir: r.config.metaRoot / leaseId,
    cwd: leaseDir / "tmp",
    argv: @["/bin/sh", "-c",
      "cp /bin/sh \"$TMPDIR/repro-canary\" && \"$TMPDIR/repro-canary\" -c true; true"],
    env: @[("HOME", leaseDir / "home"), ("TMPDIR", leaseDir / "tmp"),
           ("PATH", r.config.pathEnv), ("LANG", "C")],
    readRoots: r.config.readRoots, closureRoots: r.config.closureRoots,
    hidePaths: r.config.hidePaths, layers: r.config.layers,
    timeoutMs: 60_000, slot: r.canarySlot())
  var outcome: LeaseOutcome
  try:
    createDir(leaseDir)
    outcome = await runLease(spec)
  except CatchableError as err:
    outcome = LeaseOutcome(error: err.msg)
  discard cleanupLease(spec)
  try: removeDir(spec.metaDir) except OSError: discard
  if not outcome.started:
    return (false, "the canary lease could not start: " & outcome.error)
  for rep in outcome.reports:
    if rep.kind == "exec-outside-closure" and "repro-canary" in rep.detail:
      return (true, "")
  return (false, "the canary's exec outside the closure was not reported")
