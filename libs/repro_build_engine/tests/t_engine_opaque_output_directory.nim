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
import repro_test_support/reasoned_skip

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

  test "a link outside a removed tree that points into it stays an input":
    # A tree removed before the run holds only this run's writes, so what the
    # action observes INSIDE it is not an input. A symbolic link that sits
    # outside the tree is not inside it wherever it points: the link is the
    # entry, and its own state is a prior input. Monitor-Hook-Shim.md
    # §"Metadata, Probe, And Symlink APIs", "Both sides in one resolution".
    # The filter used to place a recorded path by `realpath`, which follows
    # the last component too, so `src/link -> ../gen/a.txt` read as a path
    # under `gen`, left the key, and retargeting it was a false hit
    # (reprobuild-pm issues/2026-11-18-output-tree-input-filter-drops-a-
    # symlink-that-points-into-the-tree.md).
    when defined(windows):
      # The filter resolves no link spelling on Windows (reprobuild-pm
      # issues/2026-10-27-restore-gate-symlink-spellings-are-not-resolved-on-
      # windows.md), so a link is never placed by its target there.
      skip("Windows resolves no link spelling in this filter, so a link " &
        "is never placed by its target there")
    else:
      let sh = findExe("sh")
      require sh.len > 0
      # Physical spelling, and an alias of it built here, so both are held
      # whatever `TMPDIR` is.
      let tempRoot = expandFilename(createTempDir("repro-opaque-link", ""))
      let alias = tempRoot & "-alias"
      defer:
        if symlinkExists(alias):
          removeFile(alias)
        removeDir(tempRoot)
      createSymlink(tempRoot, alias)
      fixtureWrite(tempRoot / "src" / "plain", "plain\n")
      createSymlink("../gen/a.txt", tempRoot / "src" / "link")
      createSymlink("../out", tempRoot / "src" / "dirlink")

      # The filter itself, on the monitor's channels, for an optional
      # candidate (`gen`) and an opaque directory (`out`).
      createDir(tempRoot / "gen")
      createDir(tempRoot / "out")
      writeFile(tempRoot / "gen" / "a.txt", "A\n")
      writeFile(tempRoot / "out" / "made.txt", "made\n")
      createSymlink("../src/plain", tempRoot / "out" / "inner")
      for work in [tempRoot, alias]:
        var act = action("build", ["unused"], cwd = work, outputs = ["out"],
          cacheable = true, monitorDepfile = work / "build.rdep",
          governingLockIdentity = lockIdentityOutsideSolvedGraph())
        act.optionalOutputs = @["gen"]
        act.removeBeforeRun = @["out"]
        for channel in ["read", "probe"]:
          var evidence: PathSetEvidence
          evidence.declaredOutputs = act.outputs
          # Every spelling of the same entries a tool or the monitor may
          # report: a trailing `/`, a `.` component, a parent walk.
          let observed = [work / "src/plain", work / "src/link",
                          work / "src/dirlink", work / "src/link/",
                          work & "/./src/link", work & "/src/./link",
                          work & "/src/../src/link"]
          if channel == "read":
            evidence.monitorReads.observeAll(evidence.evidenceProvenance,
              evcMonitorCapture, observed)
          else:
            evidence.monitorProbes.observeAll(evidence.evidenceProvenance,
              evcMonitorCapture, observed)
          let inputs = act.cacheInputPaths(evidence)
          checkpoint work & " " & channel & ": " & $inputs
          check work / "src/plain" in inputs
          check work / "src/link" in inputs
          check work / "src/dirlink" in inputs
          check work / "src/link/" in inputs
          check inputs.len == observed.len
      # Controls, in the physical spelling: the filter has not gone blind.
      # What is inside a tree is still dropped, and so is a path that reaches
      # the tree THROUGH a link (its ancestors are resolved; only a last
      # component is the entry). A link INSIDE a tree that leads out of it
      # is kept, as it was before: the action made it, but it is the only
      # recorded trace of the source file read through it.
      block:
        var act = action("build", ["unused"], cwd = tempRoot, outputs = ["out"],
          cacheable = true, monitorDepfile = tempRoot / "build.rdep",
          governingLockIdentity = lockIdentityOutsideSolvedGraph())
        act.optionalOutputs = @["gen"]
        act.removeBeforeRun = @["out"]
        var evidence: PathSetEvidence
        evidence.declaredOutputs = act.outputs
        evidence.monitorReads.observeAll(evidence.evidenceProvenance,
          evcMonitorCapture, [tempRoot / "gen/a.txt", tempRoot / "out/made.txt",
                              tempRoot / "src/dirlink/made.txt",
                              tempRoot / "src/plain", tempRoot / "out/inner"])
        check act.cacheInputPaths(evidence) ==
          @[tempRoot / "src/plain", tempRoot / "out/inner"]
        # The membership channel asks about the directory that was LISTED,
        # and listing follows a link: through `src/dirlink` it is the tree's
        # own entries, this run's writes. The listing is dropped; the link
        # stays an input as a probe (above). A directory that is not a tree
        # is still handed over.
        evidence.monitorDirectoryEnumerations.observeAll(
          evidence.evidenceProvenance, evcMonitorCapture,
          [tempRoot / "src/dirlink", tempRoot / "src/dirlink/",
           tempRoot / "out", tempRoot / "src"])
        check act.cacheEnumeratedDirectories(evidence, [tempRoot]) ==
          @[tempRoot / "src"]
      removeFile(tempRoot / "out" / "inner")
      removeDir(tempRoot / "gen")
      removeDir(tempRoot / "out")

      # End to end, through the depfile channel: the action reads through
      # the link, and retargeting the link must run it again.
      var config = defaultBuildEngineConfig(tempRoot / "cache")
      config.bypassRunQuota = true
      config.enableCachedOutputRestore()
      config.maxParallelism = 1
      var build = action("build", [sh, "-c",
        "mkdir -p gen; echo A > gen/a.txt; echo B > gen/other.txt; " &
        "cat src/link > product.txt; " &
        "printf 'product.txt: src/link src/plain\\n' > build.d"],
        cwd = tempRoot, inputs = ["src/plain"], outputs = ["product.txt"],
        depfile = "build.d", cacheable = true,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      build.optionalOutputs = @["gen"]
      let first = runBuild(graph([build]), config)
      checkpoint first.results[0].stderr
      require first.results[0].status == asSucceeded
      check readFile(tempRoot / "product.txt") == "A\n"
      # Unchanged: the link is keyed and still answers.
      let unchanged = runBuild(graph([build]), config)
      check unchanged.results[0].status == asCacheHit
      # Retargeted: same tree, another file of it. The target text has
      # another length, so the default timestamp policy sees the link change
      # whatever the filesystem's mtime granularity is
      # (Incremental-Invalidation.md §"Symlink inputs").
      removeFile(tempRoot / "src" / "link")
      createSymlink("../gen/other.txt", tempRoot / "src" / "link")
      let retargeted = runBuild(graph([build]), config)
      checkpoint retargeted.results[0].stderr
      check retargeted.results[0].status == asSucceeded
      check readFile(tempRoot / "product.txt") == "B\n"

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
