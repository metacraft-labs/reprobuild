import std/[os, osproc, sequtils, strtabs, strutils]

import repro_dev_env_artifacts
import repro_provider_runtime

type
  DevEnvPrintFormat* = enum
    depPosix
    depFish
    depPowerShell
    depJson

proc parseDevEnvPrintFormat*(value: string): DevEnvPrintFormat =
  case value.normalize()
  of "posix", "sh", "bash", "zsh":
    depPosix
  of "fish":
    depFish
  of "powershell", "pwsh", "ps1":
    depPowerShell
  of "json":
    depJson
  else:
    raise newException(ValueError,
      "unsupported --print-env format: " & value)

proc validEnvName(name: string): bool =
  if name.len == 0:
    return false
  if not (name[0] in {'A'..'Z', 'a'..'z', '_'}):
    return false
  for ch in name:
    if not (ch in {'A'..'Z', 'a'..'z', '0'..'9', '_'}):
      return false
  true

proc requireEnvName(name: string) =
  if not validEnvName(name):
    raise newException(ValueError,
      "dev-env artifact contains invalid environment variable name: " & name)

proc posixQuote(value: string): string =
  result = "'"
  for ch in value:
    if ch == '\'':
      result.add("'\\''")
    else:
      result.add(ch)
  result.add("'")

proc fishQuote(value: string): string =
  result = "'"
  for ch in value:
    case ch
    of '\'':
      result.add("\\'")
    of '\\':
      result.add("\\\\")
    else:
      result.add(ch)
  result.add("'")

proc powerShellQuote(value: string): string =
  "'" & value.replace("'", "''") & "'"

proc metadataOps(artifact: DevEnvArtifact; artifactPath = ""): seq[DevEnvShellOp] =
  if artifactPath.len > 0:
    result.add(DevEnvShellOp(kind: deskSetEnv,
      name: "REPRO_DEV_ENV_ARTIFACT",
      value: artifactPath))
  result.add(DevEnvShellOp(kind: deskSetEnv,
    name: "REPRO_DEV_ENV_PROJECT_ROOT",
    value: artifact.projectRoot))
  result.add(DevEnvShellOp(kind: deskSetEnv,
    name: "REPRO_DEV_ENV_SELECTED_ACTIVITIES",
    value: artifact.selectedActivities.join(",")))
  result.add(DevEnvShellOp(kind: deskSetEnv,
    name: "REPRO_DEV_ENV_TASKS",
    value: artifact.tasks.mapIt(it.name).join(",")))
  result.add(DevEnvShellOp(kind: deskSetEnv,
    name: "REPRO_DEV_ENV_SERVICES",
    value: artifact.services.mapIt(it.name).join(",")))

proc activationOps(artifact: DevEnvArtifact; artifactPath = "";
                   extraOps: openArray[DevEnvShellOp] = [];
                   preOps: openArray[DevEnvShellOp] = []):
    seq[DevEnvShellOp] =
  # TODO(io-mon live interpose): when a dev-env artifact carries io-mon's
  # monitor/shim build outputs, the Incremental-Test-Runner M8 live read-file
  # capture expects $IO_MON (the standalone `io-mon` CLI), the binary's dir on
  # PATH, and $REPRO_MONITOR_SHIM_LIB (the interpose shim) to be
  # part of the activated environment — mirroring codetracer/.envrc (POSIX) and
  # env.ps1 (Windows DIY). These are emitted via the artifact's own `shellOps`
  # (deskSetEnv / deskSetPathList) by whatever produces the artifact; this
  # renderer stays generic. The wiring is plumbed in the shell-level activation
  # points (`.envrc`, `env.ps1`); the artifact-driven path is left to the
  # artifact producer. The honest platform gaps (macOS chained-fixups interpose,
  # Linux LD_PRELOAD validation, Windows CreateRemoteThread path) are tracked in
  # io-mon's capture CLI and codetracer/src/ct_test/incremental/io_mon_capture.nim.
  # ``preOps`` carries the bin dirs of packages the recipe declared in
  # ``uses:`` and the engine realized. They are applied BEFORE the recipe's
  # own shellOps, which is the opposite of ``extraOps`` below and for the
  # opposite reason: a provisioned package is the DEFAULT the recipe asked
  # for, so an explicit ``prependPath`` in the same recipe has to be able to
  # sit in front of it. A project whose scripts need a locked virtualenv's
  # interpreter ahead of the toolchain's cannot say so otherwise — which is
  # exactly the order the environment this replaces used.
  result = @[]
  for op in preOps:
    result.add(op)
  for op in artifact.shellOps:
    result.add(op)
  # W2 — ``extraOps`` carries environment the ARTIFACT cannot: the bin dirs of
  # cross-repo ``uses:`` producers whose output a previous ``repro build``
  # already materialized. They are deliberately NOT part of the cached RBDE
  # artifact (a producer's build OUTPUT is not one of the artifact's declared
  # source inputs, so it cannot key the artifact's cache without defeating the
  # M77 prompt-time fast path the key exists to serve). The caller re-derives
  # them at every activation instead — see ``devEnvProducerPins`` in
  # ``repro_cli_support``. They are appended AFTER the recipe's own shellOps so
  # a ``deskPrependPath`` here lands in front of anything the recipe prepended:
  # a declared pin outranks both the recipe's ad-hoc PATH edits and the
  # ambient PATH, which is the whole point of pinning it.
  for op in extraOps:
    result.add(op)
  result.add(metadataOps(artifact, artifactPath))

proc renderPosix*(ops: openArray[DevEnvShellOp]): string =
  result = "# Generated by repro dev-env. Do not edit.\n"
  for op in ops:
    requireEnvName(op.name)
    let sep = if op.separator.len > 0: op.separator else: $PathSep
    case op.kind
    of deskSetEnv, deskSetPathList:
      result.add("export " & op.name & "=" & posixQuote(op.value) & "\n")
    of deskUnsetEnv:
      result.add("unset " & op.name & "\n")
    of deskPrependPath:
      result.add("if [ -n \"${" & op.name & ":-}\" ]; then\n")
      result.add("  export " & op.name & "=" & posixQuote(op.value) &
        posixQuote(sep) & "\"$" & op.name & "\"\n")
      result.add("else\n")
      result.add("  export " & op.name & "=" & posixQuote(op.value) & "\n")
      result.add("fi\n")
    of deskAppendPath:
      result.add("if [ -n \"${" & op.name & ":-}\" ]; then\n")
      result.add("  export " & op.name & "=\"$" & op.name & "\"" &
        posixQuote(sep) & posixQuote(op.value) & "\n")
      result.add("else\n")
      result.add("  export " & op.name & "=" & posixQuote(op.value) & "\n")
      result.add("fi\n")
    of deskSetWorkingDirectory:
      result.add("cd " & posixQuote(op.value) & "\n")

proc renderFish*(ops: openArray[DevEnvShellOp]): string =
  result = "# Generated by repro dev-env. Do not edit.\n"
  for op in ops:
    requireEnvName(op.name)
    case op.kind
    of deskSetEnv, deskSetPathList:
      result.add("set -gx " & op.name & " " & fishQuote(op.value) & "\n")
    of deskUnsetEnv:
      result.add("set -e " & op.name & "\n")
    of deskPrependPath:
      result.add("if set -q " & op.name & "\n")
      result.add("  set -gx " & op.name & " " & fishQuote(op.value) &
        " $" & op.name & "\n")
      result.add("else\n")
      result.add("  set -gx " & op.name & " " & fishQuote(op.value) & "\n")
      result.add("end\n")
    of deskAppendPath:
      result.add("if set -q " & op.name & "\n")
      result.add("  set -gx " & op.name & " $" & op.name & " " &
        fishQuote(op.value) & "\n")
      result.add("else\n")
      result.add("  set -gx " & op.name & " " & fishQuote(op.value) & "\n")
      result.add("end\n")
    of deskSetWorkingDirectory:
      result.add("cd " & fishQuote(op.value) & "\n")

proc renderPowerShell*(ops: openArray[DevEnvShellOp]): string =
  result = "# Generated by repro dev-env. Do not edit.\n"
  for op in ops:
    requireEnvName(op.name)
    let sep = if op.separator.len > 0: op.separator else: $PathSep
    case op.kind
    of deskSetEnv, deskSetPathList:
      result.add("$env:" & op.name & " = " & powerShellQuote(op.value) & "\n")
    of deskUnsetEnv:
      result.add("Remove-Item Env:" & op.name &
        " -ErrorAction SilentlyContinue\n")
    of deskPrependPath:
      result.add("if ($env:" & op.name & ") {\n")
      result.add("  $env:" & op.name & " = " & powerShellQuote(op.value) &
        " + " & powerShellQuote(sep) & " + $env:" & op.name & "\n")
      result.add("} else {\n")
      result.add("  $env:" & op.name & " = " & powerShellQuote(op.value) & "\n")
      result.add("}\n")
    of deskAppendPath:
      result.add("if ($env:" & op.name & ") {\n")
      result.add("  $env:" & op.name & " = $env:" & op.name & " + " &
        powerShellQuote(sep) & " + " & powerShellQuote(op.value) & "\n")
      result.add("} else {\n")
      result.add("  $env:" & op.name & " = " & powerShellQuote(op.value) & "\n")
      result.add("}\n")
    of deskSetWorkingDirectory:
      result.add("Set-Location -LiteralPath " & powerShellQuote(op.value) & "\n")

proc renderDevEnvShellOps*(ops: openArray[DevEnvShellOp];
                           format: DevEnvPrintFormat): string =
  case format
  of depPosix:
    renderPosix(ops)
  of depFish:
    renderFish(ops)
  of depPowerShell:
    renderPowerShell(ops)
  of depJson:
    raise newException(ValueError,
      "json rendering requires the full dev-env artifact")

proc renderDevEnvArtifact*(artifact: DevEnvArtifact; artifactPath = "";
                           format: DevEnvPrintFormat;
                           extraOps: openArray[DevEnvShellOp] = [];
                           preOps: openArray[DevEnvShellOp] = []): string =
  case format
  of depJson:
    toJsonInspection(artifact) & "\n"
  else:
    renderDevEnvShellOps(activationOps(artifact, artifactPath, extraOps, preOps),
      format)

proc baseEnvironment(): StringTableRef =
  # Case-INSENSITIVE on Windows, where environment variable names are.
  #
  # With a case-sensitive table the ambient `Path` and an op naming `PATH`
  # become two separate entries, and the child receives a block containing
  # both. A shell that does its own linear lookup (bash) finds the one it
  # wants and appears to work; `cmd.exe` does not, so a dev-env TASK could
  # fail to see tools that a dev-env EXEC in the same environment resolved
  # perfectly — the two surfaces disagreeing about the same activation.
  #
  # POSIX environment names ARE case-sensitive, so the distinction is kept
  # there rather than normalised away globally.
  when defined(windows):
    result = newStringTable(modeCaseInsensitive)
  else:
    result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value

proc pathListContains(list, entry, sep: string): bool =
  ## Whether ``entry`` is already an element of the ``sep``-separated
  ## ``list``.
  ##
  ## Element-wise, not substring: ``C:/store/p/ab/bin`` is a substring of
  ## ``C:/store/p/abc/bin`` and is not the same entry. Case-insensitive on
  ## Windows, where the filesystem is, so the same directory reached under a
  ## different spelling still counts as present.
  if entry.len == 0:
    return false
  for element in list.split(sep):
    when defined(windows):
      if cmpIgnoreCase(element, entry) == 0:
        return true
    else:
      if element == entry:
        return true
  false

proc applyOp(env: StringTableRef; op: DevEnvShellOp;
             workingDirectory: var string) =
  requireEnvName(op.name)
  let sep = if op.separator.len > 0: op.separator else: $PathSep
  case op.kind
  of deskSetEnv, deskSetPathList:
    env[op.name] = op.value
  of deskUnsetEnv:
    env.del(op.name)
  of deskPrependPath:
    let current = env.getOrDefault(op.name)
    env[op.name] =
      if current.len == 0:
        op.value
      elif current.pathListContains(op.value, sep):
        # Already there: leave the list alone.
        #
        # Activation has to be idempotent because activations NEST. A `just`
        # recipe whose shell is `repro exec -- bash` re-enters the
        # environment it is already inside, and before this each re-entry
        # prepended the same thirty-five entries again. Two levels is 3.6 KB
        # of duplicate PATH, which on Windows is enough to cross cmd.exe's
        # 8191-character limit on its own: the observed failure was
        # `VsDevCmd.bat` reporting "The input line is too long" and `tsc` not
        # being recognised, inside a build that works perfectly when run one
        # level down.
        #
        # Skipping rather than moving to the front: the entry is already in
        # the list because this same environment put it there, so its
        # position is the one this environment chose.
        current
      else:
        op.value & sep & current
  of deskAppendPath:
    let current = env.getOrDefault(op.name)
    env[op.name] =
      if current.len == 0:
        op.value
      elif current.pathListContains(op.value, sep):
        current
      else:
        current & sep & op.value
  of deskSetWorkingDirectory:
    if op.value.len > 0:
      workingDirectory = op.value
      env["PWD"] = op.value

proc activatedEnvironment*(artifact: DevEnvArtifact; artifactPath = "";
                           defaultWorkingDirectory = "";
                           extraOps: openArray[DevEnvShellOp] = [];
                           preOps: openArray[DevEnvShellOp] = []):
    tuple[env: StringTableRef; workingDirectory: string] =
  result.env = baseEnvironment()
  result.workingDirectory =
    if defaultWorkingDirectory.len > 0:
      defaultWorkingDirectory
    else:
      artifact.projectRoot
  for op in activationOps(artifact, artifactPath, extraOps, preOps):
    result.env.applyOp(op, result.workingDirectory)

proc containsPathSeparator(value: string): bool =
  value.contains(DirSep) or value.contains(AltSep)

proc executableCandidate(dir, name, workingDirectory: string): string =
  let base =
    if dir.isAbsolute or workingDirectory.len == 0:
      dir
    else:
      workingDirectory / dir
  let direct = base / name
  if fileExists(direct):
    return direct
  when defined(windows):
    if splitFile(name).ext.len == 0:
      let withExe = base / addFileExt(name, ExeExt)
      if fileExists(withExe):
        return withExe
  ""

proc resolveFromActivatedPath*(command: string; env: StringTableRef;
                              workingDirectory: string): string =
  if command.len == 0 or command.containsPathSeparator():
    return command
  let pathValue = env.getOrDefault("PATH")
  for dir in pathValue.split(PathSep):
    if dir.len == 0:
      continue
    let candidate = executableCandidate(dir, command, workingDirectory)
    if candidate.len > 0:
      return candidate
  command

proc runActivatedCommand*(artifact: DevEnvArtifact; artifactPath: string;
                          command: openArray[string];
                          defaultWorkingDirectory = "";
                          extraOps: openArray[DevEnvShellOp] = [];
                          preOps: openArray[DevEnvShellOp] = []): int =
  if command.len == 0:
    raise newException(ValueError, "dev-env command is empty")
  let activation = activatedEnvironment(artifact, artifactPath,
    defaultWorkingDirectory, extraOps, preOps)
  var childArgs: seq[string] = @[]
  for i in 1 ..< command.len:
    childArgs.add(command[i])
  let executable = resolveFromActivatedPath(command[0], activation.env,
    activation.workingDirectory)
  var process = startProcess(executable,
    args = childArgs,
    env = activation.env,
    workingDir = activation.workingDirectory,
    options = {poUsePath, poParentStreams})
  result = process.waitForExit()
  process.close()

proc spawnActivatedShell*(artifact: DevEnvArtifact; artifactPath,
                          shellPath: string;
                          defaultWorkingDirectory = "";
                          extraOps: openArray[DevEnvShellOp] = [];
                          preOps: openArray[DevEnvShellOp] = []): int =
  if shellPath.len == 0:
    raise newException(ValueError, "dev-env shell path is empty")
  let activation = activatedEnvironment(artifact, artifactPath,
    defaultWorkingDirectory, extraOps, preOps)
  var process = startProcess(shellPath,
    env = activation.env,
    workingDir = activation.workingDirectory,
    options = {poUsePath, poParentStreams})
  result = process.waitForExit()
  process.close()
