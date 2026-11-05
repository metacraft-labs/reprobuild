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

import std/[algorithm, os, sequtils, sets, strutils, tables]

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

  Alert* = object
    host*: string
    detector*: string          ## DET-AO-n, or G34 for a probe of the sink
    trigger*: string
    sinkSeq*: uint64
    detail*: string

  DetectorStatus* = object
    host*: string
    detector*: string
    status*: string            ## live-idle | live-detecting | silent | never-reported
    detections*: int
    detail*: string

  CheckInputs* = object
    storeDir*: string
    hosts*: seq[EnrolledHost]
    manifests*: seq[DeployManifest]   ## verified, published
    publishedArtefacts*: seq[string]  ## SHA-256 hex of published binaries
    nowMs*: int64
    silenceFactor*: int

  CheckReport* = object
    alerts*: seq[Alert]
    statuses*: seq[DetectorStatus]

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
  TickRiders* = ["addon-manifest", "addon-apply-refusal", "addon-store",
                 "addon-rollback", "addon-freshness"]
    ## Detectors whose records come out of the deploy agent's tick: alive
    ## exactly when the tick is.
  AttestedDetectors* = ["addon-agent-tick", "addon-apply", "addon-reassert"]
    ## Detectors every record of which carries an attestation on a host
    ## that has an attestation key.

proc detectorId*(detector: string): string =
  for (d, id) in DetectorIds:
    if d == detector: return id
  ""

proc parseHosts*(text: string): seq[EnrolledHost] =
  ## ``<host id> [<target>|-] [<attestation key hex>]`` per line, ``#``
  ## comments.
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] == '#': continue
    let p = line.splitWhitespace()
    if p[0].len != 64 or not p[0].allCharsInSet(HexDigits):
      raise newException(EvidenceCheckError, "not a 64-hex host id: " & p[0])
    var h = EnrolledHost(hostId: p[0].toLowerAscii())
    if p.len > 1 and p[1] != "-": h.target = p[1]
    if p.len > 2: h.attestationKey = p[2].toLowerAscii()
    result.add(h)

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

proc runEvidenceCheck*(inp: CheckInputs): CheckReport =
  let factor = if inp.silenceFactor > 0: inp.silenceFactor else: 3
  let entries = readEvidenceStore(inp.storeDir)
  var byHost = initTable[string, seq[EvidenceEntry]]()
  for e in entries:
    byHost.mgetOrPut($e.senderHostId, @[]).add(e)
  # The producer's publications, by target and sequence.
  var published = initTable[string, Table[uint64, DeployManifest]]()
  var latest = initTable[string, DeployManifest]()
  for m in inp.manifests:
    published.mgetOrPut(m.target, initTable[uint64, DeployManifest]())[m.sequence] = m
    if m.target notin latest or latest[m.target].sequence < m.sequence:
      latest[m.target] = m
  let artefacts = toHashSet(inp.publishedArtefacts)

  for h in inp.hosts:
    let mine = byHost.getOrDefault(h.hostId, @[])
    template alert(det, trig: string; s: uint64; d: string) =
      result.alerts.add(Alert(host: h.hostId, detector: det, trigger: trig,
                              sinkSeq: s, detail: d))
    # The host's attestation key: enrolled, or the one its bootstrap record
    # named (the first record a host ships).
    # Generation 0 is bootstrap's own, applied from no manifest: the
    # bootstrap record names it.
    var key = h.attestationKey
    var gen0 = ""
    var bootstrapDpkg = ""
      ## dpkg's last run before the hook existed: not the hook's to follow.
    for e in mine:
      if e.kind == ekRecord and e.record.detector == "addon-bootstrap":
        if key.len == 0: key = e.record.field("attestationKey").toLowerAscii()
        gen0 = e.record.field("generation")
        bootstrapDpkg = e.record.field("dpkgLastRun")
        break
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
    var appliedMs = 0'i64
    for e in mine:
      if e.kind == ekRefusedVerb:
        alert("G34", "sink-probe", e.seq, "the host's credential sent a " &
          "verb outside the sink's vocabulary (" &
          (if e.body.len > 0: $e.body[0] else: "?") & ")")
        continue
      if e.kind != ekRecord: continue
      let r = e.record
      let det = r.detector
      if not det.startsWith("addon-"): continue
      case r.category
      of ecDetection:
        detections.inc(det)
        alert(detectorId(det), r.trigger, e.seq, r.field("message"))
      of ecHeartbeat:
        lastBeat[det] = (e.receivedAtMs, parseSigned(r.field("intervalMs")))
      of ecAudit: discard
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
        if key.len > 0 and det in AttestedDetectors:
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
      let why = verifyAttestation(SignedAttestation(statement: stmt,
        signature: r.field("attestationSignature"),
        publicKey: r.field("attestationKey")), key)
      if why.len > 0:
        alert("DET-AO-9", "attestation-invalid", e.seq, why)
        continue
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

    # DET-AO-8: heartbeats, then the per-boot and per-dpkg-run rules.
    var beating = @["addon-evidence-ship"]
    if h.target.len > 0:
      # An agent host with a sink carries the egress observer, which
      # heartbeats on its own timer (DET-AO-3's DET-5).
      beating.add("addon-agent-tick")
      beating.add("addon-egress")
    var alive = initTable[string, bool]()
    for det in beating:
      var st = DetectorStatus(host: h.hostId, detector: det,
                              detections: detections.getOrDefault(det))
      if det notin lastBeat or lastBeat[det].interval <= 0:
        st.status = "never-reported"
        alert("DET-AO-8", "never-reported", 0, det & " never sent a heartbeat")
        alive[det] = false
      else:
        let (ms, interval) = lastBeat[det]
        if inp.nowMs - ms > interval * int64(factor) and
            not mutated("check-silence-as-idle"):
          st.status = "silent"
          st.detail = "last heartbeat " & $((inp.nowMs - ms) div 1000) &
            " s ago, interval " & $(interval div 1000) & " s"
          alert("DET-AO-8", "silent", 0, det & ": " & st.detail)
          alive[det] = false
        else:
          st.status = if st.detections > 0: "live-detecting" else: "live-idle"
          alive[det] = true
      result.statuses.add(st)
    let shipInterval = if "addon-evidence-ship" in lastBeat:
                         lastBeat["addon-evidence-ship"].interval
                       else: 0'i64
    for (boot, firstMs) in boots:
      if boot notin reassertBoots and shipInterval > 0 and
          inp.nowMs - firstMs > shipInterval * int64(factor):
        alert("DET-AO-8", "reassert-silent", 0, "boot " & boot &
          " has no re-assert record")
    for (run, firstMs) in dpkgRuns:
      if not hookRuns.anyIt(it >= run) and shipInterval > 0 and
          inp.nowMs - firstMs > shipInterval * int64(factor):
        alert("DET-AO-8", "apt-hook-silent", 0, "dpkg ran at " & run &
          " and no apt hook record names that run")
    for det in ["addon-reassert", "addon-apt-hook"]:
      result.statuses.add(DetectorStatus(host: h.hostId, detector: det,
        detections: detections.getOrDefault(det),
        status: (if not alive.getOrDefault("addon-evidence-ship"): "silent"
                 elif detections.getOrDefault(det) > 0: "live-detecting"
                 else: "live-idle"),
        detail: "checked per boot / per dpkg run"))
    if h.target.len > 0:
      for det in TickRiders:
        result.statuses.add(DetectorStatus(host: h.hostId, detector: det,
          detections: detections.getOrDefault(det),
          status: (if not alive.getOrDefault("addon-agent-tick"): "silent"
                   elif detections.getOrDefault(det) > 0: "live-detecting"
                   else: "live-idle"),
          detail: "rides on addon-agent-tick"))
      # DET-AO-10: lag against the producer's latest.
      if h.target in latest:
        let l = latest[h.target]
        if l.issuedAt > 0'u64 and applied < int64(l.sequence) and
            not mutated("lag-detector-disabled"):
          let ageMs = inp.nowMs - int64(l.issuedAt) * 1000
          if ageMs > int64(l.maxAgeSeconds) * 1000:
            alert("DET-AO-10", "lag", 0, "applied sequence " &
              (if applied < 0: "none" else: $applied) & " is behind the " &
              "producer's " & $l.sequence & " for " & h.target & ", published " &
              $(ageMs div 1000) & " s ago (maximum age " & $l.maxAgeSeconds &
              " s)")
  result.alerts.sort(proc(a, b: Alert): int = cmp(a.host & a.detector & $a.sinkSeq,
                                                   b.host & b.detector & $b.sinkSeq))

proc render*(r: CheckReport): string =
  for s in r.statuses:
    result.add("status " & s.host & " " & s.detector & " " & s.status &
      " detections=" & $s.detections &
      (if s.detail.len > 0: " (" & s.detail & ")" else: "") & "\n")
  for a in r.alerts:
    result.add("ALERT " & a.host & " " & a.detector & " " & a.trigger &
      (if a.sinkSeq > 0'u64: " seq=" & $a.sinkSeq else: "") &
      (if a.detail.len > 0: " " & a.detail.replace("\n", " ") else: "") & "\n")
