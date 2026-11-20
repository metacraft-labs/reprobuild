## An edge that reads a SHARED content-keyed tool cache never offers its
## results to another host.
##
## Issue: reprobuild-pm
## `issues/2026-11-12-content-keyed-tool-caches-are-shared-as-widely-as-correctness-allows-with-no-trust.md`.
## Governing text: Tool-Owned-Caches.md §"Trust Boundary" and
## Edge-Determinism-And-Soft-Rebuild.md §1.4.
##
## THE ATTACK. `go_package` gives every Go build edge of a project one
## `GOCACHE` (and one `GOMODCACHE`) under `.repro/build/go/`, and leaves both
## out of the edge's dependency evidence. Go serves a cached compile by the
## name its entry is stored under and never re-hashes the bytes. So anyone who
## can write that directory -- another edge of the project, or whoever wrote
## it before -- decides what the Go build edge links, while the edge's key,
## which covers its sources and not the cache, does not move. A record made
## that way and published says to every other host "these outputs follow from
## this key", and they do not.
##
## WHAT IS DONE HERE, all of it production code except the two seams below:
##
##   1. The real `go_package` constructor declares the edges of a project in
##      a temporary directory, through the real provider-mode
##      `buildPackageFragment`, and the real `lowerProviderSnapshot` lowers
##      them into engine actions.
##   2. The real engine (`runBuild`) runs them. The build edge's real script
##      runs the real `go build` against the project's real `GOCACHE`. Its
##      binary prints a sentence taken from its source.
##   3. The attacker -- a second writer of that cache -- rewrites the cached
##      compile in place, a same-length replacement of the sentence, as any
##      process able to write the directory can. Nothing in the checkout
##      changes.
##   4. A fresh build (a new engine cache root, the output removed) runs the
##      same edge: the binary now prints the attacker's sentence, and the
##      edge's portable strong fingerprint is the one the clean build had.
##      That is the failure the design permits, demonstrated rather than
##      argued.
##   5. The property: neither record -- the clean one nor the poisoned one --
##      reaches the peer-cache publisher, the portable-memo publisher or the
##      binary-cache publisher, and the trace names the cache. Before the fix
##      every one of them reached the binary-cache publisher, and, for an edge
##      whose input-check policy is content-checked, the peer and portable
##      publishers too.
##
## The `timestamp` case is the edge exactly as lowered today: the `go` tool
## declares no input-check policy, so Caching-Architecture D2 leaves the edge
## on `timestamp`, which the peer and portable publishers already refuse, but
## which the binary-cache publisher in its intermediate scope is still
## offered. The `checksum` case sets the policy D2 would give the edge once
## its tool declares one (as `gcc` and `clang` already do), so all three
## publishers are graded on the same records.
##
## A control in the same harness (a builtin edge with one declared input and
## no tool cache) is offered to all three publishers, so the hooks are live
## and the refusals above are not an artefact of the harness.
##
## MOCK POLICY. Two seams, each justified by what is under test -- what the
## ENGINE offers each cross-host publisher:
##
##   * The publishers are recording closures in the engine's own hook slots
##     (`peerCacheActionPublisher`, `portableMemoPublisher`,
##     `binaryCachePublisher`), as in `t_publishers_refuse_level1_records`.
##     The real publishers behind those slots are exercised against real
##     stores elsewhere; the question here is whether the engine offers them
##     the record at all.
##   * The build edge's monitor capture is supplied as a prewired
##     `monitorDepfile` in io-mon's own encoding (the seam a direct engine
##     caller uses), naming the reads the edge makes of its sources and, in
##     the poisoned build, of every entry of the cache. On Linux the preload
##     monitor cannot enter the Go toolchain: its binaries are statically
##     linked (no `PT_INTERP`), and io-mon records an exec into a static
##     image as event loss (`exec_image_injectability.h`), so a real capture
##     is incomplete and the record is withheld before any publisher is
##     reached. A backend that can see into Go (macOS interposition, or a
##     non-preload Linux backend) produces the complete capture supplied
##     here, and that is the case the rule exists for. The capture's cache
##     reads are dropped by the edge's own ignored roots, which is the
##     production path that keeps the cache out of the key.
##
## Needs `go` (on `PATH`, else realised through `nix` from the catalog's Go
## expression). Without either the case is skipped with the reason, unless
## `REPRO_GO_CACHE_TRUST_REQUIRED=1`, which makes their absence a failure.

import std/[os, osproc, strutils, unittest]

import repro_build_engine
import repro_cli_support
import repro_core
import repro_core/paths
import repro_local_store
from repro_cas_store import CasStore
import repro_project_dsl
import repro_provider_runtime
import repro_tool_profiles
import repro_dsl_stdlib/constructors/go_package
import repro_test_support/process_fixtures
import repro_test_support/reasoned_skip
import io_mon/[capabilities, types, writer]

const
  PkgName = "goCacheTrustVictim"
  RequiredEnv = "REPRO_GO_CACHE_TRUST_REQUIRED"
  GoExpression = currentSourcePath.parentDir.parentDir.parentDir /
    "libs" / "repro_dsl_stdlib" / "src" / "repro_dsl_stdlib" / "packages" /
    "nix" / "go-1.25.4" / "default.nix"
  # The same length on purpose: the attacker rewrites the cached compile in
  # place, and Go checks only the size an entry records, not its digest.
  VictimSentence = "built from the checked-in source"
  PlantedSentence = "PLANTED BY ANOTHER CACHE WRITER!"
  MainGo = "package main\n\nimport \"os\"\n\nfunc main() { " &
    "os.Stdout.WriteString(\"" & VictimSentence & "\\n\") }\n"
  GoMod = "module example.com/hello\n\ngo 1.21\n"

static:
  doAssert VictimSentence.len == PlantedSentence.len

proc goBinDir(): tuple[dir, why: string] =
  ## The directory of a `go` to put on the actions' `PATH`, or why there is
  ## none.
  let onPath = findExe("go")
  if onPath.len > 0:
    return (onPath.parentDir, "")
  if findExe("nix").len == 0:
    return ("", "neither go nor nix is on PATH")
  let (output, code) = execCmdEx(quoteShellCommand(["nix", "build",
    "--no-link", "--print-out-paths", "--file", GoExpression]))
  if code != 0:
    return ("", "nix could not realise " & GoExpression & ": " & output)
  for line in output.splitLines():
    if line.startsWith("/nix/store/") and
        fileExists(line.strip() / "bin" / "go"):
      return (line.strip() / "bin", "")
  ("", "nix realised no go: " & output)

proc writeCapture(path: string; reads: seq[string]) =
  ## An io-mon capture in io-mon's own encoding: the host's backend profile
  ## records (without them the edge fails closed on the entropy
  ## observability policy instead) and one read per path.
  var records = profileRecords(defaultHooksMonitorProfile())
  for read in reads:
    records.add(MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
      osPid: 4242, threadId: 4242, path: read, detail: ""))
  let raw = encodeCanonical(records)
  var text = newString(raw.len)
  if raw.len > 0:
    copyMem(addr text[0], unsafeAddr raw[0], raw.len)
  writeFile(path, text)

proc newProject(root: string): string =
  result = root / "proj"
  createDir(result / "src")
  writeFile(result / "src" / "go.mod", GoMod)
  writeFile(result / "src" / "main.go", MainGo)

proc loweredGoEdges(project: string): seq[BuildAction] =
  ## The project's Go edges as `repro build` would hand them to the engine:
  ## declared by the real constructor in provider mode (so its paths are
  ## absolute under `project`), then lowered by the real lowering.
  let request = ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "t-go-cache-trust",
    entryPointId: PkgName & ".root",
    entryPointBodyHash: PkgName & ".build.v1",
    reason: girExplicitUserRequest,
    arguments: project,
    namespace: "project-" & PkgName)
  let fragment = buildPackageFragment(PackageDef(packageName: PkgName),
    request, proc () = discard go_package("hello"), includeDefault = false)
  let snapshot = ProviderGraphSnapshot(fragments: @[StoredGraphFragment(
    providerArtifactId: request.providerArtifactId,
    entryPointId: fragment.entryPointId,
    entryPointBodyHash: fragment.entryPointBodyHash,
    arguments: fragment.arguments,
    namespace: fragment.namespace,
    nodes: fragment.nodes,
    edges: fragment.edges)])
  lowerProviderSnapshot(snapshot, PathOnlyBuildIdentity(), project,
    @["go-build-" & PkgName]).actions

proc buildEdgeOf(actions: seq[BuildAction]): BuildAction =
  for action in actions:
    if action.id.startsWith("go-build-"):
      return action
  raise newException(ValueError, "no go build edge was lowered")

type
  Offered = object
    ## What one build offered the three cross-host publishers.
    peer: int
    portable: int
    binary: int
    trace: string
    result: ActionResult

proc publishingConfig(project, cacheRoot: string;
                      offered: ref Offered): BuildEngineConfig =
  ## Every cross-host publisher wired, as recording closures, and the
  ## portable fingerprint computed for every edge (`REPRO_PORTABLE_CACHE=1`),
  ## so each record is judged by all three.
  result = defaultBuildEngineConfig(cacheRoot)
  result.maxParallelism = 1
  result.bypassRunQuota = true
  result.fallbackToRunQuotaBypass = true
  # The edge's script runs under a shell and Go from the host's tool store,
  # and a read outside every logical root makes the portable fingerprint
  # unavailable (`portable-fingerprint-unavailable`), which would leave the
  # same-key claim below untested. So the tool store is a tracked root, as
  # a host that shares records with others declares it, and the
  # conventional system directories (where `/bin/sh` lives off Nix) are
  # untracked host roots.
  result.portableRoots = @[
    LogicalRoot(label: "project", path: project, kind: lrkTracked),
    LogicalRoot(label: "toolstore", path: "/nix/store", kind: lrkTracked)]
  for dir in ["/bin", "/usr", "/lib", "/lib64", "/etc"]:
    result.portableRoots.add(LogicalRoot(label: "system" & dir.replace('/', '-'),
      path: dir, kind: lrkUntracked))
  result.portableContentCheckedOnly = false
  result.binaryCacheIntermediateScope = true
  result.portableMemoPublisher = proc (roots: seq[LogicalRoot];
      record: PortableMemoRecord; withOutputs: bool): string {.gcsafe.} =
    {.cast(gcsafe).}:
      inc offered.portable
    ""
  result.peerCacheActionPublisher = proc (query: PeerCacheActionQuery;
      record: ActionResultRecord; cas: var CasStore) {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      inc offered.peer
  result.binaryCachePublisher = proc (req: BinaryCachePublishRequest):
      BinaryCachePublishResult {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      inc offered.binary
    BinaryCachePublishResult(ok: true, statusCode: 200)

proc collect(run: BuildRunResult; id: string; offered: ref Offered): Offered =
  result = offered[]
  for event in run.trace:
    if event.actionId == id:
      result.trace.add(event.event & ": " & event.detail & "\n")
  for item in run.results:
    if item.id == id:
      result.result = item

proc buildGo(project, cacheRoot: string; checksum: bool;
             cacheReads: seq[string]): Offered =
  ## One build of the project's Go edges. `cacheReads` are the cache entries
  ## the capture reports the build edge reading.
  var actions = loweredGoEdges(project)
  let captures = cacheRoot.parentDir / (cacheRoot.extractFilename & "-iomon")
  createDir(captures)
  for i in 0 ..< actions.len:
    let capture = captures / (actions[i].id & ".iomon")
    if actions[i].id.startsWith("go-build-"):
      writeCapture(capture, @[project / "src" / "go.mod",
        project / "src" / "main.go"] & cacheReads)
      if checksum:
        actions[i].actionCachePolicy = ffpChecksum
    else:
      writeCapture(capture, @[])
    actions[i].monitorDepfile = capture
  var offered: ref Offered
  new(offered)
  let config = publishingConfig(project, cacheRoot, offered)
  let run = runBuild(graph(actions, newSeq[BuildPool]()), config)
  result = collect(run, buildEdgeOf(actions).id, offered)
  checkpoint(result.trace)
  checkpoint(result.result.stderr)
  require result.result.status == asSucceeded

proc events(trace, event: string): seq[string] =
  for line in trace.splitLines():
    if line.startsWith(event & ": "):
      result.add(line)

proc runBinary(project: string): string =
  let binary = project / GoScratchSubdir / "out" / "usr" / "bin" / "hello"
  require fileExists(binary)
  let (output, code) = execCmdEx(quoteShell(binary))
  check code == 0
  output.strip()

proc cacheEntries(goCache: string): seq[string] =
  for path in walkDirRec(goCache):
    result.add(path)

proc plantInCache(goCache: string): int =
  ## The attacker: rewrite every cached entry that holds the victim's
  ## sentence. Same length, so the size Go records for the entry still
  ## matches; Go does not re-hash an entry it serves.
  for path in walkDirRec(goCache):
    if not path.endsWith("-d"):
      continue
    let bytes = readFile(path)
    if VictimSentence in bytes:
      writeFile(path, bytes.replace(VictimSentence, PlantedSentence))
      inc result

proc scratchDir(label: string): string =
  ## A scratch directory released when this process exits, registered
  ## before it is created (CONTRIBUTING.md, "one process per case").
  result = getTempDir() / ("repro-go-cache-trust-" & label & "-" &
    $getCurrentProcessId())
  releaseDirAtProcessExit(result)
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc setUpGoEnvironment(): string =
  ## "" when Go is usable, else why not. The actions inherit this process's
  ## environment (the lowered edges declare no tool profile, so `PATH` is
  ## inherited), so Go is pointed at private state here.
  let (dir, why) = goBinDir()
  if dir.len == 0:
    return why
  putEnv("PATH", dir & PathSep & getEnv("PATH"))
  let home = scratchDir("home")
  putEnv("HOME", home)
  putEnv("GOTELEMETRY", "off")
  putEnv("GOTOOLCHAIN", "local")
  putEnv("GOFLAGS", "")
  putEnv("GOPATH", home / "gopath")
  ""

proc attackScenario(checksum: bool)

template goCase(checksum: bool) =
  ## A template, not a proc, because `skip` marks the enclosing test.
  let why = setUpGoEnvironment()
  if why.len > 0:
    check getEnv(RequiredEnv) != "1"
    skip(why)
  else:
    attackScenario(checksum)

proc attackScenario(checksum: bool) =
  let root = scratchDir(if checksum: "checksum" else: "timestamp")
  let project = newProject(root)
  let goCache = goCacheDir(project)
  let modCache = goModCacheDir(project)

  # The clean build: the binary says what its source says.
  let clean = buildGo(project, root / "cache-clean", checksum, @[])
  check runBinary(project) == VictimSentence

  # The attacker writes the cache. Nothing in the checkout changes.
  let planted = plantInCache(goCache)
  require planted > 0
  removeFile(project / GoScratchSubdir / "out" / "usr" / "bin" / "hello")

  # A fresh build of the same edge, which reads every entry of the cache.
  let poisoned = buildGo(project, root / "cache-poisoned", checksum,
    cacheEntries(goCache))
  # The failure the design permits: outputs the attacker chose, under the
  # key the clean build had.
  check runBinary(project) == PlantedSentence
  check poisoned.result.portableStrongHex.len > 0
  check poisoned.result.portableStrongHex == clean.result.portableStrongHex

  # The property: neither record leaves this host.
  for (name, built) in [("clean", clean), ("poisoned", poisoned)]:
    checkpoint name
    check built.result.launched
    check built.peer == 0
    check built.portable == 0
    check built.binary == 0
    # Each refusal says why, naming the caches the edge reads.
    let binaryRefused = events(built.trace, "binary-cache-publish-refused")
    check binaryRefused.len == 1
    check binaryRefused.len == 1 and goCache in binaryRefused[0] and
      modCache in binaryRefused[0] and $edHostBound in binaryRefused[0]
    let portableRefused = events(built.trace, "portable-memo-host-bound")
    check portableRefused.len == 1
    check portableRefused.len == 1 and goCache in portableRefused[0]
    # The class is judged before the publication rule, so even the
    # `timestamp` record's refusal names the cache rather than its policy.
    let peerRefused = events(built.trace, "peer-cache-publish-refused")
    check peerRefused.len == 1
    check peerRefused.len == 1 and goCache in peerRefused[0]

suite "an edge reading a shared content-keyed tool cache stays on its host":

  test "the lowered go build edge names its caches and is host-bound (no Go needed)":
    # The constructor-to-engine half of the rule, checked without running
    # Go, so it holds on a host where the attack cases below skip: the
    # constructor names the caches, the payload codec and the lowering carry
    # them, and the engine composes the edge's class from them.
    let project = newProject(scratchDir("lowering"))
    let edge = buildEdgeOf(loweredGoEdges(project))
    check goCacheDir(project) in edge.contentKeyedToolCaches
    check goModCacheDir(project) in edge.contentKeyedToolCaches
    check edge.determinismClass == edHostBound
    check edge.crossHostRefusal().len > 0
    # Only the build edge reads them; the download edge is never cached.
    for action in loweredGoEdges(project):
      if action.id != edge.id:
        checkpoint action.id
        check action.contentKeyedToolCaches.len == 0

  test "the go build edge as lowered today (timestamp) is offered to no publisher":
    goCase(checksum = false)

  test "the go build edge under a content-checked policy is offered to no publisher":
    goCase(checksum = true)

  test "control: an edge reading no tool cache is offered to all three":
    let root = scratchDir("control")
    let project = root / "proj"
    createDir(project / "src")
    createDir(project / "out")
    writeFile(project / "src" / "input.txt", "input\n")
    let action = builtinAction(bakWriteText, "t-go-cache-trust-control",
      cwd = project,
      inputs = [project / "src" / "input.txt"],
      outputs = [project / "out" / "result.txt"],
      cacheable = true,
      actionCachePolicy = ffpChecksum,
      text = "built\n",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    var offered: ref Offered
    new(offered)
    let run = runBuild(graph(@[action], newSeq[BuildPool]()),
      publishingConfig(project, root / "cache", offered))
    let built = collect(run, action.id, offered)
    checkpoint(built.trace)
    require built.result.status == asSucceeded
    check built.peer == 1
    check built.portable == 1
    check built.binary == 1
