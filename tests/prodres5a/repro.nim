## RP5a fixture — a workspace PRODUCER project exporting a ``resourceType``
## (RP4) typed RESOURCE contract (export-by-default; the SC-9 analog for
## resource types).
##
## Consumed by the sibling consumer in
## ``tests/integration/t_rp5a_consumer_imports_resource_contract_no_driver.nim``
## via ``uses: "prodres5a"``: the RP5a ``usesImportCode`` extension discovers
## this sibling (``../prodres5a/repro.nim`` relative to the consumer source),
## detects the ``resourceType`` block, and — instead of importing this module
## wholesale (which would drag the ``containerDriver`` /
## ``registerResourceProvider`` module-init closure into the consumer) — emits
## the driver-free typed wrapper + contract FROM THE EXTRACTED
## ``InterfaceResource`` schema. The consumer then binds
## ``container(address, image, cpus)`` type-checked against THIS schema at its
## macro expansion, WITHOUT the driver crossing.
##
## Renaming the ``cpus`` attr / the ``vm_harness.container`` typeId here shifts
## the exported schema and is a COMPILE break at any stale consumer bind.

import repro_project_dsl
import repro_resources
import std/options

type
  ContainerAttrs = object
    image*: string
    cpus*: int

proc cIdentity(inst: ResourceInstance): string {.nimcall.} =
  "container:" & inst.address

proc cDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  digestString(inst.address)

proc cObserve(inst: ResourceInstance;
              recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  result.present = false

proc cApply(inst: ResourceInstance; action: ResourceActionKind;
            observed: ObservedState): ResourceBinding {.nimcall.} =
  ResourceBinding(address: inst.address, typeId: inst.typeId,
    resourceId: cIdentity(inst), present: true)

let containerDriver = ResourceProviderDriver(
  identity: cIdentity, digest: cDigest, observe: cObserve, apply: cApply)

resourceType "vm_harness.container":
  attrs: ContainerAttrs
  wrapper: container
  determinism: rdVolatile
  driver: containerDriver
  attr image: string
  attr cpus: int

package prodres5a:
  executable placeholder:
    discard
