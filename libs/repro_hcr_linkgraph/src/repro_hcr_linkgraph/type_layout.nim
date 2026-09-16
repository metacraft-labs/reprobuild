# type_layout.nim
#
# Pre-Flight Binary AST Type Layout Validation for Reprobuild HCR (HAX-M1)
#
# Design doc: reprobuild-specs/HCR/Patch-Loading-Lifecycle.md §3
#             reprobuild-specs/HCR/Binary-Diffing-And-Symbol-Resolution.md §4
# Related milestones:
# - reprobuild-specs/HCR-Advanced-Lifecycle-And-Tooling.milestones.org (HAX-M1)

import std/[os, osproc, strutils, sequtils, tables, sets]

type
  CompositeTypeKind* = enum
    ctkStruct
    ctkUnion
    ctkClass

  TypeMemberFact* = object
    name*: string
    typeName*: string
    offsetBytes*: int64
    bitSize*: int64
    bitOffset*: int64

  CompositeTypeLayout* = object
    name*: string
    kind*: CompositeTypeKind
    byteSize*: int64
    alignment*: int64
    members*: seq[TypeMemberFact]
    isExported*: bool

  TypeMutationKind* = enum
    tmkCompatibleUnchanged
    tmkCompatibleInternal
    tmkIncompatibleSize
    tmkIncompatibleMemberOffset
    tmkIncompatibleMemberType
    tmkIncompatibleFieldOrder
    tmkIncompatibleMemberAdded
    tmkIncompatibleMemberRemoved

  TypeDiffFact* = object
    structName*: string
    mutationKind*: TypeMutationKind
    memberName*: string
    expectedOffset*: int64
    observedOffset*: int64
    expectedSize*: int64
    observedSize*: int64
    isRefusal*: bool
    reason*: string

  TypeLayoutValidationResult* = object
    isCompatible*: bool
    refusalReason*: string
    diffs*: seq[TypeDiffFact]

type
  DieNode = ref object
    offset: int64
    tag: string
    indent: int
    attrs: Table[string, string]
    children: seq[DieNode]
    parent: DieNode

proc parseDwarfInt(s: string): int64 =
  var clean = s.strip()
  if clean.startsWith("(") and clean.endsWith(")"):
    clean = clean[1 .. ^2].strip()
  if clean.startsWith("DW_OP_plus_uconst"):
    clean = clean["DW_OP_plus_uconst".len .. ^1].strip()
  elif clean.startsWith("DW_OP_constu"):
    clean = clean["DW_OP_constu".len .. ^1].strip()
  clean = clean.strip()
  if clean.startsWith("0x") or clean.startsWith("0X"):
    try:
      return parseHexInt(clean)
    except ValueError:
      return 0
  else:
    try:
      return parseBiggestInt(clean)
    except ValueError:
      return 0

proc unquote(s: string): string =
  var clean = s.strip()
  let q1 = clean.find('"')
  if q1 >= 0:
    let q2 = clean.find('"', q1 + 1)
    if q2 > q1:
      return clean[q1 + 1 ..< q2]
  if clean.startsWith("(") and clean.endsWith(")"):
    clean = clean[1 .. ^2].strip()
  return clean

proc parseDieTree(dwarfOutput: string): seq[DieNode] =
  var dies: seq[DieNode] = @[]
  var currentDie: DieNode = nil
  var stack: seq[DieNode] = @[]

  for rawLine in dwarfOutput.splitLines():
    let line = rawLine.strip(trailing = true)
    if line.len == 0:
      continue

    # 1. Check for dwarfdump format:
    # 0x00000047:   DW_TAG_structure_type
    # or 0x0000007f:     NULL
    let colPos = line.find(':')
    if colPos > 0 and (line.startsWith("0x") or line.startsWith("0X")):
      let offsetStr = line[0 ..< colPos].strip()
      var offsetVal: int64 = 0
      var isDieHeader = false
      try:
        offsetVal = parseHexInt(offsetStr)
        isDieHeader = true
      except ValueError:
        isDieHeader = false

      if isDieHeader:
        let afterCol = line[colPos + 1 .. ^1]
        let tagPos = afterCol.find("DW_TAG_")
        let nullPos = afterCol.find("NULL")
        if tagPos >= 0 or nullPos >= 0:
          var tag = ""
          var indent = 0
          if tagPos >= 0:
            indent = tagPos
            var endPos = tagPos
            while endPos < afterCol.len and (afterCol[endPos].isAlphaNumeric or afterCol[endPos] == '_'):
              inc endPos
            tag = afterCol[tagPos ..< endPos]
          else:
            indent = nullPos
            tag = "NULL"

          let die = DieNode(
            offset: offsetVal,
            tag: tag,
            indent: indent,
            attrs: initTable[string, string](),
            children: @[],
            parent: nil
          )
          dies.add(die)
          currentDie = die

          if tag == "NULL":
            if stack.len > 0:
              discard stack.pop()
            continue

          while stack.len > 0 and die.indent <= stack[^1].indent:
            discard stack.pop()
          if stack.len > 0:
            stack[^1].children.add(die)
            die.parent = stack[^1]
          stack.add(die)
          continue

    # 2. Check for readelf / objdump format:
    #  <1><47>: Abbrev Number: 2 (DW_TAG_structure_type)
    #  <2><4f>: Abbrev Number: 3 (DW_TAG_member)
    let trimmed = line.strip(leading = true)
    if trimmed.startsWith("<"):
      let end1 = trimmed.find('>')
      if end1 > 1:
        let start2 = trimmed.find('<', end1 + 1)
        let end2 = trimmed.find('>', start2 + 1)
        if start2 > 0 and end2 > start2:
          let levelStr = trimmed[1 ..< end1]
          let offsetStr = trimmed[start2 + 1 ..< end2]
          var levelVal = 0
          var offsetVal: int64 = 0
          var isReadelfHeader = false
          try:
            levelVal = parseInt(levelStr)
            offsetVal = parseHexInt(offsetStr)
            isReadelfHeader = true
          except ValueError:
            isReadelfHeader = false

          if isReadelfHeader:
            var tag = ""
            let tagPos = trimmed.find("DW_TAG_")
            if tagPos >= 0:
              var endPos = tagPos
              while endPos < trimmed.len and (trimmed[endPos].isAlphaNumeric or trimmed[endPos] == '_'):
                inc endPos
              tag = trimmed[tagPos ..< endPos]
            elif trimmed.contains("NULL"):
              tag = "NULL"

            if tag.len > 0:
              let indent = levelVal * 2
              let die = DieNode(
                offset: offsetVal,
                tag: tag,
                indent: indent,
                attrs: initTable[string, string](),
                children: @[],
                parent: nil
              )
              dies.add(die)
              currentDie = die

              if tag == "NULL":
                if stack.len > 0:
                  discard stack.pop()
                continue

              while stack.len > 0 and die.indent <= stack[^1].indent:
                discard stack.pop()
              if stack.len > 0:
                stack[^1].children.add(die)
                die.parent = stack[^1]
              stack.add(die)
              continue

    # 3. Check for attribute line:
    if currentDie != nil:
      let atPos = line.find("DW_AT_")
      if atPos >= 0:
        var nameEnd = atPos
        while nameEnd < line.len and (line[nameEnd].isAlphaNumeric or line[nameEnd] == '_'):
          inc nameEnd
        let attrName = line[atPos ..< nameEnd]
        var rest = line[nameEnd .. ^1].strip()
        if rest.startsWith(":") or rest.startsWith("\t"):
          rest = rest[1 .. ^1].strip()
        currentDie.attrs[attrName] = rest

  return dies

proc extractTypeLayoutsFromDwarf*(dwarfOutput: string): seq[CompositeTypeLayout] =
  let dies = parseDieTree(dwarfOutput)

  # Pass 1: Build type name map & typedef aliases
  var typeMap = initTable[int64, string]()
  var typedefTarget = initTable[int64, int64]()
  var targetToTypedefName = initTable[int64, string]()

  for die in dies:
    case die.tag
    of "DW_TAG_base_type", "DW_TAG_structure_type", "DW_TAG_union_type", "DW_TAG_class_type", "DW_TAG_enumeration_type":
      if die.attrs.hasKey("DW_AT_name"):
        typeMap[die.offset] = unquote(die.attrs["DW_AT_name"])
    of "DW_TAG_typedef":
      if die.attrs.hasKey("DW_AT_name"):
        let tName = unquote(die.attrs["DW_AT_name"])
        typeMap[die.offset] = tName
        if die.attrs.hasKey("DW_AT_type"):
          let rawType = die.attrs["DW_AT_type"]
          let targetOff = parseDwarfInt(rawType)
          if targetOff > 0:
            typedefTarget[die.offset] = targetOff
            targetToTypedefName[targetOff] = tName
    of "DW_TAG_pointer_type":
      if die.attrs.hasKey("DW_AT_type"):
        let rawType = die.attrs["DW_AT_type"]
        let targetOff = parseDwarfInt(rawType)
        if targetOff > 0 and targetOff in typeMap:
          typeMap[die.offset] = typeMap[targetOff] & " *"
        else:
          let q = unquote(rawType)
          if q.len > 0 and q != rawType:
            typeMap[die.offset] = q
          else:
            typeMap[die.offset] = "void *"
      else:
        typeMap[die.offset] = "void *"
    else:
      discard

  # Pass 2: Extract composite types
  var layouts: seq[CompositeTypeLayout] = @[]
  var seenNames = initHashSet[string]()

  for die in dies:
    if die.tag in ["DW_TAG_structure_type", "DW_TAG_union_type", "DW_TAG_class_type"]:
      let isDecl = die.attrs.getOrDefault("DW_AT_declaration").contains("true") or
                   die.attrs.getOrDefault("DW_AT_declaration").contains("1")
      let hasByteSize = die.attrs.hasKey("DW_AT_byte_size")
      if isDecl and not hasByteSize and die.children.len == 0:
        continue

      let kind = case die.tag
        of "DW_TAG_structure_type": ctkStruct
        of "DW_TAG_union_type": ctkUnion
        of "DW_TAG_class_type": ctkClass
        else: ctkStruct

      var name = ""
      if die.attrs.hasKey("DW_AT_name"):
        name = unquote(die.attrs["DW_AT_name"])
      elif die.offset in targetToTypedefName:
        name = targetToTypedefName[die.offset]

      let byteSize = if hasByteSize: parseDwarfInt(die.attrs["DW_AT_byte_size"]) else: 0'i64
      let alignment = if die.attrs.hasKey("DW_AT_alignment"): parseDwarfInt(die.attrs["DW_AT_alignment"]) else: 0'i64

      var isExported = false
      if name.len > 0 and not name.startsWith("(anon") and not name.startsWith("__anon") and not name.startsWith("_GLOBAL__"):
        isExported = true
      if die.attrs.hasKey("DW_AT_external"):
        let ext = die.attrs["DW_AT_external"]
        isExported = ext.contains("true") or ext.contains("1")

      var members: seq[TypeMemberFact] = @[]
      for ch in die.children:
        if ch.tag == "DW_TAG_member":
          let chDecl = ch.attrs.getOrDefault("DW_AT_declaration").contains("true") or
                       ch.attrs.getOrDefault("DW_AT_declaration").contains("1")
          if chDecl and not ch.attrs.hasKey("DW_AT_data_member_location"):
            continue

          let mName = if ch.attrs.hasKey("DW_AT_name"): unquote(ch.attrs["DW_AT_name"]) else: ""

          var mTypeName = ""
          if ch.attrs.hasKey("DW_AT_type"):
            let rawType = ch.attrs["DW_AT_type"]
            let q = unquote(rawType)
            if q.len > 0 and q != rawType:
              mTypeName = q
            else:
              let typeOff = parseDwarfInt(rawType)
              if typeOff in typeMap:
                mTypeName = typeMap[typeOff]
              else:
                mTypeName = rawType
          else:
            mTypeName = "unknown"

          var offsetBytes: int64 = 0
          var bitSize: int64 = 0
          var bitOffset: int64 = 0

          if ch.attrs.hasKey("DW_AT_bit_size"):
            bitSize = parseDwarfInt(ch.attrs["DW_AT_bit_size"])

          if ch.attrs.hasKey("DW_AT_data_bit_offset"):
            let totalBitOff = parseDwarfInt(ch.attrs["DW_AT_data_bit_offset"])
            offsetBytes = totalBitOff div 8
            bitOffset = totalBitOff mod 8
          elif ch.attrs.hasKey("DW_AT_bit_offset"):
            bitOffset = parseDwarfInt(ch.attrs["DW_AT_bit_offset"])
            if ch.attrs.hasKey("DW_AT_data_member_location"):
              offsetBytes = parseDwarfInt(ch.attrs["DW_AT_data_member_location"])
          elif ch.attrs.hasKey("DW_AT_data_member_location"):
            offsetBytes = parseDwarfInt(ch.attrs["DW_AT_data_member_location"])

          members.add(TypeMemberFact(
            name: mName,
            typeName: mTypeName,
            offsetBytes: offsetBytes,
            bitSize: bitSize,
            bitOffset: bitOffset
          ))

      let layout = CompositeTypeLayout(
        name: name,
        kind: kind,
        byteSize: byteSize,
        alignment: alignment,
        members: members,
        isExported: isExported
      )

      if name.len > 0:
        if name in seenNames:
          for i in 0 ..< layouts.len:
            if layouts[i].name == name:
              if layouts[i].members.len == 0 and members.len > 0:
                layouts[i] = layout
              break
        else:
          seenNames.incl(name)
          layouts.add(layout)
      else:
        layouts.add(layout)

  return layouts

proc runDwarfDump(objectPath: string): string =
  if not fileExists(objectPath):
    raise newException(IOError, "Object file does not exist: " & objectPath)

  type CandidateTool = tuple[binName: string, args: seq[string]]
  let candidates: seq[CandidateTool] = @[
    ("dwarfdump", @["--debug-info", objectPath]),
    ("llvm-dwarfdump", @["--debug-info", objectPath]),
    ("objdump", @["--dwarf=info", objectPath]),
    ("readelf", @["--debug-dump=info", objectPath])
  ]

  var errors: seq[string] = @[]
  for (binName, args) in candidates:
    let exePath = findExe(binName)
    if exePath.len > 0:
      try:
        let cmd = quoteShell(exePath) & (if args.len > 0: " " & args.map(quoteShell).join(" ") else: "")
        let res = execCmdEx(cmd)
        if res.exitCode == 0 and res.output.len > 0:
          return res.output
        else:
          errors.add(binName & " exited with code " & $res.exitCode)
      except CatchableError as e:
        errors.add(binName & " error: " & e.msg)

  raise newException(IOError, "Failed to dump DWARF debug info from '" & objectPath & "'. Attempts: " & errors.join("; "))

proc extractTypeLayoutsFromObject*(objectPath: string): seq[CompositeTypeLayout] =
  let output = runDwarfDump(objectPath)
  extractTypeLayoutsFromDwarf(output)

proc diffTypeLayouts*(baseline: seq[CompositeTypeLayout],
                      candidate: seq[CompositeTypeLayout],
                      ignoreOffsetShift: bool = false): TypeLayoutValidationResult =
  var diffs: seq[TypeDiffFact] = @[]
  var baseMap = initTable[string, CompositeTypeLayout]()
  var candMap = initTable[string, CompositeTypeLayout]()

  for b in baseline:
    if b.name.len > 0:
      baseMap[b.name] = b
  for c in candidate:
    if c.name.len > 0:
      candMap[c.name] = c

  for name, b in baseMap:
    if name notin candMap:
      continue

    let c = candMap[name]
    var structDiffs: seq[TypeDiffFact] = @[]

    # Check kind change
    if b.kind != c.kind:
      let diff = TypeDiffFact(
        structName: b.name,
        mutationKind: tmkIncompatibleMemberType,
        memberName: "",
        expectedOffset: 0,
        observedOffset: 0,
        expectedSize: b.byteSize,
        observedSize: c.byteSize,
        isRefusal: b.isExported,
        reason: "type-layout-incompatible: struct '" & b.name & "' kind changed from " & $b.kind & " to " & $c.kind
      )
      structDiffs.add(diff)

    # Check byte size change
    if b.byteSize != c.byteSize:
      let isRef = b.isExported
      let diff = TypeDiffFact(
        structName: b.name,
        mutationKind: (if b.isExported: tmkIncompatibleSize else: tmkCompatibleInternal),
        memberName: "",
        expectedOffset: 0,
        observedOffset: 0,
        expectedSize: b.byteSize,
        observedSize: c.byteSize,
        isRefusal: isRef,
        reason: (if b.isExported:
                   "type-layout-incompatible: struct '" & b.name & "' size changed from " & $b.byteSize & " to " & $c.byteSize
                 else:
                   "internal type struct '" & b.name & "' size changed from " & $b.byteSize & " to " & $c.byteSize)
      )
      structDiffs.add(diff)

    # Check field order
    var bMemberNames: seq[string] = @[]
    for m in b.members: bMemberNames.add(m.name)
    var cMemberNames: seq[string] = @[]
    for m in c.members: cMemberNames.add(m.name)

    let commonInBase = bMemberNames.filter(proc(n: string): bool = n in cMemberNames)
    let commonInCand = cMemberNames.filter(proc(n: string): bool = n in bMemberNames)
    if commonInBase != commonInCand:
      let isRef = b.isExported and not ignoreOffsetShift
      let diff = TypeDiffFact(
        structName: b.name,
        mutationKind: (if b.isExported: tmkIncompatibleFieldOrder else: tmkCompatibleInternal),
        memberName: "",
        expectedOffset: 0,
        observedOffset: 0,
        expectedSize: b.byteSize,
        observedSize: c.byteSize,
        isRefusal: isRef,
        reason: "type-layout-incompatible: struct '" & b.name & "' field order reordered"
      )
      structDiffs.add(diff)

    # Member comparison maps
    var bMembers = initTable[string, TypeMemberFact]()
    for m in b.members: bMembers[m.name] = m
    var cMembers = initTable[string, TypeMemberFact]()
    for m in c.members: cMembers[m.name] = m

    # Removed members
    for m in b.members:
      if m.name notin cMembers:
        let isRef = b.isExported
        let diff = TypeDiffFact(
          structName: b.name,
          mutationKind: (if b.isExported: tmkIncompatibleMemberRemoved else: tmkCompatibleInternal),
          memberName: m.name,
          expectedOffset: m.offsetBytes,
          observedOffset: -1,
          expectedSize: b.byteSize,
          observedSize: c.byteSize,
          isRefusal: isRef,
          reason: "type-layout-incompatible: struct '" & b.name & "' member '" & m.name & "' was removed"
        )
        structDiffs.add(diff)

    # Added members
    for m in c.members:
      if m.name notin bMembers:
        let isRef = b.isExported
        let diff = TypeDiffFact(
          structName: b.name,
          mutationKind: (if b.isExported: tmkIncompatibleMemberAdded else: tmkCompatibleInternal),
          memberName: m.name,
          expectedOffset: -1,
          observedOffset: m.offsetBytes,
          expectedSize: b.byteSize,
          observedSize: c.byteSize,
          isRefusal: isRef,
          reason: "type-layout-incompatible: struct '" & b.name & "' member '" & m.name & "' was added"
        )
        structDiffs.add(diff)

    # Common members
    for mBase in b.members:
      if mBase.name in cMembers:
        let mCand = cMembers[mBase.name]

        # Offset shift
        if mBase.offsetBytes != mCand.offsetBytes or mBase.bitOffset != mCand.bitOffset:
          let isRef = b.isExported and not ignoreOffsetShift
          let diff = TypeDiffFact(
            structName: b.name,
            mutationKind: (if b.isExported: tmkIncompatibleMemberOffset else: tmkCompatibleInternal),
            memberName: mBase.name,
            expectedOffset: mBase.offsetBytes,
            observedOffset: mCand.offsetBytes,
            expectedSize: b.byteSize,
            observedSize: c.byteSize,
            isRefusal: isRef,
            reason: "type-layout-incompatible: struct '" & b.name & "' member '" & mBase.name &
                    "' offset shifted from " & $mBase.offsetBytes & " to " & $mCand.offsetBytes &
                    " (expected offset: " & $mBase.offsetBytes & ", observed offset: " & $mCand.offsetBytes & ")"
          )
          structDiffs.add(diff)

        # Bit size change
        if mBase.bitSize != mCand.bitSize:
          let isRef = b.isExported and not ignoreOffsetShift
          let diff = TypeDiffFact(
            structName: b.name,
            mutationKind: (if b.isExported: tmkIncompatibleMemberOffset else: tmkCompatibleInternal),
            memberName: mBase.name,
            expectedOffset: mBase.offsetBytes,
            observedOffset: mCand.offsetBytes,
            expectedSize: b.byteSize,
            observedSize: c.byteSize,
            isRefusal: isRef,
            reason: "type-layout-incompatible: struct '" & b.name & "' bitfield '" & mBase.name &
                    "' bit size changed from " & $mBase.bitSize & " to " & $mCand.bitSize
          )
          structDiffs.add(diff)

        # Type change
        if mBase.typeName.len > 0 and mCand.typeName.len > 0 and mBase.typeName != mCand.typeName:
          let isRef = b.isExported
          let diff = TypeDiffFact(
            structName: b.name,
            mutationKind: (if b.isExported: tmkIncompatibleMemberType else: tmkCompatibleInternal),
            memberName: mBase.name,
            expectedOffset: mBase.offsetBytes,
            observedOffset: mCand.offsetBytes,
            expectedSize: b.byteSize,
            observedSize: c.byteSize,
            isRefusal: isRef,
            reason: "type-layout-incompatible: struct '" & b.name & "' member '" & mBase.name &
                    "' type changed from '" & mBase.typeName & "' to '" & mCand.typeName & "'"
          )
          structDiffs.add(diff)

    if structDiffs.len == 0:
      diffs.add(TypeDiffFact(
        structName: b.name,
        mutationKind: tmkCompatibleUnchanged,
        memberName: "",
        expectedOffset: 0,
        observedOffset: 0,
        expectedSize: b.byteSize,
        observedSize: c.byteSize,
        isRefusal: false,
        reason: "struct '" & b.name & "' layout unchanged"
      ))
    else:
      for d in structDiffs:
        diffs.add(d)

  var isCompatible = true
  var refusalReasons: seq[string] = @[]
  for d in diffs:
    if d.isRefusal:
      isCompatible = false
      refusalReasons.add(d.reason)

  let refusalReason = if refusalReasons.len > 0: refusalReasons.join("; ") else: ""

  return TypeLayoutValidationResult(
    isCompatible: isCompatible,
    refusalReason: refusalReason,
    diffs: diffs
  )

proc validatePatchTypeCompatibility*(baselineObjectPath, candidateObjectPath: string,
                                     ignoreOffsetShift: bool = false): TypeLayoutValidationResult =
  let baselineLayouts = extractTypeLayoutsFromObject(baselineObjectPath)
  let candidateLayouts = extractTypeLayoutsFromObject(candidateObjectPath)
  return diffTypeLayouts(baselineLayouts, candidateLayouts, ignoreOffsetShift)
