## Evidence records of the add-on (spec §10.4, §10.5; threat model §9).
##
## Every apply, refusal, rollback, quarantine, re-assert result, apt-hook
## finding and deploy-agent tick produces ONE record, written in two forms
## before anything else is reported:
##
## * the LOCAL record: one JSON document under ``EvidenceDirPath``
##   (``/var/lib/repro/system/addon/evidence``, root-only), the operator's
##   view on the host and what the earlier gates read;
## * the OUTBOX entry: the same record as the Evidence sink receives it (a
##   ``repro_peer_cache`` ``EvidenceRecord``, already redacted), under
##   ``EvidenceOutboxPath``, written only on a host bootstrapped with a sink
##   (``EvidenceConfPath`` exists). The shipping unit
##   (``repro-addon-evidence.service``, ``evidence_ship``) is started by a
##   path unit the moment an entry lands there and deletes each entry once
##   the sink acknowledged it. The off-host copy is the record (DET-6, EVID-2);
##   the outbox is the queue for the seconds the sink is unreachable.
##
## Each record names the DETECTOR that produced it (``AddonDetector``, one
## per threat-model §9 detector), a CATEGORY -- ``detection`` for what an
## operator must look at, ``audit`` for what happened as planned,
## ``heartbeat`` for "this detector is alive" -- and a TRIGGER. Records that
## describe the add-on's state carry the signed generation attestation of
## the generation the host runs (``attestation``), never presented as host
## attestation.
##
## A record that cannot be written raises: an event the add-on promised to
## record must not pass silently. The journal line is best effort.

import std/[algorithm, json, os, strutils, times]

import repro_peer_cache/evidence_record

import ./attestation
import ./fingerprint
import ./generation0
import ./host_exec
import ./ledger

export evidence_record.EvidenceCategory

const
  EvidenceDir* = EvidenceDirPath
    ## Root-only, beside the add-on's other state.
  EvidenceSchema* = "reprobuild.addon.evidence.v1"

type
  AddonDetector* = enum
    ## The detectors of threat model §9, by the name their records carry.
    edManifest = "addon-manifest"            ## DET-AO-1 manifest refusal
    edApplyRefusal = "addon-apply-refusal"   ## DET-AO-2 apply-side refusal
    edReassert = "addon-reassert"            ## DET-AO-4 re-assert result
    edStore = "addon-store"                  ## DET-AO-5 store integrity
    edAptHook = "addon-apt-hook"             ## DET-AO-6 apt hook finding
    edRollback = "addon-rollback"            ## DET-AO-7 rollback, quarantine
    edAgentTick = "addon-agent-tick"         ## DET-AO-8 heartbeat; DET-AO-10 input
    edFreshness = "addon-freshness"          ## DET-AO-10 host half (aoStale)
    edApply = "addon-apply"                  ## what a switch activated (audit)
    edBootstrap = "addon-bootstrap"          ## the first record (spec §6.2)
    edShip = "addon-evidence-ship"           ## the shipping unit's heartbeat

  EvidenceSite* = object
    ## Where records go. ``defaultSite`` is the host's; tests point every
    ## path into a scratch directory.
    stateDir*: string        ## the add-on state directory (attestation input)
    dir*: string             ## local JSON records
    outbox*: string          ## sink-form entries
    confPath*: string        ## outbox entries are written only when it exists
    attestationKey*: string
    host*: string
    journal*: bool

  EvidenceEvent* = object
    detector*: AddonDetector
    category*: EvidenceCategory
    trigger*: string
    kind*: string            ## the local file's kind (``<time>-<kind>.json``)
    fields*: seq[(string, string)]
    payload*: string         ## captured bytes (EVID-1), redacted by trigger
    attest*: bool            ## carry the current generation's attestation
    attestGeneration*: string ## attest this generation instead of ``current``
    localData*: JsonNode     ## the local JSON's own typed values, when a
                             ## caller kept them (``writeEvidenceRecord``)
    offHostOnly*: bool
      ## No local JSON copy: a heartbeat (one per tick), which would only
      ## fill the disk locally. Written nowhere on a host without a sink.

proc readHostName(): string =
  try: readFile("/proc/sys/kernel/hostname").strip()
  except IOError, OSError: "localhost"

proc defaultSite*(stateDir = "/var/lib/repro/system"): EvidenceSite =
  EvidenceSite(stateDir: stateDir, dir: EvidenceDirPath,
    outbox: EvidenceOutboxPath, confPath: EvidenceConfPath,
    attestationKey: AttestationKeyPath, host: readHostName(), journal: true)

proc shipsOffHost*(site: EvidenceSite): bool =
  ## Whether this host was bootstrapped with an Evidence sink.
  fileExists(site.confPath)

proc attestFields*(site: EvidenceSite; generation = ""):
    tuple[fields: seq[(string, string)]; error: string] =
  ## The signed attestation of ``generation`` (default: the current one) as
  ## record fields, or why there is none. A host without an attestation key
  ## (bootstrapped without a sink) attests nothing and says so.
  if not fileExists(site.attestationKey):
    return (@[], "no attestation key on this host")
  try:
    let a = currentAttestation(site.stateDir, site.host, generation)
    let s = signAttestation(a, site.attestationKey)
    result.fields = @[("attestation", s.statement),
                      ("attestationSignature", s.signature),
                      ("attestationKey", s.publicKey),
                      ("generation", a.generation)]
  except CatchableError as e:
    result.error = e.msg

proc outboxName(kind: string): string =
  ## Sortable by write time: nanoseconds since the epoch, zero padded, then
  ## the writer's pid (two writers in one nanosecond), then the kind.
  let t = getTime()
  let ns = t.toUnix() * 1_000_000_000 + int64(t.nanosecond)
  align($ns, 20, '0') & "-" & $getCurrentProcessId() & "-" & kind & ".evr"

proc toRecord*(e: EvidenceEvent; extra: seq[(string, string)]): EvidenceRecord =
  var fields = @[("kind", e.kind)] & e.fields & extra
  result = newEvidenceRecord(e.category, $e.detector, e.trigger, fields,
    cast[seq[byte]](e.payload), nowMs = int64(epochTime() * 1000))
  result.senderPid = int32(getCurrentProcessId())

proc recordEvidence*(e: EvidenceEvent; site = defaultSite()): string =
  ## Write one record (local JSON, then the outbox entry) and return the
  ## local record's path. Raises when either cannot be written.
  var e = e
  if e.offHostOnly and not shipsOffHost(site): return ""
  if e.kind.len == 0: e.kind = if e.trigger.len > 0: e.trigger else: $e.detector
  var extra: seq[(string, string)]
  var attestError = ""
  if e.attest:
    let a = attestFields(site, e.attestGeneration)
    extra = a.fields
    attestError = a.error
  extra.add(("host", site.host))
  let t = getTime()
  var doc = %*{"schema": EvidenceSchema, "kind": e.kind,
               "detector": $e.detector, "category": $e.category,
               "trigger": e.trigger, "timeUnix": t.toUnix(),
               "time": t.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")}
  for (k, v) in e.fields & extra: doc[k] = %v
  if not e.localData.isNil:
    for k, v in e.localData: doc[k] = v
  if attestError.len > 0: doc["attestationMissing"] = %attestError
  if e.payload.len > 0:
    doc["payloadSha256"] = %sha256Hex(e.payload)
    doc["payloadSize"] = %e.payload.len
  if not e.offHostOnly:
    createDir(site.dir)
    setFilePermissions(site.dir, {fpUserRead, fpUserWrite, fpUserExec})
    result = site.dir / (t.utc.format("yyyyMMdd'T'HHmmss") & "-" &
                         align($t.nanosecond, 9, '0') & "-" & e.kind & ".json")
    writeFileAtomic(result, pretty(doc) & "\n", 0o600)
  if shipsOffHost(site):
    createDir(site.outbox)
    setFilePermissions(site.outbox, {fpUserRead, fpUserWrite, fpUserExec})
    let rec = redact(toRecord(e, extra))
    writeFileAtomic(site.outbox / outboxName(e.kind),
                    cast[string](encodeEvidenceRecord(rec)), 0o600)
  if site.journal and not e.offHostOnly:
    # The journal line is best effort; the files above are the record.
    try:
      let exe = resolveHostTool([AptHookLoggerTool, "/bin/logger"])
      if exe.len > 0:
        var line = "repro-addon evidence " & $e.detector & " " & e.trigger
        for (k, v) in e.fields:
          if k != "attestation": line.add(" " & k & "=" & v.replace("\n", " "))
        discard runHostTool([exe, "-t", "repro-addon-evidence", "-p",
          (if e.category == ecDetection: "user.warning" else: "user.info"),
          line], timeoutSec = 5)
    except CatchableError:
      discard

proc detectorOfKind*(kind: string): AddonDetector =
  ## The detector of a record written through ``writeEvidenceRecord``.
  case kind
  of "stale-manifest": edFreshness
  of "failed-at-floor": edRollback
  of "compiled-profile-refused": edApplyRefusal
  else: edApplyRefusal

proc writeEvidenceRecord*(kind: string; data: JsonNode;
                          dir = EvidenceDir): string =
  ## A ``detection`` record of ``kind`` with ``data``'s keys as fields (the
  ## form the A8 records were written in). Raises when it cannot be written.
  var fields: seq[(string, string)]
  for k, v in data:
    fields.add((k, if v.kind == JString: v.getStr() else: $v))
  var site = defaultSite()
  site.dir = dir
  recordEvidence(EvidenceEvent(detector: detectorOfKind(kind),
    category: ecDetection, trigger: kind, kind: kind, fields: fields,
    attest: true, localData: data), site)

proc evidenceRecords*(kind: string; dir = EvidenceDir): seq[string] =
  ## The paths of every record of ``kind``, oldest first.
  if not dirExists(dir): return
  for f in walkFiles(dir / ("*-" & kind & ".json")): result.add(f)
  result.sort()

proc dpkgLastRun*(path: string): string =
  ## The time of dpkg's last ``startup`` line (``YYYY-MM-DD HH:MM:SS``,
  ## the host's local time), "" when it never ran or the log is unreadable.
  ## Read from the end, so a long log costs one bounded read.
  try:
    var f: File
    if not open(f, path, fmRead): return ""
    defer: f.close()
    let size = getFileSize(f)
    let start = max(0'i64, size - 256 * 1024)
    f.setFilePos(start)
    var tail = newString(int(size - start))
    if tail.len > 0: discard f.readBuffer(addr tail[0], tail.len)
    for line in tail.splitLines():
      let parts = line.splitWhitespace()
      if parts.len >= 3 and parts[2] == "startup":
        result = parts[0] & " " & parts[1]
  except CatchableError:
    discard

proc outboxEntries*(outbox = EvidenceOutboxPath): seq[string] =
  ## The outbox, oldest first.
  if not dirExists(outbox): return
  for kind, p in walkDir(outbox):
    if kind == pcFile and p.endsWith(".evr"): result.add(p)
  result.sort()
