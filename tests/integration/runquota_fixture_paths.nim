import std/os

proc runquotadPath*(repoRoot: string): string =
  let override = getEnv("RUNQUOTAD_BIN")
  if override.len > 0:
    return override
  repoRoot.parentDir / "runquota" / "build" / "bin" /
    addFileExt("runquotad", ExeExt)

proc runquotaBinDir*(repoRoot: string): string =
  let override = getEnv("RUNQUOTAD_BIN")
  if override.len > 0:
    return override.parentDir
  repoRoot.parentDir / "runquota" / "build" / "bin"
