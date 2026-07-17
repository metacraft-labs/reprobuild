## The low-level instantiation surface: `resource(...)` boxes a typed
## attribute record into a `ResourceInstance` and registers it into a
## plain-global desired-resource collection — mirroring how
## `registerPackageDef` collects packages. It returns a `ResourceRef`
## whose `.address` can seed another resource's `dependsOn`.
##
## A defining repo exports a thin typed wrapper proc (e.g. `container`)
## that lowers to `resource(...)`; that wrapper is ordinary composable
## Nim the downstream repo ships, giving strong typing and navigation
## without any macro. The optional `resourceType` block macro is NOT
## implemented in slice 2 (see the campaign notes): the proc-based
## `registerResourceProvider` + typed wrapper procs are the required,
## load-bearing composability.

import repro_resources/instance
import repro_project_dsl          # TypedExtensionBox / ExtensionBox

type
  ResourceRef* = object
    ## Handle returned by `resource(...)`. `.address` seeds a
    ## dependent resource's `dependsOn`.
    address*: string

# Plain module global (mirror of `registerPackageDef`'s
# `var registry: seq[PackageDef]`), NOT a threadvar: the desired graph
# is assembled on one thread during DSL evaluation.
var desiredResources: seq[ResourceInstance] = @[]

proc resetDesiredResources*() =
  ## Test / re-evaluation seam: clear the collected desired graph.
  desiredResources.setLen(0)

proc collectedResources*(): seq[ResourceInstance] =
  ## The desired resource graph collected so far, in declaration order.
  desiredResources

proc resource*[T](typeId: string; address: string; attrs: T;
                  dependsOn: seq[string] = @[]): ResourceRef =
  ## Low-level generic instantiation. Boxes the typed attribute record
  ## `attrs` into a `ResourceInstance` (carrying the provider's declared
  ## determinism) and registers it into the desired-resource
  ## collection. The `typeId` MUST already be registered via
  ## `registerResourceProvider` (an unknown id is a hard error), which
  ## both supplies the determinism class and — through the paired
  ## `registerExtension[T](typeId)` — makes the attrs box marshallable.
  let def = lookupResourceProvider(typeId)   # hard-errors on unknown typeId
  let box: ExtensionBox = TypedExtensionBox[T](typeId: typeId, val: attrs)
  desiredResources.add(ResourceInstance(
    typeId: typeId,
    address: address,
    attrs: box,
    dependsOn: dependsOn,
    determinism: def.determinism))
  ResourceRef(address: address)
