## M13 — LIVE Python recording drives the engine end-to-end (REQUIRED).
##
## A headline M13 test alongside the Ruby one: NO hand-crafted trace, NO
## `unittest.skip`. The test writes a real 3-function Python program (`used_a`,
## `used_b` executed; `unused_c` defined but never called), records it LIVE with
## the PRODUCTION maturin/PyO3 Python recorder into a modern CTFS `.ct` bundle,
## and drives the SAME `record()` / `decide()` engine over the live bundle:
##
##   * editing an EXECUTED function (then re-recording) ⇒ `idRerunChanged`;
##   * editing the UNEXECUTED `unused_c` ⇒ `idSkipUnchanged`.
##
## Both decisions are made from a REAL, freshly-recorded CTFS trace read via
## `ct-print --json-events` — the genuine live path, end-to-end.
##
## # Provisioning (build once, reuse — NO silent skips)
##
## The recorder is built at most once via `ensurePythonRecorderBuilt` (cached by
## its on-disk native extension under the editable source tree, plus the `.venv`
## interpreter); the heavy `just venv 3.13 dev` maturin compile runs only when the
## built-marker is absent. `ct-print` is built at most once into the known build
## path. The production Python recorder DOES build and record on this host (arm64
## macOS) after the recorder's flake fix (gating `cargo-llvm-cov` off darwin, now
## pushed upstream) — so this test MUST pass here. A genuine build/record failure
## FAILS LOUDLY with the captured diagnostic; it is never `unittest.skip`-ed.
##
## NOTE: the previous M13 revision wrongly gated this language as "the dev shell
## won't build". That diagnosis used the WRONG entry (`just dev` + `uv`); the
## correct `just venv 3.13 dev` builds and records LIVE here, as proven by this
## test's live executed set ({`<__main__>`, `main`, `used_a`, `used_b`}).

import std/[unittest, os, strutils]
import repro_ct_incremental
import live_record

const
  # The 3-function program. used_a/used_b are executed (called from main);
  # unused_c is defined but never called, so the recorder never emits it as a
  # called function — it is absent from the live trace's executed set.
  pythonProgram = """def used_a(x):
    return x + 1

def used_b(x):
    return x * 2

def unused_c(x):
    return x - 99

def main():
    print(used_a(2) + used_b(3))

main()
"""

proc writeProgram(dir, body: string): string =
  ## Write the Python program into `dir/prog.py` and return its absolute path.
  let path = dir / "prog.py"
  writeFile(path, body)
  path

proc mirrorRecordedSource(recordedAbsPath, body: string): string =
  ## The CTFS bundle records the program's ABSOLUTE path. The engine strips the
  ## leading separator and resolves it under `sourceRoot`, so mirror `body` at
  ## `<sourceRoot>/<recordedAbsPath-without-leading-slash>` and return sourceRoot.
  let root = freshLiveDir("repro_ct_live_python_src_")
  let rel = recordedAbsPath.strip(leading = true, trailing = false,
    chars = {DirSep, '/'})
  let dst = root / rel
  createDir(dst.parentDir)
  writeFile(dst, body)
  root

proc editPyFunctionBody(sourceRoot, recordedAbsPath, funcName, newBodyLine: string) =
  ## Replace the indented body line of `def <funcName>(...)` in the mirrored
  ## Python source (the function body is the single `return ...` line below the
  ## `def`). Conservative: only rewrites the first body line.
  let rel = recordedAbsPath.strip(leading = true, trailing = false,
    chars = {DirSep, '/'})
  let path = sourceRoot / rel
  var lines = readFile(path).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip().startsWith("def " & funcName) and i + 1 < lines.len:
      lines[i+1] = newBodyLine
      writeFile(path, lines.join("\n"))
      return
  doAssert false, "function not found in mirrored python source: " & funcName

suite "M13 live Python recording":

  setup:
    # ct-print is required to read any CTFS bundle the recorder produces.
    let ctp = ensureCtPrintBuilt()
    doAssert ctp.ok, "ct-print could not be built for the M13 Python test:\n" &
      ctp.diagnostic

  test "live_python_recording_decides_end_to_end":
    # --- record the program LIVE with the production maturin Python recorder ---
    let progDir = freshLiveDir("repro_ct_live_python_prog_")
    let progPath = writeProgram(progDir, pythonProgram)
    let rec = recordPythonLive(progPath)
    # The production Python recorder builds + records on this host: a gate here is
    # a HARD failure (never a silent skip), surfacing the exact captured output.
    if rec.kind == roGated:
      checkpoint("Python live recording gated unexpectedly:\n" & rec.diagnostic)
    require rec.kind == roSuccess

    # The reader must see exactly {<__main__>, main, used_a, used_b} from the
    # LIVE bundle; unused_c (never called) is absent — proving the executed set
    # comes from a genuine recording, not source inspection.
    let execRes = readExecutedFunctionsCtfs(rec.ctPath)
    check execRes.isOk
    var names: seq[string]
    var recordedPath = ""
    for f in execRes.get():
      names.add f.name
      if recordedPath.len == 0 and f.file.len > 0: recordedPath = f.file
    check "used_a" in names
    check "used_b" in names
    check "main" in names
    check "unused_c" notin names
    # The bundle records an ABSOLUTE source path that may differ from the path we
    # wrote to: on macOS `/var/folders/.../T` (what `getTempDir` returns) is the
    # symlink form whose canonical target is `/private/var/folders/.../T`, and the
    # recorder canonicalises it. The engine resolves dependencies by the RECORDED
    # path (stripped of its leading separator) under `sourceRoot`, so we MUST
    # mirror + edit against the recorded path, not the local write path — else the
    # mirror lands beside where the engine looks and every function reads as
    # "missing" (a silent false SKIP). Derive the recorded path from the live set.
    check recordedPath.len > 0

    # --- (a) correct SKIP: unchanged source ----------------------------------
    let rootSkip = mirrorRecordedSource(recordedPath, pythonProgram)
    var cacheSkip = initCache(rootSkip / "cache.json")
    let recA = record(cacheSkip, "python_live", rec.traceDir, rootSkip)
    check recA.isOk
    if recA.isErr: checkpoint("record error: " & recA.error)
    let decSkip = decide("python_live", rec.traceDir, rootSkip, cacheSkip)
    check decSkip.kind == idSkipUnchanged

    # --- (b) correct RERUN: edit an EXECUTED function (used_a) -----------------
    # used_a IS executed, so editing its body changes the executed set's hash and
    # the engine must re-run, naming used_a. used_b (also executed, unedited) must
    # NOT be listed — function-level precision over a REAL live bundle. NOTE: the
    # module-level `<__main__>` pseudo-function's recorded body begins at line 1
    # (`def used_a`) and — by the indentation extractor — spans through used_a's
    # body up to the next sibling-indent `def`, so editing used_a's body legitimately
    # changes `<__main__>`'s hash too; we therefore assert used_a is present and
    # used_b absent (not an exact-set equality).
    let rootRerun = mirrorRecordedSource(recordedPath, pythonProgram)
    var cacheRerun = initCache(rootRerun / "cache.json")
    check record(cacheRerun, "python_live", rec.traceDir, rootRerun).isOk
    editPyFunctionBody(rootRerun, recordedPath, "used_a", "    return x + 1000")
    let decRerun = decide("python_live", rec.traceDir, rootRerun, cacheRerun)
    check decRerun.kind == idRerunChanged
    check "used_a" in decRerun.changedFuncs
    check "used_b" notin decRerun.changedFuncs

    # --- (c) editing the UNEXECUTED unused_c still SKIPS -----------------------
    # unused_c is never called, so it is absent from the live executed set;
    # editing it must NOT re-run. It also sits OUTSIDE every executed function's
    # extracted body (the `<__main__>` body stops at the `def used_b` sibling
    # indent, well before unused_c), so no executed function's hash changes —
    # function-level, not file-level, precision over one shared live source file.
    let rootUnexec = mirrorRecordedSource(recordedPath, pythonProgram)
    var cacheUnexec = initCache(rootUnexec / "cache.json")
    check record(cacheUnexec, "python_live", rec.traceDir, rootUnexec).isOk
    editPyFunctionBody(rootUnexec, recordedPath, "unused_c", "    return x - 123456")
    let decUnexec = decide("python_live", rec.traceDir, rootUnexec, cacheUnexec)
    check decUnexec.kind == idSkipUnchanged
