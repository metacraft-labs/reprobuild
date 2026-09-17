# type_layout_driver.nim
#
# Automated Integration Verification Gate for Milestone HAX-M1:
# "Pre-Flight Binary AST Type Layout Validation"
#
# Design doc: reprobuild-specs/HCR/Patch-Loading-Lifecycle.md §3
#             reprobuild-specs/HCR/Binary-Diffing-And-Symbol-Resolution.md §4
# Related milestones:
# - reprobuild-specs/HCR-Advanced-Lifecycle-And-Tooling.milestones.org (HAX-M1)
#
# Gate type: integration
# Real components:
# - Real binary AST type layout extractor (repro_hcr_linkgraph/type_layout)
# - Real DWARF debug info parsing from compiled relocatable object files
# - Real C compiler (clang) toolchain generating native Mach-O / ELF fixtures
# - Real type layout differential analysis and refusal classifier
#
# Allowed mocks: arm 5 uses canned dumper executables to make candidate
# disagreement deterministic. All layout compatibility arms use real compiler
# objects and the installed DWARF tools; the pure parser fixtures live separately.
#
# Asserts:
# 1. Anti-vacuity: Type parser extracts exact member offsets (0, 4, 8) and member counts.
# 2. Control arm: Identical struct layout with altered function logic passes cleanly.
# 3. Positive arm: Multiple unchanged struct types with modified function bodies pass cleanly.
# 4. Refusal arm: Struct member offset shift and field reordering refused with `type-layout-incompatible`
#    naming the struct, member, expected offset, and observed offset.
# 5. Class-2 recording arm: the same object file, resolved over two DIFFERENT
#    single-tool search paths, yields DIFFERENT type facts AND a different
#    recorded `DwarfToolResolution` / `dwarfToolIdentity` that names the tool
#    actually used, its resolved executable path, and the search path walked.
#    This is the property `reprobuild-specs/Package-Model.md` class 2 demands
#    ("the resulting action identity records the search path, the resolved
#    executable path, and configured probes") and that a bare
#    `findExe` + `execCmdEx` cannot provide.
# 6. Falsifier: Simulates omitting member offset validation (--falsify-ignore-offset-shift),
#    causing incompatible patch to be accepted and triggering FALSIFIER-CAUGHT.

import std/[os, osproc, strutils, sequtils]
import repro_hcr_linkgraph

# ---------------------------------------------------------------------------
# The execution half of the class-2 seam.
#
# `repro_hcr_linkgraph` parses object files and records resolutions; it does
# not spawn processes (see scripts/check_ambient_execution.sh). The caller that
# owns the identity supplies the runner. In production that is a build edge
# spawning under the monitor with `BuildAction.toolIdentityRefs`; here it is
# this gate, and tests are allowed to shell out to fixtures.
#
# The command construction below is byte-identical to the one this library
# used before the seam existed, so the arms below exercise the same execution
# behaviour they always did.
# ---------------------------------------------------------------------------
proc ambientDwarfRunner(executablePath: string; args: seq[string]):
    tuple[output: string, exitCode: int] =
  let cmd = quoteShell(executablePath) &
    (if args.len > 0: " " & args.map(quoteShell).join(" ") else: "")
  execCmdEx(cmd)

proc fail(msg: string) {.noreturn.} =
  stderr.writeLine("ERROR: " & msg)
  quit(1)

proc requireContains(haystack, needle, what: string) =
  ## Anti-vacuity guard: an all-empty record would satisfy a naive equality
  ## check between two identities, so every identity assertion in arm 5 is a
  ## containment assertion against a SPECIFIC expected substring.
  if haystack.len == 0:
    fail(what & ": recorded value is EMPTY (vacuous record)")
  if not haystack.contains(needle):
    fail(what & ": expected to contain '" & needle & "', got:\n" & haystack)

proc writeStubDumper(dir, name, payload: string) =
  ## Write a single-tool search-path directory holding one canned DWARF
  ## dumper. Canned rather than real binutils so the arm is hermetic: the
  ## point is that the FOUR configured candidates disagree, which must be
  ## observable on any host regardless of which of them happens to be
  ## installed.
  createDir(dir)
  let path = dir / name
  writeFile(path, "#!/bin/sh\ncat <<'REPRO_DWARF_EOF'\n" & payload &
    "REPRO_DWARF_EOF\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
                            fpGroupRead, fpGroupExec,
                            fpOthersRead, fpOthersExec})

# dwarfdump-format output: Vector3D { x@0, y@4, z@8 }, byte_size 16.
const DwarfdumpStubPayload = """
0x0000000b: DW_TAG_compile_unit
              DW_AT_name	("stub.c")

0x00000026:   DW_TAG_structure_type
                DW_AT_name	("Vector3D")
                DW_AT_byte_size	(0x10)

0x0000002f:     DW_TAG_member
                  DW_AT_name	("x")
                  DW_AT_data_member_location	(0x00)

0x0000003a:     DW_TAG_member
                  DW_AT_name	("y")
                  DW_AT_data_member_location	(0x04)

0x00000045:     DW_TAG_member
                  DW_AT_name	("z")
                  DW_AT_data_member_location	(0x08)

0x00000050:     NULL
0x00000051:   NULL
"""

# readelf-format output: the SAME struct, DIFFERENT layout facts —
# Vector3D { x@0, y@8, z@16 }, byte_size 24.
const ReadelfStubPayload = """
 <0><b>: Abbrev Number: 1 (DW_TAG_compile_unit)
    <c>   DW_AT_name        : stub.c
 <1><26>: Abbrev Number: 2 (DW_TAG_structure_type)
    <27>   DW_AT_name        : Vector3D
    <2f>   DW_AT_byte_size   : 24
 <2><30>: Abbrev Number: 3 (DW_TAG_member)
    <31>   DW_AT_name        : x
    <33>   DW_AT_data_member_location: 0
 <2><3a>: Abbrev Number: 3 (DW_TAG_member)
    <3b>   DW_AT_name        : y
    <3d>   DW_AT_data_member_location: 8
 <2><45>: Abbrev Number: 3 (DW_TAG_member)
    <46>   DW_AT_name        : z
    <48>   DW_AT_data_member_location: 16
"""

proc main() =
  var falsifyIgnoreOffsetShift = false
  var positionalArgs: seq[string] = @[]

  for i in 1 .. paramCount():
    let arg = paramStr(i)
    if arg == "--falsify-ignore-offset-shift":
      falsifyIgnoreOffsetShift = true
    elif arg.startsWith("-"):
      stderr.writeLine("Unknown flag: " & arg)
      quit(1)
    else:
      positionalArgs.add(arg)

  if positionalArgs.len < 4:
    stderr.writeLine("Usage: test_hax_m1_driver [--falsify-ignore-offset-shift] <base_obj> <ctrl_obj> <mut_reorder_obj> <mut_shift_obj>")
    quit(1)

  let baseObj = positionalArgs[0]
  let ctrlObj = positionalArgs[1]
  let mutReorderObj = positionalArgs[2]
  let mutShiftObj = positionalArgs[3]

  for p in [baseObj, ctrlObj, mutReorderObj, mutShiftObj]:
    if not fileExists(p):
      stderr.writeLine("ERROR: Object file not found: " & p)
      quit(1)

  echo "=== HAX-M1: Pre-Flight Binary AST Type Layout Validation Integration Gate ==="

  let ambientHost = newDwarfToolHost(ambientDwarfRunner, ambientSearchPath())

  # ---------------------------------------------------------------------------
  # 1. Anti-Vacuity Arm: Verify exact offsets and member counts from real DWARF
  # ---------------------------------------------------------------------------
  echo "[1/6] Anti-Vacuity Arm: Parsing baseline DWARF and verifying member offsets..."
  let baseExtraction = extractTypeLayoutsFromObject(baseObj, ambientHost)
  let baseLayouts = baseExtraction.layouts
  if baseExtraction.resolution.toolName.len == 0:
    stderr.writeLine("ERROR: Anti-vacuity check failed: extraction recorded no resolved DWARF tool")
    quit(1)
  if baseExtraction.resolution.resolvedExecutablePath.len == 0:
    stderr.writeLine("ERROR: Anti-vacuity check failed: extraction recorded no resolved executable path")
    quit(1)
  if baseLayouts.len == 0:
    stderr.writeLine("ERROR: Anti-vacuity check failed: No composite type layouts extracted from " & baseObj)
    quit(1)

  var foundVector = false
  var foundBitFlags = false

  for layout in baseLayouts:
    if layout.name == "Vector3D":
      foundVector = true
      if layout.byteSize != 16:
        stderr.writeLine("ERROR: Vector3D byteSize expected 16, got " & $layout.byteSize)
        quit(1)
      if layout.members.len != 3:
        stderr.writeLine("ERROR: Vector3D member count expected 3, got " & $layout.members.len)
        quit(1)
      if layout.members.mapIt(it.typeName) != @["int", "int", "double"]:
        fail("Vector3D expected member types int, int, double, got " &
          $layout.members.mapIt(it.typeName))
      if layout.members[0].name != "x" or layout.members[0].offsetBytes != 0:
        stderr.writeLine("ERROR: Vector3D.x expected offset 0, got " & $layout.members[0].offsetBytes)
        quit(1)
      if layout.members[1].name != "y" or layout.members[1].offsetBytes != 4:
        stderr.writeLine("ERROR: Vector3D.y expected offset 4, got " & $layout.members[1].offsetBytes)
        quit(1)
      if layout.members[2].name != "z" or layout.members[2].offsetBytes != 8:
        stderr.writeLine("ERROR: Vector3D.z expected offset 8, got " & $layout.members[2].offsetBytes)
        quit(1)
    elif layout.name == "BitFlags":
      foundBitFlags = true
      if layout.members.len != 3:
        stderr.writeLine("ERROR: BitFlags member count expected 3, got " & $layout.members.len)
        quit(1)
      if layout.members[0].name != "mode" or layout.members[0].bitSize != 4:
        stderr.writeLine("ERROR: BitFlags.mode expected bitSize 4, got " & $layout.members[0].bitSize)
        quit(1)
      if layout.members[1].name != "state" or layout.members[1].bitSize != 4:
        stderr.writeLine("ERROR: BitFlags.state expected bitSize 4, got " & $layout.members[1].bitSize)
        quit(1)
      if layout.members[2].name != "tag" or layout.members[2].offsetBytes != 4:
        stderr.writeLine("ERROR: BitFlags.tag expected offset 4, got " & $layout.members[2].offsetBytes)
        quit(1)

  if not foundVector:
    stderr.writeLine("ERROR: Anti-vacuity check failed: Vector3D struct not found in baseline DWARF")
    quit(1)
  if not foundBitFlags:
    stderr.writeLine("ERROR: Anti-vacuity check failed: BitFlags struct not found in baseline DWARF")
    quit(1)

  echo "  [OK] Anti-vacuity verified: Vector3D has exact offsets (0, 4, 8) and size 16; BitFlags has bitfields and tag."

  # ---------------------------------------------------------------------------
  # 2. Control Arm: Identical struct layout with altered function logic
  # ---------------------------------------------------------------------------
  echo "[2/6] Control Arm: Validating identical struct layout with altered function logic..."
  let ctrlResult = validatePatchTypeCompatibility(baseObj, ctrlObj, ambientHost)
  if not ctrlResult.isCompatible:
    stderr.writeLine("ERROR: Control arm failed: Expected compatible result, got refusal: " & ctrlResult.refusalReason)
    quit(1)
  if ctrlResult.refusalReason.len > 0:
    stderr.writeLine("ERROR: Control arm failed: Unexpected refusal reason: " & ctrlResult.refusalReason)
    quit(1)
  for diff in ctrlResult.diffs:
    if diff.isRefusal:
      stderr.writeLine("ERROR: Control arm contained unexpected refusal diff: " & diff.reason)
      quit(1)
  echo "  [OK] Control arm passed cleanly: Identical type layout validated."

  # ---------------------------------------------------------------------------
  # 3. Refusal Arm A: Field reordering with member offset shift (x <-> y swapped)
  # ---------------------------------------------------------------------------
  echo "[3/6] Refusal Arm A: Validating refusal on struct field reordering / offset shift..."
  let reorderResult = validatePatchTypeCompatibility(baseObj, mutReorderObj, ambientHost,
    ignoreOffsetShift = falsifyIgnoreOffsetShift)

  if falsifyIgnoreOffsetShift:
    # Under falsifier mode: if the check was bypassed, the incompatible patch will be accepted!
    if reorderResult.isCompatible:
      stderr.writeLine("FALSIFIER-CAUGHT: Incompatible patch with field offset shift was incorrectly accepted!")
      quit(2)
    else:
      stderr.writeLine("ERROR: Expected falsifier to accept patch when offset shift validation is ignored, but was refused")
      quit(1)

  if reorderResult.isCompatible:
    stderr.writeLine("ERROR: Refusal arm A failed: Expected incompatible layout, but validation accepted the patch!")
    quit(1)

  if not reorderResult.refusalReason.contains("type-layout-incompatible"):
    stderr.writeLine("ERROR: Refusal arm A failed: Expected 'type-layout-incompatible' in refusal reason, got: " & reorderResult.refusalReason)
    quit(1)

  # Verify refusal details name struct, member, expected offset, and observed offset
  var foundMemberOffsetShift = false
  var foundFieldOrderReordered = false
  for diff in reorderResult.diffs:
    if diff.structName == "Vector3D":
      if diff.mutationKind == tmkIncompatibleMemberOffset:
        foundMemberOffsetShift = true
        if diff.memberName == "x":
          if diff.expectedOffset != 0 or diff.observedOffset != 4:
            stderr.writeLine("ERROR: Expected offset 0 and observed offset 4 for Vector3D.x, got exp=" & $diff.expectedOffset & ", obs=" & $diff.observedOffset)
            quit(1)
        elif diff.memberName == "y":
          if diff.expectedOffset != 4 or diff.observedOffset != 0:
            stderr.writeLine("ERROR: Expected offset 4 and observed offset 0 for Vector3D.y, got exp=" & $diff.expectedOffset & ", obs=" & $diff.observedOffset)
            quit(1)
      elif diff.mutationKind == tmkIncompatibleFieldOrder:
        foundFieldOrderReordered = true

  if not foundMemberOffsetShift:
    stderr.writeLine("ERROR: Refusal arm A failed: No tmkIncompatibleMemberOffset diff found for Vector3D")
    quit(1)
  if not foundFieldOrderReordered:
    stderr.writeLine("ERROR: Refusal arm A failed: No tmkIncompatibleFieldOrder diff found for Vector3D")
    quit(1)

  echo "  [OK] Refusal Arm A passed: Structured refusal 'type-layout-incompatible' emitted naming Vector3D, field shifts (x: 0->4, y: 4->0)."

  # ---------------------------------------------------------------------------
  # 4. Refusal Arm B: Field offset shift via padding insertion (y: 4->8, z: 8->16)
  # ---------------------------------------------------------------------------
  echo "[4/6] Refusal Arm B: Validating refusal on field offset shift and size change..."
  let shiftResult = validatePatchTypeCompatibility(baseObj, mutShiftObj, ambientHost)
  if shiftResult.isCompatible:
    stderr.writeLine("ERROR: Refusal arm B failed: Expected incompatible layout, but validation accepted the patch!")
    quit(1)

  if not shiftResult.refusalReason.contains("type-layout-incompatible"):
    stderr.writeLine("ERROR: Refusal arm B failed: Expected 'type-layout-incompatible' in refusal reason, got: " & shiftResult.refusalReason)
    quit(1)

  var foundShiftY = false
  var foundShiftZ = false
  var foundSizeChange = false
  for diff in shiftResult.diffs:
    if diff.structName == "Vector3D":
      if diff.mutationKind == tmkIncompatibleMemberOffset and diff.memberName == "y":
        foundShiftY = true
        if diff.expectedOffset != 4 or diff.observedOffset != 8:
          stderr.writeLine("ERROR: Vector3D.y offset shift expected exp=4, obs=8, got: " & $diff.expectedOffset & ", " & $diff.observedOffset)
          quit(1)
      elif diff.mutationKind == tmkIncompatibleMemberOffset and diff.memberName == "z":
        foundShiftZ = true
        if diff.expectedOffset != 8 or diff.observedOffset != 16:
          stderr.writeLine("ERROR: Vector3D.z offset shift expected exp=8, obs=16, got: " & $diff.expectedOffset & ", " & $diff.observedOffset)
          quit(1)
      elif diff.mutationKind == tmkIncompatibleSize:
        foundSizeChange = true
        if diff.expectedSize != 16 or diff.observedSize != 24:
          stderr.writeLine("ERROR: Vector3D size change expected exp=16, obs=24, got: " & $diff.expectedSize & ", " & $diff.observedSize)
          quit(1)

  if not foundShiftY:
    stderr.writeLine("ERROR: Refusal arm B failed: Expected offset shift for member 'y'")
    quit(1)
  if not foundShiftZ:
    stderr.writeLine("ERROR: Refusal arm B failed: Expected offset shift for member 'z'")
    quit(1)
  if not foundSizeChange:
    stderr.writeLine("ERROR: Refusal arm B failed: Expected struct size change for Vector3D")
    quit(1)

  echo "  [OK] Refusal Arm B passed: Caught shifted offsets (y: 4->8, z: 8->16) and size mutation (16->24)."

  # ---------------------------------------------------------------------------
  # 5. Class-2 Recording Arm: which dumper ran must be RECORDED, not discarded
  #
  # The four configured candidates do not emit the same DWARF text. Two hosts
  # carrying different subsets therefore extract different type layouts from
  # the SAME object file. Package-Model class 2 makes that survivable only by
  # requiring the resolution to enter the identity: "the resulting action
  # identity records the search path, the resolved executable path, and
  # configured probes". This arm pins exactly that.
  #
  # Two single-tool search paths are built, each carrying ONE canned dumper.
  # Same object file, same argv shape, different tool => different layouts AND
  # a different recorded identity that names the tool that actually ran.
  # ---------------------------------------------------------------------------
  echo "[5/6] Class-2 Recording Arm: verifying the DWARF-tool resolution is recorded..."

  let scratch = getTempDir() / "repro-hax-m1-class2-" & $getCurrentProcessId()
  removeDir(scratch)
  let dirDwarfdump = scratch / "only-dwarfdump"
  let dirReadelf = scratch / "only-readelf"
  writeStubDumper(dirDwarfdump, "dwarfdump", DwarfdumpStubPayload)
  writeStubDumper(dirReadelf, "readelf", ReadelfStubPayload)
  defer: removeDir(scratch)

  let hostDwarfdump = newDwarfToolHost(ambientDwarfRunner, [dirDwarfdump])
  let hostReadelf = newDwarfToolHost(ambientDwarfRunner, [dirReadelf])

  let viaDwarfdump = extractTypeLayoutsFromObject(baseObj, hostDwarfdump)
  let viaReadelf = extractTypeLayoutsFromObject(baseObj, hostReadelf)

  # -- 5a. The hazard is real: same object, different tool, different facts.
  proc vector3D(layouts: seq[CompositeTypeLayout]): CompositeTypeLayout =
    for layout in layouts:
      if layout.name == "Vector3D":
        return layout
    fail("Class-2 arm: Vector3D not found in extracted layouts")

  let layoutA = vector3D(viaDwarfdump.layouts)
  let layoutB = vector3D(viaReadelf.layouts)
  if layoutA.byteSize != 16:
    fail("Class-2 arm: dwarfdump arm expected Vector3D byteSize 16, got " & $layoutA.byteSize)
  if layoutB.byteSize != 24:
    fail("Class-2 arm: readelf arm expected Vector3D byteSize 24, got " & $layoutB.byteSize)
  if layoutA.members.len != 3 or layoutB.members.len != 3:
    fail("Class-2 arm: expected 3 members in both arms, got " &
      $layoutA.members.len & " and " & $layoutB.members.len)
  if layoutA.members[2].offsetBytes != 8:
    fail("Class-2 arm: dwarfdump arm expected Vector3D.z at 8, got " & $layoutA.members[2].offsetBytes)
  if layoutB.members[2].offsetBytes != 16:
    fail("Class-2 arm: readelf arm expected Vector3D.z at 16, got " & $layoutB.members[2].offsetBytes)

  # -- 5b. The winning tool, its resolved path, and the walked search path are
  #        all recorded — each asserted against a SPECIFIC expected value, not
  #        merely "the two records differ" (an all-empty record would pass
  #        that).
  let resA = viaDwarfdump.resolution
  let resB = viaReadelf.resolution

  if resA.toolName != "dwarfdump":
    fail("Class-2 arm: expected recorded toolName 'dwarfdump', got '" & resA.toolName & "'")
  if resB.toolName != "readelf":
    fail("Class-2 arm: expected recorded toolName 'readelf', got '" & resB.toolName & "'")
  if resA.resolvedExecutablePath != dirDwarfdump / "dwarfdump":
    fail("Class-2 arm: expected recorded resolvedExecutablePath '" &
      (dirDwarfdump / "dwarfdump") & "', got '" & resA.resolvedExecutablePath & "'")
  if resB.resolvedExecutablePath != dirReadelf / "readelf":
    fail("Class-2 arm: expected recorded resolvedExecutablePath '" &
      (dirReadelf / "readelf") & "', got '" & resB.resolvedExecutablePath & "'")
  if resA.searchPath != @[dirDwarfdump]:
    fail("Class-2 arm: expected recorded searchPath @[" & dirDwarfdump &
      "], got " & $resA.searchPath)
  if resB.searchPath != @[dirReadelf]:
    fail("Class-2 arm: expected recorded searchPath @[" & dirReadelf &
      "], got " & $resB.searchPath)
  if resA.argv.len != 3 or resA.argv[0] != dirDwarfdump / "dwarfdump" or
      resA.argv[1] != "--debug-info" or resA.argv[2] != baseObj:
    fail("Class-2 arm: expected recorded argv [<resolved dwarfdump>, --debug-info, " &
      baseObj & "], got " & $resA.argv)
  if resB.argv.len != 3 or resB.argv[0] != dirReadelf / "readelf" or
      resB.argv[1] != "--debug-dump=info" or resB.argv[2] != baseObj:
    fail("Class-2 arm: expected recorded argv [<resolved readelf>, --debug-dump=info, " &
      baseObj & "], got " & $resB.argv)

  # -- 5c. EVERY configured probe is recorded, in order — including the three
  #        candidates the readelf-only search path did not carry. "This host
  #        had no llvm-dwarfdump" is precisely the fact that makes two hosts
  #        disagree, so dropping it would leave the record unable to explain
  #        the divergence.
  let expectedCandidates = @["dwarfdump", "llvm-dwarfdump", "objdump", "readelf"]
  for (label, res) in [("dwarfdump-only", resA), ("readelf-only", resB)]:
    if res.probes.len != expectedCandidates.len:
      fail("Class-2 arm (" & label & "): expected " & $expectedCandidates.len &
        " recorded probes, got " & $res.probes.len)
    for i, expected in expectedCandidates:
      if res.probes[i].binName != expected:
        fail("Class-2 arm (" & label & "): probe " & $i & " expected '" &
          expected & "', got '" & res.probes[i].binName & "'")
  if not resA.probes[0].accepted:
    fail("Class-2 arm: dwarfdump probe should be recorded as accepted")
  for i in 0 .. 2:
    if resB.probes[i].resolvedPath.len != 0:
      fail("Class-2 arm: probe " & $i & " (" & resB.probes[i].binName &
        ") should record an EMPTY resolvedPath on the readelf-only search path, got '" &
        resB.probes[i].resolvedPath & "'")
    if resB.probes[i].attempted:
      fail("Class-2 arm: probe " & $i & " (" & resB.probes[i].binName &
        ") should not be recorded as attempted on the readelf-only search path")
  if not resB.probes[3].accepted:
    fail("Class-2 arm: readelf probe should be recorded as accepted")

  # -- 5d. The identity key the action owner folds in differs, and each half
  #        names its own tool, its own resolved path, and its own search path.
  let identityA = dwarfToolIdentity(resA)
  let identityB = dwarfToolIdentity(resB)
  requireContains(identityA, "tool:dwarfdump", "identity (dwarfdump-only)")
  requireContains(identityA, "resolved:" & dirDwarfdump / "dwarfdump", "identity (dwarfdump-only)")
  requireContains(identityA, "search-path:" & dirDwarfdump, "identity (dwarfdump-only)")
  requireContains(identityA, "argv:--debug-info", "identity (dwarfdump-only)")
  requireContains(identityB, "tool:readelf", "identity (readelf-only)")
  requireContains(identityB, "resolved:" & dirReadelf / "readelf", "identity (readelf-only)")
  requireContains(identityB, "search-path:" & dirReadelf, "identity (readelf-only)")
  requireContains(identityB, "argv:--debug-dump=info", "identity (readelf-only)")
  if identityA == identityB:
    fail("Class-2 arm: two different resolved tools produced the SAME identity — " &
      "the resolution is not entering the identity")
  if identityA.contains(dirReadelf / "readelf") or identityB.contains(dirDwarfdump / "dwarfdump"):
    fail("Class-2 arm: an identity names a tool that did not run")

  # -- 5e. The identity travels on the validation result, which is what the
  #        HCR coordinator (Patch-Loading-Lifecycle Phase C) caches its verdict
  #        under.
  let validatedA = validatePatchTypeCompatibility(baseObj, baseObj, hostDwarfdump)
  let validatedB = validatePatchTypeCompatibility(baseObj, baseObj, hostReadelf)
  if validatedA.toolResolutions.len != 2 or validatedB.toolResolutions.len != 2:
    fail("Class-2 arm: validation result must carry one resolution per compared object")
  requireContains(validatedA.toolIdentity, "tool:dwarfdump", "validation identity (dwarfdump-only)")
  requireContains(validatedB.toolIdentity, "tool:readelf", "validation identity (readelf-only)")
  if validatedA.toolIdentity == validatedB.toolIdentity:
    fail("Class-2 arm: validation identity does not distinguish the resolved tool")

  echo "  [OK] Class-2 Recording Arm passed: resolution recorded (search path, " &
    "resolved executable, 4 configured probes) and the identity names the tool that ran."

  # ---------------------------------------------------------------------------
  # 6. Summary
  # ---------------------------------------------------------------------------
  echo "[6/6] All arms completed successfully."
  echo "=== Gate PASSED: Pre-Flight Binary AST Type Layout Validation ==="

when isMainModule:
  main()
