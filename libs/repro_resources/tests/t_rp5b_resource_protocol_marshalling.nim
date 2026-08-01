## RP5b (Provider-Runtime-Protocol-v1.md §5): the resource-lane marshalling
## round-trip. A ``ResourceInstance`` (with its typeId-keyed attrs box), an
## ``ObservedState`` and a ``ResourceBinding`` cross the wire as ``BoxedValue``
## pairs and come back equal. The attrs box round-trips by its OWN resource
## typeId through the shared Typed-Graph-Extensions registry (the same seam
## slice-2 ``marshalAttrs`` uses), so the receiving side needs only the attrs
## marshaller — never the driver.

import std/[options, unittest]

import repro_resources
import repro_project_dsl

type
  ContainerAttrs = object
    image*: string
    cpus*: int

# The provider driver is irrelevant to the marshalling round-trip; we register
# a minimal provider so ``resource(...)``/``digestString`` are usable and the
# attrs marshaller exists.
proc cIdentity(inst: ResourceInstance): string {.nimcall.} =
  "container:" & inst.address
proc cDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  digestString(inst.address)
proc cObserve(inst: ResourceInstance;
              recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  discard
proc cApply(inst: ResourceInstance; action: ResourceActionKind;
            observed: ObservedState): ResourceBinding {.nimcall.} =
  discard

suite "RP5b: resource-lane protocol marshalling round-trip":

  setup:
    resetDesiredResources()
    registerResourceProvider(ResourceProviderDef(
      typeId: "rt.container",
      determinism: rdHostBound,
      driver: ResourceProviderDriver(
        identity: cIdentity, digest: cDigest,
        observe: cObserve, apply: cApply)))
    registerExtension[ContainerAttrs]("rt.container")
    registerResourceProtocolCodecs()

  test "ResourceInstance round-trips (attrs box by typeId)":
    let inst = ResourceInstance(
      typeId: "rt.container",
      address: "web",
      attrs: TypedExtensionBox[ContainerAttrs](
        typeId: "rt.container",
        val: ContainerAttrs(image: "nginx", cpus: 4)),
      dependsOn: @["db", "cache"],
      determinism: rdHostBound)

    let box = boxResourceInstance(inst)
    check box.typeId == ResourceInstanceTypeId
    let back = unboxResourceInstance(box)

    check back.typeId == inst.typeId
    check back.address == inst.address
    check back.dependsOn == inst.dependsOn
    check back.determinism == inst.determinism
    # The attrs box crossed by its OWN resource typeId and rehydrated equal.
    check back.attrs.typeId == "rt.container"
    check TypedExtensionBox[ContainerAttrs](back.attrs).val ==
      TypedExtensionBox[ContainerAttrs](inst.attrs).val

  test "ObservedState round-trips (present/digest/rawBytes)":
    var obs: ObservedState
    obs.present = true
    obs.digest = digestString("some-state")
    obs.rawBytes = @[1'u8, 2'u8, 3'u8, 250'u8]

    let box = boxObservedState(obs)
    check box.typeId == ObservedStateTypeId
    let back = unboxObservedState(box)
    check back.present == obs.present
    check back.digest == obs.digest
    check back.rawBytes == obs.rawBytes

    # The absent case round-trips too.
    var absent: ObservedState
    absent.present = false
    let backAbsent = unboxObservedState(boxObservedState(absent))
    check not backAbsent.present

  test "ResourceBinding round-trips (identity + post-write digest)":
    let b = ResourceBinding(
      address: "web",
      typeId: "rt.container",
      resourceId: "container:web",
      postWriteDigest: digestString("realized"),
      present: true)
    let back = unboxResourceBinding(boxResourceBinding(b))
    check back.address == b.address
    check back.typeId == b.typeId
    check back.resourceId == b.resourceId
    check back.postWriteDigest == b.postWriteDigest
    check back.present == b.present

  test "a wrong-typeId box is a hard error (non-vacuous unbox check)":
    let obsBox = boxObservedState(ObservedState(present: true))
    expect ValueError:
      discard unboxResourceInstance(obsBox)
    expect ValueError:
      discard unboxResourceBinding(obsBox)
