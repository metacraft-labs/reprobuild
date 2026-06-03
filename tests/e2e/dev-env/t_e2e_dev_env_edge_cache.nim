import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_dev_env_artifacts
import repro_build_engine
import repro_dev_env_engine
import repro_provider_runtime
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

when defined(linux) or defined(macosx):
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
    compileNim(repoRoot, shimSource, result.shim, "m3-dev-env-monitor-shim",
      appLib = true)
    compileNim(repoRoot,
      repoRoot / "apps" / "repro-fs-snoop" / "repro_fs_snoop.nim",
      result.fsSnoop, "m3-dev-env-fs-snoop")

proc compileRepro(repoRoot, tempRoot: string): string =
  result = tempRoot / "repro"
  compileNim(repoRoot, repoRoot / "apps" / "repro" / "repro.nim",
    result, "m3-dev-env-repro")

proc providerText(modeValue, taskCommand: string): string =
  "import std/strutils\n" &
    "import repro_project_dsl\n\n" &
    "package fixture:\n" &
    "  uses:\n" &
    "    \"nim >=2.2 <3.0\"\n" &
    "  devEnv:\n" &
    "    activity \"default\"\n" &
    "    setEnv \"FIXTURE_MODE\", \"" & modeValue & "\"\n" &
    "    setEnv \"AUX_VALUE\", readDevEnvFile(\"dev-env-value.txt\").strip()\n" &
    "    prependPath \"PATH\", \"tools/bin\"\n" &
    "    task \"build\", command = \"" & taskCommand & "\", description = \"Build fixture\"\n" &
    "    diagnostic \"dev env ready\"\n"

proc writeFixture(dir: string; modeValue = "dev";
                  taskCommand = "nim c src/main.nim") =
  createDir(dir)
  createDir(dir / "src")
  createDir(dir / "tools" / "bin")
  writeFile(dir / "dev-env-value.txt", "alpha\n")
  writeFile(dir / "src" / "main.nim", "echo \"fixture\"\n")
  writeFile(dir / "fixture_provider.nim", providerText(modeValue,
    taskCommand))

proc configFor(projectRoot, outDir, reproBin, fsSnoop, shim,
               repoRoot: string): DevEnvEdgeConfig =
  DevEnvEdgeConfig(
    modulePath: projectRoot / "fixture_provider.nim",
    projectRoot: projectRoot,
    outDir: outDir,
    workDir: repoRoot,
    publicCliPath: reproBin,
    monitorCliPath: fsSnoop,
    monitorShimLibPath: shim,
    activity: "default",
    lockSliceId: "lock-m3",
    renderShell: true,
    statsEnabled: true)

proc findShellOp(ops: openArray[DevEnvShellOp]; name: string): DevEnvShellOp =
  for op in ops:
    if op.name == name:
      return op
  raise newException(ValueError, "missing shell op " & name)

proc artifactShellOp(path, name: string): DevEnvShellOp =
  readDevEnvArtifact(path).shellOps.findShellOp(name)

proc readBytes(path: string): string =
  readFile(path)

proc observedInputEndsWith(edge: DevEnvEdgeResult; suffix: string): bool =
  for path in edge.introspectionAction.evidence.monitorReads:
    if path.replace('\\', '/').endsWith(suffix):
      return true
  for path in edge.introspectionAction.evidence.monitorProbes:
    if path.replace('\\', '/').endsWith(suffix):
      return true
  for path in edge.introspectionAction.evidence.depfileInputs:
    if path.replace('\\', '/').endsWith(suffix):
      return true

proc dumpIntrospectionEvidence(edge: DevEnvEdgeResult) =
  echo "declaredInputs=", edge.introspectionAction.evidence.declaredInputs.join("|")
  echo "depfileInputs=", edge.introspectionAction.evidence.depfileInputs.join("|")
  echo "monitorReads=", edge.introspectionAction.evidence.monitorReads.join("|")
  echo "monitorWrites=", edge.introspectionAction.evidence.monitorWrites.join("|")
  echo "monitorProbes=", edge.introspectionAction.evidence.monitorProbes.join("|")

proc prepareCase(prefix: string): tuple[tempRoot, projectRoot, outDir,
    reproBin, fsSnoop, shim, repoRoot: string] =
  result.repoRoot = getCurrentDir()
  result.tempRoot = createTempDir(prefix, "")
  result.projectRoot = result.tempRoot / "project"
  result.outDir = result.tempRoot / "out"
  writeFixture(result.projectRoot)
  createDir(result.outDir)
  result.reproBin = compileRepro(result.repoRoot, result.tempRoot)
  when defined(linux) or defined(macosx):
    let monitor = prepareMonitorTools(result.repoRoot,
      result.tempRoot / "monitor")
    result.fsSnoop = monitor.fsSnoop
    result.shim = monitor.shim
  else:
    raise newException(OSError,
      "dev-env monitored edge tests require fs-snoop support")

suite "e2e_dev_env_edge_cache":
  test "e2e_dev_env_edge_noop_reuses_cached_artifact":
    let c = prepareCase("repro-m3-dev-env-noop")
    defer: removeDir(c.tempRoot)
    let cfg = configFor(c.projectRoot, c.outDir, c.reproBin, c.fsSnoop,
      c.shim, c.repoRoot)

    let first = computeDevEnvEdge(cfg)
    let firstBytes = first.artifactPath.readBytes()
    check first.stats.providerIntrospectionLaunched
    check first.stats.artifactWriteLaunched
    check first.stats.shellRenderingLaunched
    check first.artifactPath.artifactShellOp("AUX_VALUE").value == "alpha"
    if not first.observedInputEndsWith("dev-env-value.txt"):
      first.dumpIntrospectionEvidence()
    check first.observedInputEndsWith("dev-env-value.txt")

    let second = computeDevEnvEdge(cfg)
    check second.artifactPath == first.artifactPath
    check second.artifactPath.readBytes() == firstBytes
    check not second.stats.providerBuildLaunched
    check second.stats.providerBuildSkippedFresh
    check not second.stats.providerIntrospectionLaunched
    check second.stats.providerIntrospectionCacheHit
    check second.stats.artifactWriteSkipped
    check not second.stats.shellRenderingLaunched
    check second.stats.shellRenderingCacheHit
    check second.stats.shellRenderingSkipped
    if not second.observedInputEndsWith("dev-env-value.txt"):
      second.dumpIntrospectionEvidence()
    check second.observedInputEndsWith("dev-env-value.txt")

  test "e2e_dev_env_edge_reruns_on_observed_input_change":
    let c = prepareCase("repro-m3-dev-env-observed")
    defer: removeDir(c.tempRoot)
    let cfg = configFor(c.projectRoot, c.outDir, c.reproBin, c.fsSnoop,
      c.shim, c.repoRoot)

    let first = computeDevEnvEdge(cfg)
    let firstBytes = first.artifactPath.readBytes()
    sleep(30)
    writeFile(c.projectRoot / "dev-env-value.txt", "charlie\n")
    let second = computeDevEnvEdge(cfg)

    check second.stats.providerBuildSkippedFresh
    check second.stats.providerIntrospectionLaunched
    check second.stats.artifactWriteLaunched
    check second.artifactPath.readBytes() != firstBytes
    check second.artifactPath.artifactShellOp("AUX_VALUE").value == "charlie"
    check second.observedInputEndsWith("dev-env-value.txt")

  test "e2e_dev_env_edge_rebuilds_provider_on_project_change":
    let c = prepareCase("repro-m3-dev-env-provider")
    defer: removeDir(c.tempRoot)
    let cfg = configFor(c.projectRoot, c.outDir, c.reproBin, c.fsSnoop,
      c.shim, c.repoRoot)

    let first = computeDevEnvEdge(cfg)
    let firstProviderArtifactId = first.providerArtifactId
    check first.artifactPath.artifactShellOp("FIXTURE_MODE").value == "dev"
    sleep(30)
    writeFile(c.projectRoot / "fixture_provider.nim",
      providerText("changed", "nim c -d:changed src/main.nim"))
    let second = computeDevEnvEdge(cfg)

    check second.stats.providerBuildLaunched
    check second.providerCompileAction.id == "__repro_provider_compile"
    check second.providerCompileAction.status == asSucceeded
    check second.stats.providerIntrospectionLaunched
    check second.introspectionAction.evidence.declaredInputs.anyIt(
      it == second.providerBinaryPath)
    check second.providerArtifactId != firstProviderArtifactId
    check second.artifactPath.artifactShellOp("FIXTURE_MODE").value ==
      "changed"
    check readDevEnvArtifact(second.artifactPath).tasks.anyIt(
      it.command == "nim c -d:changed src/main.nim")
