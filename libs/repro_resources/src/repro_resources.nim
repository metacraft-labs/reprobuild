## Reprobuild generic external-provider resource lane
## (`Composable-Resource-Types.md` slice 2).
##
## Public surface:
##
##   * `ResourceInstance` — the generic, `typeId`-tagged desired-resource
##     value with a type-erased (`ExtensionBox`) attribute payload.
##   * `ResourceProviderDriver` / `ResourceProviderDef` +
##     `registerResourceProvider` — a plain-global provider registry
##     (mirror of `registerPackageDef`) whose driver vtable operates on
##     `ResourceInstance`.
##   * `resource(typeId, address, attrs, dependsOn)` — the low-level
##     instantiation surface that boxes attrs and collects a desired
##     graph; a defining repo exports thin typed wrapper procs on top.
##   * `reconcileResources` — the generic dependency-ordered reconciler
##     that dispatches every leaf op through the registered driver.
##   * `marshalAttrs` / `unmarshalAttrs` — provider<->client attribute
##     marshalling reusing the Typed-Graph-Extensions registry.
##
## Determinism is reused from slice 1 (`ResourceDeterminism`); this lane
## is deliberately self-contained and does NOT rewrite the home-scope or
## system-scope engines.

import repro_resources/instance
import repro_resources/collect
import repro_resources/reconcile
import repro_resources/marshal
import repro_resources/resource_type

export instance
export collect
export reconcile
export marshal
export resource_type
