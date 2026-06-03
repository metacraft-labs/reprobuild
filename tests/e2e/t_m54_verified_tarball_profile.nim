import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_tool_profiles
import repro_test_support

proc actionLineCacheEffective(log, id: string): bool =
  ## "Cache was effective for this action" — accepts either
  ## `asCacheHit` (cache hit + outputs restored from CAS) or
  ## `asUpToDate` (cache hit + outputs already present, no restore).
  ## Both leave `launched=false`. The engine picks `asUpToDate`
  ## whenever the prior outputs survived between runs. See
  ## `completeSuccess(...)` calls in
  ## `libs/repro_build_engine/.../repro_build_engine.nim`.
  let prefix = "action: " & id & " status="
  log.contains(prefix & "asCacheHit launched=false") or
  log.contains(prefix & "asUpToDate launched=false")

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc pathExists(path: string): bool =
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc ensureRunQuotaDaemon(repoRoot: string): tuple[process: owned(Process);
    socket: string] =
  let runquotaRoot = repoRoot.parentDir / "runquota"
  let daemonBin = runquotaRoot / "build" / "bin" / addFileExt("runquotad", ExeExt)
  if not fileExists(daemonBin):
    raise newException(OSError,
      "runquotad binary missing at " & daemonBin & "; build it via " &
      "the test harness (scripts/run_tests.sh)")
  let socketPath = "/tmp/repro-m54-rq-" & $getCurrentProcessId() & ".sock"
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

proc sha256Hex(path: string): string =
  let command =
    if findExe("sha256sum").len > 0:
      shellCommand(["sha256sum", path])
    else:
      shellCommand(["shasum", "-a", "256", path])
  let output = requireSuccess(command)
  output.strip().splitWhitespace()[0].toLowerAscii()

proc writeToolArchive(tempRoot: string): tuple[archivePath: string; sha256: string] =
  let payloadRoot = tempRoot / "payload"
  let packageRoot = payloadRoot / "m54tool-1.0.0"
  let binDir = packageRoot / "bin"
  createDir(binDir)
  let toolPath = binDir / "m54tool"
  writeFile(toolPath,
    "#!/bin/sh\n" &
    "set -eu\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then\n" &
    "  echo 'm54tool 1.0.0'\n" &
    "  exit 0\n" &
    "fi\n" &
    "output=\n" &
    "while [ \"$#\" -gt 0 ]; do\n" &
    "  case \"$1\" in\n" &
    "    --output) output=$2; shift 2 ;;\n" &
    "    *) input=$1; shift ;;\n" &
    "  esac\n" &
    "done\n" &
    "test -n \"${input:-}\"\n" &
    "test -n \"$output\"\n" &
    "mkdir -p \"$(dirname \"$output\")\"\n" &
    "printf 'm54:%s\\n' \"$(cat \"$input\")\" > \"$output\"\n")
  setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  let archivePath = tempRoot / "m54tool-1.0.0.tar.gz"
  discard requireSuccess(shellCommand(["tar", "-czf", archivePath, "-C",
    payloadRoot, "m54tool-1.0.0"]))
  (archivePath: archivePath, sha256: sha256Hex(archivePath))

proc writeTarballPackage(projectRoot, primaryUrl, mirrorUrl, expectedSha: string;
                         executablePath = "bin/m54tool") =
  createDir(projectRoot / "reprobuild" / "packages")
  writeFile(projectRoot / "reprobuild" / "packages" / "m54tool.nim",
    "import repro_project_dsl\n\n" &
    "package m54tool:\n" &
    "  provisioning:\n" &
    "    tarball url = " & primaryUrl.escape() & ",\n" &
    "      mirror = " & mirrorUrl.escape() & ",\n" &
    "      sha256 = " & expectedSha.escape() & ",\n" &
    "      archiveType = \"tar.gz\",\n" &
    "      stripComponents = 1,\n" &
    "      executablePath = " & executablePath.escape() & ",\n" &
    "      packageId = \"m54tool@1.0.0\",\n" &
    "      lockIdentity = \"tarball:m54tool@1.0.0:sha256:" & expectedSha & "\"\n\n" &
    "  executable m54tool:\n" &
    "    cli:\n" &
    "      call:\n" &
    "        flag output is string, alias = \"--output\", role = output, required = true\n" &
    "        pos source is string, role = input, position = 0\n")

proc writeProject(projectRoot, primaryUrl, mirrorUrl, expectedSha: string;
                  executablePath = "bin/m54tool") =
  createDir(projectRoot / "src")
  writeFile(projectRoot / "src" / "input.txt", "fixture-input")
  writeTarballPackage(projectRoot, primaryUrl, mirrorUrl, expectedSha,
    executablePath)
  writeFile(projectRoot / "reprobuild.nim",
    "import repro_project_dsl\n\n" &
    "package m54Project:\n" &
    "  usesImportPath \"reprobuild/packages\"\n" &
    "  uses:\n" &
    "    \"m54tool >=1.0 <2.0\"\n\n" &
    "  build:\n" &
    "    let produced = m54tool(actionId = \"tarball-run\",\n" &
    "      source = \"src/input.txt\",\n" &
    "      output = \"build/tarball-output.txt\")\n" &
    "    defaultBuildAction(produced)\n")

suite "m54_verified_tarball_profile":
  test "m54_verified_tarball_profile_e2e":
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m54-tarball", "")
    defer: removeDir(tempRoot)

    let reproBin = tempRoot / "repro"
    discard requireSuccess(shellCommand([
      "nim", "c", "--verbosity:0", "--hints:off",
      "--nimcache:" & (tempRoot / "nimcache-repro"),
      "--out:" & reproBin,
      repoRoot / "apps" / "repro" / "repro.nim"
    ]), repoRoot)

    var daemon = ensureRunQuotaDaemon(repoRoot)
    defer:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
      if pathExists(daemon.socket):
        removeFile(daemon.socket)

    let archive = writeToolArchive(tempRoot)
    let corruptArchive = tempRoot / "m54tool-corrupt.tar.gz"
    writeFile(corruptArchive, "corrupt archive bytes")

    let projectRoot = tempRoot / "project"
    let brokenPrimary = "file://" & (tempRoot / "missing-primary.tar.gz")
    let goodMirror = "file://" & archive.archivePath
    writeProject(projectRoot, brokenPrimary, goodMirror, archive.sha256)

    let first = requireSuccess(shellCommand([reproBin, "build", projectRoot,
      "--tool-provisioning=tarball", "--log=actions"]), repoRoot)
    check first.contains("tool-provisioning=tarball")
    check first.contains("cachePortability: portable")
    check first.contains("action: tarball-run status=asSucceeded launched=true")
    check readFile(projectRoot / "build" / "tarball-output.txt") ==
      "m54:fixture-input\n"

    let interfaceArtifact = readInterfaceArtifact(valueAfter(first, "interface:"))
    check interfaceArtifact.projectInterface.toolUses.len == 1
    check interfaceArtifact.projectInterface.toolUses[0].tarballProvisioning.len == 1
    check interfaceArtifact.projectInterface.toolUses[0].tarballProvisioning[0].
      sha256 == archive.sha256

    let identityPath = valueAfter(first, "toolIdentity:")
    let inspectionPath = valueAfter(first, "inspection:")
    check identityPath.endsWith("tarball-tool-identities.rbtp")
    check readFile(identityPath)[0 .. 3] == "RBTP"
    let identity = readPathOnlyBuildIdentity(identityPath)
    check identity.profiles.len == 1
    let profile = identity.profiles[0]
    check profile.installMethod == "tarball"
    check profile.adapterStrength == asStrong
    check profile.cachePortability == cpPortable
    check profile.tarballUrl == brokenPrimary
    check profile.tarballMirrors == @[goodMirror]
    check profile.tarballSelectedUrl == goodMirror
    check profile.tarballSha256 == archive.sha256
    check profile.archiveType == "tar.gz"
    check profile.stripComponents == 1
    check profile.declaredExecutablePath == "bin/m54tool"
    check profile.resolvedExecutablePath.endsWith("/bin/m54tool")
    check profile.probes.len == 1
    check profile.probes[0].output.contains("m54tool 1.0.0")
    check fileExists(profile.selectedStorePath /
      ".reprobuild-tarball-receipt.json")

    let inspection = parseFile(inspectionPath)
    check inspection{"profiles"}[0]{"installMethod"}.getStr() == "tarball"
    check inspection{"profiles"}[0]{"tarballSelectedUrl"}.getStr() == goodMirror
    check inspection{"profiles"}[0]{"resolvedExecutablePath"}.getStr() ==
      profile.resolvedExecutablePath

    let prefixInfo = getFileInfo(profile.selectedStorePath)
    let second = requireSuccess(shellCommand([reproBin, "build", projectRoot,
      "--tool-provisioning=tarball", "--log=actions"]), repoRoot)
    if not actionLineCacheEffective(second, "tarball-run"):
      checkpoint(second)
    check actionLineCacheEffective(second, "tarball-run")
    let secondIdentity = readPathOnlyBuildIdentity(valueAfter(second,
      "toolIdentity:"))
    check secondIdentity.profiles[0].selectedStorePath == profile.selectedStorePath
    check secondIdentity.profiles[0].tarballSelectedUrl == goodMirror
    check secondIdentity.profiles[0].profileFingerprint == profile.profileFingerprint
    check getFileInfo(profile.selectedStorePath).lastWriteTime ==
      prefixInfo.lastWriteTime

    let corruptRoot = tempRoot / "corrupt-project"
    writeProject(corruptRoot, "file://" & (tempRoot / "missing-corrupt.tar.gz"),
      "file://" & corruptArchive, archive.sha256)
    let corrupt = requireFailure(shellCommand([reproBin, "build", corruptRoot,
      "--tool-provisioning=tarball"]), repoRoot)
    check corrupt.contains("sha256 mismatch")
    check not fileExists(corruptRoot / "build" / "tarball-output.txt")

    let unsafeRoot = tempRoot / "unsafe-project"
    writeProject(unsafeRoot, brokenPrimary, goodMirror, archive.sha256,
      executablePath = "bin/../../m54tool")
    let unsafe = requireFailure(shellCommand([reproBin, "build", unsafeRoot,
      "--tool-provisioning=tarball"]), repoRoot)
    check unsafe.contains("tarball executablePath must be relative")
    check not fileExists(unsafeRoot / "build" / "tarball-output.txt")
