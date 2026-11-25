## The capture log of the Nimble catalog's refusals (threat model § 9,
## EVID-1, G28).
##
## Every refusal and every origin event is kept as one record naming its
## class, the package, the digest (or commit, or revision) that was expected,
## what was observed instead, and where the bytes came from. The classes:
##
## | Class | Produced by | Expected | Observed | Source |
## | --- | --- | --- | --- | --- |
## | `digest-mismatch` | a client fetch (`nimble.fetch`), any transport | the lock's tree digest, or its `archive_sha256` | the digest of the bytes received | the transport and location |
## | `extraction-refusal` | a client fetch: an archive member refused (G11) | the lock's tree digest | the rule | the transport and location |
## | `egress-refusal` | the generator's fetch edges, a client's origin fallback (G5) | | the refusal kind | the URL |
## | `rewound-refresh` | `repro lock refresh` (NPC-AREQ15) | the pinned revision | the revision the ref names now | the catalog's remote |
## | `origin-event` | the generator: `tag-moved`, `history-rewritten`, `gone`, `tag-removed` | the event's before | the event's after | the package's origin |
## | `repoint-candidate` | the generator: a `repointed` event | the accepted origin | the new origin | the new origin |
## | `unreadable-symlink` | the generator's `source` edge: a link out of its tree (G4) | the link's target | the source object's digest | the origin and commit |
## | `worker-output-refused` | the publisher's admission of a worker's output (G36) | | the BLAKE3 of the refused bytes | the edge |
## | `probe-violation` | a probe that failed in its sandbox (G6, `probe`) | the source object's digest | the exit status | the origin and commit |
##
## The log is append-only: a file opened for appending (`O_APPEND`), one
## line per record written by one `write`, so records appended at once by
## several writers (the fetch waves of two `repro` processes, the
## generator) never interleave inside a line; never rewritten by this
## module. A URL's user information is never recorded (`withoutCredentials`). Each line is self-describing: the header
## word, then the record's fields percent-encoded as the generator's edge
## objects are (`edge_objects.enc`). A deployment ships the same records
## off-host to the evidence sink (`evidenceRecordOf`): the local file is
## the operator's view, the sink's copy is the record (EVID-2).

import std/[os, strutils]
when defined(posix):
  import std/posix

import repro_peer_cache/evidence_record

import repro_domain_types/nimble_index

import ./edge_objects
import ./egress
import ./generator
import ./probe

const
  CaptureHeader* = "reprobuild.nimble-capture.v1"
  CaptureDetector* = "nimble-catalog-capture"
    ## the detector name the records carry in the evidence sink
  MaxCaptureFieldBytes = 4096

type
  CaptureClass* = enum
    ccDigestMismatch = "digest-mismatch"
    ccExtractionRefusal = "extraction-refusal"
    ccEgressRefusal = "egress-refusal"
    ccRewoundRefresh = "rewound-refresh"
    ccOriginEvent = "origin-event"
    ccRepointCandidate = "repoint-candidate"
    ccUnreadableSymlink = "unreadable-symlink"
    ccWorkerOutputRefused = "worker-output-refused"
    ccProbeViolation = "probe-violation"

  CaptureRecord* = object
    class*: CaptureClass
    package*: string  ## the package, or the catalog for a rewound refresh
    expected*: string
    observed*: string
    source*: string   ## where the bytes came from
    detail*: string
    at*: uint64       ## seconds since the epoch, the producer's clock

  CaptureError* = object of CatchableError

proc bounded(s: string): string =
  if s.len <= MaxCaptureFieldBytes: s else: s[0 ..< MaxCaptureFieldBytes]

proc withoutCredentials*(url: string): string =
  ## ``url`` with the user information of its authority (`user:secret@`)
  ## replaced by `***@`: an origin refused for carrying credentials is
  ## recorded, its credentials are not.
  let sep = url.find("://")
  if sep < 0: return url
  let start = sep + 3
  var stop = url.len
  for i in start ..< url.len:
    if url[i] in {'/', '?', '#'}:
      stop = i
      break
  let at = url.rfind('@', start = start, last = stop - 1)
  if at < 0: return url
  url[0 ..< start] & "***" & url[at .. ^1]

proc captureLine*(r: CaptureRecord): string =
  var parts = @[CaptureHeader]
  for f in [$r.class, r.package, r.expected, r.observed, r.source, r.detail,
            $r.at]:
    parts.add enc(bounded(f))
  parts.join(" ") & "\n"

proc parseCaptureLine*(line: string): CaptureRecord =
  let fs = line.split(' ')
  if fs.len != 8 or fs[0] != CaptureHeader:
    raise newException(CaptureError, "not a capture record: " & line.escape())
  var cls: CaptureClass
  var known = false
  let c = dec(fs[1])
  for k in CaptureClass:
    if $k == c:
      cls = k
      known = true
  if not known:
    raise newException(CaptureError, "unknown capture class " & c.escape())
  try:
    result = CaptureRecord(class: cls, package: dec(fs[2]),
      expected: dec(fs[3]), observed: dec(fs[4]), source: dec(fs[5]),
      detail: dec(fs[6]), at: parseBiggestUInt(dec(fs[7])))
  except ValueError as e:
    raise newException(CaptureError, "malformed capture record: " & e.msg)

proc evidenceRecordOf*(r: CaptureRecord): EvidenceRecord =
  ## The record as the evidence sink receives it (detector
  ## ``CaptureDetector``, trigger the class), every field on the sink's
  ## allow-list.
  newEvidenceRecord(ecDetection, CaptureDetector, $r.class, [
    ("package", r.package), ("digest", r.expected),
    ("observedDigest", r.observed), ("bytesFrom", r.source),
    ("reason", r.detail)], nowMs = int64(r.at) * 1000)

proc appendCaptures*(path: string; records: openArray[CaptureRecord];
                     reporter: DetectionReporter = nil) =
  ## Append ``records`` to the log at ``path`` (created with its directory
  ## when absent), and hand each to ``reporter`` (the evidence appender of a
  ## deployment) when one is given. Raises when the log cannot be written:
  ## a refusal the catalog promised to keep must not pass silently.
  if records.len == 0: return
  if path.len > 0:
    createDir(parentDir(path))
    when defined(posix):
      let fd = posix.open(path.cstring,
        O_WRONLY or O_CREAT or O_APPEND or O_CLOEXEC, 0o600)
      if fd < 0:
        raise newException(CaptureError, "the capture log " & path &
          " cannot be opened for appending: " & osErrorMsg(osLastError()))
      try:
        for r in records:
          # One record, one write: O_APPEND places it whole at the end.
          let line = captureLine(r)
          let n = posix.write(fd, unsafeAddr line[0], line.len)
          if n != line.len:
            raise newException(CaptureError, "the capture log " & path &
              " took " & $n & " of a record's " & $line.len & " bytes: " &
              osErrorMsg(osLastError()))
      finally:
        discard posix.close(fd)
    else:
      var f: File
      if not open(f, path, fmAppend):
        raise newException(CaptureError, "the capture log " & path &
          " cannot be opened for appending")
      try:
        for r in records: f.write captureLine(r)
        f.flushFile()
      finally:
        f.close()
  if reporter != nil:
    for r in records: reporter(evidenceRecordOf(r))

proc readCaptures*(path: string): seq[CaptureRecord] =
  ## Every record of the log at ``path``, in order; none when it is absent.
  if not fileExists(path): return
  for line in readFile(path).splitLines():
    if line.len == 0: continue
    result.add parseCaptureLine(line)

# ---------------------------------------------------------------------------
# The generator's records
# ---------------------------------------------------------------------------

proc originsOf(g: GenerationResult): seq[(string, string)] =
  for (id, bytes) in g.built.objects:
    if id == g.built.rootId or id == g.built.root.nameMap.id or
        id == g.built.root.events.id:
      continue
    for o in decodeShard(bytes).observations:
      result.add (nameKey(o.name), o.origin.url)

proc originOf(origins: seq[(string, string)]; name: string): string =
  let k = nameKey(name)
  for (n, u) in origins:
    if n == k: return u
  ""

proc capturesOfGeneration*(g: GenerationResult; at: uint64):
    seq[CaptureRecord] =
  ## A generation's records: its egress refusals, the worker outputs the
  ## publisher refused, its links out of their trees, and its origin events
  ## (a `repointed` event as a repoint candidate).
  for r in g.refusals:
    result.add CaptureRecord(class: ccEgressRefusal, package: r.package,
      observed: $r.refusal.kind, source: withoutCredentials(r.refusal.url),
      detail: $r.family & ": " & r.refusal.detail &
        (if r.refusal.address.len > 0: " (" & r.refusal.address & ")"
         else: ""), at: at)
  for r in g.workerRefusals:
    result.add CaptureRecord(class: ccWorkerOutputRefused, package: r.package,
      observed: r.output, source: $r.family & " " & r.subject,
      detail: r.reason, at: at)
  for l in g.outsideLinks:
    result.add CaptureRecord(class: ccUnreadableSymlink, package: l.package,
      expected: l.target, observed: l.tree,
      source: withoutCredentials(l.origin) & "@" & l.commit,
      detail: "symbolic link " & l.path & " points outside the tree", at: at)
  let origins = originsOf(g)
  for e in g.events:
    if e.kind == oeRepointed:
      result.add CaptureRecord(class: ccRepointCandidate, package: e.package,
        expected: withoutCredentials(e.before),
        observed: withoutCredentials(e.after),
        source: withoutCredentials(e.after),
        detail: $e.kind, at: at)
    else:
      result.add CaptureRecord(class: ccOriginEvent, package: e.package,
        expected: e.before, observed: e.after,
        source: withoutCredentials(originOf(origins, e.package)),
        detail: $e.kind & (if e.version.len > 0: " " & e.version else: ""),
        at: at)

proc rewoundRefreshCapture*(catalog, remote, pinned, offered, detail: string;
                            at: uint64): CaptureRecord =
  ## A refresh refused as a rewind (NPC-AREQ15).
  CaptureRecord(class: ccRewoundRefresh, package: catalog, expected: pinned,
    observed: offered, source: withoutCredentials(remote), detail: detail,
    at: at)

proc probeCapture*(package, origin, commit, tree: string;
                   outcome: ProbeOutcome; at: uint64): CaptureRecord =
  ## A probe that failed: its exit status (or the time limit) and its own
  ## diagnostics, which name what the package's code tried.
  CaptureRecord(class: ccProbeViolation, package: package, expected: tree,
    observed: (if outcome.timedOut: "timed out"
               else: "exit " & $outcome.exitCode),
    source: withoutCredentials(origin) & "@" & commit,
    detail: outcome.diagnostics, at: at)

proc projectCaptureLog*(projectRoot: string): string =
  ## Where a project's client-side records are kept (its fetches' digest
  ## mismatches and refusals, its refreshes refused as rewinds).
  projectRoot / ".repro" / "nimble-captures.log"

proc isEgressRefusalKind*(rule: string): bool =
  for k in EgressRefusalKind:
    if $k == rule: return true
  false
