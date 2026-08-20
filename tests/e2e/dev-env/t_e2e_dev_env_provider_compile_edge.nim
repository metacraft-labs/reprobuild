## The provider-compile edge is an ordinary monitored build-graph edge with NO
## hand-written freshness gate in front of it
## (``reprobuild-specs/Compiles-Are-Normal-Edges.md``).
##
## PRIMARY assertion — ``provider_compile_rebuilds_on_non_import_dependency``:
## a dependency the provider compile acquires WITHOUT an ``import`` statement
## (here a ``staticRead`` payload) must invalidate the compiled provider.
##
## This is the regression the deleted gate could not catch. Its key was
## ``discoverNimSources``, a TEXT import walk of the recipe, so a file reached
## by ``staticRead`` / ``staticExec`` / macro-time resolution never appeared in
## it. With the gate in place this exact fixture reported a green, fast dev-env
## activation carrying the OLD payload value — a stale artifact behind a
## successful build, which is the characteristic failure of a hand-enumerated
## key. The monitored edge records the compiler's read of the payload, so the
## engine's action cache misses and the provider is recompiled.
##
## Secondary assertions — the edge still PUBLISHES and HITS
## (``provider_compile_edge_publishes_and_hits``), and the reported
## ``providerBuildSkippedFresh`` / ``providerBuildLaunched`` flags are the
## engine's own decision rather than the deleted gate's.
##
## No mocks: this runs the engine-built ``build/bin/repro`` binary, the real Nim
## compiler, the real io-mon shim and the real filesystem. The only fixture is
## the recipe itself.

import std/[os, strutils, tempfiles, times, unittest]

import repro_dev_env_artifacts
import repro_build_engine
import repro_dev_env_engine
import repro_provider_runtime
import repro_test_support

proc reproBinary(repoRoot: string): string =
  requireBinary(repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc providerText(): string =
  # ``staticRead`` is the whole point: ``payload.txt`` is a COMPILE-TIME input
  # of this module that no ``import``/``include`` statement mentions, so the
  # text-closure key the removed gate used cannot see it.
  "import std/strutils\n" &
    "import repro_project_dsl\n\n" &
    "const bakedPayload = staticRead(\"payload.txt\").strip()\n\n" &
    "package fixture:\n" &
    "  defaultToolProvisioning \"path\"\n" &
    "  uses:\n" &
    "    \"nim >=2.2 <3.0\"\n" &
    "  devEnv:\n" &
    "    activity \"default\"\n" &
    "    setEnv \"BAKED_VALUE\", bakedPayload\n" &
    "    diagnostic \"dev env ready\"\n"

proc writeFixture(dir: string; payload: string) =
  createDir(dir)
  writeFile(dir / "payload.txt", payload & "\n")
  writeFile(dir / "fixture_provider.nim", providerText())

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
    lockSliceId: "lock-provider-edge",
    renderShell: false,
    statsEnabled: true)

proc bakedValue(path: string): string =
  for op in readDevEnvArtifact(path).shellOps:
    if op.name == "BAKED_VALUE":
      return op.value
  raise newException(ValueError, "missing shell op BAKED_VALUE")

type Case = tuple[tempRoot, projectRoot, outDir, reproBin, monitorCliPath,
  shim, repoRoot: string, monitorCliArgs: seq[string]]

proc prepareCase(prefix, payload: string): Case =
  result.repoRoot = getCurrentDir()
  result.tempRoot = createTempDir(prefix, "")
  result.projectRoot = result.tempRoot / "project"
  result.outDir = result.tempRoot / "out"
  writeFixture(result.projectRoot, payload)
  createDir(result.outDir)
  result.reproBin = reproBinary(result.repoRoot)
  when isIoMonitorSupported:
    let monitor = prepareMonitorTools(result.repoRoot,
      result.tempRoot / "monitor", "provider-compile-edge")
    result.monitorCliPath = monitor.monitorCliPath
    result.monitorCliArgs = monitor.monitorCliArgs
    result.shim = monitor.shim

suite "e2e_dev_env_provider_compile_edge":
  when isIoMonitorSupported:
    test "provider_compile_rebuilds_on_non_import_dependency":
      let c = prepareCase("repro-provider-edge-soundness", "alpha")
      defer: removeDir(c.tempRoot)
      let cfg = configFor(c.projectRoot, c.outDir, c.reproBin,
        c.monitorCliPath, c.monitorCliArgs, c.shim, c.repoRoot)

      let first = computeDevEnvEdge(cfg)
      check first.stats.providerBuildLaunched
      check first.artifactPath.bakedValue() == "alpha"

      # Touch ONLY the non-imported compile-time dependency. No .nim file
      # changes, so the removed gate's text-closure key is byte-identical
      # across the two runs.
      writeFile(c.projectRoot / "payload.txt", "bravo\n")

      let second = computeDevEnvEdge(cfg)
      # PRIMARY: the recompiled provider must carry the new payload. With the
      # hand-written gate this read "alpha" and the run was reported fresh.
      check second.artifactPath.bakedValue() == "bravo"
      check second.stats.providerBuildLaunched
      check not second.stats.providerBuildSkippedFresh

    test "provider_compile_edge_publishes_and_hits":
      let c = prepareCase("repro-provider-edge-hit", "alpha")
      defer: removeDir(c.tempRoot)
      let cfg = configFor(c.projectRoot, c.outDir, c.reproBin,
        c.monitorCliPath, c.monitorCliArgs, c.shim, c.repoRoot)

      let coldStart = epochTime()
      let first = computeDevEnvEdge(cfg)
      echo "TIMING coldDevEnvEdgeSeconds=", epochTime() - coldStart
      check first.stats.providerBuildLaunched
      check first.providerCompileAction.cacheDecision == cdMiss

      # PRIMARY: nothing changed, so the edge that just published must now be
      # answered from the action cache instead of recompiling. This is the
      # engine's decision, not a freshness probe's: the gate that used to
      # answer here is gone.
      let warmStart = epochTime()
      let second = computeDevEnvEdge(cfg)
      echo "TIMING warmDevEnvEdgeSeconds=", epochTime() - warmStart
      check not second.stats.providerBuildLaunched
      check second.stats.providerBuildSkippedFresh
      check second.providerCompileAction.cacheDecision == cdHit
      check second.artifactPath.bakedValue() == "alpha"

      # The freshness sidecar is a DECLARED output of the edge, so a cache
      # answer leaves the full output set on disk rather than two of three.
      check fileExists(second.providerArtifactPath & ".inputs")
