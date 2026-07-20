## TI2 (Production Thin Interface Mode consumer) — the SEPARATE-RESOURCE-MODULE
## producer path (the RP5c2 vm-harness shape). A producer keeps its
## ``resourceType`` blocks in a SEPARATE subdirectory module
## (``repro/resources.nim``) and NAMES it from ``repro.nim`` via a
## ``resourceModule "<path>": path "<dir>"`` surface entry — NOT inline in
## ``repro.nim``, and NOT imported into the producer's core build. A consumer
## that ``uses:`` this producer must STILL be routed to the driver-free accessor
## splice (never SC-9's wholesale module import), the cached lift must reflect the
## separate module's ``publicResources``, and editing the separate module's
## PUBLIC schema must invalidate the consumer's cached accessor.
##
## Spec: Project-Interface-Artifacts-And-Import-Modes.md §"Import Modes" (Thin
## Interface Mode); Project-Provider-Runtime-Protocol.milestones.org §TI2 (the
## separate-resource-module fix); RP5c2 vm-harness layout.
##
## This is the non-inline counterpart of
## ``t_ti2_thin_interface_consumer_reads_cached_artifact`` (which uses an inline
## ``resourceType`` producer). It proves three properties by compiling REAL
## consumer ``repro.nim`` modules as subprocesses and observing the accessor
## generation WITNESS + the emitted cache:
##
##   1. **Detected + routed to the accessor splice (no driver closure).** The
##      separate-module producer IS detected as a resource producer (via the
##      ``resourceModule`` surface entry → its module's ``resourceType`` block),
##      so the consumer is routed to the driver-free accessor splice, NOT SC-9's
##      wholesale import. Asserted: the consumer compiles, and the cached
##      accessor source carries no driver / ``registerResourceProvider``.
##
##   2. **Coherent freshness over the SEPARATE module (NON-VACUOUS staleness).**
##      Editing the subdirectory resource module's PUBLIC schema (``cpus`` →
##      ``vcpus``) — a change a root-only stamp would MISS — invalidates the
##      consumer's cached accessor: the next consumer RE-generates (witness
##      grows) against the NEW schema; a STALE ``cpus`` bind no longer
##      type-checks while the new ``vcpus`` bind compiles.
##
##   3. **Shared cached lift is a HIT on unchanged.** A second consumer of the
##      unchanged producer is a CACHE HIT (witness does not grow) — the lift ran
##      once and is shared.

import std/[os, osproc, strutils, unittest]

const repoRoot = currentSourcePath().parentDir.parentDir.parentDir

# ---------------------------------------------------------------------------
# The SEPARATE resource module — carries the ``resourceType`` block + its
# driver. Lives in a SUBDIRECTORY (``repro/resources.nim``), the vm-harness
# shape. NOT inline in the producer ``repro.nim``.
# ---------------------------------------------------------------------------

const resourcesModule = """
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
"""

# ---------------------------------------------------------------------------
# The producer ``repro.nim`` — declares the SEPARATE module via a
# ``resourceModule`` surface entry. It imports ONLY ``repro_project_dsl`` (never
# ``repro/resources``), so a producer core build stays driver-free.
# ---------------------------------------------------------------------------

const producerRepro = """
import repro_project_dsl

resourceModule "repro/resources.nim":
  path "."

package producer:
  executable placeholder:
    discard
"""

proc consumerRepro(bindStmt: string): string =
  """
import repro_project_dsl

package theconsumer:
  defaultToolProvisioning "path"

  uses:
    "producer"

  build:
    discard

proc useContainer() =
""" & bindStmt & "\n"

proc countWitness(path: string): int =
  if not fileExists(path):
    return 0
  for line in readFile(path).splitLines:
    if line.strip.len > 0:
      inc result

proc writeProducer(producerDir: string; resourcesSrc: string) =
  createDir(producerDir)
  createDir(producerDir / "repro")
  writeFile(producerDir / "repro.nim", producerRepro)
  writeFile(producerDir / "repro" / "resources.nim", resourcesSrc)

proc compileConsumer(consumerDir, witnessPath, bindStmt, nimcache: string;
                     checkOnly = false): tuple[ok: bool, output: string] =
  createDir(consumerDir)
  writeFile(consumerDir / "repro.nim", consumerRepro(bindStmt))
  let nimExe = findExe("nim")
  doAssert nimExe.len > 0, "nim compiler not on PATH"
  let env = "REPRO_TI2_ACCESSOR_WITNESS=" & quoteShell(witnessPath)
  let compileVerb =
    if checkOnly:
      "check --hints:off --warnings:off"
    else:
      "c --compileOnly --hints:off --warnings:off -o:" &
        quoteShell(nimcache / "consumer_bin")
  let cmd =
    env & " " & nimExe & " " & compileVerb &
    " --nimcache:" & quoteShell(nimcache) &
    " " & quoteShell(consumerDir / "repro.nim")
  let (output, code) = execCmdEx("cd " & quoteShell(repoRoot) & " && " & cmd)
  (code == 0, output)

suite "TI2: separate-module producer (vm-harness shape)":

  test "t_ti2_separate_module_producer_detected_fresh_and_shared":
    let base = repoRoot / "build" / "nimcache" /
      ("ti2-sepmod-fixtures-" & $getCurrentProcessId())
    removeDir(base)
    createDir(base)
    defer: removeDir(base)

    # Clean the producer-keyed accessor cache so this run starts COLD.
    let accCache = repoRoot / "build" / "nimcache" / "ti2-resource-accessors" /
      "producer"
    removeDir(accCache)

    let producerDir = base / "producer"
    writeProducer(producerDir, resourcesModule)

    let witness = base / "witness.log"

    # ---- (1) FIRST consumer — COLD: detected + the generator runs ONCE. ----
    # The separate-module producer must be routed to the accessor splice (not
    # SC-9's wholesale import). If detection failed, the consumer would import
    # the producer's ``repro.nim`` wholesale — which does NOT export ``container``
    # (the wrapper is emitted only via the accessor splice), so the bind would
    # not type-check. A green compile here proves the accessor-splice routing.
    let c1 = compileConsumer(base / "consumer1", witness,
      "  discard container(\"web\", image = \"nginx\", cpus = 2)",
      base / "nc1")
    check c1.ok                          # detected + contract crossed + bind ok
    check countWitness(witness) == 1     # exactly one cold generation

    # ---- No driver closure crossed (assert on the emitted accessor cache). ----
    let cachedAccessors = readFile(accCache / "producer.accessors.nim")
    check cachedAccessors.contains("proc container*")
    check cachedAccessors.contains("\"vm_harness.container\"")
    check not cachedAccessors.contains("containerDriver")
    check not cachedAccessors.contains("registerResourceProvider")

    # ---- (3, checked before the edit) SECOND consumer — CACHE HIT: shared. ----
    # Compiled under ``nim check`` (cannot run ``staticExec``) — still sees the
    # ``container`` wrapper via the exec-free VM read, and the witness does NOT
    # grow: the lift ran once, shared across consumers.
    let c2 = compileConsumer(base / "consumer2", witness,
      "  discard container(\"api\", image = \"redis\", cpus = 4)",
      base / "nc2", checkOnly = true)
    check c2.ok
    check countWitness(witness) == 1     # STILL one — shared cached lift

    # ---- (2) NON-VACUOUS staleness over the SEPARATE module. Edit the
    #          SUBDIRECTORY resource module's public schema (``cpus`` → ``vcpus``).
    #          A ROOT-ONLY stamp would MISS this (the edit is not in the project
    #          root) and serve a STALE accessor. The recursive stamp folds the
    #          resource-module closure in, so the stamp shifts and the next
    #          consumer RE-generates against the NEW schema. ----
    writeFile(producerDir / "repro" / "resources.nim",
      resourcesModule.replace("cpus", "vcpus"))

    # A consumer binding the NEW attr name compiles AND forces a re-gen.
    let cNew = compileConsumer(base / "consumer3", witness,
      "  discard container(\"db\", image = \"pg\", vcpus = 8)",
      base / "nc3")
    check cNew.ok
    check countWitness(witness) == 2     # the separate-module edit forced re-gen

    # A consumer binding the STALE attr name (``cpus``) no longer type-checks —
    # the falsifiable end. The cache is fresh from consumer3's re-gen, so this
    # reads the NEW-schema accessor on the fast path and the stale bind fails.
    let cStale = compileConsumer(base / "consumer4", witness,
      "  discard container(\"cache\", image = \"mc\", cpus = 8)",
      base / "nc4", checkOnly = true)
    check not cStale.ok
    check countWitness(witness) == 2     # no new gen — stale read hit cache
