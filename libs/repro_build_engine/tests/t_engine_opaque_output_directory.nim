## Opaque output directories: an obligatory output whose whole tree is the
## action's product, removed before every run, recorded whole and restored
## exactly. Build-Engine-And-Scheduler.md §"Opaque output directories".
##
## The precedent is BuildXL's exclusive opaque directory (wiped before the
## pip runs, every file found afterwards a required output, cleared before a
## cached tree is deployed) and Bazel's tree artifact. These cases drive the
## real scheduler, a real `sh` and the real local cache: nothing is mocked.
## Read filtering is exercised through a depfile, the one observed-input
## channel available without the monitor; `cacheInputPaths` applies the same
## `isRemovedOutputTreePath` test to the monitor's channels.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine

proc fixtureWrite(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)

proc opaqueFragment(actionId: string; extra = ""): string =
  "repro-dynamic-graph-v1\n" &
    "opaque-output\t" & actionId & "\tout\n" &
    "output\t" & actionId & "\tout/product.txt\n" & extra

suite "opaque output directories":

  test "removed before the run, recorded whole, restored exactly":
    let tempRoot = createTempDir("repro-opaque-output", "")
    defer: removeDir(tempRoot)
    let sh = findExe("sh")
    require sh.len > 0
    fixtureWrite(tempRoot / "input", "first\n")
    fixtureWrite(tempRoot / "outputs.rbdyn", opaqueFragment("build"))
    var config = defaultBuildEngineConfig(tempRoot / "cache")
    config.bypassRunQuota = true
    config.enableCachedOutputRestore()
    config.maxParallelism = 1
    # The command reads back an intermediate it wrote into the tree and
    # reports that read in its depfile, as a delegated tool reads its own
    # classes or objects while packaging them.
    let build = action("build", [sh, "-c",
      "mkdir -p out/sub; cp input out/sub/intermediate.txt; " &
      "cat out/sub/intermediate.txt > out/product.txt; " &
      "printf 'out/product.txt: input out/sub/intermediate.txt\\n' > build.d"],
      cwd = tempRoot, inputs = ["input", "outputs.rbdyn"], depfile = "build.d",
      dynamicDepsFile = "outputs.rbdyn", cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

    # A previous build's leftover is not this run's product.
    fixtureWrite(tempRoot / "out" / "stale.txt", "left over\n")
    let first = runBuild(graph([build]), config)
    checkpoint first.results[0].stderr
    check first.results[0].status == asSucceeded
    check readFile(tempRoot / "out" / "product.txt") == "first\n"
    check fileExists(tempRoot / "out" / "sub" / "intermediate.txt")
    check not fileExists(tempRoot / "out" / "stale.txt")
    # The tree deleted: a hit puts back every file of it. This needs the
    # intermediate the action read back (its depfile names it) to be left
    # out of the key: keyed, it would be absent at lookup and the record
    # could never answer.
    removeDir(tempRoot / "out")
    let restored = runBuild(graph([build]), config)
    checkpoint restored.results[0].stderr
    check restored.results[0].status == asCacheHit
    check readFile(tempRoot / "out" / "product.txt") == "first\n"
    check readFile(tempRoot / "out" / "sub" / "intermediate.txt") == "first\n"

    # A tree that differs from the record (an extra entry, a missing product)
    # is replaced by the recorded tree, extra entry removed.
    fixtureWrite(tempRoot / "out" / "extra.txt", "not in the record\n")
    removeFile(tempRoot / "out" / "product.txt")
    let exact = runBuild(graph([build]), config)
    checkpoint exact.results[0].stderr
    check exact.results[0].status == asCacheHit
    check readFile(tempRoot / "out" / "product.txt") == "first\n"
    check not fileExists(tempRoot / "out" / "extra.txt")

    # New inputs: the action runs again from an empty tree.
    fixtureWrite(tempRoot / "input", "second\n")
    fixtureWrite(tempRoot / "out" / "stale.txt", "left over\n")
    let rerun = runBuild(graph([build]), config)
    check rerun.results[0].status == asSucceeded
    check readFile(tempRoot / "out" / "product.txt") == "second\n"
    check not fileExists(tempRoot / "out" / "stale.txt")

  test "an obligatory product inside the tree still fails when absent":
    let tempRoot = createTempDir("repro-opaque-obligation", "")
    defer: removeDir(tempRoot)
    let sh = findExe("sh")
    require sh.len > 0
    fixtureWrite(tempRoot / "outputs.rbdyn", opaqueFragment("build"))
    var config = defaultBuildEngineConfig(tempRoot / "cache")
    config.bypassRunQuota = true
    config.maxParallelism = 1
    # The tool writes its tree but names the product differently from what
    # discovery promised: the edge fails, naming the promised path.
    let build = action("build", [sh, "-c",
      "mkdir -p out; echo x > out/renamed.txt; printf 'out/renamed.txt:\\n' > build.d"],
      cwd = tempRoot, inputs = ["outputs.rbdyn"], depfile = "build.d",
      dynamicDepsFile = "outputs.rbdyn", cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let outcome = runBuild(graph([build]), config)
    checkpoint $outcome.results[0].status & " " & outcome.results[0].stderr
    check outcome.results[0].status == asFailed
    check outcome.results[0].missingOutputs.len == 1
    check outcome.results[0].missingOutputs[0].replace('\\', '/').endsWith(
      "out/product.txt")

  test "the fragment that declares a tree must key the action":
    let tempRoot = createTempDir("repro-opaque-unkeyed", "")
    defer: removeDir(tempRoot)
    fixtureWrite(tempRoot / "outputs.rbdyn", opaqueFragment("build"))
    var config = defaultBuildEngineConfig(tempRoot / "cache")
    config.bypassRunQuota = true
    config.dryRun = true
    let build = action("build", ["unused"], cwd = tempRoot,
      dynamicDepsFile = "outputs.rbdyn",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    expect BuildEngineError:
      discard runBuild(graph([build]), config)
    fixtureWrite(tempRoot / "empty.rbdyn",
      "repro-dynamic-graph-v1\nopaque-output\tbuild\t\n")
    var emptyPath = build
    emptyPath.dynamicDepsFile = "empty.rbdyn"
    emptyPath.inputs = @["empty.rbdyn"]
    expect BuildEngineError:
      discard runBuild(graph([emptyPath]), config)

  test "a tree is exclusive to its action, whatever the order":
    let tempRoot = createTempDir("repro-opaque-exclusive", "")
    defer: removeDir(tempRoot)
    var config = defaultBuildEngineConfig(tempRoot / "cache")
    config.bypassRunQuota = true
    config.dryRun = true
    var owner = action("owner", ["unused"], cwd = tempRoot,
      outputs = ["out"],
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    owner.removeBeforeRun = @["out"]
    # Ordered after the owner, and still refused: the owner's next run would
    # remove this output. (R7 lets ordered write scopes overlap; a removed
    # tree may not.)
    let inside = action("inside", ["unused"], cwd = tempRoot,
      deps = ["owner"], outputs = ["out/later.txt"],
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    expect BuildEngineError:
      discard runBuild(graph([owner, inside]), config)
    var scope = inside
    scope.outputs = @[]
    scope.declaredOutputs = @["out/sub"]
    expect BuildEngineError:
      discard runBuild(graph([owner, scope]), config)
    # Beside the tree is fine.
    var beside = inside
    beside.outputs = @["outside.txt"]
    let ok = runBuild(graph([owner, beside]), config)
    check ok.results.len == 2
    # The same through a dynamic record, against a statically declared output.
    fixtureWrite(tempRoot / "outputs.rbdyn",
      "repro-dynamic-graph-v1\nopaque-output\tdynamic\tdyn\n")
    let dynamicOwner = action("dynamic", ["unused"], cwd = tempRoot,
      inputs = ["outputs.rbdyn"], dynamicDepsFile = "outputs.rbdyn",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let staticInside = action("static-inside", ["unused"], cwd = tempRoot,
      outputs = ["dyn/file.txt"],
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    expect BuildEngineError:
      discard runBuild(graph([dynamicOwner, staticInside]), config)

  test "the cwd a tree lives in is not keyed, however the monitor spells it":
    # `cabal v2-build` lists and probes its working directory, the parent of
    # its build tree; the monitor reports that as `<cwd>/.` and `<cwd>/./.`.
    # Keyed, the cwd's listing changes whenever the tree is deleted, and the
    # record can never restore it. Its membership is the action's own doing
    # (the tree is its output), so only `<cwd>` itself may stay, and only
    # as an existence probe -- which `cacheInputPaths` drops for an output's
    # ancestor.
    let tempRoot = createTempDir("repro-opaque-dot", "")
    defer: removeDir(tempRoot)
    # The tree exists, as it does when a run's evidence is folded.
    createDir(tempRoot / "dist" / "cache")
    let work = tempRoot.replace('\\', '/')
    var act = action("build", ["unused"], cwd = work, outputs = ["dist"],
      cacheable = true, monitorDepfile = work / "build.rdep",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    act.removeBeforeRun = @["dist"]
    var evidence: PathSetEvidence
    evidence.declaredOutputs = act.outputs
    for spelling in [work, work & "/.", work & "/./."]:
      evidence.monitorProbes.observeAll(evidence.evidenceProvenance,
        evcMonitorCapture, [spelling])
      evidence.monitorDirectoryEnumerations.observeAll(
        evidence.evidenceProvenance, evcMonitorCapture, [spelling])
    evidence.monitorReads.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, [work & "/./hello.cabal", work & "/dist/./cache/plan.json"])
    let inputs = act.cacheInputPaths(evidence)
    for path in inputs:
      check not path.replace('\\', '/').endsWith("/.")
      check path.replace('\\', '/') != work
      check "/dist/" notin path.replace('\\', '/')
    var sawManifest = false
    for path in inputs:
      if path.replace('\\', '/').endsWith("hello.cabal"):
        sawManifest = true
    check sawManifest
    check act.cacheEnumeratedDirectories(evidence).len == 0

  test "a tree may not contain its action's cwd or declared inputs":
    let tempRoot = createTempDir("repro-opaque-containment", "")
    defer: removeDir(tempRoot)
    var config = defaultBuildEngineConfig(tempRoot / "cache")
    config.bypassRunQuota = true
    config.dryRun = true
    var owner = action("owner", ["unused"], cwd = tempRoot / "work",
      outputs = ["."],
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    owner.removeBeforeRun = @["."]
    expect BuildEngineError:
      discard runBuild(graph([owner]), config)
    owner.outputs = @[".."]
    owner.removeBeforeRun = @[".."]
    expect BuildEngineError:
      discard runBuild(graph([owner]), config)
    owner.outputs = @["out"]
    owner.removeBeforeRun = @["out"]
    owner.inputs = @["out/config.txt"]
    expect BuildEngineError:
      discard runBuild(graph([owner]), config)
    owner.inputs = @["config.txt"]
    let ok = runBuild(graph([owner]), config)
    check ok.results.len == 1
