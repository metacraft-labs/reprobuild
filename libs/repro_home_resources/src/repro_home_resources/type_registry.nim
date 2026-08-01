## Native resource-type registry for the home-scope engine.
##
## This is Migration step 1 of `Composable-Resource-Types.md` for the
## home scope: the closed `case kind` dispatch in `lifecycle.nim`
## (`digestOfResource`) and `plan.nim` (`observeResource`) is replaced
## by a registry lookup. Each built-in `ResourceKind` is wrapped as a
## registered `ResourceTypeDef` whose `driver` points at the existing
## per-kind leaf procs, so behavior is unchanged; the closed enum
## becomes an implementation detail behind a `typeId`-keyed table.
##
## Import-cycle note: this module deliberately imports ONLY `types`
## (for `Resource` / `ObservedState`) and `repro_home_generations`
## (for `Digest256`). It does NOT import `lifecycle`, `plan`, or the
## `drivers/*` modules — those depend on the leaf operations, not on
## the registry container. The concrete `ResourceTypeDef` values are
## assembled and registered in `builtin_registrations.nim`, which is
## free to import lifecycle + plan without creating a cycle back into
## this module.

import std/[tables]

import repro_home_generations

import ./types

type
  ResourceDeterminism* = enum
    ## The determinism class a resource type declares
    ## (`Composable-Resource-Types.md` "Determinism"). Slice 1 only
    ## POPULATES this field correctly; soft-rebuild consumption is a
    ## later slice.
    ##
    ## RP4 INVARIANT: `repro_interface_artifacts`'s
    ## `InterfaceResourceDeterminism` (`irdStrong .. irdVolatile`) is an
    ## ordinal-aligned mirror of this enum — it deliberately does NOT
    ## import this module (to keep the blake3 / home-resources closure
    ## out of the interface-artifacts codec), and maps across by
    ## `int(ord(...))`. The `rdStrong=0 .. rdVolatile=3` ordering below
    ## MUST stay in lockstep with that mirror; reordering or inserting a
    ## case here without updating the mirror silently corrupts a lifted
    ## `InterfaceResource.determinism`.
    rdStrong        ## bytewise reproducible; cross-machine substitutable
    rdWeak          ## reproducible up to declared noise; default for tools
    rdHostBound     ## realization is machine-specific (a snapshot, a
                    ## registry); NO cross-machine substitution by default
    rdVolatile      ## inherently non-reproducible (a launched VM/container)

  ResourceDriver* = object
    ## The native analog of a Terraform provider's Read/Plan/Apply
    ## RPCs, restricted to the leaf operations the home-scope engine
    ## dispatches on the DESIRED `Resource` today. Each callback is a
    ## `{.nimcall.}` proc so the driver is a plain value living in the
    ## registry.
    ##
    ## Slice 1 wires the two operations that today switch on
    ## `desired.kind` / `r.kind`:
    ##   * `digest` — `lifecycle.digestOfResource`
    ##   * `observe` — `plan.observeResource`
    ## There is no central `apply` case in the home engine (apply is
    ## dispatched per-driver-module, keyed by the recorded binding),
    ## so `apply` is intentionally absent from the driver here.
    digest*: proc(r: Resource): Digest256 {.nimcall.}
    observe*: proc(r: Resource): ObservedState {.nimcall.}

  ResourceTypeDef* = object
    typeId*: string                       ## stable, e.g. "fs.managedBlock"
    determinism*: ResourceDeterminism
    driver*: ResourceDriver

# A plain module global (populated once at import-time module init on the main
# thread), NOT a threadvar: this mirrors `registerPackageDef`'s
# `var registry: seq[PackageDef]` in repro_project_dsl/runtime_core.nim, and —
# unlike a threadvar — stays visible to the engine regardless of which thread
# runs a lookup. A threadvar would be empty on any thread that did not itself
# run the built-in registration, a latent trap once dispatch runs off the main
# thread (e.g. in the provider process). Read-mostly after init.
var resourceTypeRegistry: Table[string, ResourceTypeDef]

proc registerResourceType*(def: ResourceTypeDef) =
  ## Register (or replace) a resource type by its stable `typeId`.
  ## The resource analog of `registerPackageDef`.
  resourceTypeRegistry[def.typeId] = def

proc lookupResourceType*(typeId: string): ResourceTypeDef =
  ## Fetch the registered type for `typeId`. Raises a clear error on
  ## an unknown id — an unregistered resource type is a hard,
  ## diagnosable error, never a silent zeroed default.
  if not resourceTypeRegistry.hasKey(typeId):
    raise newException(KeyError,
      "no resource type registered for typeId '" & typeId &
      "'; the home-scope built-ins register themselves when " &
      "`repro_home_resources` is imported")
  resourceTypeRegistry[typeId]

proc isResourceTypeRegistered*(typeId: string): bool =
  ## Test seam: whether a `typeId` has a registered driver.
  resourceTypeRegistry.hasKey(typeId)

proc registeredResourceTypeIds*(): seq[string] =
  ## Test seam: the set of registered `typeId`s (unordered).
  result = @[]
  for k in resourceTypeRegistry.keys:
    result.add(k)
