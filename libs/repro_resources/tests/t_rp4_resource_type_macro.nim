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
# The third mirror of the determinism lattice, for the ordinal-alignment
# case at the end of this file. This is the only module in the tree that can
# see all three at once. The submodule is imported directly rather than the
# `repro_core` umbrella so this test does not acquire the solver's runtime
# closure (libclingo) for four `ord` comparisons.
import repro_core/edge_determinism

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

# ---------------------------------------------------------------------------
# Regression guard (RP8 fix): the header typeId may be a CONST identifier bound
# to a string, not only a string literal — the form vm-harness's real provider
# uses (``const TypeContainer = ...`` then ``resourceType TypeContainer:``).
# A ``static string`` param folded a const to its value; the ``untyped`` param
# added for go-to-def must keep that compatibility, so we pin a const-ident
# declaration compiles and registers with the const's string VALUE.
# ---------------------------------------------------------------------------

const TypeContainerConst = "vm_harness.container.constid"

resourceType TypeContainerConst:
  attrs: ContainerAttrs
  wrapper: containerByConst
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
    # Two ``resourceType`` blocks register at module init (the literal-typeId
    # ``vm_harness.container`` under test here + the const-ident regression
    # guard ``…​.constid``); select the one under test by typeId.
    var res: InterfaceResource
    var sawContainer = false
    for r in pi.publicResources:
      if r.typeId == "vm_harness.container":
        res = r
        sawContainer = true
    check sawContainer
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

  test "const-identifier typeId compiles + registers with the const's value":
    # RP8-fix regression guard: ``resourceType TypeContainerConst:`` (a const
    # IDENT header, not a literal) must lower exactly as the literal form —
    # registering under the const's string VALUE and emitting a working wrapper.
    check TypeContainerConst == "vm_harness.container.constid"
    check isResourceProviderRegistered(TypeContainerConst)
    let def = lookupResourceProvider("vm_harness.container.constid")
    check def.determinism == rdVolatile
    check def.driver.apply != nil

    # The wrapper lowers to ``resource(<const value>, ...)`` — the typeId that
    # crosses is the const's VALUE, proving the node was passed through, not
    # rejected or mis-registered under the identifier's name.
    discard containerByConst("svc", image = "nginx", cpus = 1)
    let desired = collectedResources()
    check desired.len == 1
    check desired[0].typeId == "vm_harness.container.constid"

    # Entry-point ids also resolve the const at runtime (``<typeId> & ".op"``).
    let pi = toProjectInterface(hostPkg)
    var found = false
    for res in pi.publicResources:
      if res.typeId == "vm_harness.container.constid":
        found = true
        check res.entrypoints.identity == "vm_harness.container.constid.identity"
        check res.entrypoints.apply == "vm_harness.container.constid.apply"
    check found

  test "a project with no resource type exposes no publicResources":
    # Clear the resource-type interface registry: the SAME host package
    # now lifts to zero resources — the exported schema tracks the
    # (absence of a) declaration, not the package's own members.
    resetResourceTypeInterfaceRegistry()
    let pi = toProjectInterface(hostPkg)
    check pi.publicResources.len == 0
    check pi.publicExecutables.len == 1

  test "the three determinism enums are ordinal-aligned (the RP4 invariant)":
    ## `ResourceDeterminism`, `InterfaceResourceDeterminism` and
    ## `EdgeDeterminism` are three self-contained mirrors of one four-value
    ## lattice, deliberately kept out of each other's import closure and
    ## mapped across by `int(ord(...))`. All three modules' docstrings say a
    ## reorder silently corrupts a lifted class; until this case existed,
    ## none of them said it anywhere a compiler or a test could hear it.
    ##
    ## `t_edge_determinism_vocabulary` pins `EdgeDeterminism`'s own ordinals,
    ## but it lives in `repro_core` and cannot see the other two — so a
    ## reorder of `ResourceDeterminism` would leave it green. This is the one
    ## place in the tree that can import all three at once, which is why the
    ## cross-check belongs here.
    check ord(rdStrong) == ord(irdStrong)
    check ord(rdWeak) == ord(irdWeak)
    check ord(rdHostBound) == ord(irdHostBound)
    check ord(rdVolatile) == ord(irdVolatile)

    check ord(rdStrong) == ord(edStrong)
    check ord(rdWeak) == ord(edWeak)
    check ord(rdHostBound) == ord(edHostBound)
    check ord(rdVolatile) == ord(edVolatile)

    # ...and all three are the SAME four values, not merely pairwise equal on
    # the four names above: an inserted fifth case would keep every line
    # above true and still shift every `int(ord(...))` map that crosses a
    # module boundary.
    check ord(high(ResourceDeterminism)) == 3
    check ord(high(InterfaceResourceDeterminism)) == 3
    check ord(high(EdgeDeterminism)) == 3
    check ord(low(ResourceDeterminism)) == 0
    check ord(low(InterfaceResourceDeterminism)) == 0
    check ord(low(EdgeDeterminism)) == 0
