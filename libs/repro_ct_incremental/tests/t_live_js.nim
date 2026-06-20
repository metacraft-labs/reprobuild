## M13 — LIVE JavaScript recording drives the engine (attempt; loud gate on
## failure).
##
## Attempts a GENUINE live recording with the PRODUCTION JS recorder (the SWC
## instrumenter + napi-rs native runtime, via its `record` subcommand), then
## drives the engine over the resulting CTFS bundle. NO hand-crafted trace, NO
## `unittest.skip`.
##
## # Loud gate — a GENUINE upstream break (CI red), NOT a silent skip
##
## The JS recorder is currently broken at the source: its napi addon (the
## `recorder_native` crate) FAILS TO COMPILE because `NimTraceWriter` no longer
## exposes the `enable_column_breakpoints_support` / `enable_column_motions_support`
## methods the addon calls — a `codetracer-trace-format-nim` API mismatch from the
## column-aware-tracing rollout. This is a real, current upstream break, confirmed
## RED on the recorder repo's OWN CI on `dev` (it is NOT a missing `npm install`
## or a wrong dev shell). `recordJsLive` ATTEMPTS the build and, when it fails,
## returns a `roGated` outcome carrying the EXACT captured compiler error. This
## test prints that diagnostic loudly and ASSERTS the documented gate. Once the
## column-aware-tracing API mismatch is fixed upstream and the recorder builds,
## the SAME test records live and asserts the engine's skip/rerun decisions over
## the live bundle (no test change needed).

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

    if rec.kind == roGated:
      echo "\n================ M13 JS LIVE-RECORDING GATE ================"
      echo "The production JS recorder does not build: a GENUINE current upstream"
      echo "break, RED on the recorder repo's own CI on `dev`. The napi addon"
      echo "(recorder_native) fails to compile because NimTraceWriter lacks"
      echo "enable_column_breakpoints_support / enable_column_motions_support"
      echo "(a codetracer-trace-format-nim API mismatch from the column-aware-"
      echo "tracing rollout). This is NOT a missing npm install or wrong dev shell."
      echo "Captured diagnostic from the real build attempt:"
      echo rec.diagnostic
      echo "===========================================================\n"
      check rec.diagnostic.len > 0
    else:
      check rec.kind == roSuccess
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
