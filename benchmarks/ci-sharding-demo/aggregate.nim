## CI-Sharding demonstration — per-N aggregator.
##
## Reads the per-shard reports written by ``repro test --shard k/N
## --fixture-from=... --report=<path>`` for a single N and computes:
##
##   * Per-shard wall time (from ``actual_total_time_ns``)
##   * Max wall time across the N shards (the "wall-time-of-the-CI-matrix"
##     metric — what a user actually waits for)
##   * Sum of per-shard wall times (the "total CPU spent" metric)
##   * Union of executed test selectors across the N shards
##   * Whether any selector appears on more than one shard
##   * Aggregate pass / fail counts
##
## Then verifies (against an optional baseline) coverage, exclusivity, and
## aggregate parity, and prints one "OK <name>" or "FAIL <name>: <reason>"
## line per check on stdout.  The exit code is 0 iff every check passed.
##
## Usage:
##   aggregate --n=N --shard-dir=<dir> --shard-prefix=<prefix>
##             [--baseline-pass=K] [--baseline-fail=K]
##             [--baseline-set=<comma-separated stems>]
##             [--metrics-out=<path>]
##
## Per-shard report path: ``<shard-dir>/<shard-prefix>-k-of-N.json`` for
## k in 1..N.

import std/[json, os, parseopt, sequtils, sets, strutils, tables]

type
  Check = object
    name: string
    ok: bool
    detail: string

  ShardMetrics = object
    walls: seq[int64]      ## ns per shard
    passed: seq[int]
    failed: seq[int]
    assigned: seq[HashSet[string]]
    union: HashSet[string]
    duplicates: HashSet[string]
    totalPassed: int
    totalFailed: int

proc readReport(path: string): JsonNode =
  if not fileExists(path):
    return newJNull()
  try:
    return parseJson(readFile(path))
  except CatchableError:
    return newJNull()

proc collectMetrics(shardDir, shardPrefix: string;
                    n: int): ShardMetrics =
  result.assigned = newSeq[HashSet[string]](n)
  result.walls = newSeq[int64](n)
  result.passed = newSeq[int](n)
  result.failed = newSeq[int](n)
  result.union = initHashSet[string]()
  result.duplicates = initHashSet[string]()
  var seen = initHashSet[string]()
  for k in 1 .. n:
    let path = shardDir / (shardPrefix & "-" & $k & "-of-" & $n & ".json")
    let report = readReport(path)
    if report.kind != JObject:
      continue
    if report.hasKey("actual_total_time_ns") and
        report["actual_total_time_ns"].kind == JInt:
      result.walls[k - 1] = report["actual_total_time_ns"].getBiggestInt().int64
    if report.hasKey("test_pass_count") and report["test_pass_count"].kind == JInt:
      result.passed[k - 1] = report["test_pass_count"].getInt()
    if report.hasKey("test_fail_count") and report["test_fail_count"].kind == JInt:
      result.failed[k - 1] = report["test_fail_count"].getInt()
    var shardSet = initHashSet[string]()
    if report.hasKey("assigned_selectors") and
        report["assigned_selectors"].kind == JArray:
      for entry in report["assigned_selectors"].elems:
        let sel = entry.getStr()
        shardSet.incl(sel)
        if sel in seen:
          result.duplicates.incl(sel)
        else:
          seen.incl(sel)
        result.union.incl(sel)
    result.assigned[k - 1] = shardSet
    result.totalPassed += result.passed[k - 1]
    result.totalFailed += result.failed[k - 1]

proc maxOf(walls: seq[int64]): int64 =
  for w in walls:
    if w > result:
      result = w

proc sumOf(walls: seq[int64]): int64 =
  for w in walls:
    result += w

proc main =
  var n = 0
  var shardDir = ""
  var shardPrefix = ""
  var baselinePass = -1
  var baselineFail = -1
  var baselineSetRaw = ""
  var metricsOut = ""
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "n": n = parseInt(val)
      of "shard-dir": shardDir = val
      of "shard-prefix": shardPrefix = val
      of "baseline-pass": baselinePass = parseInt(val)
      of "baseline-fail": baselineFail = parseInt(val)
      of "baseline-set": baselineSetRaw = val
      of "metrics-out": metricsOut = val
      else: quit("unknown flag: --" & key, 2)
    of cmdArgument: discard
    of cmdShortOption: discard
    of cmdEnd: break
  if n <= 0 or shardDir.len == 0 or shardPrefix.len == 0:
    quit("usage: aggregate --n=N --shard-dir=<dir> --shard-prefix=<prefix>", 2)

  let m = collectMetrics(shardDir, shardPrefix, n)
  var baselineSet = initHashSet[string]()
  for token in baselineSetRaw.split(','):
    let t = token.strip()
    if t.len > 0:
      baselineSet.incl(t)

  var checks: seq[Check] = @[]

  # 1. Every shard report was readable.
  var missing = 0
  for k in 1 .. n:
    if m.assigned[k - 1].len == 0 and m.walls[k - 1] == 0:
      # Could be a real empty shard (legitimate with small fixture + many
      # shards) — only flag if EVERY shard was empty.
      inc missing
  checks.add(Check(name: "shard reports readable",
    ok: missing < n,
    detail: $missing & "/" & $n & " empty"))

  # 2. Exclusivity: no selector across two shards.
  checks.add(Check(name: "exclusivity (no test on >1 shard)",
    ok: m.duplicates.len == 0,
    detail:
      if m.duplicates.len == 0: ""
      else: "duplicates: " & toSeq(m.duplicates).join(",")))

  # 3. Coverage against baseline (if baseline supplied).
  if baselineSet.len > 0:
    var missingFromShards = initHashSet[string]()
    for sel in baselineSet:
      if sel notin m.union:
        missingFromShards.incl(sel)
    var extraInShards = initHashSet[string]()
    for sel in m.union:
      if sel notin baselineSet:
        extraInShards.incl(sel)
    let coverageOk = missingFromShards.len == 0 and extraInShards.len == 0
    var detail = ""
    if missingFromShards.len > 0:
      detail.add("missing " & $missingFromShards.len)
    if extraInShards.len > 0:
      if detail.len > 0: detail.add(", ")
      detail.add("extra " & $extraInShards.len)
    checks.add(Check(name: "coverage (union == baseline set)",
      ok: coverageOk, detail: detail))
  else:
    checks.add(Check(name: "coverage (no baseline set supplied)",
      ok: true, detail: "skipped — union size " & $m.union.len))

  # 4. Parity: pass + fail totals match baseline.
  if baselinePass >= 0:
    checks.add(Check(name: "parity (pass count == baseline)",
      ok: m.totalPassed == baselinePass,
      detail: "got " & $m.totalPassed & " expected " & $baselinePass))
  if baselineFail >= 0:
    checks.add(Check(name: "parity (fail count == baseline)",
      ok: m.totalFailed == baselineFail,
      detail: "got " & $m.totalFailed & " expected " & $baselineFail))

  # Per-shard summary lines (info, not pass/fail).
  for k in 1 .. n:
    echo "INFO shard ", k, "/", n, ": wall_ns=", m.walls[k - 1],
      " assigned=", m.assigned[k - 1].len,
      " passed=", m.passed[k - 1],
      " failed=", m.failed[k - 1]

  let maxWall = maxOf(m.walls)
  let sumWall = sumOf(m.walls)
  echo "INFO total: max_wall_ns=", maxWall, " sum_wall_ns=", sumWall,
    " union_size=", m.union.len,
    " passed=", m.totalPassed, " failed=", m.totalFailed

  if metricsOut.len > 0:
    var obj = newJObject()
    obj["n"] = %n
    var walls = newJArray()
    for w in m.walls: walls.add(%w)
    obj["per_shard_wall_ns"] = walls
    var ps = newJArray()
    for p in m.passed: ps.add(%p)
    obj["per_shard_passed"] = ps
    var fs = newJArray()
    for f in m.failed: fs.add(%f)
    obj["per_shard_failed"] = fs
    obj["max_wall_ns"] = %maxWall
    obj["sum_wall_ns"] = %sumWall
    obj["union_size"] = %m.union.len
    obj["total_passed"] = %m.totalPassed
    obj["total_failed"] = %m.totalFailed
    obj["duplicates"] = %m.duplicates.len
    var unionArr = newJArray()
    for sel in m.union: unionArr.add(%sel)
    obj["union"] = unionArr
    let p = parentDir(metricsOut)
    if p.len > 0 and not dirExists(p): createDir(p)
    writeFile(metricsOut, obj.pretty() & "\n")

  var anyFailed = false
  for c in checks:
    let label = if c.ok: "OK   " else: "FAIL "
    if not c.ok: anyFailed = true
    if c.detail.len > 0:
      echo label, c.name, " (", c.detail, ")"
    else:
      echo label, c.name
  quit(if anyFailed: 1 else: 0)

main()
