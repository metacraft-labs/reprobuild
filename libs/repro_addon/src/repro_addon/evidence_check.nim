## The off-host half of the add-on's detectors (threat model §9): what the
## Evidence zone runs over the sink's store to turn add-on records into
## alerts. It reads the store LOCALLY (EVID-3: the sink exposes no read over
## the network) and the producer's published manifests, and never trusts a
## host for anything but the records it signed.
##
##   repro-evidence-sink addon-check --dir STORE --hosts FILE
##       [--manifests DIR --deploy-signers FILE]
##       [--published-artefacts SHA256SUMS] [--silence-factor N] [--now-ms MS]
##
## It reports, per enrolled host:
##
## * every DETECTION record of an add-on detector, as an alert under its
##   threat-model identifier (DET-AO-1, -2, -3, -4, -5, -6, -7 and the host
##   half of -10);
## * DET-AO-8, silence -- distinct from "nothing detected" (DET-5). A
##   detector with a heartbeat of its own (the deploy agent's tick, the
##   shipping unit) is ``silent`` once ``silenceFactor`` intervals passed
##   without one, ``never-reported`` when it never sent one. The re-assert
##   unit runs once per boot, so each boot the shipping unit reports must
##   have a re-assert record; the apt hook runs after dpkg, so each dpkg run
##   the shipping unit reports must have a hook record. The detectors that
##   ride on the tick (manifest, apply refusal, store, rollback, freshness)
##   are alive exactly when the tick is;
## * DET-AO-9, attestation mismatch: an attestation that does not verify
##   against the host's enrolled attestation key; a generation whose ledger
##   or profile digest changed between two records; on an agent-managed
##   host, a generation that no published manifest produced, or whose
##   deployment, profile digest or closure digests differ from what the
##   producer published for its sequence; a bootstrap digest that is not a
##   published artefact; a record of a host with a key that should carry an
##   attestation and does not;
## * DET-AO-10, lag: a host whose applied sequence is behind the producer's
##   latest published sequence for its target while that manifest is older
##   than its own maximum age.
##
## What it cannot see is threat model deviation D4: root on a host holds
## the attestation key and the sink credential, and can ship records that
## copy the producer's sequence and attestation. Records shipped before
## that are trustworthy and cannot be erased (G34).

import std/[algorithm, options, os, sequtils, sets, strutils, tables]
from std/posix import nil

import repro_peer_cache/auth as peerAuth
import repro_peer_cache/evidence
import repro_peer_cache/types
import repro_deploy_agent/manifest

import ./attestation
import ./mutations

type
  EnrolledHost* = object
    hostId*: string            ## 64 hex: the sink-stamped sender id
    target*: string            ## the deploy agent's target; "" if none
    attestationKey*: string    ## hex; "" = the key of its bootstrap record
    generation0*: string
      ## bootstrap's generation, as enrolled; "" = its bootstrap record's.
      ## The key and generation 0 are ENROLMENT facts: the sink's retention
      ## deletes old records, the bootstrap record among them (A11 audit
      ## F6), so ``--update-hosts`` writes both into the hosts file the
      ## first time it sees them.
    retiredAt*: Option[uint64]
      ## The sink sequence the id was retired at, absent while it is live.
      ## An option: a hand-over can be a store's first entry, sequence 0
      ## (A11 review round 4; 0 used to mean "not retired").
      ## 0, or the sink sequence after which this host id and its key are
      ## retired (spec §13 decision 52): its keys were handed over to new
      ## ones (``--update-hosts`` sets it to the hand-over's sequence), or an
      ## operator retired them as compromised. A record of it after that
      ## point, a hand-over among them, is an alert.
    successor*: string
      ## The host id that took over from a retired one (``retired@N:ID``):
      ## it must be enrolled, and its silence is checked, so a retirement
      ## can never mute a host (A11 review finding 4).

  Alert* = object
    host*: string
    detector*: string          ## DET-AO-n, or G34 for a probe of the sink
    trigger*: string
    sinkSeq*: Option[uint64]
      ## The sink sequence of the record that raised the alert, or none (a
      ## silence, the check's own state). An option, not a sentinel: a
      ## store numbers its entries from 0, and an alert on its first entry
      ## names sequence 0 (A11; before, 0 meant "none", and that alert
      ## printed no sequence and could not be acknowledged).
    detail*: string

  DetectorStatus* = object
    host*: string
    detector*: string
    status*: string
      ## live-idle | live-detecting | silent | never-reported | stalled |
      ## contained (by an operator, decision 51) | retired | self-test
    detections*: int
    detail*: string

  CheckInputs* = object
    storeDir*: string
    hosts*: seq[EnrolledHost]
    manifests*: seq[DeployManifest]   ## verified, published
    publishedArtefacts*: seq[string]  ## SHA-256 hex of published binaries
    nowMs*: int64
    silenceFactor*: int
    sinkHostId*: string
      ## The sink's own host id (``<store>/sink-host``): only records it
      ## appended can acknowledge a detection.
    statePath*: string
      ## The check's own state (``--state``, default beside the hosts file):
      ## when it first saw each published sequence, so lag counts from the
      ## first publication even after the producer re-signed it and the
      ## manifest directory holds only the newest copy (A11 review finding
      ## 7). "" keeps nothing between runs.

  HandledAlert* = object
    alert*: Alert
    ackSeq*: uint64            ## the acknowledgement's sink sequence
    operator*: string
    reason*: string

  CheckReport* = object
    alerts*: seq[Alert]
    statuses*: seq[DetectorStatus]
    handled*: seq[HandledAlert]
      ## Alerts the sink operator acknowledged (``repro-evidence-sink ack``,
      ## A11 drill D4): reported, not counted.

  EvidenceCheckError* = object of CatchableError

const
  DetectorIds* = {"addon-manifest": "DET-AO-1",
                  "addon-apply-refusal": "DET-AO-2",
                  "addon-egress": "DET-AO-3",
                  "addon-reassert": "DET-AO-4",
                  "addon-store": "DET-AO-5",
                  "addon-apt-hook": "DET-AO-6",
                  "addon-rollback": "DET-AO-7",
                  "addon-freshness": "DET-AO-10",
                  "addon-evidence-ship": "DET-AO-8"}
  TickRiders* = ["addon-manifest", "addon-apply-refusal",
                 "addon-rollback", "addon-freshness"]
    ## Detectors whose records come out of the deploy agent's tick: alive
    ## exactly when the tick is.
  AttestedDetectors* = ["addon-agent-tick", "addon-apply", "addon-reassert",
                        "addon-containment"]
  ContainmentDetector* = "addon-containment"
  KeysDetector* = "addon-evidence-keys"
  ProbeWindowMs* = 60_000'i64
    ## How soon after the host's announced ``credential-probe`` record its
    ## refused verbs must arrive to be that self-test (D9).
  ProbeVerbs* = 4
    ## The forbidden operations ``evidence-credential-check`` tries.
  SelfTestVerbs* = [16, 17, 18, 19]
    ## Their verbs: list, read, overwrite, delete (``evidence.verbOf``).
  ProbeAnnouncementsPerDay* = 6
    ## Self-tests honoured per host per day.
  ContainmentClockSkewMs* = 600_000'i64
    ## How far a containment statement's own time may differ from its
    ## receipt at the sink.
  RecordGraceIntervals* = 2'i64
    ## How long, in shipping heartbeats, a boot may go without its re-assert
    ## record and a dpkg run without its hook record: both ship the moment
    ## they are written, so two heartbeats is ample -- and shorter than the
    ## heartbeat's own silence (``silenceFactor``, 3), so a host whose
    ## shipping is alive still shows the detector silent.
  ShipStallMs* = 60_000'i64
    ## A shipping heartbeat reporting a longer wait is a stall
    ## (``evidence_ship.ShipDelayAlertMs``).
    ## Detectors every record of which carries an attestation on a host
    ## that has an attestation key.

proc detectorId*(detector: string): string =
  for (d, id) in DetectorIds:
    if d == detector: return id
  ""

proc parseRetired(f: string; h: var EnrolledHost) =
  ## ``retired@<sink seq>[:<successor host id>]``.
  let v = f["retired@".len .. ^1]
  let colon = v.find(':')
  try:
    h.retiredAt = some(parseBiggestUInt(if colon >= 0: v[0 ..< colon] else: v).uint64)
    when mutated("seq-zero-sentinel"):
      if h.retiredAt.get == 0'u64: h.retiredAt = none(uint64)
  except ValueError:
    raise newException(EvidenceCheckError, "malformed " & f)
  if colon >= 0:
    h.successor = v[colon + 1 .. ^1].toLowerAscii()
    if h.successor.len != 64 or not h.successor.allCharsInSet(HexDigits):
      raise newException(EvidenceCheckError, "not a 64-hex successor: " & f)

proc parseHosts*(text: string): seq[EnrolledHost] =
  ## ``<host id> [<target>|-] [<attestation key>|-] [<generation 0>|-]
  ## [retired@<sink seq>[:<successor id>]]`` per line, ``#`` comments. The
  ## ``retired@`` field may stand in any position after the host id; the
  ## other fields keep their order (A11 review finding 16: an operator who
  ## appended it to a short line made it the attestation key).
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    let p = line.splitWhitespace()
    if p[0].len != 64 or not p[0].allCharsInSet(HexDigits):
      raise newException(EvidenceCheckError, "not a 64-hex host id: " & p[0])
    var h = EnrolledHost(hostId: p[0].toLowerAscii())
    var positional: seq[string]
    for f in p[1 .. ^1]:
      when mutated("hosts-retired-fifth-only"):
        positional.add(f)
      else:
        if f.startsWith("retired@"): parseRetired(f, h)
        else: positional.add(f)
    when mutated("hosts-retired-fifth-only"):
      if positional.len > 3 and positional[3].startsWith("retired@"):
        parseRetired(positional[3], h)
        positional.setLen(3)
    if positional.len > 0 and positional[0] != "-": h.target = positional[0]
    if positional.len > 1 and positional[1] != "-":
      h.attestationKey = positional[1].toLowerAscii()
    if positional.len > 2 and positional[2] != "-": h.generation0 = positional[2]
    result.add(h)

proc renderHosts*(hosts: openArray[EnrolledHost]): string =
  result = "# <host id> <target|-> <attestation key|-> <generation 0|-> " &
    "[retired@<sink seq>:<successor id>]\n"
  for h in hosts:
    result.add(h.hostId & " " & (if h.target.len > 0: h.target else: "-") &
      " " & (if h.attestationKey.len > 0: h.attestationKey else: "-") &
      " " & (if h.generation0.len > 0: h.generation0 else: "-") &
      (if h.retiredAt.isSome:
         " retired@" & $h.retiredAt.get &
           (if h.successor.len > 0: ":" & h.successor else: "")
       else: "") & "\n")

proc handoverRefusal*(v: KeyHandover; sender: string;
                      hosts: openArray[EnrolledHost]): string =
  ## Why a verified hand-over is not one, or "": a hand-over enrols a NEW
  ## id with a NEW key. To the sender's own id, to any id already in the
  ## hosts file, or to the same key, it would only retire the host and mute
  ## it (A11 review finding 4).
  when mutated("handover-to-enrolled-id"):
    return ""
  if v.newCredentialHost == sender:
    return "the hand-over names the sender's own id"
  for h in hosts:
    if h.hostId == v.newCredentialHost:
      return "the hand-over names an id already enrolled (" &
        v.newCredentialHost & ")"
  if v.newKey == v.oldKey:
    return "the hand-over names the old key as the new one"
  ""

proc enrolFromStore*(hosts: seq[EnrolledHost]; storeDir: string):
    tuple[hosts: seq[EnrolledHost]; changed: bool] =
  ## Each host's attestation key and generation 0 taken from its first
  ## bootstrap record where the hosts file has none yet; never replaces an
  ## enrolled value.
  result.hosts = hosts
  let entries = readEvidenceStore(storeDir)
  for h in result.hosts.mitems:
    if h.attestationKey.len > 0 and h.generation0.len > 0: continue
    for e in entries:
      if e.kind == ekRecord and $e.senderHostId == h.hostId and
          e.record.detector == "addon-bootstrap":
        if h.attestationKey.len == 0 and e.record.field("attestationKey").len > 0:
          h.attestationKey = e.record.field("attestationKey").toLowerAscii()
          result.changed = true
        if h.generation0.len == 0 and e.record.field("generation").len > 0:
          h.generation0 = e.record.field("generation")
          result.changed = true
        break
  # Follow each verified hand-over of a host's keys (decision 52): the new
  # credential's host id is enrolled with the new key and the same target
  # and generation 0, and the old id is retired at the hand-over. A host
  # already retired follows none after that point.
  # Each hand-over record is followed at most once, so the walk ends
  # whatever the records say (a chain of hand-overs grows the list by one
  # host per record, never more).
  var followed: seq[uint64]
  var i = 0
  while i < result.hosts.len:
    let h = result.hosts[i]
    inc i
    if h.attestationKey.len == 0: continue
    for e in entries:
      if e.kind != ekRecord or $e.senderHostId != h.hostId or
          e.record.detector != KeysDetector or
          e.record.trigger != "rekey-handover": continue
      if e.seq in followed: continue
      if h.retiredAt.isSome and e.seq > h.retiredAt.get: break
      let v = verifyHandover(e.record.field("handover"),
        e.record.field("handoverSignature"), h.attestationKey)
      if not v.ok: continue
      if h.retiredAt.isSome:
        break                           # followed already (or retired by hand)
      if handoverRefusal(v.h, h.hostId, result.hosts).len > 0: continue
      followed.add(e.seq)
      result.hosts[i - 1].retiredAt = some(e.seq)
      result.hosts[i - 1].successor = v.h.newCredentialHost
      result.hosts.add(EnrolledHost(hostId: v.h.newCredentialHost,
        target: h.target, attestationKey: v.h.newKey,
        generation0: h.generation0))
      result.changed = true
      break

proc loadPublishedManifests*(dir: string;
                             anchors: peerAuth.TrustAnchors):
                             seq[DeployManifest] =
  ## Every manifest file under ``dir`` that decodes and is signed by an
  ## anchored producer key. Anything else is ignored: the checker compares
  ## hosts with what the producer published, and an unsigned file is not
  ## that.
  if not dirExists(dir): return
  for kind, p in walkDir(dir):
    if kind != pcFile: continue
    try:
      let m = decodeManifest(cast[seq[byte]](readFile(p)))
      if verifyTrusted(m, anchors): result.add(m)
    except CatchableError:
      discard

proc loadPublishedArtefacts*(path: string): seq[string] =
  ## The digests of a ``SHA256SUMS`` file.
  for line in readFile(path).splitLines():
    let p = line.splitWhitespace()
    if p.len >= 1 and p[0].len == 64: result.add(p[0].toLowerAscii())

proc parseUnsigned(s: string): uint64 =
  try: parseBiggestUInt(s).uint64 except ValueError: 0'u64

proc parseSigned(s: string): int64 =
  try: parseBiggestInt(s) except ValueError: 0'i64

proc validAlertKind*(k: string): bool =
  ## ``<detector>/<trigger>``: ``DET-AO-<n>`` or ``G<n>``, then a trigger
  ## of lower-case words joined by ``-``.
  let p = k.split('/')
  if p.len != 2 or p[1].len == 0: return false
  let det = p[0]
  let detOk = (det.startsWith("DET-AO-") and det.len > 7 and
               det[7 .. ^1].allCharsInSet(Digits)) or
              (det.len > 1 and det[0] == 'G' and
               det[1 .. ^1].allCharsInSet(Digits))
  detOk and p[1].allCharsInSet({'a' .. 'z', '0' .. '9', '-'})

const CheckStateHeader* = "repro-check-state 1"
  ## The first line ``writeFirstSeen`` writes. A file without it is not the
  ## check's: empty, truncated or foreign (A11 review round 3), unless it
  ## is round 2's format (lines only, at least one), which is read once.

proc readFirstSeen*(path: string): Table[string, uint64] =
  ## ``<target> <sequence> <first issuedAt>`` per line. A file that does not
  ## exist is the first run (empty). A file that exists and cannot be read,
  ## or holds a line that is not one of these, raises
  ## ``EvidenceCheckError``: it is the only memory of when sequences were
  ## first published, and reading it as empty -- then rewriting it -- would
  ## destroy that memory (A11 review round 2).
  result = initTable[string, uint64]()
  if not fileExists(path) and not symlinkExists(path): return
  var text = ""
  try: text = readFile(path)
  except IOError, OSError:
    when mutated("lag-state-fails-open"):
      return
    else:
      raise newException(EvidenceCheckError, "the check's state file " &
        path & " exists and cannot be read: " & getCurrentExceptionMsg())
  var lines = text.splitLines()
  if lines.len > 0 and lines[0] == CheckStateHeader:
    lines = lines[1 .. ^1]
  elif not mutated("check-state-empty-is-valid"):
    # Round 2 wrote no header: such a file is read when it holds at least
    # one entry. An empty one -- zero bytes, or blank lines -- is a state
    # the check never wrote, and restarts every count: refused.
    if text.strip().len == 0:
      raise newException(EvidenceCheckError, "the check's state file " &
        path & " is empty: it is not a state the check wrote (lost or " &
        "truncated), and every lag count would restart")
  for l in lines:
    if l.strip().len == 0: continue
    let p = l.splitWhitespace()
    var ok = p.len == 3
    var v = 0'u64
    if ok:
      try:
        discard parseBiggestUInt(p[1])        # the sequence: a number
        v = parseBiggestUInt(p[2]).uint64
      except ValueError: ok = false
    if not ok:
      raise newException(EvidenceCheckError, "the check's state file " &
        path & " holds a line that is not <target> <sequence> <issuedAt>: " & l)
    result[p[0] & " " & p[1]] = v

proc fsyncPathOrRaise(path: string) =
  let fd = posix.open(path.cstring, posix.O_RDONLY or posix.O_CLOEXEC)
  if fd < 0: raiseOSError(osLastError(), "open " & path & " to sync it")
  try:
    if posix.fsync(fd) != 0: raiseOSError(osLastError(), "fsync " & path)
  finally:
    discard posix.close(fd)

proc writeFirstSeen*(path: string; t: Table[string, uint64]) =
  ## Durably: a temporary file in the same directory, fsync'd, renamed over
  ## the state, then the directory fsync'd. Raises ``EvidenceCheckError``
  ## when it cannot: the caller reports it, it is never swallowed.
  var lines: seq[string]
  for k, v in t: lines.add(k & " " & $v)
  lines.sort()
  lines.insert(CheckStateHeader, 0)
  let tmp = path & ".tmp"
  try:
    createDir(parentDir(path))
    writeFile(tmp, lines.join("\n") & "\n")
    fsyncPathOrRaise(tmp)
    moveFile(tmp, path)
    fsyncPathOrRaise(parentDir(path))
  except CatchableError as e:
    try: removeFile(tmp) except CatchableError: discard
    raise newException(EvidenceCheckError, "the check's state file " &
      path & " cannot be written: " & e.msg)

proc sequenceOf*(a: Alert): Option[uint64] =
  ## The alert's sequence, as the check prints and matches it.
  when mutated("alert-seq-zero-is-none"):
    # FALSIFYING BUILD: 0 stands for "no sequence" again.
    if a.sinkSeq.isSome and a.sinkSeq.get == 0'u64: return none(uint64)
  a.sinkSeq

proc seqText*(a: Alert): string =
  ## `` seq=N`` for an alert a record raised, "" for one none did.
  let sq = sequenceOf(a)
  if sq.isSome: " seq=" & $sq.get else: ""

proc successorChainLive*(hosts: seq[EnrolledHost]; h: EnrolledHost): bool =
  ## Whether the chain of successors from the retired ``h`` ends at an
  ## enrolled, live host (A retired to B, B to C, C live: true). Bounded by
  ## the number of hosts, so a loop (A to B, B to A) or an id that is not
  ## enrolled is false (A11 review round 2: a host re-keyed twice raised a
  ## false alert, since its first successor is retired too).
  var cur = h
  for step in 0 .. hosts.len:
    if cur.successor.len == 0: return false
    var found = false
    for x in hosts:
      if x.hostId == cur.successor:
        cur = x
        found = true
        break
    if not found: return false
    when mutated("successor-chain-one-step"):
      return cur.retiredAt.isNone
    if cur.retiredAt.isNone: return true
  false

proc runEvidenceCheck*(inp: CheckInputs): CheckReport =
  let factor = if inp.silenceFactor > 0: inp.silenceFactor else: 3
  let entries = readEvidenceStore(inp.storeDir)
  var byHost = initTable[string, seq[EvidenceEntry]]()
  for e in entries:
    byHost.mgetOrPut($e.senderHostId, @[]).add(e)
  # The producer's publications, by target and sequence.
  var published = initTable[string, Table[uint64, DeployManifest]]()
  var latest = initTable[string, DeployManifest]()
  var earliest = initTable[string, Table[uint64, DeployManifest]]()
  for m in inp.manifests:
    published.mgetOrPut(m.target, initTable[uint64, DeployManifest]())[m.sequence] = m
    if m.target notin latest or latest[m.target].sequence < m.sequence or
        (latest[m.target].sequence == m.sequence and
         latest[m.target].issuedAt < m.issuedAt):
      latest[m.target] = m
    # The FIRST copy of each sequence: when the producer first published it.
    # A re-signed copy (spec §9.2 expects a producer to re-sign) must not
    # restart the time a host has been behind (audit finding F1).
    let byTarget = addr earliest.mgetOrPut(m.target,
                                           initTable[uint64, DeployManifest]())
    if m.issuedAt > 0'u64 and (m.sequence notin byTarget[] or
        byTarget[][m.sequence].issuedAt > m.issuedAt):
      byTarget[][m.sequence] = m
  # The check's own memory of first publications (finding 7): the earliest
  # ``issuedAt`` it has ever seen for each (target, sequence), merged with
  # what the manifests directory holds now, and kept.
  # A state file the check cannot use is an alert of its own (it is not
  # host-specific, so it has no sequence and cannot be acknowledged: it
  # clears once the file is usable), and lag is then judged from the
  # manifest directory alone. An unreadable file is never rewritten.
  template stateAlert(trig, d: string) =
    result.alerts.add(Alert(host: "-", detector: "DET-AO-10", trigger: trig,
                            sinkSeq: none(uint64), detail: d))
  when not mutated("lag-ignores-check-state"):
    if inp.statePath.len > 0:
      var readable = true
      var seen: Table[string, uint64]
      try: seen = readFirstSeen(inp.statePath)
      except EvidenceCheckError as e:
        readable = false
        stateAlert("check-state-unreadable", e.msg & "; lag is judged from " &
          "the manifest directory alone, and the file is left as it is")
      if readable and not fileExists(inp.statePath):
        result.statuses.add(DetectorStatus(host: "-", detector: "check-state",
          status: "new", detail: inp.statePath & " did not exist: lag " &
            "counts from the first publications seen from now on"))
      for target, bySeq in earliest:
        for sq, m in bySeq:
          let k = target & " " & $sq
          if k notin seen or seen[k] > m.issuedAt: seen[k] = m.issuedAt
      for k, issued in seen:
        let sp = k.rfind(' ')
        let target = k[0 ..< sp]
        let sq = parseUnsigned(k[sp + 1 .. ^1])
        let byTarget = addr earliest.mgetOrPut(target,
                                               initTable[uint64, DeployManifest]())
        if sq in byTarget[]:
          if byTarget[][sq].issuedAt > issued:
            var m = byTarget[][sq]
            m.issuedAt = issued
            byTarget[][sq] = m
        elif target in latest and latest[target].sequence >= sq:
          # Its copy is gone from the directory; the sequence and when it was
          # first published are what lag needs, with the newest copy's age.
          var m = latest[target]
          m.sequence = sq
          m.issuedAt = issued
          byTarget[][sq] = m
      if readable:
        try: writeFirstSeen(inp.statePath, seen)
        except EvidenceCheckError as e:
          when not mutated("lag-state-fails-open"):
            stateAlert("check-state-unwritable", e.msg & "; the first " &
              "publications seen this run are not kept")
  let artefacts = toHashSet(inp.publishedArtefacts)
  # The sink operator's acknowledgements (D4): records the sink itself
  # appended, naming the sink sequence AND the alert (detector and trigger)
  # it handled -- one record can raise several alerts (finding 9).
  var acks = initTable[string, HandledAlert]()
  if inp.sinkHostId.len > 0:
    # The sink's own acknowledgements are never acknowledged.
    var sinkOwnAcks = initHashSet[string]()
    for e in entries:
      if e.kind == ekRecord and $e.senderHostId == inp.sinkHostId and
          e.record.detector == "sink-operator":
        sinkOwnAcks.incl($e.seq)
    for e in entries:
      if e.kind == ekRecord and $e.senderHostId == inp.sinkHostId and
          e.record.detector == "sink-operator" and
          e.record.trigger == "acknowledged":
        let n = parseUnsigned(e.record.field("acknowledges"))
        let finding = e.record.field("finding")
        let k = when mutated("ack-by-sequence-only"): $n
                else: $n & " " & finding
        # The same rules the sink applies when it appends (A11 review round
        # 3), and one the check alone can apply: an acknowledgement handles
        # only a record that came BEFORE it.
        let valid = when mutated("ack-rules-cli-only"): true
                    else: validAlertKind(finding) and n < e.seq and
                          $n notin sinkOwnAcks
        # Sequence 0 is a store's first entry, acknowledgeable like any.
        let named = e.record.field("acknowledges").len > 0 and
                    e.record.field("acknowledges").allCharsInSet(Digits)
        if named and finding.len > 0 and valid and k notin acks:
          acks[k] = HandledAlert(ackSeq: e.seq,
            operator: e.record.field("operator"),
            reason: e.record.field("reason"))

  for h in inp.hosts:
    let mine = byHost.getOrDefault(h.hostId, @[])
    template alert(det, trig: string; s: uint64; d: string) =
      result.alerts.add(Alert(host: h.hostId, detector: det, trigger: trig,
                              sinkSeq: some(s), detail: d))
    template alertUnsequenced(det, trig, d: string) =
      ## An alert no single record raised (a silence, a lag).
      result.alerts.add(Alert(host: h.hostId, detector: det, trigger: trig,
                              sinkSeq: none(uint64), detail: d))
    # The host's attestation key: enrolled, or the one its bootstrap record
    # named (the first record a host ships).
    # Generation 0 is bootstrap's own, applied from no manifest: the
    # bootstrap record names it.
    var key = when mutated("check-forgets-enrolled-key"): "" else: h.attestationKey
    var gen0 = when mutated("check-forgets-enrolled-key"): "" else: h.generation0
    var bootstrapDpkg = ""
      ## dpkg's last run before the hook existed: not the hook's to follow.
    var exemptBoots = initHashSet[string]()
      ## Boots in which the host was bootstrapped or enrolled: its re-assert
      ## ran before the evidence configuration existed, so its record of
      ## that boot never had an outbox to go to.
    var first = true
    for e in mine:
      if e.kind == ekRecord and e.record.detector == "addon-bootstrap":
        exemptBoots.incl(e.record.field("bootId"))
        if first:
          if key.len == 0: key = e.record.field("attestationKey").toLowerAscii()
          if gen0.len == 0: gen0 = e.record.field("generation")
          bootstrapDpkg = e.record.field("dpkgLastRun")
          first = false
    var detections = initCountTable[string]()
    var lastBeat = initTable[string, tuple[ms, interval: int64]]()
    var boots: seq[tuple[id: string; firstMs: int64]]
    var dpkgRuns: seq[tuple[run: string; firstMs: int64]]
    var reassertBoots = initHashSet[string]()
    var hookRuns: seq[string]
      ## The dpkg runs the hook's records name. One apt run can run dpkg
      ## several times and the hook once, after the last: a dpkg run is
      ## covered by a hook record naming it or a later one (the
      ## ``YYYY-MM-DD HH:MM:SS`` spelling compares as text).
    var genDigests = initTable[string, tuple[ledger, profile: string]]()
    var reported = initHashSet[string]()
    var applied = -1'i64
    var attestedSeen = false
    var shipStalled = false
    var lastShipDelay = (0'i64, 0'u64)
    var appliedMs = 0'i64
    var tickBeats: seq[tuple[seq: uint64; ms: int64]]
    var containment: seq[tuple[seq: uint64; ms: int64; contained: bool;
                               operator, reason: string]]
    var probe = none(tuple[seq: uint64; ms: int64; verbs: int; seen: uint8])
      ## The open self-test window, if one is open: the announcement, and
      ## the bit set of the documented verbs it has absorbed.
    var announcements: seq[int64]
    var lastContainSeq = none(uint64)
    var lastContainStatement = ""
    var selfTests = 0
    var afterRetirement = false
    for e in mine:
      if h.retiredAt.isSome and e.seq > h.retiredAt.get and not afterRetirement:
        # A retired host id still sending: its old credential is in use.
        afterRetirement = true
        alert("DET-AO-9", "record-after-retirement", e.seq, "the host id " &
          "was retired at sink sequence " & $h.retiredAt.get & " (its keys " &
          "were handed over or presumed compromised) and is still sending")
      if e.kind == ekRefusedVerb:
        # The host's own credential self-test announces itself with a
        # ``credential-probe`` record first (D9); the refused verbs that
        # follow it within ``ProbeWindowMs``, at most one per forbidden
        # operation, are that test's expected answer. Anything else is a
        # probe of the sink (G34).
        # Exactly the four documented operations (list, read, overwrite,
        # delete), once each, inside one announcement's window; anything
        # else, a repeat, or a fifth is a probe (finding 15).
        when not mutated("check-ignores-probe-announcement"):
          let verb = if e.body.len > 0: int(e.body[0]) else: -1
          let bit = verb - SelfTestVerbs[0]
          let documented = when mutated("self-test-any-verb"): true
                           else: bit >= 0 and bit < ProbeVerbs
          let fresh = when mutated("self-test-any-verb"): true
                      else: documented and probe.isSome and
                            (probe.get.seen and (1'u8 shl bit)) == 0
          if probe.isSome and e.receivedAtMs - probe.get.ms <= ProbeWindowMs and
              probe.get.verbs < ProbeVerbs and documented and fresh:
            var p = probe.get
            inc p.verbs
            if bit >= 0 and bit < 8: p.seen = p.seen or (1'u8 shl bit)
            probe = some(p)
            if p.verbs == ProbeVerbs:
              inc selfTests
              probe = none(tuple[seq: uint64; ms: int64; verbs: int;
                                 seen: uint8])     # the window closes
            continue
        alert("G34", "sink-probe", e.seq, "the host's credential sent a " &
          "verb outside the sink's vocabulary (" &
          (if e.body.len > 0: $e.body[0] else: "?") & ")")
        continue
      if e.kind != ekRecord: continue
      let r = e.record
      let det = r.detector
      if det == "addon-evidence-ship" and r.trigger == "credential-probe":
        # A bounded number of announcements a day; beyond it an
        # announcement opens no window (finding 15).
        announcements.keepItIf(e.receivedAtMs - it < 86_400_000'i64)
        when mutated("self-test-any-verb"):
          probe = some((seq: e.seq, ms: e.receivedAtMs, verbs: 0, seen: 0'u8))
        else:
          if announcements.len < ProbeAnnouncementsPerDay:
            probe = some((seq: e.seq, ms: e.receivedAtMs, verbs: 0, seen: 0'u8))
          else:
            alert("G34", "self-test-flood", e.seq, "more than " &
              $ProbeAnnouncementsPerDay & " credential self-tests " &
              "announced in a day; this one opens no window")
        announcements.add(e.receivedAtMs)
      if det == "addon-agent-tick" and r.category == ecHeartbeat:
        tickBeats.add((e.seq, e.receivedAtMs))
      if det == KeysDetector and r.trigger == "rekey-handover":
        if h.retiredAt.isSome and e.seq > h.retiredAt.get:
          alert("DET-AO-9", "handover-after-retirement", e.seq, "a key " &
            "hand-over signed by a key retired at sink sequence " &
            $h.retiredAt.get & " is refused")
        else:
          let v = verifyHandover(r.field("handover"),
            r.field("handoverSignature"), key)
          if not v.ok:
            alert("DET-AO-9", "handover-invalid", e.seq, v.why)
          else:
            var others: seq[EnrolledHost]
            for x in inp.hosts:
              if x.hostId != h.successor: others.add(x)
            let why = handoverRefusal(v.h, h.hostId, others)
            if why.len > 0:
              alert("DET-AO-9", "handover-invalid", e.seq, why)
      if not det.startsWith("addon-"): continue
      case r.category
      of ecDetection:
        detections.inc(det)
        alert(detectorId(det), r.trigger, e.seq, r.field("message"))
      of ecHeartbeat:
        lastBeat[det] = (e.receivedAtMs, parseSigned(r.field("intervalMs")))
      of ecAudit: discard
      if det == "addon-evidence-ship" and r.category == ecHeartbeat and
          not mutated("check-ignores-ship-delay"):
        # The latest heartbeat decides: a stall that has since recovered
        # (records leave at once again) no longer alerts.
        lastShipDelay = (parseSigned(r.field("shipDelayMs")), e.seq)
      if det == "addon-evidence-ship" and r.category == ecHeartbeat:
        let b = r.field("bootId")
        if b.len > 0 and b notin boots.mapIt(it.id):
          boots.add((b, e.receivedAtMs))
        let d = r.field("dpkgLastRun")
        if d.len > 0 and d > bootstrapDpkg and d notin dpkgRuns.mapIt(it.run):
          dpkgRuns.add((d, e.receivedAtMs))
      if det == "addon-reassert":
        reassertBoots.incl(r.field("bootId"))
      if det == "addon-apt-hook" and r.trigger == "hook-run":
        hookRuns.add(r.field("dpkgLastRun"))
      # DET-AO-9: the attestation.
      let stmt = r.field("attestation")
      if stmt.len == 0:
        # Before the host's first attested record (a tick while bootstrap's
        # generation 0 was still being committed) a record cannot attest;
        # after it, a record that should and does not is an alert.
        if key.len > 0 and det in AttestedDetectors and attestedSeen:
          let k = "unattested/" & det
          if k notin reported:
            reported.incl(k)
            alert("DET-AO-9", "unattested", e.seq, det &
              " record without an attestation from a host with an " &
              "attestation key")
        continue
      when mutated("check-skips-attestation"):
        # FALSIFYING BUILD: no attestation is compared.
        continue
      if key.len == 0:
        # No key enrolled and no bootstrap record left to take it from: one
        # alert for the host, not one per record (A11 audit F6).
        if "unenrolled" notin reported:
          reported.incl("unenrolled")
          alert("DET-AO-9", "attestation-key-unenrolled", e.seq, "no " &
            "attestation key is enrolled for the host, and its bootstrap " &
            "record is no longer in the store; enrol it in the hosts file")
        continue
      let why = verifyAttestation(SignedAttestation(statement: stmt,
        signature: r.field("attestationSignature"),
        publicKey: r.field("attestationKey")), key)
      if why.len > 0:
        alert("DET-AO-9", "attestation-invalid", e.seq, why)
        continue
      attestedSeen = true
      if det == ContainmentDetector:
        # Only a containment STATEMENT the host's enrolled key signed counts,
        # for this host id, newer than the last one accepted and made close
        # to its receipt (finding 3): a generation attestation copied from
        # another record, or a replayed one, is refused.
        when mutated("containment-unbound"):
          containment.add((e.seq, e.receivedAtMs,
            r.trigger == "operator-contained", r.field("operator"),
            r.field("reason")))
        else:
          let v = verifyContainment(r.field("containment"),
            r.field("containmentSignature"), key)
          let action = if r.trigger == "operator-contained": "contain"
                       elif r.trigger == "operator-released": "release" else: ""
          if not v.ok:
            alert("DET-AO-9", "containment-invalid", e.seq, v.why)
          elif v.c.credentialHost != h.hostId or v.c.action != action:
            alert("DET-AO-9", "containment-invalid", e.seq, "the statement " &
              "is for " & v.c.credentialHost & " / " & v.c.action)
          elif lastContainSeq.isSome and v.c.sequence == lastContainSeq.get and
              r.field("containment") == lastContainStatement and
              not mutated("containment-duplicate-is-replay"):
            # The same statement delivered again (shipping is at least
            # once: a run that crashed after the sink's acknowledgement and
            # before deleting the entry sends it again). It changes nothing.
            discard
          elif lastContainSeq.isSome and v.c.sequence <= lastContainSeq.get:
            alert("DET-AO-9", "containment-replayed", e.seq, "containment " &
              "sequence " & $v.c.sequence & " is not newer than " &
              $lastContainSeq.get)
          elif abs(e.receivedAtMs - v.c.atMs) > ContainmentClockSkewMs and
              not mutated("containment-skew-ignored"):
            alert("DET-AO-9", "containment-stale", e.seq, "made at " &
              $v.c.atMs & ", received at " & $e.receivedAtMs)
          else:
            lastContainSeq = some(v.c.sequence)
            lastContainStatement = r.field("containment")
            containment.add((e.seq, e.receivedAtMs, action == "contain",
              v.c.operator, v.c.reason))
      let a = parseStatement(stmt)
      if det == "addon-agent-tick":
        applied = int64(a.sequence)
        appliedMs = e.receivedAtMs
      if a.generation in genDigests:
        let was = genDigests[a.generation]
        if (was.ledger != a.ledgerDigest or was.profile != a.profileDigest) and
            ("changed/" & a.generation) notin reported:
          reported.incl("changed/" & a.generation)
          alert("DET-AO-9", "generation-changed", e.seq, "generation " &
            a.generation & " attested ledger " & was.ledger & " profile " &
            was.profile & " before, ledger " & a.ledgerDigest & " profile " &
            a.profileDigest & " now")
      else:
        genDigests[a.generation] = (a.ledgerDigest, a.profileDigest)
      if artefacts.len > 0 and a.bootstrapDigest.len > 0 and
          a.bootstrapDigest notin artefacts and "bootstrap" notin reported:
        reported.incl("bootstrap")
        alert("DET-AO-9", "bootstrap-unpublished", e.seq, "add-on binary " &
          a.bootstrapDigest & " is not a published artefact")
      if h.target.len > 0 and a.generation != "" and
          ("pub/" & a.generation) notin reported:
        if a.sequence == 0'u64:
          # Generation 0 (bootstrap's) carries no manifest; any other
          # generation of an agent-managed host must come from one -- an
          # operator's local apply is exactly "a locally modified
          # generation" (threat model §9's positive control).
          if a.generation != gen0:
            reported.incl("pub/" & a.generation)
            alert("DET-AO-9", "unpublished-generation", e.seq, "generation " &
              a.generation & " was not applied from a deploy manifest")
        else:
          let table = published.getOrDefault(h.target)
          if a.sequence notin table:
            if inp.manifests.len > 0:
              reported.incl("pub/" & a.generation)
              alert("DET-AO-9", "sequence-unpublished", e.seq, "generation " &
                a.generation & " claims sequence " & $a.sequence & " of " &
                h.target & ", which the producer did not publish")
          else:
            let m = table[a.sequence]
            var diffs: seq[string]
            if m.deploymentId != a.deploymentId:
              diffs.add("deploymentId " & a.deploymentId & " != " & m.deploymentId)
            if manifestProfileDigestOf(m) != a.manifestProfileDigest:
              diffs.add("profile " & a.manifestProfileDigest & " != " &
                manifestProfileDigestOf(m))
            if closureDigestsDigest(m.closureDigests) != a.closuresDigest:
              diffs.add("closures " & a.closuresDigest & " != " &
                closureDigestsDigest(m.closureDigests))
            if diffs.len > 0:
              reported.incl("pub/" & a.generation)
              alert("DET-AO-9", "attestation-mismatch", e.seq, "generation " &
                a.generation & " (sequence " & $a.sequence & "): " &
                diffs.join("; "))

    # Containment (decision 51): the latest signed containment record. It
    # holds only when the tick was live when it was recorded -- the last tick
    # heartbeat before it is within the silence window -- so a stop that came
    # first (an attacker who silenced the agent, then announced a
    # containment) still reads as silence. A tick after it means the
    # containment did not hold.
    var contained = false
    var containDetail = ""
    if containment.len > 0 and not mutated("check-ignores-containment"):
      let c = containment[^1]
      var beatBefore = none(tuple[seq: uint64; ms: int64])
      for b in tickBeats:
        if b.seq < c.seq and not (mutated("seq-zero-sentinel") and b.seq == 0'u64):
          beatBefore = some(b)
      let interval = if "addon-agent-tick" in lastBeat:
                       lastBeat["addon-agent-tick"].interval else: 0'i64
      if c.contained:
        if beatBefore.isSome and interval > 0 and
            c.ms - beatBefore.get.ms <= interval * int64(factor):
          contained = true
          containDetail = "contained by operator " & c.operator & " at sink " &
            "sequence " & $c.seq & ": " & c.reason
          if tickBeats.anyIt(it.seq > c.seq):
            alert("DET-AO-8", "ticked-while-contained", c.seq, "the deploy " &
              "agent ticked after the operator contained the host")
      elif "addon-agent-tick" in lastBeat and
          lastBeat["addon-agent-tick"].ms < c.ms:
        # Released: the silence clock starts at the release.
        lastBeat["addon-agent-tick"] = (c.ms, lastBeat["addon-agent-tick"].interval)
    if selfTests > 0:
      result.statuses.add(DetectorStatus(host: h.hostId,
        detector: "sink-credential", status: "self-test",
        detail: $selfTests & " announced credential self-test(s): every " &
          "forbidden operation refused"))
    if h.retiredAt.isSome:
      result.statuses.add(DetectorStatus(host: h.hostId, detector: "host",
        status: "retired", detail: "retired at sink sequence " & $h.retiredAt.get &
          (if h.successor.len > 0: ", succeeded by " & h.successor else: "")))
      # The successor carries the host's silence checks; a retirement
      # without an enrolled successor would mute it (finding 4).
      when not mutated("retired-without-successor-ok"):
        if not successorChainLive(inp.hosts, h):
          alert("DET-AO-8", "retired-without-successor", h.retiredAt.get,
            "retired at sink sequence " & $h.retiredAt.get & " with no enrolled " &
            "successor (" & (if h.successor.len > 0: h.successor else: "none") &
            "): nothing reports for it")
      continue
    # DET-AO-8: heartbeats, then the per-boot and per-dpkg-run rules.
    # The store verification heartbeats on its own timer (decision 46).
    var beating = @["addon-evidence-ship", "addon-store"]
    if h.target.len > 0:
      # An agent host with a sink carries the egress observer, which
      # heartbeats on its own timer (DET-AO-3's DET-5).
      beating.add("addon-agent-tick")
      beating.add("addon-egress")
    var alive = initTable[string, bool]()
    for det in beating:
      var st = DetectorStatus(host: h.hostId, detector: det,
                              detections: detections.getOrDefault(det))
      if contained and det == "addon-agent-tick":
        st.status = "contained"
        st.detail = containDetail
        alive[det] = false
      elif det notin lastBeat or lastBeat[det].interval <= 0:
        st.status = "never-reported"
        alertUnsequenced("DET-AO-8", "never-reported", det & " never sent a heartbeat")
        alive[det] = false
      else:
        let (ms, interval) = lastBeat[det]
        if inp.nowMs - ms > interval * int64(factor) and
            not mutated("check-silence-as-idle"):
          st.status = "silent"
          st.detail = "last heartbeat " & $((inp.nowMs - ms) div 1000) &
            " s ago, interval " & $(interval div 1000) & " s"
          alertUnsequenced("DET-AO-8", "silent", det & ": " & st.detail)
          alive[det] = false
        else:
          st.status = if st.detections > 0: "live-detecting" else: "live-idle"
          alive[det] = true
      result.statuses.add(st)
    let shipInterval = if "addon-evidence-ship" in lastBeat:
                         lastBeat["addon-evidence-ship"].interval
                       else: 0'i64
    if lastShipDelay[0] > ShipStallMs:
      shipStalled = true
      alert("DET-AO-8", "shipping-stalled", lastShipDelay[1], "a record " &
        "waited " & $(lastShipDelay[0] div 1000) & " s to leave the host " &
        "(the shipping unit is not started as records land)")
    var silentDetail = initTable[string, string]()
    for (boot, firstMs) in boots:
      if boot notin reassertBoots and boot notin exemptBoots and
          shipInterval > 0 and
          inp.nowMs - firstMs > shipInterval * RecordGraceIntervals:
        alertUnsequenced("DET-AO-8", "reassert-silent", "boot " & boot &
          " has no re-assert record")
        silentDetail["addon-reassert"] = "boot " & boot & " has no record"
    for (run, firstMs) in dpkgRuns:
      if not hookRuns.anyIt(it >= run) and shipInterval > 0 and
          inp.nowMs - firstMs > shipInterval * RecordGraceIntervals:
        alertUnsequenced("DET-AO-8", "apt-hook-silent", "dpkg ran at " & run &
          " and no apt hook record names that run")
        silentDetail["addon-apt-hook"] = "dpkg run " & run & " has no record"
    if shipStalled:
      for st in result.statuses.mitems:
        if st.host == h.hostId and st.detector == "addon-evidence-ship":
          st.status = "stalled"
          st.detail = "records wait for the timer"
    for det in ["addon-reassert", "addon-apt-hook"]:
      # A status never contradicts the check's own alert (A11 audit F4).
      let own = det in silentDetail and not mutated("check-status-ignores-silence")
      result.statuses.add(DetectorStatus(host: h.hostId, detector: det,
        detections: detections.getOrDefault(det),
        status: (if not alive.getOrDefault("addon-evidence-ship") or own: "silent"
                 elif detections.getOrDefault(det) > 0: "live-detecting"
                 else: "live-idle"),
        detail: (if own: silentDetail[det]
                 else: "checked per boot / per dpkg run")))
    if h.target.len > 0:
      for det in TickRiders:
        result.statuses.add(DetectorStatus(host: h.hostId, detector: det,
          detections: detections.getOrDefault(det),
          status: (if contained: "contained"
                   elif not alive.getOrDefault("addon-agent-tick"): "silent"
                   elif detections.getOrDefault(det) > 0: "live-detecting"
                   else: "live-idle"),
          detail: "rides on addon-agent-tick"))
      # DET-AO-10: lag. The host has been behind since the producer FIRST
      # published the oldest sequence above the one it applied; it lags once
      # that is longer ago than that copy's maximum age, however often the
      # producer re-signed since.
      if h.target in latest and not mutated("lag-detector-disabled"):
        let l = latest[h.target]
        var since: DeployManifest
        var found = false
        when mutated("lag-from-newest-copy"):
          # FALSIFYING BUILD: the age of the newest copy of the latest
          # sequence, which every re-signature resets.
          if l.issuedAt > 0'u64 and applied < int64(l.sequence):
            since = l
            found = true
        else:
          # Any sequence above the host's that it has been behind for longer
          # than that sequence's own maximum age (the one most overdue).
          var worst = 0'i64
          for sq, m in earliest.getOrDefault(h.target):
            if int64(sq) <= applied: continue
            let over = inp.nowMs - int64(m.issuedAt) * 1000 -
                       int64(m.maxAgeSeconds) * 1000
            if over > 0 and (not found or over > worst):
              since = m
              worst = over
              found = true
        if found:
          let ageMs = inp.nowMs - int64(since.issuedAt) * 1000
          if ageMs > int64(since.maxAgeSeconds) * 1000:
            alertUnsequenced("DET-AO-10", "lag", "applied sequence " &
              (if applied < 0: "none" else: $applied) & " is behind the " &
              "producer's " & $l.sequence & " for " & h.target &
              "; sequence " & $since.sequence & " was first published " &
              $(ageMs div 1000) & " s ago (maximum age " &
              $since.maxAgeSeconds & " s)")
  # Acknowledged detections are handled, not alerts (D4).
  when not mutated("check-ignores-acks"):
    var open: seq[Alert]
    for a in result.alerts:
      let sq = sequenceOf(a)
      let k = when mutated("ack-by-sequence-only"): $sq.get(0)
              else: $sq.get(0) & " " & a.detector & "/" & a.trigger
      if sq.isSome and k in acks:
        var hnd = acks[k]
        hnd.alert = a
        result.handled.add(hnd)
      else: open.add(a)
    result.alerts = open
  result.alerts.sort(proc(a, b: Alert): int =
    cmp(a.host & a.detector & seqText(a), b.host & b.detector & seqText(b)))

proc render*(r: CheckReport): string =
  for s in r.statuses:
    result.add("status " & s.host & " " & s.detector & " " & s.status &
      " detections=" & $s.detections &
      (if s.detail.len > 0: " (" & s.detail & ")" else: "") & "\n")
  for x in r.handled:
    result.add("HANDLED " & x.alert.host & " " & x.alert.detector & " " &
      x.alert.trigger & seqText(x.alert) & " acknowledged by " &
      x.operator & " at seq=" & $x.ackSeq & ": " &
      x.reason.replace("\n", " ") & "\n")
  for a in r.alerts:
    result.add("ALERT " & a.host & " " & a.detector & " " & a.trigger &
      seqText(a) &
      (if a.detail.len > 0: " " & a.detail.replace("\n", " ") else: "") & "\n")
