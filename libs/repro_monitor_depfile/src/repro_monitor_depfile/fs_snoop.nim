import std/[os, osproc, strutils, times]

import repro_monitor_depfile/reader
import repro_monitor_depfile/render
import repro_monitor_depfile/types
import repro_monitor_depfile/writer

# Windows: pull in the CreateRemoteThread+LoadLibraryW injector that
# substitutes for the macOS DYLD_INSERT_LIBRARIES env-var injection.
when defined(windows):
  import repro_monitor_depfile/windows_injector

type
  ParsedFsSnoopCommand = object
    inspectMode: bool
    inspectPath: string
    inspectFormat: string
    request: FsSnoopRequest
    depfileWasExplicit: bool

var tempDirNonce = uint64(getCurrentProcessId())

proc createLocalTempDir(prefix: string): string =
  inc tempDirNonce
  let now = getTime()
  result = getTempDir() / (prefix & "-" & $getCurrentProcessId() & "-" &
    $now.toUnix & "-" & $now.nanosecond & "-" & $tempDirNonce)
  createDir(result)

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
  # Windows: the shim builds as a .dll instead of a .dylib; probe both so the
  # same lookup logic works on either platform without runtime branching at
  # every call site. The explicit env override is still honoured first.
  when defined(windows):
    result = @[
      getEnv("REPRO_MONITOR_SHIM_LIB"),
      appDir / ".." / "lib" / "librepro_monitor_shim.dll",
      appDir / "librepro_monitor_shim.dll",
      getCurrentDir() / "build" / "lib" / "librepro_monitor_shim.dll"
    ]
  elif defined(linux):
    result = @[
      getEnv("REPRO_MONITOR_SHIM_LIB"),
      appDir / ".." / "lib" / "librepro_monitor_shim.so",
      appDir / "librepro_monitor_shim.so",
      getCurrentDir() / "build" / "lib" / "librepro_monitor_shim.so"
    ]
  else:
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
  when defined(linux):
    const injectionEnv = "LD_PRELOAD"
  else:
    const injectionEnv = "DYLD_INSERT_LIBRARIES"
  let existing = getEnv(injectionEnv)
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
  when defined(macosx):
    let shimLib = findShimLibrary()
    if shimLib.len == 0:
      raise newException(IOError,
        "cannot find librepro_monitor_shim.dylib; run just build or set " &
          "REPRO_MONITOR_SHIM_LIB")

    let fragmentDir = createLocalTempDir("repro-fs-snoop-fragments")
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
  elif defined(linux):
    let shimLib = findShimLibrary()
    if shimLib.len == 0:
      raise newException(IOError,
        "cannot find librepro_monitor_shim.so; run just build or set " &
          "REPRO_MONITOR_SHIM_LIB")

    let fragmentDir = createLocalTempDir("repro-fs-snoop-fragments")
    defer: removeDir(fragmentDir)
    ensureParentDir(request.depFilePath)

    var oldEnv: seq[(string, string, bool)] = @[]
    setEnvVar("LD_PRELOAD", injectionValue(shimLib), oldEnv)
    setEnvVar("REPRO_MONITOR_FRAGMENT_DIR", fragmentDir, oldEnv)
    setEnvVar("REPRO_MONITOR_OUTPUT", request.depFilePath, oldEnv)
    setEnvVar("REPRO_MONITOR_SESSION", $epochTime(), oldEnv)
    setEnvVar("REPRO_MONITOR_SHIM_LIB", shimLib, oldEnv)
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
  elif defined(windows):
    # Windows: same end-to-end flow as macOS, but the injection uses
    # CreateProcess(CREATE_SUSPENDED) + CreateRemoteThread(LoadLibraryW)
    # instead of the DYLD_INSERT_LIBRARIES env var. Fragment-dir + output
    # path env vars are still set so the in-DLL hook bodies know where to
    # append RMDF fragments.
    let shimLib = findShimLibrary()
    if shimLib.len == 0:
      raise newException(IOError,
        "cannot find librepro_monitor_shim.dll; run just build or set " &
          "REPRO_MONITOR_SHIM_LIB")

    let fragmentDir = createLocalTempDir("repro-fs-snoop-fragments")
    defer: removeDir(fragmentDir)
    ensureParentDir(request.depFilePath)

    var oldEnv: seq[(string, string, bool)] = @[]
    setEnvVar("REPRO_MONITOR_FRAGMENT_DIR", fragmentDir, oldEnv)
    setEnvVar("REPRO_MONITOR_OUTPUT", request.depFilePath, oldEnv)
    setEnvVar("REPRO_MONITOR_SESSION", $epochTime(), oldEnv)
    setEnvVar("REPRO_MONITOR_SHIM_LIB", shimLib, oldEnv)
    defer: restoreEnv(oldEnv)

    let injection = runWithMonitorShim(request.command, shimLib)
    result = injection.exitCode

    discard mergeFragments(fragmentDir, request.depFilePath)
    discard readMonitorDepFile(request.depFilePath)
    renderStreamToPath(request.depFilePath, request.streamMode,
      request.eventStreamPath)
  else:
    raise newException(OSError,
      "fs-snoop hooks backend currently supports macOS, Linux, and Windows only")

proc runFsSnoopCli*(programName: string; args: seq[string]): int =
  try:
    var parsed = parseFsSnoopCommand(args)
    if parsed.inspectMode:
      echo renderMonitorDepFile(parsed.inspectPath, parsed.inspectFormat)
      return 0

    var tempRoot = ""
    if parsed.request.depFilePath.len == 0:
      tempRoot = createLocalTempDir("repro-fs-snoop")
      parsed.request.depFilePath = tempRoot / "evidence.rdep"
    try:
      result = runMonitoredCommand(parsed.request)
    finally:
      if tempRoot.len > 0:
        removeDir(tempRoot)
  except CatchableError as err:
    stderr.writeLine(programName & ": error: " & err.msg)
    result = 1
