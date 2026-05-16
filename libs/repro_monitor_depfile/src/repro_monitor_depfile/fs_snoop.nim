import std/[os, osproc, strutils, tempfiles, times]

import repro_monitor_depfile/reader
import repro_monitor_depfile/render
import repro_monitor_depfile/types
import repro_monitor_depfile/writer

type
  ParsedFsSnoopCommand = object
    inspectMode: bool
    inspectPath: string
    inspectFormat: string
    request: FsSnoopRequest
    depfileWasExplicit: bool

proc parseOutputMode(value: string): FsSnoopOutputMode =
  case value
  of "none":
    fsoNone
  of "text":
    fsoText
  of "jsonl":
    fsoJsonl
  of "binary", "binary-stream":
    fsoBinaryStream
  else:
    raise newException(ValueError, "unsupported event mode: " & value)

proc requireValue(args: seq[string]; index: var int; flag: string): string =
  if index + 1 >= args.len:
    raise newException(ValueError, flag & " requires a value")
  inc index
  args[index]

proc splitFlagValue(arg, flag: string): string =
  let prefix = flag & "="
  if arg.startsWith(prefix):
    arg[prefix.len .. ^1]
  else:
    ""

proc parseInspect(args: seq[string]): ParsedFsSnoopCommand =
  if args.len < 2:
    raise newException(ValueError, "inspect requires an RMDF path")
  result.inspectMode = true
  result.inspectPath = args[1]
  result.inspectFormat = "text"
  var i = 2
  while i < args.len:
    let arg = args[i]
    case arg
    of "--format":
      result.inspectFormat = requireValue(args, i, "--format")
    of "--events":
      result.inspectFormat = requireValue(args, i, "--events")
    else:
      let formatValue = splitFlagValue(arg, "--format")
      if formatValue.len > 0:
        result.inspectFormat = formatValue
      else:
        raise newException(ValueError, "unsupported inspect argument: " & arg)
    inc i

proc parseRun(args: seq[string]): ParsedFsSnoopCommand =
  result.inspectMode = false
  result.request.streamMode = fsoNone
  result.request.passthroughChildStdout = true
  result.request.passthroughChildStderr = true

  var i = 0
  var commandStart = -1
  while i < args.len:
    let arg = args[i]
    if arg == "--":
      commandStart = i + 1
      break
    case arg
    of "--depfile":
      result.request.depFilePath = requireValue(args, i, "--depfile")
      result.depfileWasExplicit = true
    of "--events":
      result.request.streamMode = parseOutputMode(requireValue(args, i, "--events"))
    of "--format":
      result.request.streamMode = parseOutputMode(requireValue(args, i, "--format"))
    of "--event-stream":
      result.request.eventStreamPath = requireValue(args, i, "--event-stream")
    else:
      let depValue = splitFlagValue(arg, "--depfile")
      let eventsValue = splitFlagValue(arg, "--events")
      let formatValue = splitFlagValue(arg, "--format")
      let streamValue = splitFlagValue(arg, "--event-stream")
      if depValue.len > 0:
        result.request.depFilePath = depValue
        result.depfileWasExplicit = true
      elif eventsValue.len > 0:
        result.request.streamMode = parseOutputMode(eventsValue)
      elif formatValue.len > 0:
        result.request.streamMode = parseOutputMode(formatValue)
      elif streamValue.len > 0:
        result.request.eventStreamPath = streamValue
      else:
        raise newException(ValueError, "unsupported fs-snoop argument: " & arg)
    inc i

  if commandStart < 0 or commandStart >= args.len:
    raise newException(ValueError, "missing command; use -- <command> [args...]")
  result.request.command = args[commandStart .. ^1]

proc parseFsSnoopCommand(args: seq[string]): ParsedFsSnoopCommand =
  if args.len > 0 and args[0] == "inspect":
    parseInspect(args)
  else:
    parseRun(args)

proc ensureParentDir(path: string) =
  let parent = parentDir(path)
  if parent.len > 0:
    createDir(parent)

proc candidateShimLibraries(): seq[string] =
  let appDir = getAppDir()
  result = @[
    getEnv("REPRO_MONITOR_SHIM_LIB"),
    appDir / ".." / "lib" / "librepro_monitor_shim.dylib",
    getCurrentDir() / "build" / "lib" / "librepro_monitor_shim.dylib"
  ]

proc findShimLibrary(): string =
  for candidate in candidateShimLibraries():
    if candidate.len > 0 and fileExists(candidate):
      return absolutePath(candidate)
  ""

proc setEnvVar(name, value: string; oldValues: var seq[(string, string, bool)]) =
  oldValues.add((name, getEnv(name), existsEnv(name)))
  putEnv(name, value)

proc restoreEnv(oldValues: seq[(string, string, bool)]) =
  for i in countdown(oldValues.high, 0):
    let (name, value, existed) = oldValues[i]
    if existed:
      putEnv(name, value)
    else:
      delEnv(name)

proc injectionValue(shimLib: string): string =
  let existing = getEnv("DYLD_INSERT_LIBRARIES")
  if existing.len == 0:
    shimLib
  else:
    shimLib & $PathSep & existing

proc renderStreamToPath(depfilePath: string; mode: FsSnoopOutputMode;
                        streamPath: string) =
  case mode
  of fsoNone:
    discard
  of fsoBinaryStream:
    if streamPath.len == 0:
      raise newException(ValueError,
        "--events binary requires --event-stream so child output stays separate")
    ensureParentDir(streamPath)
    writeFile(streamPath, readFile(depfilePath))
  of fsoText, fsoJsonl:
    var lines: seq[string] = @[]
    for item in streamMonitorDepFile(depfilePath):
      if mode == fsoText:
        lines.add(renderMonitorStreamItemText(item))
      else:
        lines.add(renderMonitorStreamItemJsonl(item))
    if streamPath.len > 0:
      ensureParentDir(streamPath)
      writeFile(streamPath, lines.join("\n") & "\n")
    else:
      for line in lines:
        stderr.writeLine(line)

proc runMonitoredCommand(request: FsSnoopRequest): int =
  when not defined(macosx):
    raise newException(OSError,
      "fs-snoop hooks backend is currently macOS-only")
  else:
    let shimLib = findShimLibrary()
    if shimLib.len == 0:
      raise newException(IOError,
        "cannot find librepro_monitor_shim.dylib; run just build or set " &
          "REPRO_MONITOR_SHIM_LIB")

    let fragmentDir = createTempDir("repro-fs-snoop-fragments", "")
    defer: removeDir(fragmentDir)
    ensureParentDir(request.depFilePath)

    var oldEnv: seq[(string, string, bool)] = @[]
    setEnvVar("DYLD_INSERT_LIBRARIES", injectionValue(shimLib), oldEnv)
    setEnvVar("REPRO_MONITOR_FRAGMENT_DIR", fragmentDir, oldEnv)
    setEnvVar("REPRO_MONITOR_OUTPUT", request.depFilePath, oldEnv)
    setEnvVar("REPRO_MONITOR_SESSION", $epochTime(), oldEnv)
    defer: restoreEnv(oldEnv)

    let childArgs =
      if request.command.len > 1:
        request.command[1 .. ^1]
      else:
        @[]
    let process = startProcess(request.command[0],
      args = childArgs,
      options = {poUsePath, poParentStreams})
    result = waitForExit(process)
    close(process)

    discard mergeFragments(fragmentDir, request.depFilePath)
    discard readMonitorDepFile(request.depFilePath)
    renderStreamToPath(request.depFilePath, request.streamMode,
      request.eventStreamPath)

proc runFsSnoopCli*(programName: string; args: seq[string]): int =
  try:
    var parsed = parseFsSnoopCommand(args)
    if parsed.inspectMode:
      echo renderMonitorDepFile(parsed.inspectPath, parsed.inspectFormat)
      return 0

    var tempRoot = ""
    if parsed.request.depFilePath.len == 0:
      tempRoot = createTempDir("repro-fs-snoop", "")
      parsed.request.depFilePath = tempRoot / "evidence.rdep"
    try:
      result = runMonitoredCommand(parsed.request)
    finally:
      if tempRoot.len > 0:
        removeDir(tempRoot)
  except CatchableError as err:
    stderr.writeLine(programName & ": error: " & err.msg)
    result = 1
