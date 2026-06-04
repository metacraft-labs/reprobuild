import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_tool_profiles

import repro_test_support

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc runShell(command: openArray[string]; cwd = getCurrentDir();
              pathValue = getEnv("PATH")): tuple[code: int; output: string] =
  let shellCommand = "PATH=" & q(pathValue) & " " & command.mapIt(q(it)).join(" ")
  let res = execCmdEx(shellCommand, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: openArray[string]; cwd = getCurrentDir();
                    pathValue = getEnv("PATH")): string =
  let res = runShell(command, cwd, pathValue)
  if res.code != 0:
    checkpoint(res.output)
  check res.code == 0
  res.output

proc requireFailure(command: openArray[string]; cwd = getCurrentDir();
                    pathValue = getEnv("PATH")): string =
  let res = runShell(command, cwd, pathValue)
  check res.code != 0
  res.output

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc writeFixtureTool(binDir: string) =
  createDir(binDir)
  let toolPath = binDir / "m8-fixture-tool"
  writeFile(toolPath,
    "#!/bin/sh\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then\n" &
    "  echo probe >> \"$0.probes\"\n" &
    "  echo 'm8-fixture-tool 1.0.0'\n" &
    "  exit 0\n" &
    "fi\n" &
    "echo 'fixture tool executed'\n")
  setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

suite "e2e_path_only_tool_interfaces":
  when isNixSupported:
    test "configured probes use tool-specific version flags":
      let defaultProbes = configuredProbes("m8-fixture-tool",
        "m8-fixture-tool")
      check defaultProbes.len == 1
      check defaultProbes[0].args == @["--version"]

      let tmuxProbes = configuredProbes("tmux", "tmux")
      check tmuxProbes.len == 1
      check tmuxProbes[0].args == @["-V"]

      let xvfbRunProbes = configuredProbes("xvfb-run", "xvfb-run")
      check xvfbRunProbes.len == 1
      check xvfbRunProbes[0].name == "help"
      check xvfbRunProbes[0].args == @["--help"]

    test "public build command resolves typed uses from explicit PATH-only mode":
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-m8-path-only", "")
      defer: removeDir(tempRoot)

      let reproBin = tempRoot / "repro"
      discard requireSuccess(@["nim", "c", "--verbosity:0", "--hints:off",
        "--nimcache:" & (tempRoot / "nimcache-repro"),
        "--out:" & reproBin, repoRoot / "apps" / "repro" / "repro.nim"])

      let binDir = tempRoot / "bin"
      writeFixtureTool(binDir)
      let pathValue = binDir & $PathSep & getEnv("PATH")
      let sourceFixture = repoRoot / "tests" / "fixtures" / "path-only"
      let fixtureRoot = tempRoot / "fixtures" / "path-only"
      createDir(fixtureRoot)
      copyFile(sourceFixture / "ok.nim", fixtureRoot / "ok.nim")
      copyFile(sourceFixture / "missing.nim", fixtureRoot / "missing.nim")
      let target = fixtureRoot & "#ok"

      let okOutput = requireSuccess(@[reproBin, "build", target,
        "--tool-provisioning=path", "--log=actions"], repoRoot, pathValue)
      check okOutput.contains("provisioning-disabled mode active")
      check okOutput.contains("cachePortability: local-only")

      let identityPath = valueAfter(okOutput, "toolIdentity:")
      let inspectionPath = valueAfter(okOutput, "inspection:")
      check fileExists(identityPath)
      check fileExists(inspectionPath)
      check readFile(identityPath)[0 .. 3] == "RBTP"
      check readFile(identityPath)[0] != '{'

      let identity = readPathOnlyBuildIdentity(identityPath)
      check identity.projectName == "pathOnlyOk"
      check identity.profiles.len == 1
      check identity.actionIdentities.len == 1
      check identity.profiles[0].installMethod == "path"
      check identity.profiles[0].packageSelector == "m8-fixture-tool"
      check identity.profiles[0].executableName == "m8-fixture-tool"
      check identity.profiles[0].pathSearchList[0] == binDir
      check identity.profiles[0].resolvedExecutablePath == binDir / "m8-fixture-tool"
      check identity.profiles[0].adapterStrength == asWeak
      check identity.profiles[0].cachePortability == cpLocalOnly
      check identity.profiles[0].probes.len == 1
      check identity.profiles[0].probes[0].spec.name == "version"
      check identity.profiles[0].probes[0].output.contains("m8-fixture-tool 1.0.0")
      check readFile(binDir / "m8-fixture-tool.probes").splitLines.
        filterIt(it.len > 0).len == 1
      check identity.actionIdentities[0].pathSearchList == identity.profiles[0].
        pathSearchList
      check identity.actionIdentities[0].resolvedExecutablePath ==
        identity.profiles[0].resolvedExecutablePath
      check identity.actionIdentities[0].cachePortability == cpLocalOnly
      check readFile(inspectionPath).contains("\"installMethod\": \"path\"")
      check readFile(inspectionPath).contains("\"adapterStrength\": \"weak\"")
      check readFile(inspectionPath).contains("\"cachePortability\": \"local-only\"")

      let cachedOutput = requireSuccess(@[reproBin, "build", target,
        "--tool-provisioning=path", "--log=actions"], repoRoot, pathValue)
      let cachedIdentity = readPathOnlyBuildIdentity(
        valueAfter(cachedOutput, "toolIdentity:"))
      check cachedIdentity.actionIdentities[0].actionFingerprint ==
        identity.actionIdentities[0].actionFingerprint
      check readFile(binDir / "m8-fixture-tool.probes").splitLines.
        filterIt(it.len > 0).len == 1

      let extraDir = tempRoot / "extra-path-entry"
      createDir(extraDir)
      let changedPathValue = pathValue & $PathSep & extraDir
      let changedOutput = requireSuccess(@[reproBin, "build", target,
        "--tool-provisioning=path", "--log=actions"], repoRoot, changedPathValue)
      let changedIdentity = readPathOnlyBuildIdentity(
        valueAfter(changedOutput, "toolIdentity:"))
      check changedIdentity.profiles[0].resolvedExecutablePath ==
        identity.profiles[0].resolvedExecutablePath
      check changedIdentity.actionIdentities[0].actionFingerprint !=
        identity.actionIdentities[0].actionFingerprint
      check readFile(binDir / "m8-fixture-tool.probes").splitLines.
        filterIt(it.len > 0).len == 2

      let noFlagOutput = requireFailure(@[reproBin, "build", target], repoRoot,
        pathValue)
      check noFlagOutput.contains("refusing implicit PATH fallback")

      let missingTarget = fixtureRoot & "#missing"
      let missingOutput = requireFailure(@[reproBin, "build", missingTarget,
        "--tool-provisioning=path"], repoRoot, pathValue)
      check missingOutput.contains("tool-resolution failed")
      check missingOutput.contains("m8-missing-tool")
