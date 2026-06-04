import std/[algorithm, json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_hcr_linkgraph

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  for index, arg in args:
    if index > 0:
      result.add(" ")
    result.add(q(arg))

proc runSuccess(command: string; cwd = getCurrentDir()): string =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    checkpoint(res.output)
  check res.exitCode == 0
  res.output

proc findSection(graph: LinkGraph; name: string): SectionFact =
  for section in graph.sections:
    if section.sectionFullName == name:
      return section
  fail()

proc hasRelocation(graph: LinkGraph; sectionName, kindName, targetName: string): bool =
  for relocation in graph.relocations:
    let section = graph.sections[relocation.sectionId]
    if section.sectionFullName == sectionName and relocation.kindName == kindName and
        relocation.targetName == targetName:
      return true
  false

proc diffByName(diff: FunctionDiffSet; name: string): FunctionDiff =
  for entry in diff.functions:
    if entry.name == name:
      return entry
  fail()

proc decisionKinds(decisions: seq[RelocationDecision]): seq[string] =
  for decision in decisions:
    result.add decision.functionName & ":" & decision.kindName & ":" & $decision.support
  result.sort()

proc hasUnsupportedFeature(graph: LinkGraph; feature: string): bool =
  for item in graph.unsupportedFeatures:
    if item.feature == feature:
      return true
  false

proc noisyRelocationFields(graph: LinkGraph; functionName: string): LinkGraph =
  result = graph
  let symbol = result.findSymbol(functionName)
  let sectionId = symbol.sectionId
  for relocation in result.relocationsForSymbol(symbol):
    let offset = int(relocation.offset)
    let width = max(1, int(relocation.lengthBytes))
    for i in 0 ..< width:
      if offset + i >= 0 and offset + i < result.sections[sectionId].data.len:
        result.sections[sectionId].data[offset + i] =
          result.sections[sectionId].data[offset + i] xor 0xa5'u8

proc writeInspection(path: string; oldGraph, newGraph: LinkGraph;
                     diff: FunctionDiffSet; classifications: seq[RelocationDecision];
                     plan: PatchPlanEvidence; commands, fileOld, fileNew: string) =
  var root = newJObject()
  root["schemaId"] = newJString("reprobuild.hcr.m26.inspection.v1")
  root["oldGraph"] = linkGraphJson(oldGraph)
  root["newGraph"] = linkGraphJson(newGraph)
  root["diff"] = diffJson(diff)
  var classJson = newJArray()
  for decision in classifications:
    classJson.add %*{
      "relocationId": decision.relocationId,
      "functionName": decision.functionName,
      "sectionName": decision.sectionName,
      "kindName": decision.kindName,
      "targetName": decision.targetName,
      "support": $decision.support,
      "reason": decision.reason
    }
  root["classifications"] = classJson
  root["patchPlan"] = patchPlanJson(plan)
  root["compileCommandEvidence"] = newJString(commands)
  root["oldFile"] = newJString(fileOld.strip())
  root["newFile"] = newJString(fileNew.strip())
  writeFile(path, pretty(root))

when defined(macosx):
  suite "integration_hcr_linkgraph_relocation_classification":
    test "Mach-O arm64 objects produce LinkGraph facts, diffs, relocation classes, and pure plans":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-hcr-m26", "")
      defer: removeDir(tempRoot)

      let fixtureDir = repoRoot / "tests" / "fixtures" / "hcr" / "object-inputs"
      let buildScript = fixtureDir / "build-hcr-linkgraph-fixture.sh"
      check fileExists(fixtureDir / "hcr_linkgraph_old.s")
      check fileExists(fixtureDir / "hcr_linkgraph_new.s")
      check fileExists(buildScript)

      discard runSuccess(shellCommand([buildScript, tempRoot]), repoRoot)
      let oldObj = tempRoot / "hcr_linkgraph_old.o"
      let newObj = tempRoot / "hcr_linkgraph_new.o"
      let evidencePath = tempRoot / "linkgraph-compile-commands.txt"
      check fileExists(oldObj)
      check fileExists(newObj)
      check not fileExists(tempRoot / "hcr_linkgraph_old.dylib")
      check not fileExists(tempRoot / "hcr_linkgraph_new.dylib")
      check not fileExists(tempRoot / "hcr_linkgraph_old.so")
      check not fileExists(tempRoot / "hcr_linkgraph_new.so")

      let commands = readFile(evidencePath)
      check commands.contains("schema_id=reprobuild.hcr.linkgraph-fixture-commands.v1")
      check commands.contains("positive_path=relocatable-object")
      check commands.contains("shared_library_loading_positive_path=forbidden")
      check commands.contains("-c")
      check commands.contains("-g")
      check not commands.contains("-shared")
      check not commands.contains("-dynamiclib")
      check not commands.contains("dlopen")
      check not commands.contains("dlsym")
      check not commands.contains("LoadLibrary")
      check not commands.contains("GetProcAddress")

      let fileOld = runSuccess(shellCommand(["file", oldObj]))
      let fileNew = runSuccess(shellCommand(["file", newObj]))
      # Check Mach-O format + arm64 arch independently because the word
      # ordering of `file(1)`'s Mach-O description has shifted across
      # macOS releases (older: `Mach-O 64-bit arm64 object`, recent:
      # `Mach-O 64-bit object arm64`). Both signals — the Mach-O
      # 64-bit prefix and the arm64 token — must be present to
      # confirm we built an arm64 Mach-O object, but the assertion
      # must not pin a specific phrasing or it rots on every
      # macOS/file upgrade.
      check fileOld.contains("Mach-O 64-bit") and fileOld.contains("arm64")
      check fileNew.contains("Mach-O 64-bit") and fileNew.contains("arm64")

      let oldGraph = parseMachOArm64Object(oldObj)
      let newGraph = parseMachOArm64Object(newObj)

      check oldGraph.schemaId == "reprobuild.hcr.linkgraph.v1"
      check newGraph.arch == "mach-o/arm64"
      check newGraph.sections.len >= 5
      check newGraph.findSection("__TEXT,__text").kind == skCode
      check newGraph.findSection("__DATA,__data").kind == skData
      check newGraph.hasDebugFacts
      check newGraph.hasUnwindFacts
      check newGraph.hasUnsupportedFeature("debug-info-registration")
      check newGraph.hasUnsupportedFeature("unwind-registration")

      let functionNames = newGraph.functionSymbols.mapIt(it.name).sorted()
      check functionNames == @[
        "_hcr_changed_constant",
        "_hcr_changed_data_reader",
        "_hcr_changed_external_call",
        "_hcr_unchanged_leaf",
        "_hcr_unchanged_reloc_data"
      ]
      for name in functionNames:
        let symbol = newGraph.findSymbol(name)
        check symbol.size > 0
        check newGraph.functionBytes(symbol).len == int(symbol.size)

      check newGraph.findSymbol("_hcr_data_anchor").kind == sykData
      check newGraph.findSymbol("_hcr_external_target").kind == sykUndefined

      check newGraph.hasRelocation("__TEXT,__text", "ARM64_RELOC_BRANCH26",
        "_hcr_external_target")
      check newGraph.hasRelocation("__TEXT,__text", "ARM64_RELOC_PAGE21",
        "_hcr_data_anchor")
      check newGraph.hasRelocation("__TEXT,__text", "ARM64_RELOC_PAGEOFF12",
        "_hcr_data_anchor")
      check newGraph.relocations.anyIt(it.kindName == "ARM64_RELOC_UNSIGNED" and
        newGraph.sections[it.sectionId].kind in {skDebug, skUnwind})

      let diff = diffFunctions(oldGraph, newGraph)
      check diff.diffByName("_hcr_changed_constant").kind == fckChangedCode
      check diff.diffByName("_hcr_changed_data_reader").kind == fckChangedCode
      check diff.diffByName("_hcr_changed_external_call").kind == fckChangedCode
      check diff.diffByName("_hcr_unchanged_leaf").kind == fckUnchanged
      let unchangedReloc = diff.diffByName("_hcr_unchanged_reloc_data")
      check unchangedReloc.kind == fckUnchanged
      check unchangedReloc.normalizedBytesEqual
      check unchangedReloc.relocationSignaturesEqual
      check unchangedReloc.newRelocations.len == 2

      let noisyGraph = noisyRelocationFields(newGraph, "_hcr_unchanged_reloc_data")
      let noiseDiff = diffFunctions(newGraph, noisyGraph)
      let noiseEntry = noiseDiff.diffByName("_hcr_unchanged_reloc_data")
      check not noiseEntry.rawBytesEqual
      check noiseEntry.normalizedBytesEqual
      check noiseEntry.relocationSignaturesEqual
      check noiseEntry.kind == fckUnchanged

      var mutatedGraph = newGraph
      let stable = mutatedGraph.findSymbol("_hcr_unchanged_reloc_data")
      for relocation in mutatedGraph.relocationsForSymbol(stable):
        if relocation.kindName == "ARM64_RELOC_PAGEOFF12":
          mutatedGraph.relocations[relocation.id].targetName = "_hcr_other_data"
          break
      let signatureDiff = diffFunctions(newGraph, mutatedGraph)
      let signatureEntry = signatureDiff.diffByName("_hcr_unchanged_reloc_data")
      check signatureEntry.normalizedBytesEqual
      check not signatureEntry.relocationSignaturesEqual
      check signatureEntry.kind == fckRelocationSignatureChanged

      let snapshot = DeterministicTargetSnapshot(
        schemaId: "reprobuild.hcr.target-snapshot.v1",
        snapshotId: "m26-deterministic-target",
        pointerWidthBytes: 8,
        symbols: @[
          TargetSymbolFact(name: "_hcr_external_target", address: 0x1000_4000'u64,
            kind: sykFunction),
          TargetSymbolFact(name: "_hcr_data_anchor", address: 0x1000_8000'u64,
            kind: sykData)
        ]
      )
      let classifications = classifyRelocations(newGraph, snapshot)
      let classificationKinds = classifications.decisionKinds()
      check classificationKinds.anyIt(it.contains("ARM64_RELOC_BRANCH26:rsSupportedDirect"))
      check classificationKinds.anyIt(it.contains("ARM64_RELOC_PAGE21:rsSupportedDirect"))
      check classificationKinds.anyIt(it.contains("ARM64_RELOC_PAGEOFF12:rsSupportedDirect"))
      check classifications.anyIt(it.support == rsUnsupported and
        it.kindName == "ARM64_RELOC_UNSIGNED" and it.reason.len > 0)

      let missingTarget = DeterministicTargetSnapshot(
        schemaId: "reprobuild.hcr.target-snapshot.v1",
        snapshotId: "m26-missing-target",
        pointerWidthBytes: 8,
        symbols: @[]
      )
      let rejected = classifyRelocations(newGraph, missingTarget)
      check rejected.anyIt(it.sectionName == "__TEXT,__text" and
        it.kindName == "ARM64_RELOC_BRANCH26" and it.support == rsUnsupported and
        it.reason.contains("absent"))

      let plan = patchPlan(oldGraph, newGraph, snapshot)
      check plan.schemaId == "reprobuild.hcr.patch-plan-evidence.v1"
      check plan.supportProfile == "m26-macho64-arm64-object-facts"
      check plan.targetSnapshotId == "m26-deterministic-target"
      check plan.changedFunctions == @[
        "_hcr_changed_constant",
        "_hcr_changed_data_reader",
        "_hcr_changed_external_call"
      ]
      check plan.plannedSectionBytes.len == 3
      check plan.relocationDecisions.len >= 3
      check plan.requiredTargetSymbols == @["_hcr_data_anchor", "_hcr_external_target"]
      check plan.unsupportedFallbackReasons.anyIt(it.contains("debug"))
      check plan.unsupportedFallbackReasons.anyIt(it.contains("unwind"))
      check not plan.mutatesTarget
      check plan.targetMutationOperations == 0
      check not plan.sharedLibraryPositivePath

      let rendered = patchPlanJson(plan)
      check rendered["sharedLibraryPositivePath"].getBool() == false
      check rendered["targetMutationOperations"].getInt() == 0
      check rendered["relocationDecisions"].len >= 3

      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeInspection(logDir / "integration_hcr_linkgraph_relocation_classification.json",
        oldGraph, newGraph, diff, classifications, plan, commands, fileOld, fileNew)

when not defined(macosx):
  suite "integration_hcr_linkgraph_relocation_classification":
    test "M26 Mach-O arm64 gate is macOS-only":
      skip()
