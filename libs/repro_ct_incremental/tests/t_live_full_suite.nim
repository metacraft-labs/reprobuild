## M13 — the whole campaign suite stays green WITH the live-recording tests.
##
## `full_suite_green_with_live_recordings` compiles and runs EVERY other test
## file in this directory (the full M0-M13 lib suite, including the four M13 live
## tests) as subprocesses and asserts each exits 0. This proves the live-recording
## work introduced no regression in the existing engine tests and that the live
## tests themselves are green (Ruby live end-to-end; Python/JS/native via their
## loud, asserted gates).
##
## The suite is driven through `nim c -r` so this single test reproduces the
## whole campaign verification in one command. Each subprocess inherits the same
## dev shell this test runs in (so `ct-print`, the cached recorder builds, and
## the recorder dev shells are all reachable). A non-zero exit from any file
## fails this test with that file's captured output.

import std/[unittest, os, osproc, strutils, algorithm]

const
  thisFile = currentSourcePath()
  testsDir = thisFile.parentDir

proc nimExe(): string =
  ## The `nim` to drive subprocess compiles with: prefer `$NIM`, else a `nim` on
  ## PATH, else the documented fallback wrapper. Mirrors how the suite is built.
  let envNim = getEnv("NIM")
  if envNim.len > 0 and fileExists(envNim): return envNim
  let onPath = findExe("nim")
  if onPath.len > 0: return onPath
  const fallback =
    "/nix/store/0a3x96yrzlpyhhx567ljbp6mpiv2gbi9-arm64-apple-darwin-nim-wrapper-2.2.4/bin/nim"
  if fileExists(fallback): return fallback
  "nim"

proc campaignTestFiles(): seq[string] =
  ## Every `t_*.nim` in this directory EXCEPT this driver itself (to avoid
  ## infinite recursion). Sorted for deterministic ordering.
  for kind, path in walkDir(testsDir):
    if kind in {pcFile, pcLinkToFile}:
      let name = path.extractFilename
      if name.startsWith("t_") and name.endsWith(".nim") and
          path != thisFile:
        result.add path
  result.sort()

suite "M13 full suite green with live recordings":

  test "full_suite_green_with_live_recordings":
    let nim = nimExe()
    let files = campaignTestFiles()
    # Sanity: the suite must include the live tests and the pre-M13 engine tests.
    var names: seq[string]
    for f in files: names.add f.extractFilename
    check "t_live_ruby.nim" in names
    check "t_live_python.nim" in names
    check "t_live_js.nim" in names
    check "t_live_native.nim" in names
    check "t_invalidation_engine.nim" in names
    check "t_ctfs_reader.nim" in names

    var failures: seq[string]
    for f in files:
      let (output, code) = execCmdEx(
        quoteShell(nim) & " c -r --hints:off --warnings:off " & quoteShell(f))
      if code != 0:
        failures.add f.extractFilename & " (exit " & $code & "):\n" &
          output.strip()
    if failures.len > 0:
      checkpoint("campaign suite has FAILING files:\n" & failures.join("\n---\n"))
    check failures.len == 0
