## M25 — engine-side action-create dyndep record support.
##
## Library-local unit tests that exercise the engine's ``create-action``
## dyndep ingest pipeline without depending on a RunQuota daemon. Each
## case prepares a static graph + pre-written ``.rbdyn`` fragment and
## runs the engine with ``bypassRunQuota: true`` so the assertions are
## entirely owned by ``runBuild``'s in-process scheduler.
##
## Spec reference: ``Standard-Provider-Implementation.milestones.org`` §M25.
## The named test in the milestone is ``test_engine_action_create_dyndep_record``
## — its scope is "encode + decode an action-create .rbdyn record; engine
## materialises the action".

import std/[json, os, strutils, tempfiles, unittest]

import repro_build_engine
from repro_local_store import LogicalRoot, lrkTracked

proc fixtureWrite(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)

suite "M25 engine action-create dyndep ingest":

  test "create-action dyndep record materialises into the dry-run graph":
    # Dry-run exercises the scheduler's bookkeeping without launching any
    # subprocess. The synthesised action declares argv pointing at a
    # placeholder; the dry-run path marks it ``asWouldRun`` once its
    # deps clear. The key assertion is that the materialised action
    # appears in ``buildResult.results`` AND its dependents see it.
    let tempRoot = createTempDir("repro-m25-engine-dryrun", "")
    defer: removeDir(tempRoot)

    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let fragmentPath = workRoot / "consumer.rbdyn"

    let createJson = $(%*{
      "id": "synth-compile",
      "argv": ["/bin/echo", "synth"],
      "cwd": workRoot,
      "outputs": ["synth.o"],
      "commandStatsId": "m25-engine-synth-compile"
    })
    fixtureWrite(fragmentPath,
      "repro-dynamic-graph-v1\n" &
      "create-action\t" & createJson & "\n" &
      "dep\tconsumer\tsynth-compile\n")

    var config = defaultBuildEngineConfig(cacheRoot)
    config.maxParallelism = 2'u32
    config.bypassRunQuota = true
    config.dryRun = true
    config.stdoutLimit = 65536
    config.stderrLimit = 65536

    let buildResult = runBuild(graph([
      action("consumer", ["/bin/echo", "consumer"], cwd = workRoot,
        outputs = ["consumer.out"],
        dynamicDepsFile = "consumer.rbdyn",
        commandStatsId = "m25-engine-consumer",
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
    ]), config)

    proc byId(id: string): ActionResult =
      for item in buildResult.results:
        if item.id == id:
          return item
      raise newException(ValueError, "missing result " & id)

    # The synth action MUST be in the result set even though it never
    # appeared in the static graph — that's the load-bearing assertion
    # of the milestone.
    check byId("synth-compile").status == asWouldRun
    check byId("consumer").status == asWouldRun

  test "create-action with self-cycle dep is rejected":
    let tempRoot = createTempDir("repro-m25-engine-self-cycle", "")
    defer: removeDir(tempRoot)

    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let fragmentPath = workRoot / "consumer.rbdyn"

    let createJson = $(%*{
      "id": "self-cycle",
      "argv": ["/bin/echo", "noop"],
      "cwd": workRoot,
      "outputs": ["self.txt"],
      "deps": ["self-cycle"]
    })
    fixtureWrite(fragmentPath,
      "repro-dynamic-graph-v1\n" &
      "create-action\t" & createJson & "\n")

    var config = defaultBuildEngineConfig(cacheRoot)
    config.bypassRunQuota = true
    config.dryRun = true
    config.maxParallelism = 1'u32
    config.stdoutLimit = 65536
    config.stderrLimit = 65536

    expect BuildEngineError:
      discard runBuild(graph([
        action("consumer", ["/bin/echo", "consumer"], cwd = workRoot,
          outputs = ["consumer.out"],
          dynamicDepsFile = "consumer.rbdyn",
          governingLockIdentity = lockIdentityOutsideSolvedGraph())
      ]), config)

  test "create-action with duplicate declared output is rejected":
    let tempRoot = createTempDir("repro-m25-engine-dup-output", "")
    defer: removeDir(tempRoot)

    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let fragmentPath = workRoot / "consumer.rbdyn"

    # ``consumer.out`` is already declared by the consumer in the static
    # graph; a create-action record that re-declares the same output
    # must raise BuildEngineError.
    let createJson = $(%*{
      "id": "dup-output",
      "argv": ["/bin/echo", "dup"],
      "cwd": workRoot,
      "outputs": ["consumer.out"]
    })
    fixtureWrite(fragmentPath,
      "repro-dynamic-graph-v1\n" &
      "create-action\t" & createJson & "\n")

    var config = defaultBuildEngineConfig(cacheRoot)
    config.bypassRunQuota = true
    config.dryRun = true
    config.maxParallelism = 1'u32
    config.stdoutLimit = 65536
    config.stderrLimit = 65536

    expect BuildEngineError:
      discard runBuild(graph([
        action("consumer", ["/bin/echo", "consumer"], cwd = workRoot,
          outputs = ["consumer.out"],
          dynamicDepsFile = "consumer.rbdyn",
          governingLockIdentity = lockIdentityOutsideSolvedGraph())
      ]), config)

  test "fragment header without v1 banner is rejected":
    let tempRoot = createTempDir("repro-m25-engine-bad-banner", "")
    defer: removeDir(tempRoot)

    let workRoot = tempRoot / "work"
    let cacheRoot = tempRoot / ".repro-cache"
    createDir(workRoot)
    let fragmentPath = workRoot / "consumer.rbdyn"
    fixtureWrite(fragmentPath, "repro-dynamic-graph-v9\ncreate-action\t{}\n")

    var config = defaultBuildEngineConfig(cacheRoot)
    config.bypassRunQuota = true
    config.dryRun = true
    config.maxParallelism = 1'u32
    config.stdoutLimit = 65536
    config.stderrLimit = 65536

    expect BuildEngineError:
      discard runBuild(graph([
        action("consumer", ["/bin/echo", "consumer"], cwd = workRoot,
          outputs = ["consumer.out"],
          dynamicDepsFile = "consumer.rbdyn",
          governingLockIdentity = lockIdentityOutsideSolvedGraph())
      ]), config)

  test "dynamic optional byproducts preserve presence and absence through cache":
    # Real subprocess/depfile, engine and CAS. The fragment represents a
    # configure tool describing a conditional linker output before execution.
    let tempRoot = createTempDir("repro-dynamic-optional", "")
    defer: removeDir(tempRoot)
    let sh = findExe("sh")
    require sh.len > 0
    fixtureWrite(tempRoot / "input", "input")
    fixtureWrite(tempRoot / "outputs.rbdyn",
      "repro-dynamic-graph-v1\noptional-output\tlink\tmodule.lib\n")
    var config = defaultBuildEngineConfig(tempRoot / "cache")
    config.bypassRunQuota = true
    config.enableCachedOutputRestore()
    config.maxParallelism = 1
    config.portableLookup = true
    config.portableRoots = @[
      LogicalRoot(label: "project", path: tempRoot, kind: lrkTracked),
      LogicalRoot(label: "shell", path: parentDir(sh), kind: lrkTracked)]
    let link = action("link", [sh, "-c",
      "echo dll > module.dll; printf 'module.dll: input outputs.rbdyn\\n' > link.d; " &
      "read flag < input; if test \"$flag\" = exports; then echo lib > module.lib; fi"],
      cwd = tempRoot, outputs = ["module.dll"],
      inputs = ["input", "outputs.rbdyn"], depfile = "link.d",
      dynamicDepsFile = "outputs.rbdyn", cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    # Missing byproduct is a successful cacheable action, and its recorded
    # absence must remove a stale library on the next lookup.
    let first = runBuild(graph([link]), config)
    check first.results[0].status == asSucceeded
    check not fileExists(tempRoot / "module.lib")
    fixtureWrite(tempRoot / "module.lib", "stale")
    removeFile(tempRoot / "module.dll")
    let hit = runBuild(graph([link]), config)
    check hit.results[0].status == asCacheHit
    check fileExists(tempRoot / "module.dll")
    check not fileExists(tempRoot / "module.lib")
    fixtureWrite(tempRoot / "input", "exports\n")
    let withExports = runBuild(graph([link]), config)
    check withExports.results[0].status == asSucceeded
    check fileExists(tempRoot / "module.lib")
    checkpoint withExports.results[0].portableReason
    check withExports.results[0].portable
    check withExports.results[0].portableOutputs.len == 2
    removeFile(tempRoot / "module.dll")
    removeFile(tempRoot / "module.lib")
    let withExportsHit = runBuild(graph([link]), config)
    check withExportsHit.results[0].status == asCacheHit
    check readFile(tempRoot / "module.lib").strip == "lib"

  test "optional trees cannot erase independent producers or declared inputs":
    let tempRoot = createTempDir("repro-optional-ownership", "")
    defer: removeDir(tempRoot)
    var config = defaultBuildEngineConfig(tempRoot / "cache")
    config.bypassRunQuota = true
    config.dryRun = true
    let owner = action("install", ["unused"], cwd = tempRoot,
      optionalOutputs = ["stage"],
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let other = action("other", ["unused"], cwd = tempRoot,
      outputs = ["stage/other.txt"],
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    expect BuildEngineError:
      discard runBuild(graph([owner, other]), config)
    var malformed = owner
    malformed.optionalOutputs = @[""]
    expect BuildEngineError:
      discard runBuild(graph([malformed]), config)
    for candidate in [".", "..", tempRoot]:
      malformed.optionalOutputs = @[candidate]
      expect BuildEngineError:
        discard runBuild(graph([malformed]), config)
    malformed.optionalOutputs = @["stage/./product"]
    malformed.outputs = @["stage/product"]
    expect BuildEngineError:
      discard runBuild(graph([malformed]), config)
    fixtureWrite(tempRoot / "malformed.rbdyn", "repro-dynamic-graph-v1\ncreate-action\t" &
      $(%*{"id": "created", "argv": ["unused"], "cwd": tempRoot,
        "optionalOutputs": [""]}) & "\n")
    let dynamic = action("trigger", ["unused"], cwd = tempRoot,
      dynamicDepsFile = "malformed.rbdyn",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    expect BuildEngineError:
      discard runBuild(graph([dynamic]), config)
    var alternateSpelling = owner
    for candidate in ["stage/.", "elsewhere/../stage"]:
      alternateSpelling.optionalOutputs = @[candidate]
      expect BuildEngineError:
        discard runBuild(graph([alternateSpelling, other]), config)
    when not defined(windows):
      createDir(tempRoot / "real")
      createSymlink(tempRoot / "real", tempRoot / "alias")
      var throughAlias = owner
      throughAlias.optionalOutputs = @["alias/stage"]
      var throughReal = other
      throughReal.outputs = @["real/stage/other.txt"]
      expect BuildEngineError:
        discard runBuild(graph([throughAlias, throughReal]), config)
      throughAlias.inputs = @["real/stage/source.txt"]
      expect BuildEngineError:
        discard runBuild(graph([throughAlias]), config)
      # A final symlink is removed as a link, without owning its target.
      throughAlias.optionalOutputs = @["alias"]
      let linkOnly = runBuild(graph([throughAlias, throughReal]), config)
      check linkOnly.results.len == 2
    var selfRead = owner
    selfRead.inputs = @["stage"]
    expect BuildEngineError:
      discard runBuild(graph([selfRead]), config)
    selfRead.inputs = @["stage/nested/source"]
    expect BuildEngineError:
      discard runBuild(graph([selfRead]), config)
    # Explicit ordering retains the established sequential-writer contract.
    var ordered = other
    ordered.deps = @[owner.id]
    let valid = runBuild(graph([owner, ordered]), config)
    check valid.results.len == 2
    check valid.results[0].status == asWouldRun
    check valid.results[1].status == asWouldRun

  when not defined(windows):
    test "an optional output cannot remove a link the working directory is reached through":
      # An optional output `..` was accepted when the working directory is
      # reached through a symlinked `TMPDIR`. The engine removes an optional
      # candidate before the action runs, as the entry its spelling names.
      # Under a
      # working directory spelled `<link>/work`, `..` names the link. The
      # link does not contain the physical working directory, so a check
      # against the physical directory alone accepted it. The case builds
      # its own linked prefix, so it does not depend on how `TMPDIR` is
      # reached (macOS reaches its default one through `/var`).
      let tempRoot = createTempDir("repro-optional-linked-cwd", "")
      defer: removeDir(tempRoot)
      var config = defaultBuildEngineConfig(tempRoot / "cache")
      config.bypassRunQuota = true
      config.dryRun = true
      createDir(tempRoot / "phys" / "work")
      createDir(tempRoot / "phys" / "sibling")
      createDir(tempRoot / "far" / "deep")
      createDir(tempRoot / "far" / "work")
      createSymlink(tempRoot / "phys", tempRoot / "link")
      createSymlink("link", tempRoot / "outer")
      createSymlink("far/../phys/work", tempRoot / "direct")
      createSymlink(tempRoot / "far" / "deep", tempRoot / "detour")
      let linkedCwd = tempRoot / "link" / "work"
      let chainedCwd = tempRoot / "outer" / "work"
      let directCwd = tempRoot / "direct"
      # A parent walk after a link: the kernel starts the action in
      # `far/work`, and a relative output is joined onto the lexical `work`.
      let detourCwd = tempRoot & "/detour/../work"
      type Verdict = enum accepted, refusedForCwd, refusedOtherwise
      proc verdict(cwd, candidate: string): Verdict =
        let subject = action("install", ["unused"], cwd = cwd,
          optionalOutputs = [candidate],
          governingLockIdentity = lockIdentityOutsideSolvedGraph())
        try:
          let built = runBuild(graph([subject]), config)
          doAssert built.results.len == 1
          accepted
        except BuildEngineError as err:
          checkpoint err.msg
          if "optional output contains the action's cwd" in err.msg:
            refusedForCwd
          else:
            refusedOtherwise
      for cwd in [linkedCwd, chainedCwd]:
        for candidate in [".", "..", "../../link", "../../phys", "../work",
            cwd, tempRoot / "link", tempRoot / "phys",
            tempRoot / "phys" / "work", tempRoot / "link" / "work" / "..",
            tempRoot]:
          checkpoint cwd & " <- " & candidate
          check verdict(cwd, candidate) == refusedForCwd
      # The outer link is on the chained spelling only.
      check verdict(chainedCwd, tempRoot / "outer") == refusedForCwd
      check verdict(chainedCwd, "../../outer") == refusedForCwd
      check verdict(linkedCwd, tempRoot / "outer") == accepted
      # A working directory that is itself a link, whose target walks
      # through another directory.
      for candidate in [".", directCwd, "../direct", tempRoot / "far",
          tempRoot / "phys" / "work", tempRoot / "phys"]:
        checkpoint directCwd & " <- " & candidate
        check verdict(directCwd, candidate) == refusedForCwd
      for candidate in [".", "..", tempRoot / "detour",
          tempRoot / "far" / "deep", tempRoot / "far" / "work",
          tempRoot / "far", tempRoot / "work"]:
        checkpoint detourCwd & " <- " & candidate
        check verdict(detourCwd, candidate) == refusedForCwd
      # What the working directory is not reached through stays declarable.
      for cwd in [linkedCwd, chainedCwd]:
        for candidate in ["stage", "../sibling", tempRoot / "phys" / "sibling",
            tempRoot / "link" / "sibling", tempRoot / "detour",
            tempRoot / "far"]:
          checkpoint cwd & " <- " & candidate
          check verdict(cwd, candidate) == accepted
      check verdict(detourCwd, "stage") == accepted
      # A relative output is placed where the action runs (`far/work`), not
      # at the lexical `work`, so `../detour` names `far/detour`: not the link.
      check verdict(detourCwd, "../detour") == accepted
      check verdict(detourCwd, tempRoot / "link") == accepted
      # An opaque output directory is removed before the run the same way.
      var opaque = action("opaque", ["unused"], cwd = linkedCwd,
        outputs = [".."],
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      opaque.removeBeforeRun = @[".."]
      try:
        discard runBuild(graph([opaque]), config)
        fail()
      except BuildEngineError as err:
        check "output removed before run contains the action's cwd" in err.msg
