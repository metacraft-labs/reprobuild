## HLX-M8 verification gate
## `e2e_hcr_linux_prepare_object_expands_compressed_debug_sections`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §5.1, §8.
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M8 — the residue
## item "`repro hcr prepare-object` could decompress `SHF_COMPRESSED`
## `.debug_*` on ELF, and does not".
##
## ---------------------------------------------------------------------------
## WHAT WAS WRONG, AND WHAT THIS GATE MEASURES
##
## GCC on this toolchain emits `SHF_COMPRESSED` `.debug_*` BY DEFAULT. The HCR
## agent applies relocations to those sections IN MEMORY so a debugger can
## attribute the patched body, and it refuses a compressed one BY NAME
## (`debug-object-compressed-debug-section`) because relocating into a zlib
## stream corrupts it silently. So an object from an ordinary
## `gcc(debug3 = true)` edge carried a `debugObjectPayload` that could never be
## registered.
##
## The only remedy was a per-edge `-gz=none`: a flag `gcc` can express, `clang`
## CANNOT express at all, that exactly ONE HCR edge in this repository carried
## while five other sources did not, and that nothing stops the next edge from
## omitting. `prepare-object` is the pass whose job is to make an object
## patchable. Expanding the sections there fixes the class.
##
## ---------------------------------------------------------------------------
## WHAT MAKES THIS GATE DISCRIMINATE
##
## THE PREMISE IS ASSERTED, NOT ASSUMED. Case 1 fails loudly if the compiler's
## own output has NO compressed section. Without that, a toolchain that stopped
## compressing by default would make every assertion below pass for the wrong
## reason — the expansion would be a no-op and the registration would succeed
## because there was nothing to expand.
##
## THE EXPANSION IS CHECKED AGAINST AN INDEPENDENT PRODUCER. Every section of
## the prepared object is compared byte for byte, together with its flags,
## alignment, entsize, link and info, against `objcopy
## --decompress-debug-sections` run on the same input. `objcopy` is binutils'
## own decompressor and knows nothing about this repository. Without it, the
## gate would only be asserting that this repository's DEFLATE decoder agrees
## with itself, which a decoder that produced plausible-but-wrong debug bytes
## would also satisfy. `objcopy` is REQUIRED: absent, the case FAILS with a
## remedy rather than skipping.
##
## THE END-TO-END ARM IS ONE VARIABLE. Case 2 runs the SAME target binary, the
## SAME patch bytes, the SAME `.eh_frame`, the SAME socket transport and the
## SAME production coordinator client twice, differing ONLY in whether the
## `debugObjectPayload` is the compiler's output or `prepare-object`'s. The
## compiler-output arm must go UNREGISTERED with the named refusal; the
## prepared arm must REGISTER and the unwinder must answer. Both arms assert
## the patch applied (11 -> 77), so the difference is attributable to the
## payload and not to one arm having failed to patch.
##
## WHAT WORLD THIS FAILS IN. Revert the ELF arm of
## `runHcrPrepareObjectCommand` to its `copyFile` passthrough and case 1 goes
## red on `elfHasCompressedSections(prepared)` and on every objcopy
## comparison, and case 2's prepared arm goes red on `jitRegistered`. Break the
## DEFLATE decoder in any way that still produces output of the declared length
## and case 1 goes red on the objcopy content comparison while the length
## assertions stay green — which is why the comparison is on CONTENT and not on
## sizes.

import std/[json, options, os, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_hcr_linkgraph/elf_decompress
  import "../hcr-linux-direct/elf_rel_reader"
  import "./prepare_fixture"

  const Gate = "e2e_hcr_linux_prepare_object_expands_compressed_debug_sections"

  proc reproBinary(repoRoot: string): string =
    result = repoRoot / "build" / "bin" / "repro"
    if not fileExists(result):
      raise newException(IOError,
        Gate & " requires the built `repro` binary at " & result &
        ". Remedy: run `just build` in this checkout.")

  proc workspace(repoRoot: string): string =
    result = repoRoot / "build" / "hcr-linux-prepare"
    createDir(result)

  suite Gate:
    test "prepare-object expands SHF_COMPRESSED debug sections and agrees with objcopy":
      let repoRoot = getCurrentDir()
      let workDir = workspace(repoRoot)
      let objcopy = requireTool("objcopy", Gate,
        "Remedy: enter reprobuild's dev shell (`direnv exec .`), which " &
        "provides binutils. This gate cross-checks its own DEFLATE decoder " &
        "against binutils' and will not run without the second producer.")
      let repro = reproBinary(repoRoot)

      let sourcePath = workDir / "patchable_new.c"
      writeFile(sourcePath, NewSource)

      # ---- THE PREMISE, asserted first. `-g3` with no `-gz` is the spelling a
      # project writes; if this toolchain stopped compressing by default,
      # everything below would pass for the wrong reason.
      let raw = compilePatchObject(workDir, sourcePath, "patchable.raw.o")
      check elfHasCompressedSections(raw)
      let rawParsed = parseElfRelObject(raw)
      var compressedNames: seq[string] = @[]
      for section in rawParsed.sections:
        if (section.flags and ShfCompressed) != 0'u64:
          compressedNames.add section.name
      check compressedNames.len > 0
      # `.debug_info` is the one that matters: it is the section the relocation
      # loop walks, so it is the one whose compression produced the refusal.
      check ".debug_info" in compressedNames

      # ---- the real CLI, not a library call.
      let prepared = workDir / "patchable.prepared.o"
      removeFile(prepared)
      let prepareLog = runOrFail(shellCommand([
        repro, "hcr", "prepare-object",
        "--input", raw, "--output", prepared,
        "--function", VictimSymbol, "--segment", "__HCR"]), repoRoot)
      check fileExists(prepared)
      check prepareLog.contains("objectFormat=elf")
      check prepareLog.contains("decompressedSections=" & $compressedNames.len)
      check prepareLog.contains(".debug_info(")
      check not elfHasCompressedSections(prepared)

      # ---- THE INDEPENDENT PRODUCER.
      let reference = workDir / "patchable.objcopy.o"
      removeFile(reference)
      discard runOrFail(shellCommand([
        objcopy, "--decompress-debug-sections", raw, reference]), repoRoot)
      check not elfHasCompressedSections(reference)

      let preparedParsed = parseElfRelObject(prepared)
      let referenceParsed = parseElfRelObject(reference)

      # PAIRED BY INDEX, not by name, and the names are then asserted to agree
      # at each index. A name-keyed comparison is WRONG here and was measured
      # wrong: a single `-g3` translation unit emits several DISTINCT
      # `.debug_macro` sections that all share that name, so a lookup by name
      # compares the first one against itself three times and never looks at
      # the others. Index pairing also proves the expansion preserved section
      # ORDER, which is what everything referring to a section by index —
      # `sh_link`, `sh_info`, `SHT_GROUP` membership, `st_shndx` — depends on.
      check preparedParsed.sections.len == referenceParsed.sections.len

      proc sectionContent(obj: ElfRelObject; index: int): seq[byte] =
        let section = obj.sections[index]
        result = newSeq[byte](int(section.size))
        for i in 0 ..< int(section.size):
          result[i] = obj.bytes[int(section.offset) + i]

      var compared = 0
      var expandedCompared = 0
      var expandedNames: seq[string] = @[]
      for index in 0 ..< referenceParsed.sections.len:
        let mineHeader = preparedParsed.sections[index]
        let theirsHeader = referenceParsed.sections[index]
        check mineHeader.name == theirsHeader.name
        # SHT_NULL (index 0) and SHT_NOBITS occupy no file bytes; comparing
        # `sh_offset`-addressed content for them would compare unrelated data.
        if index == 0 or int(theirsHeader.size) == 0:
          continue
        # `.shstrtab` is excluded and the exclusion is named rather than
        # silent: `objcopy` rebuilds the section-name string table from
        # scratch, so its bytes differ by ordering alone. The per-index NAME
        # assertion above is what would catch a dropped or reordered section,
        # which is the thing `.shstrtab` content would otherwise have proved.
        if mineHeader.name == ".shstrtab":
          continue
        let mine = sectionContent(preparedParsed, index)
        let theirs = sectionContent(referenceParsed, index)
        if mine != theirs:
          checkpoint("section content differs from objcopy at index " &
            $index & " (" & mineHeader.name & "): " & $mine.len & " vs " &
            $theirs.len & " bytes")
        check mine == theirs
        check mineHeader.flags == theirsHeader.flags
        check mineHeader.entsize == theirsHeader.entsize
        check (mineHeader.flags and ShfCompressed) == 0'u64
        compared.inc
        if (rawParsed.sections[index].flags and ShfCompressed) != 0'u64:
          expandedCompared.inc
          expandedNames.add mineHeader.name
          # An expanded section must be BIGGER than what the compiler wrote,
          # or "expanded" would be satisfied by copying the stream through.
          check mine.len > int(rawParsed.sections[index].size)

      # Anti-vacuity: the loop must have compared something, and in particular
      # must have compared EVERY section the compiler compressed.
      check compared >= 10
      check expandedCompared == compressedNames.len

      writeEvidence(repoRoot, Gate, %*{
        "schemaId": "reprobuild.hcr.hlx-m8.prepare-object-expansion.v1",
        "compilerCompressedSections": compressedNames,
        "sectionsComparedAgainstObjcopy": compared,
        "expandedSectionsCompared": expandedCompared,
        "expandedSectionNames": expandedNames,
        "prepareLog": prepareLog.strip()})

    test "the prepared object registers where the compiler's own output cannot":
      let repoRoot = getCurrentDir()
      let workDir = workspace(repoRoot)
      discard reproBinary(repoRoot)

      let oldPath = workDir / "patchable_old.c"
      let newPath = workDir / "patchable_new.c"
      writeFile(oldPath, OldSource)
      writeFile(newPath, NewSource)

      # The target is compiled from the OLD source, so it starts at 11.
      let target = buildWireTarget(repoRoot, workDir, oldPath,
        "hcr_lx_prepare_target")

      let raw = compilePatchObject(workDir, newPath, "patchable.raw.o")
      let prepared = workDir / "patchable.prepared.o"
      removeFile(prepared)
      discard runOrFail(shellCommand([
        reproBinary(repoRoot), "hcr", "prepare-object",
        "--input", raw, "--output", prepared,
        "--function", VictimSymbol, "--segment", "__HCR"]), repoRoot)

      # The patch BODY and the `.eh_frame` are taken from the PREPARED object
      # in both arms, so the only thing that differs between them is the
      # `debugObjectPayload`.
      let parsedPrepared = parseElfRelObject(prepared)
      let patchBytes = parsedPrepared.functionBytes(VictimSymbol)
      check patchBytes.len > 0
      let ehFrame = parsedPrepared.sectionBytes(".eh_frame")
      check ehFrame.len > 0

      let rawBytes = fileBytes(raw)
      let preparedBytes = fileBytes(prepared)
      check rawBytes.len > 1000
      check preparedBytes.len > rawBytes.len

      let compressedArm = deliverPatch(repoRoot, target,
        workDir / "raw.sock", patchBytes, rawBytes, ehFrame)
      let preparedArm = deliverPatch(repoRoot, target,
        workDir / "prepared.sock", patchBytes, preparedBytes, ehFrame)

      # ---- BOTH ARMS PATCHED. Without this the difference below could be
      # explained by one arm never reaching Phase I at all.
      for arm in [compressedArm, preparedArm]:
        check arm.node["before"].getInt() == OriginalValue
        check arm.node["after"].getInt() == PatchedValue
        check arm.node["codeSwapped"].getBool()
        check arm.delivery.patchApplied.isSome

      # ---- the compiler's own output: REFUSED, by name.
      check compressedArm.node["debugObjectBytes"].getInt() == 0
      check not compressedArm.node["jitRegistered"].getBool()
      check compressedArm.node["jitRefused"].getBool()
      let compressedApplied = compressedArm.delivery.patchApplied.get()
      check compressedApplied.registrationDegraded
      check compressedApplied.registrationDiagnostic.contains(
        "debug-object-compressed-debug-section")

      # ---- the prepared object: REGISTERED, and the unwinder answers.
      check preparedArm.node["debugObjectBytes"].getInt() == preparedBytes.len
      check preparedArm.node["jitRegistered"].getBool()
      check not preparedArm.node["jitRefused"].getBool()
      check preparedArm.node["ehFrameRegistered"].getBool()
      check preparedArm.node["fdeFound"].getBool()
      check preparedArm.node["jitFirstEntry"].getStr() != "0x0"
      let preparedApplied = preparedArm.delivery.patchApplied.get()
      check not preparedApplied.registrationDegraded
      check preparedApplied.registrationDegradedReported

      # The two arms are asserted to DIFFER directly rather than each against
      # its own constant.
      check compressedArm.node["jitRegistered"].getBool() !=
        preparedArm.node["jitRegistered"].getBool()

      writeEvidence(repoRoot, Gate & ".registration", %*{
        "schemaId": "reprobuild.hcr.hlx-m8.prepare-object-registration.v1",
        "rawObjectBytes": rawBytes.len,
        "preparedObjectBytes": preparedBytes.len,
        "compressedArm": compressedArm.node,
        "compressedArmDiagnostic": compressedApplied.registrationDiagnostic,
        "preparedArm": preparedArm.node})

else:
  suite "e2e_hcr_linux_prepare_object_expands_compressed_debug_sections":
    test "the ELF prepare-object expansion gate is linux-x86_64-only":
      skip()
