## A dynamically created action (a `create-action` record of a
## `repro-dynamic-graph-v1` fragment) can be launched from its declared
## environment alone and can have scratch directories, as a declared edge
## can (`BuildAction.isolateHostEnvironment`, `BuildAction.scratchDirs`).
##
## A graph-production edge that writes the actions of a build it planned (the
## cargo plan's unit edges, for one) needs both: a unit's key must not move
## with the shell the engine runs in, and rustc's incremental directory is
## state the next run must not read. The fixture is a plain shell command,
## not a compiler, so the test is about the engine alone.
##
## No mocks: the engine runs the real producer and the real created action
## through `runBuild`, with RunQuota bypassed (the scheduler under test is
## the engine's own).

import std/[json, os, strutils, tempfiles, unittest]

import repro_build_engine

const Leak = "REPRO_T_CREATED_ACTION_LEAK"

proc writeFragment(path: string; records: openArray[JsonNode];
                   collector: string) =
  var text = "repro-dynamic-graph-v1\n"
  for r in records:
    text.add "create-action\t" & $r & "\n"
    text.add "dep\t" & collector & "\t" & r["id"].getStr() & "\n"
  createDir(parentDir(path))
  writeFile(path, text)

proc collector(root: string): BuildAction =
  action("collector", ["/bin/sh", "-c", "true"], cwd = root,
    dynamicDepsFile = "frag.rbdyn",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc run(root: string; actions: openArray[BuildAction]): BuildRunResult =
  var config = defaultBuildEngineConfig(root / "cache")
  config.bypassRunQuota = true
  config.maxParallelism = 1'u32
  runBuild(graph(actions), config)

proc statusOf(res: BuildRunResult; id: string): ActionStatus =
  for r in res.results:
    if r.id == id: return r.status
  raise newException(KeyError, "no result for " & id)

suite "a created action's environment isolation and scratch directories":

  test "an isolated created action sees only its declared variables":
    let root = createTempDir("repro-created-isolated-", "")
    defer: removeDir(root)
    putEnv(Leak, "from-the-engine")
    defer: delEnv(Leak)
    let script = "printf '%s|%s' \"${" & Leak & "-unset}\" \"$KEPT\" > seen.txt"
    for (id, isolate, expected) in [("isolated", true, "unset|declared"),
                                    ("open", false, "from-the-engine|declared")]:
      writeFragment(root / "frag.rbdyn", [%*{
        "id": id, "argv": ["/bin/sh", "-c", script], "cwd": root,
        "outputs": ["seen.txt"], "env": ["KEPT=declared", "PATH=/usr/bin:/bin"],
        "isolateHostEnvironment": isolate}], "collector")
      removeFile(root / "seen.txt")
      let res = run(root, [collector(root)])
      check res.statusOf(id) == asSucceeded
      check readFile(root / "seen.txt") == expected

  test "the isolation is part of a created action's key":
    proc keyOf(isolate: bool): string =
      var spec = initCreatedActionSpec("k", ["/bin/sh", "-c", "true"])
      spec.env = @["PATH=/usr/bin:/bin"]
      spec.isolateHostEnvironment = isolate
      $createdAction(spec, lockIdentityOutsideSolvedGraph()).weakFingerprint
    check keyOf(true) != keyOf(false)

  test "a created action's scratch directory is emptied before every run":
    let root = createTempDir("repro-created-scratch-", "")
    defer: removeDir(root)
    createDir(root / "work")
    writeFile(root / "work" / "stale", "left before the build")
    let script = "if [ -e work/stale ]; then echo stale; else echo clean; fi " &
      "> seen.txt; mkdir -p work; echo left > work/stale"
    writeFragment(root / "frag.rbdyn", [%*{
      "id": "scratched", "argv": ["/bin/sh", "-c", script], "cwd": root,
      "outputs": ["seen.txt"], "scratchDirs": ["work"]}], "collector")
    for attempt in 1 .. 2:
      let res = run(root, [collector(root)])
      check res.statusOf("scratched") == asSucceeded
      check readFile(root / "seen.txt").strip() == "clean"
    check fileExists(root / "work" / "stale")

  test "a created action's scratch directory holding its output is refused":
    let root = createTempDir("repro-created-scratch-bad-", "")
    defer: removeDir(root)
    writeFragment(root / "frag.rbdyn", [%*{
      "id": "bad", "argv": ["/bin/sh", "-c", "mkdir -p work; echo x > work/o"],
      "cwd": root, "outputs": ["work/o"], "scratchDirs": ["work"]}],
      "collector")
    let res = run(root, [collector(root)])
    check res.statusOf("bad") == asFailed

  test "a misspelt member of a record is refused, not ignored":
    let root = createTempDir("repro-created-misspelt-", "")
    defer: removeDir(root)
    createDir(root)
    writeFile(root / "frag.rbdyn", "repro-dynamic-graph-v1\ncreate-action\t" &
      $(%*{"id": "m", "argv": ["/bin/true"], "isolateHostEnviroment": true}) &
      "\n")
    expect BuildEngineError:
      discard run(root, [collector(root)])
