import std/[os, strutils]

import repro_dev_env_engine/cache_key

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

proc valueFromFlag(args: openArray[string]; i: var int; flag: string): string =
  let arg = args[i]
  if arg.startsWith(flag & "="):
    return arg.split("=", maxsplit = 1)[1]
  if arg == flag:
    if i + 1 >= args.len:
      raise newException(ValueError, flag & " requires a value")
    inc i
    return args[i]
  ""

proc parseFastExportArgs(args: openArray[string]): ParsedFastExport =
  if args.len == 0:
    raise newException(ValueError, "missing shell")
  result.shell = args[0]
  var i = 1
  while i < args.len:
    let arg = args[i]
    if arg == "--project-root" or arg.startsWith("--project-root="):
      result.projectRoot = valueFromFlag(args, i, "--project-root")
    elif arg == "--activity" or arg.startsWith("--activity="):
      result.activity = valueFromFlag(args, i, "--activity")
    elif arg == "--develop-overrides" or
        arg.startsWith("--develop-overrides="):
      result.developOverridesPath =
        valueFromFlag(args, i, "--develop-overrides")
    elif arg == "--allow-stale":
      result.allowStale = true
    elif arg == "--pre-activation-env" or
        arg.startsWith("--pre-activation-env="):
      discard valueFromFlag(args, i, "--pre-activation-env")
    else:
      raise newException(ValueError, "delegate to full CLI")
    inc i
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

proc gitDirForProjectRoot(projectRoot: string): string =
  let dotGit = projectRoot / ".git"
  if dirExists(dotGit):
    return dotGit
  if fileExists(dotGit):
    let content = readFile(dotGit).strip()
    const prefix = "gitdir:"
    if content.normalize().startsWith(prefix):
      let raw = content[prefix.len .. ^1].strip()
      if raw.isAbsolute:
        return os.normalizedPath(raw)
      return os.normalizedPath(projectRoot / raw)
  ""

proc developOverridesMetadataPath(projectRoot: string): string =
  let gitDir = gitDirForProjectRoot(projectRoot)
  if gitDir.len > 0:
    return gitDir / "reprobuild" / "develop-overrides.json"
  projectRoot / ".repro" / "local" / "develop-overrides.json"

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
  let overridesPath =
    if parsed.developOverridesPath.len > 0:
      os.normalizedPath(absolutePath(parsed.developOverridesPath))
    else:
      developOverridesMetadataPath(parsed.projectRoot)
  let activeKey = getEnv("__REPRO_APPLIED")
  if activeKey.len == 0:
    return
  let candidateKey = computeDevEnvEdgeCacheKey(parsed.projectRoot,
    parsed.activity, "", overridesPath)
  if candidateKey != activeKey:
    return
  stdout.write(script)
  DevEnvFastPathResult(handled: true, exitCode: 0)
