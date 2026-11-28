## A dynamically created action can be a member of named targets, and only
## of targets its producer is a member of.
##
## A `create-action` record may name `targetNames`. The engine gives the
## created action those names, as the DSL lowering gives a declared edge its
## target names, so a `--only`-style selector and the portable plane's
## materialization of named targets treat it as a member. A name its
## PRODUCER (the action whose `dynamicDepsFile` holds the record) is not a
## member of is refused: building a target selects the producer, so a
## fragment may add members to the targets the build selected, and may not
## open a target of its own.
##
## The fixture is a plain shell command. No mocks: the real engine runs the
## producer and ingests its fragment.
##
## Falsifying mutations: accepting any target name a record gives passes the
## refused cases and fails them; not stamping the record's `targetNames` on
## the created action fails the selector case and the trace check.

import std/[json, os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core/edge_determinism

proc fragment(root: string; targets: seq[string]) =
  writeFile(root / "frag.rbdyn", "repro-dynamic-graph-v1\ncreate-action\t" &
    $(%*{"id": "member", "argv": ["/bin/sh", "-c", "echo m > m.txt"],
         "cwd": root, "outputs": ["m.txt"], "targetNames": targets}) &
    "\ndep\tcollector\tmember\n")

proc collector(root: string; targets: seq[string]): BuildAction =
  result = action("collector", ["/bin/sh", "-c", "true"], cwd = root,
    dynamicDepsFile = "frag.rbdyn",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.targetNames = targets

proc run(root: string; producer: BuildAction): BuildRunResult =
  var config = defaultBuildEngineConfig(root / "cache")
  config.bypassRunQuota = true
  config.maxParallelism = 1'u32
  runBuild(graph([producer]), config)

proc details(run: BuildRunResult; id, event: string): seq[string] =
  for item in run.trace:
    if item.actionId == id and item.event == event:
      result.add item.detail

suite "a created action in its producer's named targets":

  test "a record naming its producer's target makes the action a member":
    let root = createTempDir("repro-created-targets-", "")
    defer: removeDir(root)
    fragment(root, @["cg5-target"])
    let res = run(root, collector(root, @["cg5-target", "other"]))
    check res.details("member", "action-create-targets") == @["cg5-target"]
    for r in res.results:
      if r.id == "member": check r.status == asSucceeded
    check fileExists(root / "m.txt")

  test "a record naming a target its producer is not in is refused":
    let root = createTempDir("repro-created-targets-refused-", "")
    defer: removeDir(root)
    fragment(root, @["elsewhere"])
    try:
      discard run(root, collector(root, @["cg5-target"]))
      checkpoint "the record was accepted"
      check false
    except BuildEngineError as err:
      check "names the target 'elsewhere'" in err.msg
    check not fileExists(root / "m.txt")

  test "a producer in no target cannot give a created action one":
    let root = createTempDir("repro-created-targets-none-", "")
    defer: removeDir(root)
    fragment(root, @["cg5-target"])
    expect BuildEngineError:
      discard run(root, collector(root, @[]))

  test "a record naming no target is accepted from any producer":
    let root = createTempDir("repro-created-targets-empty-", "")
    defer: removeDir(root)
    fragment(root, @[])
    let res = run(root, collector(root, @[]))
    check res.details("member", "action-create-targets").len == 0
    check fileExists(root / "m.txt")

  test "a selector naming the target selects the created action":
    # `--only` (`rebuildOnly`) matches an action by its id or by a target
    # name it carries (`matchesOnlySelector`). The action the engine builds
    # from the record carries the record's target names, so a selector that
    # names the target, and not the action, selects it.
    let spec = parseCreatedActionSpec($(%*{"id": "member",
      "argv": ["/bin/true"], "targetNames": ["cg5-target"]}))
    let created = createdAction(spec, lockIdentityOutsideSolvedGraph())
    var config = defaultBuildEngineConfig("/nonexistent-cache")
    config.rebuildClass = rbHard
    config.rebuildOnly = @["cg5-target"]
    check rebuildSelectorInvalidates(config, created)
    config.rebuildOnly = @["another-target"]
    check not rebuildSelectorInvalidates(config, created)
