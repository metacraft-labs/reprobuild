## Rollback removes and updates must compare resource observations with the
## CURRENT generation before any write. Real CLI, compiled profiles and files;
## the package-source seam only avoids unrelated package realization, as in
## the other home rollback gates. No resource driver is mocked.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  result = getEnv("REPRO_TEST_HOME_ROLLBACK_BINARY",
    ProjectRoot / "build" / "bin" / exeName)
  doAssert fileExists(result),
    "repro binary not found at " & result & "; build with `just build` first"

proc writeFixtureExe(path: string) =
  when defined(windows):
    writeFile(path, "@echo off\r\nexit /b 0\r\n")
  else:
    writeFile(path, "#!/bin/sh\nexit 0\n")
    setFilePermissions(path, {fpUserExec, fpUserWrite, fpUserRead})

const
  Foreign = "the user's own content\n"
  Current = "from-b\n"
  Target = "from-a\n"
  ProfilePrefix = """
import repro_profile

profile "rollback-resource-drift":
  activity default:
    `pkg-x`
"""

type Sandbox = object
  root, stateDir, storeRoot, profileDir, homeDir, source: string

proc newSandbox(): Sandbox =
  result.root = createTempDir("repro-rollback-resource-drift-", "")
  result.stateDir = result.root / "state"
  result.storeRoot = result.root / "store"
  result.profileDir = result.root / "profile"
  result.homeDir = result.root / "home"
  for d in [result.stateDir, result.storeRoot, result.profileDir, result.homeDir]:
    createDir(d)
  result.source = result.root / (when defined(windows): "pkg-x.cmd" else: "pkg-x")
  writeFixtureExe(result.source)

proc run(sb: Sandbox; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): env[k] = v
  env["REPRO_HOME_ROLLBACK_ACCEPT_OVERWRITE"] = ""
  env["REPRO_HOME_PROFILE_DIR"] = sb.profileDir
  env["REPRO_HOME_STATE_DIR"] = sb.stateDir
  env["REPRO_STORE_ROOT"] = sb.storeRoot
  env["HOME"] = sb.homeDir
  env["USERPROFILE"] = sb.homeDir
  env["REPRO_HOST"] = "rollback-resource-drift-host"
  env["REPRO_TEST_PACKAGE_SOURCE"] = "pkg-x=" & sb.source
  env["REPRO_HOME_PACKAGE_CATALOG"] = "pkg-x"
  env["REPRO_TEST_PACKAGE_GENERATES"] = ""
  env["REPRO_TEST_PACKAGE_MANAGED_BLOCKS"] = ""
  let p = startProcess(reproBinary(), args = @args, env = env,
    options = {poUsePath, poStdErrToStdOut})
  result.output = p.outputStream().readAll()
  result.exitCode = p.waitForExit()
  p.close()

proc apply(sb: Sandbox; content: string) =
  var profile = ProfilePrefix
  if content.len > 0:
    # Rollback sorts resource addresses. Put the clean resource first so a
    # per-operation check would change it before discovering the user's edit.
    profile.add "\n  resources:\n    fsUserFile(hostFile = \"~/.marker\", content = \"" &
      content.replace("\n", "\\n") & "\", address = \"z-drift-marker\")\n"
    profile.add "    fsUserFile(hostFile = \"~/.other-marker\", content = \"other-" &
      content.replace("\n", "\\n") & "\", address = \"a-other-marker\")\n"
  writeFile(sb.profileDir / "home.nim", profile)
  let applied = sb.run(["home", "apply"])
  doAssert applied.exitCode == 0, applied.output

proc twoGenerations(sb: Sandbox; updating: bool): tuple[a, b: string] =
  sb.apply(if updating: Target else: "")
  result.a = readCurrentGenerationId(sb.stateDir)
  sb.apply(Current)
  result.b = readCurrentGenerationId(sb.stateDir)
  doAssert result.a != result.b
  doAssert readFile(sb.homeDir / ".marker") == Current

proc checkTarget(sb: Sandbox; updating: bool) =
  if updating:
    check readFile(sb.homeDir / ".marker") == Target
  else:
    check not fileExists(sb.homeDir / ".marker")

suite "rollback current resources respect drift":
  test "remove and update refuse user edits before changing the generation":
    for updating in [false, true]:
      let sb = newSandbox()
      defer: removeDir(sb.root)
      let gens = sb.twoGenerations(updating)
      writeFile(sb.homeDir / ".marker", Foreign)
      let refused = sb.run(["home", "rollback"])
      checkpoint refused.output
      check refused.exitCode != 0
      check "user edit detected" in refused.output
      check "--accept-overwrite" in refused.output
      check "marker" in refused.output
      check fileExists(sb.homeDir / ".marker")
      if fileExists(sb.homeDir / ".marker"):
        check readFile(sb.homeDir / ".marker") == Foreign
      check readCurrentGenerationId(sb.stateDir) == gens.b
      check fileExists(sb.homeDir / ".other-marker")
      if fileExists(sb.homeDir / ".other-marker"):
        check readFile(sb.homeDir / ".other-marker") == "other-" & Current

  test "accept-overwrite explicitly permits remove and update of user edits":
    for updating in [false, true]:
      let sb = newSandbox()
      defer: removeDir(sb.root)
      let gens = sb.twoGenerations(updating)
      writeFile(sb.homeDir / ".marker", Foreign)
      let accepted = sb.run(["home", "rollback", "--accept-overwrite"])
      checkpoint accepted.output
      check accepted.exitCode == 0
      check "drift detected at resource:" in accepted.output
      check "marker" in accepted.output
      check "clobbered under --accept-overwrite" in accepted.output
      check readCurrentGenerationId(sb.stateDir) == gens.a
      sb.checkTarget(updating)

  test "unchanged current resources permit remove and update":
    for updating in [false, true]:
      let sb = newSandbox()
      defer: removeDir(sb.root)
      let gens = sb.twoGenerations(updating)
      let rolled = sb.run(["home", "rollback"])
      checkpoint rolled.output
      check rolled.exitCode == 0
      check readCurrentGenerationId(sb.stateDir) == gens.a
      sb.checkTarget(updating)

  test "absent current resources permit remove and update":
    for updating in [false, true]:
      let sb = newSandbox()
      defer: removeDir(sb.root)
      let gens = sb.twoGenerations(updating)
      removeFile(sb.homeDir / ".marker")
      let rolled = sb.run(["home", "rollback"])
      checkpoint rolled.output
      check rolled.exitCode == 0
      check readCurrentGenerationId(sb.stateDir) == gens.a
      sb.checkTarget(updating)
