## TI2 (Production Thin Interface Mode consumer) — a consumer that ``uses:`` a
## resource-declaring PRODUCER compiles against the producer's CACHED interface
## artifact (TI1's ``interfaceLiftPlan`` + ``liftInterfaceArtifact`` edge), NOT a
## per-consumer ``nim c -r`` re-extract. This is the production win over RP5a's
## ``staticExec``-per-consumer path (~2m/consumer).
##
## Spec: Project-Interface-Artifacts-And-Import-Modes.md §"Import Modes" (Thin
## Interface Mode); Project-Provider-Runtime-Protocol.milestones.org §TI2.
##
## The two RP5a tests (``t_rp5a_producer_exports_resource_contract_across_workspace``,
## ``t_rp5a_consumer_imports_resource_contract_no_driver``) already migrate onto
## the cached-artifact read (``resolveProducerTypedContract`` now lifts the
## interface via the TI1 cached edge). THIS test adds the two TI2-specific
## proofs by compiling REAL consumer ``repro.nim`` modules as subprocesses and
## observing the resource-accessor generation WITNESS:
##
##   1. **Shared cached lift + FAST (no per-consumer ``nim c -r``).** Two
##      distinct consumers ``uses:`` the SAME producer. The FIRST consumer's
##      macro-expansion cold-generates the emitted accessor splice ONCE (one
##      witness line). The SECOND consumer's macro-expansion is a CACHE HIT: it
##      reads the cached accessor source in the Nim VM (a pure file read) and
##      splices it WITHOUT spawning the ``nim c -r`` generator — the witness log
##      does NOT grow. The lift ran once, shared across consumers. FAST: the
##      per-consumer ~2m generator is gone on the hit path.
##
##   2. **NON-VACUOUS falsifiability.** A renamed producer decl re-keys the
##      content-addressed cache (the stamp shifts), so the next consumer
##      RE-generates against the NEW schema — and a STALE consumer bind on the
##      OLD attribute name no longer type-checks, while a fresh bind on the new
##      name compiles. The witness confirms the rename forced a real re-gen
##      (not a stale hit).
##
## The producer's DRIVER never crosses on any of these paths: each generated
## consumer imports ONLY ``repro_resources`` (the resource runtime), never the
## producer module, and the spliced accessor source carries no
## ``registerResourceProvider`` / driver closure (asserted on the emitted text).

import std/[os, osproc, strutils, unittest]

const repoRoot = currentSourcePath().parentDir.parentDir.parentDir

# ---------------------------------------------------------------------------
# The producer ``repro.nim`` — a resourceType producer discovered by a consumer
# as ``../producer``. Its inline ``resourceType`` block is the contract the
# consumer binds a typed wrapper against.
# ---------------------------------------------------------------------------

const producerRepro = """
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

package producer:
  executable placeholder:
    discard
"""

proc consumerRepro(producerSelector, bindStmt: string): string =
  ## A consumer ``repro.nim`` that ``uses: "producer"`` (so ``usesImportCode``
  ## splices the producer's driver-free resource surface) and binds the typed
  ## ``container`` wrapper in a proc body. Reaching a green compile means the
  ## contract crossed AND the bind type-checks.
  ("""
import repro_project_dsl

package theconsumer:
  defaultToolProvisioning "path"

  uses:
    "$1"

  build:
    discard

proc useContainer() =
""" % [producerSelector]) & bindStmt & "\n"

proc countWitness(path: string): int =
  ## The number of COLD generator runs recorded in the witness log — one line
  ## per ``nim c -r`` accessor generation. A cache HIT does not append.
  if not fileExists(path):
    return 0
  for line in readFile(path).splitLines:
    if line.strip.len > 0:
      inc result

proc compileConsumer(consumerDir, witnessPath, producerSelector, bindStmt,
                     nimcache: string;
                     checkOnly = false;
                     withoutAmbientNim = false): tuple[ok: bool, output: string] =
  ## Materialize a consumer ``repro.nim`` under ``consumerDir`` (a sibling of
  ## ``../producer``) and compile it as a SUBPROCESS with the accessor witness
  ## redirected to ``witnessPath``. The consumer lives UNDER the repo tree so
  ## Nim's config walk wires the lib ``--path`` set. Returns whether it
  ## compiles. The subprocess boundary is what lets us observe the witness: the
  ## accessor generation (if any) happens at THIS compile's macro-expansion.
  ##
  ## ``checkOnly``: use ``nim check`` instead of ``nim c``. Nim runs
  ## ``staticExec`` (the RP5a-style cold-path generator) ONLY under ``nim c`` —
  ## compile-time exec is disabled under ``nim check``. So a consumer that
  ## type-checks under ``nim check`` PROVES it took the exec-free TI2 fast path
  ## (a pure VM ``readFile`` of the cached accessor source); a consumer needing
  ## the generator would fail to see the spliced ``container`` wrapper under
  ## ``nim check``. The cold (cache-miss) compile therefore uses ``nim c``.
  createDir(consumerDir)
  writeFile(consumerDir / "repro.nim",
    consumerRepro(producerSelector, bindStmt))
  let nimExe = findExe("nim")
  doAssert nimExe.len > 0, "nim compiler not on PATH"
  var env = "REPRO_TI2_ACCESSOR_WITNESS=" & quoteShell(witnessPath)
  if withoutAmbientNim:
    let nimDir = nimExe.parentDir.normalizedPath
    var filteredPath: seq[string]
    for entry in getEnv("PATH").split(PathSep):
      if entry.normalizedPath != nimDir:
        filteredPath.add(entry)
    env.add(" PATH=" & quoteShell(filteredPath.join($PathSep)))
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

suite "TI2: thin-interface consumer reads the cached interface artifact":

  test "t_ti2_consumer_reads_cached_artifact_shared_lift_fast":
    # A per-run fixture tree UNDER the repo (so the consumer/producer/generator
    # all resolve the repo config.nims), cleaned on exit.
    let base = repoRoot / "build" / "nimcache" /
      ("ti2-fixtures-" & $getCurrentProcessId())
    removeDir(base)
    createDir(base)
    defer: removeDir(base)

    # Use a process-unique producer selector so the separate-module TI2 binary
    # can run concurrently without either test deleting the other's cache.
    let producerSelector = "producer_" & $getCurrentProcessId()
    let accCache = repoRoot / "build" / "nimcache" / "ti2-resource-accessors" /
      producerSelector
    removeDir(accCache)

    let producerDir = base / producerSelector
    createDir(producerDir)
    writeFile(producerDir / "repro.nim", producerRepro)

    let witness = base / "witness.log"

    # ---- (1) FIRST consumer — COLD: the generator runs ONCE. ----
    let c1 = compileConsumer(base / "consumer1", witness, producerSelector,
      "  discard container(\"web\", image = \"nginx\", cpus = 2)",
      base / "nc1", withoutAmbientNim = true)
    checkpoint c1.output
    check c1.ok                          # the contract crossed + bind type-checks
    check countWitness(witness) == 1     # exactly one cold generation

    # ---- (2) SECOND consumer of the SAME producer — CACHE HIT: FAST. ----
    # Compiled under ``nim check`` — which CANNOT run ``staticExec``. It still
    # type-checks the ``container`` bind, PROVING the spliced accessor came from
    # the exec-free VM ``readFile`` fast path (a consumer needing the generator
    # would not see ``container`` under ``nim check``). The witness log does NOT
    # grow — the lift ran once, shared across both consumers; the ~2m per-
    # consumer generator is gone.
    let c2 = compileConsumer(base / "consumer2", witness, producerSelector,
      "  discard container(\"api\", image = \"redis\", cpus = 4)",
      base / "nc2", checkOnly = true)
    checkpoint c2.output
    check c2.ok
    check countWitness(witness) == 1     # STILL one — the 2nd consumer re-used

    # ---- no driver closure crossed (assert on the emitted accessor cache). ----
    let cachedAccessors = readFile(accCache /
      (producerSelector & ".accessors.nim"))
    check cachedAccessors.contains("proc container*")
    check cachedAccessors.contains("\"vm_harness.container\"")
    check not cachedAccessors.contains("containerDriver")
    check not cachedAccessors.contains("registerResourceProvider")

    # ---- (3) NON-VACUITY — a renamed producer decl re-keys + a stale bind
    #          breaks. Rewrite the producer's ``cpus`` attr to ``vcpus``. The
    #          content stamp shifts, so the NEXT consumer RE-generates (witness
    #          grows) against the NEW schema. ----
    writeFile(producerDir / "repro.nim",
      producerRepro.replace("cpus", "vcpus"))

    # A consumer binding the NEW attr name compiles (and forces a re-gen).
    let cNew = compileConsumer(base / "consumer3", witness, producerSelector,
      "  discard container(\"db\", image = \"pg\", vcpus = 8)",
      base / "nc3")
    checkpoint cNew.output
    check cNew.ok
    check countWitness(witness) == 2     # the rename forced a real re-gen

    # A consumer binding the STALE attr name (``cpus``) no longer type-checks —
    # the wrapper formal is now ``vcpus``. This is the falsifiable end: a
    # producer decl rename breaks a stale consumer bind. The cache is fresh from
    # consumer3's re-gen, so this reads the NEW-schema accessor on the fast path
    # (``nim check``) and the stale ``cpus`` bind fails to compile.
    let cStale = compileConsumer(base / "consumer4", witness, producerSelector,
      "  discard container(\"cache\", image = \"mc\", cpus = 8)",
      base / "nc4", checkOnly = true)
    checkpoint cStale.output
    check not cStale.ok
    check countWitness(witness) == 2     # no new gen — the stale read hit cache
