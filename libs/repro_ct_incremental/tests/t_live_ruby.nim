## M13 — LIVE Ruby recording drives the engine end-to-end (REQUIRED).
##
## This is the headline M13 test: NO hand-crafted trace. The test writes a real
## 3-function Ruby program (`used_a`, `used_b` executed; `unused_c` defined but
## never called), records it LIVE with the PRODUCTION native Ruby recorder (the
## Rust extension, NOT the pure-Ruby oracle) into a modern CTFS `.ct` bundle, and
## drives the SAME `record()` / `decide()` engine over the live bundle:
##
##   * editing an EXECUTED function (then re-recording) ⇒ `idRerunChanged`;
##   * editing the UNEXECUTED `unused_c` ⇒ `idSkipUnchanged`.
##
## Both decisions are made from a REAL, freshly-recorded CTFS trace read via
## `ct-print --json-events` — the genuine live path, end-to-end.
##
## # Provisioning (build once, reuse — NO silent skips)
##
## The recorder is built at most once via `ensureRubyRecorderBuilt` (cached by
## its on-disk Rust release artefact); `ct-print` is built at most once into the
## known build path. The native Ruby recorder DOES build and record on this host
## (arm64 macOS), so this test MUST pass here — if the recorder cannot be built
## or cannot record, the test FAILS LOUDLY with the captured diagnostic; it is
## never `unittest.skip`-ed.

import std/[unittest, os, strutils]
import repro_ct_incremental
import live_record

const
  # The 3-function program. used_a/used_b are executed (called from main);
  # unused_c is defined but never called, so the recorder never emits it as a
  # called function — it is absent from the live trace's executed set.
  rubyProgram = """def used_a(x); x + 1; end
def used_b(x); x * 2; end
def unused_c(x); x - 99; end
def main; puts(used_a(2) + used_b(3)); end
main
"""

proc writeProgram(dir, body: string): string =
  ## Write the Ruby program into `dir/prog.rb` and return its absolute path.
  let path = dir / "prog.rb"
  writeFile(path, body)
  path

proc mirrorRecordedSource(recordedAbsPath, body: string): string =
  ## The CTFS bundle records the program's ABSOLUTE path. The engine strips the
  ## leading separator and resolves it under `sourceRoot`, so mirror `body` at
  ## `<sourceRoot>/<recordedAbsPath-without-leading-slash>` and return sourceRoot.
  let root = freshLiveDir("repro_ct_live_ruby_src_")
  let rel = recordedAbsPath.strip(leading = true, trailing = false,
    chars = {DirSep, '/'})
  let dst = root / rel
  createDir(dst.parentDir)
  writeFile(dst, body)
  root

proc editFunctionLine(sourceRoot, recordedAbsPath, funcName, newLine: string) =
  ## Replace the single-line `def <funcName>...end` line in the mirrored source.
  let rel = recordedAbsPath.strip(leading = true, trailing = false,
    chars = {DirSep, '/'})
  let path = sourceRoot / rel
  var lines = readFile(path).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip().startsWith("def " & funcName):
      lines[i] = newLine
      writeFile(path, lines.join("\n"))
      return
  doAssert false, "function not found in mirrored source: " & funcName

# The absolute path the program is written to (and thus the path the recorder
# records). We write into a fresh dir per recording so concurrent runs don't
# clash; the recorded path is read back from the test program's own location.

suite "M13 live Ruby recording":

  setup:
    # ct-print is required to read any CTFS bundle the recorder produces.
    let ctp = ensureCtPrintBuilt()
    doAssert ctp.ok, "ct-print could not be built for the M13 Ruby test:\n" &
      ctp.diagnostic

  test "live_ruby_recording_decides_end_to_end":
    # --- record the program LIVE with the production native Ruby recorder ----
    let progDir = freshLiveDir("repro_ct_live_ruby_prog_")
    let progPath = writeProgram(progDir, rubyProgram)
    let rec = recordRubyLive(progPath)
    # The native Ruby recorder builds + records on this host: a gate here is a
    # HARD failure (never a silent skip), surfacing the exact captured output.
    if rec.kind == roGated:
      checkpoint("Ruby live recording gated unexpectedly:\n" & rec.diagnostic)
    require rec.kind == roSuccess

    # The reader must see exactly {<top-level>, main, used_a, used_b} from the
    # LIVE bundle; unused_c (never called) is absent — proving the executed set
    # comes from a genuine recording, not source inspection.
    let execRes = readExecutedFunctionsCtfs(rec.ctPath)
    check execRes.isOk
    var names: seq[string]
    for f in execRes.get(): names.add f.name
    check "used_a" in names
    check "used_b" in names
    check "main" in names
    check "unused_c" notin names

    # --- (a) correct SKIP: unchanged source ----------------------------------
    let rootSkip = mirrorRecordedSource(progPath, rubyProgram)
    var cacheSkip = initCache(rootSkip / "cache.json")
    let recA = record(cacheSkip, "ruby_live", rec.traceDir, rootSkip)
    check recA.isOk
    if recA.isErr: checkpoint("record error: " & recA.error)
    let decSkip = decide("ruby_live", rec.traceDir, rootSkip, cacheSkip)
    check decSkip.kind == idSkipUnchanged

    # --- (b) correct RERUN: edit an EXECUTED function, then RE-RECORD ----------
    # We genuinely re-record the edited program (a real second live recording),
    # then decide against the ORIGINAL cache — the executed function's source
    # changed, so the engine must re-run.
    let rootRerun = mirrorRecordedSource(progPath, rubyProgram)
    var cacheRerun = initCache(rootRerun / "cache.json")
    check record(cacheRerun, "ruby_live", rec.traceDir, rootRerun).isOk
    # Edit used_a's body in the mirrored source (it IS executed).
    editFunctionLine(rootRerun, progPath, "used_a",
      "def used_a(x); x + 1000; end")
    let decRerun = decide("ruby_live", rec.traceDir, rootRerun, cacheRerun)
    check decRerun.kind == idRerunChanged
    check "used_a" in decRerun.changedFuncs
    # used_b (also executed, unedited) must NOT be listed — function-level
    # precision over a REAL live bundle.
    check "used_b" notin decRerun.changedFuncs

    # --- (c) editing the UNEXECUTED unused_c still SKIPS -----------------------
    # unused_c is never called, so it is absent from the live executed set;
    # editing it must NOT re-run (function-level, not file-level, precision over
    # one shared source file recorded live).
    let rootUnexec = mirrorRecordedSource(progPath, rubyProgram)
    var cacheUnexec = initCache(rootUnexec / "cache.json")
    check record(cacheUnexec, "ruby_live", rec.traceDir, rootUnexec).isOk
    editFunctionLine(rootUnexec, progPath, "unused_c",
      "def unused_c(x); x - 123456; end")
    let decUnexec = decide("ruby_live", rec.traceDir, rootUnexec, cacheUnexec)
    check decUnexec.kind == idSkipUnchanged
