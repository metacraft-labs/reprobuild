import std/[json, os, osproc, sequtils, strtabs, streams, strutils, tempfiles,
    unittest]

import repro_test_support

proc compileNim(repoRoot, sourcePath, outputPath, cacheName: string;
                appLib = false) =
  var args = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--nimcache:" & repoRoot / "build" / "nimcache" / cacheName,
    "--out:" & outputPath
  ]
  if appLib:
    args.insert("--app:lib", 2)
  args.add(sourcePath)
  discard requireSuccess(shellCommand(args), repoRoot)

when isFsSnoopSupported:
  proc prepareMonitorTools(repoRoot, tempRoot: string):
      tuple[fsSnoop: string; shim: string] =
    let binDir = tempRoot / "bin"
    let libDir = tempRoot / "lib"
    createDir(binDir)
    createDir(libDir)
    result.fsSnoop = binDir / "repro-fs-snoop"
    result.shim =
      when defined(linux):
        libDir / "librepro_monitor_shim.so"
      else:
        libDir / "librepro_monitor_shim.dylib"
    let shimSource =
      when defined(linux):
        repoRoot / "libs" / "repro_monitor_shim" / "src" /
          "repro_monitor_shim" / "linux_preload.nim"
      else:
        repoRoot / "libs" / "repro_monitor_shim" / "src" /
          "repro_monitor_shim" / "macos_interpose.nim"
    compileNim(repoRoot, shimSource, result.shim, "m9-dev-env-monitor-shim",
      appLib = true)
    compileNim(repoRoot,
      repoRoot / "apps" / "repro-fs-snoop" / "repro_fs_snoop.nim",
      result.fsSnoop, "m9-dev-env-fs-snoop")

proc compileRepro(repoRoot, tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  compileNim(repoRoot, repoRoot / "apps" / "repro" / "repro.nim",
    result, "m9-dev-env-repro")

proc providerText(modeValue, toolCommand: string): string =
  "import std/strutils\n" &
    "import repro_project_dsl\n\n" &
    "package fixture:\n" &
    "  uses:\n" &
    "    \"nim >=2.2 <3.0\"\n" &
    "  devEnv:\n" &
    "    activity \"default\"\n" &
    "    setEnv \"PERF_MODE\", \"" & modeValue & "\"\n" &
    "    setEnv \"AUX_VALUE\", readDevEnvFile(\"dev-env-value.txt\").strip()\n" &
    "    prependPath \"PATH\", \"tools/bin\"\n" &
    "    task \"bench\", command = \"" & toolCommand & "\", description = \"Bench fixture\"\n" &
    "    diagnostic \"dev env ready\"\n"

proc writeProvider(projectRoot, modeValue, toolCommand: string) =
  writeFile(projectRoot / "reprobuild.nim", providerText(modeValue,
    toolCommand))

proc writeFixture(dir: string) =
  createDir(dir)
  createDir(dir / "tools" / "bin")
  writeFile(dir / "dev-env-value.txt", "alpha\n")
  writeProvider(dir, "initial", "fixture-tool --bench")
  let toolPath = dir / "tools" / "bin" / "fixture-tool"
  writeFile(toolPath,
    "#!/bin/sh\n" &
    "printf 'tool:%s:%s:%s\\n' \"$AUX_VALUE\" \"$PERF_MODE\" \"$REPRO_DEV_ENV_TASKS\"\n")
  setFilePermissions(toolPath, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

type
  M9Case = object
    tempRoot: string
    projectRoot: string
    repoRoot: string
    reproBin: string
    fsSnoop: string
    shim: string

proc prepareCase(prefix: string): M9Case =
  result.repoRoot = getCurrentDir()
  result.tempRoot = createTempDir(prefix, "")
  result.projectRoot = result.tempRoot / "project"
  writeFixture(result.projectRoot)
  result.reproBin = compileRepro(result.repoRoot, result.tempRoot)
  when isFsSnoopSupported:
    let monitor = prepareMonitorTools(result.repoRoot, result.tempRoot)
    result.fsSnoop = monitor.fsSnoop
    result.shim = monitor.shim

proc envFor(c: M9Case): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  result["REPRO_MONITOR_SHIM_LIB"] = c.shim
  result["REPRO_FS_SNOOP"] = c.fsSnoop
  result["PATH"] = parentDir(c.reproBin) & $PathSep & getEnv("PATH")

proc runProgram(program: string; args: openArray[string]; cwd: string;
                env: StringTableRef = nil): tuple[exitCode: int; output: string] =
  var process = startProcess(program,
    args = @args,
    workingDir = cwd,
    env = env,
    options = {poUsePath, poStdErrToStdOut})
  let output =
    if process.outputStream != nil: process.outputStream.readAll()
    else: ""
  let exitCode = process.waitForExit()
  process.close()
  (exitCode: exitCode, output: output)

proc runRepro(c: M9Case; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  runProgram(c.reproBin, args, c.repoRoot, c.envFor())

proc requireRepro(c: M9Case; args: openArray[string]): string =
  let res = runRepro(c, args)
  if res.exitCode != 0:
    raise newException(OSError,
      "repro command failed with exit " & $res.exitCode & ": " &
        args.join(" ") & "\n" & res.output)
  res.output

proc activateWithStats(c: M9Case; statsPath: string): JsonNode =
  let output = requireRepro(c, @[
    "__repro-direnv-activate", c.projectRoot,
    "--dev-env-stats=" & statsPath
  ])
  check output.contains("AUX_VALUE")
  check output.contains("PERF_MODE")
  parseJson(readFile(statsPath))

proc metricCount(stats: JsonNode; name: string): int =
  for item in stats["metrics"]:
    if item["name"].getStr() == name:
      return item["count"].getInt()

proc requirePerformanceEnvelope(stats: JsonNode) =
  check stats["schemaId"].getStr() == "reprobuild.dev-env.cli-stats.v1"
  check stats["performance"]["schemaId"].getStr() ==
    "reprobuild.dev-env.performance-evidence.v1"
  check stats["performance"]["artifactLookup"]["artifactBytes"].getBiggestInt() > 0
  check stats["performance"]["providerIntrospection"]["actions"].getInt() == 1
  check stats["performance"]["invalidation"]["fastNoopScanCount"].getInt() >= 1
  check stats["performance"]["shellRender"]["actions"].getInt() == 1
  check stats["performance"]["shellRender"]["shellFragmentBytes"].getBiggestInt() > 0
  check stats["devEnvRunStats"].metricCount("repro cache lookup") >= 0

proc requireNoopActivationStats(stats: JsonNode) =
  requirePerformanceEnvelope(stats)
  check not stats["stats"]["providerBuildLaunched"].getBool()
  check stats["stats"]["providerBuildSkippedFresh"].getBool()
  check not stats["stats"]["providerIntrospectionLaunched"].getBool()
  check stats["stats"]["providerIntrospectionCacheHit"].getBool()
  check stats["stats"]["artifactWriteSkipped"].getBool()
  check not stats["stats"]["shellRenderingLaunched"].getBool()
  check stats["stats"]["shellRenderingCacheHit"].getBool()
  let perf = stats["performance"]
  check perf["providerIntrospection"]["launched"].getBool() == false
  check perf["providerIntrospection"]["cacheHit"].getBool()
  check perf["artifactLookup"]["introspectionCacheHit"].getBool()
  check perf["invalidation"]["cacheLookupCount"].getInt() >= 1
  check perf["invalidation"]["hotInputScanCount"].getInt() >= 1
  check perf["invalidation"]["checkedInputPathCount"].getInt() >= 2

proc requireObservedInputRerunStats(stats: JsonNode) =
  requirePerformanceEnvelope(stats)
  check stats["stats"]["providerBuildSkippedFresh"].getBool()
  check not stats["stats"]["providerBuildLaunched"].getBool()
  check stats["stats"]["providerIntrospectionLaunched"].getBool()
  check stats["stats"]["artifactWriteLaunched"].getBool()
  check stats["stats"]["shellRenderingLaunched"].getBool()
  let perf = stats["performance"]
  check perf["providerIntrospection"]["launched"].getBool()
  check perf["providerIntrospection"]["monitorReadCount"].getInt() >= 1
  check perf["invalidation"]["cacheLookupCount"].getInt() >= 1

proc requireProviderSourceRerunStats(stats: JsonNode) =
  requirePerformanceEnvelope(stats)
  check stats["stats"]["providerBuildLaunched"].getBool()
  check stats["stats"]["providerIntrospectionLaunched"].getBool()
  check stats["stats"]["artifactWriteLaunched"].getBool()
  let perf = stats["performance"]
  check perf["providerBuild"]["launched"].getBool()
  check perf["providerBuild"]["actionPresent"].getBool()
  check perf["providerIntrospection"]["declaredInputCount"].getInt() >= 2

suite "e2e_dev_env_performance_gates":
  when isFsSnoopSupported:
    test "benchmark_dev_env_activation_noop":
      let c = prepareCase("repro-m9-dev-env-perf")
      defer: removeDir(c.tempRoot)

      let first = activateWithStats(c, c.tempRoot / "first-stats.json")
      requirePerformanceEnvelope(first)
      check first["stats"]["providerIntrospectionLaunched"].getBool()
      check first["stats"]["shellRenderingLaunched"].getBool()
      let artifactPath = first["artifactPath"].getStr()
      let shellFragmentPath = first["shellFragmentPath"].getStr()
      let firstArtifactBytes = readFile(artifactPath)

      let noop = activateWithStats(c, c.tempRoot / "noop-stats.json")
      requireNoopActivationStats(noop)
      check noop["artifactPath"].getStr() == artifactPath
      check noop["shellFragmentPath"].getStr() == shellFragmentPath
      check readFile(artifactPath) == firstArtifactBytes

    test "benchmark_dev_env_activation_changed_inputs":
      let c = prepareCase("repro-m9-dev-env-changes")
      defer: removeDir(c.tempRoot)

      discard activateWithStats(c, c.tempRoot / "first-stats.json")
      sleep(100)
      writeFile(c.projectRoot / "dev-env-value.txt", "bravo\n")
      let observed = activateWithStats(c, c.tempRoot / "observed-stats.json")
      requireObservedInputRerunStats(observed)
      check readFile(observed["shellFragmentPath"].getStr()).contains("bravo")

      sleep(100)
      writeProvider(c.projectRoot, "provider_changed",
        "fixture-tool --bench --provider")
      let provider = activateWithStats(c, c.tempRoot / "provider-stats.json")
      requireProviderSourceRerunStats(provider)
      check readFile(provider["shellFragmentPath"].getStr()).contains(
        "provider_changed")
