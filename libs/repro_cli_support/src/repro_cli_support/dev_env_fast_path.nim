## The thin client's answer to a confirmed ``repro dev-env export`` no-op
## (see ``apps/repro-client/repro_client.nim``). Its flags are read from
## repro's command-line description (``repro_cli_support/cli_description``)
## at compile time, so this reader and the engine's parser agree on every
## spelling; anything it does not recognise is handed to the engine.

import std/[os, strutils]

import repro_dev_env_engine/[cache_key, directory_trust]

import ./cli_description

const
  CanonicalProjectFileName = "repro.nim"
  LegacyProjectFileName = "reprobuild.nim"

type
  DevEnvFastPathResult* = object
    handled*: bool
    exitCode*: int

  ParsedFastExport = object
    shell: string
    projectRoot: string
    activity: string
    developOverridesPath: string
    allowStale: bool

const
  ExportCommand = @["dev-env", "export"]
  ProjectRootFlag = reproFlagSpellings(ExportCommand, "projectRoot")
  ActivityFlag = reproFlagSpellings(ExportCommand, "activity")
  DevelopOverridesFlag = reproFlagSpellings(ExportCommand, "developOverrides")
  PreActivationEnvFlag = reproFlagSpellings(ExportCommand, "preActivationEnv")
  AllowStaleFlag = reproFlagSpellings(ExportCommand, "allowStale")

proc takeValue(args: openArray[string]; i: var int;
               spellings: openArray[string]; value: var string): bool =
  ## Whether ``args[i]`` is one of a value flag's ``spellings``, as
  ## ``--flag=value`` or ``--flag value``; its value goes to ``value`` and
  ## ``i`` moves past it. A flag with no value left raises.
  for spelling in spellings:
    if args[i].startsWith(spelling & "="):
      value = args[i][spelling.len + 1 .. ^1]
      return true
    if args[i] == spelling:
      if i + 1 >= args.len:
        raise newException(ValueError, spelling & " requires a value")
      inc i
      value = args[i]
      return true
  false

proc parseFastExportArgs(args: openArray[string]): ParsedFastExport =
  ## The command line of ``dev-env export`` as the engine reads it; anything
  ## else (an unknown flag, a second positional, ``--``, ``--help``) raises,
  ## and the invocation goes to the engine.
  var i = 0
  var preActivationEnv = ""
  while i < args.len:
    let arg = args[i]
    if takeValue(args, i, ProjectRootFlag, result.projectRoot) or
        takeValue(args, i, ActivityFlag, result.activity) or
        takeValue(args, i, DevelopOverridesFlag,
          result.developOverridesPath) or
        takeValue(args, i, PreActivationEnvFlag, preActivationEnv):
      discard
    elif arg in AllowStaleFlag:
      result.allowStale = true
    elif arg.startsWith("-") or result.shell.len > 0:
      raise newException(ValueError, "delegate to full CLI")
    else:
      result.shell = arg
    inc i
  if result.shell.len == 0:
    raise newException(ValueError, "missing shell")
  if result.activity.len == 0:
    result.activity = "default"

proc fastNoOpScript(shell: string): string =
  case shell.normalize()
  of "bash", "zsh":
    ": # repro shell hook: no-op (cache key unchanged)\n"
  of "fish", "nushell", "nu", "pwsh", "powershell", "ps", "ps1":
    "# repro shell hook: no-op (cache key unchanged)\n"
  else:
    ""


proc findDevEnvProjectRoot(startPath: string): string =
  var cursor = os.normalizedPath(absolutePath(startPath))
  if fileExists(cursor) and not dirExists(cursor):
    cursor = parentDir(cursor)
  while cursor.len > 0:
    let canonical = cursor / CanonicalProjectFileName
    let legacy = cursor / LegacyProjectFileName
    let hasCanonical = fileExists(canonical)
    let hasLegacy = fileExists(legacy)
    if hasCanonical and hasLegacy:
      return ""
    if hasCanonical or hasLegacy:
      return cursor
    let parent = parentDir(cursor)
    if parent == cursor or parent.len == 0:
      break
    cursor = parent
  ""

proc tryDevEnvExportFastPath*(args: openArray[string]): DevEnvFastPathResult =
  ## Handle only a confirmed ``dev-env export`` no-op. Usage errors, stale
  ## requests, misses, and full activations deliberately fall through to the
  ## complete CLI so diagnostics and behavior remain centralized there.
  if args.len < 2 or args[0] != "dev-env" or args[1] != "export":
    return
  let exportArgs =
    if args.len > 2:
      args[2 .. ^1]
    else:
      @[]
  var parsed: ParsedFastExport
  try:
    parsed = parseFastExportArgs(exportArgs)
  except CatchableError:
    return
  if parsed.allowStale:
    return
  let script = fastNoOpScript(parsed.shell)
  if script.len == 0:
    return
  if parsed.projectRoot.len == 0:
    parsed.projectRoot = findDevEnvProjectRoot(getCurrentDir())
    if parsed.projectRoot.len == 0:
      return
  else:
    parsed.projectRoot = os.normalizedPath(absolutePath(parsed.projectRoot))
  let trust = directoryTrustState(parsed.projectRoot)
  var isAllowed = trust == dtTrusted

  if getEnv("REPRO_DEV_ENV_AUTO_ALLOW") == "1":
    isAllowed = true

  if not isAllowed:
    proc samePath(a, b: string): bool =
      if a == b: return true
      if a.len == 0 or b.len == 0: return false
      var canonicalA = a
      var canonicalB = b
      try: canonicalA = expandFilename(a)
      except CatchableError: discard
      try: canonicalB = expandFilename(b)
      except CatchableError: discard
      return canonicalA == canonicalB

    if samePath(getEnv("__REPRO_WARNED"), parsed.projectRoot):
      return DevEnvFastPathResult(handled: true, exitCode: 0)
    return

  let activeKey = getEnv("__REPRO_APPLIED")
  if activeKey.len == 0:
    return
  # Compared against the ACTIVE activation's prompt watch manifest -- the
  # observed inputs it was built from -- located from
  # `$__REPRO_ACTIVE_MANIFEST` (spelled literally: this module stays off the
  # shell-export module's imports). The engine's own fast-path check in
  # `repro dev-env export` derives the same path through the same proc, and
  # the two must agree byte for byte. See the prompt watch section of
  # `repro_dev_env_engine/cache_key`.
  let watchManifest = promptWatchManifestPathFor(
    getEnv("__REPRO_ACTIVE_MANIFEST"))
  let candidateKey = computeDevEnvEdgeCacheKey(parsed.projectRoot,
    parsed.activity, "", parsed.developOverridesPath, watchManifest)
  if candidateKey != activeKey:
    return
  stdout.write(script)
  DevEnvFastPathResult(handled: true, exitCode: 0)
