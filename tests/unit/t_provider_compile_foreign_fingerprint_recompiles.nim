## A provider-compile artifact whose recorded fingerprint is neither the
## planned one nor the current one must not abort the build: the "now" side
## of the check must be a real reading of the inputs, and an artifact the
## edge SERVED (no compile ran) that describes another compile must be
## replaced by a compile the cache cannot satisfy.
##
## The failure this pins down: `repro build` aborted in "running provider
## compile" with
##
##   provider compile artifact is stale after edge execution: ...
##   the artifact does not match the sources it was compiled from
##     no declared provider-compile input changed on disk
##     providerFingerprint planned:  dcfc...
##     providerFingerprint recorded: 36b9...
##     providerFingerprint now:      dcfc...
##
## Two things produce exactly that triad, and both are covered here:
##
##   * the plan's reprobuild-library fingerprint came from the
##     stamp-validated memo (`setReproLibFingerprintMemoDir`) after the
##     sources changed under stamps that did not move. The compile child
##     never uses the memo, so it recorded the real fingerprint; the check
##     then computed "now" through the same memo, so "now" equalled the plan
##     by construction and the true reading was never made;
##   * the edge's outputs were served (a cache hit, or outputs accepted as
##     up to date) and describe a compile of a different input set. Whatever
##     served them serves them again on every later build, so failing the
##     build fails every build until the entry is found and cleared by hand.
##
## MOCK POLICY. Every artifact is written by the product's own codec with
## fingerprints from the product's own `providerFingerprintFor`, against real
## files, and read back by the product's own reader and checks; the memo is
## the product's own. What is NOT run is `nim c` and the build engine: the
## second half drives `verifyProviderCompileEdge` with a runner that places
## the edge's outputs on disk as a cache restore or a compile would. That is
## the whole of the edge's contribution to the decision under test (which
## files it left, and whether it launched a compile), so a real engine and a
## minute-long Nim compile would add time and no coverage; the CLI call sites
## pass a runner that wraps the real engine (`runVerifiedProviderCompileEdge`
## in repro_cli_support, `computeDevEnvEdge` in repro_dev_env_engine). The
## work directory is synthetic so the library source set is the two files
## this test controls, not the checkout it runs from.

import std/[os, strutils, times, unittest]

import repro_interface_artifacts
import repro_core
import repro_hash

const
  dslStub = """
## Stub standing in for the DSL entry module, so the synthetic work directory
## is recognized as a self-contained library root.
const reproProjectDslStub* = 1
"""
  # Same length on purpose: the memo validates by (path, kind, size, mtime),
  # so an edit that keeps the size and the mtime is one it cannot see.
  libBefore = "const libraryConstant* = 1\n"
  libAfter = "const libraryConstant* = 2\n"
  recipeBody = """
package foreignGate:
  build:
    discard
"""

const pinnedMtimeUnix = 1_700_000_000'i64

proc pinnedMtime(): Time = fromUnix(pinnedMtimeUnix)

type Fixture = object
  root: string
  workDir: string
  libPath: string
  modulePath: string
  binPath: string
  artifactPath: string
  memoDir: string

proc newFixture(name: string): Fixture =
  result.root = getTempDir() / "provider-foreign-" & name & "-" &
    $getCurrentProcessId()
  removeDir(extendedPath(result.root))
  result.workDir = result.root / "workspace"
  result.libPath = result.workDir / "libs" / "demo" / "src" / "demo.nim"
  createDir(extendedPath(parentDir(result.libPath)))
  writeFile(extendedPath(result.libPath), libBefore)
  setLastModificationTime(extendedPath(result.libPath), pinnedMtime())
  let dslPath = result.workDir / "libs" / "repro_project_dsl" / "src" /
    "repro_project_dsl.nim"
  createDir(extendedPath(parentDir(dslPath)))
  writeFile(extendedPath(dslPath), dslStub)
  result.modulePath = result.root / "project" / "repro.nim"
  createDir(extendedPath(parentDir(result.modulePath)))
  writeFile(extendedPath(result.modulePath), recipeBody)
  result.binPath = result.root / "out" / "project-provider"
  result.artifactPath = result.root / "out" / "provider-compile.rbsz"
  result.memoDir = result.root / "memo"
  createDir(extendedPath(result.root / "out"))

proc interfaceFingerprint(): ContentDigest =
  casDigest(toBytes("provider-foreign-gate-interface"))

proc plan(fx: Fixture): ProviderCompilePlan =
  providerCompilePlan(fx.modulePath, fx.binPath, interfaceFingerprint(),
    fx.workDir)

proc writeEdgeOutputs(fx: Fixture; payload: string;
                      libFingerprint = ""): ProviderCompileArtifact =
  ## The two files the edge leaves: the binary and an artifact describing it.
  ## With no `libFingerprint` the artifact's fingerprint is what the edge's
  ## child computes (it never uses the memo); with one, it describes a
  ## compile against a DIFFERENT library set, which is what a foreign cache
  ## entry restores.
  writeFile(extendedPath(fx.binPath), payload)
  let p = fx.plan()
  result = ProviderCompileArtifact(
    inputSources: p.inputSources,
    outputBinaryPath: p.outputBinaryPath,
    compilerCommand: p.compilerCommand,
    compileEdge: p.compileEdge,
    interfaceFingerprint: interfaceFingerprint(),
    providerFingerprint: providerFingerprintFor(p.inputSources,
      interfaceFingerprint(), fx.workDir, libFingerprint = libFingerprint),
    outputBinaryFingerprint: casDigest(toBytes(payload)),
    executionResult: ProviderCompileExecutionResult(exitCode: 0))
  writeProviderCompileArtifact(fx.artifactPath, result)

proc childOutputs(fx: Fixture; payload: string): ProviderCompileArtifact =
  ## As the edge's child writes them: in a process with no memo.
  setReproLibFingerprintMemoDir("")
  defer: setReproLibFingerprintMemoDir(fx.memoDir)
  fx.writeEdgeOutputs(payload)

suite "a provider-compile artifact recording a third fingerprint":

  test "a plan taken from a stale library memo does not abort the build":
    let fx = newFixture("stale-memo")
    defer: removeDir(extendedPath(fx.root))
    setReproLibFingerprintMemoDir(fx.memoDir)
    defer: setReproLibFingerprintMemoDir("")

    # 1. An earlier entry plans the edge and memoizes the library digest.
    let before = fx.plan()

    # 2. The library source changes under stamps the memo trusts: same size,
    #    same mtime (an mtime-preserving copy or restore over the tree).
    writeFile(extendedPath(fx.libPath), libAfter)
    setLastModificationTime(extendedPath(fx.libPath), pinnedMtime())

    # 3. This build plans the edge. The memo answers, so the plan is the old
    #    one; the edge's child hashes the real sources.
    let planned = fx.plan()
    check planned.providerFingerprint == before.providerFingerprint
    let artifact = fx.childOutputs("provider-binary-bytes")

    # The issue's conditions, asserted so the test cannot silently stop
    # exercising them: the recorded fingerprint is not the planned one, and
    # no stamp the plan recorded has moved.
    check artifact.providerFingerprint != planned.providerFingerprint
    check getLastModificationTime(extendedPath(fx.libPath)) == pinnedMtime()
    check getFileSize(extendedPath(fx.libPath)) == libBefore.len

    # 4. The check reads the inputs as they are, finds the artifact matches
    #    them, and accepts it, saying why.
    let verdict = providerCompileConsistencyAfterExecution(planned,
      fx.artifactPath)
    checkpoint verdict.detail
    check verdict.fresh
    check verdict.reconciled
    check verdict.detail.contains("memo was dropped")

    # 5. The stale memo is gone: the next plan is the real one.
    check fx.plan().providerFingerprint == artifact.providerFingerprint

  test "an artifact served without a compile is recompiled, not reported":
    let fx = newFixture("served")
    defer: removeDir(extendedPath(fx.root))
    let planned = fx.plan()
    var runs: seq[bool] = @[]
    let runEdge = proc (forceRebuild: bool): ProviderCompileEdgeRun =
      runs.add(forceRebuild)
      if not forceRebuild:
        # A cache entry for some other input set: internally consistent,
        # right interface and binary path, foreign fingerprint.
        discard fx.writeEdgeOutputs("cached-binary",
          libFingerprint = "another-library-set")
        ProviderCompileEdgeRun(compiled: false,
          provenance: "status=asCacheHit cache=cdHit")
      else:
        discard fx.writeEdgeOutputs("compiled-binary")
        ProviderCompileEdgeRun(compiled: true,
          provenance: "status=asSucceeded cache=cdMiss reason=force-rebuild")

    let verdict = verifyProviderCompileEdge(planned, fx.artifactPath, runEdge)
    checkpoint verdict.detail
    check verdict.fresh
    check verdict.recompiled
    check runs == @[false, true]
    check verdict.detail.contains("status=asCacheHit cache=cdHit")
    check verdict.detail.contains("providerFingerprint recorded")
    check readProviderCompileArtifact(fx.artifactPath).providerFingerprint ==
      planned.providerFingerprint

  test "a fresh served artifact is used as it is":
    let fx = newFixture("served-fresh")
    defer: removeDir(extendedPath(fx.root))
    let planned = fx.plan()
    var runs: seq[bool] = @[]
    let runEdge = proc (forceRebuild: bool): ProviderCompileEdgeRun =
      runs.add(forceRebuild)
      discard fx.writeEdgeOutputs("cached-binary")
      ProviderCompileEdgeRun(compiled: false, provenance: "status=asUpToDate")
    let verdict = verifyProviderCompileEdge(planned, fx.artifactPath, runEdge)
    check verdict.fresh
    check not verdict.recompiled
    check not verdict.reconciled
    check runs == @[false]

  test "a foreign artifact the edge compiled itself is not retried":
    let fx = newFixture("compiled-foreign")
    defer: removeDir(extendedPath(fx.root))
    let planned = fx.plan()
    var runs: seq[bool] = @[]
    let runEdge = proc (forceRebuild: bool): ProviderCompileEdgeRun =
      runs.add(forceRebuild)
      discard fx.writeEdgeOutputs("compiled-binary",
        libFingerprint = "another-library-set")
      ProviderCompileEdgeRun(compiled: true,
        provenance: "status=asSucceeded cache=cdMiss")
    let verdict = verifyProviderCompileEdge(planned, fx.artifactPath, runEdge)
    checkpoint verdict.detail
    check not verdict.fresh
    check verdict.foreignFingerprint
    check runs == @[false]
    check verdict.detail.contains("compiled the provider in this run")
    check verdict.detail.contains("status=asSucceeded cache=cdMiss")

  test "a recompile that is rejected too names both runs":
    let fx = newFixture("rejected-twice")
    defer: removeDir(extendedPath(fx.root))
    let planned = fx.plan()
    var runs: seq[bool] = @[]
    let runEdge = proc (forceRebuild: bool): ProviderCompileEdgeRun =
      runs.add(forceRebuild)
      discard fx.writeEdgeOutputs("binary",
        libFingerprint = "another-library-set")
      ProviderCompileEdgeRun(compiled: forceRebuild,
        provenance: (if forceRebuild: "forced-run" else: "served-run"))
    let verdict = verifyProviderCompileEdge(planned, fx.artifactPath, runEdge)
    checkpoint verdict.detail
    check not verdict.fresh
    check runs == @[false, true]
    check verdict.detail.contains("served-run")
    check verdict.detail.contains("forced-run")
