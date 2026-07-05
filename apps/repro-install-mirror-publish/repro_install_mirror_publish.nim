import std/[os, strutils]

import repro_project_dsl/install_mirror_resolver

proc usage(): string =
  "usage: repro-install-mirror-publish --recipes-root <dir> " &
    "--package <name> --version <version> --source <dir>"

proc valueArg(args: seq[string]; i: var int; name, arg: string): string =
  let prefix = name & "="
  if arg.startsWith(prefix):
    return arg[prefix.len .. ^1]
  if arg == name:
    inc i
    if i >= args.len:
      raise newException(ValueError, "missing value for " & name)
    return args[i]
  ""

proc runInstallMirrorPublishCommand*(args: seq[string]): int =
  var recipesRoot = ""
  var packageName = ""
  var version = ""
  var sourceDir = ""
  var i = 0
  try:
    while i < args.len:
      let arg = args[i]
      var value = valueArg(args, i, "--recipes-root", arg)
      if value.len > 0:
        recipesRoot = value
      else:
        value = valueArg(args, i, "--package", arg)
        if value.len > 0:
          packageName = value
        else:
          value = valueArg(args, i, "--version", arg)
          if value.len > 0:
            version = value
          else:
            value = valueArg(args, i, "--source", arg)
            if value.len > 0:
              sourceDir = value
            else:
              raise newException(ValueError, "unknown argument: " & arg)
      inc i
    if recipesRoot.len == 0 or packageName.len == 0 or version.len == 0 or
        sourceDir.len == 0:
      raise newException(ValueError, usage())
    let published = publishInstallMirrorToStore(recipesRoot, packageName,
      version, sourceDir)
    stdout.writeLine(published.absolutePath)
    0
  except CatchableError as err:
    stderr.writeLine("repro-install-mirror-publish: " & err.msg)
    stderr.writeLine(usage())
    2

when isMainModule:
  quit(runInstallMirrorPublishCommand(commandLineParams()))
