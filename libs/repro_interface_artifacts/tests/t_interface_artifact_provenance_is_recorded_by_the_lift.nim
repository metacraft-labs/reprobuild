## Shared-Development-Services §4.3's SAME-GENERATION PRECONDITION — THE
## RECORDING HALF: a lift that publishes an interface artifact records,
## beside it, what it was lifted from.
##
## §4.3 requires the attach decision to "establish that the owner's
## artifact corresponds to the owner's current definition". A CONSUMER
## establishes it by reading a stamp the OWNER's lift wrote; the decision
## side is measured in
## `libs/repro_resources/tests/t_l6_attach_refuses_a_stale_lift.nim`.
## This file measures the other side, and it is the only one that can:
## the decision side deliberately needs no compiled lift, because
## `ownerArtifactGeneration` takes the stamp, reads the recipe and never
## the artifact's bytes.
##
## § MOCK POLICY — NO MOCKS, AND A REAL COMPILER
##
## The lift here is the REAL `interfaceLiftPlan` + `liftInterfaceArtifact`
## pair over a REAL `repro.nim` written to a throwaway directory, which
## spawns the real Nim frontend exactly as `repro build` does. Nothing is
## stubbed and no artifact is hand-written. That is also why there is one
## compiled lift and not four: a lift is a multi-second subprocess, and
## every property beyond "the stamp is written, and it is the stamp of
## THIS recipe" is a property of the stamp rather than of the lift, and is
## measured without one in the decision-side file.
##
## § WHAT A GREEN HERE DOES NOT SAY
##
## It says the TI1/TI2 lift path records provenance. It does not say the
## `repro dev-env` / `repro build` extraction edge does -- that path
## publishes through `extractInterfaceEdge` in `repro_cli_support`, which
## is a different call site, and it is measured by driving the CLI rather
## than from here.

import std/[options, os, strutils, unittest]

import repro_interface_artifacts

const MinimalRecipe = """
import repro_project_dsl
import ./side_module

package sdsProvenanceProbe:
  executable placeholder:
    discard
"""

const SideModuleV1 = """
const sideValue* = "one"
"""

const SideModuleV2 = """
const sideValue* = "two"
"""

proc scratchRoot(tag: string): string =
  ## Per-process and per-case; never a module-level constant, because the
  ## runner executes each case as its own process and runs cases of one
  ## binary concurrently.
  result = getTempDir() / ("repro-sds-lift-prov-" &
    $getCurrentProcessId() & "-" & tag)
  removeDir(result)
  createDir(result)

suite "§4.3's provenance stamp is recorded by the lift":

  test "a real lift writes the stamp, and it is this recipe's closure":
    let base = scratchRoot("recorded")
    defer: removeDir(base)
    let projectRoot = base / "owner"
    createDir(projectRoot)
    writeFile(projectRoot / "repro.nim", MinimalRecipe)
    writeFile(projectRoot / "side_module.nim", SideModuleV1)
    let outDir = base / "out"
    createDir(outDir)
    let artifact = outDir / "project-interface.rbsz"

    let plan = interfaceLiftPlan(projectRoot / "repro.nim", artifact,
      outDir / "project-interface.nim", workDir = getCurrentDir())
    discard liftInterfaceArtifact(plan)
    check fileExists(artifact)

    # THE STAMP IS THERE, beside the artifact, and it parses.
    let stampPath = interfaceArtifactProvenancePath(artifact)
    check stampPath == artifact & ".provenance"
    check fileExists(stampPath)
    let recorded = readInterfaceArtifactProvenance(artifact)
    check recorded.isSome
    let provenance = recorded.get
    check provenance.recipeFileName == "repro.nim"
    check provenance.closureIdentity.len == 64

    # AND IT IS THE STAMP OF THIS RECIPE'S CLOSURE, not of something
    # else that happens to be 64 hex characters: the independently
    # recomputed identity of the same closure equals it.
    let recomputed = recipeClosureSourceDigests(projectRoot / "repro.nim")
    check recomputed.identity == provenance.closureIdentity

    # The closure the lift recorded INCLUDES the module the recipe
    # imports, which is the property a recipe-file-only stamp would not
    # have. Named rather than merely counted.
    var namedSide = false
    var namedRecipe = false
    for src in provenance.sourceDigests:
      if src.path.endsWith("side_module.nim"): namedSide = true
      if src.path.endsWith("repro.nim"): namedRecipe = true
    check namedRecipe
    check namedSide

    # EDITING THE IMPORTED MODULE MOVES THE IDENTITY, with the artifact
    # and its stamp untouched on disk. This is the state §4.3 calls
    # stale, produced by a real lift followed by a real edit.
    writeFile(projectRoot / "side_module.nim", SideModuleV2)
    let afterEdit = recipeClosureSourceDigests(projectRoot / "repro.nim")
    check afterEdit.identity != provenance.closureIdentity
    let stillRecorded = readInterfaceArtifactProvenance(artifact)
    check stillRecorded.isSome
    check stillRecorded.get.closureIdentity == provenance.closureIdentity

  test "the stamp round-trips through its own renderer and parser":
    ## The codec, measured on a value the WRITER produced rather than on
    ## one this test typed: a renderer and a parser that agree only about
    ## hand-written input is a pair that has not been tested.
    let base = scratchRoot("roundtrip")
    defer: removeDir(base)
    writeFile(base / "repro.nim", "const x* = 1\n")
    let artifact = base / "iface.rbsz"
    writeFile(artifact, "bytes")
    writeInterfaceArtifactProvenance(artifact, base / "repro.nim")
    let stampPath = interfaceArtifactProvenancePath(artifact)
    let text = readFile(stampPath)
    check text.startsWith(InterfaceProvenanceSchemaId & "\n")
    let parsed = parseInterfaceArtifactProvenance(text)
    check parsed.isSome
    check renderInterfaceArtifactProvenance(parsed.get) == text

  test "the recorded identity is PATH-INDEPENDENT across two copies":
    ## The property that makes the stamp usable at all: the comparand
    ## must survive being re-established by a different process in a
    ## different directory. Two byte-identical copies of one recipe, at
    ## two different absolute paths, must record the SAME identity --
    ## which is what rules out `interfaceExtractionFingerprint` and
    ## `interfaceLiftActionKey`, both of which fold in the absolute
    ## module path, the work directory and the compiler identity.
    let base = scratchRoot("paths")
    defer: removeDir(base)
    var identities: seq[string] = @[]
    for copy in ["copy-a", "copy-b-with-a-much-longer-name"]:
      let root = base / copy
      createDir(root)
      writeFile(root / "repro.nim", MinimalRecipe)
      writeFile(root / "side_module.nim", SideModuleV1)
      identities.add(recipeClosureSourceDigests(root / "repro.nim").identity)
    check identities.len == 2
    check identities[0] == identities[1]
    check identities[0].len == 64
