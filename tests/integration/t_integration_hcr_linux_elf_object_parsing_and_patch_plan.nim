## HLX-M1 verification gate
## `integration_hcr_linux_elf_object_parsing_and_patch_plan`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §7.5 and
## `Test-Designs/Reprobuild-HCR-Direct-Patch-Algorithm-Validation.md`. The ELF
## analogue of the M26 Mach-O gate
## (`integration_hcr_linkgraph_relocation_classification`).
##
## `allowed_mocks: none`. Every object this gate reads is produced here and now
## by a real compiler: two generations of a real C translation unit, a real C++
## translation unit for `SHT_GROUP`/`GRP_COMDAT`, a real
## `-fpatchable-function-entry` build for `SHF_LINK_ORDER`, and a real
## 66,000-function object that forces all three `SHN_XINDEX` escapes. No bytes
## are hand-assembled and no fixture is checked in pre-built.
##
## What it establishes:
##
##   * Section, symbol and relocation tables are read from real objects, and
##     `st_size` is used as authoritative rather than inferred from gaps
##     (design §7.5's one convenience over Mach-O).
##   * Function diffing separates three outcomes that are genuinely different:
##     unchanged, changed body, and changed relocation SIGNATURE.
##   * Relocation classification produces a supported-direct subset and, for
##     everything outside it, a STRUCTURED REASON. The unsupported cases here
##     are real compiler output — GOT-relative and TLS relocations GCC emitted
##     on its own — not constructions invented to be rejected.
##   * Unsupported features are REPORTED, not dropped. The gate asserts that
##     the reasons reach `PatchPlanEvidence.unsupportedFallbackReasons`, which
##     is the field a caller would actually read.
##   * `SHN_XINDEX`: all three escapes at once — `e_shnum == 0` with the real
##     count in `shdr[0].sh_size`, `e_shstrndx == SHN_XINDEX`, and symbols
##     resolved through `SHT_SYMTAB_SHNDX` — and a function whose section index
##     is above `SHN_LORESERVE` still parsed as defined.
##
## Falsifiability note. The `SHN_XINDEX` arm is not decorative: applying the
## reserved-range test to an ALREADY-EXPANDED section index silently
## reclassifies every high-index function as undefined, which is a defect this
## gate was written to catch and did catch. Re-measured by review 2026-09-10
## against the fixture this gate actually compiles: 724 of its 66,000 functions
## carry an expanded index at or above SHN_LORESERVE, so that is the blast
## radius here. (An earlier, larger fixture was the source of the "4,725"
## figure once recorded in this comment; it is not the fixture that ships.)
## The arm asserts the function COUNT, which is what makes it robust against a
## PARTIAL drop anywhere in the table rather than only at the sampled symbol.
##
## No silent skips: a missing compiler fails the gate loudly.

import std/[algorithm, json, os, osproc, sequtils, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_linkgraph
  import repro_project_dsl

  # Taken from the patchable build profile itself, so the profile and this gate
  # cannot drift apart.
  let PatchableFlags = patchableCompileFlags(ReproHcr())

  proc q(value: string): string = quoteShell(value)

  proc shellCommand(args: openArray[string]): string =
    for index, arg in args:
      if index > 0:
        result.add(" ")
      result.add(q(arg))

  proc runSuccess(command: string; cwd: string): string =
    let res = execCmdEx(command, workingDir = cwd)
    if res.exitCode != 0:
      checkpoint("command failed (exit " & $res.exitCode & "): " & command)
      checkpoint(res.output)
    require res.exitCode == 0
    res.output

  proc requireTool(name: string) =
    let found = findExe(name)
    if found.len == 0:
      checkpoint("required tool is not on PATH: " & name)
    require found.len > 0

  proc requireFixture(path: string) =
    if not fileExists(path):
      checkpoint("fixture source is missing: " & path)
    require fileExists(path)

  proc diffByName(diff: FunctionDiffSet; name: string): FunctionDiff =
    for entry in diff.functions:
      if entry.name == name:
        return entry
    checkpoint("function diff has no entry for " & name)
    fail()

  proc hasFeature(graph: LinkGraph; feature: string): bool =
    for item in graph.unsupportedFeatures:
      if item.feature == feature:
        return true
    false

  proc featureReason(graph: LinkGraph; feature: string): string =
    for item in graph.unsupportedFeatures:
      if item.feature == feature:
        return item.reason
    ""

  proc decisionsFor(decisions: seq[RelocationDecision];
                    kindName: string): seq[RelocationDecision] =
    for decision in decisions:
      if decision.kindName == kindName:
        result.add decision

  proc sectionNamed(graph: LinkGraph; name: string): SectionFact =
    for section in graph.sections:
      if section.name == name:
        return section
    checkpoint("object has no section named " & name)
    fail()

  suite "integration_hcr_linux_elf_object_parsing_and_patch_plan":
    test "real ELF relocatable objects produce facts, diffs, classified relocations and plans":
      requireTool("gcc")
      requireTool("readelf")

      let repoRoot = getCurrentDir()
      let fixtureDir = repoRoot / "tests" / "fixtures" / "hcr" /
        "linux-elf-objects"
      let gen1Source = fixtureDir / "hcr_lx_obj_gen1.c"
      let gen2Source = fixtureDir / "hcr_lx_obj_gen2.c"
      requireFixture(gen1Source)
      requireFixture(gen2Source)

      let workDir = repoRoot / "build" / "hcr-linux-elf-objects"
      removeDir(workDir)
      createDir(workDir)

      let gen1Object = workDir / "gen1.o"
      let gen2Object = workDir / "gen2.o"
      for (source, output) in [(gen1Source, gen1Object), (gen2Source, gen2Object)]:
        discard runSuccess(shellCommand(["gcc", "-O2", "-g", "-fPIC",
          "-ffunction-sections", "-fdata-sections", "-c", source,
          "-o", output]), repoRoot)

      var gen1Facts: ElfObjectFacts
      var gen2Facts: ElfObjectFacts
      let gen1 = parseElfX86_64Object(gen1Object, gen1Facts)
      let gen2 = parseElfX86_64Object(gen2Object, gen2Facts)

      # -------------------------------------------------------------------
      # Section, symbol and relocation facts.
      # -------------------------------------------------------------------
      check gen1.format == ofElf64X86_64
      check gen1.arch == "elf64/x86-64"
      check gen1.sections.len == gen1Facts.sectionCount
      check gen1.sections.len > 10
      check gen1.relocations.len > 0
      check gen1.hasDebugFacts        # -g was passed
      check gen1.hasUnwindFacts       # .eh_frame is emitted for these functions

      # `-ffunction-sections` really did give each function its own section, so
      # the section names below are the ones the reader read and not defaults.
      let changedSection = gen1.sectionNamed(".text.hcr_lx_obj_changed_leaf")
      check changedSection.kind == skCode
      check gen1.sectionNamed(".debug_info").kind == skDebug
      check gen1.sectionNamed(".eh_frame").kind == skUnwind

      # Design §7.5: `st_size` is authoritative on ELF, so every function
      # symbol carries a real size and none had to be inferred from the gap to
      # the next symbol.
      let functions = gen1.functionSymbols()
      # Review 2026-09-10: an EXACT count, not a floor. `functionSymbols`
      # already filters on `size > 0`, so the per-symbol size check below is a
      # tautology over the set that predicate defines and cannot fail on its
      # own — the count is the only thing standing between this arm and a
      # vacuous pass. gen1.c defines exactly six functions; if sizes went to
      # zero the set would shrink and this line reddens.
      check functions.len == 6
      for symbol in functions:
        checkpoint("function " & symbol.name)
        check symbol.size > 0'u64
        check symbol.isDefined
        check gen1.functionBytes(symbol).len == int(symbol.size)

      # A NOBITS section must contribute no file bytes. Reading `sh_size` bytes
      # at its `sh_offset` would silently return whatever section follows it.
      for section in gen1.sections:
        if section.name.startsWith(".bss") or section.name.startsWith(".tbss"):
          check section.data.len == 0

      # -------------------------------------------------------------------
      # Diffing: three genuinely different outcomes.
      # -------------------------------------------------------------------
      let diff = diffFunctions(gen1, gen2)
      check diff.diffByName("hcr_lx_obj_unchanged_leaf").kind == fckUnchanged
      check diff.diffByName("hcr_lx_obj_changed_leaf").kind == fckChangedCode
      # The extra call in generation two changes the relocation signature, not
      # only the bytes, and must be classified as such.
      check diff.diffByName("hcr_lx_obj_calls_external").kind ==
        fckRelocationSignatureChanged
      let changedNames = diff.changedFunctionNames()
      check "hcr_lx_obj_changed_leaf" in changedNames
      check "hcr_lx_obj_calls_external" in changedNames
      check "hcr_lx_obj_unchanged_leaf" notin changedNames

      # -------------------------------------------------------------------
      # Relocation classification. The target snapshot is deliberately small:
      # it names the external function and the two globals a plan would have to
      # bind, and nothing else, so "absent from the snapshot" is also exercised.
      # -------------------------------------------------------------------
      let snapshot = DeterministicTargetSnapshot(
        schemaId: "reprobuild.hcr.target-snapshot.v1",
        snapshotId: "hlx-m1-elf-object-fixture",
        pointerWidthBytes: 8,
        symbols: @[
          TargetSymbolFact(name: "hcr_lx_obj_external",
                           address: 0x0000_7f00_0010_0000'u64,
                           kind: sykFunction),
          TargetSymbolFact(name: "hcr_lx_obj_global_counter",
                           address: 0x0000_7f00_0020_0000'u64,
                           kind: sykData),
          TargetSymbolFact(name: "hcr_lx_obj_table",
                           address: 0x0000_7f00_0030_0000'u64,
                           kind: sykData)])

      let decisions = classifyRelocations(gen2, snapshot)
      check decisions.len == gen2.relocations.len

      # PLT32 to a real external function: supported, and bound to the address
      # the snapshot gave.
      let pltDecisions = decisions.decisionsFor("R_X86_64_PLT32")
      check pltDecisions.len > 0
      var boundExternal = false
      for decision in pltDecisions:
        if decision.targetName == "hcr_lx_obj_external":
          checkpoint("PLT32 -> " & decision.targetName & ": " & decision.reason)
          check decision.support == rsSupportedDirect
          check decision.requiresTargetSymbol
          check decision.targetAddress == 0x0000_7f00_0010_0000'u64
          boundExternal = true
      check boundExternal

      # GOT-relative: real GCC output, and outside the HLX-M1 subset. The point
      # is the REASON, not merely the rejection.
      let gotDecisions = decisions.decisionsFor("R_X86_64_REX_GOTPCRELX")
      check gotDecisions.len > 0
      for decision in gotDecisions:
        check decision.support == rsUnsupported
        check decision.reason.contains("GOT")
        check decision.reason.len > 20

      # TLS: also real GCC output, also outside the subset, also with a reason
      # that names why.
      #
      # Measured, GCC puts a `R_X86_64_DTPOFF32` in `.debug_info` as well as in
      # `.text`, and those two are correctly given DIFFERENT reasons: the code
      # one says TLS is outside the profile, the debug one says debug
      # relocations are recorded but not applied. Both are unsupported; only
      # the code one is a statement about TLS. Asserting a single reason for
      # both would have forced one of them to be wrong.
      var tlsInCode = 0
      var tlsInNonCode = 0
      for decision in decisions:
        if decision.kindName in ["R_X86_64_TLSLD", "R_X86_64_DTPOFF32",
                                 "R_X86_64_TLSGD", "R_X86_64_GOTTPOFF"]:
          check decision.support == rsUnsupported
          if decision.sectionName.startsWith(".text"):
            tlsInCode += 1
            check decision.reason.contains("thread-local")
          else:
            tlsInNonCode += 1
            check decision.reason.contains("does not apply them")
      check tlsInCode > 0
      check tlsInNonCode > 0

      # A relocation whose target is not in the snapshot is reported as such,
      # rather than being planned against address 0.
      var sawAbsentTarget = false
      for decision in decisions:
        if decision.requiresTargetSymbol and decision.targetAddress == 0'u64:
          check decision.reason.contains("absent from the deterministic target")
          sawAbsentTarget = true
      check sawAbsentTarget

      # -------------------------------------------------------------------
      # The plan, and the structured reasons reaching the field a caller reads.
      # -------------------------------------------------------------------
      let plan = patchPlan(gen1, gen2, snapshot)
      check plan.schemaId == "reprobuild.hcr.patch-plan-evidence.v1"
      check plan.supportProfile == "hlx-m1-elf64-x86-64-object-facts"
      check plan.targetSnapshotId == "hlx-m1-elf-object-fixture"
      # A plan is an analysis, not an action.
      check plan.mutatesTarget == false
      check plan.targetMutationOperations == 0

      check "hcr_lx_obj_changed_leaf" in plan.changedFunctions
      check "hcr_lx_obj_calls_external" in plan.changedFunctions
      check "hcr_lx_obj_unchanged_leaf" notin plan.changedFunctions

      # Real bytes for every changed function, taken from the section the
      # symbol is defined in.
      check plan.plannedSectionBytes.len == plan.changedFunctions.len
      for planned in plan.plannedSectionBytes:
        checkpoint("planned " & planned.functionName & " in " &
          planned.sectionName)
        check planned.byteCount > 0'u64
        check planned.bytes.len == int(planned.byteCount)
        check planned.rawDigest.startsWith("blake3-256:")
        check planned.sectionName.startsWith(".text")

      check "hcr_lx_obj_external" in plan.requiredTargetSymbols

      # Unsupported features are REPORTED, not dropped. This is the assertion
      # the milestone's description turns on.
      check plan.unsupportedFallbackReasons.len > 0
      let allReasons = plan.unsupportedFallbackReasons.join(" | ")
      checkpoint("unsupportedFallbackReasons: " & allReasons)
      check allReasons.contains("thread-local")
      check gen2.hasFeature("elf-tls-section")
      check gen2.featureReason("elf-tls-section").contains("SHF_TLS")
      check gen2.hasFeature("debug-info-registration")
      check gen2.hasFeature("unwind-registration")

      # -------------------------------------------------------------------
      # `SHT_GROUP` / `GRP_COMDAT`, from a real C++ translation unit.
      # -------------------------------------------------------------------
      requireTool("g++")
      let comdatSource = fixtureDir / "hcr_lx_obj_comdat.cpp"
      requireFixture(comdatSource)
      let comdatObject = workDir / "comdat.o"
      discard runSuccess(shellCommand(["g++", "-O2", "-std=c++17", "-fPIC",
        "-ffunction-sections", "-c", comdatSource, "-o", comdatObject]),
        repoRoot)
      var comdatFacts: ElfObjectFacts
      let comdat = parseElfX86_64Object(comdatObject, comdatFacts)
      # Cross-checked against readelf so the count is not just this reader
      # agreeing with itself.
      var readelfGroupCount = 0
      for line in runSuccess(shellCommand(["readelf", "-SW", comdatObject]),
          repoRoot).splitLines():
        if line.contains(" GROUP "):
          readelfGroupCount += 1
      check readelfGroupCount > 0
      check comdatFacts.comdatGroupCount == readelfGroupCount
      check comdat.hasFeature("elf-comdat-group-member")
      let comdatReason = comdat.featureReason("elf-comdat-group-member")
      checkpoint("comdat reason: " & comdatReason)
      check comdatReason.contains("COMDAT group")
      # The reason names the signature symbol, which is what identifies WHICH
      # group a section belongs to.
      check comdatReason.contains("_Z") or comdatReason.contains("HcrLxBox")

      # -------------------------------------------------------------------
      # `SHF_LINK_ORDER`: how `__patchable_function_entries` survives
      # `--gc-sections`. Built with the real patchable profile flags.
      # -------------------------------------------------------------------
      check PatchableFlags == @["-fpatchable-function-entry=16,0",
                                "-falign-functions=16"]
      let patchableObject = workDir / "patchable.o"
      var patchableArgs = @["gcc", "-O2", "-fPIC", "-ffunction-sections"]
      patchableArgs.add PatchableFlags
      patchableArgs.add ["-c", gen1Source, "-o", patchableObject]
      discard runSuccess(shellCommand(patchableArgs), repoRoot)
      var patchableFacts: ElfObjectFacts
      let patchable = parseElfX86_64Object(patchableObject, patchableFacts)
      check patchableFacts.patchableEntrySectionCount > 0
      check patchableFacts.linkOrderSectionCount >=
        patchableFacts.patchableEntrySectionCount
      check patchable.hasFeature("elf-shf-link-order")
      check patchable.featureReason("elf-shf-link-order")
        .contains("SHF_LINK_ORDER")
      # The plain build has no such section, so the assertion above is about
      # the flags and not about every object everywhere.
      check gen1Facts.patchableEntrySectionCount == 0

      # -------------------------------------------------------------------
      # `SHN_XINDEX`, all three escapes, from a real compile.
      # -------------------------------------------------------------------
      const XindexFunctionCount = 66000
      let xindexSource = workDir / "hcr_lx_obj_xindex.c"
      var generated = newStringOfCap(XindexFunctionCount * 34)
      for i in 0 ..< XindexFunctionCount:
        generated.add "int hcr_lx_x_" & $i & "(int v){return v+" & $i & ";}\n"
      writeFile(xindexSource, generated)
      let xindexObject = workDir / "xindex.o"
      # `-O0` keeps this compile to a few seconds; the escapes depend on the
      # SECTION COUNT, which `-ffunction-sections` decides, not on optimisation.
      discard runSuccess(shellCommand(["gcc", "-O0", "-ffunction-sections",
        "-c", xindexSource, "-o", xindexObject]), repoRoot)

      # Cross-check the preconditions with readelf before trusting the reader:
      # if the compiler stopped overflowing, this arm would prove nothing.
      let xindexHeader = runSuccess(shellCommand(["readelf", "-hW",
        xindexObject]), repoRoot)
      check xindexHeader.contains("Number of section headers:         0 (")
      check xindexHeader.contains("Section header string table index: 65535 (")

      var xindexFacts: ElfObjectFacts
      let xindex = parseElfX86_64Object(xindexObject, xindexFacts)
      check xindexFacts.usedShnumOverflow
      check xindexFacts.usedShstrndxXindex
      check xindexFacts.xindexSymbolCount > 0
      check xindexFacts.sectionCount > 65535
      check xindex.hasFeature("elf-shn-xindex-in-use")

      # EVERY generated function is present. Testing the reserved range
      # against an already-expanded index silently drops the functions whose
      # section index is above SHN_LORESERVE — 724 of the 66,000 here,
      # re-measured by review 2026-09-10. The COUNT is what makes this robust:
      # the spot check below happens to sample a high-index symbol and would
      # also redden, but only the count catches a partial drop elsewhere.
      check xindex.elfFunctionSymbolCount() == XindexFunctionCount

      # And a specific high-index function resolves with the right section.
      var highIndexChecked = false
      for detail in xindexFacts.symbolDetails:
        if xindex.symbols[detail.symbolIndex].name == "hcr_lx_x_65999":
          check detail.sectionIndex > 0xff00'u32
          check xindex.symbols[detail.symbolIndex].isDefined
          check xindex.sections[int(detail.sectionIndex)].name ==
            ".text.hcr_lx_x_65999"
          highIndexChecked = true
      check highIndexChecked

      # -------------------------------------------------------------------
      # Malformed input is a raise, never a partial graph. "0 symbols" and
      # "the symbol table could not be read" must not be the same answer.
      # -------------------------------------------------------------------
      let truncated = workDir / "truncated.o"
      let gen1Bytes = readFile(gen1Object)
      writeFile(truncated, gen1Bytes[0 ..< 128])
      var truncatedFacts: ElfObjectFacts
      var raised = false
      try:
        discard parseElfX86_64Object(truncated, truncatedFacts)
      except ValueError:
        raised = true
      check raised

      let notElf = workDir / "not-an-object.o"
      writeFile(notElf, "this is definitely not an ELF file at all, not even a bit")
      raised = false
      try:
        discard parseElfX86_64Object(notElf, truncatedFacts)
      except ValueError:
        raised = true
      check raised

      # -------------------------------------------------------------------
      # Evidence.
      # -------------------------------------------------------------------
      var evidence = newJObject()
      evidence["schemaId"] =
        newJString("reprobuild.hcr.hlx-m1.elf-object-parsing-gate.v1")
      evidence["gccVersion"] =
        newJString(runSuccess("gcc --version", repoRoot).splitLines()[0])
      evidence["patchableFlags"] = %PatchableFlags
      evidence["generation1"] = %*{
        "sections": gen1.sections.len,
        "symbols": gen1.symbols.len,
        "relocations": gen1.relocations.len,
        "functions": gen1.elfFunctionSymbolCount()
      }
      evidence["diff"] = %*{
        "unchanged": $diff.diffByName("hcr_lx_obj_unchanged_leaf").kind,
        "changedBody": $diff.diffByName("hcr_lx_obj_changed_leaf").kind,
        "changedSignature": $diff.diffByName("hcr_lx_obj_calls_external").kind
      }
      evidence["plan"] = %*{
        "supportProfile": plan.supportProfile,
        "changedFunctions": plan.changedFunctions,
        "requiredTargetSymbols": plan.requiredTargetSymbols,
        "unsupportedFallbackReasons": plan.unsupportedFallbackReasons,
        "relocationDecisions": plan.relocationDecisions.len
      }
      evidence["comdat"] = %*{
        "groupsFromReader": comdatFacts.comdatGroupCount,
        "groupsFromReadelf": readelfGroupCount
      }
      evidence["patchableSections"] = %*{
        "patchableEntrySections": patchableFacts.patchableEntrySectionCount,
        "linkOrderSections": patchableFacts.linkOrderSectionCount
      }
      evidence["shnXindex"] = %*{
        "generatedFunctions": XindexFunctionCount,
        "sectionCount": xindexFacts.sectionCount,
        "eShnumOverflow": xindexFacts.usedShnumOverflow,
        "eShstrndxXindex": xindexFacts.usedShstrndxXindex,
        "symbolsViaSymtabShndx": xindexFacts.xindexSymbolCount,
        "functionsParsed": xindex.elfFunctionSymbolCount()
      }
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir /
        "integration_hcr_linux_elf_object_parsing_and_patch_plan.json",
        pretty(evidence))

else:
  suite "integration_hcr_linux_elf_object_parsing_and_patch_plan":
    test "HLX-M1 ELF object parsing gate is linux-x86_64-only":
      skip()
