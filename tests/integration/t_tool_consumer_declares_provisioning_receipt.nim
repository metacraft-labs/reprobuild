## An edge that uses a provisioned tool declares that tool's provisioning
## receipt as an input, so re-realizing the tool invalidates the edge.
##
## Dependency-Provisioning-In-Build-Graph.md section 3, step 5 ("Downstream
## Consumption"): compilation or execution edges that require a provisioned
## tool declare a dependency on the provisioning action's output. A tarball
## tool is realized by a `bakForeignProvision` edge whose output is a receipt
## (section 4.2); the receipt's path is stable across re-pins and its content
## names the realization. Before this test the consuming edge reached the
## tool only through the tool identity -- the engine prepended its directory
## to PATH at launch -- and declared nothing, so a re-pinned tool left an
## up-to-date consumer up to date.
##
## What is asserted, through the real tool resolver, the real CLI projection
## of the tool identity (`mkToolIdentityResolver`) and the real engine:
##
##   * a consumer whose `toolIdentityRefs` name a tarball-provisioned tool
##     has that tool's receipt among its declared inputs when it runs;
##   * a repeat run is not re-executed;
##   * re-pinning the tool (the same provisioning edge, a new realization)
##     re-executes the consumer;
##   * a consumer that names no provisioned tool declares no receipt.
##
## No mocks: the tool archive is a real local file (`file://`, a `raw`
## archive, so no extractor is involved), realized into a real temporary
## tool store. The consumer is a real process -- this test binary, re-entered
## in its `fixture-consumer` mode -- that copies its input and writes a Make
## depfile naming it, so its read set is reported rather than monitored.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_cli_support
import repro_core
import repro_depfile
import repro_interface_artifacts
import repro_tool_profiles

proc writeRawTool(dir, name, body: string): tuple[url, sha256: string] =
  createDir(dir)
  let path = dir / name
  writeFile(path, body)
  (url: "file://" & path.replace('\\', '/'), sha256: fileSha256Hex(path))

proc rawUse(url, sha256: string): InterfaceToolUse =
  result = InterfaceToolUse(rawConstraint: "receiptfixture",
    packageSelector: "receiptfixture@1.0", executableName: "receiptfixture")
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: "receiptfixture", url: url, sha256: sha256,
    archiveType: "raw", executablePath: "bin/receiptfixture.cmd",
    packageId: "receiptfixture@1.0",
    lockIdentity: "tarball:receiptfixture@1.0:" & sha256)]

proc identityFor(use: InterfaceToolUse; storeRoot: string):
    PathOnlyBuildIdentity =
  let artifact = ProjectInterfaceArtifact(projectInterface: ProjectInterface(
    projectName: "receipt-consumer", packageName: "receipt-consumer",
    toolUses: @[use]))
  toolBuildIdentity(artifact, tpmTarball, storeRoot = storeRoot)

when isMainModule:
  let params = commandLineParams()
  if params.len == 4 and params[0] == "fixture-consumer":
    # <source> <output> <depfile>
    createDir(params[2].parentDir)
    writeFile(params[2], readFile(params[1]))
    proc escaped(path: string): string =
      for ch in path:
        case ch
        of ' ': result.add("\\ ")
        of '\\': result.add("\\\\")
        of ':': result.add("\\:")
        else: result.add(ch)
    writeFile(params[3], escaped(params[2]) & ": " & escaped(params[1]) &
      "\n")
    quit 0

proc depfilePolicy(depfile: string): DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: dgRecognizedFormat,
    completeness: decComplete,
    recognizedReports: @[
      RecognizedDependencyReportSpec(
        formatName: DependencyFormatName(MakeDepfileFormatName),
        outputs: @[ExpectedDependencyFile(logicalName: "deps",
          path: depfile, required: true)],
        completeness: decComplete)])

proc resultFor(run: BuildRunResult; id: string): ActionResult =
  for item in run.results:
    if item.id == id:
      return item
  raise newException(KeyError, "no result for " & id)

suite "an edge that uses a provisioned tool declares its receipt":
  putEnv("REPRO_CACHE_DISABLE", "1")
  let tempRoot = createTempDir("repro-receipt-consumer-", "")
  let storeRoot = tempRoot / "store"
  let source = tempRoot / "src" / "input.txt"
  createDir(source.parentDir)
  writeFile(source, "consumer input\n")
  let v1 = writeRawTool(tempRoot / "v1", "receiptfixture.cmd", "@echo v1\r\n")
  let v2 = writeRawTool(tempRoot / "v2", "receiptfixture.cmd", "@echo v2\r\n")
  let receipt =
    tarballProvisioningEdges(rawUse(v1.url, v1.sha256), storeRoot).rootReceipt

  proc consumerGraph(id: string; refs: seq[string]): BuildGraph =
    let output = tempRoot / "out" / (id & ".txt")
    let depfile = tempRoot / "out" / (id & ".d")
    var consumer = action(id,
      [getAppFilename(), "fixture-consumer", source, output, depfile],
      governingLockIdentity = lockIdentityOutsideSolvedGraph(),
      cwd = tempRoot, inputs = [source], outputs = [output],
      cacheable = true, dependencyPolicy = depfilePolicy(depfile))
    consumer.toolIdentityRefs = refs
    graph(@[consumer])

  proc run(g: BuildGraph; identity: PathOnlyBuildIdentity): BuildRunResult =
    var config = defaultBuildEngineConfig(tempRoot / "scratch",
      tempRoot / "cache")
    config.bypassRunQuota = true
    config.maxParallelism = 1
    config.suppressTrace = true
    config.toolIdentityResolver = mkToolIdentityResolver(identity)
    runBuild(g, config)

  test "the consumer's declared inputs include the tool's receipt":
    let identity = identityFor(rawUse(v1.url, v1.sha256), storeRoot)
    check fileExists(receipt)
    let first = run(consumerGraph("consumer", @["receiptfixture"]), identity)
    let item = first.resultFor("consumer")
    check item.status == asSucceeded
    check receipt in item.evidence.declaredInputs
    check source in item.evidence.declaredInputs

  test "a repeat is not re-executed; a re-pinned tool re-executes it":
    let identityV1 = identityFor(rawUse(v1.url, v1.sha256), storeRoot)
    # The build this case repeats happens HERE. It used to be the previous
    # case's, but the runner runs every case in its own process with its own
    # `tempRoot`, so the "repeat" was a first build and always ran.
    let first = run(consumerGraph("consumer", @["receiptfixture"]), identityV1)
    check first.resultFor("consumer").status == asSucceeded
    let again = run(consumerGraph("consumer", @["receiptfixture"]), identityV1)
    check again.resultFor("consumer").status in {asUpToDate, asCacheHit}
    check not again.resultFor("consumer").launched

    # Re-pin: the same provisioning edge (same receipt path) realizes v2.
    let identityV2 = identityFor(rawUse(v2.url, v2.sha256), storeRoot)
    check tarballProvisioningEdges(rawUse(v2.url, v2.sha256),
      storeRoot).rootReceipt == receipt
    let repinned = run(consumerGraph("consumer", @["receiptfixture"]),
      identityV2)
    check repinned.resultFor("consumer").status == asSucceeded

  test "a consumer that names no provisioned tool declares no receipt":
    let identity = identityFor(rawUse(v2.url, v2.sha256), storeRoot)
    let plain = run(consumerGraph("plain", @[]), identity)
    let item = plain.resultFor("plain")
    check item.status == asSucceeded
    check receipt notin item.evidence.declaredInputs

  removeDir(tempRoot)
