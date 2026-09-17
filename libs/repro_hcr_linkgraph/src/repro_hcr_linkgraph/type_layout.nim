# type_layout.nim
#
# Pre-Flight Binary AST Type Layout Validation for Reprobuild HCR (HAX-M1)
#
# Design doc: reprobuild-specs/HCR/Patch-Loading-Lifecycle.md §3
#             reprobuild-specs/HCR/Binary-Diffing-And-Symbol-Resolution.md §4
# Related milestones:
# - reprobuild-specs/HCR-Advanced-Lifecycle-And-Tooling.milestones.org (HAX-M1)

import std/[os, strutils, sequtils, tables, sets]

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

  DwarfToolProbe* = object
    ## One CONFIGURED probe of the DWARF-dumper plan, together with what the
    ## resolution actually observed for it. Every configured candidate gets a
    ## row — including the ones the search path did not carry (``resolvedPath``
    ## empty, ``attempted`` false) — because "the tool was not installed here"
    ## is exactly the fact that makes two hosts disagree.
    binName*: string
    args*: seq[string]
    resolvedPath*: string
      ## Absolute path the search-path walk produced, or ``""`` when no
      ## directory on the search path carried this candidate.
    attempted*: bool
      ## True when the probe was actually executed.
    exitCode*: int
      ## Meaningful only when ``attempted``; ``-1`` when the run itself raised.
    outputBytes*: int
      ## Size of the captured stdout. Zero output is a rejection even at
      ## exit code 0, which is the existing loop's behaviour.
    accepted*: bool
      ## True for the single probe whose output was used.
    diagnostic*: string
      ## Non-empty when the probe was executed and rejected.

  DwarfToolResolution* = object
    ## Package-Model class 2 (PATH-only executable) resolution record.
    ##
    ## The spec's class-2 tier is the weakest one reprobuild admits, and it
    ## still demands that "the resulting action identity records the search
    ## path, the resolved executable path, and configured probes". This object
    ## IS that record. It is returned from every entry point that resolves a
    ## DWARF dumper, so the resolution cannot be performed and discarded —
    ## which is what ``docs/ambient-execution-linter.md`` calls "not class 2;
    ## it is unclassified".
    ##
    ## The four configured candidates (``dwarfdump`` / ``llvm-dwarfdump`` /
    ## ``objdump`` / ``readelf``) do NOT emit the same DWARF text, so which one
    ## the host happened to carry changes the extracted layouts. Whoever owns
    ## the action identity for a type-layout validation MUST fold
    ## ``dwarfToolIdentity`` into it; otherwise two hosts produce different
    ## layout facts under one cache key.
    searchPath*: seq[string]
      ## The directories the resolver walked, in order.
    probes*: seq[DwarfToolProbe]
      ## Every configured probe, in the configured order.
    toolName*: string
      ## Candidate whose output was used; ``""`` when none succeeded.
    resolvedExecutablePath*: string
      ## The winning candidate's resolved executable path.
    argv*: seq[string]
      ## The argv actually handed to the runner (``argv[0]`` is the resolved
      ## executable path, not the bare candidate name).

  DwarfDumpRunner* = proc (executablePath: string; args: seq[string]):
      tuple[output: string, exitCode: int] {.closure.}
    ## The execution half of the class-2 seam.
    ##
    ## This library parses object files; it does not own an action identity and
    ## it is not allowed to spawn processes (see
    ## ``scripts/check_ambient_execution.sh`` and
    ## ``reprobuild-specs/Package-Model.md`` §"Executables, Libraries, And
    ## Package Collections"). The identity owner supplies the runner — a build
    ## edge passes one that spawns under the monitor with the tool bound
    ## through ``BuildAction.toolIdentityRefs``; the HAX-M1 gate passes one
    ## backed by ``std/osproc``.

  DwarfToolHost* = object
    ## The injected resolution+execution environment: the search path the
    ## candidates are resolved against, and the runner that executes the
    ## winner. Construct with ``newDwarfToolHost``.
    searchPath*: seq[string]
    run*: DwarfDumpRunner

  TypeLayoutExtraction* = object
    ## Extraction result. The resolution travels WITH the layouts by
    ## construction: there is no entry point that returns layouts alone, so a
    ## caller cannot end up holding type facts whose provenance it never saw.
    layouts*: seq[CompositeTypeLayout]
    resolution*: DwarfToolResolution

  TypeLayoutValidationResult* = object
    isCompatible*: bool
    refusalReason*: string
    diffs*: seq[TypeDiffFact]
    toolResolutions*: seq[DwarfToolResolution]
      ## One per object file compared (baseline first, then candidate). Empty
      ## for ``diffTypeLayouts``, which is pure and resolves nothing.
    toolIdentity*: string
      ## Concatenation of ``dwarfToolIdentity`` over ``toolResolutions``. Fold
      ## this into the action identity of whatever schedules the validation.

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
  if clean.startsWith("<") and clean.endsWith(">"):
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
  # GNU dumpers prefix resolved strings with their storage/index annotation.
  # Strip that annotation, not colons that belong to a C++ qualified name.
  if clean.startsWith("(indexed string:") or
      clean.startsWith("(indirect string, offset:") or
      clean.startsWith("(indirect line string, offset:"):
    let annotationEnd = clean.find("):")
    if annotationEnd >= 0:
      clean = clean[annotationEnd + 2 .. ^1].strip()
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

type DwarfToolCandidate* = tuple[binName: string, args: seq[string]]

proc dwarfDumpCandidates*(objectPath: string): seq[DwarfToolCandidate] =
  ## The configured probe plan, in priority order. Exported so the identity
  ## owner can see the plan without running it, and so the order is pinnable
  ## by a test rather than only observable through a successful dump.
  @[
    ("dwarfdump", @["--debug-info", objectPath]),
    ("llvm-dwarfdump", @["--debug-info", objectPath]),
    ("objdump", @["--dwarf=info", objectPath]),
    ("readelf", @["--debug-dump=info", objectPath])
  ]

proc splitSearchPath*(pathValue: string): seq[string] =
  ## Split a ``PATH``-shaped value into its directories, preserving order and
  ## dropping empty entries.
  for part in pathValue.split(PathSep):
    if part.len > 0:
      result.add(part)

proc ambientSearchPath*(): seq[string] =
  ## The host's ``PATH``, split. Reading the environment is not itself the
  ## hazard the ambient-execution rule targets — resolving and executing a
  ## binary while recording nothing is. Callers pass the result into
  ## ``newDwarfToolHost``, where it is recorded on every resolution.
  splitSearchPath(getEnv("PATH"))

proc newDwarfToolHost*(run: DwarfDumpRunner;
                       searchPath: openArray[string]): DwarfToolHost =
  ## Bind an execution runner to the search path its candidates are resolved
  ## against. Both halves are the caller's, and both are recorded.
  if run == nil:
    raise newException(ValueError,
      "newDwarfToolHost: a DwarfDumpRunner is required — this library does " &
      "not spawn processes; the owner of the action identity supplies the " &
      "runner and receives the recorded resolution back")
  DwarfToolHost(searchPath: @searchPath, run: run)

proc expandExecutableSymlink(path: string): string =
  ## Mirror ``os.findExe``'s ``followSymlinks = true`` behaviour so the
  ## recorded ``resolvedExecutablePath`` names the real file rather than a
  ## dispatcher symlink. Bounded so a symlink cycle cannot hang a build.
  result = path
  when not defined(windows):
    var guard = 0
    while guard < 64:
      try:
        if not symlinkExists(result):
          break
        let target = expandSymlink(result)
        result =
          if target.isAbsolute: target
          else: result.parentDir / target
      except OSError:
        break
      inc guard

proc resolveOnSearchPath*(binName: string;
                          searchPath: openArray[string]): string =
  ## Walk ``searchPath`` for ``binName`` and return the resolved executable
  ## path, or ``""``.
  ##
  ## This replaces ``os.findExe``: not as a way to dodge the linter's grep, but
  ## because ``findExe`` reads the ambient ``PATH`` itself and therefore cannot
  ## tell the caller which directories it walked. Taking the search path as an
  ## argument is what makes ``DwarfToolResolution.searchPath`` a fact rather
  ## than a guess, and it is what lets a test drive the resolution over a
  ## controlled directory.
  if binName.len == 0:
    return ""
  when defined(windows):
    const exeExts = ["exe", "cmd", "bat", ""]
  else:
    const exeExts = [""]

  proc withExt(name, ext: string): string =
    if ext.len == 0: name else: addFileExt(name, ext)

  proc probeDir(dir, name: string): string =
    for ext in exeExts:
      let candidate =
        if dir.len == 0: withExt(name, ext)
        else: dir / withExt(name, ext)
      if fileExists(candidate):
        return expandExecutableSymlink(candidate)
    ""

  # ``findExe`` checks the current directory first on Windows, and on POSIX
  # only when the name already carries a path separator. Preserved verbatim.
  when defined(windows):
    let here = probeDir("", binName)
    if here.len > 0:
      return here
  else:
    if '/' in binName:
      let here = probeDir("", binName)
      if here.len > 0:
        return here

  for dir in searchPath:
    if dir.len == 0:
      continue
    let hit = probeDir(dir, binName)
    if hit.len > 0:
      return hit
  ""

proc dwarfToolIdentity*(resolution: DwarfToolResolution): string =
  ## Deterministic, line-oriented rendering of the class-2 record, shaped like
  ## the engine's own ``reprobuild.profileBuildAction.v1`` action key (one
  ## ``argv:<elem>`` line per element). Fold this into the action identity of
  ## whatever schedules a type-layout validation: it is what makes a host with
  ## ``llvm-dwarfdump`` and a host with only ``readelf`` land on DIFFERENT
  ## cache keys instead of sharing one.
  var lines: seq[string] = @["dwarf-tool-resolution.v1"]
  for dir in resolution.searchPath:
    lines.add("search-path:" & dir)
  for probe in resolution.probes:
    lines.add("probe:" & probe.binName &
              ":args=" & probe.args.join(" ") &
              ":resolved=" & (if probe.resolvedPath.len > 0: probe.resolvedPath else: "-") &
              ":attempted=" & $probe.attempted &
              ":exit=" & $probe.exitCode &
              ":bytes=" & $probe.outputBytes &
              ":accepted=" & $probe.accepted)
  lines.add("tool:" & (if resolution.toolName.len > 0: resolution.toolName else: "-"))
  lines.add("resolved:" &
            (if resolution.resolvedExecutablePath.len > 0:
               resolution.resolvedExecutablePath
             else: "-"))
  for arg in resolution.argv:
    lines.add("argv:" & arg)
  lines.join("\n")

proc runDwarfDump*(objectPath: string; host: DwarfToolHost;
                   resolution: var DwarfToolResolution): string =
  ## Resolve a DWARF dumper over ``host.searchPath``, run it through
  ## ``host.run``, and record the whole resolution into ``resolution``.
  ##
  ## Behaviour is the pre-existing loop, unchanged: the candidate order is
  ## ``dwarfdump`` → ``llvm-dwarfdump`` → ``objdump`` → ``readelf``; a
  ## candidate missing from the search path is skipped silently; a candidate
  ## that exits non-zero or emits nothing falls through to the next one; and
  ## exhausting the list raises ``IOError`` with the same ``Attempts: …`` list.
  ## What is new is that every one of those decisions is now written down.
  if not fileExists(objectPath):
    raise newException(IOError, "Object file does not exist: " & objectPath)
  if host.run == nil:
    raise newException(ValueError,
      "runDwarfDump: DwarfToolHost carries no runner — build it with " &
      "newDwarfToolHost")

  resolution = DwarfToolResolution(
    searchPath: host.searchPath,
    probes: @[],
    toolName: "",
    resolvedExecutablePath: "",
    argv: @[])

  var errors: seq[string] = @[]
  var dumped = ""
  var found = false

  for (binName, args) in dwarfDumpCandidates(objectPath):
    var probe = DwarfToolProbe(
      binName: binName,
      args: args,
      resolvedPath: "",
      attempted: false,
      exitCode: 0,
      outputBytes: 0,
      accepted: false,
      diagnostic: "")

    if found:
      # Later candidates are not probed once one has won — recording them as
      # "not attempted" keeps the plan visible without claiming a probe that
      # never happened.
      resolution.probes.add(probe)
      continue

    let exePath = resolveOnSearchPath(binName, host.searchPath)
    probe.resolvedPath = exePath
    if exePath.len == 0:
      probe.diagnostic = binName & " not found on the recorded search path"
      resolution.probes.add(probe)
      continue

    probe.attempted = true
    try:
      let res = host.run(exePath, args)
      probe.exitCode = res.exitCode
      probe.outputBytes = res.output.len
      if res.exitCode == 0 and res.output.len > 0:
        probe.accepted = true
        resolution.toolName = binName
        resolution.resolvedExecutablePath = exePath
        resolution.argv = @[exePath] & args
        dumped = res.output
        found = true
      else:
        probe.diagnostic = binName & " exited with code " & $res.exitCode
        errors.add(binName & " exited with code " & $res.exitCode)
    except CatchableError as e:
      probe.exitCode = -1
      probe.diagnostic = binName & " error: " & e.msg
      errors.add(binName & " error: " & e.msg)

    resolution.probes.add(probe)

  if found:
    return dumped

  raise newException(IOError, "Failed to dump DWARF debug info from '" & objectPath & "'. Attempts: " & errors.join("; "))

proc extractTypeLayoutsFromObject*(objectPath: string;
                                   host: DwarfToolHost): TypeLayoutExtraction =
  ## Extract composite type layouts from ``objectPath``, returning the layouts
  ## together with the class-2 resolution that produced them.
  var resolution: DwarfToolResolution
  let output = runDwarfDump(objectPath, host, resolution)
  TypeLayoutExtraction(
    layouts: extractTypeLayoutsFromDwarf(output),
    resolution: resolution)

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
                                     host: DwarfToolHost,
                                     ignoreOffsetShift: bool = false): TypeLayoutValidationResult =
  ## Phase C of the patch-loading lifecycle
  ## (``reprobuild-specs/HCR/Patch-Loading-Lifecycle.md`` §"Phase C: Type
  ## Layout Validation").
  ##
  ## The returned result carries ``toolResolutions`` / ``toolIdentity``: the
  ## refusal or acceptance below is only as reproducible as the dumper that
  ## produced the layouts, so the coordinator that schedules this validation
  ## must fold ``toolIdentity`` into the identity it caches the verdict under.
  let baseline = extractTypeLayoutsFromObject(baselineObjectPath, host)
  let candidate = extractTypeLayoutsFromObject(candidateObjectPath, host)
  result = diffTypeLayouts(baseline.layouts, candidate.layouts, ignoreOffsetShift)
  result.toolResolutions = @[baseline.resolution, candidate.resolution]
  var keys: seq[string] = @[]
  for resolution in result.toolResolutions:
    keys.add(dwarfToolIdentity(resolution))
  result.toolIdentity = keys.join("\n--\n")
