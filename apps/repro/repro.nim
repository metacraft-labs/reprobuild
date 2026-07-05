when defined(windows):
  import repro_cli_support

  when isMainModule:
    quit runThinApp("repro")
else:
  import std/[os, posix]

  import repro_cli_support/dev_env_fast_path

  proc publicCliPath(): string =
    let app = getAppFilename()
    if app.isAbsolute:
      os.normalizedPath(app)
    elif app.contains(DirSep) or app.contains(AltSep):
      os.normalizedPath(getCurrentDir() / app)
    else:
      let resolved = findExe(app)
      if resolved.len > 0 and resolved.isAbsolute:
        os.normalizedPath(resolved)
      elif resolved.len > 0:
        os.normalizedPath(getCurrentDir() / resolved)
      else:
        os.normalizedPath(getCurrentDir() / app)

  proc fullCliPath(): string =
    let app = publicCliPath()
    let sibling = parentDir(app) / addFileExt("repro-full", ExeExt)
    if fileExists(sibling):
      return sibling
    let onPath = findExe(addFileExt("repro-full", ExeExt))
    if onPath.len > 0:
      return onPath
    sibling

  proc execFullCli(args: seq[string]) {.noreturn.} =
    let full = fullCliPath()
    putEnv("REPRO_PUBLIC_CLI_PATH", publicCliPath())
    let argv = allocCStringArray(@[full] & args)
    discard execv(cstring(full), argv)
    stderr.writeLine("repro: failed to exec " & full & ": " &
      osErrorMsg(osLastError()))
    quit(127)

  when isMainModule:
    let args = commandLineParams()
    let fast = tryDevEnvExportFastPath(args)
    if fast.handled:
      quit fast.exitCode
    execFullCli(args)
