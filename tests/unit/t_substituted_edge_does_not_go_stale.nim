## The provider-compile edge's POST-execution consistency check must not
## reject an artifact the edge itself just materialized.
##
## The failure this gate pins down, observed on a long multi-package build:
## the edge ran, wrote a provider binary and a provider-compile artifact that
## described it exactly, and the caller then rejected both with nothing but
## "provider compile artifact is stale after edge execution", killing the
## whole build.
##
## The mechanism is a time-of-check/time-of-use window, and it is wide.
## ``providerFingerprint`` covers the recipe's source closure AND — via
## ``reproLibSourceFingerprint`` — every ``.nim``/``.nims`` under the work
## directory's ``libs/``. The caller hashes that set to build the plan, the
## edge then runs for minutes in a child process, and the child hashes the set
## again when it writes the artifact. Any of those files being rewritten in
## between makes the two digests differ by construction — and the pre-execution
## digest is the one that is out of date, not the artifact.
##
## Whether the edge's outputs arrived by compiling or by being restored from a
## cache is immaterial to the check: either way the files appear on disk and
## the same comparison is made against the same pre-execution digest. Both
## arrival routes are covered below.
##
## No mock objects. Every artifact here is written by the product's own codec
## (``writeProviderCompileArtifact``) with fingerprints from the product's own
## ``providerFingerprintFor``, against real files on a real filesystem, and is
## read back by the product's own reader. What is NOT run is ``nim c`` itself:
## the compiler's entire contribution to this check is the artifact it writes,
## so driving a five-minute Nim compile would add a five-minute wait and no
## coverage. The work directory is synthetic so the fingerprint's library
## source set is the two files this test controls rather than the reprobuild
## checkout it is running from — the test must not depend on, or provoke, an
## edit to the tree it lives in.

import std/[os, strutils, unittest]

import repro_interface_artifacts
import repro_core
import repro_hash

const
  dslStub = """
## Stub standing in for the DSL entry module, so the synthetic work directory
## is recognized as a self-contained library root and no external library root
## is folded into the fingerprint.
const reproProjectDslStub* = 1
"""
  libBefore = """
const libraryConstant* = 1
"""
  libAfter = """
const libraryConstant* = 2
const libraryAddition* = 3
"""
  recipeBody = """
package staleGate:
  build:
    discard
"""

type Fixture = object
  root: string
  workDir: string
  libPath: string
  modulePath: string
  binPath: string
  artifactPath: string

proc newFixture(name: string): Fixture =
  result.root = getTempDir() / "provider-staleness-" & name & "-" &
    $getCurrentProcessId()
  removeDir(extendedPath(result.root))
  result.workDir = result.root / "workspace"
  result.libPath = result.workDir / "libs" / "demo" / "src" / "demo.nim"
  createDir(extendedPath(parentDir(result.libPath)))
  writeFile(extendedPath(result.libPath), libBefore)
  let dslPath = result.workDir / "libs" / "repro_project_dsl" / "src" /
    "repro_project_dsl.nim"
  createDir(extendedPath(parentDir(dslPath)))
  writeFile(extendedPath(dslPath), dslStub)
  result.modulePath = result.root / "project" / "repro.nim"
  createDir(extendedPath(parentDir(result.modulePath)))
  writeFile(extendedPath(result.modulePath), recipeBody)
  result.binPath = result.root / "out" / "project-provider"
  result.artifactPath = result.root / "out" / "provider-compile.rbsz"
  createDir(extendedPath(result.root / "out"))

proc interfaceFingerprint(): ContentDigest =
  casDigest(toBytes("provider-staleness-gate-interface"))

proc materializeEdgeOutputs(fx: Fixture; payload: string): ProviderCompileArtifact =
  ## Write exactly what the provider-compile edge leaves behind: the binary,
  ## and an artifact describing it whose ``providerFingerprint`` is computed
  ## from the inputs AS THEY ARE NOW — which is what the edge's child process
  ## does, and the whole reason it can differ from the plan's.
  writeFile(extendedPath(fx.binPath), payload)
  let sources = discoverNimSources(fx.modulePath)
  let plan = providerCompilePlan(fx.modulePath, fx.binPath,
    interfaceFingerprint(), fx.workDir)
  result = ProviderCompileArtifact(
    inputSources: sources,
    outputBinaryPath: plan.outputBinaryPath,
    compilerCommand: plan.compilerCommand,
    compileEdge: plan.compileEdge,
    interfaceFingerprint: interfaceFingerprint(),
    providerFingerprint: providerFingerprintFor(sources,
      interfaceFingerprint(), fx.workDir),
    outputBinaryFingerprint: casDigest(toBytes(payload)),
    executionResult: ProviderCompileExecutionResult(exitCode: 0))
  writeProviderCompileArtifact(fx.artifactPath, result)

suite "provider-compile artifact survives an input moving under the edge":

  test "an input rewritten while the edge runs does not condemn the artifact":
    let fx = newFixture("compiled")
    defer: removeDir(extendedPath(fx.root))

    # 1. The caller plans the edge. This hashes the library sources as they
    #    are now, and the digest is carried to the post-execution check.
    let plan = providerCompilePlan(fx.modulePath, fx.binPath,
      interfaceFingerprint(), fx.workDir)

    # 2. The edge runs. While it runs, somebody edits a library source — the
    #    reprobuild checkout is a shared working tree and a package closure
    #    takes hours, so this is an ordinary event, not an exotic one.
    writeFile(extendedPath(fx.libPath), libAfter)

    # 3. The edge's child writes its outputs, hashing the inputs it sees.
    let artifact = materializeEdgeOutputs(fx, "provider-binary-bytes")

    # This is precisely the recorded failure: the artifact is self-consistent
    # and current, and the pre-execution digest disagrees with it. Asserting
    # it here keeps the scenario honest — if this ever stops holding, the test
    # below has stopped exercising the defect it was written for.
    check artifact.providerFingerprint != plan.providerFingerprint
    check not providerCompileArtifactFresh(fx.artifactPath,
      plan.outputBinaryPath, plan.interfaceFingerprint,
      plan.providerFingerprint, plan.workDir)

    # 4. The post-execution check must accept it, and say why it had to
    #    reconcile rather than accepting silently.
    let verdict = providerCompileConsistencyAfterExecution(plan,
      fx.artifactPath)
    check verdict.fresh
    check verdict.reconciled
    check verdict.detail.contains(fx.libPath)

  test "outputs restored from a cache in the same run are accepted":
    # The restore route: the artifact and binary are placed on disk by the
    # cache rather than by a compiler. The check sees the same two files and
    # must reach the same verdict.
    let fx = newFixture("restored")
    defer: removeDir(extendedPath(fx.root))

    let plan = providerCompilePlan(fx.modulePath, fx.binPath,
      interfaceFingerprint(), fx.workDir)
    writeFile(extendedPath(fx.libPath), libAfter)

    # Produce the cache's payload out of tree, then "restore" it by copying
    # both outputs into place — no compiler is involved on this route at all.
    let stagedBin = fx.root / "cache" / "project-provider"
    let stagedArtifact = fx.root / "cache" / "provider-compile.rbsz"
    createDir(extendedPath(fx.root / "cache"))
    discard materializeEdgeOutputs(fx, "restored-provider-binary-bytes")
    copyFile(extendedPath(fx.binPath), extendedPath(stagedBin))
    copyFile(extendedPath(fx.artifactPath), extendedPath(stagedArtifact))
    removeFile(extendedPath(fx.binPath))
    removeFile(extendedPath(fx.artifactPath))
    copyFile(extendedPath(stagedArtifact), extendedPath(fx.artifactPath))
    copyFile(extendedPath(stagedBin), extendedPath(fx.binPath))

    let verdict = providerCompileConsistencyAfterExecution(plan,
      fx.artifactPath)
    check verdict.fresh
    check verdict.reconciled

  test "an unchanged input set is accepted without reconciling":
    # Non-vacuity in the other direction: when nothing moved, the check must
    # take the plain path and NOT report a reconciliation.
    let fx = newFixture("quiet")
    defer: removeDir(extendedPath(fx.root))

    let plan = providerCompilePlan(fx.modulePath, fx.binPath,
      interfaceFingerprint(), fx.workDir)
    discard materializeEdgeOutputs(fx, "provider-binary-bytes")

    let verdict = providerCompileConsistencyAfterExecution(plan,
      fx.artifactPath)
    check verdict.fresh
    check not verdict.reconciled
    check verdict.detail.len == 0

  test "an artifact describing a different binary is still rejected":
    # The gate keeps its teeth: reconciliation only ever forgives the source
    # fingerprint, never the artifact/binary correspondence.
    let fx = newFixture("wrong-binary")
    defer: removeDir(extendedPath(fx.root))

    let plan = providerCompilePlan(fx.modulePath, fx.binPath,
      interfaceFingerprint(), fx.workDir)
    discard materializeEdgeOutputs(fx, "provider-binary-bytes")
    writeFile(extendedPath(fx.binPath), "some-other-binary")

    let verdict = providerCompileConsistencyAfterExecution(plan,
      fx.artifactPath)
    check not verdict.fresh
    check verdict.detail.contains("not the one the artifact describes")
