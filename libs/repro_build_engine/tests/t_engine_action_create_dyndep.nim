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
        commandStatsId = "m25-engine-consumer")
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
          dynamicDepsFile = "consumer.rbdyn")
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
          dynamicDepsFile = "consumer.rbdyn")
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
          dynamicDepsFile = "consumer.rbdyn")
      ]), config)
