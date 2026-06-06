## Helpers shared across the CI-Sharding M2 e2e tests.
##
## Each test under ``tests/e2e/sharding/`` invokes ``repro test --shard
## k/N`` against a tiny in-tree fixture describing 6 fake "test edges"
## (each is just ``/bin/true``).  Centralising the fixture writer,
## ``repro`` binary lookup, and shard-report reader avoids per-test
## boilerplate drift.

import std/[json, os, osproc, streams, strutils, tables]

const
  ReproBinRelative* = "build/bin/repro"

proc repoRoot*(): string =
  ## The reprobuild repo root, irrespective of the test's working
  ## directory.  Falls back to ``getCurrentDir()`` when the path lookup
  ## fails (e.g. a sandbox without the source tree, in which case the
  ## test would fail at the binary-existence check anyway).
  let env = getEnv("REPRO_REPO_ROOT")
  if env.len > 0 and dirExists(env):
    return env
  result = getCurrentDir()
  # Walk up until we find ``build/bin/repro`` or a sentinel.
  for _ in 0 .. 6:
    if fileExists(result / ReproBinRelative):
      return result
    let parent = parentDir(result)
    if parent.len == 0 or parent == result:
      break
    result = parent

proc reproBin*(): string =
  repoRoot() / ReproBinRelative

proc writeTrueScript*(path: string; exitCode = 0) =
  ## Writes a tiny POSIX shell script that exits with ``exitCode``.
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  writeFile(path,
    "#!/bin/sh\n" &
    "exit " & $exitCode & "\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

type
  FixtureEdgeSpec* = object
    id*: int
    selector*: string
    historyKey*: string
    buildDeps*: seq[int]
    testName*: string
    testCmd*: seq[string]

  FixtureActionSpec* = object
    id*: int
    commandStatsId*: string
    deps*: seq[int]
    buildCmd*: seq[string]

  FixtureSpec* = object
    actions*: seq[FixtureActionSpec]
    edges*: seq[FixtureEdgeSpec]
    fallbackBuildCostNs*: int64
    fallbackTestCostNs*: int64
    historyDir*: string
    estimateDbPath*: string
    estimateScope*: string
    policy*: string

proc toJson*(spec: FixtureSpec): JsonNode =
  result = newJObject()
  result["fallbackBuildCostNs"] = %spec.fallbackBuildCostNs
  result["fallbackTestCostNs"] = %spec.fallbackTestCostNs
  result["historyDir"] = %spec.historyDir
  result["estimateDbPath"] = %spec.estimateDbPath
  result["estimateScope"] = %spec.estimateScope
  result["policy"] = %spec.policy
  var actions = newJArray()
  for a in spec.actions:
    var node = newJObject()
    node["id"] = %a.id
    node["commandStatsId"] = %a.commandStatsId
    var deps = newJArray()
    for d in a.deps:
      deps.add(%d)
    node["deps"] = deps
    var cmd = newJArray()
    for s in a.buildCmd:
      cmd.add(%s)
    node["buildCmd"] = cmd
    actions.add(node)
  result["buildActions"] = actions
  var edges = newJArray()
  for e in spec.edges:
    var node = newJObject()
    node["id"] = %e.id
    node["selector"] = %e.selector
    node["historyKey"] = %e.historyKey
    var deps = newJArray()
    for d in e.buildDeps:
      deps.add(%d)
    node["buildDeps"] = deps
    var cmd = newJArray()
    for s in e.testCmd:
      cmd.add(%s)
    node["runCmd"] = cmd
    node["testName"] = %e.testName
    edges.add(node)
  result["testEdges"] = edges

proc writeFixture*(path: string; spec: FixtureSpec) =
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  writeFile(path, spec.toJson().pretty() & "\n")

proc populateEstimateDb*(path: string; scope: string;
                        durations: openArray[tuple[id: string; ns: int64]]) =
  ## Writes the planner's companion ``learned_estimate_durations``
  ## table.  Mirrors the helper in ``t_partition_planner_reads_runquota_estimates.nim``.
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  if fileExists(path):
    removeFile(path)
  var insertRows = newSeq[string]()
  for d in durations:
    insertRows.add("('" & scope & "', '" & d.id & "', " & $d.ns & ")")
  let sqlText = """
    create table if not exists learned_estimate_durations (
      scope text not null,
      command_stats_id text not null,
      wall_time_ns integer not null,
      sample_count integer not null default 1,
      updated_unix_millis integer not null default 0,
      primary key (scope, command_stats_id)
    );
    insert into learned_estimate_durations
      (scope, command_stats_id, wall_time_ns) values
    """ & insertRows.join(",\n      ") & ";"
  let output = execProcess("sqlite3", args = [path, sqlText],
      options = {poUsePath, poStdErrToStdOut})
  doAssert output.len == 0, "sqlite3 fixture setup failed: " & output

proc writeTestDurationsJson*(historyDir: string;
                            durations: openArray[tuple[key: string; ms: int]]) =
  if not dirExists(historyDir):
    createDir(historyDir)
  var obj = newJObject()
  for d in durations:
    obj[d.key] = %d.ms
  writeFile(historyDir / "test-durations.json", obj.pretty() & "\n")

proc runRepro*(args: openArray[string]; cwd: string):
    tuple[code: int; output: string] =
  ## Invoke the built ``repro`` binary with ``args``, capturing merged
  ## stdout+stderr.  ``cwd`` is the workspace the test created.
  let bin = reproBin()
  doAssert fileExists(bin), "repro binary missing at " & bin &
    "; run ``just build`` in the reprobuild repo before this test."
  let p = startProcess(bin,
    workingDir = cwd,
    args = @args,
    options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  var buf = ""
  let outp = p.outputStream
  var line = newStringOfCap(120)
  while true:
    if outp.readLine(line):
      buf.add(line)
      buf.add("\n")
    else:
      let code = p.peekExitCode()
      if code != -1:
        return (code, buf)

proc readShardReport*(path: string): JsonNode =
  doAssert fileExists(path), "shard report missing at " & path
  parseJson(readFile(path))
