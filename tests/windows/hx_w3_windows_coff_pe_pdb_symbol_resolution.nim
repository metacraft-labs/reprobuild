## HX-W-3 production COFF, PE/PDB, and runtime symbol-resolution gate.
##
## Design: `reprobuild-specs/HCR/Binary-Diffing-And-Symbol-Resolution.md`
## sections 3.2-3.3 and `HCR/Incremental-Linker-Algorithm.md` section 5.2.
##
## `allowed_mocks: none`. The Python driver supplies real MSVC-built COFF
## objects, a PE EXE and DLL, and their full PDBs. This executable calls the
## production LinkGraph parser/planner and serialized DbgHelp resolver. The
## companion target process calls the production ToolHelp/GetModuleHandleExW
## runtime resolver against the actually loaded images.

import std/[json, os, sequtils, strutils]

import repro_hcr_linkgraph

proc require(condition: bool; message: string) =
  if not condition:
    raise newException(ValueError, message)

proc identityJson(identity: WindowsPdbIdentity): JsonNode =
  %*{
    "guid": pdbIdentityText(identity).split('-')[0].toLowerAscii,
    "age": identity.age
  }

proc main() =
  let arguments = commandLineParams()
  require(arguments.len == 7,
    "usage: gate EXE EXE_PDB DLL DLL_PDB OLD_OBJ NEW_OBJ NO_CODEVIEW_EXE")
  let exeFacts = parsePeCodeViewFacts(arguments[0])
  let exePdbIdentity = parsePdbIdentity(arguments[1])
  let dllFacts = parsePeCodeViewFacts(arguments[2])
  let dllPdbIdentity = parsePdbIdentity(arguments[3])
  require(exeFacts.identity == exePdbIdentity,
          "EXE CodeView/PDB identity differs")
  require(dllFacts.identity == dllPdbIdentity,
          "DLL CodeView/PDB identity differs")
  require(exeFacts.identity != dllFacts.identity,
          "independent EXE and DLL unexpectedly share a PDB identity")

  let exeResolution = resolveWindowsPdbFunction(
    arguments[0], arguments[1], "hx_w3_exe_private")
  let dllResolution = resolveWindowsPdbFunction(
    arguments[2], arguments[3], "hx_w3_dll_private")
  require(exeResolution.status == wprsOk,
    "EXE private symbol lookup failed: " & exeResolution.reason &
    " win32=" & $exeResolution.win32Error)
  require(dllResolution.status == wprsOk,
    "DLL private symbol lookup failed: " & dllResolution.reason &
    " win32=" & $dllResolution.win32Error)
  require(exeResolution.matchCount == 1 and dllResolution.matchCount == 1,
          "private function lookup was not exact and unique")
  require(exeResolution.rva > 0 and dllResolution.rva > 0,
          "private function lookup returned a zero RVA")

  let absent = resolveWindowsPdbFunction(
    arguments[0], arguments[1], "hx_w3_symbol_that_is_absent")
  require(absent.status == wprsPdbSymbolAbsent and absent.matchCount == 0,
          "absent PDB symbol did not produce pdb-symbol-absent")
  let ambiguous = resolveWindowsPdbFunction(
    arguments[0], arguments[1], "hx_w3_ambiguous")
  require(ambiguous.status == wprsPdbSymbolAmbiguous and
          ambiguous.matchCount == 2,
          "duplicate private PDB functions did not produce " &
          "pdb-symbol-ambiguous (status=" & $ambiguous.status &
          ", count=" & $ambiguous.matchCount & ")")
  let mismatch = resolveWindowsPdbFunction(
    arguments[0], arguments[3], "hx_w3_exe_private")
  require(mismatch.status == wprsPdbIdentityMismatch and
          "pe-pdb-identity-mismatch" in mismatch.reason,
          "mismatched PDB was not rejected before DbgHelp")
  let noIdentity = resolveWindowsPdbFunction(
    arguments[6], arguments[1], "hx_w3_exe_private")
  require(noIdentity.status == wprsPeCodeViewIdentityMissing and
          "pe-codeview-identity-missing" in noIdentity.reason,
          "PE without CodeView identity was not rejected before DbgHelp")

  var oldFacts, newFacts: CoffObjectFacts
  let oldGraph = parseCoffAmd64Object(arguments[4], oldFacts)
  let newGraph = parseCoffAmd64Object(arguments[5], newFacts)
  require(oldGraph.format == ofCoffAmd64 and newGraph.format == ofCoffAmd64,
          "COFF parser returned the wrong object format")
  require(newFacts.primarySymbolCount > 0 and newFacts.relocationCount > 0,
          "COFF facts lost symbols or relocations")
  require(newFacts.implicitAddendCount == newFacts.relocationCount,
          "COFF parser did not capture every relocation field addend")
  require(newFacts.rel32VariantCount > 0,
          "fixture did not exercise REL32_1 through REL32_5")
  require(newGraph.relocations.anyIt(
            it.kindName == "IMAGE_REL_AMD64_REL32_4"),
          "fixture did not preserve IMAGE_REL_AMD64_REL32_4")
  require(newGraph.relocations.anyIt(
            it.kindName == "IMAGE_REL_AMD64_ADDR64"),
          "fixture did not preserve IMAGE_REL_AMD64_ADDR64")
  require(newGraph.relocations.anyIt(it.addend != 0),
          "fixture did not exercise a non-zero implicit addend")

  for relocation in newGraph.relocations:
    if relocation.pcrel:
      let symbolAddress = 0x0000_0001_7000_2000'u64
      let placeAddress = 0x0000_0001_7000_1000'u64
      let computed = coffAmd64RelocationValue(
        relocation, symbolAddress, placeAddress, 0)
      let variant = int64(relocation.typeCode) - 4'i64
      let expected = cast[int64](symbolAddress) + relocation.addend -
        cast[int64](placeAddress) - 4'i64 - variant
      require(computed.value == expected and
              computed.pcBiasBytes == uint8(4 + variant),
              relocation.kindName & " used the wrong S+A-P-4-N formula")

  var symbols: seq[TargetSymbolFact]
  for relocation in newGraph.relocations:
    if not symbols.anyIt(it.name == relocation.targetName):
      symbols.add TargetSymbolFact(
        name: relocation.targetName,
        address: 0x0000_0001_7000_2000'u64 + uint64(symbols.len * 0x100),
        kind: sykData)
  let snapshot = DeterministicTargetSnapshot(
    schemaId: "reprobuild.hcr.target-snapshot.v1",
    snapshotId: "hx-w3-real-coff-fixture",
    pointerWidthBytes: 8,
    symbols: symbols)
  let plan = patchPlan(oldGraph, newGraph, snapshot)
  require(plan.supportProfile == "hx-w3-coff-amd64-object-facts",
          "COFF plan did not identify the HX-W-3 support profile")
  require("hx_w3_rel32_4" in plan.changedFunctions,
          "real COFF code change was absent from the patch plan")
  require(not plan.mutatesTarget and plan.targetMutationOperations == 0,
          "pure planning mutated the target")
  require(plan.relocationDecisions.anyIt(
            it.kindName == "IMAGE_REL_AMD64_REL32_4" and
            it.support == rsSupportedDirect),
          "REL32_4 was not planned as a supported direct relocation")

  echo $(%*{
    "ok": true,
    "exe_identity": identityJson(exeFacts.identity),
    "exe_rva": toHex(exeResolution.rva, 16).toLowerAscii,
    "dll_identity": identityJson(dllFacts.identity),
    "dll_rva": toHex(dllResolution.rva, 16).toLowerAscii,
    "coff": {
      "sections": newFacts.sectionCount,
      "symbols": newFacts.primarySymbolCount,
      "relocations": newFacts.relocationCount,
      "implicit_addends": newFacts.implicitAddendCount,
      "rel32_variants": newFacts.rel32VariantCount,
      "changed_functions": plan.changedFunctions
    }
  })

when isMainModule:
  main()
