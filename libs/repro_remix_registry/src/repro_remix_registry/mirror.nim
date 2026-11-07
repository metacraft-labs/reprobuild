## Mirror synchronisation (`Remix-Registry.md` §"Federation and mirrors
## (M7)").
##
## A mirror is a second registry. `MirrorSync` plays the part of an intake
## for it: it pulls from the upstream read front, verifies everything
## offline against the upstream log key, and delivers the very same record
## bytes into the mirror's own Boundary spool, so the mirror re-logs them
## under its own key without changing any identity. Policy statements are
## copied into the mirror's Interior-only policy inbox.
##
## Before every round it demands a consistency proof from the last
## upstream checkpoint it accepted. A log that cannot produce one has
## rewritten history or is showing this mirror a different view; the round
## stops and the evidence is kept.

import std/[algorithm, os, tables]

import repro_remix

import ./boundary
import ./registrar
import ./client
import ./index

type
  SyncOutcome* = enum
    soSynced
    soNothingNew
    soSplitView
      ## Upstream's checkpoint is not consistent with the last one accepted.

  MirrorSync* = ref object
    upstream*: Fetch
    upstreamTrust*: TrustConfig
    spool: Spool
    policyInbox: string
    curate*: proc (e: IndexEntry): bool
      ## Which releases to carry; nil = all. Curation drops releases, never
      ## policy statements.
    copyPolicy*: bool
      ## True for every honest mirror. Exists so tests can build the
      ## dishonest one whose omission clients must detect.
    lastCheckpoint*: Envelope
    haveLast: bool
    statePath: string
      ## The last accepted upstream checkpoint, kept on disk so that a
      ## restarted mirror still demands consistency with it.
    delivered: Table[Digest32, bool]
    evidence*: seq[(Envelope, Envelope)]
      ## Checkpoint pairs that failed consistency.

proc newMirrorSync*(upstream: Fetch; upstreamTrust: TrustConfig;
                    mirrorRoot: string): MirrorSync =
  let cfg = registrar.RegistrarConfig(spoolDir: mirrorRoot / "boundary" / "spool",
    policyInbox: mirrorRoot / "interior" / "policy-inbox")
  createDir(cfg.policyInbox)
  result = MirrorSync(upstream: upstream, upstreamTrust: upstreamTrust,
    spool: initSpool(cfg.spoolDir), policyInbox: cfg.policyInbox,
    copyPolicy: true, statePath: mirrorRoot / "interior" / "mirror-upstream-checkpoint")
  if fileExists(result.statePath):
    let s = readFile(result.statePath)
    var b = newSeq[byte](s.len)
    for i, c in s: b[i] = byte(ord(c))
    result.lastCheckpoint = decodeEnvelope(b)
    result.haveLast = true

proc deliver(m: MirrorSync; t: MessageType; payload: seq[byte]) =
  discard m.spool.deliver("mirror-sync", encodeMessage(BoundaryMessage(
    msgType: t, intake: "mirror-sync", rateKey: "mirror-sync", payload: payload)))

proc must(f: Fetch; path: string): seq[byte] =
  let (status, body) = f(path)
  if status != 200:
    refuse(rrMissingBlob, "upstream returned " & $status & " for " & path)
  body

proc sync*(m: MirrorSync): SyncOutcome =
  let cpEnv = decodeEnvelope(m.upstream.must("/v1/checkpoint/latest"))
  let cp = verifyCheckpoint(cpEnv, m.upstreamTrust.logKeys)
  if m.haveLast:
    let last = verifyCheckpoint(m.lastCheckpoint, m.upstreamTrust.logKeys)
    if cp.treeSize < last.treeSize:
      m.evidence.add (m.lastCheckpoint, cpEnv)
      return soSplitView
    if cp.treeSize == last.treeSize:
      if cp.rootHash != last.rootHash:
        m.evidence.add (m.lastCheckpoint, cpEnv)
        return soSplitView
      return soNothingNew
    let (status, body) = m.upstream("/v1/consistency/" & $last.treeSize & "/" & $cp.treeSize)
    var ok = false
    if status == 200:
      let (_, _, path) = decodeProof(body)
      ok = checkConsistency(last, cp, path)[0]
    if not ok:
      m.evidence.add (m.lastCheckpoint, cpEnv)
      return soSplitView
  # Policy first: a mirror must never carry a release without the policy
  # that applies to it.
  let (_, policy) = fetchPolicySnapshot(m.upstream, m.upstreamTrust, 0, 0,
                                        int(cp.treeSize))
  for p in policy:
    let id = statementId(p)
    if id in m.delivered or not m.copyPolicy: continue
    let bytes = encodeEnvelope(p)
    var s = newString(bytes.len)
    for i, b in bytes: s[i] = char(b)
    writeFile(m.policyInbox / (toHex(id) & ".tmp"), s)
    moveFile(m.policyInbox / (toHex(id) & ".tmp"), m.policyInbox / (toHex(id) & ".stmt"))
    m.delivered[id] = true
  let snapshot = decodeIndex(m.upstream.must("/v1/index/" & $cp.treeSize))
  for e in snapshot.entries:
    if e.release in m.delivered: continue
    if not m.curate.isNil and not m.curate(e): continue
    let accepted = fetchAndAccept(m.upstream, e.release, m.upstreamTrust)
    if not accepted.decision.accepted: continue
    # Key logs in chain order, then blobs, then manifests ancestors-first,
    # each as the exact upstream bytes. (Bundle entries are sorted by
    # digest, which is neither order.)
    var keyLogs: seq[(uint64, Digest32, seq[byte])]
    for be in accepted.bundle.entries:
      if be.kind == bekKeyLogEnvelope and be.digest notin m.delivered:
        let entry = decodeKeyLogEntry(decodeEnvelope(be.bytes).body)
        keyLogs.add (entry.sequence, be.digest, be.bytes)
    keyLogs.sort(proc (a, b: (uint64, Digest32, seq[byte])): int = cmp(a[0], b[0]))
    for (_, digest, bytes) in keyLogs:
      m.deliver(mtSubmitRelease, bytes)
      m.delivered[digest] = true
    for be in accepted.bundle.entries:
      if be.kind == bekBlob and be.digest notin m.delivered:
        m.deliver(mtSubmitBlob, be.bytes)
        m.delivered[be.digest] = true
    var pending: seq[(Digest32, seq[Digest32], seq[byte])]
    for be in accepted.bundle.entries:
      if be.kind == bekManifestEnvelope:
        let v = decodeAndVerify(be.bytes)
        if Digest32(v.id) notin m.delivered:
          pending.add (Digest32(v.id), v.manifest.parents, be.bytes)
    while pending.len > 0:
      var progressed = false
      var rest: seq[(Digest32, seq[Digest32], seq[byte])]
      for (id, parents, bytes) in pending:
        var ready = true
        for p in parents:
          if p notin m.delivered: ready = false
        if ready:
          m.deliver(mtSubmitRelease, bytes)
          m.delivered[id] = true
          progressed = true
        else:
          rest.add (id, parents, bytes)
      if not progressed:
        refuse(rrIncompleteLineage, "bundle lineage does not close")
      pending = rest
  m.lastCheckpoint = cpEnv
  m.haveLast = true
  let bytes = encodeEnvelope(cpEnv)
  var s = newString(bytes.len)
  for i, b in bytes: s[i] = char(b)
  writeFile(m.statePath & ".tmp", s)
  moveFile(m.statePath & ".tmp", m.statePath)
  soSynced
