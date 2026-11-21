## Existing MSVC facility data is merged below caller/recipe choices.
##
## No platform discovery is mocked: the pure boundary consumes literal
## VsDevCmd-shaped environment data, as test_msvc_env_merge does. This lets
## non-Windows hosts check precedence, inactive tools and the x64-only limit
## without installing proprietary tools or claiming native MSVC acceptance.
## The child control uses a real executable and environment, not a fake driver.
import std/[os, osproc, streams, strtabs, strutils, tables, unittest]
import repro_dev_env_activation
import repro_dev_env_artifacts
import repro_platform
import repro_provider_runtime/types

const
  VcBin = r"C:\BuildTools\VC\Tools\MSVC\14.44\bin\HostX64\x64"
  Linker = VcBin & r"\link.exe"
  LinkerVariable = "CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER"

if commandLineParams() == @["--observe-msvc-env"]:
  echo getEnv("CC")
  echo getEnv(LinkerVariable)
  quit(0)

proc facility(): MsvcDevEnv =
  var env = initTable[string, string]()
  env["VCToolsInstallDir"] = r"C:\BuildTools\VC\Tools\MSVC\14.44"
  env["PATH"] = VcBin
  env["CC"] = "cl.exe"
  env[LinkerVariable] = Linker
  MsvcDevEnv(available: true, env: env)

proc artifact(tool: string): DevEnvArtifact =
  DevEnvArtifact(toolProfiles: @[DevEnvToolProfileRef(logicalName: tool)])

suite "development environment MSVC facility activation":
  test "a declared consumer gains the existing compiler and absolute linker":
    let env = newStringTable(modeCaseInsensitive)
    env["PATH"] = r"C:\Git\usr\bin"
    let merged = mergeDevEnvWithMsvcEnv(artifact("cargo"), env, facility(), "amd64")
    check merged["CC"] == "cl.exe"
    check merged[LinkerVariable] == Linker
    check merged["PATH"].startsWith(env["PATH"] & ";")
    check VcBin in merged["PATH"]
    check not env.hasKey("CC")

  test "final recipe PATH replacement keeps MSVC tools and explicit choices":
    let env = newStringTable(modeCaseInsensitive)
    env["CC"] = "gcc.exe"
    env["CXX"] = "g++.exe"
    env[LinkerVariable] = r"D:\chosen\link.exe"
    let caller = mergeDevEnvWithMsvcEnv(artifact("rustc"), env, facility(), "amd64")
    check caller["CC"] == "gcc.exe"
    check caller["CXX"] == "g++.exe"
    check caller[LinkerVariable] == r"D:\chosen\link.exe"
    var cwd = ""
    env.applyShellOp(DevEnvShellOp(kind: deskSetEnv, name: "PATH",
      value: r"D:\recipe\bin"), cwd)
    env.applyShellOp(DevEnvShellOp(kind: deskSetEnv, name: "CC",
      value: "recipe-gcc.exe"), cwd)
    env.applyShellOp(DevEnvShellOp(kind: deskSetEnv, name: LinkerVariable,
      value: "recipe-link.exe"), cwd)
    let merged = mergeDevEnvWithMsvcEnv(artifact("rustc"), env, facility(), "amd64")
    check merged["CC"] == "recipe-gcc.exe"
    check merged["CXX"] == "g++.exe"
    check merged[LinkerVariable] == "recipe-link.exe"
    check merged["PATH"] == r"D:\recipe\bin" & ";" & VcBin

  test "MinGW-only and inactive consumers get no MSVC environment":
    let env = newStringTable(modeCaseInsensitive)
    env["PATH"] = r"C:\MinGW\bin"
    for tool in ["nim", "gcc", "go", "python3"]:
      let merged = mergeDevEnvWithMsvcEnv(artifact(tool), env, facility(), "amd64")
      check merged["PATH"] == env["PATH"]
      check not merged.hasKey("CC")
      check not merged.hasKey(LinkerVariable)
    var inactive = artifact("cargo")
    inactive.toolProfiles[0].activityRequirements = @["rust-tools"]
    let merged = mergeDevEnvWithMsvcEnv(inactive, env, facility(), "amd64")
    check not merged.hasKey("CC")
    inactive.selectedActivities = @["rust-tools"]
    check mergeDevEnvWithMsvcEnv(inactive, env, facility(), "amd64")["CC"] == "cl.exe"

  test "the existing x64 facility is not silently used for native ARM":
    let env = newStringTable(modeCaseInsensitive)
    let merged = mergeDevEnvWithMsvcEnv(artifact("cargo"), env, facility(), "arm64")
    check not merged.hasKey("CC")
    check not merged.hasKey(LinkerVariable)

  test "an unavailable facility does not fabricate compiler availability":
    let env = newStringTable(modeCaseInsensitive)
    env["PATH"] = r"C:\Git\usr\bin"
    let merged = mergeDevEnvWithMsvcEnv(artifact("cargo"), env,
      MsvcDevEnv(available: false), "amd64")
    check merged["PATH"] == env["PATH"]
    check not merged.hasKey("CC")
    check not merged.hasKey(LinkerVariable)

  test "the real child receives the merged compiler and linker values":
    let environment = newStringTable(modeCaseInsensitive)
    for key, value in envPairs():
      environment[key] = value
    environment.del("CC")
    environment.del(LinkerVariable)
    let merged = mergeDevEnvWithMsvcEnv(artifact("cargo"),
      environment, facility(), "amd64")
    let child = startProcess(getAppFilename(), args = @["--observe-msvc-env"],
      env = merged, options = {poStdErrToStdOut})
    let output = child.outputStream.readAll().replace("\r\n", "\n")
    let exitCode = child.waitForExit()
    child.close()
    check exitCode == 0
    check output == "cl.exe\n" & Linker & "\n"
