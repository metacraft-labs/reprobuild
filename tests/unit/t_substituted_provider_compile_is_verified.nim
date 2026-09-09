## A provider binary pulled out of a cache is only usable if something checks
## that it is the right one. This gate is that check.
##
## The publish/substitute pair for the provider-compile edge exists because the
## materialized-output cache cannot shorten the compile: a package whose build
## output arrives from the cache whole still pays a full single-threaded
## ``nim c`` first. Fixing that means putting a compiled ELF into a cache, and
## the stated hazard of doing so is that an edge publishing on incomplete
## evidence "fails by serving a stale binary rather than by erroring".
##
## So the restore path does not trust the fetch. It installs the entry and then
## hands the pair to ``providerCompileConsistencyAfterExecution`` — the same
## check a freshly compiled pair passes — and on a refusal it removes every
## file it wrote, so a rejected entry costs a rebuild and can never be
## mistaken for a compile that happened.
##
## No mock objects and no fake cache client. The archive layout is produced by
## the shipped ``stageProviderCompilePrefix`` and consumed by the shipped
## ``acceptRestoredProviderCompilePrefix`` — the same two procs the network
## path calls, with only the HTTP fetch between them left out (it contributes
## bytes, not a decision). Work directories are synthetic so the fingerprint's
## library source set is the files these tests own.

import std/[os, strutils, unittest]

import repro_core
import repro_hash
import repro_interface_artifacts
import repro_binary_cache_client/in_process
import repro_binary_cache_client/provider_compile_cache

const
  dslStub = "const reproProjectDslStub* = 1\n"
  libV1 = "const libraryConstant* = 1\n"
  libV2 = "const libraryConstant* = 2\n"
  recipeBody = """
package substituteGate:
  build:
    discard
"""

type Fixture = object
  root, workDir, libPath, modulePath, binPath, artifactPath, scratch: string

proc newFixture(name: string): Fixture =
  result.root = getTempDir() / "provider-substitute-" & name & "-" &
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
  result.binPath = result.root / "out" / "provider" / "project-provider"
  result.artifactPath = result.root / "out" / "provider-compile.rbsz"
  result.scratch = result.root / "scratch"
  createDir(extendedPath(result.root / "out"))
  createDir(extendedPath(result.scratch))

proc ifp(): ContentDigest = casDigest(toBytes("substitute-gate-interface"))

proc planFor(fx: Fixture): ProviderCompilePlan =
  providerCompilePlan(fx.modulePath, fx.binPath, ifp(), fx.workDir)

proc materializeCompile(fx: Fixture; payload: string) =
  ## Write what a completed provider compile leaves behind: the binary, and an
  ## artifact describing it whose fingerprints are computed from the inputs as
  ## they stand.
  createDir(extendedPath(parentDir(fx.binPath)))
  writeFile(extendedPath(fx.binPath), payload)
  # A provider binary is executable, and the whole point of restoring one is
  # that it can be run. Set the bit here so the round trip below has to keep
  # it.
  setFilePermissions(extendedPath(fx.binPath),
    {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
     fpOthersRead, fpOthersExec})
  let sources = discoverNimSources(fx.modulePath)
  let plan = planFor(fx)
  writeProviderCompileArtifact(fx.artifactPath, ProviderCompileArtifact(
    inputSources: sources,
    outputBinaryPath: plan.outputBinaryPath,
    compilerCommand: plan.compilerCommand,
    compileEdge: plan.compileEdge,
    interfaceFingerprint: ifp(),
    providerFingerprint: providerFingerprintFor(sources, ifp(), fx.workDir),
    outputBinaryFingerprint: casDigest(toBytes(payload)),
    executionResult: ProviderCompileExecutionResult(exitCode: 0)))

proc publishInto(fx: Fixture; prefixDir: string) =
  ## Stage the entry, put it THROUGH THE REAL WIRE FORMAT, and remove the
  ## local compile so what follows is a real restore rather than a no-op.
  ##
  ## Going through ``packPrefix``/``extractPrefix`` rather than handing the
  ## staging tree straight over is deliberate: the archive is what actually
  ## crosses the machine boundary, and a provider binary that arrives without
  ## its exec bit is useless in a way no digest comparison would notice.
  let stageDir = prefixDir & ".stage"
  check stageProviderCompilePrefix(planFor(fx), fx.artifactPath, stageDir)
  let archive = packPrefix(stageDir)
  removeDir(extendedPath(stageDir))
  removeDir(extendedPath(prefixDir))
  extractPrefix(archive, prefixDir)
  removeFile(extendedPath(fx.binPath))
  removeFile(extendedPath(fx.artifactPath))
  removeFile(extendedPath(fx.artifactPath & ".inputs"))

suite "a substituted provider compile is verified before it is used":

  test "a matching entry is restored and accepted":
    let fx = newFixture("hit")
    defer: removeDir(extendedPath(fx.root))
    materializeCompile(fx, "provider-binary-bytes")
    let prefix = fx.root / "entry"
    publishInto(fx, prefix)
    check not fileExists(extendedPath(fx.binPath))

    let verdict = acceptRestoredProviderCompilePrefix(planFor(fx),
      fx.artifactPath, prefix)
    check verdict.fresh
    check fileExists(extendedPath(fx.binPath))
    check fileExists(extendedPath(fx.artifactPath))
    check readFile(extendedPath(fx.binPath)) == "provider-binary-bytes"
    # The restored binary must keep its exec bit, or the provider cannot run.
    when not defined(windows):
      check fpUserExec in getFilePermissions(extendedPath(fx.binPath))
      check fpOthersExec in getFilePermissions(extendedPath(fx.binPath))

  test "an entry built against different libraries is REFUSED":
    # The hazard this whole design exists to avoid. The publisher's reprobuild
    # libraries differ from the consumer's, so the published binary is linked
    # against code the consumer does not have. It must not be served.
    let fx = newFixture("stale-libs")
    defer: removeDir(extendedPath(fx.root))
    materializeCompile(fx, "provider-binary-bytes")
    let prefix = fx.root / "entry"
    publishInto(fx, prefix)

    # The consumer's library tree is not the publisher's.
    writeFile(extendedPath(fx.libPath), libV2)

    let verdict = acceptRestoredProviderCompilePrefix(planFor(fx),
      fx.artifactPath, prefix)
    check not verdict.fresh
    check verdict.detail.contains("providerFingerprint")
    # And it leaves nothing behind that a later step could mistake for a
    # compile: a half-installed provider is the failure mode.
    check not fileExists(extendedPath(fx.binPath))
    check not fileExists(extendedPath(fx.artifactPath))

  test "an entry whose artifact does not describe its binary is REFUSED":
    let fx = newFixture("torn")
    defer: removeDir(extendedPath(fx.root))
    materializeCompile(fx, "provider-binary-bytes")
    let prefix = fx.root / "entry"
    publishInto(fx, prefix)
    # Corrupt the payload the way a truncated or swapped upload would.
    writeFile(extendedPath(prefix / "provider-binary"), "not-that-binary")

    let verdict = acceptRestoredProviderCompilePrefix(planFor(fx),
      fx.artifactPath, prefix)
    check not verdict.fresh
    check verdict.detail.contains("not the one the artifact describes")
    check not fileExists(extendedPath(fx.binPath))

  test "an entry missing the compile artifact is REFUSED":
    let fx = newFixture("partial")
    defer: removeDir(extendedPath(fx.root))
    materializeCompile(fx, "provider-binary-bytes")
    let prefix = fx.root / "entry"
    publishInto(fx, prefix)
    removeFile(extendedPath(prefix / "provider-compile.rbsz"))

    let verdict = acceptRestoredProviderCompilePrefix(planFor(fx),
      fx.artifactPath, prefix)
    check not verdict.fresh
    check verdict.detail.contains("provider binary and a compile artifact")
    check not fileExists(extendedPath(fx.binPath))

  test "publishing refuses an artifact this host would itself refuse":
    # Symmetry. Publishing an unverified pair makes a claim about inputs
    # nobody checked, which is how a bad entry gets into a cache in the first
    # place. There is no network in this case — the refusal happens before
    # any endpoint is contacted, which is why an unconfigured cache still
    # exercises it.
    let fx = newFixture("publish-refusal")
    defer: removeDir(extendedPath(fx.root))
    materializeCompile(fx, "provider-binary-bytes")
    writeFile(extendedPath(fx.binPath), "a-different-binary")
    var cfg = ProviderCompileCacheConfig(configured: true, keypairOk: true,
      publishEndpoint: "http://127.0.0.1:1", keyPath: "/nonexistent",
      certPath: "/nonexistent")
    let attempt = publishProviderCompile(planFor(fx), "substituteGate",
      fx.artifactPath, fx.scratch, cfg)
    check not attempt.ok
    check attempt.reason.contains("refusing to publish")
    check attempt.reason.contains("not the one the artifact describes")

  test "a staged prefix carries the binary, the artifact and the sidecar":
    let fx = newFixture("layout")
    defer: removeDir(extendedPath(fx.root))
    materializeCompile(fx, "provider-binary-bytes")
    writeFile(extendedPath(fx.artifactPath & ".inputs"), "sidecar-bytes")
    let prefix = fx.root / "entry"
    check stageProviderCompilePrefix(planFor(fx), fx.artifactPath, prefix)
    check fileExists(extendedPath(prefix / "provider-binary"))
    check fileExists(extendedPath(prefix / "provider-compile.rbsz"))
    check fileExists(extendedPath(prefix / "provider-compile.rbsz.inputs"))
    # The layout is producer-independent: nothing in it names the producer's
    # directories, so a consumer places the files where its OWN plan says.
    check not prefix.contains(fx.binPath)

  test "staging refuses when there is no compile to publish":
    let fx = newFixture("nothing")
    defer: removeDir(extendedPath(fx.root))
    check not stageProviderCompilePrefix(planFor(fx), fx.artifactPath,
      fx.root / "entry")
