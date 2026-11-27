## Actions a dynamic graph fragment creates take part in the portable cache
## lookup, as declared edges do.
##
## The portable pre-pass resolves the STATIC graph before anything runs, so
## it never saw an action a `create-action` record adds while the build runs,
## nor anything downstream of a dynamic producer (whose fragment it cannot
## read ahead of time). Such an action is looked up at dispatch instead
## (`latePortableLookup`), when its dependencies have completed: an output of
## an ancestor that ran in this build is identified from disk, one served
## from a portable record from that record.
##
## The graph: a static `consumer` carries the fragment; the fragment creates
## `created.one` (`cp input.txt out/one.txt`) and `created.two` (depends on
## it, `cp out/one.txt out/two.txt`). Both are
## cacheable, content-checked (`hybrid`) and monitored, and both name their
## files relative to the checkout, so their records are portable. Checkout A
## builds it; checkout B, at another absolute path sharing A's action-cache
## root, builds it with the portable lookup on.
##
## What each case pins:
## * B executes neither created action, and gets A's bytes.
## * C, whose `input.txt` differs, executes `created.one` (its read differs)
##   and then `created.two` (its input, `out/one.txt`, has other content),
##   and produces C's bytes: a late lookup is keyed on this checkout's
##   inputs, ancestors' outputs from disk included, never on A's.
##
## Falsifying mutation: `latePortableLookup` returning false makes B execute
## both created actions, and the first case fails.
##
## MOCK POLICY: NO MOCKS. The real `runBuild` scheduler, the real fragment
## ingest, the real portable memo plane and output store, the graph-built
## io-monitor (`prepareMonitorTools`), real `cp` commands over real files.

import std/[os, strutils, unittest]

import repro_build_engine
import repro_core
import repro_local_store
import repro_test_support

const RepoRootMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

let TmpDir = absolutePath("build/test-tmp/t_created_actions_portable_lookup-" &
  testCaseScratchSlug())

var cachedMonitorTools: MonitorTools
var cachedMonitorToolsReady = false

proc monitorTools(repoRoot: string): MonitorTools =
  if not cachedMonitorToolsReady:
    cachedMonitorTools = prepareMonitorTools(repoRoot,
      repoRoot / "build" / "test-monitor-created-portable", "created-portable")
    putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
    cachedMonitorToolsReady = true
  cachedMonitorTools

const
  OneId = "created.one"
  TwoId = "created.two"

proc record(cwd, id: string; argv: openArray[string];
            inputs, outputs, deps: openArray[string]): string =
  ## A created action running ``argv``. No shell: a shell draws entropy at
  ## start-up (bash seeds `$RANDOM`), and an unblessed draw keeps the
  ## record from being published at all.
  var spec = initCreatedActionSpec(id, argv)
  spec.cwd = cwd
  spec.inputs = @inputs
  spec.outputs = @outputs
  spec.deps = @deps
  spec.cacheable = true
  spec.actionCachePolicy = ffpHybrid
  spec.policyKind = CreatedActionAutomaticMonitor
  spec.env = @["PATH=" & parentDir(findExe("cp", followSymlinks = false))]
  spec.isolateHostEnvironment = true
  "create-action\t" & createActionRecord(spec) & "\n"

proc newCheckout(name, input: string): string =
  result = TmpDir / name / "proj"
  createDir(result / "out")
  writeFile(result / "input.txt", input)
  writeFile(result / "frag.rbdyn", "repro-dynamic-graph-v1\n" &
    record(result, OneId, [findExe("cp", followSymlinks = false), "input.txt", "out/one.txt"],
      ["input.txt"], ["out/one.txt"], []) &
    record(result, TwoId, [findExe("cp", followSymlinks = false), "out/one.txt", "out/two.txt"],
      ["out/one.txt"], ["out/two.txt"], [OneId]) &
    "dep\tconsumer\t" & TwoId & "\n")

proc consumer(project: string): BuildAction =
  action("consumer", ["/bin/sh", "-c", "true"], cwd = project,
    dynamicDepsFile = "frag.rbdyn",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc build(repoRoot, project, shared: string; lookup: bool): BuildRunResult =
  let tools = monitorTools(repoRoot)
  var config = defaultBuildEngineConfig(project.parentDir / "cache")
  config.bypassRunQuota = true
  config.fallbackToRunQuotaBypass = true
  config.maxParallelism = 1'u32
  config.monitorCliPath = tools.monitorCliPath
  config.monitorCliArgs = tools.monitorCliArgs
  config.actionCacheRoot = shared
  # The Nix store is a root too: `cp` and its libraries are read from it,
  # and a read outside every root keeps a record off the portable plane.
  config.portableRoots = @[
    LogicalRoot(label: "project", path: project, kind: lrkTracked),
    LogicalRoot(label: "nix", path: "/nix/store", kind: lrkTracked)]
  config.portableContentCheckedOnly = true
  config.portableLookup = lookup
  result = runBuild(graph([consumer(project)]), config)
  for r in result.results:
    checkpoint(r.id & ": " & $r.status & " launched=" & $r.launched & " " &
      r.reason & " portable=" & $r.portable & " " & r.portableReason &
      " skip=" & r.cachePublishSkipReason &
      (if r.stderr.len > 0: "\nstderr: " & r.stderr else: ""))
  for item in result.trace:
    if item.event.startsWith("portable"):
      checkpoint(item.actionId & " " & item.event & ": " & item.detail)
  for r in result.results:
    require r.status in {asSucceeded, asCacheHit, asUpToDate}

proc resultOf(run: BuildRunResult; id: string): ActionResult =
  for r in run.results:
    if r.id == id:
      return r
  raise newException(KeyError, "no result for " & id)

proc events(run: BuildRunResult; id, event: string): int =
  for item in run.trace:
    if item.actionId == id and item.event == event:
      inc result

suite "created actions are looked up in the portable plane":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)

  test "a second checkout is served both created actions":
    let repoRoot = findRepoRoot()
    let shared = TmpDir / "shared"
    let a = newCheckout("a", "alpha\n")
    let first = build(repoRoot, a, shared, lookup = false)
    check first.resultOf(OneId).launched
    check first.resultOf(TwoId).launched
    check readFile(a / "out" / "two.txt") == "alpha\n"

    let b = newCheckout("b", "alpha\n")
    let second = build(repoRoot, b, shared, lookup = true)
    for id in [OneId, TwoId]:
      checkpoint id
      check not second.resultOf(id).launched
      check second.resultOf(id).portable
      check second.events(id, "portable-resolved") == 1
    check readFile(b / "out" / "one.txt") == "alpha\n"
    check readFile(b / "out" / "two.txt") == "alpha\n"

  test "a checkout whose input differs executes both, with its own bytes":
    let repoRoot = findRepoRoot()
    let shared = TmpDir / "shared"
    let a = newCheckout("a", "alpha\n")
    discard build(repoRoot, a, shared, lookup = false)

    let c = newCheckout("c", "gamma\n")
    let third = build(repoRoot, c, shared, lookup = true)
    for id in [OneId, TwoId]:
      checkpoint id
      check third.resultOf(id).launched
      check third.events(id, "portable-resolved") == 0
    check readFile(c / "out" / "two.txt") == "gamma\n"
