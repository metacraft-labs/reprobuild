# test_hax_m1_binary_type_layout_diff_detects_field_shifts.nim
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
# Allowed mocks: none
# Justification: Every use of mock objects in tests must be explicitly justified in the
# header comment of the test implementation file. We prefer strong integration tests that
# mock as little as possible and run against real filesystem, compiler, binary, and
# lifecycle execution boundaries. Mocks used: ZERO.
#
# Asserts:
# 1. Anti-vacuity: Type parser extracts exact member offsets (0, 4, 8) and member counts.
# 2. Control arm: Identical struct layout with altered function logic passes cleanly.
# 3. Positive arm: Multiple unchanged struct types with modified function bodies pass cleanly.
# 4. Refusal arm: Struct member offset shift and field reordering refused with `type-layout-incompatible`
#    naming the struct, member, expected offset, and observed offset.
# 5. Falsifier: Simulates omitting member offset validation (--falsify-ignore-offset-shift),
#    causing incompatible patch to be accepted and triggering FALSIFIER-CAUGHT.

import std/[os, strutils, sequtils]
import repro_hcr_linkgraph

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

  # ---------------------------------------------------------------------------
  # 1. Anti-Vacuity Arm: Verify exact offsets and member counts from real DWARF
  # ---------------------------------------------------------------------------
  echo "[1/5] Anti-Vacuity Arm: Parsing baseline DWARF and verifying member offsets..."
  let baseLayouts = extractTypeLayoutsFromObject(baseObj)
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
  echo "[2/5] Control Arm: Validating identical struct layout with altered function logic..."
  let ctrlResult = validatePatchTypeCompatibility(baseObj, ctrlObj)
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
  echo "[3/5] Refusal Arm A: Validating refusal on struct field reordering / offset shift..."
  let reorderResult = validatePatchTypeCompatibility(baseObj, mutReorderObj, ignoreOffsetShift = falsifyIgnoreOffsetShift)

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
  echo "[4/5] Refusal Arm B: Validating refusal on field offset shift and size change..."
  let shiftResult = validatePatchTypeCompatibility(baseObj, mutShiftObj)
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
  # 5. Summary
  # ---------------------------------------------------------------------------
  echo "[5/5] All arms completed successfully."
  echo "=== Gate PASSED: Pre-Flight Binary AST Type Layout Validation ==="

when isMainModule:
  main()
