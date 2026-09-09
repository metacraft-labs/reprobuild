## When the provider-compile edge's post-execution check DOES reject an
## artifact, it must say what it found — not merely that it found something.
##
## The diagnostic is the deliverable here, not a nicety. The rejection this
## gate covers aborts a whole multi-hour package closure, and a bare "is stale"
## costs the operator the entire run before they learn anything at all. Every
## rejection path must therefore name the file, the path or the digest pair
## that produced it.
##
## No mock objects: artifacts are written by the product's own codec with
## fingerprints from ``providerFingerprintFor``, against real files. The work
## directory is synthetic so the library source set the fingerprint covers is
## the handful of files this test owns.

import std/[options, os, strutils, unittest]

import repro_interface_artifacts
import repro_core
import repro_hash

const
  dslStub = "const reproProjectDslStub* = 1\n"
  libV1 = "const libraryConstant* = 1\n"
  libV2 = "const libraryConstant* = 2\n"
  libV3 = "const libraryConstant* = 3\nconst extra* = 4\n"
  recipeBody = """
package staleDiagnostic:
  build:
    discard
"""

type Fixture = object
  root, workDir, libPath, modulePath, binPath, artifactPath: string

proc newFixture(name: string): Fixture =
  result.root = getTempDir() / "provider-stale-detail-" & name & "-" &
    $getCurrentProcessId()
  removeDir(extendedPath(result.root))
  result.workDir = result.root / "workspace"
  result.libPath = result.workDir / "libs" / "demo" / "src" / "demo.nim"
  createDir(extendedPath(parentDir(result.libPath)))
  writeFile(extendedPath(result.libPath), libV1)
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

proc ifp(): ContentDigest =
  casDigest(toBytes("provider-stale-detail-interface"))

proc writeEdgeOutputs(fx: Fixture; payload: string;
                      interfaceOverride = none(ContentDigest);
                      binaryPathOverride = "") =
  writeFile(extendedPath(fx.binPath), payload)
  let sources = discoverNimSources(fx.modulePath)
  let plan = providerCompilePlan(fx.modulePath, fx.binPath, ifp(), fx.workDir)
  let recordedInterface =
    if interfaceOverride.isSome: interfaceOverride.get() else: ifp()
  let artifact = ProviderCompileArtifact(
    inputSources: sources,
    outputBinaryPath:
      if binaryPathOverride.len > 0: binaryPathOverride
      else: plan.outputBinaryPath,
    compilerCommand: plan.compilerCommand,
    compileEdge: plan.compileEdge,
    interfaceFingerprint: recordedInterface,
    providerFingerprint: providerFingerprintFor(sources, recordedInterface,
      fx.workDir),
    outputBinaryFingerprint: casDigest(toBytes(payload)),
    executionResult: ProviderCompileExecutionResult(exitCode: 0))
  writeProviderCompileArtifact(fx.artifactPath, artifact)

suite "a rejected provider-compile artifact names what changed":

  test "the changed library source is named, with its size and mtime":
    let fx = newFixture("named")
    defer: removeDir(extendedPath(fx.root))

    # Plan under v1; the edge's child hashes v2; a third edit lands before the
    # check runs, so the artifact matches NEITHER the plan nor the current
    # state and the rejection stands. It must still name the file.
    let plan = providerCompilePlan(fx.modulePath, fx.binPath, ifp(),
      fx.workDir)
    writeFile(extendedPath(fx.libPath), libV2)
    writeEdgeOutputs(fx, "provider-binary-bytes")
    writeFile(extendedPath(fx.libPath), libV3)

    let verdict = providerCompileConsistencyAfterExecution(plan,
      fx.artifactPath)
    check not verdict.fresh
    check verdict.detail.contains(fx.libPath)
    check verdict.detail.contains("size " & $libV1.len & " -> " & $libV3.len)
    check verdict.detail.contains("mtime ")
    # And it must show the three digests that disagree, so the reader can tell
    # "an input moved" from "the wrong artifact arrived".
    check verdict.detail.contains("providerFingerprint planned:")
    check verdict.detail.contains("providerFingerprint recorded:")
    check verdict.detail.contains("providerFingerprint now:")

  test "a missing provider binary is named rather than called stale":
    let fx = newFixture("missing-binary")
    defer: removeDir(extendedPath(fx.root))

    let plan = providerCompilePlan(fx.modulePath, fx.binPath, ifp(),
      fx.workDir)
    writeEdgeOutputs(fx, "provider-binary-bytes")
    removeFile(extendedPath(fx.binPath))

    let verdict = providerCompileConsistencyAfterExecution(plan,
      fx.artifactPath)
    check not verdict.fresh
    check verdict.detail.contains("provider binary")
    check verdict.detail.contains(fx.binPath)

  test "an artifact from another project interface names both digests":
    let fx = newFixture("other-interface")
    defer: removeDir(extendedPath(fx.root))

    let plan = providerCompilePlan(fx.modulePath, fx.binPath, ifp(),
      fx.workDir)
    let foreign = casDigest(toBytes("a-different-project-interface"))
    writeEdgeOutputs(fx, "provider-binary-bytes",
      interfaceOverride = some(foreign))

    let verdict = providerCompileConsistencyAfterExecution(plan,
      fx.artifactPath)
    check not verdict.fresh
    check verdict.detail.contains("different project interface")
    check verdict.detail.contains(toHex(plan.interfaceFingerprint.bytes))
    check verdict.detail.contains(toHex(foreign.bytes))

  test "an artifact naming another output binary names both paths":
    let fx = newFixture("other-binary-path")
    defer: removeDir(extendedPath(fx.root))

    let plan = providerCompilePlan(fx.modulePath, fx.binPath, ifp(),
      fx.workDir)
    let foreignPath = fx.root / "elsewhere" / "project-provider"
    writeEdgeOutputs(fx, "provider-binary-bytes",
      binaryPathOverride = foreignPath)

    let verdict = providerCompileConsistencyAfterExecution(plan,
      fx.artifactPath)
    check not verdict.fresh
    check verdict.detail.contains("different provider binary")
    check verdict.detail.contains(foreignPath)
    check verdict.detail.contains(plan.outputBinaryPath)

  test "a binary that is not the one described names both digests":
    let fx = newFixture("binary-mismatch")
    defer: removeDir(extendedPath(fx.root))

    let plan = providerCompilePlan(fx.modulePath, fx.binPath, ifp(),
      fx.workDir)
    writeEdgeOutputs(fx, "provider-binary-bytes")
    writeFile(extendedPath(fx.binPath), "substituted-other-binary")

    let verdict = providerCompileConsistencyAfterExecution(plan,
      fx.artifactPath)
    check not verdict.fresh
    check verdict.detail.contains("not the one the artifact describes")
    check verdict.detail.contains(
      toHex(casDigest(toBytes("provider-binary-bytes")).bytes))
    check verdict.detail.contains(
      toHex(casDigest(toBytes("substituted-other-binary")).bytes))
