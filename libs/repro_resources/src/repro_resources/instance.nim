## The generic desired-resource value + provider driver + registry for
## the external-provider lane (`Composable-Resource-Types.md` slice 2).
##
## This is the SELF-CONTAINED generic lane: it operates on a
## `typeId`-tagged, type-erased `ResourceInstance` rather than the
## home-scope `Resource` union, so a downstream repo (vm-harness,
## infra) can define resource TYPES in its own source and have a
## generic reconciler drive them through a registered driver — the
## resource analog of how `package` lowers to a generic `PackageDef`.
##
## Relationship to slice 1 (`repro_home_resources/type_registry.nim`):
## slice 1's `ResourceDriver` operates on the home `Resource` union and
## deliberately has NO `apply` (home apply is per-driver-module keyed by
## the recorded binding). Generalizing it to `ResourceInstance` would
## force the home union into every external consumer and disturb the
## clean home-scope engine. This lane therefore uses a SIBLING generic
## registry, but REUSES slice 1's `ResourceDeterminism` enum (imported,
## not redefined) and the home-lib value types (`Digest256`,
## `ObservedState`, `ResourceActionKind`) so the two lanes speak the
## same determinism/decision vocabulary. Unifying the built-ins onto
## this lane is the spec's later migration step, out of scope here.

import std/[tables, options]

import blake3
from repro_home_generations/pointer import Digest256
import repro_home_resources/type_registry     # ResourceDeterminism
from repro_home_resources/types import ObservedState, ResourceActionKind
import repro_project_dsl                        # ExtensionBox / TypedExtensionBox

export ResourceDeterminism          # rdStrong / rdWeak / rdHostBound / rdVolatile
export ObservedState, ResourceActionKind
export ExtensionBox, TypedExtensionBox
export Digest256

type
  ResourceInstance* = object
    ## The generic desired-resource value: a stable `typeId` plus a
    ## type-erased attribute payload, exactly as `PackageDef` is
    ## generic over package contents. Marshalled provider->client by
    ## `Typed-Graph-Extensions.md` boxing keyed on `typeId`.
    typeId*: string                 ## -> resourceProviderRegistry
    address*: string                ## stable DSL address, the graph node key
    attrs*: ExtensionBox            ## typed attribute payload (Typed-Graph-Extensions)
    dependsOn*: seq[string]         ## resource addresses; the graph edges
    determinism*: ResourceDeterminism ## per-instance determinism (may narrow the type default)

  ResourceBinding* = object
    ## The generic recorded-binding value returned by `apply` — a
    ## minimal, codec-free analog of the home-scope on-disk
    ## `ResourceBinding` (whose manifest shape is intentionally NOT
    ## coupled here). Retains the identity and the post-write digest a
    ## later reconcile compares against for cache-hit / drift.
    address*: string
    typeId*: string
    resourceId*: string             ## real-world identity (driver.identity)
    postWriteDigest*: Digest256     ## digest of the state actually realized
    present*: bool                  ## false after a destroy

  ResourceProviderDriver* = object
    ## The generic native analog of a Terraform provider's
    ## Read/Plan/Apply RPCs, operating on `ResourceInstance`. Each
    ## callback is a `{.nimcall.}` proc so the driver is a plain value
    ## living in the registry and invocable by the generic engine.
    identity*: proc(inst: ResourceInstance): string {.nimcall.}
      ## stable real-world identity used to correlate desired <-> recorded.
    digest*: proc(inst: ResourceInstance): Digest256 {.nimcall.}
      ## canonical content digest of the DESIRED state (the cache-hit test).
    observe*: proc(inst: ResourceInstance;
                   recorded: Option[ResourceBinding]): ObservedState {.nimcall.}
      ## read current real-world state (Terraform ReadResource).
    apply*: proc(inst: ResourceInstance; action: ResourceActionKind;
                 observed: ObservedState): ResourceBinding {.nimcall.}
      ## perform the create/update/destroy; return the new recorded binding.

  ResourceProviderDef* = object
    typeId*: string                 ## stable, e.g. "vm_harness.container"
    determinism*: ResourceDeterminism
    driver*: ResourceProviderDriver

# ---------------------------------------------------------------------------
# Provider registry — a plain module global (mirror of
# `registerPackageDef`'s `var registry: seq[PackageDef]`), NOT a
# threadvar: the driver vtable must be visible to the engine on whatever
# thread runs a reconcile, regardless of which thread ran registration.
# ---------------------------------------------------------------------------

var resourceProviderRegistry: Table[string, ResourceProviderDef]

proc registerResourceProvider*(def: ResourceProviderDef) =
  ## Register (or replace) a resource provider by its stable `typeId`.
  ## The generic-lane analog of `registerPackageDef` /
  ## `registerResourceType`.
  resourceProviderRegistry[def.typeId] = def

proc lookupResourceProvider*(typeId: string): ResourceProviderDef =
  ## Fetch the registered provider for `typeId`. An unknown id is a
  ## HARD, diagnosable error (never a silent skip): unlike a
  ## forward-compat metadata extension, an unknown *resource* cannot be
  ## dropped — its state would silently never converge.
  if not resourceProviderRegistry.hasKey(typeId):
    raise newException(KeyError,
      "no resource provider registered for typeId '" & typeId &
      "'; the defining repo must link the module that calls " &
      "registerResourceProvider(...) into this process")
  resourceProviderRegistry[typeId]

proc isResourceProviderRegistered*(typeId: string): bool =
  ## Test seam: whether a `typeId` has a registered provider.
  resourceProviderRegistry.hasKey(typeId)

proc registeredResourceProviderIds*(): seq[string] =
  ## Test seam: the set of registered provider `typeId`s (unordered).
  result = @[]
  for k in resourceProviderRegistry.keys:
    result.add(k)

# ---------------------------------------------------------------------------
# Digest helper reused by drivers that want the default content-hash.
# ---------------------------------------------------------------------------

proc digestBytes*(bytes: openArray[byte]): Digest256 =
  ## BLAKE3-256 over canonical bytes — the same primitive the home lib
  ## uses, exposed so external drivers can compute a desired-state
  ## digest without re-deriving it.
  blake3.digest(bytes)

proc digestString*(s: string): Digest256 =
  blake3.digest(s)
