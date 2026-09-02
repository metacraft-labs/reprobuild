## Helpers shared across the CI-Sharding M2 e2e tests.
##
## Each test under ``tests/e2e/sharding/`` invokes ``repro test --shard
## k/N`` against a tiny in-tree fixture describing 6 fake "test edges"
## (each is just ``/bin/true``).  Centralising the fixture writer,
## ``repro`` binary lookup, and shard-report reader avoids per-test
## boilerplate drift.

import std/[json, os, osproc, streams, strutils, tables]

from repro_test_support import requireHostBinary, binaryFormatOf,
  hostBinaryFormat, describeBinaryFormat, HostBinaryFormat

const
  # The executable extension has to be resolved HERE, not at the use site:
  # this constant is both the sentinel `repoRoot` walks up looking for and
  # the binary `reproBin` returns. Spelled without `.exe` it made the two
  # fail together on Windows — `fileExists` was false at every level, so the
  # walk ran to the DRIVE ROOT and the assertion then reported
  # `repro binary missing at M:\build\bin\repro`, naming a path that was
  # wrong in two independent ways.
  ReproBinRelative* = "build/bin/" & addFileExt("repro", ExeExt)

const SourceAnchoredRepoRoot =
  currentSourcePath().parentDir().parentDir().parentDir().parentDir()
  ## ``tests/e2e/sharding/sharding_test_support.nim`` -> the checkout root.
  ## ``currentSourcePath()`` is absolute on both platforms, so this is the
  ## repo that CONTAINS this file, not the repo the launcher happened to be
  ## standing in.

proc repoRoot*(): string =
  ## The reprobuild repo root, irrespective of the test's working
  ## directory.
  ##
  ## The walk used to START at ``getCurrentDir()``, which made the process
  ## working directory an unstated fixture input: launched from a scratch
  ## directory carrying a staged ``build/bin/repro`` it returned THAT
  ## directory, and every case below then drove a binary the test did not
  ## build. Anchor on the source path instead and keep the walk only as the
  ## answer to "did somebody move this file", not to "where was the shell".
  let env = getEnv("REPRO_REPO_ROOT")
  if env.len > 0 and dirExists(env):
    return env
  result = SourceAnchoredRepoRoot
  # Walk up until we find the repro binary or a sentinel.
  for _ in 0 .. 6:
    if fileExists(result / ReproBinRelative):
      return result
    let parent = parentDir(result)
    if parent.len == 0 or parent == result:
      break
    result = parent
  # The walk found nothing: the source-anchored root is still the honest
  # answer, and the binary-existence check below reports the real problem.
  result = SourceAnchoredRepoRoot

proc reproBin*(): string =
  repoRoot() / ReproBinRelative

proc reprobuildRepoRoot*(): string =
  ## Readable alias for ``repoRoot()`` at call sites that bind the result to
  ## a local also called ``repoRoot``. Added by W15 when
  ## ``t_e2e_repro_test_shard_workspace_integration.nim`` stopped carrying its
  ## own private, differently-broken copy of the root walk.
  repoRoot()

proc requireShardingReproBinary*(): string {.discardable.} =
  ## Prove the binary this family is about to execute is THIS platform's.
  ##
  ## ``fileExists`` was the only check here, and it is not the property:
  ## ``build/`` is gitignored and shared between this host's Windows checkout
  ## and the WSL view of the same tree, so ``build/bin/repro`` can be a Linux
  ## ELF while ``build/bin/repro.exe`` is the PE, and an extension-less
  ## spelling picks up whichever platform built last. ``doAssert`` rather than
  ## ``check`` on purpose: this is a helper proc, and on the Windows toolchain
  ## pin (stock Nim 2.2.8) a ``check`` outside a ``test`` body prints its
  ## failure and still reports ``[OK]``.
  requireHostBinary(reproBin())

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
  # W15: presence was the only check, and presence is not the property — an
  # artefact of the OTHER platform satisfies ``fileExists`` and then fails at
  # exec with "%1 is not a valid Win32 application", which reads as a product
  # refusal. Prove the machine format instead.
  let bin = requireShardingReproBinary()
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
