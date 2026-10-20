## ReproOS-Remix-Protocol-And-Registry M6 verification
## ``test_negative_safety_and_revocation_block_all_install_paths``.
##
## "CLI, desktop, agent, API, cached artifact, old lock, and offline bundle
## paths cannot bypass a blocking verdict or revocation policy."
##
## Each install path is an `InstallSource` passed to the one gate,
## `planInstall`; the test drives every source through the same blocked,
## revoked, laundered-through-lineage, omitted-ancestor and replayed-old-lock
## cases, and checks at compile time that no code outside the module can
## construct a plan without the gate. Keys, logs, proofs and quorum
## signatures are real.

import std/[algorithm, sequtils, unittest]

import repro_remix
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32: result[i] = seed xor byte(i)

proc kid(k: PeerKeypair): Digest32 = Digest32(keyIdOf(k))

let logKey = generateKeypair()
let policyA = generateKeypair()
let policyB = generateKeypair()
let trust = TrustConfig(logKeys: @[kid(logKey)],
  policyKeys: @[kid(policyA), kid(policyB)], policyThreshold: 2)

type World = object
  log: MerkleLog
  records: seq[seq[byte]]

proc logRecord(w: var World; env: Envelope): uint64 =
  let bytes = encodeEnvelope(env)
  result = uint64(w.log.append(logLeaf(env.recordKind, envelopeIdentity(env), bytes)))
  w.records.add bytes

proc checkpoint(w: World): Envelope =
  result = newStatementEnvelope(Statement(kind: skLogCheckpoint, subjectKind: sbLog,
    subject: kid(logKey), treeSize: uint64(w.log.size), rootHash: w.log.root()))
  result.signEnvelope(logKey)

proc logged(w: World; pos: uint64): LoggedRecord =
  LoggedRecord(envelopeBytes: w.records[pos], index: pos,
               proof: w.log.inclusionProof(int(pos), w.log.size))

proc release(name: string; k: PeerKeypair; parents: seq[Digest32] = @[]): Envelope =
  result = newManifestEnvelope(Manifest(remixName: "u/" & name, version: "1.0.0",
    intent: "Release " & name & ".", license: "MIT",
    targets: @[Target(original: OriginalRef(package: "firefox",
      interfaceFingerprint: d32(1), catalogWorkspace: "reprobuild-packages",
      catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
      catalogRevision: "0123456789abcdef0123456789abcdef01234567",
      catalogInterfaceArtifact: d32(2)), constraintKind: ckExactFingerprint)],
    parents: parents, authors: @[kid(k)]))
  result.signEnvelope(k)

proc blockVerdict(id: Digest32): Envelope =
  result = newStatementEnvelope(Statement(kind: skVerdict, subjectKind: sbRelease,
    subject: id, scope: @["block"]))
  result.signEnvelope(policyA)
  result.signEnvelope(policyB)

proc refusalReasons(r: PlanResult): seq[RemixRefusal] = r.refusals.mapIt(it.reason)

# --- the world ---------------------------------------------------------------
var w: World
let author = generateKeypair()
let backup = generateKeypair()
let genesis = entrySigned(KeyLogEntry(operation: klGenesis, algorithm: saEcdsaP256,
  publicKey: @(author.publicKey), roles: {roleAuthor}), @[author])
let addBackup = entrySigned(KeyLogEntry(principal: kid(author), sequence: 1,
  previous: envelopeIdentity(genesis), operation: klAddKey, algorithm: saEcdsaP256,
  publicKey: @(backup.publicKey), roles: {roleAuthor}), @[author])
var chain = @[(genesis, w.logRecord(genesis)), (addBackup, w.logRecord(addBackup))]
let goodPos = w.logRecord(release("good", author))
let badPos = w.logRecord(release("bad", author))
let badId = Digest32(decodeAndVerify(w.records[badPos]).id)
let childPos = w.logRecord(release("child-of-bad", backup, @[badId]))
let stolenPos = w.logRecord(release("stolen", author))
let revoke = entrySigned(KeyLogEntry(principal: kid(author), sequence: 2,
  previous: envelopeIdentity(addBackup), operation: klRevokeKey, target: kid(author),
  compromisedFrom: stolenPos), @[backup])
chain.add (revoke, w.logRecord(revoke))
let principal = replayKeyLog(chain)

proc snapshot(policy: seq[Envelope]; issuedAt = 1000'i64; maxAge = 0'i64;
              allowStaleOffline = false): PolicySnapshot =
  PolicySnapshot(trust: trust, checkpoint: w.checkpoint(), policyStatements: policy,
    principals: @[principal], issuedAt: issuedAt, maxAgeSeconds: maxAge,
    allowStaleOffline: allowStaleOffline)

proc plan(src: InstallSource; pos: uint64; ancestors: seq[uint64] = @[];
          snap: PolicySnapshot; now = 1000'i64): PlanResult =
  planInstall(src, @[Candidate(record: w.logged(pos))],
              ancestors.mapIt(w.logged(it)), snap, d32(9), now,
              admittedLicenses = @["MIT"])

const AllSources = [srcRegistry, srcBundle, srcLock, srcCache, srcCli,
                    srcDesktop, srcAgent, srcApi]

suite "Remix M6 — negative safety and revocation block every install path":

  test "an allowed release plans from every path (positive control)":
    for src in AllSources:
      checkpoint $src
      let r = plan(src, goodPos, snap = snapshot(@[]))
      check r.ok
      check r.plan.source == src
      check lockMembers(r.plan.lockBytes) == @[Digest32(decodeAndVerify(w.records[goodPos]).id)]

  test "a quorum-signed block refuses every path":
    let snap = snapshot(@[blockVerdict(badId)])
    for src in AllSources:
      checkpoint $src
      let r = plan(src, badPos, snap = snap)
      check not r.ok
      check r.refusalReasons == @[rrBlockedByPolicy]

  test "a revoked key refuses every path, inside its compromise window":
    for src in AllSources:
      checkpoint $src
      let r = plan(src, stolenPos, snap = snapshot(@[]))
      check not r.ok
      check r.refusalReasons == @[rrRevokedKey]

  test "a block cannot be laundered through a child release":
    let snap = snapshot(@[blockVerdict(badId)])
    for src in AllSources:
      checkpoint $src
      # Supplying the blocked parent: refused on the parent.
      let withParent = plan(src, childPos, @[badPos], snap)
      check not withParent.ok
      check rrBlockedByPolicy in withParent.refusalReasons
      # Omitting the parent to dodge the gate: refused as ungateable.
      let without = plan(src, childPos, snap = snap)
      check not without.ok
      check without.refusalReasons == @[rrIncompleteLineage]

  test "an install lock written before a block is re-gated when replayed":
    let before = plan(srcRegistry, badPos, snap = snapshot(@[]))
    check before.ok
    let members = lockMembers(before.plan.lockBytes)
    check members == @[badId]
    let replay = plan(srcLock, badPos, snap = snapshot(@[blockVerdict(badId)]))
    check not replay.ok
    check replay.refusalReasons == @[rrBlockedByPolicy]

  test "stale policy refuses online paths; offline paths still gate on the frozen snapshot":
    let stale = snapshot(@[blockVerdict(badId)], issuedAt = 0, maxAge = 100,
                         allowStaleOffline = true)
    check plan(srcRegistry, goodPos, snap = stale).stalePolicy
    check plan(srcAgent, goodPos, snap = stale).stalePolicy
    check plan(srcBundle, goodPos, snap = stale).ok
    check not plan(srcBundle, badPos, snap = stale).ok

  test "no code outside the gate can construct a plan":
    check not compiles(InstallPlan(source: srcCli))
    check not compiles(InstallPlan(gated: true))
    var forged: InstallPlan                      # the zero value is nil
    check forged.isNil
    expect RemixError:
      forged.requireGated()
    expect RemixError:
      InstallPlan().requireGated()
    plan(srcCli, goodPos, snap = snapshot(@[])).plan.requireGated()
