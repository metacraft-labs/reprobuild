## CI-Sharding demonstration — fixture generator.
##
## Parses ``repro.tests.nim`` for declared ``buildNimUnittest.build(...)``
## edges and emits a fixture JSON consumable by
## ``repro test --shard k/N --fixture-from=<path>``.
##
## Strategy: the binaries are produced ahead of time by ``scripts/run_tests.sh``
## (the suite's standard build path), so the fixture's per-action ``buildCmd``
## is a no-op (``["true"]``) and the per-edge ``runCmd`` invokes the actual
## test binary under ``build/test-bin/<stem>``.  This sidesteps the
## workspace-mode tool-provisioning requirement while still exercising the
## SAME ``planTestShards`` / ``runquota_partition`` codepath that backs the
## workspace-mode integration — the fixture path is the M2 entry point and
## the workspace path delegates to the identical planner.
##
## When ``--include-only=<list>`` is given, only edges whose stem appears in
## the comma-separated list are emitted (used by the small-fixture preflight
## verification).
##
## Usage:
##   nim r gen_fixture.nim <repro.tests.nim> <build/test-bin> <out.json>
##     [--include-only=stem1,stem2]
##     [--max=N]      # take the first N edges (after include filter)
##     [--timeout=N]  # wrap each test invocation in `timeout Ns ...`
##                    # (avoids stuck tests killing the run; 0 disables)
##     [--exclude=stem1,stem2]
##                    # comma-separated stems to skip (known-hang or
##                    # known-slow tests)

import std/[json, os, parseopt, sets, strutils]

type
  Edge = object
    source: string
    binary: string

proc extractEdges(path: string): seq[Edge] =
  let content = readFile(path)
  # Each edge is declared like:
  #
  #   let _<name> = buildNimUnittest.build(
  #     source = "libs/...nim",
  #     binary = "build/test-bin/<stem>")
  #
  # We do a robust line-scan: look for ``source = "..."`` immediately followed
  # (within a few lines) by ``binary = "..."``.
  var i = 0
  var lines = content.splitLines()
  while i < lines.len:
    let line = lines[i].strip()
    if line.startsWith("source ="):
      let srcStart = line.find('"')
      if srcStart < 0:
        inc i; continue
      let srcEnd = line.find('"', srcStart + 1)
      if srcEnd < 0:
        inc i; continue
      let src = line[srcStart + 1 .. srcEnd - 1]
      # Look for binary = on the next non-blank line.
      var j = i + 1
      while j < lines.len and lines[j].strip().len == 0:
        inc j
      if j >= lines.len:
        inc i; continue
      let bline = lines[j].strip()
      if not bline.startsWith("binary ="):
        inc i; continue
      let binStart = bline.find('"')
      if binStart < 0:
        inc i; continue
      let binEnd = bline.find('"', binStart + 1)
      if binEnd < 0:
        inc i; continue
      let bin = bline[binStart + 1 .. binEnd - 1]
      result.add(Edge(source: src, binary: bin))
      i = j + 1
    else:
      inc i

proc main =
  var args: seq[string] = @[]
  var includeOnly = initHashSet[string]()
  var excludeStems = initHashSet[string]()
  var excludeSubstr: string = ""
  var hasInclude = false
  var maxEdges = -1
  var timeoutSec = 0
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      args.add(key)
    of cmdLongOption:
      case key
      of "include-only":
        hasInclude = true
        for token in val.split(','):
          let t = token.strip()
          if t.len > 0:
            includeOnly.incl(t)
      of "exclude":
        for token in val.split(','):
          let t = token.strip()
          if t.len > 0:
            excludeStems.incl(t)
      of "exclude-substring":
        # Comma-separated substrings; any stem containing one of them is
        # filtered out.  Used to bulk-skip e2e-style tests that spawn
        # daemons and dominate wall time in the harness.
        excludeSubstr.add(val)
      of "max":
        maxEdges = parseInt(val)
      of "timeout":
        timeoutSec = parseInt(val)
      else:
        quit("unknown flag: --" & key, 2)
    of cmdShortOption:
      quit("unknown short flag: -" & key, 2)
    of cmdEnd:
      break
  if args.len != 3:
    quit("usage: gen_fixture.nim <repro.tests.nim> <build/test-bin> <out.json> [--include-only=...] [--max=N]", 2)
  let testsNim = args[0]
  let binDir = args[1]
  let outPath = args[2]
  let edges = extractEdges(testsNim)
  var spec = newJObject()
  spec["fallbackBuildCostNs"] = %1_000_000_000'i64
  spec["fallbackTestCostNs"] = %1_000_000_000'i64
  spec["historyDir"] = %""
  spec["estimateDbPath"] = %""
  spec["estimateScope"] = %""
  spec["policy"] = %"independent"
  var buildActions = newJArray()
  var testEdges = newJArray()
  var emitted = 0
  for idx, e in edges:
    let stem = splitFile(e.binary).name
    if hasInclude and stem notin includeOnly:
      continue
    if stem in excludeStems:
      stderr.writeLine("gen_fixture: excluding " & stem & " (--exclude)")
      continue
    if excludeSubstr.len > 0:
      var matched = false
      for substr in excludeSubstr.split(','):
        let s = substr.strip()
        if s.len > 0 and stem.find(s) >= 0:
          matched = true
          break
      if matched:
        stderr.writeLine("gen_fixture: excluding " & stem &
          " (--exclude-substring)")
        continue
    if maxEdges >= 0 and emitted >= maxEdges:
      break
    let binAbs = absolutePath(binDir / stem)
    if not fileExists(binAbs):
      # Skip edges whose binary is not on disk (test wasn't built).
      stderr.writeLine("gen_fixture: skipping " & stem & " — binary not at " & binAbs)
      continue
    let actionId = 100_000 + idx * 2
    let edgeId = 100_001 + idx * 2
    var aNode = newJObject()
    aNode["id"] = %actionId
    aNode["commandStatsId"] = %("nimc::" & stem)
    aNode["deps"] = newJArray()
    var aCmd = newJArray()
    aCmd.add(%"true")
    aNode["buildCmd"] = aCmd
    buildActions.add(aNode)
    var eNode = newJObject()
    eNode["id"] = %edgeId
    eNode["selector"] = %stem
    eNode["historyKey"] = %stem
    var deps = newJArray()
    deps.add(%actionId)
    eNode["buildDeps"] = deps
    var rCmd = newJArray()
    if timeoutSec > 0:
      # ``timeout --kill-after=2s <N>s </dev/null <binary>`` ensures stuck
      # tests can't hold up the whole shard.  Redirecting stdin from
      # /dev/null is what ``timeout`` itself does for child stdin, but
      # we cannot redirect inside a ``runCmd`` argv directly — so the
      # whole invocation runs under ``sh -c``.
      rCmd.add(%"sh")
      rCmd.add(%"-c")
      rCmd.add(%("exec timeout --kill-after=2s " & $timeoutSec & "s " &
        quoteShell(binAbs) & " </dev/null"))
    else:
      rCmd.add(%binAbs)
    eNode["runCmd"] = rCmd
    eNode["testName"] = %stem
    testEdges.add(eNode)
    inc emitted
  spec["buildActions"] = buildActions
  spec["testEdges"] = testEdges
  let parent = parentDir(outPath)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  writeFile(outPath, spec.pretty() & "\n")
  stderr.writeLine("gen_fixture: emitted " & $emitted & " edges to " & outPath)

main()
