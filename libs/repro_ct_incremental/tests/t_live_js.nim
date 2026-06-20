## M13 — LIVE JavaScript recording drives the engine.
##
## Performs a GENUINE live recording with the PRODUCTION JS recorder (the SWC
## instrumenter + napi-rs native runtime, via its `record` subcommand), then
## drives the engine over the resulting CTFS bundle. NO hand-crafted trace, NO
## `unittest.skip`, NO accepted gate — this path is genuinely live and the test
## ASSERTS success.
##
## # Why this is live (the earlier "upstream break" was a stale sibling)
##
## A prior revision of this test ACCEPTED a build gate, claiming the napi addon
## (`recorder_native`) could not compile because `NimTraceWriter` lacked the
## `enable_column_breakpoints_support` / `enable_column_motions_support` methods.
## That diagnosis was WRONG: those methods DO exist on the column-aware-tracing
## API — the failure came from STALE sibling checkouts (`codetracer-trace-format`
## and `codetracer-trace-format-nim` behind their mainline, so the addon built
## against an old writer API and even SIGSEGV'd at record time on the old Nim
## writer). With the siblings synced to mainline the recorder builds AND records
## cleanly, and the engine extracts exactly the executed functions. A workspace
## with stale siblings is a misconfiguration, not a legitimate platform gate, so
## this test FAILS LOUDLY (printing the captured diagnostic) rather than
## accepting a gate.

import std/[unittest, os, strutils]
import repro_ct_incremental
import live_record

const
  jsProgram = """function used_a(x) { return x + 1; }
function used_b(x) { return x * 2; }
function unused_c(x) { return x - 99; }
function main() { console.log(used_a(2) + used_b(3)); }
main();
"""

proc writeProgram(dir, body: string): string =
  let path = dir / "prog.js"
  writeFile(path, body)
  path

proc mirrorRecordedSource(recordedAbsPath, body: string): string =
  let root = freshLiveDir("repro_ct_live_js_src_")
  let rel = recordedAbsPath.strip(leading = true, trailing = false,
    chars = {DirSep, '/'})
  let dst = root / rel
  createDir(dst.parentDir)
  writeFile(dst, body)
  root

proc editJsFunctionLine(sourceRoot, recordedAbsPath, funcName, newLine: string) =
  ## Replace the single-line `function <funcName>(...) { ... }` line.
  let rel = recordedAbsPath.strip(leading = true, trailing = false,
    chars = {DirSep, '/'})
  let path = sourceRoot / rel
  var lines = readFile(path).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip().startsWith("function " & funcName):
      lines[i] = newLine
      writeFile(path, lines.join("\n"))
      return
  doAssert false, "function not found in mirrored js source: " & funcName

suite "M13 live JavaScript recording":

  test "live_js_recording_decides_end_to_end":
    let ctp = ensureCtPrintBuilt()
    doAssert ctp.ok, "ct-print could not be built for the M13 JS test:\n" &
      ctp.diagnostic

    let progDir = freshLiveDir("repro_ct_live_js_prog_")
    let progPath = writeProgram(progDir, jsProgram)
    let rec = recordJsLive(progPath)

    # The JS recorder builds and records LIVE on a correctly-synced workspace.
    # A `roGated` outcome here means the recorder failed to build/record — on a
    # synced workspace that is a real regression (e.g. stale sibling checkouts),
    # NOT a legitimate platform gate, so fail loudly with the captured output.
    if rec.kind == roGated:
      echo "\n=========== M13 JS LIVE-RECORDING FAILURE ==========="
      echo "The production JS recorder failed to build/record. On a correctly-"
      echo "synced workspace this is a REGRESSION (commonly stale sibling"
      echo "checkouts of codetracer-trace-format / -trace-format-nim behind their"
      echo "mainline). Captured diagnostic from the real attempt:"
      echo rec.diagnostic
      echo "====================================================\n"
    doAssert rec.kind == roSuccess,
      "JS live recording did not succeed (see diagnostic above)"

    let execRes = readExecutedFunctionsCtfs(rec.ctPath)
    check execRes.isOk
    var names: seq[string]
    for f in execRes.get(): names.add f.name
    check "used_a" in names
    check "used_b" in names
    check "unused_c" notin names

    let rootSkip = mirrorRecordedSource(progPath, jsProgram)
    var cacheSkip = initCache(rootSkip / "cache.json")
    check record(cacheSkip, "js_live", rec.traceDir, rootSkip).isOk
    check decide("js_live", rec.traceDir, rootSkip, cacheSkip).kind ==
      idSkipUnchanged

    let rootRerun = mirrorRecordedSource(progPath, jsProgram)
    var cacheRerun = initCache(rootRerun / "cache.json")
    check record(cacheRerun, "js_live", rec.traceDir, rootRerun).isOk
    editJsFunctionLine(rootRerun, progPath, "used_a",
      "function used_a(x) { return x + 1000; }")
    let decRerun = decide("js_live", rec.traceDir, rootRerun, cacheRerun)
    check decRerun.kind == idRerunChanged
    check "used_a" in decRerun.changedFuncs

    let rootUnexec = mirrorRecordedSource(progPath, jsProgram)
    var cacheUnexec = initCache(rootUnexec / "cache.json")
    check record(cacheUnexec, "js_live", rec.traceDir, rootUnexec).isOk
    editJsFunctionLine(rootUnexec, progPath, "unused_c",
      "function unused_c(x) { return x - 123456; }")
    check decide("js_live", rec.traceDir, rootUnexec, cacheUnexec).kind ==
      idSkipUnchanged
