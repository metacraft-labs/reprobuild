## Apply pipeline step 9: materialize one launcher artifact per
## exported command into the user-visible bin directory.
##
## Per [Launch-Plans-And-Platform-Launchers.md] "Materialization Into
## Home Profile Bin Dirs":
##
##   * Linux/macOS: a symlink to the realized executable when no
##     environment shaping is required, or a generated POSIX launcher
##     script for strategy 3.
##   * Windows: always a copy of the Reprobuild native launcher
##     binary (`build/repro-launcher.exe`) plus a sidecar named
##     `<command>.repro-launch`.
##
## Pre-conditions: the `LaunchPlan` envelope has already been stored
## in the M56 CAS (the pipeline calls `storeLaunchPlan` before invoking
## this module). This module locates the bin dir for the generation
## being applied, writes the artifacts, and returns one
## `MaterializedLauncherRecord` per command for the manifest writer.

import std/[os, strutils]
from repro_core/paths import extendedPath

import repro_home_generations
import repro_local_store
import repro_launch_plan

import ./errors
import ./plan
import ./realize

const
  LauncherBinaryEnvVar* = "REPRO_LAUNCHER_BINARY"
    ## Operator/test override for the path to the Reprobuild Windows
    ## launcher binary. Defaults to `build/repro-launcher.exe` next to
    ## the repro binary; tests pre-position the same binary the M57
    ## gates produce.

type
  MaterializedLauncherRecord* = object
    commandName*: string
    binDirRelativePath*: string
    binDirArtifactKind*: string
    launchPlanDigest*: Digest256

proc locateLauncherBinary(): string =
  let override = getEnv(LauncherBinaryEnvVar)
  if override.len > 0:
    return override
  # Look for the launcher binary next to the `repro` executable we're
  # running under; the project's `just repro_launcher_binary` recipe
  # writes it to `build/repro-launcher.exe`.
  let exeDir = getAppDir()
  let candidates = [
    exeDir / "repro-launcher.exe",
    exeDir.parentDir / "repro-launcher.exe",
    getCurrentDir() / "build" / "repro-launcher.exe"]
  for c in candidates:
    if fileExists(extendedPath(c)):
      return c
  ""

proc hostArch(): string =
  when defined(amd64) or defined(x86_64):
    "x86_64"
  elif defined(arm64) or defined(aarch64):
    "arm64"
  elif defined(arm):
    "arm32"
  else:
    "unknown"

proc buildLaunchPlan(rec: RealizedRecord; commandName: string): LaunchPlan =
  ## Synthesize a minimal LaunchPlan for the phase-A case: no
  ## environment shaping, no executable bindings, no runtime library
  ## dirs. The binding decision is platform-driven and recorded so
  ## the launcher can pick the right materialization at activation
  ## time.
  result.schemaVersion = LaunchPlanCurrentSchemaVersion
  result.realizedPrefix = rec.prefixAbsolutePath
  result.exportedCommand = commandName
  result.executablePath = rec.resolvedExecutablePath
  result.arguments = @[]
  result.hasWorkingDirectory = false
  result.environmentBindings = @[]
  result.executableBindings = @[]
  result.runtimeLibraryDirs = @[]
  result.projectedRuntimeImage = ProjectedRuntimeImage(present: false)
  result.executionProfile = ExecutionProfileChecksum(present: false)
  when defined(windows):
    result.supportProfile = newSupportProfile("windows", hostArch(), "msvc", "")
    result.binding = lbkWindowsLauncher
  elif defined(macosx):
    result.supportProfile = newSupportProfile("macos", hostArch(), "darwin", "")
    result.binding = lbkMacosScript
  else:
    result.supportProfile = newSupportProfile("linux", hostArch(), "gnu", "")
    result.binding = lbkLinuxScript
  result.provenance = LaunchPlanProvenance(
    adapter: $rec.adapter,
    packageId: rec.packageId,
    realizationHashHex: prefixIdHex(rec.prefixId))

proc digestFromKey(key: PrefixIdBytes): Digest256 =
  for i in 0 ..< 32:
    result[i] = key[i]

when defined(windows):
  proc isNativeExe(path: string): bool =
    let lower = path.toLowerAscii()
    lower.endsWith(".exe")

  proc materializeWindowsLauncher(binDir, commandName, launcherBinary,
                                  storeRoot, idHex, exePath: string;
                                  prefix: string): MaterializedLauncherRecord =
    let cmdExe = binDir / (commandName & ".exe")
    let sidecar = cmdExe & LaunchPlanSidecarSuffix
    createDir(extendedPath(binDir))
    # The Reprobuild native launcher binary launches via CreateProcessW,
    # which on Windows only spawns native PE executables (.exe). When
    # the realized executable is a `.cmd` or `.bat` script (typical for
    # Scoop apps that ship shims, and for Phase A path-adapter fixtures),
    # the launcher binary cannot start it directly. We fall back to a
    # `.cmd` shim that delegates through `cmd.exe /c`. The activation
    # manifest records `launcher-script` in that case so the on-disk
    # artifact and the manifest record stay consistent.
    if launcherBinary.len > 0 and fileExists(extendedPath(launcherBinary)) and
        isNativeExe(exePath):
      if fileExists(extendedPath(cmdExe)):
        removeFile(extendedPath(cmdExe))
      copyFile(extendedPath(launcherBinary), extendedPath(cmdExe))
      let sidecarRec = LaunchSidecar(
        schemaVersion: LaunchSidecarCurrentVersion,
        launchPlanIdHex: idHex,
        storeRoot: storeRoot,
        realizedPrefix: prefix,
        exportedCommand: commandName,
        requiresExecutionProfile: false,
        executionProfileHex: "")
      writeSidecarFile(sidecar, sidecarRec)
      result.binDirArtifactKind = "windows-launcher"
    else:
      # Fallback: a thin `.cmd` shim that calls through to the resolved
      # executable via cmd.exe. Used for `.cmd`/`.bat` fixtures and
      # when the launcher binary is missing.
      let cmdShim = binDir / (commandName & ".cmd")
      let body = "@echo off\r\n\"" & exePath & "\" %*\r\n"
      writeFile(extendedPath(cmdShim), body)
      result.binDirArtifactKind = "launcher-script"

proc materializeLaunchers*(store: var Store; binDir: string;
                           realized: seq[RealizedRecord];
                           launchers: seq[PlannedLauncher]):
    seq[MaterializedLauncherRecord] =
  createDir(extendedPath(binDir))
  # Build a quick lookup from package id → realized record.
  var byPkg: seq[(string, RealizedRecord)]
  for r in realized:
    byPkg.add((r.packageId, r))
  proc lookup(pkg: string): RealizedRecord =
    for (k, v) in byPkg:
      if k == pkg:
        return v
    raiseLauncherFailed(pkg,
      "no realized record for package while materializing launchers " &
      "(planner/realize-step bug)")
  let launcherBinary = locateLauncherBinary()
  for l in launchers:
    let rec = lookup(l.fromPackageId)
    # M74: a Scoop package whose manifest declares no `bin` field (a
    # library / `env_add_path`-only app) realizes a prefix but exposes
    # no executable — `resolvedExecutablePath` is empty. Such a package
    # gets NO launcher: skip it gracefully, it is not an error.
    if rec.resolvedExecutablePath.len == 0:
      continue
    let plan = buildLaunchPlan(rec, l.commandName)
    let key = storeLaunchPlan(store, plan)
    let digest = digestFromKey(key)
    let idHex = prefixIdHex(key)
    var matRec: MaterializedLauncherRecord
    matRec.commandName = l.commandName
    matRec.launchPlanDigest = digest
    when defined(windows):
      let winRec = materializeWindowsLauncher(binDir, l.commandName,
        launcherBinary, store.root, idHex, rec.resolvedExecutablePath,
        rec.prefixAbsolutePath)
      matRec.binDirArtifactKind = winRec.binDirArtifactKind
      matRec.binDirRelativePath =
        if winRec.binDirArtifactKind == "windows-launcher":
          l.commandName & ".exe"
        else:
          l.commandName & ".cmd"
    else:
      # POSIX: write a strategy-3 script. Even for symlinkable
      # binaries the script form is the lowest-friction path for the
      # phase-A gates; M64+ can specialize to direct symlinks for the
      # `lbkLinuxRunpathExact` strategy.
      let scriptPath = binDir / l.commandName
      let scriptBody =
        block:
          let posixPlan =
            block:
              var p = plan
              p.binding = when defined(macosx): lbkMacosScript else: lbkLinuxScript
              p
          generatePosixLauncherScript(posixPlan,
            when defined(macosx): "DYLD_LIBRARY_PATH" else: "LD_LIBRARY_PATH")
      writeFile(extendedPath(scriptPath), scriptBody)
      when not defined(windows):
        # 0o755
        try:
          setFilePermissions(extendedPath(scriptPath), {fpUserExec, fpUserWrite, fpUserRead,
            fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
        except OSError as err:
          raiseLauncherFailed(l.commandName,
            "setFilePermissions failed for " & scriptPath & ": " & err.msg)
      matRec.binDirRelativePath = l.commandName
      matRec.binDirArtifactKind = "launcher-script"
    result.add(matRec)

proc removeLauncher*(binDir, commandName: string) =
  ## Drop the launcher artifact for a command removed from the plan.
  when defined(windows):
    let cmdExe = binDir / (commandName & ".exe")
    let sidecar = cmdExe & LaunchPlanSidecarSuffix
    let cmdShim = binDir / (commandName & ".cmd")
    if fileExists(extendedPath(cmdExe)): removeFile(extendedPath(cmdExe))
    if fileExists(extendedPath(sidecar)): removeFile(extendedPath(sidecar))
    if fileExists(extendedPath(cmdShim)): removeFile(extendedPath(cmdShim))
  else:
    let scriptPath = binDir / commandName
    if fileExists(extendedPath(scriptPath)): removeFile(extendedPath(scriptPath))
