## A Nix-realized tool is realized by a provisioning edge, and an edge that
## uses it declares that edge's receipt as an input.
##
## Dependency-Provisioning-In-Build-Graph.md section 2 (every package
## materialization is a `bakForeignProvision` edge routed by its provisioner)
## and section 3, step 5 (an edge that uses a provisioned tool declares a
## dependency on the provisioning action's output). reprobuild-pm issue
## 2026-10-07 "from-source and out-of-dev-env Nix realizations are not
## provisioning edges": `resolveNixTool` realized a `nixPackage` inline,
## through the `reprobuild-nix-daemon` helper, and set no
## `provisioningReceipt`, so `withProvisioningReceiptInputs` found nothing to
## add for the tool's consumers and a re-realization to a different store
## path reached them only through the tool identity.
##
## What is asserted, through the real tool resolver (`toolBuildIdentity`
## with `tpmNix`), the real CLI projection of the tool identity
## (`mkToolIdentityResolver`) and the real engine:
##
##   * the resolved profile, and the action identity built from it, carry a
##     receipt that exists and names the realized store path;
##   * that receipt is the output of a `bakForeignProvision` edge whose
##     provisioner (`argv[0]`) is `"nix"`;
##   * a consumer whose `toolIdentityRefs` name the tool has the receipt among
##     its declared inputs; a repeat is not re-executed; a realization to a
##     different store path keeps the receipt's path, changes its content,
##     and re-executes the consumer;
##   * a repeat realization is an action-cache hit, and a realization whose
##     store path was collected is realized again rather than served.
##
## MOCK POLICY -- NO MOCKS. The tool is realized by the real
## `reprobuild-nix-daemon` helper running the host's real `nix build` over the
## repository's local fixture flake (`tests/fixtures/nix-daemon-local-flake`,
## the fixture `t_nix_daemon_provisioner.nim` and
## `t_nix_tool_realizations_are_gc_rooted.nim` use). Each case copies the
## fixture and makes its one line of shell text unique, so every realized
## output is a store path private to this process: that is what lets the
## re-realization case delete it with `nix-store --delete` (never a garbage
## collection) without touching anything else on the host. The consumer is a
## real process -- this test binary, re-entered in its `fixture-consumer`
## mode -- that copies its input and writes a Make depfile naming it.

import std/[json, os, osproc, strutils, tempfiles, times, unittest]

import repro_build_engine
import repro_cli_support
import repro_core
import repro_depfile
import repro_interface_artifacts
import repro_test_support/process_fixtures
import repro_test_support/reasoned_skip
import repro_tool_profiles

const RepoMarker = "repro.nim"
const FixtureRelRoot = "tests/fixtures/nix-daemon-local-flake"
const FixtureSelector = ".#hello-sh"
const FixtureExecutable = "bin/reprobuild-nix-daemon-fixture"
const FixtureText = "printf '%s\\n' reprobuild-nix-daemon-fixture"
const ToolName = "reprobuild-nix-daemon-fixture"

const HostRunsGate = not defined(windows)

const PlatformSkipReason =
  "[platform N/A] t_nix_tool_resolution_is_a_provisioning_edge: " &
    "Nix does not run natively on Windows, where `resolveNixTool` refuses"
  ## A runtime guard on a compile-time constant, so each body is still
  ## type-checked on a host that skips it.

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

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc findNixDaemon(repoRoot: string): string =
  for candidate in [
    getEnv("REPROBUILD_NIX_DAEMON_BIN"),
    repoRoot / "build" / "bin" / "reprobuild-nix-daemon",
    repoRoot / "tools" / "reprobuild-nix-daemon" / "reprobuild-nix-daemon"
  ]:
    if candidate.len > 0 and fileExists(candidate):
      return candidate
  raise newException(IOError,
    "reprobuild-nix-daemon missing; set REPROBUILD_NIX_DAEMON_BIN")

proc nixStore(args: openArray[string]): tuple[output: string; code: int] =
  ## `followSymlinks = false`: `nix-store` is a symlink to the multi-call
  ## `nix`, which dispatches on `argv[0]`.
  let exe = findExe("nix-store", followSymlinks = false)
  doAssert exe.len > 0, "nix-store is not on PATH; this test needs real Nix"
  var cmd = quoteShell(exe)
  for arg in args:
    cmd.add(" " & quoteShell(arg))
  let (output, code) = execCmdEx(cmd)
  (output: output, code: code)

proc receiptPaths(receipt: string): seq[string] =
  for line in readFile(receipt).splitLines():
    if line.strip().len > 0:
      result.add(line.strip())

type Fixture = object
  ## One case's private world: a tool store, a scratch root and, per
  ## realization, a private copy of the fixture flake.
  root: string
  storeRoot: string
  realized: seq[string]   ## private store paths to delete at the end
  tag: string

var fixtureCounter = 0

proc privateFlake(f: var Fixture; variant: string): string =
  ## The fixture flake with its shell text made unique to this process and
  ## `variant`, so the realized output is a store path nothing else on the
  ## host references.
  let sourceRoot = findRepoRoot() / FixtureRelRoot
  result = f.root / ("flake-" & variant)
  createDir(result)
  let flake = readFile(sourceRoot / "flake.nix")
  doAssert FixtureText in flake,
    "fixture flake no longer carries the line this test makes unique"
  writeFile(result / "flake.nix", flake.replace(FixtureText,
    "printf '%s\\n' reprobuild-nix-tool-edge-" & f.tag & "-" & variant))
  copyFile(sourceRoot / "flake.lock", result / "flake.lock")
  for args in ["init -q", "add flake.nix flake.lock"]:
    let (output, code) = execCmdEx("git -C " & quoteShell(result) & " " & args)
    doAssert code == 0, "failed to prepare fixture git index: " & output

proc openFixture(): Fixture =
  inc fixtureCounter
  result.tag = $getCurrentProcessId() & "-" & $int64(epochTime() * 1000) &
    "-" & $fixtureCounter
  result.root = createTempDir("repro-nix-tool-edge-", "")
  releaseDirAtProcessExit(result.root)
  result.storeRoot = result.root / "store"
  let daemonPath = findNixDaemon(findRepoRoot())
  putEnv("REPROBUILD_NIX_DAEMON_BIN", daemonPath)
  # A private helper (its socket is keyed by user and helper identity), so no
  # other test's helper -- or its response cache -- answers these requests.
  putEnv("USER", "repro-nix-tool-edge-" & $getCurrentProcessId())
  putEnv("REPRO_CACHE_DISABLE", "1")

proc dropRoots(f: Fixture) =
  ## The GC roots that hold this case's private outputs: the resolver's
  ## (`<store>/nix-gc-roots`) and the provisioning engine's ledger, which
  ## roots the store paths an edge's receipt names
  ## (`<store>/provisioning/scratch/nix-gc-roots`).
  removeDir(f.storeRoot / "nix-gc-roots")
  removeDir(provisioningStateRoot(f.storeRoot) / "scratch" / "nix-gc-roots")

proc close(f: Fixture) =
  setCurrentDir(f.root.parentDir)
  # The helper's socket naming exists only where the helper does; on Windows
  # no case gets this far (see `PlatformSkipReason`), but the file still
  # compiles there.
  when not defined(windows):
    let socketPath = nixDaemonSocketPath(nixDaemonHelperKey(
      getEnv("REPROBUILD_NIX_DAEMON_BIN")))
    discard execCmd("pkill -f " & quoteShell(socketPath) & " || true")
  f.dropRoots()
  for path in f.realized:
    if path.len > 0 and dirExists(path):
      discard nixStore(["--delete", path])
  removeDir(f.root)

proc fixtureUse(lockTag: string): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "nix-tool-edge-fixture",
    packageSelector: "nix-tool-edge-fixture@1.0.0",
    executableName: ToolName,
    location: SourceLocation(file: "fixture", line: 1))
  result.nixProvisioning = @[InterfaceNixProvisioning(
    packageName: "nix-tool-edge-fixture",
    selector: FixtureSelector,
    executablePath: FixtureExecutable,
    packageId: "nix-tool-edge-fixture.1.0.0",
    lockIdentity: "fixture#nix-tool-edge-" & lockTag,
    location: SourceLocation(file: "fixture", line: 2))]

proc identityFor(use: InterfaceToolUse; storeRoot: string):
    PathOnlyBuildIdentity =
  let artifact = ProjectInterfaceArtifact(projectInterface: ProjectInterface(
    projectName: "nix-receipt-consumer", packageName: "nix-receipt-consumer",
    toolUses: @[use]))
  toolBuildIdentity(artifact, tpmNix, storeRoot = storeRoot)

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

proc consumerGraph(f: Fixture; id: string; refs: seq[string]): BuildGraph =
  let source = f.root / "src" / "input.txt"
  if not fileExists(source):
    createDir(source.parentDir)
    writeFile(source, "consumer input\n")
  let output = f.root / "out" / (id & ".txt")
  let depfile = f.root / "out" / (id & ".d")
  var consumer = action(id,
    [getAppFilename(), "fixture-consumer", source, output, depfile],
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    cwd = f.root, inputs = [source], outputs = [output],
    cacheable = true, dependencyPolicy = depfilePolicy(depfile))
  consumer.toolIdentityRefs = refs
  graph(@[consumer])

proc runConsumer(f: Fixture; g: BuildGraph;
                 identity: PathOnlyBuildIdentity): BuildRunResult =
  var config = defaultBuildEngineConfig(f.root / "scratch", f.root / "cache")
  config.bypassRunQuota = true
  config.maxParallelism = 1
  config.suppressTrace = true
  config.toolIdentityResolver = mkToolIdentityResolver(identity)
  runBuild(g, config)

suite "a Nix-realized tool is a provisioning edge with a receipt":

  test "the profile carries the receipt of a nix bakForeignProvision edge":
    if not HostRunsGate:
      skip(PlatformSkipReason)
    else:
      var f = openFixture()
      defer: f.close()
      let flake = f.privateFlake("a")
      setCurrentDir(flake)
      let use = fixtureUse(f.tag & "-a")
      let identity = identityFor(use, f.storeRoot)
      require identity.profiles.len == 1
      let profile = identity.profiles[0]
      f.realized.add(profile.selectedStorePath)
      checkpoint("realized: " & profile.selectedStorePath)
      checkpoint("receipt: " & profile.provisioningReceipt)
      check profile.selectedStorePath.startsWith("/nix/store/")
      check fileExists(profile.resolvedExecutablePath)
      # The unfixed resolver left this empty: no provisioning edge realized the
      # tool, so there was no receipt to name.
      check profile.provisioningReceipt.len > 0
      check fileExists(profile.provisioningReceipt)
      if fileExists(profile.provisioningReceipt):
        check profile.selectedStorePath in
          receiptPaths(profile.provisioningReceipt)
      check identity.actionIdentities[0].provisioningReceipt ==
        profile.provisioningReceipt

      # The receipt is the output of the edge, and the edge is a Nix
      # provisioning edge the engine's own "nix" provisioner executes.
      # `getCurrentDir()`, not `flake`: the resolver resolves against the working
      # directory as the OS reports it (`/private/tmp/…` on macOS).
      let edges = nixToolProvisioningEdges(use, f.storeRoot, getCurrentDir())
      require edges.actions.len == 1
      let edge = edges.actions[0]
      check edge.kind == bakForeignProvision
      check edge.argv.len == 2
      check edge.argv[0] == "nix"
      check edge.argv[1] == nixAcquisitionPlan(use).nixSelector
      check edge.outputs == @[profile.provisioningReceipt]
      check edges.rootReceipt == profile.provisioningReceipt
      # Resolved against the project directory, run from the tool store (the
      # engine's GC-root ledger keys an action by id and `cwd`, so a per-store
      # `cwd` is what lets a re-pin release the superseded realization).
      check parseJson(edge.builtinText){"workspaceRoot"}.getStr() ==
        getCurrentDir()
      check edge.cwd == f.storeRoot
      check edge.networkMode == netFetch
      # The flake a `.#…` selector is evaluated from is a declared input, so
      # an edit to it misses the action cache rather than serving the old
      # receipt (the helper's own report of these reads is attribution only).
      check getCurrentDir() / "flake.nix" in edge.inputs
      check getCurrentDir() / "flake.lock" in edge.inputs

  test "a consumer declares the receipt and is re-run by a new realization":
    if not HostRunsGate:
      skip(PlatformSkipReason)
    else:
      var f = openFixture()
      defer: f.close()
      let flakeA = f.privateFlake("a")
      setCurrentDir(flakeA)
      let identityA = identityFor(fixtureUse(f.tag & "-a"), f.storeRoot)
      let profileA = identityA.profiles[0]
      f.realized.add(profileA.selectedStorePath)
      let receipt = profileA.provisioningReceipt
      check receipt.len > 0

      let first = f.runConsumer(f.consumerGraph("consumer", @[ToolName]),
        identityA)
      let item = first.resultFor("consumer")
      check item.status == asSucceeded
      checkpoint("consumer inputs: " & $item.evidence.declaredInputs)
      # The unfixed resolver gave the consumer nothing to declare.
      check receipt.len > 0 and receipt in item.evidence.declaredInputs

      let again = f.runConsumer(f.consumerGraph("consumer", @[ToolName]),
        identityA)
      check again.resultFor("consumer").status in {asUpToDate, asCacheHit}
      check not again.resultFor("consumer").launched

      # A new realization of the SAME tool request (a bumped pin): a different
      # store path, the same receipt path, different receipt content.
      let flakeB = f.privateFlake("b")
      setCurrentDir(flakeB)
      let identityB = identityFor(fixtureUse(f.tag & "-b"), f.storeRoot)
      let profileB = identityB.profiles[0]
      f.realized.add(profileB.selectedStorePath)
      require profileB.selectedStorePath != profileA.selectedStorePath
      check profileB.provisioningReceipt == receipt
      if receipt.len > 0 and fileExists(receipt):
        check profileB.selectedStorePath in receiptPaths(receipt)
        check profileA.selectedStorePath notin receiptPaths(receipt)
      let repinned = f.runConsumer(f.consumerGraph("consumer", @[ToolName]),
        identityB)
      check repinned.resultFor("consumer").status == asSucceeded
      check repinned.resultFor("consumer").launched

      # An edge that names no provisioned tool declares no receipt.
      let plain = f.runConsumer(f.consumerGraph("plain", @[]), identityB)
      check plain.resultFor("plain").status == asSucceeded
      check receipt notin plain.resultFor("plain").evidence.declaredInputs

  test "a repeat is an action-cache hit; a collected realization is redone":
    if not HostRunsGate:
      skip(PlatformSkipReason)
    else:
      var f = openFixture()
      defer: f.close()
      let flake = f.privateFlake("a")
      setCurrentDir(flake)
      let use = fixtureUse(f.tag & "-a")
      let profile = resolveNixTool(use, f.storeRoot)
      let realized = profile.selectedStorePath
      f.realized.add(realized)
      check profile.provisioningReceipt.len > 0
      let edges = nixToolProvisioningEdges(use, f.storeRoot, getCurrentDir())

      # Run the edge again, as a resolution that missed its fast path would:
      # the action cache serves it and nothing is launched.
      let repeat = runProvisioningEdges(edges, f.storeRoot)
      let edgeResult = repeat.resultFor(edges.rootId)
      checkpoint("repeat edge status: " & $edgeResult.status)
      check edgeResult.status in {asUpToDate, asCacheHit}
      check not edgeResult.launched

      # The realization is collected (its tool-store roots dropped, then the
      # private output deleted). The action cache still holds a receipt naming
      # it; resolving must realize it again rather than serve that receipt.
      f.dropRoots()
      let deleted = nixStore(["--delete", realized])
      checkpoint("nix-store --delete -> " & $deleted.code & "\n" &
        deleted.output)
      require deleted.code == 0
      require not dirExists(realized)
      let again = resolveNixTool(use, f.storeRoot)
      check again.selectedStorePath == realized
      check dirExists(again.selectedStorePath)
      check fileExists(again.resolvedExecutablePath)
      check again.provisioningReceipt == profile.provisioningReceipt
      check realized in receiptPaths(again.provisioningReceipt)

  test "a resolution with no tool store has no receipt":
    if not HostRunsGate:
      skip(PlatformSkipReason)
    else:
      # A receipt is a consumer's declared input and must outlive the
      # resolution; with no tool store there is nowhere stable to keep it (see
      # `resolveNixTool`). The CLI always passes a store.
      var f = openFixture()
      defer: f.close()
      let flake = f.privateFlake("a")
      setCurrentDir(flake)
      let profile = resolveNixTool(fixtureUse(f.tag & "-a"))
      f.realized.add(profile.selectedStorePath)
      check profile.selectedStorePath.startsWith("/nix/store/")
      check fileExists(profile.resolvedExecutablePath)
      check profile.provisioningReceipt.len == 0
