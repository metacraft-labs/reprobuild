import std/[os, strutils]
import repro_core
import repro_interface_artifacts
import repro_monitor_depfile/fs_snoop
import repro_tool_profiles

proc wantsVersion*(args: openArray[string]): bool =
  args.len == 1 and args[0] in ["--version", "-V"]

proc renderVersion*(programName: string): string =
  programName & " " & versionString()

proc renderUsage*(programName: string): string =
  if programName == "repro":
    programName & " " & versionString() & "\nusage: " & programName &
      " --version\n       " & programName &
      " build <target[#name]> --tool-provisioning=path\n       " & programName &
      " debug fs-snoop [inspect <depfile> | [options] -- <command> [args...]]"
  elif programName == "repro-fs-snoop":
    programName & " " & versionString() & "\nusage: " & programName &
      " [options] -- <command> [args...]\n       " & programName &
      " inspect <depfile> --format text|json"
  else:
    programName & " " & versionString() & "\nusage: " & programName & " --version"

proc parseToolProvisioning(value: string): ToolProvisioningMode =
  case value
  of "path":
    tpmPathOnly
  else:
    raise newException(ValueError, "unsupported --tool-provisioning=" & value)

proc splitTarget(target: string): tuple[base: string; fragment: string] =
  let marker = target.find('#')
  if marker < 0:
    (base: target, fragment: "")
  else:
    (base: target[0 ..< marker], fragment: target[marker + 1 .. ^1])

proc moduleForTarget(target: string): string =
  let parts = splitTarget(target)
  if parts.fragment.len > 0:
    if dirExists(parts.base):
      return parts.base / (parts.fragment & ".nim")
    return parts.base
  if dirExists(parts.base):
    return parts.base / "reprobuild.nim"
  parts.base

proc outputDirForModule(modulePath: string; target: string): string =
  let parts = splitTarget(target)
  let name =
    if parts.fragment.len > 0:
      parts.fragment
    else:
      splitFile(modulePath).name
  parentDir(modulePath) / ".repro" / "build" / name

proc runBuildCommand(args: openArray[string]): int =
  var target = ""
  var mode = tpmUnspecified
  for arg in args:
    if arg.startsWith("--tool-provisioning="):
      mode = parseToolProvisioning(arg.split("=", maxsplit = 1)[1])
    elif arg == "--tool-provisioning":
      raise newException(ValueError,
        "--tool-provisioning requires an inline value, for example " &
          "--tool-provisioning=path")
    elif arg.startsWith("-"):
      raise newException(ValueError, "unsupported build flag: " & arg)
    elif target.len == 0:
      target = arg
    else:
      raise newException(ValueError, "unexpected build argument: " & arg)

  if target.len == 0:
    raise newException(ValueError, "missing build target")

  let modulePath = absolutePath(moduleForTarget(target))
  if not fileExists(modulePath):
    raise newException(IOError, "build target module not found: " & modulePath)

  let outDir = outputDirForModule(modulePath, target)
  let interfacePath = outDir / "project-interface.rbsz"
  let stubPath = outDir / "project-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath)

  if artifact.projectInterface.toolUses.len > 0 and mode == tpmUnspecified:
    raise newException(ValueError,
      "typed tool provisioning is required for uses declarations; refusing " &
        "implicit PATH fallback. Pass --tool-provisioning=path to use the " &
        "explicit weak local profile.")

  if mode == tpmPathOnly:
    let identity = pathOnlyBuildIdentity(artifact)
    let identityPath = outDir / "path-only-tool-identities.rbtp"
    let inspectionPath = outDir / "path-only-tool-identities.inspect.json"
    writePathOnlyBuildIdentity(identityPath, identity)
    writeInspectionJson(inspectionPath, identity)
    echo "repro build: provisioning-disabled mode active (tool-provisioning=path)"
    echo "project: " & artifact.projectInterface.projectName
    echo "interface: " & interfacePath
    echo "toolIdentity: " & identityPath
    echo "inspection: " & inspectionPath
    echo "cachePortability: local-only"
    return 0

  echo "repro build: no external tools requested"
  echo "interface: " & interfacePath
  0

proc runThinApp*(programName: string): int =
  let args = commandLineParams()
  if wantsVersion(args):
    echo renderVersion(programName)
    return 0
  if programName == "repro-fs-snoop":
    return runFsSnoopCli(programName, args)
  if programName == "repro" and args.len >= 2 and args[0] == "debug" and
      args[1] == "fs-snoop":
    let fsArgs =
      if args.len > 2:
        args[2 .. ^1]
      else:
        @[]
    return runFsSnoopCli("repro debug fs-snoop", fsArgs)
  if programName == "repro" and args.len > 0 and args[0] == "build":
    try:
      let buildArgs =
        if args.len > 1:
          args[1 .. ^1]
        else:
          @[]
      return runBuildCommand(buildArgs)
    except CatchableError as err:
      stderr.writeLine("repro build: error: " & err.msg)
      return 1
  echo renderUsage(programName)
  0
