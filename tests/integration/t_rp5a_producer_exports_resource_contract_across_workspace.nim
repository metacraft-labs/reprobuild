## RP5a — a workspace producer's declared ``resourceType`` (RP4) is a
## CONSUMABLE TYPED RESOURCE CONTRACT keyed by the workspace project name
## (export-by-default; the SC-9 analog for resource types).
##
## Spec: ``Project-Provider-Runtime-Protocol.milestones.org`` §RP5a
## (RESOURCE-CONSUMER-IMPORT) + RP4's ``InterfaceResource``;
## ``Cross-Repo-Source-Consumption.md`` §9 (SC-8/9/10 typed consumer import).
##
## This test drives the RP5a-extended entry point ``resolveProducerTypedContract``
## (in ``repro_cli_support``) directly, hermetically, against real sibling
## producer ``repro.nim`` fixtures in a tempdir — nothing touches $HOME, no
## network / git is required. It is the resource-type twin of
## ``t_sc_producer_exports_typed_cli_contract_across_workspace``. It proves:
##
##   1. **export-by-default resource contract.** A sibling producer declaring a
##      ``resourceType "vm_harness.container"`` block (attrs ``image``/``cpus``,
##      wrapper ``container``, determinism ``rdVolatile``) is discoverable BY THE
##      WORKSPACE PROJECT NAME, and its exported resource schema is exactly the
##      RP4 ``InterfaceResource`` projected off the shipped
##      ``ProjectInterface.publicResources``: the ``typeId``, the determinism
##      class, the typed ``attr`` schema, and the observe/plan/apply entry-point
##      ids. Discovered via BOTH arms — a develop override AND an on-disk sibling.
##   2. **a producer with no resource type exposes NO resource contract.** A
##      sibling declaring only an ``executable`` (no ``resourceType``) resolves
##      to ``ptckContract`` for its executable but ``hasResourceContract`` is
##      false and ``publicResources`` is empty.
##   3. **the driver implementation is absent from the exported contract.** The
##      ``InterfaceResource`` carries only schema (typeId / attrs / entrypoint
##      ids), never the producer's driver value — the contract is what crosses,
##      the implementation stays behind (RP5a: no closure). Asserted structurally
##      (the resource carries entrypoint IDS, i.e. protocol descriptors, not a
##      driver).
##
## Falsifiability (the RP4-deferred gate end): a producer whose resource ``attr``
## is RENAMED (``cpus`` -> ``vcpus``) shifts the exported attribute schema — the
## OLD name disappears and the NEW one appears — so a stale consumer bind on the
## old attribute no longer resolves. Renaming the whole ``typeId`` likewise
## shifts the exported type-id set, so a stale ``producer.<typeId>`` bind is gone.

import std/[os, unittest]

import repro_cli_support
import repro_interface_artifacts

# ---------------------------------------------------------------------------
# Producer fixtures. Each is a real ``repro.nim`` extracted through the shipped
# ``extractInterfaceFromModule`` — the SAME extractor the SC-2/SC-3 splice
# pre-pass uses — so the exported schema is the genuine RP4
# ``ProjectInterface.publicResources``, not a fabricated one. The ``driver`` is
# a plain ``{.nimcall.}`` vtable authored exactly as RP4's lane requires; the
# ``resourceType`` macro registers it but does NOT put it in the interface.
# ---------------------------------------------------------------------------

const resourceProducerHeader = """
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
"""

# (1) A resource-exporting producer. The ``resourceType`` block declares the
#     typed contract a consumer binds.
const producerResourceRepro = resourceProducerHeader & """
resourceType "vm_harness.container":
  attrs: ContainerAttrs
  wrapper: container
  determinism: rdVolatile
  driver: containerDriver
  attr image: string
  attr cpus: int

package prodres:
  executable placeholder:
    discard
"""

# The falsifiability twin: the SAME producer with the ``cpus`` attr RENAMED to
# ``vcpus`` (and the record field renamed to match). The exported attribute
# schema MUST shift — ``cpus`` gone, ``vcpus`` present.
const producerResourceRenamedAttrRepro = """
import repro_project_dsl
import repro_resources
import std/options

type
  ContainerAttrs = object
    image*: string
    vcpus*: int

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
  attr vcpus: int

package prodres:
  executable placeholder:
    discard
"""

# (2) A producer that declares an ``executable`` but NO ``resourceType`` — it
#     has a typed contract (its executable) but exports no resource contract.
const producerNoResourceRepro = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package prodexe:
  defaultToolProvisioning "path"

  uses:
    "sh"

  executable prodexe:
    name: "prodexe"
    cli:
      subcmd "serve":
        flag socket is string
"""

proc writeProducer(root, source: string) =
  createDir(root)
  writeFile(root / "repro.nim", source)

suite "RP5a: producer exports resource contract across workspace":

  test "t_rp5a_producer_exports_resource_contract_across_workspace":
    let scratch = getTempDir() / "rp5a-" & $getCurrentProcessId()
    removeDir(scratch)
    createDir(scratch)
    defer: removeDir(scratch)

    let workspace = absolutePath(scratch / "consumer")
    createDir(workspace)

    let resRoot = absolutePath(scratch / "prodres")
    let exeRoot = absolutePath(scratch / "prodexe")
    writeProducer(resRoot, producerResourceRepro)
    writeProducer(exeRoot, producerNoResourceRepro)

    # ---- (1a) discovery via an ON-DISK WORKSPACE SIBLING. ----
    let resContract = resolveProducerTypedContract("prodres", workspace)
    check resContract.kind == ptckContract
    check resContract.selector == "prodres"
    check resContract.projectName == "prodres"
    check hasTypedContract(resContract)
    check hasResourceContract(resContract)
    # The exported resource contract carries the declared ``typeId``.
    check resContract.publicResources.len == 1
    check typedContractResourceTypeIds(resContract) == @["vm_harness.container"]
    let res = resContract.publicResources[0]
    check res.typeId == "vm_harness.container"
    check res.determinism == irdVolatile
    # The typed ``attr`` schema — the wrapper formals a consumer binds.
    check typedContractResourceAttrs(resContract, "vm_harness.container") ==
      @["image", "cpus"]
    check res.attributes[0].name == "image"
    check res.attributes[0].nimType == "string"
    check res.attributes[1].name == "cpus"
    check res.attributes[1].nimType == "int"
    # (3) The producer's DRIVER is absent: what crossed is protocol entry-point
    #     descriptors (ids), not a driver value. Only schema crossed the
    #     boundary (the interface artifact has no driver field at all).
    check res.entrypoints.observe == "vm_harness.container.observe"
    check res.entrypoints.plan == "vm_harness.container.plan"
    check res.entrypoints.apply == "vm_harness.container.apply"

    # ---- (1b) discovery via a DEVELOP OVERRIDE (the other arm). ----
    createDir(workspace / ".repro")
    writeFile(workspace / ".repro" / "develop-overrides.toml", """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "prodres"
local_path = "../prodres"
state = "editable"
created_at = "2026-07-02T00:00:00Z"
""")
    let resViaOverride = resolveProducerTypedContract("prodres", workspace)
    check resViaOverride.kind == ptckContract
    check hasResourceContract(resViaOverride)
    check typedContractResourceTypeIds(resViaOverride) ==
      @["vm_harness.container"]
    check typedContractResourceAttrs(resViaOverride, "vm_harness.container") ==
      @["image", "cpus"]
    removeFile(workspace / ".repro" / "develop-overrides.toml")

    # ---- (2) a producer with NO resource type exposes NO resource contract. ----
    let exeContract = resolveProducerTypedContract("prodexe", workspace)
    check exeContract.kind == ptckContract          # it DOES export an executable
    check exeContract.publicExecutables.len == 1
    check not hasResourceContract(exeContract)      # but NO resource contract
    check exeContract.publicResources.len == 0
    check typedContractResourceTypeIds(exeContract).len == 0

    # ---- FALSIFIABILITY: a renamed resource ``attr`` shifts the schema. ----
    writeFile(resRoot / "repro.nim", producerResourceRenamedAttrRepro)
    let renamed = resolveProducerTypedContract("prodres", workspace)
    check renamed.kind == ptckContract
    check hasResourceContract(renamed)
    let renamedAttrs =
      typedContractResourceAttrs(renamed, "vm_harness.container")
    check "vcpus" in renamedAttrs        # the NEW attr appears
    check "cpus" notin renamedAttrs      # the OLD attr is gone
    check "image" in renamedAttrs        # the untouched attr stays
