## TI3 (interface/provider fingerprint split) — editing a producer's PRIVATE
## implementation (a resource DRIVER body / a ``build:`` body) re-materializes the
## producer's provider artifact but does NOT recompile/reprocess downstream
## consumers: their view of the producer (the spliced driver-free accessor) is
## byte-identical, so they see no changed input. Editing a PUBLIC signature (a
## resource ATTRIBUTE name/type) DOES invalidate downstream consumers.
##
## Spec: Project-Provider-Runtime-Protocol.milestones.org §TI3.
##
## The mechanism under test is the TWO-LEVEL accessor-cache freshness key in
## ``usesImportCode`` (``repro_project_dsl/macros_a.nim``):
##
##   * Level 1 (cheap, VM-safe, no subprocess): the producer's ``producerSourceStamp``
##     (an FNV hash over the FULL source, impl included). Unchanged → fast HIT,
##     read the cached accessor. (The TI2 warm path, untouched.)
##   * Level 2 (only on a stamp MISS — the source genuinely changed): obtain the
##     producer's current InterfaceFingerprint via TI1's CACHED interface-lift
##     edge and compare it to the fingerprint recorded next to the cached accessor
##     (``<selector>.ifp``):
##       - fingerprint UNCHANGED (private-impl edit): the accessor is provably
##         identical → REUSE it IN PLACE (do not rewrite its bytes/mtime; no
##         downstream input change), refresh only the stamp. NO regeneration
##         witness.
##       - fingerprint CHANGED (public-signature edit): regenerate the accessor +
##         record the new fingerprint. A regeneration witness is appended.
##
## This test compiles REAL consumer ``repro.nim`` modules as subprocesses and
## observes: the accessor-generation WITNESS (per rewrite), the cached accessor
## file's BYTES and MTIME (unchanged on a private-impl edit), and the compile
## outcome (a stale public bind breaks after a signature edit).

import std/[os, osproc, strutils, times, unittest]

import repro_interface_artifacts
import repro_core
import repro_hash

const repoRoot = currentSourcePath().parentDir.parentDir.parentDir

# ---------------------------------------------------------------------------
# The producer ``repro.nim`` — a resourceType producer whose driver bodies are
# its PRIVATE implementation. ``$DRIVER_BODY$`` / ``$ATTR2$`` are substitution
# holes so the test can perturb the PRIVATE impl vs the PUBLIC signature
# independently.
# ---------------------------------------------------------------------------

proc producerRepro(driverBody: string; attr2: string;
                   preamble: string = ""): string =
  ## ``preamble`` is injected at the very top of the module (BEFORE any public
  ## decl). A non-empty preamble SHIFTS every public decl's ``SourceLocation``
  ## downward — the adversarial line-shift a genuine private-impl edit can cause
  ## (a comment added above the module, a longer driver body pushing the
  ## ``resourceType`` block down). The de-gamed test asserts the
  ## InterfaceFingerprint is INVARIANT to that shift.
  ("$PREAMBLE$" & """
import repro_project_dsl
import repro_resources
import std/options

type""").replace("$PREAMBLE$", if preamble.len > 0: preamble & "\n" else: "") &
  """
  ContainerAttrs = object
    image*: string
    $ATTR2$*: int

proc cIdentity(inst: ResourceInstance): string {.nimcall.} =
  "container:" & inst.address

proc cDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  digestString(inst.address)

proc cObserve(inst: ResourceInstance;
              recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
$DRIVER_BODY$

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
  attr $ATTR2$: int

package producer:
  executable placeholder:
    discard
""".replace("$DRIVER_BODY$", driverBody).replace("$ATTR2$", attr2)

# Two DIFFERENT driver bodies — same PUBLIC surface (same attrs/wrapper/typeId).
# CRITICAL (de-gamed, TI3-fix): the private-impl edit DELIBERATELY SHIFTS the
# public decls' line numbers. ``driverBodyV2`` is MULTI-LINE (it pushes the
# ``resourceType`` block DOWN vs V1's single line), and the private edit ALSO
# prepends a comment ``preamble`` (see ``implPreamble``) that shifts EVERY decl
# down. The ``resourceType`` / package / attr ``SourceLocation`` therefore MOVES
# — yet the InterfaceFingerprint MUST be identical, because the TI3 fix
# normalises locations OUT of the fingerprint. If the fingerprint still
# depended on ``loc.line`` (the confirmed bug) this edit would spuriously
# invalidate downstream — which is exactly what this test now falsifies. The
# FULL-source ``producerSourceStamp`` still changes (it hashes content), so
# Level 2 is exercised and must resolve to reuse-in-place.
const driverBodyV1 = "  result.present = false"
const driverBodyV2 =
  "  # multi-line body: shifts the public decls below it downward\n" &
  "  let a = inst.address\n" &
  "  let empty = a.len < 0\n" &
  "  result.present = empty"
# A comment line prepended at the very top of the module on the private edit —
# shifts the ``SourceLocation`` of EVERY public decl (package, executable,
# resourceType, attrs) down by one line.
const implPreamble = "# private-impl note: driver behaviour tuned (line-shift)"

proc consumerRepro(bindStmt: string): string =
  ## A consumer ``repro.nim`` that ``uses: "producer"`` and binds the typed
  ## ``container`` wrapper.
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
  ## One line per COLD accessor REWRITE. A Level-1 HIT and a Level-2 reuse-in-
  ## place do NOT append.
  if not fileExists(path):
    return 0
  for line in readFile(path).splitLines:
    if line.strip.len > 0:
      inc result

proc compileConsumer(consumerDir, witnessPath, bindStmt, nimcache: string;
                     checkOnly = false): tuple[ok: bool, output: string] =
  ## Materialize + compile a consumer as a SUBPROCESS with the accessor witness
  ## redirected to ``witnessPath``. ``checkOnly`` uses ``nim check`` (which
  ## cannot run ``staticExec``), so a green check PROVES the consumer took the
  ## exec-free VM readFile fast path.
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

# The producer-keyed accessor cache paths (shared across all consumers of the
# ``producer`` selector).
const accCache = repoRoot / "build" / "nimcache" / "ti2-resource-accessors" /
  "producer"
const accessorFile = accCache / "producer.accessors.nim"
const ifpFile = accCache / "producer.ifp"

# The producer's own provider artifact (impl-INCLUDING) — proof of the SPLIT:
# a private-impl edit re-materializes THIS while leaving the consumer's accessor
# untouched. We approximate "provider artifact re-materialized" by the
# producer's full-source stamp (impl-including), which the Level-2 path records
# in the ``.stamp`` sidecar — it MUST change on a driver-body edit even though
# the InterfaceFingerprint does not.
const stampFile = accCache / "producer.stamp"

suite "TI3: interface/provider fingerprint split":

  test "t_ti3_private_impl_edit_no_downstream_recompile":
    let base = repoRoot / "build" / "nimcache" /
      ("ti3-fixtures-a-" & $getCurrentProcessId())
    removeDir(base)
    createDir(base)
    defer: removeDir(base)

    # Start COLD: clear the producer-keyed accessor cache.
    removeDir(accCache)

    let producerDir = base / "producer"
    createDir(producerDir)
    writeFile(producerDir / "repro.nim",
      producerRepro(driverBodyV1, "cpus"))

    let witness = base / "witness.log"

    # ---- (1) COLD generate the accessor (witness == 1). ----
    let c1 = compileConsumer(base / "consumer1", witness,
      "  discard container(\"web\", image = \"nginx\", cpus = 2)",
      base / "nc1")
    check c1.ok
    check countWitness(witness) == 1

    # Snapshot the cached accessor's BYTES + MTIME + the recorded fingerprint +
    # the impl-including stamp.
    check fileExists(accessorFile)
    check fileExists(ifpFile)
    check fileExists(stampFile)
    let accessorBytesBefore = readFile(accessorFile)
    let accessorMtimeBefore = getLastModificationTime(accessorFile)
    let ifpBefore = readFile(ifpFile).strip()
    let stampBefore = readFile(stampFile).strip()

    # ---- (2) PRIVATE-IMPL edit: change ONLY the driver body AND prepend a
    #          top-of-module comment. Same PUBLIC surface, but the public decls'
    #          LINE NUMBERS SHIFT (multi-line body + preamble). Re-run. ----
    writeFile(producerDir / "repro.nim",
      producerRepro(driverBodyV2, "cpus", preamble = implPreamble))

    let c2 = compileConsumer(base / "consumer2", witness,
      "  discard container(\"api\", image = \"redis\", cpus = 4)",
      base / "nc2")
    check c2.ok

    # THE TI3 WIN — downstream saw NO changed input:
    #   * the accessor was NOT regenerated (witness did NOT grow);
    check countWitness(witness) == 1
    #   * the accessor file is BYTE-IDENTICAL and its MTIME is UNCHANGED
    #     (reuse-in-place, not a rewrite) — so a build system keying on the
    #     accessor's content/mtime does NOT recompile the consumer;
    check readFile(accessorFile) == accessorBytesBefore
    check getLastModificationTime(accessorFile) == accessorMtimeBefore
    #   * the recorded InterfaceFingerprint is UNCHANGED (the impl-EXCLUDING
    #     fingerprint did not move — that is WHY reuse-in-place was legal).
    check readFile(ifpFile).strip() == ifpBefore

    # THE SPLIT — the producer's own (impl-INCLUDING) identity DID move: the
    # full-source stamp changed (the driver body is part of it), i.e. the
    # producer's provider artifact re-materializes even though the consumer's
    # interface view did not.
    check readFile(stampFile).strip() != stampBefore

  test "t_ti3_public_signature_edit_invalidates_downstream":
    let base = repoRoot / "build" / "nimcache" /
      ("ti3-fixtures-b-" & $getCurrentProcessId())
    removeDir(base)
    createDir(base)
    defer: removeDir(base)

    removeDir(accCache)

    let producerDir = base / "producer"
    createDir(producerDir)
    writeFile(producerDir / "repro.nim",
      producerRepro(driverBodyV1, "cpus"))

    let witness = base / "witness.log"

    # ---- (1) COLD generate (witness == 1). ----
    let c1 = compileConsumer(base / "consumer1", witness,
      "  discard container(\"web\", image = \"nginx\", cpus = 2)",
      base / "nc1")
    check c1.ok
    check countWitness(witness) == 1
    let ifpBefore = readFile(ifpFile).strip()
    let accessorBytesBefore = readFile(accessorFile)

    # ---- (2) PUBLIC-SIGNATURE edit: rename the resource ATTRIBUTE
    #          ``cpus`` → ``vcpus`` (attr record field AND the ``attr`` decl).
    #          Re-run a consumer binding the NEW name. ----
    writeFile(producerDir / "repro.nim",
      producerRepro(driverBodyV1, "vcpus"))

    let cNew = compileConsumer(base / "consumer2", witness,
      "  discard container(\"db\", image = \"pg\", vcpus = 8)",
      base / "nc2")
    check cNew.ok

    # The signature edit MUST invalidate downstream:
    #   * the accessor was REGENERATED (witness grew);
    check countWitness(witness) == 2
    #   * the InterfaceFingerprint CHANGED (attributed to the signature change —
    #     this is precisely what made the Level-2 path regenerate rather than
    #     reuse);
    check readFile(ifpFile).strip() != ifpBefore
    #   * the accessor CONTENT changed (the wrapper formal is now ``vcpus``).
    check readFile(accessorFile) != accessorBytesBefore
    check readFile(accessorFile).contains("vcpus")

    # Falsifiable end: a STALE consumer binding the OLD attr name no longer
    # type-checks. Read on the fast path (``nim check``) against the fresh
    # NEW-schema accessor; the stale ``cpus`` bind fails to compile.
    let cStale = compileConsumer(base / "consumer3", witness,
      "  discard container(\"cache\", image = \"mc\", cpus = 8)",
      base / "nc3", checkOnly = true)
    check not cStale.ok
    check countWitness(witness) == 2     # no new gen — the stale read hit cache

  test "t_ti3_interface_fingerprint_is_line_shift_invariant":
    ## Adversarial, dispositive proof (mirrors the reviewer's harness): compute
    ## the InterfaceFingerprint DIRECTLY via the REAL cached lift edge
    ## (``interfaceLiftPlan`` + ``liftInterfaceArtifact``) for four producer
    ## variants that all share the SAME public surface EXCEPT the deliberate
    ## edits below. The TI3 fix normalises ``SourceLocation`` OUT of the
    ## fingerprint, so:
    ##   * baseline vs. a preamble-comment line-shift (private-impl only)  → SAME
    ##   * baseline vs. a multi-line driver body line-shift (private only) → SAME
    ##   * baseline vs. a public ATTRIBUTE rename (``cpus`` → ``vcpus``)   → DIFFER
    ## Before the fix, both line-shift variants CHANGED the fingerprint (the
    ## confirmed bug); this test would then FAIL — it is falsifiable.
    let base = repoRoot / "build" / "nimcache" /
      ("ti3-fp-" & $getCurrentProcessId())
    removeDir(base)
    createDir(base)
    defer: removeDir(base)

    proc liftFingerprint(tag, driverBody, attr2, preamble: string):
        ContentDigest =
      ## Lift a resource-module producer variant and return its
      ## InterfaceFingerprint (the location-normalised projection).
      let projectRoot = base / tag
      let resourceDir = projectRoot / "repro"
      createDir(resourceDir)
      writeFile(projectRoot / "repro.nim", """
import repro_project_dsl

package ti3fpproducer:
  executable placeholder:
    discard
""")
      writeFile(resourceDir / "resources.nim",
        producerRepro(driverBody, attr2, preamble))
      let outDir = base / (tag & "-out")
      createDir(outDir)
      let plan = interfaceLiftPlan(projectRoot / "repro.nim",
        outDir / "iface.rbsz", outDir / "iface.nim",
        resourceModule = resourceDir / "resources.nim",
        extraPaths = @[projectRoot],
        workDir = getCurrentDir())
      liftInterfaceArtifact(plan).interfaceFingerprint

    let fpBaseline = liftFingerprint("baseline", driverBodyV1, "cpus", "")
    let fpPreambleShift =
      liftFingerprint("preamble", driverBodyV1, "cpus", implPreamble)
    let fpBodyShift = liftFingerprint("body", driverBodyV2, "cpus", "")
    let fpPublicEdit = liftFingerprint("public", driverBodyV1, "vcpus", "")

    # Emit the digests so the proof is visible in the test log.
    echo "TI3-ADVERSARIAL baseline      = ", toHex(fpBaseline.bytes)
    echo "TI3-ADVERSARIAL preambleShift = ", toHex(fpPreambleShift.bytes)
    echo "TI3-ADVERSARIAL bodyShift     = ", toHex(fpBodyShift.bytes)
    echo "TI3-ADVERSARIAL publicEdit    = ", toHex(fpPublicEdit.bytes)

    # LINE-SHIFT INVARIANCE — the private-impl edits (which MOVE the public
    # decls' source lines) leave the fingerprint UNCHANGED.
    check fpPreambleShift == fpBaseline
    check fpBodyShift == fpBaseline
    # PUBLIC SENSITIVITY (non-over-normalisation) — a real public attr change
    # STILL moves the fingerprint.
    check fpPublicEdit != fpBaseline
