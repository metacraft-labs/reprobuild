import std/os
import repro_core

proc wantsVersion*(args: openArray[string]): bool =
  args.len == 1 and args[0] in ["--version", "-V"]

proc renderVersion*(programName: string): string =
  programName & " " & versionString()

proc renderUsage*(programName: string): string =
  programName & " " & versionString() & "\nusage: " & programName & " --version"

proc runThinApp*(programName: string): int =
  let args = commandLineParams()
  if wantsVersion(args):
    echo renderVersion(programName)
    return 0
  echo renderUsage(programName)
  0
