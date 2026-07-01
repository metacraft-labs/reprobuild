import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_dev_env_artifacts
import repro_build_engine
import repro_dev_env_engine
import repro_provider_runtime
import repro_test_support

# prepareMonitorTools moved to libs/repro_test_support so the Windows
# monitor fixture resolution lives in one place.

# Test-Fixtures-In-Build-Graph M1: ``repro`` is a build-graph artifact
# (``reprobuild.apps.repro`` → ``build/bin/repro``, built by ``just bootstrap``
# / the apps collection before tests run). Assert it exists and use it instead
# of recompiling ``apps/repro/repro.nim`` at test runtime.
proc reproBinary(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

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

proc configFor(projectRoot, outDir, reproBin, monitorCliPath: string,
               monitorCliArgs: seq[string], shim, repoRoot: string):
               DevEnvEdgeConfig =
  DevEnvEdgeConfig(
    modulePath: projectRoot / "fixture_provider.nim",
    projectRoot: projectRoot,
    outDir: outDir,
    workDir: repoRoot,
    publicCliPath: reproBin,
    monitorCliPath: monitorCliPath,
    monitorCliArgs: monitorCliArgs,
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
    reproBin, monitorCliPath, shim, repoRoot: string, monitorCliArgs: seq[string]] =
  result.repoRoot = getCurrentDir()
  result.tempRoot = createTempDir(prefix, "")
  result.projectRoot = result.tempRoot / "project"
  result.outDir = result.tempRoot / "out"
  writeFixture(result.projectRoot)
  createDir(result.outDir)
  result.reproBin = reproBinary(result.repoRoot)
  when isIoMonitorSupported:
    let monitor = prepareMonitorTools(result.repoRoot,
      result.tempRoot / "monitor", "m3-dev-env")
    result.monitorCliPath = monitor.monitorCliPath
    result.monitorCliArgs = monitor.monitorCliArgs
    result.shim = monitor.shim

suite "e2e_dev_env_edge_cache":
  when isIoMonitorSupported:
    test "e2e_dev_env_edge_noop_reuses_cached_artifact":
      let c = prepareCase("repro-m3-dev-env-noop")
      defer: removeDir(c.tempRoot)
      let cfg = configFor(c.projectRoot, c.outDir, c.reproBin,
        c.monitorCliPath, c.monitorCliArgs, c.shim, c.repoRoot)

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
      let cfg = configFor(c.projectRoot, c.outDir, c.reproBin,
        c.monitorCliPath, c.monitorCliArgs, c.shim, c.repoRoot)

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
      let cfg = configFor(c.projectRoot, c.outDir, c.reproBin,
        c.monitorCliPath, c.monitorCliArgs, c.shim, c.repoRoot)

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
