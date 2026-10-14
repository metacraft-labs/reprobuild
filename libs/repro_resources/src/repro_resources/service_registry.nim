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
    scoRefuseStaleLift
      ## §4.3's SAME-GENERATION PRECONDITION: the owner's lifted
      ## artifact is older than the owner's definition. Appended after
      ## the §4.3 row values so no existing ordinal moves; the wire
      ## carries `outcomeWord`, which is derived from the NAME, so a
      ## client built against a revision that lacks this value reports
      ## an unknown outcome word by name instead of reading some other
      ## outcome -- which is `parseConvergeOutcome`'s whole point.
    scoRefuseUnknownProvenance
      ## The precondition's other failure: the correspondence could not
      ## be established at all. Distinct from `scoRefuseStaleLift` for
      ## the reason `saoRefuseUnknownProvenance` is distinct from
      ## `saoRefuseStaleLift`.
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
    droppedDeadPid*: int
      ## Non-zero when an instance WAS registered at this key but its
      ## process probed `silDead`, so converge dropped the record and
      ## decided `scoMaterialise` as if nothing were there. The pid is
      ## carried so a caller that cannot materialise -- a resolver's
      ## command-less request -- can name the process that died instead
      ## of only saying that nothing is running.
    droppedDeadDetail*: string
      ## The sentence saying so, empty exactly when `droppedDeadPid` is 0.
      ## A field of its own rather than `diagnostic`, because
      ## `diagnostic` is asserted EMPTY for `scoMaterialise`: a
      ## materialise that replaces a dead record still has nothing to
      ## refuse or warn about, it only has something to report.

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
                              generation: ServiceArtifactGenerationCheck;
                              policy: LeasePolicy = keep();
                              now: Time = getTime();
                              replace = false;
                              force = false): ServiceConvergeDecision =
  ## §4.5's converge: "`up` resolves the key, attaches if an instance is
  ## present and materialises it otherwise."
  ##
  ## ORDER OF DECISION, and it is not interchangeable:
  ##
  ##   0. an instance is registered but its process probes `silDead` ->
  ##      the record is dropped and this is step 1. See the note at the
  ##      probe below.
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
  # IS THERE A PROCESS TO ATTACH TO. Asked before `--replace` and before
  # `attachDecision`, through the registry's injected probe -- the same
  # one the rebuild uses -- and not through a `kill -0` of our own. The
  # daemon spawns instances detached and never waits on them, so a dead
  # instance is an unreaped ZOMBIE: its pid, `/proc/<pid>/stat` and start
  # time are all still there and `kill -0` succeeds on it. Only the real
  # probe's `waitpid(WNOHANG)` step can tell, and it reaps the corpse as
  # it answers.
  #
  # Without this, liveness was re-evaluated only by a REBUILD, so for the
  # rest of a daemon's lifetime a dead shared instance kept answering
  # `AttachSilently` and the consumer waited out the service's whole
  # declared readiness timeout. See reprobuild-pm issue
  # `2026-10-13-attach-succeeds-against-a-shared-instance-whose-process-
  # is-a-zombie.md`.
  #
  # Only `silDead` drops the record. `silUnknown` proceeds exactly as
  # `silLive` does, for the asymmetry the rebuild keeps: declaring a live
  # instance dead would make this converge materialise a second one.
  #
  # The drop applies with or without `--replace`: there is nothing left
  # to take over, so decision step 1's reasoning ("no instance present")
  # is the one that holds.
  if registry.probeLiveness(entry.record.process.processIdentity) ==
      silDead:
    registry.forgetServiceInstance(address)
    result.outcome = scoMaterialise
    result.diagnostic = ""
    result.hadInstance = false
    result.droppedDeadPid = entry.record.process.pid
    # Worded to follow "no instance is running at `<address>`", which is
    # where the daemon's command-less refusal appends it.
    result.droppedDeadDetail =
      "the instance registered there (pid " & $entry.record.process.pid &
      ") had exited, and its record was dropped"
    return
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
  result.attach = attachDecision(entry.instance, snapshot, generation)
  result.diagnostic = result.attach.diagnostic
  case result.attach.outcome
  of saoAttachSilently: result.outcome = scoAttachSilently
  of saoAttachWithWarning: result.outcome = scoAttachWithWarning
  of saoRefuseMajor:
    result.outcome = scoRefuseMajor
    return
  of saoRefuseStaleLift:
    # §4.3's precondition. THE HOLDER IS NOT TAKEN, for the same reason
    # it is not taken on a major refusal: the consumer did not get a
    # usable handle. Said as its own branch rather than folded into the
    # major one so this `case` stays exhaustive by compiler check --
    # which is what makes a future outcome impossible to add without
    # deciding what the registry does with it.
    result.outcome = scoRefuseStaleLift
    return
  of saoRefuseUnknownProvenance:
    result.outcome = scoRefuseUnknownProvenance
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

proc generationToJson(check: ServiceArtifactGenerationCheck): JsonNode =
  %*{"generation": $check.generation,
     "artifactPath": check.artifactPath,
     "ownerPackage": check.ownerPackage,
     "ownerProject": check.ownerProject,
     "recordedIdentity": check.recordedIdentity,
     "currentIdentity": check.currentIdentity,
     "movedSources": check.movedSources,
     "detail": check.detail}

proc encodeServiceArtifactGenerationCheck*(
    check: ServiceArtifactGenerationCheck): string =
  ## §4.3's precondition answer, as wire JSON, for the daemon converge
  ## request. ONE codec, like the snapshot's, so the answer a client
  ## established and the answer the daemon decides on cannot be two
  ## different things.
  $generationToJson(check)

proc decodeServiceArtifactGenerationCheck*(text: string):
    ServiceArtifactGenerationCheck =
  ## The inverse. EVERY failure mode yields `sagUnknownProvenance`, with
  ## a `detail` saying which, and that is the load-bearing decision in
  ## this proc:
  ##
  ##   * an EMPTY string -- which is what a request body written by a
  ##     build predating this field decodes to, and what a caller that
  ##     forgot the field sends;
  ##   * unparsable JSON, a non-object, or a `generation` word this
  ##     build does not know.
  ##
  ## None of them may yield `sagFresh`. A wire-compatibility default of
  ## "fresh" would make §4.3's precondition disappear the moment a
  ## client and a daemon were built from different revisions -- the
  ## silent attach, re-introduced by the codec rather than by the
  ## policy. It is NOT raised as an error either: a refusal naming the
  ## re-lift is a decision the consumer can act on, and an exception
  ## would surface as "the daemon failed" rather than "your owner's
  ## artifact is not trustworthy".
  result = ServiceArtifactGenerationCheck(
    generation: sagUnknownProvenance, movedSources: @[])
  if text.len == 0:
    result.detail =
      "The converge request carried no artifact-generation answer at " &
      "all, which is what a client built before " &
      "Shared-Development-Services.md §4.3's same-generation " &
      "precondition sends. It is read as UNESTABLISHED rather than as " &
      "fresh, on purpose."
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError as err:
    result.detail = "The artifact-generation answer on the converge " &
      "request is unparsable (" & err.msg & "), so nothing was established."
    return
  if node.kind != JObject:
    result.detail = "The artifact-generation answer on the converge " &
      "request is not a JSON object, so nothing was established."
    return
  result.artifactPath = node{"artifactPath"}.getStr("")
  result.ownerPackage = node{"ownerPackage"}.getStr("")
  result.ownerProject = node{"ownerProject"}.getStr("")
  result.recordedIdentity = node{"recordedIdentity"}.getStr("")
  result.currentIdentity = node{"currentIdentity"}.getStr("")
  result.detail = node{"detail"}.getStr("")
  let moved = node{"movedSources"}
  if not moved.isNil and moved.kind == JArray:
    for item in moved:
      result.movedSources.add(item.getStr(""))
  let word = node{"generation"}.getStr("")
  var matched = false
  for candidate in ServiceArtifactGeneration:
    if $candidate == word:
      result.generation = candidate
      matched = true
      break
  if not matched:
    result.generation = sagUnknownProvenance
    result.detail =
      "The converge request names artifact generation `" & word &
      "`, which this build does not know; read as UNESTABLISHED rather " &
      "than as fresh." &
      (if result.detail.len > 0: " (" & result.detail & ")" else: "")

proc convergeRefused*(outcome: ServiceConvergeOutcome): bool =
  ## Whether the converge refused. `scoForcedOverOtherHolders` is NOT a
  ## refusal -- it proceeded -- and `scoMaterialise` is not either.
  outcome in {scoRefuseMajor, scoRefuseStaleLift,
              scoRefuseUnknownProvenance, scoRefuseOtherHolders,
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

# ---------------------------------------------------------------------------
# Shared-Development-Services L8 — REGISTRATIONS, and the values the
# instance MINTS for them.
#
# §7 settles the data path and this section is that settlement, built:
#
#   "A per-consumer OIDC client identifier does not exist until the
#    instance has registered the application against a running issuer.
#    That is not late-bound configuration -- nobody *contributes* it --
#    but it is not a new category either: it is a **resource
#    attribute**."
#
# So: one REGISTRATION per contributed member, each carrying the
# identifier the instance minted for it. The member set is configuration
# and is already folded by the time this runs (§5's contribution point);
# the identifier is computed when the registration reconciles.
#
# WHAT IS IMPLEMENTED HERE AND WHAT IS NOT, said plainly. The MINTER is
# injected. This repository contains no Zitadel provider and no OIDC
# client, so the thing that really calls an issuer's management API does
# not exist and is not L8's to write -- L9 owns the shared identity
# provider. What is implemented is the LANE and its hard property:
# mint-once, persist, and hand back byte-identical identifiers when a
# second consumer arrives. That property is the one the gate names, and
# it is the one that cannot be bolted on afterwards: "re-registering an
# OIDC client mints a new client id and silently invalidates whatever a
# developer configured last week".
#
# A SEPARATE STORE RECORD, not a field on the instance record, and the
# reason is who writes what. The instance record is the DAEMON's: it
# carries the pid and the process identity and is rewritten on every
# converge. The registrations are the CONSUMER's reconcile, run from the
# CLI after the daemon has answered that the instance is live. Two
# writers on one record is a race; two records keyed by the same
# instance address is not.
#
# KEYED BY THE INSTANCE, SO THE IDENTIFIERS SURVIVE A RESTART. A
# `stable` identity exists so that durable state survives (§4.2), and a
# minted client id IS that state as far as a consumer is concerned. So
# the record outlives any one process and a new instance under the same
# key reuses it. That is deliberate and it is the whole point; a record
# keyed by pid would re-mint on every `repro up`.
# ---------------------------------------------------------------------------

const
  ServiceRegistrationsTypeId* = "reprobuild.service-registrations"
  ServiceRegistrationsAttrsTypeId* = "reprobuild.service-registrations.v1"
  ServiceRegistrationsAddressSuffix* = "/registrations"
  MintedProvenanceField* = "provenance"
    ## The per-row provenance key, in BOTH documents that carry a minted
    ## identifier: this record's attrs JSON and the dev session's
    ## `shared-instance-registrations.json`. One spelling, bound here,
    ## for `RegistrationAddressSuffix`'s reason -- an invariant
    ## maintained by a sentence is not an invariant.
  InstanceAttributesField* = "instanceAttributes"
    ## Shared-Development-Services §7.3 -- the key the INSTANCE's own
    ## computed attributes live under, in the same two documents, for the
    ## same reason. §7.3's decision is that the issuer URL "travels the
    ## SAME lane as the minted id", and a lane is a store record, a
    ## session document and a point of use; this is the key it occupies
    ## in the first two.

type
  RegistrarProvenance* = enum
    ## Shared-Development-Services §7.2 — WHERE A MINTED IDENTIFIER CAME
    ## FROM, carried with the value rather than inferred from its shape.
    ##
    ## §7.2's defect: the CLI's development registrar derives an id from
    ## `blake3DomainDigest(...)[0 ..< 24]`, and the result is
    ## "indistinguishable, at the point of use, from an id a real issuer
    ## minted. A consumer receives a well-formed identifier that no
    ## issuer has ever heard of, and the failure arrives later, somewhere
    ## else, as an authentication error." A naming convention would not
    ## fix it -- an id is an opaque token and a consumer must not parse
    ## one -- so the fact travels BESIDE the value, like §4.3's
    ## provenance precondition.
    ##
    ## DECLARED HERE, IN THE MODULE THAT OWNS THE DURABLE ROW, and
    ## re-exported by `readiness_edge.nim` where it used to live. The
    ## move is L9 F5's: a stamp that exists only in the process that
    ## minted the value cannot survive a crossing into another project's
    ## session, so `ServiceRegistration` has to carry it -- and
    ## `readiness_edge` already imports this module, so the enum could
    ## not stay there without a cycle. Every existing `import
    ## repro_resources/readiness_edge` still sees the three words,
    ## because that module exports them.
    rprUnstamped = "unstamped"
      ## No registrar claimed this value. Either it was recorded with no
      ## registrar installed, or it was read back from a record written
      ## by a build that predates this field. NEVER read as either of the
      ## other two: `readIssuerMintedResourceAttribute` refuses it, and
      ## so does the `@issuer-minted:` argv token.
    rprDevelopment = "development"
      ## Produced offline, without an issuer. Legitimate -- it is the
      ## default and §7.2 keeps it ("It is the SILENCE that is wrong, not
      ## the fallback") -- and refusable by a consumer that needs the
      ## real thing.
    rprIssuer = "issuer"
      ## The issuer minted it. Reprobuild cannot VERIFY this and does not
      ## pretend to: it is the claim of the project-supplied registrar
      ## that was installed, and it is the claim this library refuses to
      ## let its OWN development registrar make.

proc parseRegistrarProvenance*(word: string): RegistrarProvenance =
  ## The ONE decode of a provenance word, for every document that
  ## carries one.
  ##
  ## AN UNKNOWN WORD IS `unstamped`, NOT A GUESS AND NOT A PARSE
  ## FAILURE. A word this build cannot read is a claim it cannot
  ## evaluate, and the one answer it must not reach for is `issuer`;
  ## `readinessOk` and `serviceCompletionRule` take the same side for the
  ## same reason. The row still resolves through `@minted:`, so a newer
  ## writer cannot break an older reader's offline path.
  ##
  ## AN ABSENT KEY ARRIVES HERE AS `""`, which is also `unstamped` --
  ## the truth about a row written by a build that predates the field.
  result = rprUnstamped
  for candidate in RegistrarProvenance:
    if $candidate == word:
      return candidate

type
  ServiceRegistration* = object
    ## One contributed member, registered, with what the instance minted.
    member*: string
      ## The member as the contribution point folded it. The IDENTITY of
      ## a registration: a re-reconcile matches on this and nothing else,
      ## which is what makes mint-once observable.
    contributor*: string
      ## The package that contributed the member (§5's attribution).
    mintedId*: string
      ## The value the instance minted. Never regenerated for a member
      ## that already has one AND whose `registrar` still matches.
    mintedAtUnix*: int64
    registrar*: string
      ## WHICH REGISTRAR minted it — Shared-Development-Services §7.2.
      ##
      ## It is part of the reuse key, not decoration, and that is the
      ## point. Without it, a row minted offline by the development
      ## registrar is REUSED BYTE FOR BYTE on the next run even when a
      ## real issuer's registrar is now installed, and the consumer then
      ## receives a locally derived digest carrying the issuer's
      ## provenance stamp: §7.2's substitution, reconstructed inside the
      ## fix for it. A row written before this field exists decodes as
      ## `""`, which matches no named registrar and is therefore
      ## re-minted once, by whoever is installed.
    provenance*: RegistrarProvenance
      ## WHAT THE REGISTRAR THAT MINTED IT CLAIMED — §7.2, made DURABLE
      ## by L9 F5.
      ##
      ## NOT DERIVABLE FROM `registrar`, and that is the whole reason it
      ## is a second field. `registrar` is a NAME (`development`, or
      ## `external:/path/to/script`); a reader that decided provenance
      ## from it would be saying "anything that is not the development
      ## one is the issuer" — which is §7.2's substitution written as an
      ## inference, and it would promote the `(unnamed registrar)`
      ## install site to `issuer` as well.
      ##
      ## WHY IT HAS TO BE DURABLE AND NOT ONLY IN-PROCESS.
      ## `recordComputedResourceAttribute` stamps a value from the
      ## registrar installed AT THAT MOMENT, and that table lives in the
      ## process that converged the instance. L9 F5 is a consumer in
      ## ANOTHER project's session reading what this instance minted, and
      ## that process has no registrar installed and never will — it
      ## attaches, it does not mint. A crossing that lost the stamp would
      ## hand it an identifier it cannot ask about, which is strictly
      ## worse than the refusal it replaces.
      ##
      ## A ROW WRITTEN BEFORE THIS FIELD DECODES AS `rprUnstamped`,
      ## which is the truth about it: nothing claimed it. `@minted:`
      ## still resolves it and `@issuer-minted:` refuses it, so the
      ## fail-closed direction is the one an older record takes.

  ServiceInstanceAttribute* = object
    ## Shared-Development-Services §7.3 — ONE COMPUTED ATTRIBUTE OF THE
    ## RUNNING INSTANCE, with the same stamp its minted identifiers
    ## carry.
    ##
    ## WHY IT IS STAMPED AT ALL, when an attribute is not "minted". §7.2
    ## reasons about a substituted *identifier*; an issuer URL is not
    ## minted by anybody, so the obvious reading is that provenance does
    ## not apply. It does, and for §7.2's own reason transposed: a WRONG
    ## issuer URL is exactly as silent as a development client id. A
    ## consumer pointed at an issuer that is not the one the instance is
    ## serving fails at authentication time, somewhere else, with
    ## nothing pointing back here. So the question "who told us this"
    ## has to be answerable at the point of use, which means the fact
    ## travels with the value — the same move, the same field.
    ##
    ## STALENESS IS CLOSED STRUCTURALLY AND NOT BY THE STAMP, because
    ## the stamp cannot see time. `reconcileServiceInstanceAttributes`
    ## REPLACES this set wholesale on every converge with what the
    ## currently installed registrar answered, so an attribute survives
    ## only as long as something keeps re-reporting it. That is the
    ## opposite rule from a registration's mint-once reuse, and the
    ## difference is in the values: a client id must be byte-stable
    ## across restarts or last week's configuration breaks, while an
    ## issuer URL legitimately MOVES when the instance rebinds. Reusing
    ## a stored URL would be the `dev-server.sh` descriptor defect L9's
    ## review measured — a registrar answering from the previous run.
    name*: string
    value*: string
    registrar*: string
      ## The `name` of the registrar that reported it. In a refusal this
      ## is the half that says WHO.
    provenance*: RegistrarProvenance
    recordedAtUnix*: int64

  ServiceRegistrationSet* = object
    address*: string
      ## `<instance address>/registrations`.
    registrations*: seq[ServiceRegistration]
    attributes*: seq[ServiceInstanceAttribute]
      ## §7.3's INSTANCE-level attributes, on the same record as the
      ## per-member rows.
      ##
      ## THE SAME RECORD, and that is §7.3's decision rather than a
      ## convenience: "Giving the issuer a second, different mechanism
      ## would mean two ways to carry one class of value, and the one
      ## that looked simpler would be the one that cannot work." One
      ## record means one read for a consumer in another session, one
      ## codec refusal, and one place `repro down` can leave behind.
      ##
      ## A SECOND ROW SET RATHER THAN A FIELD ON EACH REGISTRATION, for
      ## the reason `IssuerAttributeName`'s own comment gives: the value
      ## is a property of the instance, not of a member.

  ServiceRegistrationMinter* =
    proc (member, contributor: string): string {.closure.}
      ## What the instance does to register a member. Returns the minted
      ## identifier. INJECTED rather than imported for the reason the
      ## liveness probe is: the real implementation talks to a running
      ## service, which this library must not know how to do.

  ServiceRegistrationOutcome* = enum
    sroMinted      ## this reconcile minted a new identifier
    sroReused      ## a registration already existed; nothing was minted
    sroWithdrawn   ## the member's contributor withdrew; removed

proc serviceRegistrationsAddress*(key: ServiceInstanceKey): string =
  ## The store address of one instance's registration set.
  serviceInstanceAddress(key) & ServiceRegistrationsAddressSuffix

proc encodeServiceRegistrations*(value: ServiceRegistrationSet): string =
  ## Deterministic in field and element order, so two writes of one set
  ## produce identical bytes.
  var rows = newJArray()
  for reg in value.registrations:
    rows.add(%*{
      "member": reg.member,
      "contributor": reg.contributor,
      "mintedId": reg.mintedId,
      "mintedAtUnix": reg.mintedAtUnix,
      "registrar": reg.registrar,
      MintedProvenanceField: $reg.provenance})
  var attrs = newJArray()
  for attr in value.attributes:
    attrs.add(%*{
      "name": attr.name,
      "value": attr.value,
      "registrar": attr.registrar,
      MintedProvenanceField: $attr.provenance,
      "recordedAtUnix": attr.recordedAtUnix})
  let node = %*{"attrsTypeId": ServiceRegistrationsAttrsTypeId}
  node["registrations"] = rows
  # EMITTED EVEN WHEN EMPTY, unlike a key a writer could simply omit. An
  # absent key and an empty array decode the same here, so the choice is
  # about what the document SAYS: `"instanceAttributes": []` states that
  # this instance reported none, which is the fact a reader diffing two
  # runs needs when an attribute disappears. An omitted key would make
  # "the registrar stopped reporting it" and "this record predates the
  # field" the same bytes.
  node[InstanceAttributesField] = attrs
  $node

proc decodeServiceRegistrations*(address, attrsTypeId, attrsJson: string):
    ServiceRegistrationSet =
  ## The inverse. Raises `ValueError` on anything it cannot decode
  ## EXACTLY -- a set written by a future version is reported by name
  ## rather than read as "no registrations here", which would re-mint
  ## every identifier.
  if attrsTypeId != ServiceRegistrationsAttrsTypeId:
    raise newException(ValueError,
      "service registration set at `" & address & "` carries attrs " &
      "type `" & attrsTypeId & "`; this build reads `" &
      ServiceRegistrationsAttrsTypeId & "` only. Reading it anyway " &
      "would re-mint every identifier in it, which is the one failure " &
      "this record exists to prevent.")
  let node =
    try:
      parseJson(attrsJson)
    except CatchableError as err:
      raise newException(ValueError,
        "service registration set at `" & address &
        "` has unparsable attrs: " & err.msg)
  if node.kind != JObject:
    raise newException(ValueError,
      "service registration set at `" & address &
      "` has non-object attrs")
  result.address = address
  # §7.3's attribute rows, decoded BEFORE the early return below. A
  # record whose `registrations` key is absent -- an instance that has
  # attributes and no members, which is every instance whose consumers
  # have all withdrawn -- would otherwise drop them, and a dropped
  # attribute is the silent half of this document's defect class: the
  # token at the point of use would refuse for the wrong reason, naming
  # an uncomputed attribute when the record holds one.
  let attrRows = node{InstanceAttributesField}
  if not attrRows.isNil and attrRows.kind == JArray:
    for row in attrRows:
      if row.kind != JObject:
        raise newException(ValueError,
          "service registration set at `" & address &
          "` has a non-object " & InstanceAttributesField & " row")
      let name = row{"name"}.getStr("")
      if name.len == 0:
        raise newException(ValueError,
          "service registration set at `" & address & "` has an " &
          InstanceAttributesField & " row with no `name`, so nothing " &
          "can ask for it by name and nothing can replace it on the " &
          "next converge")
      let value = row{"value"}.getStr("")
      if value.len == 0:
        raise newException(ValueError,
          "service registration set at `" & address & "` has the " &
          InstanceAttributesField & " row `" & name &
          "` with an EMPTY `value`. Shared-Development-Services.md " &
          "§7.2: \"a nil or an empty string is the one answer that " &
          "must not be chosen\" -- an empty attribute would reach a " &
          "consuming service's argv as an empty argument and fail at " &
          "the issuer rather than here.")
      result.attributes.add(ServiceInstanceAttribute(
        name: name,
        value: value,
        registrar: row{"registrar"}.getStr(""),
        provenance: parseRegistrarProvenance(
          row{MintedProvenanceField}.getStr("")),
        recordedAtUnix: row{"recordedAtUnix"}.getBiggestInt(0)))
  let rows = node{"registrations"}
  if rows.isNil or rows.kind != JArray:
    return
  for row in rows:
    if row.kind != JObject:
      raise newException(ValueError,
        "service registration set at `" & address &
        "` has a non-object registration row")
    let member = row{"member"}.getStr("")
    if member.len == 0:
      raise newException(ValueError,
        "service registration set at `" & address &
        "` has a registration with no `member`; a registration with " &
        "no identity cannot be matched on a re-reconcile, so it would " &
        "be re-minted every time")
    result.registrations.add(ServiceRegistration(
      member: member,
      contributor: row{"contributor"}.getStr(""),
      mintedId: row{"mintedId"}.getStr(""),
      mintedAtUnix: row{"mintedAtUnix"}.getBiggestInt(0),
      registrar: row{"registrar"}.getStr(""),
      # ADDED WITHOUT BUMPING `ServiceRegistrationsAttrsTypeId`,
      # deliberately, and for the reason the decode's own refusal gives
      # two screens up: this codec REFUSES an attrs type it does not
      # know, and "reading it anyway would re-mint every identifier in
      # it, which is the one failure this record exists to prevent". A
      # bump would turn every pre-§7.2 record into exactly that
      # refusal. An absent key reads as `unstamped`, which is what the
      # row actually is.
      provenance: parseRegistrarProvenance(
        row{MintedProvenanceField}.getStr(""))))

proc readServiceRegistrations*(storeRoot: string;
                               key: ServiceInstanceKey):
                               ServiceRegistrationSet =
  ## Read the persisted set, or an empty one when none exists.
  let address = serviceRegistrationsAddress(key)
  result.address = address
  let store = openStateStore(storeRoot)
  if not store.hasStateRecord(address):
    return
  let rec = store.readStateRecord(address)
  decodeServiceRegistrations(address, rec.attrsTypeId, rec.attrsJson)

proc writeServiceRegistrations*(storeRoot: string;
                                key: ServiceInstanceKey;
                                value: ServiceRegistrationSet;
                                now: Time = getTime()) =
  let store = openStateStore(storeRoot)
  store.writeStateRecord(ResourceStateRecord(
    address: serviceRegistrationsAddress(key),
    typeId: ServiceRegistrationsTypeId,
    determinism: rdVolatile,
    attrsTypeId: ServiceRegistrationsAttrsTypeId,
    attrsJson: encodeServiceRegistrations(value),
    dependsOn: @[serviceInstanceAddress(key)],
    identity: key.identity,
    present: true,
    holders: initTable[string, Time](),
    effectiveDeadline: none(Time),
    lastRenewed: now))

proc reconcileServiceRegistrations*(
    storeRoot: string;
    key: ServiceInstanceKey;
    members: openArray[string];
    contributors: openArray[string];
    mint: ServiceRegistrationMinter;
    now: Time = getTime();
    registrar = "";
    provenance = rprUnstamped):
    tuple[set: ServiceRegistrationSet;
          outcomes: seq[tuple[member: string;
                              outcome: ServiceRegistrationOutcome]]] =
  ## Reconcile the instance's registrations against the folded member
  ## set, and return what each member's reconcile did.
  ##
  ## THE PROPERTY THIS PROC EXISTS FOR: a member that already has a
  ## registration keeps its `mintedId` and its `mintedAtUnix`
  ## BYTE-IDENTICAL. `mint` is not called for it. A second consumer
  ## arriving adds its own members and touches nothing else.
  ##
  ## `registrar` NAMES WHO IS MINTING, AND IT IS PART OF THE REUSE KEY
  ## (Shared-Development-Services §7.2). Reuse means "this member was
  ## already registered BY THIS REGISTRAR"; a row minted by a different
  ## one is re-minted rather than reused, because reusing it would hand
  ## the new registrar's provenance to the old registrar's value. The
  ## default `""` preserves the pre-§7.2 behaviour exactly for a caller
  ## that names nobody: `""` matches `""`, so reuse is unchanged.
  ##
  ## `provenance` IS WHAT THAT REGISTRAR CLAIMS, and it is recorded on
  ## the rows this call MINTS and on no others. A REUSED row keeps the
  ## stamp it was minted under, which is sound precisely because
  ## `registrar` is part of the reuse key: a row can only be reused by
  ## the registrar that minted it, and one registrar has one provenance
  ## (`ServiceRegistrarIdentity`: "ONE PROVENANCE PER REGISTRAR, not one
  ## per row"). Re-stamping a reused row from the CURRENT caller would
  ## be the same move with the same name, and `t_dss72`'s no-re-stamp
  ## control exists because it was written that way first.
  ##
  ## IT DEFAULTS TO `rprUnstamped` AND NOT TO THE CALLER'S WORD. A
  ## caller that names a registrar but no provenance has made no claim,
  ## and `unstamped` is the only answer that is not a guess.
  ##
  ## A MEMBER NO LONGER CONTRIBUTED IS REMOVED, and nothing else is --
  ## §5's withdrawal property, at this layer. It is removed rather than
  ## kept because a registration nobody asks for is a live OIDC client
  ## with no owner.
  ##
  ## `mint` RETURNING AN EMPTY STRING IS A REFUSAL, not an identifier.
  ## D-SS10: "A nil or an empty string is the one answer that must not
  ## be chosen." An empty minted id would travel to a consumer's argv
  ## as `--client-id ''`, which fails at the issuer with a message about
  ## credentials rather than about registration.
  if mint.isNil:
    raise newException(ServiceRegistryError,
      "reconcileServiceRegistrations needs a minter: the thing that " &
      "registers a member against the running instance and reports " &
      "the identifier it minted. A nil minter cannot be defaulted -- " &
      "defaulting it would invent identifiers no instance knows.")
  if members.len != contributors.len:
    raise newException(ServiceRegistryError,
      "reconcileServiceRegistrations: " & $members.len & " members " &
      "and " & $contributors.len & " contributors. The two lists are " &
      "parallel by construction (`contributionMemberAttribution` " &
      "builds them together), so a length mismatch means they came " &
      "from different folds and the attribution would be wrong.")
  let existing = readServiceRegistrations(storeRoot, key)
  var kept: seq[ServiceRegistration] = @[]
  var outcomes: seq[tuple[member: string;
                          outcome: ServiceRegistrationOutcome]] = @[]
  for i in 0 ..< members.len:
    var found = false
    for reg in existing.registrations:
      if reg.member != members[i] or reg.registrar != registrar:
        continue
      kept.add(reg)
      outcomes.add((member: members[i], outcome: sroReused))
      found = true
      break
    if found:
      continue
    let minted = mint(members[i], contributors[i])
    if minted.len == 0:
      raise newException(ServiceRegistryError,
        "registering `" & members[i] & "` in instance `" &
        serviceInstanceAddress(key) & "` produced an EMPTY identifier. " &
        "An empty minted id is not an identifier; it is a missing one " &
        "wearing the shape of one, and it would reach a consuming " &
        "service's argv as an empty argument.")
    kept.add(ServiceRegistration(
      member: members[i],
      contributor: contributors[i],
      mintedId: minted,
      mintedAtUnix: now.toUnix(),
      registrar: registrar,
      provenance: provenance))
    outcomes.add((member: members[i], outcome: sroMinted))
  for reg in existing.registrations:
    var stillAsked = false
    for i in 0 ..< members.len:
      if members[i] == reg.member:
        stillAsked = true
        break
    if not stillAsked:
      outcomes.add((member: reg.member, outcome: sroWithdrawn))
  result.set = ServiceRegistrationSet(
    address: serviceRegistrationsAddress(key), registrations: kept,
    # §7.3's attribute rows are CARRIED FORWARD, never rewritten here.
    # This proc's whole write is `result.set`, so a set built without
    # them would ERASE every instance attribute on every converge --
    # the silent drop, inside the fix for one. The attributes are
    # `reconcileServiceInstanceAttributes`' to decide, and the two procs
    # are separate precisely so that neither can quietly clear the
    # other's rows: this one cannot touch attributes, and that one
    # cannot touch registrations.
    attributes: existing.attributes)
  result.outcomes = outcomes
  writeServiceRegistrations(storeRoot, key, result.set, now)

proc reconcileServiceInstanceAttributes*(
    storeRoot: string;
    key: ServiceInstanceKey;
    attributes: openArray[tuple[name, value: string]];
    registrar = "";
    provenance = rprUnstamped;
    now: Time = getTime()): ServiceRegistrationSet =
  ## Shared-Development-Services §7.3 — RECORD WHAT THE RUNNING INSTANCE
  ## REPORTED ABOUT ITSELF, and nothing else.
  ##
  ## `attributes` is the WHOLE SET as of this converge. Whatever was
  ## stored is replaced by it, which is the anti-staleness rule stated in
  ## `ServiceInstanceAttribute`'s own comment: an attribute survives only
  ## while something keeps re-reporting it. Three cases fall out of that
  ## one rule, and all three are the behaviour §7.3 needs:
  ##
  ##   * the instance rebound to a different port -- the new URL replaces
  ##     the old one, because the registrar that just spoke to it
  ##     answered the new one;
  ##   * the workspace converged OFFLINE this time, with the development
  ##     registrar and no issuer -- the development registrar reports no
  ##     attributes, so the previous run's issuer URL is REMOVED rather
  ##     than served to a consumer as if it were this instance's. That is
  ##     the `dev-server.sh` descriptor defect, closed by construction;
  ##   * the registrar stopped reporting one attribute of several -- that
  ##     one is removed and the others are not.
  ##
  ## IT DOES NOT MERGE, and the rejected alternative is worth naming: a
  ## merge would keep an attribute nobody re-reported, which is exactly
  ## the row a consumer must not receive. "Keep what we had" is the
  ## comfortable answer and it is the one that delivers last week's
  ## issuer.
  ##
  ## `registrar` AND `provenance` ARE THE REPORTER'S, applied to every
  ## row this call writes. Unlike `reconcileServiceRegistrations` there
  ## is no reuse and so no re-stamping question: every row here is
  ## written by the registrar installed right now, so every row carries
  ## that registrar's claim and no row carries an older one.
  ##
  ## IT DEFAULTS TO `rprUnstamped` for `reconcileServiceRegistrations`'
  ## reason: a caller that names no provenance has made no claim, and
  ## `unstamped` is the only answer that is not a guess.
  var seen = initTable[string, string]()
  var rows: seq[ServiceInstanceAttribute] = @[]
  for attr in attributes:
    if attr.name.len == 0:
      raise newException(ServiceRegistryError,
        "an instance attribute of `" & serviceInstanceAddress(key) &
        "` was reported with an EMPTY name. A nameless attribute " &
        "cannot be asked for by `@instance-attribute:<name>@` and " &
        "cannot be replaced on the next converge, so it is refused " &
        "rather than stored where nothing can reach it.")
    if attr.value.len == 0:
      raise newException(ServiceRegistryError,
        "the instance attribute `" & attr.name & "` of `" &
        serviceInstanceAddress(key) & "` was reported with an EMPTY " &
        "value. Shared-Development-Services.md §7.2: \"a nil or an " &
        "empty string is the one answer that must not be chosen\". An " &
        "empty value is indistinguishable from a legitimately empty " &
        "one, so it would reach a consuming service's argv as an empty " &
        "argument and fail at the issuer instead of here. A reporter " &
        "that could not determine an attribute must omit it, which is " &
        "a REFUSAL at the point of use naming that attribute.")
    if seen.hasKey(attr.name):
      raise newException(ServiceRegistryError,
        "the instance attribute `" & attr.name & "` of `" &
        serviceInstanceAddress(key) & "` was reported twice, as `" &
        seen[attr.name] & "` and `" & attr.value & "`. Refused rather " &
        "than last-writer-wins: the two rows are two claims about one " &
        "property of one running instance and nothing here can choose " &
        "between them.")
    seen[attr.name] = attr.value
    rows.add(ServiceInstanceAttribute(
      name: attr.name, value: attr.value, registrar: registrar,
      provenance: provenance, recordedAtUnix: now.toUnix()))
  let existing = readServiceRegistrations(storeRoot, key)
  result = ServiceRegistrationSet(
    address: serviceRegistrationsAddress(key),
    # The REGISTRATIONS are carried forward untouched, the mirror image
    # of `reconcileServiceRegistrations` carrying the attributes
    # forward. Neither proc may clear the other's rows.
    registrations: existing.registrations,
    attributes: rows)
  writeServiceRegistrations(storeRoot, key, result, now)

# ---------------------------------------------------------------------------
# Shared-Development-Services D-SS11 (§4.6) — THE CROSS-PROCESS
# CONTRIBUTION STORE.
#
# §4.6, the part L9 measured as absent: "a consumer in a *different
# process* has no way to reach them ... So the lane is intra-process, and
# a cross-repo `contribute:` would compile, look wired, and do nothing."
#
# This record is the lane. It is IDENTITY-KEYED, beside the registration
# set and under the same instance address, because §4.4 is explicit that
# a shared instance's state "is addressed by its identity" -- a
# contribution set under one consumer's `.repro/` would belong to
# whichever project happened to run first, which is the defect §4.4
# names.
#
# WHO WRITES AND WHO READS. A CONSUMER's `repro up` writes its own rows
# (and only its own); the OWNER's converge reads every row and applies
# them when it reconciles its registrations. That is "applied by the
# owner's instance when it converges", and it is also why the owner MUST
# read them: `reconcileServiceRegistrations` removes a member no longer
# contributed, so an owner that folded only its own members would
# WITHDRAW every consumer's registration on its next `repro up` -- a
# live OIDC client deleted because the project that asked for it was not
# the one converging.
#
# ONE CONTRIBUTOR, ONE SLOT. A deposit REPLACES exactly the rows of the
# depositing package and leaves every other contributor's alone. That is
# §5's withdrawal property at this layer: a consumer that drops a
# contribution from its recipe has it disappear on its next `repro up`,
# and a consumer that is not run does not lose what it registered.
# ---------------------------------------------------------------------------

const
  ServiceContributionsTypeId* = "reprobuild.service-contributions"
  ServiceContributionsAttrsTypeId* = "reprobuild.service-contributions.v1"
  ServiceContributionsAddressSuffix* = "/contributions"

type
  ServiceContribution* = object
    ## One cross-process contribution, as the store holds it.
    ##
    ## The two ENUM fields are strings here for the reason they are
    ## strings on the provider wire: the record crosses a process
    ## boundary and may be read by a build that is not the one that wrote
    ## it, and an ordinal that shifted would silently re-map an
    ## operation. `coReplace` is ordinal 0 and is the one operation a
    ## consumer may not use, so a mis-mapped ordinal would turn a
    ## contribution into a destructive one. The names are refused by
    ## name on read.
    point*: string
      ## The bare point name, as the OWNER declared it in `converge` and
      ## as the consumer wrote it at the resolver.
    contributor*: string
      ## The contributing package. §5's attribution, and the key a
      ## deposit replaces on.
    operation*: string
    precedence*: string
    members*: seq[string]
    site*: string
      ## `<file>:<line>` of the resolver argument, for a diagnostic that
      ## can name the contributor's own line.

  ServiceContributionSet* = object
    address*: string
    contributions*: seq[ServiceContribution]

proc serviceContributionsAddress*(key: ServiceInstanceKey): string =
  ## The store address of one instance's cross-process contribution set.
  serviceInstanceAddress(key) & ServiceContributionsAddressSuffix

proc encodeServiceContributions*(value: ServiceContributionSet): string =
  ## Deterministic in field and element order, so two writes of one set
  ## produce identical bytes.
  var rows = newJArray()
  for c in value.contributions:
    var members = newJArray()
    for member in c.members:
      members.add(%member)
    let row = %*{
      "point": c.point,
      "contributor": c.contributor,
      "operation": c.operation,
      "precedence": c.precedence,
      "site": c.site}
    row["members"] = members
    rows.add(row)
  let node = %*{"attrsTypeId": ServiceContributionsAttrsTypeId}
  node["contributions"] = rows
  $node

proc decodeServiceContributions*(address, attrsTypeId,
                                 attrsJson: string): ServiceContributionSet =
  ## The inverse. Everything it cannot read EXACTLY is refused by name.
  ##
  ## A set written by a future version is NOT read as "no contributions
  ## here". That reading is the dangerous one: the owner's converge would
  ## then reconcile its own members only, and
  ## `reconcileServiceRegistrations` would withdraw every consumer's
  ## registration -- a silent deletion caused by a format boundary.
  if attrsTypeId != ServiceContributionsAttrsTypeId:
    raise newException(ValueError,
      "service contribution set at `" & address & "` carries attrs " &
      "type `" & attrsTypeId & "`; this build reads `" &
      ServiceContributionsAttrsTypeId & "` only. Reading it anyway " &
      "would make this instance's cross-process contributions look " &
      "absent, and the next converge would WITHDRAW every registration " &
      "they asked for.")
  let node =
    try:
      parseJson(attrsJson)
    except CatchableError as err:
      raise newException(ValueError,
        "service contribution set at `" & address &
        "` has unparsable attrs: " & err.msg)
  if node.kind != JObject:
    raise newException(ValueError,
      "service contribution set at `" & address &
      "` has non-object attrs")
  result.address = address
  let rows = node{"contributions"}
  if rows.isNil or rows.kind != JArray:
    return
  for row in rows:
    if row.kind != JObject:
      raise newException(ValueError,
        "service contribution set at `" & address &
        "` has a non-object contribution row")
    var c = ServiceContribution(
      point: row{"point"}.getStr(""),
      contributor: row{"contributor"}.getStr(""),
      operation: row{"operation"}.getStr(""),
      precedence: row{"precedence"}.getStr(""),
      site: row{"site"}.getStr(""))
    if c.point.len == 0:
      raise newException(ValueError,
        "service contribution set at `" & address &
        "` has a contribution naming no point; it could not be matched " &
        "against a declared point, so it is refused rather than read " &
        "as a contribution to nothing")
    if c.contributor.len == 0:
      raise newException(ValueError,
        "service contribution set at `" & address &
        "` has a contribution to `" & c.point &
        "` naming no contributor; a row with no contributor can never " &
        "be replaced or withdrawn by the package that made it")
    let members = row{"members"}
    if members.isNil or members.kind != JArray:
      raise newException(ValueError,
        "service contribution set at `" & address &
        "` has a contribution to `" & c.point & "` with no member list")
    for member in members:
      if member.kind != JString or member.getStr("").len == 0:
        raise newException(ValueError,
          "service contribution set at `" & address &
          "` has an empty or non-string member in the contribution to `" &
          c.point & "`")
      c.members.add(member.getStr(""))
    result.contributions.add(c)

proc readServiceContributions*(storeRoot: string;
                              key: ServiceInstanceKey):
                              ServiceContributionSet =
  ## Read the persisted set, or an empty one when none exists.
  let address = serviceContributionsAddress(key)
  result.address = address
  let store = openStateStore(storeRoot)
  if not store.hasStateRecord(address):
    return
  let rec = store.readStateRecord(address)
  decodeServiceContributions(address, rec.attrsTypeId, rec.attrsJson)

proc writeServiceContributions*(storeRoot: string;
                                key: ServiceInstanceKey;
                                value: ServiceContributionSet;
                                now: Time = getTime()) =
  let store = openStateStore(storeRoot)
  store.writeStateRecord(ResourceStateRecord(
    address: serviceContributionsAddress(key),
    typeId: ServiceContributionsTypeId,
    determinism: rdVolatile,
    attrsTypeId: ServiceContributionsAttrsTypeId,
    attrsJson: encodeServiceContributions(value),
    dependsOn: @[serviceInstanceAddress(key)],
    identity: key.identity,
    present: true,
    holders: initTable[string, Time](),
    effectiveDeadline: none(Time),
    lastRenewed: now))

proc depositServiceContributions*(storeRoot: string;
                                  key: ServiceInstanceKey;
                                  contributor: string;
                                  contributions: openArray[ServiceContribution];
                                  now: Time = getTime()):
    tuple[set: ServiceContributionSet; replaced: int; added: int] =
  ## Write `contributor`'s rows into the instance's contribution set,
  ## REPLACING exactly its previous rows and touching nobody else's.
  ##
  ## `contributions` may be empty, and an empty deposit is a WITHDRAWAL
  ## rather than a no-op: a consumer whose recipe no longer contributes
  ## must stop contributing, and the only way its `repro up` can say so
  ## is by depositing nothing. Skipping the write for an empty list would
  ## leave last week's members registered forever with nothing asking
  ## for them.
  if contributor.len == 0:
    raise newException(ServiceRegistryError,
      "depositServiceContributions needs the contributing package: a " &
      "row with no contributor can never be replaced or withdrawn, and " &
      "§5 requires every converged member to name the package that " &
      "contributed it.")
  for c in contributions:
    if c.contributor != contributor:
      raise newException(ServiceRegistryError,
        "depositServiceContributions for `" & contributor &
        "` was handed a contribution attributed to `" & c.contributor &
        "`. A deposit replaces exactly one contributor's rows, so a " &
        "mixed batch would either write rows this deposit cannot " &
        "replace later or silently re-attribute them.")
  var kept: seq[ServiceContribution] = @[]
  let existing = readServiceContributions(storeRoot, key)
  for c in existing.contributions:
    if c.contributor == contributor:
      inc result.replaced
    else:
      kept.add(c)
  for c in contributions:
    kept.add(c)
    inc result.added
  result.set = ServiceContributionSet(
    address: serviceContributionsAddress(key), contributions: kept)
  writeServiceContributions(storeRoot, key, result.set, now)

proc contributionPrecedenceFromWord(word: string;
                                   c: ServiceContribution):
    EnvironmentPrecedence =
  ## The stored precedence word back to the ladder. Refused by name
  ## rather than defaulted: `epDefault` is the LOWEST rung, so a
  ## mis-read word would silently demote an `appendForce` to the rung a
  ## `replace` discards, and the member would vanish with a step-4
  ## diagnostic nobody asked for.
  case word
  of "epSet": epSet
  of "epOverride": epOverride
  of "epForce": epForce
  of "epDefault": epDefault
  else:
    raise newException(ServiceRegistryError,
      "package `" & c.contributor & "` contributes to `" & c.point &
      "` with precedence `" & word & "`, which this build does not " &
      "know. The rungs are `epDefault`, `epSet`, `epOverride` and " &
      "`epForce`. Defaulting an unknown rung would demote the " &
      "contribution to the bottom one, where a `replace` discards it.")

proc refuseUndeclaredContribution(point, contributor, site: string;
                                  declaredPoints: openArray[string];
                                  address: string) =
  ## §4.6's refusal, in one place so the consumer's check and the
  ## owner's check cannot word it differently.
  var declared: seq[string] = @[]
  for p in declaredPoints:
    declared.add("`" & p & "`")
  raise newException(ServiceRegistryError,
    "package `" & contributor & "` contributes to `" & point &
    "` at " & (if site.len == 0: "<unknown site>" else: site) &
    ", and the instance at `" & address & "` declares no such " &
    "contribution point. It converges " &
    (if declared.len == 0: "no contribution points at all"
     else: declared.join(", ")) &
    ". Shared-Development-Services.md §4.6: \"a contribution that " &
    "reaches an instance which does not declare that point must be " &
    "REFUSED, never dropped -- including across a version skew, where " &
    "the running instance was built from an older definition that lacks " &
    "the point. §4.3's three outcomes already decide the skew case; a " &
    "contribution to an absent point is the refusing row, not the " &
    "warning row, because the consumer asked for something the instance " &
    "cannot do.\"")

proc validateServiceContributions*(declaredPoints: openArray[string];
                                   contributions: openArray[ServiceContribution];
                                   address: string) =
  ## Refuse every contribution the instance cannot honour. Raises on the
  ## FIRST offender, naming it, the contributor and the declared set.
  ##
  ## Two refusals, both §4.6's or §5.1's and neither a drop:
  ##   * a point the instance does not declare (the version-skew case),
  ##     refused through `refuseUndeclaredContribution`;
  ##   * a `replace` operation, refused with
  ##     `sharedServiceReplaceRefusal()` -- the ONE wording of §5.1's
  ##     judgement, shared with the resolver macro's compile-time
  ##     refusal and the evaluation-time one. That helper's own doc
  ##     comment carries the reason and names all three stages; it is
  ##     deliberately not restated here, because a fourth copy of one
  ##     sentence is the drift this factoring exists to stop. What is
  ##     specific to THIS stage is that it sees a row out of the
  ##     cross-process store, where a stored `replace` would become the
  ##     fold's base value and DISCARD every other consumer's appends.
  for c in contributions:
    var found = false
    for p in declaredPoints:
      if p == c.point:
        found = true
        break
    if not found:
      refuseUndeclaredContribution(c.point, c.contributor, c.site,
        declaredPoints, address)
    if c.operation != $coAppend:
      # STAGE 3 of §5.1's three refusals, and the only one that sees a
      # row out of the cross-process store. The judgement is the shared
      # `sharedServiceReplaceRefusal()`; what is local is the subject
      # (contributor, point, site) and the consequence only this stage
      # can state -- a stored `replace` becomes the FOLD's base value.
      raise newException(ServiceRegistryError,
        "package `" & c.contributor & "` contributes to `" & c.point &
        "` at " & (if c.site.len == 0: "<unknown site>" else: c.site) &
        " with operation `" & c.operation & "`. " &
        sharedServiceReplaceRefusal() &
        " Refused at the OWNER's converge as well, because a stored " &
        "`replace` would become the fold's base value and discard " &
        "every other consumer's appends.")
    if c.members.len == 0:
      raise newException(ServiceRegistryError,
        "package `" & c.contributor & "` contributes NO members to `" &
        c.point & "` at " &
        (if c.site.len == 0: "<unknown site>" else: c.site) &
        ". A contribution with no members is indistinguishable from a " &
        "forgotten one; it is refused rather than folded into nothing.")

proc foldCrossProcessContributions*(declaredPoints: openArray[string];
                                    contributions: openArray[ServiceContribution];
                                    address: string):
    tuple[members: seq[string]; contributors: seq[string]] =
  ## Fold the stored cross-process contributions into the member list the
  ## instance must register, with each member attributed to the package
  ## that contributed it.
  ##
  ## THE ALGEBRA IS NOT RE-DECIDED HERE. Every point is folded by
  ## `foldContributionRows` -- the same four steps of
  ## `Configurable-System.md` §Resolution that the intra-process lane
  ## folds with, which L8 built and this proc calls. A second
  ## implementation of "which append wins" is the drift this campaign has
  ## already paid for.
  ##
  ## THE BASE IS EMPTY, deliberately. Step 1's `R` is the
  ## highest-priority `replace`, and the owner's OWN members are already
  ## resolved by the owner's process before this proc is reached -- they
  ## are appended to this result by the caller, not folded again. So the
  ## base row here is an empty `replace` at `epDefault` attributed to the
  ## port, and what this fold decides is exactly the ordering and
  ## priority of the cross-process appends among themselves.
  ##
  ## POINTS ARE FOLDED IN THE INSTANCE'S DECLARATION ORDER, not in store
  ## order, so two deposits in different orders produce the same member
  ## list. A store whose row order decided the result would make the
  ## registration set depend on which consumer ran first.
  validateServiceContributions(declaredPoints, contributions, address)
  for point in declaredPoints:
    var rows: seq[ConfigContribution] = @[ConfigContribution(
      key: point, package: "", precedence: epDefault,
      operation: coReplace, value: dslScalarSeqString(@[]))]
    for c in contributions:
      if c.point != point:
        continue
      rows.add(ConfigContribution(
        key: point, package: c.contributor,
        precedence: contributionPrecedenceFromWord(c.precedence, c),
        operation: coAppend,
        value: dslScalarSeqString(c.members),
        sourceFile: c.site, sourceLine: 0))
    let folded = foldContributionRows(point, rows)
    for i in 0 ..< folded.members.len:
      result.members.add(folded.members[i])
      result.contributors.add(folded.memberPackages[i])

proc mintedIdFor*(value: ServiceRegistrationSet; member: string): string =
  ## The identifier minted for `member`, or the empty string when the
  ## set holds no registration for it. The caller decides what an
  ## absence means; this proc does not guess.
  for reg in value.registrations:
    if reg.member == member:
      return reg.mintedId
  return ""
