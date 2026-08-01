## TI3 (interface/provider fingerprint split) benchmark harness.
##
## Establishes the ``customSmallerIsBetter`` metric the TI-track / RP7 CI gate on:
## the ASYMMETRY the fingerprint split buys downstream consumers.
##
## The consumer's accessor-cache freshness key (``usesImportCode``) is two-level:
##
##   * a private-impl edit (a resource DRIVER body / a ``build:`` body) leaves the
##     producer's impl-EXCLUDING InterfaceFingerprint UNCHANGED, so the cached
##     accessor is reused IN PLACE → ZERO downstream consumer regenerations; while
##   * a public-signature edit (a resource ATTRIBUTE rename/type) MOVES the
##     InterfaceFingerprint, so the accessor is regenerated → the downstream
##     consumer re-processes.
##
## This harness measures the DECISION both edits actually key on — the producer's
## InterfaceFingerprint via TI1's cached interface-lift edge (``interfaceLiftPlan``
## + ``liftInterfaceArtifact``) — and emits, as ``customSmallerIsBetter`` count
## metrics, the number of downstream regenerations each edit forces: 0 for the
## private-impl edit (the TI3 win), 1 for the public-signature edit. It also emits
## the per-edit fingerprint-decision time (the cheap cached-lift check that gates
## the reuse-in-place path).
##
## Usage:
##   ti3_fingerprint_split_bench [--quick] [--out <path>]
##
## TODO(RP7): fold into the shared suite loop + wire the 20%-regression gate.

import std/[json, os, strutils, times]

import repro_interface_artifacts
import repro_core
import repro_hash

# A resourceType producer whose DRIVER body is its private implementation and
# whose ``attr`` schema is its public signature. ``$DRIVER_BODY$`` / ``$ATTR2$``
# are perturbation holes (private impl vs public signature).
proc producerBody(driverBody, attr2: string; preamble = ""): string =
  ## ``preamble`` is injected at the very top of the module (before any public
  ## decl). A non-empty preamble SHIFTS every public decl's ``SourceLocation``
  ## downward — the adversarial line-shift a real private-impl edit can cause.
  ## The TI3 fix normalises locations out of the fingerprint, so this must not
  ## move the InterfaceFingerprint.
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

# De-gamed (TI3-fix): the private-impl edit DELIBERATELY SHIFTS the public decls'
# line numbers — ``driverBodyV2`` is MULTI-LINE (pushing the ``resourceType``
# block down) and the edit ALSO prepends a comment ``implPreamble`` (shifting
# EVERY decl down). The InterfaceFingerprint MUST STILL be identical, because the
# fix normalises ``SourceLocation`` out of the fingerprint. A driver-behaviour
# edit whose only fingerprint effect (if the bug were present) would be the line
# shift is the sharpest test of line-shift invariance.
const driverBodyV1 = "  result.present = false"
const driverBodyV2 =
  "  # multi-line body: shifts the public decls below it downward\n" &
  "  let a = inst.address\n" &
  "  let empty = a.len < 0\n" &
  "  result.present = empty"
const implPreamble = "# private-impl note: driver behaviour tuned (line-shift)"

proc elapsedMs(start: float): float =
  (epochTime() - start) * 1000.0

proc liftFingerprint(modulePath, source, artifactPath, stubPath: string;
                     decisionMs: var float): string =
  ## Rewrite the producer ``repro.nim`` IN PLACE (a real edit-in-place) and
  ## re-materialize the interface via TI1's cached lift edge. The
  ## InterfaceFingerprint is location-normalised (TI3 fix), so it depends only
  ## on the DSL's SEMANTIC public shape — not on the module path or where the
  ## decls sit. Returns the InterfaceFingerprint hex; ``decisionMs`` receives the
  ## wall-clock cost of the lift decision (the check the reuse-in-place gate
  ## pays on a Level-2 source-stamp miss).
  writeFile(extendedPath(modulePath), source)
  # Drop the prior artifact so the source edit is re-lifted (the lift's own
  # action-key cache would otherwise short-circuit on the unchanged path).
  removeFile(extendedPath(artifactPath))
  removeFile(extendedPath(stubPath))
  let plan = interfaceLiftPlan(modulePath, artifactPath, stubPath,
    workDir = getCurrentDir())
  let start = epochTime()
  let art = liftInterfaceArtifact(plan)
  decisionMs = elapsedMs(start)
  toHex(art.interfaceFingerprint.bytes)

proc main() =
  var quick = false
  var outPath = "bench-results/ti3-fingerprint-split.json"
  var i = 1
  let params = commandLineParams()
  while i <= params.len:
    if i - 1 < params.len:
      let arg = params[i - 1]
      case arg
      of "--quick": quick = true
      of "--out":
        if i < params.len:
          outPath = params[i]
          inc i
      else: discard
    inc i

  let scratch = getTempDir() / "ti3-bench-" & $getCurrentProcessId() & "-" &
    $int(epochTime())
  removeDir(extendedPath(scratch))
  let projectRoot = scratch / "producer"
  let outDir = scratch / "out"
  createDir(extendedPath(projectRoot))
  createDir(extendedPath(outDir))
  defer: removeDir(extendedPath(scratch))

  # ONE producer module path, edited IN PLACE across all three revisions + ONE
  # artifact/stub path (the real edit-in-place shape). The fingerprint is
  # location-normalised, so only the DSL's semantic public shape moves it.
  let modulePath = projectRoot / "reprobuild.nim"
  let artifactPath = outDir / "producer-interface.rbsz"
  let stubPath = outDir / "producer-interface.nim"

  # Baseline producer.
  var baseMs = 0.0
  let fpBase = liftFingerprint(modulePath, producerBody(driverBodyV1, "cpus"),
    artifactPath, stubPath, baseMs)

  # PRIVATE-IMPL edit — same public surface, different (multi-line) driver body
  # AND a top-of-module comment preamble: the public decls' LINE NUMBERS SHIFT.
  # The InterfaceFingerprint MUST STILL be unchanged (line-shift invariant) →
  # ZERO downstream regenerations.
  var implMs = 0.0
  let fpImpl = liftFingerprint(modulePath,
    producerBody(driverBodyV2, "cpus", preamble = implPreamble),
    artifactPath, stubPath, implMs)
  let privateImplRegens = if fpImpl == fpBase: 0 else: 1

  # PUBLIC-SIGNATURE edit — rename the ``cpus`` attribute to ``vcpus``. The
  # InterfaceFingerprint MUST change → ONE downstream regeneration.
  var sigMs = 0.0
  let fpSig = liftFingerprint(modulePath, producerBody(driverBodyV1, "vcpus"),
    artifactPath, stubPath, sigMs)
  let publicSigRegens = if fpSig != fpBase: 1 else: 0

  if privateImplRegens != 0:
    quit("ti3 bench: private-impl edit (with a line shift) MOVED the " &
      "InterfaceFingerprint — the fingerprint is NOT line-shift invariant " &
      "(fingerprint split broken)", 1)
  if publicSigRegens != 1:
    quit("ti3 bench: public-signature edit did NOT move the " &
      "InterfaceFingerprint (falsifiability broken)", 1)

  let doc = %*{
    "schema": "reprobuild.ti3-fingerprint-split-bench.v1",
    "metadata": {
      "quick": quick,
      "project": "producer",
      "interfaceFingerprintBase": fpBase,
      "interfaceFingerprintPrivateImpl": fpImpl,
      "interfaceFingerprintPublicSig": fpSig
    },
    "metrics": [
      {
        "suite": "ti3",
        "name": "downstream regenerations: private-impl edit",
        "unit": "count",
        "value": privateImplRegens,
        "direction": "lower-is-better",
        "status": "measured"
      },
      {
        "suite": "ti3",
        "name": "downstream regenerations: public-signature edit",
        "unit": "count",
        "value": publicSigRegens,
        "direction": "lower-is-better",
        "status": "measured"
      },
      {
        "suite": "ti3",
        "name": "fingerprint decision time: private-impl edit",
        "unit": "ms",
        "value": implMs,
        "direction": "lower-is-better",
        "status": "measured"
      },
      {
        "suite": "ti3",
        "name": "fingerprint decision time: public-signature edit",
        "unit": "ms",
        "value": sigMs,
        "direction": "lower-is-better",
        "status": "measured"
      }
    ]
  }

  createDir(extendedPath(parentDir(outPath)))
  writeFile(extendedPath(outPath), pretty(doc))
  echo "ti3 fingerprint-split: private-impl regenerations ", privateImplRegens,
    " (fp ", (if fpImpl == fpBase: "UNCHANGED" else: "CHANGED"),
    "); public-signature regenerations ", publicSigRegens,
    " (fp ", (if fpSig != fpBase: "CHANGED" else: "UNCHANGED"), ")"

main()
