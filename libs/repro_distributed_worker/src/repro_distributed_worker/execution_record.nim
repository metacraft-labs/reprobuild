## The per-goal EXECUTION RECORD — Distributed-Execution M7, trust profiles
## (operator decision 2026-10-20).
##
## Every goal a worker receives produces one record, written into the
## worker's content-addressed store and named by its BLAKE3 digest in the
## `ReachGoalResponse` (`executionRecordDigest`). It says what ran and how:
## the argv and environment NAMES (never values: they can carry secrets),
## the inputs (descriptor, snapshot, the verified tree before and after),
## the outputs by digest, the isolation level that confined the action, the
## exit status, and every detection the goal produced — refusals, lease
## reports (egress, exec outside the closure, file-system and syscall
## denials), a tree that changed before certification, an impure action
## whose output did not match its declared digest.
##
## In the TRUSTED profile this record and the worker's local detection log
## ARE where the DET triggers go: the record is stored in the worker's
## content-addressed store (so its bytes are bound to the digest the
## response names) and the requester fetches it from there to decide
## whether to sign a certificate; it leaves the worker only when someone
## fetches it. In the HARDENED profile the same record is written AND every
## detection also goes to the append-only evidence sink.
##
## WHICH DETECTIONS WITHHOLD A CERTIFICATE (`blocksCertificate`). HARDENED:
## every detection. TRUSTED: exactly the plan's DET triggers — a blob whose
## BLAKE3 does not match, a selector that fails validation, a path outside
## the snapshot, an execve outside the closure, a certificate tree mismatch,
## a markSuspect — and a folded flood of one of them. Every other sandbox
## report (a Seatbelt or Landlock file denial, a denied egress or syscall,
## an unfloored unix-socket connect) is still recorded here and in the local
## log, but is informational: otherwise a macOS worker, whose compilers probe
## the build user's home, could never pass a signed goal.
##
## The encoding is JSON with a fixed key order, so equal records are equal
## bytes.
##
## EVID-6 (the trusted profile has no sink, so this record and the local
## detection log ARE its evidence stores). SCOPE: one record per goal — the
## fields above; environment VALUES are never recorded (names only), and no
## output, stdout or stderr byte (outputs by digest). READERS: the worker's
## OS user on disk (the record is stored owner-only); over the network, a
## pinned peer holding a content-plane role that names the record's digest —
## in practice the requester, to whom the response gave it. RETENTION WITH
## AUTOMATED DELETION: the worker lists every record it stores in its record
## index and `sweepExecutionRecords` deletes each one from the CAS once it
## is older than `ExecutionRecordRetentionSeconds` (thirty days, the
## evidence sink's period); the worker role runs the sweep on a timer. The
## generic CAS garbage collector (`casGc`) is not used: it deletes
## everything outside a retain set, and the worker's CAS is the daemon's
## shared action cache. REDACTION, AS AN ALLOW-LIST: the record's schema is
## the allow-list — `encodeExecutionRecord` writes exactly the keys below,
## and a detection carries only its detector, trigger, one detail and the
## operation.

import std/[json, os, sets, strutils, times]
when defined(posix):
  import std/posix

import blake3

const
  ExecutionRecordSchema* = "repro.execution-record.v1"
  MaxExecutionRecordBytes* = 4 * 1024 * 1024
  ExecutionRecordRetentionSeconds* = 30'i64 * 86_400
    ## How long an execution record stays in the worker's CAS (EVID-6).

type
  RecordedOutput* = object
    path*: string
    digest*: string
      ## Lowercase hex BLAKE3.
    size*: uint64

  RecordedInput* = object
    node*: string
    path*: string
    digest*: string
      ## Lowercase hex BLAKE3.

  RecordedDetection* = object
    detector*: string
    trigger*: string
    detail*: string
    operation*: string

  ExecutionRecord* = object
    schema*: string
    profile*: string
    isolation*: string
    workerHost*: string
    caller*: string
    requestId*: string
    goalNode*: string
    status*: string
      ## `refused`, `failed`, `completed`.
    trigger*: string
      ## The refusal trigger, when refused.
    argv*: seq[string]
    cwd*: string
    envNames*: seq[string]
    egress*: seq[string]
    impure*: bool
    descriptorDigest*: string
    snapshotDigest*: string
    snapshotContentId*: string
    treeBefore*: string
    treeAfter*: string
    outputs*: seq[RecordedOutput]
    inputArtifacts*: seq[RecordedInput]
      ## The materialized outputs of declared input nodes the goal ran with.
    exitCode*: int
    timedOut*: bool
    startedAtMs*: int64
    endedAtMs*: int64
    detections*: seq[RecordedDetection]

  ExecutionRecordError* = object of CatchableError

const
  CertificateBlockingTriggers* = ["blob-digest-mismatch",
    "selector-validation-failed", "goal-path-outside-snapshot",
    "exec-outside-closure", "certificate-tree-mismatch", "mark-suspect"]
    ## The plan's DET triggers (Distributed-Execution M7): in the TRUSTED
    ## profile only these withhold a certificate.

proc blocksCertificate*(trigger, detail: string; hardened: bool): bool =
  ## Whether a detection withholds a certificate (see the module doc).
  ## `detail` matters for a folded flood (`reports-suppressed`), whose
  ## detail names the kind it folded.
  if hardened:
    return true
  if trigger in CertificateBlockingTriggers:
    return true
  trigger == "reports-suppressed" and detail in CertificateBlockingTriggers

proc recordHex*(d: openArray[byte]): string =
  const H = "0123456789abcdef"
  result = newStringOfCap(d.len * 2)
  for b in d:
    result.add(H[int(b) shr 4])
    result.add(H[int(b) and 0xf])

proc encodeExecutionRecord*(r: ExecutionRecord): seq[byte] =
  var outs = newJArray()
  for o in r.outputs:
    outs.add(%*{"path": o.path, "blake3": o.digest, "size": o.size})
  var ins = newJArray()
  for i in r.inputArtifacts:
    ins.add(%*{"node": i.node, "path": i.path, "blake3": i.digest})
  var dets = newJArray()
  for d in r.detections:
    dets.add(%*{"detector": d.detector, "trigger": d.trigger,
                "detail": d.detail, "operation": d.operation})
  let j = %*{
    "schema": ExecutionRecordSchema,
    "profile": r.profile,
    "isolation": r.isolation,
    "worker": r.workerHost,
    "caller": r.caller,
    "requestId": r.requestId,
    "goalNode": r.goalNode,
    "status": r.status,
    "trigger": r.trigger,
    "argv": r.argv,
    "cwd": r.cwd,
    "envNames": r.envNames,
    "egress": r.egress,
    "impure": r.impure,
    "descriptor": r.descriptorDigest,
    "snapshot": r.snapshotDigest,
    "snapshotContentId": r.snapshotContentId,
    "treeBefore": r.treeBefore,
    "treeAfter": r.treeAfter,
    "outputs": outs,
    "inputArtifacts": ins,
    "exitCode": r.exitCode,
    "timedOut": r.timedOut,
    "startedAtMs": r.startedAtMs,
    "endedAtMs": r.endedAtMs,
    "detections": dets}
  let text = $j
  result = newSeq[byte](text.len)
  if text.len > 0: copyMem(addr result[0], unsafeAddr text[0], text.len)

proc decodeExecutionRecord*(bytes: openArray[byte]): ExecutionRecord =
  ## Strict: the bytes may come from another host.
  if bytes.len == 0 or bytes.len > MaxExecutionRecordBytes:
    raise newException(ExecutionRecordError, "execution record size out of range")
  var text = newString(bytes.len)
  copyMem(addr text[0], unsafeAddr bytes[0], bytes.len)
  var j: JsonNode
  try:
    j = parseJson(text)
  except CatchableError as err:
    raise newException(ExecutionRecordError, "malformed execution record: " & err.msg)
  if j.kind != JObject or j{"schema"}.getStr != ExecutionRecordSchema:
    raise newException(ExecutionRecordError, "not an execution record")
  result.schema = ExecutionRecordSchema
  result.profile = j{"profile"}.getStr
  result.isolation = j{"isolation"}.getStr
  result.workerHost = j{"worker"}.getStr
  result.caller = j{"caller"}.getStr
  result.requestId = j{"requestId"}.getStr
  result.goalNode = j{"goalNode"}.getStr
  result.status = j{"status"}.getStr
  result.trigger = j{"trigger"}.getStr
  for a in j{"argv"}.getElems: result.argv.add(a.getStr)
  result.cwd = j{"cwd"}.getStr
  for a in j{"envNames"}.getElems: result.envNames.add(a.getStr)
  for a in j{"egress"}.getElems: result.egress.add(a.getStr)
  result.impure = j{"impure"}.getBool
  result.descriptorDigest = j{"descriptor"}.getStr
  result.snapshotDigest = j{"snapshot"}.getStr
  result.snapshotContentId = j{"snapshotContentId"}.getStr
  result.treeBefore = j{"treeBefore"}.getStr
  result.treeAfter = j{"treeAfter"}.getStr
  for o in j{"outputs"}.getElems:
    result.outputs.add(RecordedOutput(path: o{"path"}.getStr,
      digest: o{"blake3"}.getStr, size: uint64(o{"size"}.getBiggestInt)))
  for i in j{"inputArtifacts"}.getElems:
    result.inputArtifacts.add(RecordedInput(node: i{"node"}.getStr,
      path: i{"path"}.getStr, digest: i{"blake3"}.getStr))
  result.exitCode = j{"exitCode"}.getInt
  result.timedOut = j{"timedOut"}.getBool
  result.startedAtMs = j{"startedAtMs"}.getBiggestInt
  result.endedAtMs = j{"endedAtMs"}.getBiggestInt
  for d in j{"detections"}.getElems:
    result.detections.add(RecordedDetection(detector: d{"detector"}.getStr,
      trigger: d{"trigger"}.getStr, detail: d{"detail"}.getStr,
      operation: d{"operation"}.getStr))

proc executionRecordDigestOf*(bytes: openArray[byte]): array[32, byte] =
  blake3.digest(@bytes)

proc describeDetections*(r: ExecutionRecord): string =
  var parts: seq[string] = @[]
  for d in r.detections:
    parts.add(d.trigger & (if d.detail.len > 0: " " & d.detail else: ""))
  parts.join("; ")

when defined(posix):
  proc flock(fd: cint; op: cint): cint {.importc, header: "<sys/file.h>".}
  const LockEx = cint(2)

template withRecordIndexLock(indexPath: string; body: untyped) =
  ## Serializes index appends against a sweep's rewrite (`flock(2)` on a
  ## sibling `.lock` file, held only for the append or the final
  ## re-read + rename, never across a CAS deletion). Unlocked when the lock
  ## file cannot be opened (the rewrite still merges, below).
  when defined(posix):
    let lockFd = posix.open((indexPath & ".lock").cstring,
      O_RDWR or O_CREAT or O_CLOEXEC, Mode(0o600))
    if lockFd >= 0:
      discard flock(lockFd, LockEx)
    try:
      body
    finally:
      if lockFd >= 0:
        discard posix.close(lockFd)   # closing the descriptor unlocks
  else:
    body

proc appendRecordIndex*(indexPath: string; digest: array[32, byte];
                        nowS = 0'i64) =
  ## Lists a stored execution record (`<unix seconds> <hex digest>`) in the
  ## owner-only index `sweepExecutionRecords` reads. Never raises.
  let now = if nowS != 0: nowS else: getTime().toUnix
  let line = $now & " " & recordHex(digest) & "\n"
  try:
    withRecordIndexLock(indexPath):
      when defined(posix):
        let fd = posix.open(indexPath.cstring,
          O_WRONLY or O_APPEND or O_CREAT or O_CLOEXEC, Mode(0o600))
        if fd >= 0:
          discard fchmod(fd, Mode(0o600))
          discard posix.write(fd, unsafeAddr line[0], line.len)
          discard posix.close(fd)
      else:
        let f = open(indexPath, fmAppend)
        try: f.write(line)
        finally: f.close()
  except CatchableError:
    discard

proc parseRecordHex(hex: string; digest: var array[32, byte]): bool =
  if hex.len != 64:
    return false
  for i in 0 ..< 32:
    try:
      digest[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))
    except ValueError:
      return false
  true

proc sweepExecutionRecords*(indexPath: string;
    deleteRecord: proc(digest: array[32, byte]): bool {.gcsafe, closure.};
    retentionSeconds = ExecutionRecordRetentionSeconds;
    nowS = 0'i64): int =
  ## Deletes every execution record listed in `indexPath` that is older
  ## than `retentionSeconds` (`deleteRecord` removes it from the CAS and
  ## says whether it is gone) and rewrites the index without them; a
  ## record whose deletion failed stays listed for the next sweep. Returns
  ## the records deleted. Never raises.
  ##
  ## The deletions run against a snapshot, unlocked; the rewrite then
  ## re-reads the index under the index lock (the one `appendRecordIndex`
  ## takes) and drops only the lines this sweep deleted — so a record
  ## listed while the sweep ran (or by a concurrent sweep) is never lost.
  let now = if nowS != 0: nowS else: getTime().toUnix
  if not fileExists(indexPath):
    return 0
  var deleted = initHashSet[string]()
  try:
    for line in readFile(indexPath).splitLines:
      let parts = line.splitWhitespace()
      if parts.len != 2:
        continue
      var at: int64
      try: at = parseBiggestInt(parts[0]) except ValueError: continue
      var digest: array[32, byte]
      if not parseRecordHex(parts[1], digest):
        continue
      if now - at >= retentionSeconds:
        var gone = false
        try: gone = deleteRecord(digest) except CatchableError: gone = false
        if gone:
          inc result
          deleted.incl(line)
    withRecordIndexLock(indexPath):
      var kept: seq[string] = @[]
      for line in readFile(indexPath).splitLines:
        if line.splitWhitespace().len == 2 and line notin deleted:
          kept.add(line)
      let tmp = indexPath & ".tmp"
      writeFile(tmp, (if kept.len > 0: kept.join("\n") & "\n" else: ""))
      when defined(posix):
        setFilePermissions(tmp, {fpUserRead, fpUserWrite})
      moveFile(tmp, indexPath)
  except CatchableError:
    discard
