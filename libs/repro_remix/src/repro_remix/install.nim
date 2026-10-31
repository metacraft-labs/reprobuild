## Install planning and the non-bypassable safety gate
## (`Remix-Protocol.md` §"Install planning (M6)").
##
## Every way of installing a Remix — from the registry, from an offline
## bundle, from an old install lock, from a cached artifact, and through
## the CLI, desktop, agent and API entry points that sit on those — ends in
## `planInstall`. `planInstall` is the only constructor of an
## `InstallPlan`: its fields are private to this module, so code elsewhere
## cannot hold a plan the gate has not passed. A plan is what activation
## consumes; no plan, no build, no activation.
##
## The gate re-decides from the *current* policy snapshot every time. A
## lock written before a release was blocked is re-gated when replayed, so
## an old lock is not a way around a new block (Invariant I-7).

import std/[algorithm, tables]

import ssz_serialization

import ./types
import ./identity
import ./codec
import ./verify
import ./lineage
import ./statements
import ./keylog
import ./acceptance
import ./composition

const
  MaxLockMembers* = MaxParents

type
  InstallSource* = enum
    ## Where an install request came from. Recorded in the plan for audit;
    ## the gate treats every source identically.
    srcRegistry = 1
    srcBundle = 2
    srcLock = 3
    srcCache = 4
    srcCli = 5
    srcDesktop = 6
    srcAgent = 7
    srcApi = 8

  PolicySnapshot* = object
    ## What the gate consults. Built from a trusted checkpoint and the
    ## quorum-signed policy statements the client holds.
    trust*: TrustConfig
    checkpoint*: Envelope
    policyStatements*: seq[Envelope]
    principals*: seq[Principal]
    issuedAt*: int64
      ## When the client last refreshed this snapshot (Unix seconds).
    maxAgeSeconds*: int64
      ## Older than this: `stale-policy`, refuse (unless the organization
      ## policy allows offline installs from a frozen snapshot).
    allowStaleOffline*: bool

  Candidate* = object
    ## One release to gate, with how it was logged.
    record*: LoggedRecord
    variant*: seq[VariantValue]

  GateRefusal* = object
    release*: Digest32
    reason*: RemixRefusal
    detail*: string

  InstallPlan* = ref object
    ## Only `planInstall` constructs one. A `ref` so that the zero value is
    ## `nil` rather than a plausible-looking plan; activation calls
    ## `requireGated`, which refuses `nil` and anything not marked here.
    gated: bool
    source: InstallSource
    lockId: Digest32
    lockBytes: seq[byte]
    composition: Composition
    snapshotCheckpoint: Digest32

  PlanResult* = object
    ok*: bool
    plan*: InstallPlan
    refusals*: seq[GateRefusal]
    stalePolicy*: bool
    conflicts*: seq[Conflict]

  InstallLockW = object
    members: List[Digest32, MaxLockMembers]
    composition: Digest32
    baseLock: Digest32
    policyCheckpoint: Digest32

proc requireGated*(p: InstallPlan) =
  ## The precondition of every activation path.
  if p.isNil or not p.gated:
    refuse(rrForbiddenContent, "no gated install plan")

proc source*(p: InstallPlan): InstallSource = p.source
proc lockId*(p: InstallPlan): Digest32 = p.lockId
proc lockBytes*(p: InstallPlan): seq[byte] = p.lockBytes
proc composition*(p: InstallPlan): Composition = p.composition

proc cmpD(a, b: Digest32): int =
  for i in 0 ..< 32:
    if a[i] != b[i]: return cmp(a[i], b[i])
  0

proc gateOne(c: Candidate; snap: PolicySnapshot): seq[GateRefusal] =
  ## Gate one release under the snapshot: the same acceptance rule a
  ## client applies to anything it fetches.
  let d = acceptRelease(AcceptanceInput(release: c.record,
    checkpoint: snap.checkpoint, principals: snap.principals,
    policyStatements: snap.policyStatements), snap.trust)
  if not d.accepted:
    result.add GateRefusal(release: Digest32(d.id), reason: d.reason, detail: d.detail)

proc planInstall*(source: InstallSource; candidates: seq[Candidate];
                  ancestors: seq[LoggedRecord]; snap: PolicySnapshot;
                  baseLock: Digest32; now: int64;
                  resolutions: seq[Resolution] = @[];
                  blobs: proc (id: Digest32): (bool, seq[byte]) = nil;
                  grantedPermissions: seq[Permission] = @[];
                  admittedLicenses: seq[string] = @[]): PlanResult =
  ## The single gate. Every member and every ancestor must be accepted
  ## under the current snapshot; then the members are composed; only a
  ## `csReady` composition yields a plan.
  if snap.maxAgeSeconds > 0 and now - snap.issuedAt > snap.maxAgeSeconds and
     not (snap.allowStaleOffline and source in {srcBundle, srcLock, srcCache}):
    result.stalePolicy = true
    result.refusals.add GateRefusal(reason: rrBlockedByPolicy,
                                    detail: "stale-policy: refresh before installing")
    return
  # Gate members and ancestors with one rule.
  var known = initTable[Digest32, seq[Digest32]]()
  var verified: seq[VerifiedManifest]
  for a in ancestors:
    let v = decodeAndVerify(a.envelopeBytes)
    known[Digest32(v.id)] = v.manifest.parents
    result.refusals.add gateOne(Candidate(record: a), snap)
  for c in candidates:
    let v = decodeAndVerify(c.record.envelopeBytes)
    known[Digest32(v.id)] = v.manifest.parents
    verified.add v
    result.refusals.add gateOne(c, snap)
  # Every ancestor of every member must have been supplied and gated.
  for v in verified:
    let l = walkLineage(v.id, proc (id: ReleaseId): (bool, seq[Digest32]) =
      let k = Digest32(id)
      if k in known: (true, known[k]) else: (false, @[]))
    for m in l.missing:
      result.refusals.add GateRefusal(release: Digest32(m), reason: rrIncompleteLineage,
        detail: "ancestor not supplied, so it cannot be gated")
  if result.refusals.len > 0:
    return
  # Compose. Blocking was decided above by the gate, so composition's own
  # `isBlocked` input has nothing further to report here.
  var members: seq[MemberSpec]
  for i, v in verified:
    members.add MemberSpec(release: v, variant: candidates[i].variant)
  let noBlobs = proc (id: Digest32): (bool, seq[byte]) = (false, newSeq[byte]())
  let parentsOf = proc (id: ReleaseId): (bool, seq[Digest32]) =
    let k = Digest32(id)
    if k in known: (true, known[k]) else: (false, newSeq[Digest32]())
  let notBlocked = proc (id: Digest32): bool = false
  let comp = compose(ComposeInputs(members: members, resolutions: resolutions,
    baseLock: baseLock, blobs: (if blobs.isNil: noBlobs else: blobs),
    parents: parentsOf, isBlocked: notBlocked,
    grantedPermissions: grantedPermissions, admittedLicenses: admittedLicenses))
  result.conflicts = comp.conflicts
  if comp.status != csReady:
    result.refusals.add GateRefusal(reason: rrForbiddenContent,
      detail: "composition is " & $comp.status)
    return
  # The install lock: members, composition, base lock and the checkpoint
  # the decision was made against.
  var memberIds: seq[Digest32]
  for v in verified: memberIds.add Digest32(v.id)
  memberIds.sort(cmpD)
  let cpId = envelopeIdentity(snap.checkpoint)
  let body = SSZ.encode(InstallLockW(members: List[Digest32, MaxLockMembers].init(memberIds),
    composition: comp.id, baseLock: baseLock, policyCheckpoint: cpId))
  let env = Envelope(schemaVersion: RemixSchemaVersion, requiredFeatures: 0,
                     recordKind: rkInstallLock, body: body)
  result.ok = true
  result.plan = InstallPlan(gated: true, source: source, lockId: envelopeIdentity(env),
    lockBytes: encodeEnvelope(env), composition: comp, snapshotCheckpoint: cpId)

proc lockMembers*(lockBytes: openArray[byte]): seq[Digest32] =
  ## Read an install lock's member releases, to replay it through
  ## `planInstall` with source `srcLock`. Reading a lock grants nothing.
  let env = decodeEnvelope(lockBytes)
  if env.recordKind != rkInstallLock:
    refuse(rrUnknownRecordKind, "not an install lock")
  try:
    asSeq(SSZ.decode(env.body, InstallLockW).members)
  except SerializationError as e:
    refuse(rrMalformed, "install lock: " & e.msg)
