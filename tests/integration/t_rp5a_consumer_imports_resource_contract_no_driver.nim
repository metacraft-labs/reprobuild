## RP5a — a CONSUMER that ``uses:`` a sibling PRODUCER imports the producer's
## resource-type CONTRACT (typed wrapper + typeId/attr/entrypoint schema) at
## COMPILE time, WITHOUT the producer's driver / implementation closure (the
## SC-9 analog for resource types).
##
## Spec: ``Project-Provider-Runtime-Protocol.milestones.org`` §RP5a
## (RESOURCE-CONSUMER-IMPORT) + RP4's ``InterfaceResource``;
## ``Cross-Repo-Source-Consumption.md`` §9.2/§9.3 (usesImportCode accessor
## emission). This test is the resource-type twin of
## ``t_sc_uses_import_resolves_workspace_project_schema``.
##
## For ``executable``/``library`` contracts SC-9 widens consumption by IMPORTING
## the producer's ``repro.nim`` module wholesale. A ``resourceType`` producer
## module cannot cross that way: its expansion emits a module-init
## ``registerResourceProvider(... driver: <driver>)`` referencing the producer's
## DRIVER, and module-init side effects are not dead-code eliminated — importing
## it whole would drag the driver into the consumer, which the RP5a gate forbids.
## So the RP5a ``usesImportCode`` extension detects a resource-declaring sibling
## and emits the consumer's typed surface FROM THE EXTRACTED ``InterfaceResource``
## SCHEMA (``emitResourceContractAccessors``), which carries no driver by
## construction — spliced via a consumer-compile-time ``static:`` + ``include``
## that never imports the producer module.
##
## This test drives the REAL ``uses:`` MACRO-TIME path: the top-level
## ``package rp5aconsumer: uses: "prodres5a"`` block below expands through the
## RP5a wiring, so the sibling ``../prodres5a/repro.nim`` (a resourceType
## producer, discovered relative to THIS file) has its resource contract
## imported into this module's scope. The ``when compiles`` / ``when declared``
## observers then prove, at macro expansion (no repro binary / network / $HOME):
##
##   1. **the typed wrapper crossed.** ``container(address, image, cpus)`` — the
##      producer's ``vm_harness.container`` wrapper — is declared and type-checks
##      in the consumer's scope (``containerCompiles``), and the contract consts
##      (``containerTypeId`` / entrypoint ids) are in scope (``typeIdDeclared``).
##   2. **NO driver closure crossed.** The producer's driver symbol
##      (``containerDriver``) and the registration proc it references
##      (``registerResourceProvider`` is not brought in by the accessor import)
##      are NOT declared in the consumer — only the CONTRACT crossed, the
##      implementation stayed behind (RP5a: no closure). Reinforced by a
##      generated driver-free consumer compile that never imports the producer.
##   3. **FALSIFIABLE (the RP4-deferred gate end):** the producer's attr is
##      ``cpus``; a STALE consumer bind on a NON-existent attribute name
##      (``vcpus``) does NOT compile (``staleBindCompiles`` is false), while the
##      real ``cpus`` bind does. Renaming the producer's attr would flip which
##      of these compiles — the stale bind is a real compile break.

import std/[os, osproc, strutils, unittest]

import repro_project_dsl
import repro_cli_support
import repro_interface_artifacts

# ---------------------------------------------------------------------------
# The CONSUMER package. ``uses: "prodres5a"`` names the sibling workspace
# RESOURCE producer at ``../prodres5a/repro.nim`` (relative to THIS test file:
# ``tests/integration/`` -> ``tests/prodres5a/``). The RP5a ``usesImportCode``
# extension detects its ``resourceType`` block and splices the driver-free typed
# resource surface (the ``container`` wrapper + its ``*TypeId`` /
# ``*ObserveEntrypoint`` / ``*ApplyEntrypoint`` consts) into this module's scope
# WITHOUT importing the producer module (so the producer's ``containerDriver`` /
# ``registerResourceProvider`` module-init closure never crosses). Reaching the
# ``suite`` at all means the wiring imported the contract and it type-checked.
# ---------------------------------------------------------------------------
package rp5aconsumer:
  defaultToolProvisioning "path"

  uses:
    "prodres5a"

  build:
    discard

# ---------------------------------------------------------------------------
# Compile-time observability. The RP5a import brings the producer's typed
# ``container`` wrapper + the ``containerTypeId`` (and entrypoint) consts into
# THIS module's scope, so ``declared`` / ``compiles`` observe whether the
# resource CONTRACT was imported and typed-checked — and whether the producer's
# DRIVER stayed behind.
# ---------------------------------------------------------------------------

# (1) The typed wrapper crossed: the producer's ``container`` wrapper proc is
#     in scope and its typed formals (``image``/``cpus``) type-check.
when compiles(container("web", image = "nginx", cpus = 2)):
  const containerCompiles = true
else:
  const containerCompiles = false

# (1b) The contract metadata const crossed: ``containerTypeId`` is declared (the
#      RP5a accessor emitter emits ``const <wrapper>TypeId* = "<typeId>"``).
when declared(containerTypeId):
  const typeIdDeclared = true
else:
  const typeIdDeclared = false

when declared(containerObserveEntrypoint):
  const observeEntrypointDeclared = true
else:
  const observeEntrypointDeclared = false

# (2) NO DRIVER closure crossed: the producer's ``containerDriver`` value is NOT
#     in the consumer's scope — only the CONTRACT crossed, never the
#     implementation. (A wholesale ``import`` of the producer module would have
#     brought ``containerDriver`` into scope; the accessor-emission path does
#     not.)
when declared(containerDriver):
  const driverDeclared = true
else:
  const driverDeclared = false

# (3) FALSIFIABLE — a STALE bind on a non-existent attribute name (``vcpus``,
#     the renamed-producer twin) does NOT type-check against the imported
#     wrapper (whose formal is ``cpus``). A producer attr rename would flip
#     which of ``cpus`` / ``vcpus`` compiles — the stale bind is a real break.
when compiles(container("web", image = "nginx", vcpus = 2)):
  const staleBindCompiles = true
else:
  const staleBindCompiles = false

# ---------------------------------------------------------------------------
# A supplementary GENERATED-consumer no-closure proof: emit the accessors from
# the extracted contract into a driver-free consumer module that imports ONLY
# ``repro_resources`` (never the producer module) and confirm it type-checks —
# and that a producer attr RENAME breaks a stale bind while a fresh bind
# compiles. This pins the emitted source itself is driver-free + falsifiable,
# complementing the macro-time ``uses:`` proof above.
# ---------------------------------------------------------------------------

const repoRoot = currentSourcePath().parentDir.parentDir.parentDir

const resourceProducerRepro = """
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

package prodres:
  executable placeholder:
    discard
"""

proc compileConsumer(genRoot, accessorSrc, bindStmt: string;
                     nonce: string): tuple[ok: bool, output: string] =
  ## Emit a generated consumer module that imports ONLY ``repro_resources``,
  ## includes the RP5a-emitted resource accessors, and binds the typed wrapper
  ## via ``bindStmt``. It NEVER imports the producer module, so the producer's
  ## driver / ``registerResourceProvider`` are absent. Written UNDER the repo
  ## tree so Nim's config walk loads the repo ``config.nims`` (wiring every
  ## ``libs/<lib>/src`` onto ``--path``). ``nim check`` it and return whether it
  ## type-checks — the driver-free compile-time consumer-import proof.
  let incPath = genRoot / ("rp5a_accessors_" & nonce & ".inc.nim")
  writeFile(incPath, accessorSrc)
  let consumerPath = genRoot / ("rp5a_consumer_" & nonce & ".nim")
  writeFile(consumerPath, """
import repro_resources
include """" & incPath.replace('\\', '/') & """"

proc useAccessor() =
""" & bindStmt & "\n")
  let nimExe = findExe("nim")
  doAssert nimExe.len > 0, "nim compiler not on PATH"
  let (output, code) = execCmdEx(
    nimExe & " check --hints:off --warnings:off" &
      " --nimcache:" & quoteShell(genRoot / ("nc_" & nonce)) &
      " " & quoteShell(consumerPath),
    workingDir = repoRoot)
  (code == 0, output)

suite "RP5a: consumer imports resource contract without driver":

  test "t_rp5a_consumer_imports_resource_contract_no_driver":
    # ---- (1) the REAL ``uses:`` macro path imported the typed contract. ----
    # The top-level ``package rp5aconsumer: uses: "prodres5a"`` block expanded
    # through the RP5a wiring, splicing the sibling's driver-free resource
    # surface into this module's scope.
    check containerCompiles          # the typed wrapper crossed + type-checks
    check typeIdDeclared             # the contract typeId const crossed
    check observeEntrypointDeclared  # the entry-point-id metadata crossed

    # ---- (2) NO driver closure crossed via the ``uses:`` path. ----
    check not driverDeclared         # the producer's ``containerDriver`` absent

    # ---- (3) FALSIFIABLE — a stale bind on a non-existent attr fails. ----
    check not staleBindCompiles      # ``vcpus`` is not a formal (attr is ``cpus``)

    # ---- supplementary generated driver-free consumer proof. ----
    let scratch = getTempDir() / "rp5a-consumer-" & $getCurrentProcessId()
    removeDir(scratch)
    createDir(scratch)
    defer: removeDir(scratch)

    let workspace = absolutePath(scratch / "consumer")
    createDir(workspace)
    let resRoot = absolutePath(scratch / "prodres")
    createDir(resRoot)
    writeFile(resRoot / "repro.nim", resourceProducerRepro)

    let genRoot = repoRoot / "build" / "nimcache" /
      ("rp5a-gen-" & $getCurrentProcessId())
    removeDir(genRoot)
    createDir(genRoot)
    defer: removeDir(genRoot)

    let contract = resolveProducerTypedContract("prodres", workspace)
    check contract.kind == ptckContract
    check hasResourceContract(contract)
    check contract.publicResources.len == 1
    let res = contract.publicResources[0]

    let accessorSrc = emitResourceContractAccessors(contract)
    check accessorSrc.contains("\"vm_harness.container\"")
    check accessorSrc.contains("proc container*")
    check accessorSrc.contains("image: string")
    check accessorSrc.contains("cpus: int")
    check accessorSrc.contains("vm_harness.container.observe")
    check accessorSrc.contains("vm_harness.container.apply")
    check res.typeId == "vm_harness.container"
    check typedContractResourceAttrs(contract, "vm_harness.container") ==
      @["image", "cpus"]

    # The typed surface COMPILES into a driver-free consumer.
    let good = compileConsumer(genRoot, accessorSrc,
      "  discard container(\"web\", image = \"nginx\", cpus = 2)", "good")
    check good.ok
    # The emitted source itself carries NO driver / registration — only the
    # contract crossed.
    check not accessorSrc.contains("containerDriver")
    check not accessorSrc.contains("registerResourceProvider")

    # FALSIFIABILITY on the emitted source: a producer attr rename shifts the
    # wrapper formals, so a stale bind on the old name no longer compiles.
    writeFile(resRoot / "repro.nim",
      resourceProducerRepro.replace("cpus", "vcpus"))
    let renamed = resolveProducerTypedContract("prodres", workspace)
    check hasResourceContract(renamed)
    let renamedAttrs =
      typedContractResourceAttrs(renamed, "vm_harness.container")
    check "vcpus" in renamedAttrs
    check "cpus" notin renamedAttrs
    let renamedSrc = emitResourceContractAccessors(renamed)

    let newBind = compileConsumer(genRoot, renamedSrc,
      "  discard container(\"web\", image = \"nginx\", vcpus = 2)", "new")
    check newBind.ok

    let staleBind = compileConsumer(genRoot, renamedSrc,
      "  discard container(\"web\", image = \"nginx\", cpus = 2)", "stale")
    check not staleBind.ok
