## RP8 (LSP mode) — interface-extraction backs an editor TYPECHECK and
## GO-TO-DEFINITION over a consumer ``repro.nim`` that ``uses:`` a producer
## declaring resource/executable types.
##
## Spec: ``Project-Provider-Runtime-Protocol.milestones.org`` §RP8. This is the
## FINAL Provider-Runtime-Protocol milestone: the whole interface-extraction
## stack (TI1 cached lift, TI2 driver-free accessor splice, TI3 fingerprint
## split, RP4/RP5a resource contracts) exists so a consumer resolves a
## producer's PUBLIC symbols WITHOUT compiling the producer's driver/impl
## closure. RP8 exposes that same extraction as the two capabilities an editor
## language-server needs. This is a focused, TESTED capability (typecheck-
## without-impl + a go-to-definition resolver returning the producer's public-
## decl source location), NOT a socket LSP server — which the RP8 gate accepts.
##
## It proves two properties:
##
##   1. **TYPECHECK resolves cross-project symbols, NO impl compile.** A
##      producer declares a ``resourceType``; a consumer ``uses:`` it and
##      references ``container(...)``. A ``nim check`` pass
##      (``typecheckConsumerAgainstInterface``) succeeds resolving the symbol
##      via the driver-free accessor. ``nim check`` CANNOT run ``staticExec``,
##      so a green check PROVES the exec-free interface path (TI2's VM read of
##      the cached accessor), not a full producer compile. The consumer's
##      generated C closure carries NO producer driver / ``registerResource‑
##      Provider`` / incus symbols — interface extraction, not full compile.
##      A reference to a NON-existent public symbol fails the check
##      (falsifiability).
##
##   2. **GO-TO-DEFINITION.** ``gotoDefinitionForProducerSymbol`` /
##      ``gotoDefinitionInProducerContract``, given ``container`` (the resource
##      wrapper) and ``cpus`` (an attribute), return the producer's
##      ``resources.nim`` source location — the FILE is the producer's resource
##      module and the LINE points at the real public declaration (computed from
##      the producer fixture). A PRIVATE driver helper (``cIdentity``) and an
##      unknown name do NOT resolve (``gdskNotFound``) — the interface only
##      exposes the public surface, so a private symbol has no location.

import std/[os, osproc, strutils, unittest]

import repro_cli_support
import repro_interface_artifacts

const repoRoot = currentSourcePath().parentDir.parentDir.parentDir

# ---------------------------------------------------------------------------
# The producer's SEPARATE resource module — a ``resourceType`` block plus its
# driver. The driver procs (``cIdentity`` …) are PRIVATE impl helpers: they
# must NOT resolve via go-to-definition (they never cross the interface). The
# public surface is the ``resourceType`` wrapper ``container`` and its ``attr``s.
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

# The producer ``repro.nim`` names the SEPARATE module via a ``resourceModule``
# surface entry (the RP5c2 vm-harness shape) and imports ONLY
# ``repro_project_dsl`` (never the resources module), so the producer core stays
# driver-free.
const producerRepro = """
import repro_project_dsl

resourceModule "repro/resources.nim":
  path "."

package producer:
  executable placeholder:
    discard
"""

proc consumerRepro(bindStmt: string): string =
  ## A consumer ``repro.nim`` that ``uses: "producer"`` (so ``usesImportCode``
  ## splices the producer's driver-free resource surface) and binds the typed
  ## ``container`` wrapper in a proc body. A green typecheck means the contract
  ## crossed AND the bind resolves via interface extraction.
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

proc writeProducer(producerDir: string) =
  createDir(producerDir)
  createDir(producerDir / "repro")
  writeFile(producerDir / "repro.nim", producerRepro)
  writeFile(producerDir / "repro" / "resources.nim", resourcesModule)

proc lineOfDecl(src, needle: string): int =
  ## The 1-based line number of the first line whose stripped content STARTS
  ## with ``needle`` in ``src`` — used to compute the expected go-to-def line
  ## from the producer fixture text (so the assertion tracks the real source).
  var n = 0
  for line in src.splitLines:
    inc n
    if line.strip.startsWith(needle):
      return n
  -1

suite "RP8: LSP typecheck + go-to-definition via interface extraction":

  test "t_rp8_typecheck_resolves_symbol_no_impl_compile":
    # A per-run fixture tree UNDER the repo (so the consumer/producer resolve the
    # repo config.nims --path set), in a PRIVATE nimcache; cleaned on exit.
    let base = repoRoot / "build" / "nimcache" /
      ("rp8-typecheck-" & $getCurrentProcessId())
    removeDir(base)
    createDir(base)
    defer: removeDir(base)

    # Clean the producer-keyed accessor cache so this run starts fresh.
    let accCache = repoRoot / "build" / "nimcache" / "ti2-resource-accessors" /
      "producer"
    removeDir(accCache)

    writeProducer(base / "producer")

    # ---- (a) A consumer that references ``container(...)`` type-checks. ----
    # First materialise the cached accessor via a ``nim c`` cold pass (nim check
    # cannot run the generator), then prove the typecheck capability sees the
    # spliced ``container`` wrapper on the exec-free path.
    let coldDir = base / "consumer_cold"
    createDir(coldDir)
    writeFile(coldDir / "repro.nim",
      consumerRepro("  discard container(\"web\", image = \"nginx\", cpus = 2)"))
    let nimExe = findExe("nim")
    doAssert nimExe.len > 0, "nim compiler not on PATH"
    let coldCache = base / "nc_cold"
    let coldCmd =
      nimExe & " c --compileOnly --hints:off --warnings:off -o:" &
      quoteShell(coldCache / "consumer_bin") &
      " --nimcache:" & quoteShell(coldCache) &
      " " & quoteShell(coldDir / "repro.nim")
    let (coldOut, coldCode) =
      execCmdEx("cd " & quoteShell(repoRoot) & " && " & coldCmd)
    check coldCode == 0

    # The RP8 TYPECHECK capability: a ``nim check`` (NO staticExec) resolves the
    # ``container`` bind through the driver-free interface accessor.
    let goodDir = base / "consumer_good"
    createDir(goodDir)
    writeFile(goodDir / "repro.nim",
      consumerRepro("  discard container(\"api\", image = \"redis\", cpus = 4)"))
    let good = typecheckConsumerAgainstInterface(
      goodDir / "repro.nim", repoRoot, base / "nc_good")
    check good.ok                        # cross-project symbol resolved

    # ---- (b) NO impl compile: the consumer's generated C closure carries no
    #          producer driver / registerResourceProvider / incus symbols. The
    #          cold ``nim c`` above emitted C into ``coldCache``; grep it. ----
    var sawContainerWrapper = false
    var sawDriverClosure = false
    for path in walkDirRec(coldCache):
      if not path.endsWith(".c"): continue
      let c = readFile(path)
      if c.contains("container"): sawContainerWrapper = true
      if c.contains("containerDriver") or
         c.contains("registerResourceProvider") or
         c.contains("cIdentity") or c.contains("incus"):
        sawDriverClosure = true
    check sawContainerWrapper            # the wrapper crossed (interface)
    check not sawDriverClosure           # the driver/impl did NOT (extraction)

    # ---- (c) FALSIFIABILITY: a reference to a NON-existent public symbol
    #          fails the typecheck. ----
    let badDir = base / "consumer_bad"
    createDir(badDir)
    writeFile(badDir / "repro.nim",
      consumerRepro("  discard nonexistent_wrapper(\"x\", foo = 1)"))
    let bad = typecheckConsumerAgainstInterface(
      badDir / "repro.nim", repoRoot, base / "nc_bad")
    check not bad.ok                     # unknown symbol does not resolve

  test "t_rp8_goto_definition_resolves_public_rejects_private":
    # Hermetic go-to-def over ``resolveProducerTypedContract`` directly. Fixtures
    # under the repo build tree (a private scratch under /home), NOT /tmp.
    let scratch = repoRoot / "build" / "nimcache" /
      ("rp8-goto-" & $getCurrentProcessId())
    removeDir(scratch)
    createDir(scratch)
    defer: removeDir(scratch)

    let workspace = absolutePath(scratch / "consumer")
    createDir(workspace)
    let producerDir = absolutePath(scratch / "producer")
    writeProducer(producerDir)

    let resourcesPath = producerDir / "repro" / "resources.nim"

    # ---- Go-to-def on the resource WRAPPER ``container`` → the resourceType
    #      block's decl location in the producer's resources.nim. ----
    let hitContainer =
      gotoDefinitionForProducerSymbol("producer", workspace, "container")
    check hitContainer.kind == gdskResourceType
    check hitContainer.typeId == "vm_harness.container"
    # The returned FILE is the producer's resource module.
    check sameFile(hitContainer.location.file, resourcesPath)
    # The returned LINE points at the real ``resourceType`` public declaration.
    let expectedResLine =
      lineOfDecl(resourcesModule, "resourceType \"vm_harness.container\"")
    check expectedResLine > 0
    check hitContainer.location.line == expectedResLine
    # Read back the producer source at that line and confirm the content.
    let resSrcLines = readFile(resourcesPath).splitLines
    check resSrcLines[hitContainer.location.line - 1].strip
      .startsWith("resourceType \"vm_harness.container\"")

    # The full typeId also resolves to the same decl.
    let hitByTypeId = gotoDefinitionForProducerSymbol(
      "producer", workspace, "vm_harness.container")
    check hitByTypeId.kind == gdskResourceType
    check hitByTypeId.location.line == expectedResLine

    # ---- Go-to-def on a resource ATTRIBUTE ``cpus`` → the attr's decl line. ----
    let hitAttr =
      gotoDefinitionForProducerSymbol("producer", workspace, "cpus")
    check hitAttr.kind == gdskResourceAttr
    check hitAttr.typeId == "vm_harness.container"
    check sameFile(hitAttr.location.file, resourcesPath)
    let expectedAttrLine = lineOfDecl(resourcesModule, "attr cpus: int")
    check expectedAttrLine > 0
    check hitAttr.location.line == expectedAttrLine
    check resSrcLines[hitAttr.location.line - 1].strip == "attr cpus: int"

    # ---- REJECTION: a PRIVATE driver helper (``cIdentity``) does NOT resolve —
    #      it never crossed the interface, so there is no public location. ----
    let priv = gotoDefinitionForProducerSymbol("producer", workspace,
      "cIdentity")
    check priv.kind == gdskNotFound
    check priv.location.line == 0

    # An UNKNOWN name likewise does not resolve.
    let unknown =
      gotoDefinitionForProducerSymbol("producer", workspace, "no_such_symbol")
    check unknown.kind == gdskNotFound
