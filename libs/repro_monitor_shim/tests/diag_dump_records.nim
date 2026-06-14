## Diagnostic: re-run the failing Node fixtures and dump every record
## the shim emitted, grouped by kind. Tells us what API the shim DID
## record so we can identify which API it's MISSING.

import std/[os, strutils, tables, tempfiles, algorithm]

import repro_test_support
import repro_monitor_depfile/types
import repro_monitor_depfile/reader

let testDir = currentSourcePath().parentDir()
let fixturesDir = testDir / "fixtures"

proc runShellLocal(cmd: string): tuple[code: int; output: string] =
  let r = execShellCmd(cmd)
  (code: r, output: "")

proc compileGccLocal(sourcePath, outputPath: string) =
  let args = @["gcc", sourcePath, "-municode", "-o", outputPath,
               "-D_CRT_SECURE_NO_WARNINGS"]
  let r = runShell(shellCommand(args))
  if r.code != 0:
    echo "gcc failed:\n" & r.output
    quit(1)

proc runUnderFsSnoop(fsSnoop, depFilePath: string;
                     command: openArray[string]): CmdResult =
  let args = @[fsSnoop, "--depfile=" & depFilePath, "--"] & @command
  runShell(shellCommand(args))

proc findNodeExe(): string =
  const candidates = [
    r"D:\metacraft\codetracer\.repro\build\reprobuild\tool-store\prefixes\node\9f0ad977a75a1ca1-72a0549fd4b624eb\node.exe",
    r"D:\metacraft-dev-deps\node\24.13.0\node-v24.13.0-win-x64\node.exe",
  ]
  for c in candidates:
    if fileExists(c):
      return c
  ""

# Ensure clingo.dll on PATH for fs-snoop.
const clingoBin = r"D:\metacraft-dev-deps\clingo\5.8.0\bin"
if dirExists(clingoBin):
  let cur = getEnv("PATH")
  if not cur.contains(clingoBin):
    putEnv("PATH", clingoBin & PathSep & cur)

let nodeExe = findNodeExe()
if nodeExe.len == 0:
  echo "no node.exe found"
  quit(1)

let repoRoot = getCurrentDir()
let tempRoot = createTempDir("repro-diag-", "")
let monitor = prepareMonitorTools(repoRoot, tempRoot / "monitor",
                                   "diag-node")
let fsSnoop = monitor.fsSnoop
let shimLib = monitor.shim
putEnv("REPRO_MONITOR_SHIM_LIB", shimLib)

proc dump(label, depPath, marker: string) =
  echo "\n=== " & label & " ==="
  if not fileExists(depPath):
    echo "  (no depfile)"
    return
  let dep = readMonitorDepFile(depPath)
  echo "total records: " & $dep.records.len
  var byKind = initCountTable[MonitorRecordKind]()
  for r in dep.records:
    byKind.inc(r.kind)
  for (kind, count) in byKind.pairs:
    echo "  " & $kind & ": " & $count

  # Marker-filtered breakdown: records whose path matches the test marker.
  echo "marker-matching records (path contains '" & marker & "'):"
  var byKindMarker = initCountTable[string]()
  for r in dep.records:
    if marker.len > 0 and r.path.contains(marker):
      let key = $r.kind & "|" & r.detail
      byKindMarker.inc(key)
  for (key, count) in byKindMarker.pairs:
    echo "  " & key & ": " & $count

  # Also breakdown by detail field for ALL records, in case the marker
  # is being stripped or the path is showing in an unexpected form.
  echo "all records by detail:"
  var byDetail = initCountTable[string]()
  for r in dep.records:
    byDetail.inc(r.detail)
  for (detail, count) in byDetail.pairs:
    echo "  " & detail & ": " & $count

  # NEW: dump first 8 NtQueryAttributesFile + NtQueryDirectoryFile path
  # samples so we can see what the OBJECT_ATTRIBUTES extraction actually
  # produced for libuv-issued stat / readdir.
  echo "NtQueryAttributesFile samples (path | result):"
  var ntQuerySeen = 0
  for r in dep.records:
    if r.detail == "NtQueryAttributesFile" and ntQuerySeen < 8:
      echo "  '" & r.path & "' | " & $r.result
      ntQuerySeen.inc
  echo "NtQueryDirectoryFile samples (path | result):"
  var ntDirSeen = 0
  for r in dep.records:
    if r.detail == "NtQueryDirectoryFile" and ntDirSeen < 8:
      echo "  '" & r.path & "' | " & $r.result
      ntDirSeen.inc
  # CRITICAL: scan EVERY record for the marker substring to identify
  # WHICH API libuv used. If "probe." appears anywhere, the detail
  # column tells us the API.
  echo "marker-anywhere records (containing marker substring '" &
    marker & "', any detail):"
  var anyMatch = 0
  for r in dep.records:
    if marker.len > 0 and r.path.contains(marker) and anyMatch < 16:
      echo "  [" & $r.kind & "/" & r.detail & "] " & r.path
      anyMatch.inc
  echo "  total anywhere matches: " & $anyMatch
  # Also count CreateFileW + NtCreateFile records BY THEIR FULL PATH so
  # we can see if libuv's stat-path produces ANYTHING with the marker.
  if marker.len > 0:
    echo "all paths grouped by first 30 chars (top 10):"
    var pathPrefixes = initCountTable[string]()
    for r in dep.records:
      if r.path.len > 0:
        let prefix =
          if r.path.len > 30: r.path[0 ..< 30] & "..."
          else: r.path
        pathPrefixes.inc(prefix)
    var pairs: seq[(string, int)] = @[]
    for (k, v) in pathPrefixes.pairs:
      pairs.add((k, v))
    pairs.sort(proc(a, b: (string, int)): int = cmp(b[1], a[1]))
    for i in 0 ..< min(10, pairs.len):
      echo "  '" & pairs[i][0] & "' x " & $pairs[i][1]

# Diag 1: fs.statSync probe storm.
let probeDir = tempRoot / "diag-probe"
createDir(probeDir)
let probeDep = tempRoot / "diag_probe.rdep"
let r1 = runUnderFsSnoop(fsSnoop, probeDep,
  @[nodeExe, fixturesDir / "fixture_node_fs_stat.js", probeDir, "8"])
echo "diag_probe rc=" & $r1.code
dump("fs.statSync N=8", probeDep, "probe.")

# Diag 2: readdir.
let srcDir = tempRoot / "diag-readdir-src"
let outDir = tempRoot / "diag-readdir-out"
createDir(srcDir)
createDir(outDir)
let readdirDep = tempRoot / "diag_readdir.rdep"
let r2 = runUnderFsSnoop(fsSnoop, readdirDep,
  @[nodeExe, fixturesDir / "fixture_node_readdir_bundle.js",
    srcDir, outDir, "3"])
echo "diag_readdir rc=" & $r2.code
dump("fs.readdirSync N=3", readdirDep, "src.")
