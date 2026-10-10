## Shared-Development-Services L7 (spec §4.5) — THE REGISTRY OF RUNNING
## INSTANCES, keyed by `(identity, scope, environment)`, and the three
## operations `repro up` / `repro down` perform against it: CONVERGE,
## RELEASE, and `--replace`'s TAKEOVER.
##
## § WHAT §4.5 ASKS FOR, AND WHICH HALF IS HERE
##
## "`repro up` is **converge**, not *start*. The daemon holds a registry
## of running instances keyed by `(identity, scope)`; `up` resolves the
## key, attaches if an instance is present and materialises it
## otherwise."
##
## This module is the registry and the POLICY over it. It is not the
## daemon: it starts no process and opens no socket. The daemon-hosted
## half — materialising the instance's process, terminating it when the
## last holder goes, and serving the two request kinds over the control
## API — is `repro_daemon_core/instance_registry.nim`, which owns one of
## these and injects the process-liveness probe. The split is the same
## one `lease_registry.nim` already draws: the lease POLICY is in
## `repro_resources`, and the daemon module is the handler body.
##
## § THIS IS A SECOND REGISTRY, NOT THE SESSION REGISTRY
##
## §4.5 is emphatic, and the sentence is the reason this file is not a
## field on a session record: "`Local-Daemons-And-Control-Plane.md` keys
## *sessions* by canonical project root among other things, and that is
## unchanged: a session stays per project root. An instance registry
## keyed by identity is what lets N of those sessions share one
## instance, and conflating the two would re-impose one instance per
## project root — the thing this document exists to lift."
##
## So nothing here is keyed by a project root. The only place a project
## root appears is the HOLDER id (`serviceLeaseHolderId`), which §4.5
## requires to be per consuming project — "one holder per consuming
## project" — and which L4's own comment already distinguishes from a
## state address.
##
## § WHERE THE REGISTRY IS PERSISTED, AND WHY IT IS THE LEASE RECORDS
##
## §4.5: "The registry above is in-memory, and authoritative only while
## the daemon is running. A daemon that restarts rebuilds it from the
## lease records `Ephemeral-State-Leases.md` persists, and that rebuild
## is **lossy today**."
##
## That is implemented literally: an instance is one
## `ResourceStateRecord` in the real L1 `StateStore`, addressed by
## `serviceInstanceAddress(key)`, with its holders in the record's own
## `holders` map through the real `mergeHolderDeadlines`. The rebuild
## reads exactly those records. Two consequences are deliberate:
##
##   * the lossiness §4.5 names is REAL here rather than simulated — a
##     `keep` holder's name is dropped by `mergeHolderDeadlines` and the
##     rebuild therefore cannot enumerate it, which is what makes rule 1
##     below load-bearing instead of decorative; and
##   * the daemon-restart clause of L7's gate is answered by a store
##     sweep rather than by a second on-disk format, so there is one
##     answer on disk to "what instances exist" and the reaper tick
##     already sweeps the same store.
##
## THE INTERFACE SNAPSHOT TRAVELS IN THE RECORD'S `attrsJson`, which is
## the record's own field for "a payload this module does not interpret"
## (`state_store.nim`: "Opaque to this module"). It is written and read
## HERE, by `encodeServiceInstanceAttrs` / `decodeServiceInstanceAttrs`,
## and the `attrsTypeId` is a version-bearing id so a future shape change
## is a named refusal rather than a misparse. It deliberately does NOT go
## through `marshalAttrs`/`unmarshalAttrs`: those dispatch on the
## extension registry, which every out-of-tree resource provider links,
## and a service instance is not a provider-visible resource type. A
## record whose attrs cannot be decoded is REPORTED and skipped, never
## silently treated as an absent instance — see `srrSkippedUndecodable`.
##
## § §4.5's THREE RULES ABOUT A RESTARTED DAEMON, AND WHAT IS IMPLEMENTED
##
## 1. "**An unrecoverable holder set is a REFUSAL, never a proceed.**
##    When the rebuilt registry cannot enumerate an instance's holders,
##    `repro up --replace` refuses and reports that the holder set is
##    unknown, naming the holders it does know." Implemented as
##    `scoRefuseUnknownHolders`, decided BEFORE `replaceDecision` is
##    consulted, so a recovered-but-empty holder set and an unrecoverable
##    one cannot take the same branch.
##
##    The same reasoning is applied — and LABELLED as an application
##    rather than quoted as a clause — to RELEASE: `releaseServiceInstance`
##    answers `srlRefuseUnknownHolders` rather than concluding "I was the
##    last holder" from a holder set it could not enumerate. Concluding
##    the other way would stop an instance another project is using,
##    which is the damage rule 1 exists to prevent arriving through the
##    other verb.
##
## 2. "**`--force` remains the only explicit override**, with its §4.3
##    meaning, and what it prints must say that holders may exist which
##    it cannot name." Implemented: the forced diagnostic on the
##    unrecoverable path says exactly that, and it is a DIFFERENT
##    sentence from the forced diagnostic on the recoverable path. A
##    single shared sentence would read as "no other holders" when the
##    truth is "no other holders are recoverable", which §4.5 calls "a
##    worse failure than the refusal it bypasses".
##
## 3. "**The durable fix belongs in the record, not in the decision.**"
##    NOT IMPLEMENTED HERE, deliberately, and the milestone drawer says
##    so with its reason: `ResourceStateRecord` is the shared SSZ v3
##    shape of the whole lease/reaper lane, and §4.5 itself contemplates
##    the interim state — "Until the record shape changes, rule 1 is
##    load-bearing and must be tested against a record written by the
##    real store rather than a constructed one". Changing the shape here
##    would make rule 1 unreachable through the real store on the same
##    commit that introduced it. The gap is the filed issue
##    `2026-10-09-a-keep-holders-identity-is-never-persisted-in-a-lease-record.md`.
##
## § TEST-DOUBLE POLICY
##
## This module takes exactly one injected function, `ServiceInstanceRegistry.
## probe`, and it is NOT a seam for a mock. The honest implementation of
## "is the process that was recorded still that process" is
## `repro_daemon_core/writer_identity.writerLiveness`, and
## `repro_daemon_core` DEPENDS ON `repro_resources` — so importing it
## here would be a library cycle. Injection is how the real function
## reaches this module without one, and both this module's tests and the
## daemon pass that real function. A `nil` probe is a refusal
## (`ServiceRegistryError`), not a default that answers "live": a
## registry that cannot test liveness must say so rather than orphan or
## double-start, which is the clause L7's gate measures.

import std/[algorithm, json, options, strutils, tables, times]

import repro_project_dsl # ServiceScope / ServiceIdentityKind
import repro_resources/instance # ResourceDeterminism (rdVolatile)
import repro_resources/lease # LeasedDep / deadlineFrom / keep
import repro_resources/reaper # ReapHandler / registerReapHandler
import repro_resources/reconcile # mergeHolderDeadlines
import repro_resources/service_attach # attachDecision / replaceDecision
import repro_resources/service_identity # ServiceInstanceKey & friends
import repro_resources/state_store # StateStore / ResourceStateRecord

export service_attach
export service_identity
# `serviceInstanceReapDecline` returns a `ReapHandlerOutcome` and
# `installDecliningServiceInstanceReapHandler` writes into the reaper's
# handler registry, so both are part of THIS module's surface. A module
# that imports this one in order to install or replace that handler would
# otherwise have to import `reaper` separately to name the type it is
# handed.
export reaper

const
  ServiceInstanceTypeId* = "reprobuild.service-instance"
    ## The `ResourceStateRecord.typeId` an instance record carries. No
    ## resource DRIVER is registered under it, and that is intentional:
    ## the instance's lifecycle is this registry's, not the generic
    ## reconciler's. The id exists so a reader of the store — or the
    ## reaper's log — can tell an instance record from a resource one.
    ##
    ## WHAT REAPS IT IS A TYPED `ReapHandler` ON THIS ID, not a driver.
    ## The sweep that enforces the lease is the SAME `reapOnce` the
    ## lease lane already runs over this store (see
    ## `serviceInstanceStoreRoot`'s note on why there is one root), and
    ## `reaper.nim`'s handler hook is how that sweep reaches a destroy
    ## this library cannot perform. The bottom of this module registers
    ## the DECLINING handler; `repro_daemon_core/instance_registry`
    ## replaces it with the one that can really stop a process.
  ServiceInstanceAttrsTypeId* = "reprobuild.service-instance.v1"
    ## The version-bearing id of the `attrsJson` shape below. A record
    ## carrying any other id is REPORTED and skipped by the rebuild
    ## rather than decoded on a guess.
  ServiceInstanceAddressPrefix* = "service:"
    ## The prefix `serviceInstanceAddress` produces. The rebuild selects
    ## records by it, so an instance record and an ordinary leased
    ## resource in the same store cannot be confused.

type
  ServiceRegistryError* = object of CatchableError
    ## Raised when the registry cannot operate AT ALL — no store root, no
    ## liveness probe. Never raised to express an outcome: every outcome
    ## of converge / release is a value, because the caller has to print
    ## it, and §4.5's refusals are outcomes.

  ServiceInstanceLiveness* = enum
    ## The three answers `writer_identity.WriterLiveness` gives, mirrored
    ## here so this module needs no dependency on the module that
    ## produces them. The asymmetry is carried over verbatim and matters:
    ## `silUnknown` must be treated as LIVE, because declaring a live
    ## instance dead orphans a process and then starts a second one.
    silLive ## the recorded process is running right now
    silDead ## provably not running: the pid is absent or reused
    silUnknown ## identity could not be established; treat as live

  ServiceInstanceLivenessProbe* =
    proc (processIdentity: string): ServiceInstanceLiveness {.closure.}

  ServiceInstanceProcess* = object
    ## What was materialised. `processIdentity` is opaque text here — it
    ## is whatever the injected probe understands, which in the daemon is
    ## `encodeWriterIdentity`'s `<bootId>:<pid>:<startStamp>` triple.
    pid*: int
    processIdentity*: string
    command*: seq[string]
    workingDir*: string

  ServiceInstanceRecord* = object
    ## The persisted projection of one running instance.
    key*: ServiceInstanceKey
    address*: string
    snapshot*: ServiceInterfaceSnapshot
    process*: ServiceInstanceProcess
    startedByHolder*: string
      ## The holder id of the project whose `repro up` materialised it.
      ## §4.3's warning has to name "the project whose definition is
      ## running"; the SNAPSHOT names the project, and this names the
      ## consumer whose invocation started it. They are different facts
      ## and both are kept.
    startedAtUnix*: int64

  HolderRecovery* = enum
    ## Whether the holder set read back from the store is TOTAL.
    hrTotal
      ## Every holder of this instance is named in the record.
    hrMayHaveUnnamedKeepHolder
      ## `effectiveDeadline == none`, which `state_store.nim` documents as
      ## produced by two different states — "no dated holder, or at least
      ## one `keep` holder pinning the state with no expiry". The record
      ## carries nothing that separates them, so the holder set MAY be
      ## incomplete. This is `holdersFromStateRecord`'s
      ## `mayHaveUnnamedKeepHolder` under a name that says what the
      ## registry does about it.

  ServiceInstanceEntry* = object
    record*: ServiceInstanceRecord
    instance*: RunningServiceInstance
      ## L6's record, now produced by a registry lookup instead of by a
      ## test constructor. L6's drawer: "L7 replaces the constructor with
      ## a registry lookup; the decision functions are pure functions of
      ## their arguments, so L7 changes provenance only." Nothing in
      ## `attachDecision` or `replaceDecision` is touched by this module.
    holderRecovery*: HolderRecovery
      ## Whether `instance.holders` is the COMPLETE holder set.
      ##
      ## `hrTotal` for an entry this daemon created (converge knows every
      ## holder it added); `hrMayHaveUnnamedKeepHolder` for one the
      ## rebuild read back from a record whose `effectiveDeadline` is
      ## `none`. §4.5: the registry "is in-memory, and authoritative only
      ## while the daemon is running", and the rebuild "is lossy today".
      ## This field is where that distinction lives, and it is the input
      ## to rule 1.
      ##
      ## IT IS NOT CLEARED BY A LATER CONVERGE. A project that attaches
      ## after a restart adds a holder the registry can name, and the
      ## unnamed `keep` holder may still be there -- so the set is still
      ## incomplete and a release must still refuse. Clearing it on the
      ## first attach would make rule 1 stop firing for exactly the
      ## instances it protects.
    liveness*: ServiceInstanceLiveness

  ServiceInstanceRegistry* = object
    storeRoot*: string
    probe*: ServiceInstanceLivenessProbe
    entries*: Table[string, ServiceInstanceEntry]

  ServiceRegistryRebuildEventKind* = enum
    srrRecovered          ## the instance is live (or unknown) and kept
    srrDroppedDeadProcess ## provably dead: the record is removed
    srrSkippedUndecodable ## the attrs could not be decoded; left alone

  ServiceRegistryRebuildEvent* = object
    address*: string
    kind*: ServiceRegistryRebuildEventKind
    liveness*: ServiceInstanceLiveness
    holderRecovery*: HolderRecovery
    detail*: string

  ServiceRegistryRebuildReport* = object
    events*: seq[ServiceRegistryRebuildEvent]
    recovered*: int
    droppedDead*: int
    skipped*: int
    unnamedKeepHolderRisks*: int
      ## How many recovered instances came back with
      ## `hrMayHaveUnnamedKeepHolder`. Counted rather than merely
      ## reported, because it is the number that says how often rule 1
      ## will fire on this store.

  ServiceConvergeOutcome* = enum
    ## The outcomes of `repro up`. The three ATTACH values are L6's three
    ## §4.3 outcomes, unchanged; `scoMaterialise` is §4.5's "materialises
    ## it otherwise"; the four remaining are `--replace`'s.
    scoMaterialise
    scoAttachSilently
    scoAttachWithWarning
    scoRefuseMajor
    scoReplace
    scoRefuseOtherHolders
    scoForcedOverOtherHolders
    scoRefuseUnknownHolders ## §4.5 rule 1

  ServiceConvergeDecision* = object
    outcome*: ServiceConvergeOutcome
    diagnostic*: string
      ## Empty if and only if the outcome is `scoMaterialise`,
      ## `scoAttachSilently` or `scoReplace` — the three that have
      ## nothing to say. Asserted in both directions, for the reason
      ## L6 gives for its own emptiness invariant.
    address*: string
    holderId*: string
    hadInstance*: bool
    holderRecovery*: HolderRecovery
    attach*: ServiceAttachDecision
      ## Populated when an instance was present and `--replace` was NOT
      ## asked. L6 decided this; L7 only supplied the record.
    replace*: ServiceReplaceDecision
      ## Populated when `--replace` was asked AND the holder set was
      ## recoverable. Left at its zero value on the rule-1 path, because
      ## `replaceDecision` was never consulted there — a populated
      ## `blockingHolders` would claim a set this path could not compute.
    holdersKnown*: seq[string]
      ## The holders the registry CAN name, sorted. On the rule-1 path
      ## this is §4.5's "naming the holders it does know".

  ServiceReleaseOutcome* = enum
    ## The outcomes of `repro down`.
    srlNoInstance           ## nothing is registered at this key
    srlNotHeld              ## this project does not hold the instance
    srlDroppedHolder        ## dropped; other holders remain, it stays up
    srlReleasedLastHolder   ## dropped; it was the last — stop the instance
    srlRefuseUnknownHolders ## rule 1's reasoning, applied to release

  ServiceReleaseDecision* = object
    outcome*: ServiceReleaseOutcome
    diagnostic*: string
      ## Empty if and only if the outcome is `srlDroppedHolder` or
      ## `srlReleasedLastHolder`.
    address*: string
    holderId*: string
    remainingHolders*: seq[string]
      ## Sorted, and after the drop. On `srlReleasedLastHolder` it is
      ## empty; on `srlRefuseUnknownHolders` it is what could be named.
    holderRecovery*: HolderRecovery
    record*: ServiceInstanceRecord
      ## Carried so the caller can terminate the right process on
      ## `srlReleasedLastHolder` without a second lookup.

# ---------------------------------------------------------------------------
# The attrs codec. One shape, one version id, read and written here.
# ---------------------------------------------------------------------------

proc isServiceInstanceAddress*(address: string): bool =
  ## Whether `address` is one `serviceInstanceAddress` produces. The
  ## rebuild's record filter, exposed because a store reader outside this
  ## module (the reaper's log, a diagnostic) asks the same question.
  address.startsWith(ServiceInstanceAddressPrefix)

proc memberToJson(member: ServiceInterfaceMember): JsonNode =
  %*{"kind": $member.kind, "name": member.name,
     "signature": member.signature}

proc memberFromJson(node: JsonNode): ServiceInterfaceMember =
  let kindText = node{"kind"}.getStr("")
  var kind = smkSignature
  var matched = false
  for candidate in ServiceMemberKind:
    if $candidate == kindText:
      kind = candidate
      matched = true
      break
  if not matched:
    raise newException(ValueError,
      "unknown service interface member kind `" & kindText & "`")
  ServiceInterfaceMember(kind: kind, name: node{"name"}.getStr(""),
    signature: node{"signature"}.getStr(""))

proc snapshotToJson(snapshot: ServiceInterfaceSnapshot): JsonNode =
  result = %*{
    "serviceName": snapshot.serviceName,
    "packageName": snapshot.packageName,
    "projectName": snapshot.projectName,
    "activityName": snapshot.activityName,
    "handleType": snapshot.handleType,
    "compatibilityMajor": int(snapshot.compatibilityMajor),
    "fingerprint": snapshot.fingerprint,
    "projectFingerprint": snapshot.projectFingerprint}
  var members = newJArray()
  for member in snapshot.members:
    members.add(memberToJson(member))
  result["members"] = members

proc snapshotFromJson(node: JsonNode): ServiceInterfaceSnapshot =
  ## `node{...}` is used for every scalar — a bare `node["x"]` on a
  ## missing key is the segfault shape
  ## `issues/2026-10-10-kind-and-len-on-a-missing-json-key-segfault.md`
  ## records, and this decoder reads a file another process wrote.
  result = ServiceInterfaceSnapshot(
    serviceName: node{"serviceName"}.getStr(""),
    packageName: node{"packageName"}.getStr(""),
    projectName: node{"projectName"}.getStr(""),
    activityName: node{"activityName"}.getStr(""),
    handleType: node{"handleType"}.getStr(""),
    compatibilityMajor: uint32(node{"compatibilityMajor"}.getInt(0)),
    fingerprint: node{"fingerprint"}.getStr(""),
    projectFingerprint: node{"projectFingerprint"}.getStr(""),
    members: @[])
  let members = node{"members"}
  if not members.isNil and members.kind == JArray:
    for member in members:
      result.members.add(memberFromJson(member))

proc encodeServiceInterfaceSnapshot*(snapshot: ServiceInterfaceSnapshot):
    string =
  ## The snapshot as wire JSON. ONE codec, used both for the record's
  ## `attrsJson` and for the daemon request body, so a snapshot that
  ## round-trips through the registry and one that round-trips through
  ## the control API cannot disagree about what a member is.
  $snapshotToJson(snapshot)

proc decodeServiceInterfaceSnapshot*(text: string):
    ServiceInterfaceSnapshot =
  ## The inverse. Raises `ValueError` -- never returns a half-decoded
  ## snapshot, because a snapshot missing its members would compare EQUAL
  ## to another snapshot missing its members and attach silently.
  let node =
    try:
      parseJson(text)
    except CatchableError as err:
      raise newException(ValueError,
        "unparsable service interface snapshot: " & err.msg)
  if node.kind != JObject:
    raise newException(ValueError,
      "a service interface snapshot must be a JSON object")
  snapshotFromJson(node)

proc keyToJson(key: ServiceInstanceKey): JsonNode =
  %*{"identityKind": identityKindWord(key.identityKind),
     "identity": key.identity,
     "scope": scopeWord(key.scope),
     "scopeKey": key.scopeKey,
     "environment": key.environment,
     "degradation": key.degradation}

proc keyFromJson(node: JsonNode): ServiceInstanceKey =
  let identityWord = node{"identityKind"}.getStr("")
  var identityKind = sikDerived
  var identityMatched = false
  for candidate in ServiceIdentityKind:
    if identityKindWord(candidate) == identityWord:
      identityKind = candidate
      identityMatched = true
      break
  if not identityMatched:
    raise newException(ValueError,
      "unknown service identity kind `" & identityWord & "`")
  let scopeText = node{"scope"}.getStr("")
  var scope = sscProject
  var scopeMatched = false
  for candidate in ServiceScope:
    if scopeWord(candidate) == scopeText:
      scope = candidate
      scopeMatched = true
      break
  if not scopeMatched:
    raise newException(ValueError,
      "unknown service scope `" & scopeText & "`")
  ServiceInstanceKey(identityKind: identityKind,
    identity: node{"identity"}.getStr(""),
    scope: scope,
    scopeKey: node{"scopeKey"}.getStr(""),
    environment: node{"environment"}.getStr(""),
    degradation: node{"degradation"}.getStr(""))

proc encodeServiceInstanceKey*(key: ServiceInstanceKey): string =
  ## The instance key as wire JSON. The SAME codec the record's attrs
  ## use, for the reason the snapshot codec is shared: a key that
  ## round-trips through the control API and one that round-trips through
  ## the store must denote the same instance, and two codecs is how they
  ## stop doing that.
  ##
  ## IT IS JSON RATHER THAN SEVEN WIRE FIELDS because
  ## `repro_daemon_core/protocol.nim` is deliberately a LEAF module --
  ## "the frame codec never depends on the resource lane" -- and
  ## `ServiceScope` / `ServiceIdentityKind` are `repro_project_dsl`
  ## types. Carrying the key as an opaque string keeps that true, and the
  ## translation happens exactly where `lease_registry.nim` already
  ## translates `ttlSeconds`.
  $keyToJson(key)

proc decodeServiceInstanceKey*(text: string): ServiceInstanceKey =
  ## The inverse. An unknown scope or identity-kind word is a named
  ## refusal (`keyFromJson` raises), never a default: defaulting the
  ## scope to `project` would silently narrow a `workspace`-scoped
  ## service to one checkout, which is the §4.4 defect this design
  ## exists to remove.
  let node =
    try:
      parseJson(text)
    except CatchableError as err:
      raise newException(ValueError,
        "unparsable service instance key: " & err.msg)
  if node.kind != JObject:
    raise newException(ValueError,
      "a service instance key must be a JSON object")
  keyFromJson(node)

proc encodeServiceInstanceAttrs*(record: ServiceInstanceRecord): string =
  ## The `attrsJson` of an instance record. Deterministic in field order
  ## because `%*` preserves insertion order, so two writes of one record
  ## produce identical bytes and a reader diffing the store sees only
  ## real change.
  var command = newJArray()
  for part in record.process.command:
    command.add(%part)
  let node = %*{
    "attrsTypeId": ServiceInstanceAttrsTypeId,
    "key": keyToJson(record.key),
    "snapshot": snapshotToJson(record.snapshot),
    "process": {
      "pid": record.process.pid,
      "processIdentity": record.process.processIdentity,
      "workingDir": record.process.workingDir},
    "startedByHolder": record.startedByHolder,
    "startedAtUnix": record.startedAtUnix}
  node["process"]["command"] = command
  $node

proc decodeServiceInstanceAttrs*(address, attrsTypeId, attrsJson: string):
    ServiceInstanceRecord =
  ## The inverse. Raises `ValueError` on anything it cannot decode
  ## EXACTLY; the rebuild turns that into `srrSkippedUndecodable` with
  ## the message, so a record written by a future version is reported by
  ## name rather than read as "no instance here".
  if attrsTypeId != ServiceInstanceAttrsTypeId:
    raise newException(ValueError,
      "service instance record at `" & address & "` carries attrs type `" &
      attrsTypeId & "`; this build reads `" & ServiceInstanceAttrsTypeId &
      "` only")
  let node =
    try:
      parseJson(attrsJson)
    except CatchableError as err:
      raise newException(ValueError,
        "service instance record at `" & address &
        "` has unparsable attrs: " & err.msg)
  if node.kind != JObject:
    raise newException(ValueError,
      "service instance record at `" & address &
      "` has non-object attrs")
  let keyNode = node{"key"}
  if keyNode.isNil or keyNode.kind != JObject:
    raise newException(ValueError,
      "service instance record at `" & address & "` carries no `key`")
  let snapshotNode = node{"snapshot"}
  if snapshotNode.isNil or snapshotNode.kind != JObject:
    raise newException(ValueError,
      "service instance record at `" & address & "` carries no `snapshot`")
  result = ServiceInstanceRecord(
    key: keyFromJson(keyNode),
    address: address,
    snapshot: snapshotFromJson(snapshotNode),
    startedByHolder: node{"startedByHolder"}.getStr(""),
    startedAtUnix: node{"startedAtUnix"}.getBiggestInt(0))
  let processNode = node{"process"}
  if not processNode.isNil and processNode.kind == JObject:
    result.process.pid = processNode{"pid"}.getInt(0)
    result.process.processIdentity =
      processNode{"processIdentity"}.getStr("")
    result.process.workingDir = processNode{"workingDir"}.getStr("")
    let command = processNode{"command"}
    if not command.isNil and command.kind == JArray:
      for part in command:
        result.process.command.add(part.getStr(""))
  # The address the record was STORED under wins over any address inside
  # the payload, and the payload carries none for that reason: two
  # sources for one fact is how a registry starts answering for the
  # wrong instance.
  if serviceInstanceAddress(result.key) != address:
    raise newException(ValueError,
      "service instance record at `" & address &
      "` carries a key whose address is `" &
      serviceInstanceAddress(result.key) &
      "`; the record and its key disagree about which instance it is")

# ---------------------------------------------------------------------------
# Store round-trip.
# ---------------------------------------------------------------------------

proc registryStore*(registry: ServiceInstanceRegistry): StateStore =
  if registry.storeRoot.len == 0:
    raise newException(ServiceRegistryError,
      "a service instance registry needs an explicit state-store root; " &
      "see `serviceStateRoot`'s `storeRoot` note for why it is never " &
      "defaulted")
  openStateStore(registry.storeRoot)

proc probeLiveness*(registry: ServiceInstanceRegistry;
                    processIdentity: string): ServiceInstanceLiveness =
  ## Run the injected probe. A `nil` probe is a REFUSAL rather than an
  ## optimistic `silLive`: see this module's test-double note.
  if registry.probe.isNil:
    raise newException(ServiceRegistryError,
      "a service instance registry needs a process-liveness probe; " &
      "pass `repro_daemon_core/writer_identity.writerLiveness` (the " &
      "daemon does) -- a registry that cannot test liveness would " &
      "either orphan a process or start a second one")
  registry.probe(processIdentity)

proc stateRecordFor(record: ServiceInstanceRecord;
                    holders: Table[string, Time];
                    effectiveDeadline: Option[Time];
                    now: Time): ResourceStateRecord =
  ResourceStateRecord(
    address: record.address,
    typeId: ServiceInstanceTypeId,
    determinism: rdVolatile,
    attrsTypeId: ServiceInstanceAttrsTypeId,
    attrsJson: encodeServiceInstanceAttrs(record),
    dependsOn: @[],
    identity: record.key.identity,
    present: true,
    holders: holders,
    effectiveDeadline: effectiveDeadline,
    lastRenewed: now)

proc holdersOf(entry: ServiceInstanceEntry): seq[string] =
  result = @[]
  for holder in entry.instance.holders:
    result.add(holder.consumerId)
  result.sort()

proc entryFrom(record: ServiceInstanceRecord;
               state: ResourceStateRecord;
               liveness: ServiceInstanceLiveness): ServiceInstanceEntry =
  let recovered = holdersFromStateRecord(state)
  ServiceInstanceEntry(
    record: record,
    instance: runningServiceInstance(record.key, record.snapshot,
      recovered.holders),
    holderRecovery:
    if recovered.mayHaveUnnamedKeepHolder: hrMayHaveUnnamedKeepHolder
      else: hrTotal,
    liveness: liveness)

# ---------------------------------------------------------------------------
# §4.5's rebuild: "A daemon that restarts rebuilds it from the lease records".
# ---------------------------------------------------------------------------

proc rebuildServiceInstanceRegistry*(registry: var ServiceInstanceRegistry):
    ServiceRegistryRebuildReport =
  ## Re-read every instance record in the store and rebuild the in-memory
  ## table. This is the WHOLE of the daemon-restart clause of L7's gate:
  ##
  ##   * "without ORPHANING" — a record whose process is provably dead
  ##     (`silDead`) is removed from the store, so the instance does not
  ##     linger as a registry entry nothing can attach to. A dead process
  ##     cannot be orphaned; a dead RECORD can, and this is what removes
  ##     it.
  ##   * "without DOUBLE-STARTING" — a record whose process is live, or
  ##     whose liveness cannot be established, is KEPT. `silUnknown` is
  ##     kept for the asymmetry `writer_identity.nim` argues: declaring a
  ##     live instance dead would make the next `repro up` materialise a
  ##     second one.
  ##
  ## It is idempotent: running it twice over one store yields the same
  ## table, and the second run reports zero `srrDroppedDeadProcess`
  ## because the first removed those records.
  result = ServiceRegistryRebuildReport(events: @[])
  # The probe is validated BEFORE the store is read, not on the first
  # record that needs it. A registry with no probe over an EMPTY store
  # would otherwise rebuild "successfully" and then refuse on the first
  # instance anyone materialised -- which is the shape of a construct
  # that looks wired and is not.
  discard registry.probeLiveness("")
  registry.entries = initTable[string, ServiceInstanceEntry]()
  let store = registry.registryStore()
  for state in listStateRecords(store):
    if not isServiceInstanceAddress(state.address):
      continue
    if not state.present:
      # A record the reaper has marked destroyed is not a running
      # instance. Removed rather than kept, for the same reason a dead
      # process's record is.
      removeStateRecord(store, state.address)
      result.droppedDead.inc
      result.events.add(ServiceRegistryRebuildEvent(
        address: state.address, kind: srrDroppedDeadProcess,
        liveness: silDead, holderRecovery: hrTotal,
        detail: "the record is marked not present"))
      continue
    let record =
      try:
        decodeServiceInstanceAttrs(state.address, state.attrsTypeId,
          state.attrsJson)
      except CatchableError as err:
        result.skipped.inc
        result.events.add(ServiceRegistryRebuildEvent(
          address: state.address, kind: srrSkippedUndecodable,
          liveness: silUnknown, holderRecovery: hrTotal,
          detail: err.msg))
        continue
    let liveness = registry.probeLiveness(record.process.processIdentity)
    if liveness == silDead:
      removeStateRecord(store, state.address)
      result.droppedDead.inc
      result.events.add(ServiceRegistryRebuildEvent(
        address: state.address, kind: srrDroppedDeadProcess,
        liveness: liveness, holderRecovery: hrTotal,
        detail: "pid " & $record.process.pid &
          " is not the process this instance was materialised as"))
      continue
    let entry = entryFrom(record, state, liveness)
    registry.entries[state.address] = entry
    result.recovered.inc
    if entry.holderRecovery == hrMayHaveUnnamedKeepHolder:
      result.unnamedKeepHolderRisks.inc
    result.events.add(ServiceRegistryRebuildEvent(
      address: state.address, kind: srrRecovered,
      liveness: liveness, holderRecovery: entry.holderRecovery,
      detail:
      (if liveness == silUnknown:
        "liveness could not be established; kept, because declaring a " &
        "live instance dead would double-start it"
      else: "pid " & $record.process.pid & " is still that process") &
      (if entry.holderRecovery == hrMayHaveUnnamedKeepHolder:
        "; the holder set MAY be incomplete (effectiveDeadline is " &
        "none, which a `keep` holder and an empty holder set both " &
        "produce)"
      else: "")))

proc openServiceInstanceRegistry*(storeRoot: string;
    probe: ServiceInstanceLivenessProbe): ServiceInstanceRegistry =
  ## Open the registry at `storeRoot` and rebuild it from the store. The
  ## rebuild report is discarded here; a caller that wants it calls
  ## `rebuildServiceInstanceRegistry` on the result (which is idempotent)
  ## or uses `openServiceInstanceRegistryReporting`.
  result = ServiceInstanceRegistry(storeRoot: storeRoot, probe: probe,
    entries: initTable[string, ServiceInstanceEntry]())
  discard rebuildServiceInstanceRegistry(result)

proc openServiceInstanceRegistryReporting*(storeRoot: string;
    probe: ServiceInstanceLivenessProbe):
    tuple[registry: ServiceInstanceRegistry;
          report: ServiceRegistryRebuildReport] =
  ## The same, keeping the rebuild report. The daemon logs it; a silently
  ## discarded report is how "the registry quietly forgot three
  ## instances" becomes invisible.
  var registry = ServiceInstanceRegistry(storeRoot: storeRoot, probe: probe,
    entries: initTable[string, ServiceInstanceEntry]())
  let report = rebuildServiceInstanceRegistry(registry)
  (registry: registry, report: report)

proc lookupServiceInstance*(registry: ServiceInstanceRegistry;
                            key: ServiceInstanceKey):
    Option[ServiceInstanceEntry] =
  ## The registry lookup §4.5 asks `up` to do: resolve the key, then see
  ## whether an instance is present.
  let address = serviceInstanceAddress(key)
  if registry.entries.hasKey(address):
    some(registry.entries[address])
  else:
    none(ServiceInstanceEntry)

proc registeredServiceInstances*(registry: ServiceInstanceRegistry):
    seq[ServiceInstanceEntry] =
  ## Every entry, in address order. The "exactly one instance" assertion
  ## of L7's gate is a length check over this.
  var addresses: seq[string] = @[]
  for address in registry.entries.keys:
    addresses.add(address)
  addresses.sort()
  for address in addresses:
    result.add(registry.entries[address])

# ---------------------------------------------------------------------------
# Holder bookkeeping. One write funnel, through the real merge.
# ---------------------------------------------------------------------------

proc holderRenewals*(address: string;
                     holders: openArray[ServiceInstanceHolder];
                     now: Time): seq[LeasedDep] =
  ## The authoritative holder set, expressed as the `LeasedDep` list that
  ## `mergeHolderDeadlines` consumes, so persistence runs through the
  ## REAL merge rather than a second copy of the keep-dominates fold.
  ##
  ## The deadline->policy direction is exact rather than approximate: a
  ## holder with NO deadline is a `keep` holder, and a dated holder
  ## becomes `delayed(deadline - now)`, which `deadlineFrom` maps back to
  ## `now + (deadline - now)` — the same absolute deadline, including
  ## when it is already in the past. So a round trip through the merge
  ## preserves every dated holder's instant and every `keep` holder's
  ## pinning, and the one thing it loses is the `keep` holder's NAME,
  ## which is §4.5's recorded defect and not this proc's.
  result = @[]
  for holder in holders:
    if holder.deadline.isNone:
      result.add(leased(address, holder.consumerId, keep()))
    else:
      result.add(leased(address, holder.consumerId,
        delayed(holder.deadline.get - now)))

proc sortedHolders(holders: openArray[ServiceInstanceHolder]):
    seq[ServiceInstanceHolder] =
  result = @holders
  result.sort(proc (a, b: ServiceInstanceHolder): int =
    cmp(a.consumerId, b.consumerId))

proc persistEntry(registry: var ServiceInstanceRegistry;
                  record: ServiceInstanceRecord;
                  holders: openArray[ServiceInstanceHolder];
                  holderRecovery: HolderRecovery;
                  liveness: ServiceInstanceLiveness;
                  now: Time): ServiceInstanceEntry =
  ## Install `holders` as the entry's AUTHORITATIVE holder set and
  ## persist the record.
  ##
  ## THE TWO HOLDER SETS ARE NOT THE SAME SET, AND THAT IS §4.5's WHOLE
  ## POINT. The in-memory set is complete while this daemon runs. The
  ## PERSISTED set is what `mergeHolderDeadlines` can carry, which drops
  ## a `keep` holder's name — "it pins with no expiry ... rather than
  ## storing a bogus deadline". Deriving the in-memory set from the
  ## record would therefore make a `keep` holder invisible the moment it
  ## was taken, and §4.5's three-holders-one-instance property would be
  ## unmeasurable under the `keep` default D-SS5 chose. So the record is
  ## written from the in-memory set and never read back to produce it,
  ## except by the rebuild — which is exactly where §4.5 says the loss
  ## happens.
  let ordered = sortedHolders(holders)
  let merged = mergeHolderDeadlines(initTable[string, Time](),
    holderRenewals(record.address, ordered, now), now)
  let state = stateRecordFor(record, merged.holders, merged.effective, now)
  writeStateRecord(registry.registryStore(), state)
  result = ServiceInstanceEntry(
    record: record,
    instance: runningServiceInstance(record.key, record.snapshot, ordered),
    holderRecovery: holderRecovery,
    liveness: liveness)
  registry.entries[record.address] = result

proc recordMaterialisedInstance*(registry: var ServiceInstanceRegistry;
                                 key: ServiceInstanceKey;
                                 snapshot: ServiceInterfaceSnapshot;
                                 process: ServiceInstanceProcess;
                                 holderId: string;
                                 policy: LeasePolicy;
                                 now: Time = getTime()):
    ServiceInstanceEntry =
  ## Register the instance a `scoMaterialise` decision asked the caller to
  ## start, with `holderId` as its first holder.
  ##
  ## SEPARATE FROM `convergeServiceInstance` BECAUSE THE PROCESS DOES NOT
  ## EXIST YET WHEN THE DECISION IS MADE. Folding the two would make the
  ## registry start processes, which is the daemon's job and not
  ## `repro_resources`'s; and it would make the decision function
  ## effectful, which is what L6 built its purity argument on.
  ##
  ## THE REFUSAL BELOW, AND WHAT IT ACTUALLY PREVENTS. It used to say
  ## that an instance with no holder "would be reaped by the next
  ## sweep". That was false, and not only because the sweep could not
  ## reap an instance record at all before the reap handler above
  ## existed: an empty holder set makes `mergeHolderDeadlines` produce
  ## `effective = none`, and `reaper.isReapable` NEVER reaps a `none`
  ## record. The truth is the opposite and is a stronger reason to
  ## refuse — a holder-less instance would be UNREAPABLE AND PERMANENT.
  ##
  ## It cannot be made reapable from here either, and that is the filed
  ## rule-3 gap rather than an omission: `none` means "no dated holder,
  ## or at least one `keep` holder pinning this with no expiry", the
  ## record carries nothing that separates the two, and teaching the
  ## sweep to reap `none` would destroy every `keep`-pinned state in the
  ## whole lease lane. So the record is refused at the only point where
  ## the distinction is still known — here, where the caller either has
  ## a holder or does not.
  if holderId.len == 0:
    raise newException(ServiceRegistryError,
      "an instance must be registered with the holder that materialised " &
      "it; §4.5 is `one holder per consuming project`, and an instance " &
      "with no holder would be UNREAPABLE: its record's " &
      "effectiveDeadline is `none`, which the reaper never selects and " &
      "which is indistinguishable from a `keep` pin, so §4.5's `an " &
      "instance is reaped when its last lease lapses` could never fire " &
      "for it and the process would outlive every consumer")
  let address = serviceInstanceAddress(key)
  let record = ServiceInstanceRecord(
    key: key, address: address, snapshot: snapshot, process: process,
    startedByHolder: holderId, startedAtUnix: now.toUnix)
  registry.persistEntry(record,
    @[ServiceInstanceHolder(consumerId: holderId,
      deadline: deadlineFrom(policy, now))],
    hrTotal, silLive, now)

proc forgetServiceInstanceEntry*(registry: var ServiceInstanceRegistry;
                                 address: string) =
  ## Drop the IN-MEMORY entry only, leaving the store record alone.
  ##
  ## SPLIT OUT OF `forgetServiceInstance` FOR ONE CALLER: the reap
  ## handler. A sweep removes the record from the store IT IS SWEEPING —
  ## which is the store it was handed, not a store re-derived from
  ## `registry.storeRoot` — so a handler that also removed the record
  ## would be removing it from a second, possibly different, place. The
  ## handler therefore drops the entry through this proc and lets the
  ## sweep own the record. Keeping it a named proc rather than an inline
  ## `entries.del` keeps the in-memory half a single funnel: a future
  ## entry-side invariant has exactly one place to live.
  registry.entries.del(address)

proc forgetServiceInstance*(registry: var ServiceInstanceRegistry;
                            address: string) =
  ## Remove the instance from the registry AND from the store. Called
  ## after the caller has stopped the process a `srlReleasedLastHolder`
  ## decision named.
  registry.forgetServiceInstanceEntry(address)
  removeStateRecord(registry.registryStore(), address)

# ---------------------------------------------------------------------------
# §4.5 — CONVERGE.
# ---------------------------------------------------------------------------

proc unknownHolderSentence(address: string;
                           known: seq[string]): string =
  if known.len == 0:
    "the running instance at `" & address & "` has an UNRECOVERABLE " &
    "holder set, and this daemon can name NO holder of it."
  else:
    var named: seq[string] = @[]
    for holder in known:
      named.add("`" & holder & "`")
    "the running instance at `" & address & "` has an UNRECOVERABLE " &
    "holder set. The holders this daemon CAN name are " &
    named.join(", ") & "; there may be others it cannot."

proc convergeServiceInstance*(registry: var ServiceInstanceRegistry;
                              key: ServiceInstanceKey;
                              snapshot: ServiceInterfaceSnapshot;
                              holderId: string;
                              policy: LeasePolicy = keep();
                              now: Time = getTime();
                              replace = false;
                              force = false): ServiceConvergeDecision =
  ## §4.5's converge: "`up` resolves the key, attaches if an instance is
  ## present and materialises it otherwise."
  ##
  ## ORDER OF DECISION, and it is not interchangeable:
  ##
  ##   1. no instance present -> `scoMaterialise`. `--replace` does NOT
  ##      refuse here and does not need to: there is nothing to take
  ##      over, and refusing would make `repro up --replace` unusable as
  ##      a habit.
  ##   2. `--replace` asked -> the takeover path, which tests §4.5 rule 1
  ##      FIRST (unrecoverable holder set) and only then consults
  ##      `replaceDecision`. Reversing those two would let a recovered-
  ##      but-empty holder set and an unrecoverable one take the same
  ##      branch, which is precisely the conflation rule 1 forbids.
  ##   3. otherwise -> L6's `attachDecision`, and the holder is taken on
  ##      both attach outcomes and on NEITHER refusal.
  ##
  ## THE HOLDER IS NOT TAKEN ON A REFUSAL. A refusal means the consumer
  ## did not get a usable handle, so recording it as a holder would make
  ## `repro down` in that project release an instance it never used, and
  ## would make `--replace` elsewhere refuse on its account.
  if holderId.len == 0:
    raise newException(ServiceRegistryError,
      "converge needs the consuming project's holder id; see " &
      "`serviceLeaseHolderId`")
  let address = serviceInstanceAddress(key)
  result = ServiceConvergeDecision(address: address, holderId: holderId,
    holderRecovery: hrTotal, holdersKnown: @[])
  let found = registry.lookupServiceInstance(key)
  if found.isNone:
    result.outcome = scoMaterialise
    result.diagnostic = ""
    result.hadInstance = false
    return
  let entry = found.get
  result.hadInstance = true
  result.holderRecovery = entry.holderRecovery
  result.holdersKnown = entry.holdersOf()
  if replace:
    if entry.holderRecovery == hrMayHaveUnnamedKeepHolder:
      let shared = unknownHolderSentence(address, result.holdersKnown)
      if force:
        # §4.5 rule 2: a `--force` here must NOT read as "no other
        # holders". This sentence and the recoverable path's are
        # deliberately different texts.
        result.outcome = scoForcedOverOtherHolders
        result.diagnostic =
          "`--force`: replacing anyway, and HOLDERS MAY EXIST WHICH THIS " &
          "DAEMON CANNOT NAME. " & shared &
          " A `keep` holder's consumer id is written nowhere in a lease " &
          "record, so this is not a claim that nobody else holds it -- " &
          "only that nobody else is recoverable. " &
          "Shared-Development-Services.md §4.5 rule 2."
      else:
        result.outcome = scoRefuseUnknownHolders
        result.diagnostic =
          "refusing `repro up --replace`: " & shared &
          " Stopping it could destroy the state of a project this daemon " &
          "merely failed to remember. Shared-Development-Services.md " &
          "§4.5 rule 1: \"An unrecoverable holder set is a REFUSAL, never " &
          "a proceed.\" Pass `--force` to replace it anyway, in the " &
          "knowledge that holders may exist which cannot be named."
      return
    result.replace = replaceDecision(entry.instance, holderId, now, force)
    result.diagnostic = result.replace.diagnostic
    case result.replace.outcome
    of sroReplace: result.outcome = scoReplace
    of sroRefuseOtherHolders: result.outcome = scoRefuseOtherHolders
    of sroForcedOverOtherHolders:
      result.outcome = scoForcedOverOtherHolders
    return
  result.attach = attachDecision(entry.instance, snapshot)
  result.diagnostic = result.attach.diagnostic
  case result.attach.outcome
  of saoAttachSilently: result.outcome = scoAttachSilently
  of saoAttachWithWarning: result.outcome = scoAttachWithWarning
  of saoRefuseMajor:
    result.outcome = scoRefuseMajor
    return
  # Attached: take this consumer's lease on the instance. The holder set
  # is the entry's own -- the authoritative one -- with this consumer
  # added or renewed, so attaching never drops another project's
  # reference and never resurrects one the record could not carry.
  var holders: seq[ServiceInstanceHolder] = @[]
  for holder in entry.instance.holders:
    if holder.consumerId != holderId:
      holders.add(holder)
  holders.add(ServiceInstanceHolder(consumerId: holderId,
    deadline: deadlineFrom(policy, now)))
  let updated = registry.persistEntry(entry.record, holders,
    entry.holderRecovery, entry.liveness, now)
  result.holdersKnown = updated.holdersOf()
  result.holderRecovery = updated.holderRecovery

# ---------------------------------------------------------------------------
# §4.5 — RELEASE.
# ---------------------------------------------------------------------------

proc releaseServiceInstance*(registry: var ServiceInstanceRegistry;
                             key: ServiceInstanceKey;
                             holderId: string;
                             now: Time = getTime()):
    ServiceReleaseDecision =
  ## §4.5: "`repro down` in one project drops a reference rather than
  ## stopping an instance another project is using, and an instance is
  ## reaped when its last lease lapses."
  ##
  ## THAT CLAUSE HAS TWO PATHS AND THIS IS ONLY ONE OF THEM. This is the
  ## explicit one: the last holder runs `repro down` and says so. The
  ## other is the LEASE LAPSING with no `repro down` at all — the orphan
  ## case, which is what happens when a consumer is killed — and it is
  ## enforced by the reap SWEEP through the typed handler at the bottom
  ## of this module, not by this proc. Both are required; neither
  ## substitutes for the other, and for a while only this one existed,
  ## which made the quoted clause false for exactly the case it matters
  ## most in.
  ##
  ## The caller STOPS the process on `srlReleasedLastHolder` and then
  ## calls `forgetServiceInstance`. It is two steps for the same reason
  ## materialise is: stopping a process is not `repro_resources`' job.
  if holderId.len == 0:
    raise newException(ServiceRegistryError,
      "release needs the consuming project's holder id; see " &
      "`serviceLeaseHolderId`")
  let address = serviceInstanceAddress(key)
  result = ServiceReleaseDecision(address: address, holderId: holderId,
    holderRecovery: hrTotal, remainingHolders: @[])
  let found = registry.lookupServiceInstance(key)
  if found.isNone:
    result.outcome = srlNoInstance
    result.diagnostic =
      "no instance is registered at `" & address &
      "`, so there is no holder to drop. Nothing was stopped."
    return
  let entry = found.get
  result.record = entry.record
  result.holderRecovery = entry.holderRecovery
  let known = entry.holdersOf()
  if entry.holderRecovery == hrMayHaveUnnamedKeepHolder:
    # §4.5 rule 1's REASONING, applied to release rather than quoted as
    # its clause: the rule names `--replace`, and the damage it forbids
    # -- destroying the state of a project the daemon failed to remember
    # -- is reached identically by concluding "I was the last holder"
    # from a holder set that could not be enumerated. So the uncertainty
    # is named and the instance is left running.
    result.outcome = srlRefuseUnknownHolders
    result.remainingHolders = known
    result.diagnostic =
      "refusing to decide whether this was the last holder of `" &
      address & "`: " & unknownHolderSentence(address, known) &
      " This project's own reference is NOT dropped either, because " &
      "dropping it without being able to count the rest would make the " &
      "next release believe it was the last. Shared-Development-" &
      "Services.md §4.5 rule 1 is about `--replace`; this is the same " &
      "damage reached through `repro down`, so the same answer applies: " &
      "name the uncertainty rather than proceed."
    return
  if known.find(holderId) < 0:
    result.outcome = srlNotHeld
    result.remainingHolders = known
    var named: seq[string] = @[]
    for holder in known:
      named.add("`" & holder & "`")
    result.diagnostic =
      "`" & holderId & "` does not hold the instance at `" & address &
      "`" &
      (if known.len == 0: ", which has no named holders at all."
        else: "; its holders are " & named.join(", ") & ".") &
      " Nothing was dropped and nothing was stopped."
    return
  var remaining: seq[ServiceInstanceHolder] = @[]
  for holder in entry.instance.holders:
    if holder.consumerId != holderId:
      remaining.add(holder)
  if remaining.len == 0:
    # The last reference. The record is LEFT IN PLACE here and removed by
    # `forgetServiceInstance` after the caller has stopped the process:
    # removing it first would, if the stop then failed, leave a running
    # process no registry entry names -- the orphan the rebuild clause
    # exists to prevent.
    result.outcome = srlReleasedLastHolder
    result.diagnostic = ""
    result.remainingHolders = @[]
    return
  let updated = registry.persistEntry(entry.record, remaining,
    entry.holderRecovery, entry.liveness, now)
  result.outcome = srlDroppedHolder
  result.diagnostic = ""
  result.remainingHolders = updated.holdersOf()

# ---------------------------------------------------------------------------
# Small reporting helpers a caller has no excuse to re-derive.
# ---------------------------------------------------------------------------

proc convergeAttached*(outcome: ServiceConvergeOutcome): bool =
  ## Whether the consumer ended up with a usable handle on the EXISTING
  ## instance. Exposed as one proc so the CLI and the daemon cannot
  ## disagree about which outcomes count as attached.
  outcome in {scoAttachSilently, scoAttachWithWarning}

proc convergeRefused*(outcome: ServiceConvergeOutcome): bool =
  ## Whether the converge refused. `scoForcedOverOtherHolders` is NOT a
  ## refusal -- it proceeded -- and `scoMaterialise` is not either.
  outcome in {scoRefuseMajor, scoRefuseOtherHolders,
              scoRefuseUnknownHolders}

proc outcomeWord*(outcome: ServiceConvergeOutcome): string =
  ## The outcome's wire/report spelling, derived from the enum name so
  ## the two cannot drift.
  ($outcome)[3 .. ^1]

proc outcomeWord*(outcome: ServiceReleaseOutcome): string =
  ($outcome)[3 .. ^1]

proc parseConvergeOutcome*(word: string): ServiceConvergeOutcome =
  ## The inverse, for the wire. An unknown word is a named refusal rather
  ## than a default outcome: defaulting would turn a protocol skew into a
  ## silent "materialise", which starts a second instance.
  for candidate in ServiceConvergeOutcome:
    if outcomeWord(candidate) == word:
      return candidate
  raise newException(ServiceRegistryError,
    "unknown service converge outcome `" & word & "`")

proc parseReleaseOutcome*(word: string): ServiceReleaseOutcome =
  for candidate in ServiceReleaseOutcome:
    if outcomeWord(candidate) == word:
      return candidate
  raise newException(ServiceRegistryError,
    "unknown service release outcome `" & word & "`")

# ---------------------------------------------------------------------------
# §4.5's "an instance is reaped when its last lease lapses" — THE REAP PATH.
#
# §4.5 gives an instance the lease lane's lifetime, and this module persists
# it as a `ResourceStateRecord` in the SAME store the lease reaper sweeps,
# deliberately (see `serviceInstanceStoreRoot`: "two roots would mean the
# reaper swept a store the registry did not read"). The clause is therefore
# the sweep's to honour, and the sweep reaches this type through
# `reaper.nim`'s typed handler hook.
#
# ## WHY A HANDLER AND NOT A REGISTERED RESOURCE TYPE
#
# The other way to make the sweep able to reap an instance record is to
# give `reprobuild.service-instance` what the generic path asks for: an
# attrs marshaller under `ServiceInstanceAttrsTypeId` and a
# `ResourceProviderDef` whose driver `observe`s and `apply(rakDestroy)`es
# it. REJECTED, for three reasons that are not stylistic:
#
#   1. it would make a service instance a PROVIDER-VISIBLE RESOURCE TYPE.
#      `marshalAttrs`/`unmarshalAttrs` dispatch on the extension registry
#      every out-of-tree resource provider links, which is exactly why
#      this module's header says the attrs deliberately do NOT travel
#      through them. Registering there publishes an internal record shape
#      to every provider in the ecosystem.
#   2. the driver would have to carry the DAEMON's capability. Destroying
#      an instance is "signal the recorded pid, wait, escalate" plus
#      "forget the registry entry" — a process table and a live registry.
#      Putting that behind `lookupResourceProvider` makes it reachable
#      from any process that merely links `repro_resources`, including a
#      reconcile in a project directory, which is the opposite of §4.5's
#      "the daemon holds the registry".
#   3. `observe` has no honest answer. A provider `observe` reports a
#      DIGEST of realised state; an instance's realised state is "pid P
#      started at T is still that process", which is what the injected
#      liveness probe answers and what a driver would have to re-derive.
#
# The handler hook costs one hook in `reaper.nim` and leaves the generic
# lane untouched.
#
# ## WHY THIS LIBRARY REGISTERS A DECLINING HANDLER
#
# Because the alternative is the generic path, and the generic path's
# refusal is a misleading sentence. Without any handler, a sweep in a
# process that cannot stop a process reconstructs the record and raises
# `no attribute marshaller registered for resource typeId
# 'reprobuild.service-instance.v1' … import the producer's lifted
# interface`, which names a remedy that does not exist and cannot exist.
# A declining handler says what is actually true: this record is reaped
# through the instance registry, this process has none installed, the
# process was NOT stopped, and the record is kept rather than removed —
# because removing it is how a live instance becomes one nothing names.
# ---------------------------------------------------------------------------

proc serviceInstanceReapDecline*(rec: ResourceStateRecord):
    ReapHandlerOutcome =
  ## The handler every process importing this module starts with: DECLINE,
  ## by name. `repro_daemon_core/instance_registry` replaces it in the
  ## daemon with the one that really stops the instance, and restores this
  ## one afterwards.
  let pidText =
    try:
      let record = decodeServiceInstanceAttrs(rec.address, rec.attrsTypeId,
        rec.attrsJson)
      "pid " & $record.process.pid & " (" &
        record.process.command.join(" ") & ")"
    except CatchableError as err:
      "an instance whose record could not even be decoded (" & err.msg & ")"
  ReapHandlerOutcome(destroyed: false, wasPresent: true,
    detail: "`" & rec.address & "` is a shared service INSTANCE record. " &
      "§4.5 reaps one through the instance registry, which is the only " &
      "thing that knows how to stop its process, and THIS process has no " &
      "instance-reap handler installed (the daemon installs it: see " &
      "`repro_daemon_core/instance_registry.installServiceInstanceReapHandler`). " &
      pidText & " was NOT stopped and the record is KEPT, because removing " &
      "it would leave a running instance that nothing names and that the " &
      "next `repro up` would double-start.")

proc installDecliningServiceInstanceReapHandler*() =
  ## Put the declining handler back. Public because the daemon's
  ## installer restores it when its tick is over, and because a test that
  ## installs the real handler has to be able to undo that.
  registerReapHandler(ServiceInstanceTypeId, serviceInstanceReapDecline)

# AT MODULE INIT, for the same reason `instance.nim`'s provider registry is
# populated at module init by whoever defines a type: the record shape and
# the thing that can interpret it ship together. A process that links this
# module can WRITE an instance record, so from that moment a sweep in that
# process must have something honest to say about one.
installDecliningServiceInstanceReapHandler()
