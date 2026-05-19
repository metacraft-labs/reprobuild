import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_tool_profiles

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string];
                  env: openArray[(string, string)] = []): string =
  var parts: seq[string] = @[]
  for (name, value) in env:
    parts.add(name & "=" & q(value))
  for arg in args:
    parts.add(q(arg))
  parts.join(" ")

proc runShell(command: string; cwd = getCurrentDir()):
    tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = getCurrentDir()): string =
  let res = runShell(command, cwd)
  if res.code != 0:
    checkpoint(res.output)
  check res.code == 0
  res.output

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc lastValueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      result = line[prefix.len .. ^1].strip()

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / "runquotad"
  if not fileExists(daemonBin):
    discard requireSuccess("cd " & q(runquotaRoot) & " && just build", repoRoot)
  # Windows: /tmp is not present; use the platform tempdir so the socket
  # path is valid on both POSIX and Windows hosts.
  let socketPath = getTempDir() / "repro-m9-rq-" & $getCurrentProcessId() &
    ".sock"
  if fileExists(socketPath):
    removeFile(socketPath)
  let daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--cpu-milli", "16000",
    "--memory-bytes", "17179869184"
  ], options = {poUsePath})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 200:
    if pathExists(socketPath):
      return (process: daemon, socket: socketPath)
    sleep(25)
  daemon.terminate()
  raise newException(OSError, "runquotad socket did not appear")

proc repoCMakeRoot(repoRoot: string): string =
  repoRoot.parentDir / "reprobuild-cmake"

proc findForkedCMake(repoRoot: string): string =
  let explicit = getEnv("REPROBUILD_FORKED_CMAKE")
  if explicit.len > 0 and fileExists(explicit):
    return explicit
  let cmakeRoot = repoCMakeRoot(repoRoot)
  # Windows: the fork may be built either by MSVC (multi-config layout with
  # Release/Debug under bin/) or by MinGW (single-config layout). Probe the
  # MSVC Release path first, then plain bin/, and try both with and without
  # the .exe suffix so a POSIX layout still resolves.
  var candidates: seq[string] = @[
    cmakeRoot / "build" / "bin" / "cmake",
    cmakeRoot / "_build" / "bin" / "cmake"
  ]
  when defined(windows):
    candidates = @[
      cmakeRoot / "build" / "bin" / "Release" / "cmake.exe",
      cmakeRoot / "build" / "bin" / "cmake.exe",
      cmakeRoot / "_build" / "bin" / "Release" / "cmake.exe",
      cmakeRoot / "_build" / "bin" / "cmake.exe"
    ] & candidates
  for candidate in candidates:
    if fileExists(candidate):
      return candidate
  ""

proc findExeInPath(name, pathValue: string): string =
  for dir in pathValue.split(PathSep):
    if dir.len == 0:
      continue
    let candidate = dir / name
    if fileExists(candidate) and {fpUserExec, fpGroupExec, fpOthersExec}.anyIt(
        it in getFilePermissions(candidate)):
      return candidate
  ""

proc buildRepro(repoRoot, tempRoot: string): string =
  let reproBin = tempRoot / "repro"
  discard requireSuccess(shellCommand([
    "nim", "c", "--verbosity:0", "--hints:off",
    "--nimcache:" & (tempRoot / "nimcache-repro"),
    "--out:" & reproBin,
    repoRoot / "apps" / "repro" / "repro.nim"
  ]), repoRoot)
  reproBin

proc writeFixture(projectRoot: string) =
  createDir(projectRoot)
  writeFile(projectRoot / "CMakeLists.txt",
    "cmake_minimum_required(VERSION 3.20)\n" &
    "project(M9ReproDevelop C)\n" &
    "file(WRITE ${CMAKE_BINARY_DIR}/m9-config.txt\n" &
    "  \"toolchain=${CMAKE_TOOLCHAIN_FILE}\\n\"\n" &
    "  \"prefix=${CMAKE_PREFIX_PATH}\\n\"\n" &
    "  \"portability=${REPROBUILD_CMAKE_TOOL_PORTABILITY}\\n\"\n" &
    "  \"c=${CMAKE_C_COMPILER}\\n\")\n" &
    "add_executable(m9 main.c)\n")
  writeFile(projectRoot / "main.c",
    "static int plus_one(int value) { return value + 1; }\n" &
    "int main(void) { return plus_one(40) == 41 ? 0 : 1; }\n")

proc developConfigureBuild(reproBin, forkedCMake, projectRoot, buildDir,
                           mode, pathValue: string;
                           extraEnv: openArray[(string, string)] = []):
    tuple[output: string; buildIdentity: PathOnlyBuildIdentity] =
  let buildCommand =
    "repro-cmake-configure -S . -B " & q(buildDir) &
    " && REPROBUILD_REPRO=" & q(reproBin) &
    " REPROBUILD_SOURCE_ROOT=" & q(getCurrentDir()) &
    " " & q(forkedCMake) & " --build " & q(buildDir)
  var envValues = @[("PATH", pathValue)]
  for item in extraEnv:
    envValues.add(item)
  let output = requireSuccess(shellCommand([
    reproBin, "develop", "--cmake", projectRoot,
    "--tool-provisioning=" & mode,
    "--cmake-binary=" & forkedCMake,
    "--", "sh", "-c", buildCommand
  ], env = envValues), getCurrentDir())
  let toolchainPath = valueAfter(output, "toolchain:")
  let wrapperPath = valueAfter(output, "configureWrapper:")
  check fileExists(toolchainPath)
  check fileExists(wrapperPath)
  let configText = readFile(buildDir / "m9-config.txt")
  check configText.contains("toolchain=" & toolchainPath)
  check configText.contains("prefix=")
  check configText.contains("portability=" & mode)
  let buildIdentityPath = lastValueAfter(output, "toolIdentity:")
  check fileExists(buildIdentityPath)
  (output: output, buildIdentity: readPathOnlyBuildIdentity(buildIdentityPath))

proc actionFor(identity: PathOnlyBuildIdentity; executableName: string):
    ToolActionIdentity =
  for action in identity.actionIdentities:
    if action.executableName == executableName:
      return action
  fail()

proc profileFor(identity: PathOnlyBuildIdentity; executableName: string):
    PathOnlyToolProfile =
  for profile in identity.profiles:
    if profile.executableName == executableName:
      return profile
  fail()

suite "e2e_repro_develop_cmake":
  test "e2e_repro_develop_cmake_configure_and_build":
    let repoRoot = getCurrentDir()
    let forkedCMake = findForkedCMake(repoRoot)
    check forkedCMake.len > 0
    if forkedCMake.len == 0:
      checkpoint("forked CMake with Reprobuild generator is unavailable")
    else:
      let tempRoot = createTempDir("repro-m9-cmake-build", "")
      defer: removeDir(tempRoot)
      let reproBin = buildRepro(repoRoot, tempRoot)
      let projectRoot = tempRoot / "project"
      writeFixture(projectRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      let pathValue = parentDir(forkedCMake) & $PathSep & getEnv("PATH")
      let result = developConfigureBuild(reproBin, forkedCMake, projectRoot,
        tempRoot / "build-path", "path", pathValue)
      check result.output.contains("action: m9 status=asSucceeded")
      check fileExists(tempRoot / "build-path" / "m9")
      check result.buildIdentity.profileFor("reprobuild-cmake-cc").
        cachePortability == cpLocalOnly

  test "e2e_repro_develop_cmake_tool_identity_changes_cache_key":
    let repoRoot = getCurrentDir()
    let forkedCMake = findForkedCMake(repoRoot)
    check forkedCMake.len > 0
    if forkedCMake.len == 0:
      checkpoint("forked CMake with Reprobuild generator is unavailable")
    else:
      let usrPath = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
      let usrCc = findExeInPath("cc", usrPath)
      let nixCc = findExe("cc")
      check usrCc.len > 0
      check nixCc.len > 0
      check usrCc != nixCc

      let tempRoot = createTempDir("repro-m9-cmake-identity", "")
      defer: removeDir(tempRoot)
      let reproBin = buildRepro(repoRoot, tempRoot)
      let projectRoot = tempRoot / "project"
      writeFixture(projectRoot)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      let pathA = parentDir(forkedCMake) & $PathSep & parentDir(usrCc) &
        $PathSep & usrPath
      let pathB = parentDir(forkedCMake) & $PathSep & parentDir(nixCc) &
        $PathSep & getEnv("PATH")
      let first = developConfigureBuild(reproBin, forkedCMake, projectRoot,
        tempRoot / "build-a", "path", pathA,
        extraEnv = [("SDKROOT", "")]).buildIdentity
      let second = developConfigureBuild(reproBin, forkedCMake, projectRoot,
        tempRoot / "build-b", "path", pathB).buildIdentity
      let firstCc = first.actionFor("reprobuild-cmake-cc")
      let secondCc = second.actionFor("reprobuild-cmake-cc")
      check firstCc.resolvedExecutablePath != secondCc.resolvedExecutablePath
      check firstCc.actionFingerprint != secondCc.actionFingerprint
      check first.profileFor("reprobuild-cmake-cc").profileFingerprint !=
        second.profileFor("reprobuild-cmake-cc").profileFingerprint

  test "e2e_repro_develop_cmake_path_vs_nix_portability":
    let repoRoot = getCurrentDir()
    let forkedCMake = findForkedCMake(repoRoot)
    check forkedCMake.len > 0
    if forkedCMake.len == 0:
      checkpoint("forked CMake with Reprobuild generator is unavailable")
    else:
      let tempRoot = createTempDir("repro-m9-cmake-portability", "")
      defer: removeDir(tempRoot)
      let reproBin = buildRepro(repoRoot, tempRoot)
      let pathProject = tempRoot / "path-project"
      let nixProject = tempRoot / "nix-project"
      writeFixture(pathProject)
      writeFixture(nixProject)

      var daemon = ensureRunQuotaDaemon(repoRoot)
      defer:
        daemon.process.terminate()
        discard daemon.process.waitForExit()
        daemon.process.close()
        if pathExists(daemon.socket):
          removeFile(daemon.socket)

      let pathValue = parentDir(forkedCMake) & $PathSep & getEnv("PATH")
      let pathIdentity = developConfigureBuild(reproBin, forkedCMake,
        pathProject,
        tempRoot / "build-path-portability", "path", pathValue).buildIdentity
      check pathIdentity.profileFor("reprobuild-cmake-cc").adapterStrength ==
        asWeak
      check pathIdentity.profileFor("reprobuild-cmake-cc").cachePortability ==
        cpLocalOnly

      let nixOutput = runShell(shellCommand([
        reproBin, "develop", "--cmake", nixProject,
        "--tool-provisioning=nix",
        "--cmake-binary=" & forkedCMake,
        "--", "sh", "-c",
        "repro-cmake-configure -S . -B " &
        q(tempRoot / "build-nix-portability") &
        " && REPROBUILD_REPRO=" & q(reproBin) &
        " REPROBUILD_SOURCE_ROOT=" & q(repoRoot) &
        " " & q(forkedCMake) & " --build " &
        q(tempRoot / "build-nix-portability")
      ], env = [("PATH", pathValue)]), repoRoot)
      if nixOutput.code != 0:
        checkpoint(nixOutput.output)
        check nixOutput.output.contains("tool-resolution failed: nix build") or
          nixOutput.output.contains("nix")
      else:
        let identityPath = lastValueAfter(nixOutput.output, "toolIdentity:")
        check fileExists(identityPath)
        let nixIdentity = readPathOnlyBuildIdentity(identityPath)
        let profile = nixIdentity.profileFor("reprobuild-cmake-cc")
        check profile.installMethod == "nix"
        check profile.adapterStrength == asStrong
        check profile.cachePortability == cpPortable
        check profile.selectedStorePath.startsWith("/nix/store/")
        check nixOutput.output.contains("action: m9 status=asSucceeded")
