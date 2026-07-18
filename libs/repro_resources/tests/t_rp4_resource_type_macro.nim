## RP4 (Provider-Runtime-Protocol-v1 §5): the ``resourceType`` DSL macro.
##
## Pins that ONE ``resourceType`` declaration emits, in a single block:
##   (a) the ``registerResourceProvider`` + ``registerExtension``
##       registrations, so the slice-2 runtime lane still reconciles a
##       trivial instance (reusing the ``t_resource_provider_lane``
##       pattern);
##   (b) the typed wrapper proc that lowers to ``resource(...)``;
##   (c) the ``InterfaceResource`` contribution — a package declaring the
##       resource type exposes it in the extracted
##       ``ProjectInterface.publicResources`` with the right typeId /
##       determinism / attribute schema / entry-point descriptors, and a
##       project with NO resource type exposes none.
##
## Falsifiability (SC-8): the attribute names + resource-op entrypoints
## in the exported schema are derived from the DECLARATION, so renaming
## an ``attr`` or an op shifts the exported contract. The codec test
## (``t_rp4_resource_codec_roundtrip.nim``) proves that such a shift
## changes the interface fingerprint and would break a stale consumer
## bind; here we assert the exported schema tracks the declaration.

import std/[tables, options, unittest]

import repro_resources
import repro_project_dsl
import repro_interface_artifacts

# ---------------------------------------------------------------------------
# A mock provider driver, authored exactly as slice 2's lane requires:
# plain ``{.nimcall.}`` procs over ``ResourceInstance``. The ``resourceType``
# macro registers this driver; it does NOT synthesise driver bodies.
# ---------------------------------------------------------------------------

type
  ContainerAttrs = object
    image*: string
    cpus*: int

var world {.threadvar.}: Table[string, string]
var applied {.threadvar.}: seq[string]

proc cIdentity(inst: ResourceInstance): string {.nimcall.} =
  "container:" & inst.address

proc cDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  let a = TypedExtensionBox[ContainerAttrs](inst.attrs).val
  digestString(inst.address & "\x00" & a.image & "\x00" & $a.cpus)

proc cObserve(inst: ResourceInstance;
              recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  let id = cIdentity(inst)
  if world.hasKey(id):
    result.present = true
    result.digest = digestString(inst.address & "\x00" & world[id])
  else:
    result.present = false

proc cApply(inst: ResourceInstance; action: ResourceActionKind;
            observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = TypedExtensionBox[ContainerAttrs](inst.attrs).val
  applied.add(inst.address)
  world[cIdentity(inst)] = a.image & "\x00" & $a.cpus
  result = ResourceBinding(
    address: inst.address,
    typeId: inst.typeId,
    resourceId: cIdentity(inst),
    postWriteDigest: cDigest(inst),
    present: true)

let containerDriver = ResourceProviderDriver(
  identity: cIdentity,
  digest: cDigest,
  observe: cObserve,
  apply: cApply)

# ---------------------------------------------------------------------------
# THE MACRO UNDER TEST — one declaration, five lowerings.
# ---------------------------------------------------------------------------

resourceType "vm_harness.container":
  attrs: ContainerAttrs
  wrapper: container
  determinism: rdVolatile
  driver: containerDriver
  attr image: string
  attr cpus: int

# The DSL ``package`` macro must expand at module top level. Declare the
# host package here; the tests below read it via ``toProjectInterface``.
resetPackageRegistry()

package `rp4_host`:
  uses:
    "nim >=2.2 <3.0"
  executable placeholder:
    discard

let hostPkg = registeredPackages()[0]

suite "RP4: resourceType macro":

  setup:
    world = initTable[string, string]()
    applied = @[]
    resetDesiredResources()

  test "macro registered the provider + marshaller (runtime lane works)":
    check isResourceProviderRegistered("vm_harness.container")
    let def = lookupResourceProvider("vm_harness.container")
    check def.determinism == rdVolatile
    check def.driver.apply != nil

    # The typed wrapper lowers to ``resource(...)`` + reconcile applies it.
    discard container("web", image = "nginx", cpus = 2)
    let desired = collectedResources()
    check desired.len == 1
    check desired[0].typeId == "vm_harness.container"
    check desired[0].determinism == rdVolatile

    let r = reconcileResources(desired)
    check r.actions.len == 1
    check r.actions[0].kind == rakCreate
    check applied == @["web"]

    # attrs box round-trips by typeId (the registerExtension marshaller).
    let wire = marshalAttrs(desired[0].attrs)
    let back = unmarshalAttrs("vm_harness.container", wire)
    check TypedExtensionBox[ContainerAttrs](back).val ==
      TypedExtensionBox[ContainerAttrs](desired[0].attrs).val

  test "resource type is lifted into ProjectInterface.publicResources":
    # The module-init ``resourceType`` populated the resource-type
    # interface registry; ``toProjectInterface`` folds it in.
    let pi = toProjectInterface(hostPkg)
    check pi.publicExecutables.len == 1
    check pi.publicResources.len == 1
    let res = pi.publicResources[0]
    check res.typeId == "vm_harness.container"
    check res.determinism == irdVolatile
    # Attribute schema tracks the declaration order + types.
    check res.attributes.len == 2
    check res.attributes[0].name == "image"
    check res.attributes[0].nimType == "string"
    check res.attributes[1].name == "cpus"
    check res.attributes[1].nimType == "int"
    # Entry-point descriptors are the driver ops as ``<typeId>.<op>``.
    check res.entrypoints.identity == "vm_harness.container.identity"
    check res.entrypoints.digest == "vm_harness.container.digest"
    check res.entrypoints.observe == "vm_harness.container.observe"
    check res.entrypoints.plan == "vm_harness.container.plan"
    check res.entrypoints.apply == "vm_harness.container.apply"

  test "a project with no resource type exposes no publicResources":
    # Clear the resource-type interface registry: the SAME host package
    # now lifts to zero resources — the exported schema tracks the
    # (absence of a) declaration, not the package's own members.
    resetResourceTypeInterfaceRegistry()
    let pi = toProjectInterface(hostPkg)
    check pi.publicResources.len == 0
    check pi.publicExecutables.len == 1
