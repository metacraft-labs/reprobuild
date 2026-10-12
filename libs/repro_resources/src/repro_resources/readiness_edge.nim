## Shared-Development-Services **D-SS10** (spec §7.1) — the ordering edge
## for a resource whose provider needs a LIVE service, and the two refusals
## the decision makes illegal rather than discouraged.
##
## § WHAT THE DECISION SAYS, AND WHAT IS THEREFORE BUILT HERE
##
## §7.1 resolved D-SS10 as "the readiness edge is the one that already
## exists": an **ordinary `dependsOn` onto the service node**, with the one
## thing that was missing said out loud —
##
##   > a service node's **completion is its declared readiness**
##
## — not its materialisation. So this module adds no edge KIND. It adds the
## two resource types that put a service node and its registration into the
## SAME address space, so that `reconcile.topoOrder`'s existing
## `dependsOn` ordering is the ordering, and `reconcileResources`'
## existing observe/decide/apply loop is what makes completion mean the
## probe.
##
## The edge itself was already on disk before this module existed:
## `writeServiceRegistrations` (service_registry.nim) has always written
## its store record with `dependsOn: @[serviceInstanceAddress(key)]`. What
## was missing was a reconcile in which that address resolves to a node
## whose completion is a probe. `topoOrder` hard-errors on an edge naming
## an address not in the desired set, which is exactly why the edge was
## inert rather than wrong.
##
## § WHY THIS IS A STRUCTURAL GUARANTEE AND NOT A SEQUENCING CONVENTION
##
## Before this module, the ordering was `convergeSharedServiceInstances`'
## own statement order, and that module's comment said so:
##
##   > This is none of the three: it is a sequential step in the CLI,
##   > ordered by program order rather than by a graph edge. It satisfies
##   > the REQUIREMENT (nothing reads an attribute before it is computed)
##   > without taking the decision.
##
## It also ordered the registration after **materialisation**: the daemon
## answers `Materialise ok` when the child is spawned, and L9's own review
## recorded that it answers so even for a child that has already died. A
## registration reconciled there runs against the listening-but-unseeded
## instance §7.1 names. Routing both nodes through `reconcileResources`
## replaces that with a graph property: the registration's provider CANNOT
## be reached before the service node's, because `topoOrder` visits
## `dependsOn` first and `reconcileResources` iterates the order it
## returns.
##
## § THE COMPLETION RULE, IN THE PROVIDER'S TWO CALLBACKS
##
## `observe` on the service node answers "is the declared probe satisfied
## RIGHT NOW" and `apply` **awaits** it within the declared timeout,
## raising on expiry. Read through `reconcile.decide`:
##
##   * probe already satisfied -> `observe` reports present at the desired
##     digest -> `rakNoOp`, no wait at all (the attach fast path);
##   * probe not yet satisfied -> absent -> `rakCreate` -> `apply` waits,
##     and a timeout raises so no downstream node runs.
##
## `observe` sets `digest = desiredDigest` whenever it reports present, so
## a service node can never be `rakDriftBlocked` — "the operator changed
## it behind our back" is not a thing a readiness probe can mean.
##
## § THE TWO ILLEGAL SHAPES
##
## 1. **`readiness none` cannot order a registration.** With no probe there
##    is nothing for completion to mean, so `dependsOn` would silently
##    degrade to "materialised". `planRegistrationEdge` REFUSES such a
##    service by name. This is the RESOLUTION-time half of a pair: the
##    EXPANSION-time half lives in `repro_project_dsl`'s `macros_b.nim`
##    and refuses the `service` block that writes `converge` with no
##    probe, at the line the author wrote. The two are deliberately
##    distinguishable in their text, the discipline L5 established for
##    `l5RefuseUnsatisfiableRequiredKeys` / `requiredConfigurableValue`:
##    expansion owns "NOTHING CAN ORDER A REGISTRATION ON IT", resolution
##    owns "DECLARES NO READINESS".
##
##    A service that declares NO `readiness` setter at all is refused by
##    both, for the same reason and in a sentence that says which of the
##    two shapes it is. Refusing only the explicit spelling would leave
##    the SILENT one legal, which inverts the campaign's whole finding.
##
## 2. **An early read of a computed attribute refuses, never answers.**
##    `readComputedResourceAttribute` names the attribute, the resource and
##    the edge that would have ordered it. D-SS10's own prohibition is
##    kept: nil and `""` are the two answers that must not be chosen,
##    because an empty string is indistinguishable from a legitimately
##    empty value.
##
## § TEST-DOUBLE POLICY
##
## Nothing here is mocked and nothing may be. `fileExists` is evaluated
## against the real filesystem by this module. `httpGet` is delegated to an
## installed prober, for the same reason `ServiceRegistrationMinter` and
## `ServiceInstanceRegistry.probe` are injected: this library owns no HTTP
## client and must not grow one. An `httpGet` probe with NO prober
## installed is a REFUSAL, not a "ready" — a hook whose absence read as
## success would be this campaign's defect class inside its own fix.

import std/[options, os, strutils, tables]

from repro_home_generations/pointer import Digest256
from repro_home_resources/types import ObservedState, ResourceActionKind,
  rakDestroy
import repro_project_dsl                  # registerExtension / TypedExtensionBox
import repro_resources/instance

type
  ReadinessEdgeError* = object of CatchableError
    ## Every refusal this module raises. A distinct type so a caller can
    ## tell a D-SS10 refusal from a store or codec failure, which matters
    ## because the two want different advice.

const
  SharedServiceNodeTypeId* = "reprobuild.shared-service-node.v1"
    ## The SERVICE NODE in the resource address space. It exists so that
    ## `dependsOn` onto a service is an ordinary resource edge rather than
    ## a second ordering concept — §7.1's whole parsimony argument.
  ServiceRegistrationTypeId* = "reprobuild.shared-service-registration.v1"
    ## The REGISTRATION RESOURCE: §7's "a resource whose provider performs
    ## the registration and reports `clientId` among its attributes".

  ReadinessProbeKindNone* = "none"
  ReadinessProbeKindFileExists* = "fileExists"
  ReadinessProbeKindHttpGet* = "httpGet"

  ReadinessPollIntervalMs* = 50
    ## The same granularity `dev_session.nim`'s `waitForReadiness` polls
    ## at, and deliberately the same number: a service does not become
    ## more or less patient because the thing waiting on it is the
    ## resource lane rather than the supervisor.

  ServiceNodeAddressPrefix* = "service-node:"
  RegistrationAddressSuffix* = "/registrations"
    ## Matches `ServiceRegistrationsAddressSuffix` in
    ## `service_registry.nim`, so the node this reconcile orders and the
    ## store record whose `dependsOn` already names the service are ONE
    ## address rather than two spellings of one idea.

  ClientIdAttributeName* = "clientId"
    ## §7's worked attribute: "a per-consumer OIDC client identifier does
    ## not exist until the instance has registered the application
    ## against a running issuer".

type
  ServiceReadinessProbe* = object
    ## What a `service` block declared about its readiness, in the shape
    ## the completion rule reads. `kind` is `""` when the author declared
    ## no `readiness` setter at all — DISTINCT from `"none"`, which is an
    ## author writing the absence down. Both are probeless and both are
    ## refused; the refusal says which, because the remedies differ.
    kind*: string
    path*: string
    url*: string
    timeoutMs*: int

  ServiceCompletionRule* = enum
    ## What the completion of a service node MEANS, derived from the
    ## declared probe rather than chosen per call site.
    scrDeclaredReadiness
      ## A probe is declared: completion is that probe succeeding. The
      ## only rule under which a registration may be ordered.
    scrUndeclared
      ## No `readiness` setter at all. Probeless.
    scrExplicitlyNone
      ## `readiness none`. Probeless, and said so on purpose.

  SharedServiceNodeAttrs* = object
    ## The service node's attributes. Flat and SSZ-clean per
    ## `attr_ssz`'s provider-author guidance.
    serviceName*: string
    instanceAddress*: string
    readinessKind*: string
    readinessPath*: string
    readinessUrl*: string
    readinessTimeoutMs*: int

  ServiceRegistrationAttrs* = object
    ## The registration resource's attributes: which service, which
    ## instance, and the folded member set with its parallel attribution.
    ## The MEMBERS are configuration and are known before the reconcile;
    ## the minted identifiers are not, which is the whole distinction §7
    ## draws.
    serviceName*: string
    instanceAddress*: string
    members*: seq[string]
    contributors*: seq[string]

  ServiceReadinessProber* =
    proc (url: string): bool {.closure.}
      ## Answers whether an `httpGet` probe is satisfied. INJECTED for the
      ## reason the minter is: the real implementation speaks HTTP, which
      ## this library must not know how to do.

  ServiceRegistrar* =
    proc (attrs: ServiceRegistrationAttrs):
      seq[tuple[member, mintedId: string]] {.closure.}
      ## Performs the registration against the LIVE instance and reports
      ## what it minted per member. INJECTED for the same reason.

  ReadinessEdgeEventSink* =
    proc (kind, service, detail: string) {.closure.}
      ## Where the two providers publish what they did, in the order they
      ## did it. The CLI installs a sink that appends to the dev session's
      ## own `events.jsonl`, which is what makes the ORDER an observable
      ## fact rather than a claim about statement order.

# ---------------------------------------------------------------------------
# Installed collaborators. Plain module globals rather than threadvars, for
# the reason `instance.nim`'s provider registry is one: the driver callbacks
# are `{.nimcall.}` procs with no closure environment, so whatever they need
# has to be reachable from module scope on whichever thread runs the
# reconcile.
# ---------------------------------------------------------------------------

var
  installedProber: ServiceReadinessProber = nil
  installedRegistrar: ServiceRegistrar = nil
  installedSink: ReadinessEdgeEventSink = nil
  computedAttributes: Table[string, Table[string, string]]

proc setServiceReadinessProber*(prober: ServiceReadinessProber) =
  ## Install the `httpGet` prober. Idempotent, last writer wins.
  installedProber = prober

proc setServiceRegistrar*(registrar: ServiceRegistrar) =
  ## Install the thing that registers members against the live instance.
  installedRegistrar = registrar

proc setReadinessEdgeEventSink*(sink: ReadinessEdgeEventSink) =
  ## Install the event sink. With none installed the providers run and
  ## publish nothing; the ORDERING is still enforced, because it is
  ## `topoOrder`'s and not the sink's.
  installedSink = sink

proc clearReadinessEdgeCollaborators*() =
  ## Test isolation: drop the prober, the registrar, the sink and every
  ## computed attribute. Named so a test cannot drop them by accident.
  installedProber = nil
  installedRegistrar = nil
  installedSink = nil
  computedAttributes.clear()

proc publish(kind, service, detail: string) =
  if not installedSink.isNil:
    installedSink(kind, service, detail)

# ---------------------------------------------------------------------------
# Addresses.
# ---------------------------------------------------------------------------

proc serviceNodeAddress*(instanceAddress: string): string =
  ## The service node's address, derived from the INSTANCE address rather
  ## than from the service's name: two activities may declare a service of
  ## the same name, and the instance key is what §4 made the identity.
  ServiceNodeAddressPrefix & instanceAddress

proc registrationResourceAddress*(instanceAddress: string): string =
  ## The registration resource's address. Identical to
  ## `serviceRegistrationsAddress(key)` by construction — see
  ## `RegistrationAddressSuffix`.
  instanceAddress & RegistrationAddressSuffix

proc registrationOrderingEdge*(instanceAddress: string): string =
  ## The edge, spelled the way a refusal should name it: which node
  ## depends on which. Named once here so the three refusal texts cannot
  ## describe three different edges.
  "`" & registrationResourceAddress(instanceAddress) &
    "` dependsOn `" & serviceNodeAddress(instanceAddress) & "`"

proc registrationOrderingEdgeOfService*(serviceName: string): string =
  ## The same edge, named from the SERVICE alone.
  ##
  ## For a refusal raised on a surface that does not hold the instance
  ## address — the argv-token concretization in
  ## `repro_cli_support/dev_session.nim` reads a file of
  ## `(serviceName, member, mintedId)` rows and nothing else. §7.1 asks a
  ## refusal to name "which attribute, which resource, and which edge
  ## would have ordered it"; within one artifact the service NAME
  ## identifies the service, so all three are nameable without the
  ## address. Derived here rather than written out at the call site so
  ## the two refusals cannot describe two different edges.
  "the registration resource of service `" & serviceName &
    "` dependsOn that service's node (`" & ServiceNodeAddressPrefix &
    "<the instance key of `" & serviceName & "`>`), whose COMPLETION is " &
    "that service's DECLARED READINESS and not its materialisation"

proc registrationResourceLabel*(serviceName, member: string): string =
  ## How a refusal names the registration RESOURCE when it has the
  ## service and the member but not the instance address.
  "the registration of member `" & member & "` in service `" &
    serviceName & "`"

# ---------------------------------------------------------------------------
# The completion rule.
# ---------------------------------------------------------------------------

proc serviceCompletionRule*(probe: ServiceReadinessProbe):
    ServiceCompletionRule =
  ## §7.1's rule, as a total function of the declared probe. `normalize`
  ## is not used: the words reaching here have already been validated by
  ## the DSL setter and by `serviceSpecFromSummary`, and a second, looser
  ## reading is how two readings of one fact start to disagree.
  case probe.kind.toLowerAscii()
  of "":
    scrUndeclared
  of "none":
    scrExplicitlyNone
  of "fileexists", "httpget":
    scrDeclaredReadiness
  else:
    # An unknown word is probeless, NOT ready. `readinessOk` in
    # `dev_session.nim` takes the same side for the same reason: a kind
    # this build cannot evaluate must never read as satisfied.
    scrUndeclared

proc ordersRegistrations*(probe: ServiceReadinessProbe): bool =
  ## Whether a registration may be ordered on a service with this probe.
  serviceCompletionRule(probe) == scrDeclaredReadiness

proc probeOf*(attrs: SharedServiceNodeAttrs): ServiceReadinessProbe =
  ServiceReadinessProbe(kind: attrs.readinessKind, path: attrs.readinessPath,
    url: attrs.readinessUrl, timeoutMs: attrs.readinessTimeoutMs)

# ---------------------------------------------------------------------------
# REFUSAL ONE OF THREE (resolution time): a registration ordered on a
# probeless service.
# ---------------------------------------------------------------------------

const
  readinessEdgeDegradationRule* =
    "With no probe there is nothing for completion to mean, so the " &
    "`dependsOn` would degrade to `materialised` -- the " &
    "listening-but-not-yet-seeded instance " &
    "Shared-Development-Services.md §7.1 refuses, and the one the " &
    "readiness marker is written LAST to avoid."

proc refuseRegistrationOnProbelessService*(serviceName, instanceAddress: string;
                                           probe: ServiceReadinessProbe) =
  ## Raise the resolution-time refusal, naming the service and that it
  ## declares no readiness.
  let shape =
    case serviceCompletionRule(probe)
    of scrExplicitlyNone:
      "DECLARES NO READINESS: its `service` block says `readiness none`"
    of scrUndeclared:
      if probe.kind.len == 0:
        "DECLARES NO READINESS: its `service` block has no `readiness` " &
          "setter at all"
      else:
        "DECLARES NO READINESS: its `service` block declares the " &
          "readiness kind `" & probe.kind & "`, which this build cannot " &
          "evaluate, so nothing can ever report it satisfied"
    of scrDeclaredReadiness:
      # Unreachable through `planRegistrationEdge`, which tests the rule
      # first. Spelled rather than `doAssert`ed so a future caller that
      # reaches it gets a sentence instead of a stack trace.
      "declares a readiness probe, so this refusal should not have been " &
        "reached -- report it"
  raise newException(ReadinessEdgeError,
    "service `" & serviceName & "` " & shape & ", and a REGISTRATION " &
    "RESOURCE is ordered on it (" &
    registrationOrderingEdge(instanceAddress) & "). " &
    readinessEdgeDegradationRule &
    " Declare a probe the supervisor implements -- `readiness " &
    "fileExists(\"<path>\")` or `readiness httpGet(port = <n>)` / " &
    "`readiness httpGet(url = \"<base>\")` -- or stop converging " &
    "contribution points on this service.")

# ---------------------------------------------------------------------------
# REFUSAL TWO OF THREE: an early read of a computed attribute.
# ---------------------------------------------------------------------------

proc recordComputedResourceAttribute*(resourceAddress, attribute,
                                      value: string) =
  ## Publish a computed attribute. An EMPTY value is refused at the write
  ## rather than at the read, because at the read there is nothing left to
  ## tell it from an attribute that was never computed — which is exactly
  ## the confusion D-SS10 forbids.
  if value.len == 0:
    raise newException(ReadinessEdgeError,
      "the computed attribute `" & attribute & "` of resource `" &
      resourceAddress & "` was computed as an EMPTY STRING. " &
      "Shared-Development-Services.md D-SS10: \"a nil or an empty " &
      "string is the one answer that must not be chosen\", because an " &
      "empty string is indistinguishable from a legitimately empty " &
      "value. A provider that has no value must fail, not report one.")
  if not computedAttributes.hasKey(resourceAddress):
    computedAttributes[resourceAddress] = initTable[string, string]()
  computedAttributes[resourceAddress][attribute] = value

proc computedResourceAttributeIsAvailable*(resourceAddress,
                                           attribute: string): bool =
  ## Whether the attribute has been computed. A TEST SEAM and a caller's
  ## guard — never a substitute for the read, which is the thing that
  ## refuses.
  computedAttributes.hasKey(resourceAddress) and
    computedAttributes[resourceAddress].hasKey(attribute)

proc readComputedResourceAttribute*(resourceAddress, attribute,
                                    instanceAddress: string): string =
  ## Read a computed resource attribute, or REFUSE BY NAME.
  ##
  ## §7.1: "A staged read of an uncomputed resource attribute reports
  ## which attribute, which resource, and which edge would have ordered
  ## it, in the same shape as §6's refusal for a required configurable
  ## that nothing satisfies." All three are named below, and the one thing
  ## this proc will not do is return `""`.
  if computedResourceAttributeIsAvailable(resourceAddress, attribute):
    return computedAttributes[resourceAddress][attribute]
  var computedHere: seq[string] = @[]
  if computedAttributes.hasKey(resourceAddress):
    for name in computedAttributes[resourceAddress].keys:
      computedHere.add(name)
  raise newException(ReadinessEdgeError,
    "the resource attribute `" & attribute & "` of resource `" &
    resourceAddress & "` IS NOT COMPUTED YET, so there is no value to " &
    "read. It is computed when that resource reconciles, and the edge " &
    "that orders the reconcile before this read is " &
    registrationOrderingEdge(instanceAddress) & " -- whose completion " &
    "is the service's DECLARED READINESS (§7.1), not its " &
    "materialisation. " &
    (if computedHere.len == 0:
       "That resource has computed no attributes at all, so it has not " &
       "reconciled."
     else:
       "Attributes that resource HAS computed: `" &
       computedHere.join("`, `") & "`.") &
    " Returning nil or an empty string is the one answer D-SS10 " &
    "forbids: an empty string is indistinguishable from a legitimately " &
    "empty value, which is how a silent misconfiguration becomes a " &
    "confusing failure somewhere else.")

# ---------------------------------------------------------------------------
# The service node's provider: completion IS the declared readiness.
# ---------------------------------------------------------------------------

proc nodeAttrs(inst: ResourceInstance): SharedServiceNodeAttrs =
  TypedExtensionBox[SharedServiceNodeAttrs](inst.attrs).val

proc readinessSatisfied*(probe: ServiceReadinessProbe): bool =
  ## Evaluate the declared probe ONCE, against the real world.
  case serviceCompletionRule(probe)
  of scrUndeclared, scrExplicitlyNone:
    # A probeless service is never reported satisfied HERE. It cannot
    # order a registration at all (`planRegistrationEdge` refuses it), so
    # this arm is only reachable through a direct call; answering `true`
    # would make the refusal above the only thing standing between a
    # recipe and the race, and one guard is not a guarantee.
    false
  of scrDeclaredReadiness:
    if probe.kind.toLowerAscii() == "fileexists":
      probe.path.len > 0 and fileExists(probe.path)
    else:
      if probe.url.len == 0:
        false
      elif installedProber.isNil:
        raise newException(ReadinessEdgeError,
          "the readiness probe `httpGet " & probe.url & "` cannot be " &
          "evaluated: no prober is installed. This library owns no HTTP " &
          "client by design, so the caller installs one with " &
          "`setServiceReadinessProber`. An absent prober is REFUSED " &
          "rather than read as `ready`: a hook whose absence counted as " &
          "success would reintroduce, inside D-SS10's own fix, exactly " &
          "the listening-but-unseeded race it exists to close.")
      else:
        installedProber(probe.url)

proc serviceNodeIdentity(inst: ResourceInstance): string =
  "shared-service-node:" & nodeAttrs(inst).instanceAddress

proc serviceNodeDigest(inst: ResourceInstance): Digest256 =
  let a = nodeAttrs(inst)
  digestString("reprobuild.shared-service-node\x00" & a.instanceAddress &
    "\x00" & a.readinessKind & "\x00" & a.readinessPath & "\x00" & a.readinessUrl)

proc serviceNodeObserve(inst: ResourceInstance;
                        recorded: Option[ResourceBinding]): ObservedState =
  ## Present IFF the declared probe is satisfied right now. This is the
  ## completion rule: nothing about the process table, nothing about
  ## whether the daemon said `Materialise ok`.
  ##
  ## `recorded` is deliberately UNUSED. A previous run's binding says the
  ## probe was satisfied THEN, and a service that has since been restarted
  ## or re-seeded is a service a registration must wait for again. Reading
  ## the record here would turn the completion rule into a cache of it.
  if readinessSatisfied(probeOf(nodeAttrs(inst))):
    result.present = true
    result.digest = serviceNodeDigest(inst)
  else:
    result.present = false

proc serviceNodeApply(inst: ResourceInstance; action: ResourceActionKind;
                      observed: ObservedState): ResourceBinding =
  ## AWAIT the declared readiness. Reached only when `observe` found the
  ## probe unsatisfied, so this is the wait a dependent would otherwise
  ## have skipped.
  let a = nodeAttrs(inst)
  let probe = probeOf(a)
  if action == rakDestroy:
    return ResourceBinding(address: inst.address, typeId: inst.typeId,
      resourceId: serviceNodeIdentity(inst),
      postWriteDigest: serviceNodeDigest(inst), present: false)
  publish("service.readiness.waiting", a.serviceName,
    "probe=" & probe.kind & " timeoutMs=" & $probe.timeoutMs)
  var waited = 0
  while waited <= probe.timeoutMs:
    if readinessSatisfied(probe):
      publish("service.readiness.satisfied", a.serviceName,
        "probe=" & probe.kind & " waitedMs=" & $waited)
      return ResourceBinding(address: inst.address, typeId: inst.typeId,
        resourceId: serviceNodeIdentity(inst),
        postWriteDigest: serviceNodeDigest(inst), present: true)
    sleep(ReadinessPollIntervalMs)
    waited.inc(ReadinessPollIntervalMs)
  publish("service.readiness.timeout", a.serviceName,
    "probe=" & probe.kind & " waitedMs=" & $waited)
  raise newException(ReadinessEdgeError,
    "service `" & a.serviceName & "` did not COMPLETE: its declared " &
    "readiness probe (" & probe.kind &
    (if probe.path.len > 0: " " & probe.path else: "") &
    (if probe.url.len > 0: " " & probe.url else: "") &
    ") was still unsatisfied after " & $waited & " ms. Every node that " &
    registrationOrderingEdge(a.instanceAddress) &
    " orders is downstream of this, so nothing was registered and no " &
    "attribute was computed -- which is the point: a registration run " &
    "against an instance that never finished seeding would mint " &
    "identifiers against a half-configured issuer.")

# ---------------------------------------------------------------------------
# The registration resource's provider: it computes the attributes.
# ---------------------------------------------------------------------------

proc registrationAttrs(inst: ResourceInstance): ServiceRegistrationAttrs =
  TypedExtensionBox[ServiceRegistrationAttrs](inst.attrs).val

proc registrationIdentity(inst: ResourceInstance): string =
  "shared-service-registration:" & registrationAttrs(inst).instanceAddress

proc registrationDigest(inst: ResourceInstance): Digest256 =
  let a = registrationAttrs(inst)
  digestString("reprobuild.shared-service-registration\x00" &
    a.instanceAddress & "\x00" & a.members.join("\x1f") & "\x00" &
    a.contributors.join("\x1f"))

proc registrationObserve(inst: ResourceInstance;
                         recorded: Option[ResourceBinding]): ObservedState =
  ## ALWAYS absent, so the reconcile always applies.
  ##
  ## That is not laziness. `reconcileServiceRegistrations` is the thing
  ## that decides mint-vs-reuse-vs-withdraw, from its own store record,
  ## and it is idempotent by construction — L8 built it for exactly that.
  ## Reporting present-at-digest here would SKIP it, and the member set a
  ## digest matches is the set this run asked for, not the set the
  ## instance holds: a withdrawal (a member no longer contributed) would
  ## then never run. A no-op decided in the wrong place is the silent drop
  ## this campaign keeps finding.
  result.present = false

proc registrationApply(inst: ResourceInstance; action: ResourceActionKind;
                       observed: ObservedState): ResourceBinding =
  let a = registrationAttrs(inst)
  if action == rakDestroy:
    return ResourceBinding(address: inst.address, typeId: inst.typeId,
      resourceId: registrationIdentity(inst),
      postWriteDigest: registrationDigest(inst), present: false)
  if installedRegistrar.isNil:
    raise newException(ReadinessEdgeError,
      "the registration resource `" & inst.address & "` cannot " &
      "reconcile: no registrar is installed. The thing that registers a " &
      "member against the running instance is INJECTED (" &
      "`setServiceRegistrar`), for the reason " &
      "`ServiceRegistrationMinter` is: this library speaks to no " &
      "issuer. An absent registrar is REFUSED rather than treated as " &
      "`nothing to register`, because a registration that silently " &
      "registers nothing leaves every consumer's `clientId` uncomputed " &
      "and the failure surfaces at the issuer instead of here.")
  let minted = installedRegistrar(a)
  for row in minted:
    # `recordComputedResourceAttribute` refuses an empty value, so an
    # empty minted id is caught HERE rather than on a consumer's argv.
    recordComputedResourceAttribute(
      registrationResourceAddress(a.instanceAddress) & ":" & row.member,
      ClientIdAttributeName, row.mintedId)
  publish("registration.reconciled", a.serviceName,
    "members=" & $a.members.len & " computed=" & $minted.len)
  ResourceBinding(address: inst.address, typeId: inst.typeId,
    resourceId: registrationIdentity(inst),
    postWriteDigest: registrationDigest(inst), present: true)

proc registerReadinessEdgeProviders*() =
  ## Idempotent: register both built-in providers and their attrs
  ## marshallers. Called once at module init below, so the CLI and the
  ## hermetic tests see them without extra wiring — the shape
  ## `registerRunEdgeConsumerProvider` already has.
  registerResourceProvider(ResourceProviderDef(
    typeId: SharedServiceNodeTypeId,
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: serviceNodeIdentity,
      digest: serviceNodeDigest,
      observe: serviceNodeObserve,
      apply: serviceNodeApply)))
  registerExtension[SharedServiceNodeAttrs](SharedServiceNodeTypeId)
  registerResourceProvider(ResourceProviderDef(
    typeId: ServiceRegistrationTypeId,
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: registrationIdentity,
      digest: registrationDigest,
      observe: registrationObserve,
      apply: registrationApply)))
  registerExtension[ServiceRegistrationAttrs](ServiceRegistrationTypeId)

registerReadinessEdgeProviders()

# ---------------------------------------------------------------------------
# The plan: two nodes and the edge between them.
# ---------------------------------------------------------------------------

proc planRegistrationEdge*(serviceName, instanceAddress: string;
                           probe: ServiceReadinessProbe;
                           members, contributors: openArray[string]):
    seq[ResourceInstance] =
  ## Build the desired graph §7.1 describes: the service node, and the
  ## registration resource with an ordinary `dependsOn` onto it.
  ##
  ## REFUSES a probeless service by name before building anything, so the
  ## graph that reaches `reconcileResources` cannot contain an edge whose
  ## completion is undefined.
  ##
  ## The result is handed to the ORDINARY `reconcileResources`. There is
  ## no bespoke driver loop here and there must not be one: the ordering
  ## guarantee is `topoOrder`'s, and a second loop would be a second
  ## place for it to be wrong.
  if not ordersRegistrations(probe):
    refuseRegistrationOnProbelessService(serviceName, instanceAddress, probe)
  if members.len != contributors.len:
    raise newException(ReadinessEdgeError,
      "planRegistrationEdge: " & $members.len & " members and " &
      $contributors.len & " contributors. The two lists are parallel by " &
      "construction, so a length mismatch means they came from " &
      "different folds and the attribution would be wrong.")
  let nodeAddr = serviceNodeAddress(instanceAddress)
  result = @[
    ResourceInstance(
      typeId: SharedServiceNodeTypeId,
      address: nodeAddr,
      attrs: TypedExtensionBox[SharedServiceNodeAttrs](
        typeId: SharedServiceNodeTypeId,
        val: SharedServiceNodeAttrs(
          serviceName: serviceName,
          instanceAddress: instanceAddress,
          readinessKind: probe.kind,
          readinessPath: probe.path,
          readinessUrl: probe.url,
          readinessTimeoutMs: probe.timeoutMs)),
      dependsOn: @[],
      determinism: rdVolatile,
      consumes: @[]),
    ResourceInstance(
      typeId: ServiceRegistrationTypeId,
      address: registrationResourceAddress(instanceAddress),
      attrs: TypedExtensionBox[ServiceRegistrationAttrs](
        typeId: ServiceRegistrationTypeId,
        val: ServiceRegistrationAttrs(
          serviceName: serviceName,
          instanceAddress: instanceAddress,
          members: @members,
          contributors: @contributors)),
      # THE EDGE. An ordinary `dependsOn`, onto the service node, exactly
      # as §7.1 resolved — and the reason this module adds no edge kind.
      dependsOn: @[nodeAddr],
      determinism: rdVolatile,
      consumes: @[])]

proc computedClientIdAddress*(instanceAddress, member: string): string =
  ## Where `registrationApply` records a member's `clientId`. Named so a
  ## reader and a refusal cannot disagree about it.
  registrationResourceAddress(instanceAddress) & ":" & member
