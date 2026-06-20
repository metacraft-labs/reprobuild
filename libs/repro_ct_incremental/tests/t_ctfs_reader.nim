## M12 tests — the engine consumes a MODERN CTFS `.ct` bundle.
##
## These are REAL: they read a real, committed CTFS bundle (`ruby.ct`, recorded
## from `live_demo.rb` by the native Ruby recorder) via the
## `ct-print --json-events` subprocess, and drive the SAME `record()` / `decide()`
## engine the Phase-1 source tests use — routed through the new `tbSourceCtfs`
## backend (CTFS dependency discovery + source-text shallow hashing) by an
## explicit `recorder_backend: "ctfs-interpreted"` metadata signal.
##
## The three M12 deliverable tests:
##   1. reads_executed_functions_from_a_ct_bundle
##   2. engine_decides_over_ctfs        (a correct SKIP and a correct RERUN)
##   3. ctfs_read_error_falls_back_to_rerun
##
## # ct-print provisioning (DOCUMENTED — no skipping)
##
## The reader needs `ct-print` from `codetracer-trace-format-nim`. The test setup
## (`ensureCtPrint`) resolves it via `CT_PRINT` / PATH / the known build path
## `/tmp/ctprint_build/ct-print`, and if none is present BUILDS it once into that
## known path (in the trace-format-nim dev shell) and reuses it for every test.
## Building is heavy, so it is done at most ONCE per test process. If ct-print
## genuinely cannot be built, the setup fails LOUDLY (a hard error) — it is never
## silently skipped (per the M12 acceptance: skipping is not acceptable).

import std/[unittest, os, strutils, times, osproc]
import repro_ct_incremental

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  ctfsFixture = fixturesDir / "m12_ctfs"
  ctBundle = ctfsFixture / "ruby.ct"
  rubySource = ctfsFixture / "live_demo.rb"
  # The bundle records the source path as `/tmp/live_demo.rb`; the engine strips
  # the leading slash and resolves it under `sourceRoot`, so the source must live
  # at `<sourceRoot>/tmp/live_demo.rb`.
  relSourcePath = "tmp/live_demo.rb"
  traceFormatRepo = "/Users/zahary/m/dev/codetracer-trace-format-nim"

var tempCounter = 0

proc freshTempDir(prefix: string): string =
  inc tempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let dir = getTempDir() / (prefix & $stamp & "_" & $tempCounter)
  createDir(dir)
  dir

proc ensureCtPrint() =
  ## Make `ct-print` resolvable for `readExecutedFunctionsCtfs`. If it is already
  ## resolvable (CT_PRINT / PATH / known build path) we are done; otherwise BUILD
  ## it once into the known build path in the trace-format-nim dev shell. A build
  ## failure is a HARD error (the M12 tests cannot run without ct-print, and
  ## skipping is not acceptable) — never a silent skip.
  if resolveCtPrint().isOk:
    return
  # Build into the documented known path. We invoke the build through the
  # trace-format-nim dev shell (`direnv exec`) so `nim` + the zstd pkg-config
  # flags are available, exactly as documented in the fixture README.
  doAssert dirExists(traceFormatRepo),
    "codetracer-trace-format-nim sibling not found at " & traceFormatRepo &
    " — cannot build ct-print for the M12 tests"
  createDir("/tmp/ctprint_build")
  let buildCmd =
    "direnv exec " & quoteShell(traceFormatRepo) & " bash -c " &
    quoteShell(
      "cd " & quoteShell(traceFormatRepo) & " && " &
      "nim c -d:release --mm:arc -p:src " &
      "--passC:\"$(pkg-config --cflags libzstd)\" " &
      "--passL:\"$(pkg-config --libs libzstd)\" " &
      "-o:/tmp/ctprint_build/ct-print src/codetracer_ct_print.nim")
  let (output, code) = execCmdEx(buildCmd)
  doAssert code == 0,
    "failed to build ct-print for the M12 tests (exit " & $code & "):\n" & output
  doAssert resolveCtPrint().isOk,
    "ct-print still not resolvable after building:\n" & output

proc makeCtfsTraceDir(): string =
  ## A fresh trace dir holding a COPY of the real `.ct` bundle plus a
  ## `trace_db_metadata.json` carrying `recorder_backend: "ctfs-interpreted"`,
  ## so `detectBackend` routes to the `tbSourceCtfs` backend (CTFS discovery +
  ## source hashing) rather than the default native `.ct` classification.
  let dir = freshTempDir("repro_ct_m12_trace_")
  copyFile(ctBundle, dir / "ruby.ct")
  writeFile(dir / "trace_db_metadata.json",
    """{"format":"ctfs","recorder_backend":"ctfs-interpreted"}""")
  dir

proc makeSourceRoot(): string =
  ## A fresh sourceRoot with the Ruby source mirrored at the recorded path
  ## (`<root>/tmp/live_demo.rb`).
  let root = freshTempDir("repro_ct_m12_src_")
  let dst = root / relSourcePath
  createDir(dst.parentDir)
  copyFile(rubySource, dst)
  root

proc editFunctionLine(root, funcName, newLine: string) =
  ## Replace the single-line `def <funcName>(...)...end` line in the mirrored
  ## source. The fixture functions are each a single line `def <name>...; end`.
  let path = root / relSourcePath
  var lines = readFile(path).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip().startsWith("def " & funcName):
      lines[i] = newLine
      writeFile(path, lines.join("\n"))
      return
  doAssert false, "function not found in source: " & funcName

suite "M12 CTFS .ct bundle ingestion":

  setup:
    ensureCtPrint()

  test "reads_executed_functions_from_a_ct_bundle":
    # Over the REAL .ct bundle, the reader returns exactly the executed set
    # {<top-level>, main, used_a, used_b}; unused_c (defined-but-never-called) is
    # absent. We read the bundle file directly (the reader accepts a .ct file or
    # a dir containing one).
    let execRes = readExecutedFunctionsCtfs(ctBundle)
    check execRes.isOk
    let funcs = execRes.get()
    var names: seq[string]
    for f in funcs:
      names.add f.name
    check "used_a" in names
    check "used_b" in names
    check "main" in names
    check "<top-level>" in names
    check "unused_c" notin names
    # Exactly four executed functions (de-duplicated, name-sorted).
    check funcs.len == 4
    check names == @["<top-level>", "main", "used_a", "used_b"]  # sorted
    # The reader resolves file + defLine best-effort from the call's entry step.
    for f in funcs:
      check f.file == "/tmp/live_demo.rb"
      case f.name
      of "used_a": check f.defLine == 1
      of "used_b": check f.defLine == 2
      of "main":   check f.defLine == 4
      else: discard  # <top-level> defLine is 0

  test "reads_executed_functions_from_a_trace_dir_containing_a_ct":
    # The reader also accepts a DIRECTORY containing exactly one .ct bundle.
    let traceDir = makeCtfsTraceDir()
    let execRes = readExecutedFunctionsCtfs(traceDir)
    check execRes.isOk
    var names: seq[string]
    for f in execRes.get(): names.add f.name
    check "used_a" in names
    check "unused_c" notin names

  test "engine_decides_over_ctfs":
    # End-to-end: record() then decide() over the real .ct bundle + its source.
    #   (a) identical source ⇒ idSkipUnchanged.
    #   (b) edit an EXECUTED function (used_a) ⇒ idRerunChanged naming it.
    let traceDir = makeCtfsTraceDir()

    # --- (a) correct SKIP: unchanged source -------------------------------
    let rootSkip = makeSourceRoot()
    var cacheSkip = initCache(rootSkip / "cache.json")
    let recA = record(cacheSkip, "ruby_test", traceDir, rootSkip)
    check recA.isOk
    if recA.isErr: echo "record error: ", recA.error
    let decSkip = decide("ruby_test", traceDir, rootSkip, cacheSkip)
    check decSkip.kind == idSkipUnchanged

    # --- (b) correct RERUN: edit an executed function ---------------------
    let rootRerun = makeSourceRoot()
    var cacheRerun = initCache(rootRerun / "cache.json")
    check record(cacheRerun, "ruby_test", traceDir, rootRerun).isOk
    # Edit used_a's body (it IS in the executed set).
    editFunctionLine(rootRerun, "used_a", "def used_a(x); x + 1000; end")
    let decRerun = decide("ruby_test", traceDir, rootRerun, cacheRerun)
    check decRerun.kind == idRerunChanged
    check "used_a" in decRerun.changedFuncs
    # used_b (also executed, unedited) must NOT be listed — function-level
    # precision over a real CTFS bundle.
    check "used_b" notin decRerun.changedFuncs

    # --- (c) editing an UNEXECUTED function still skips --------------------
    # unused_c is never called, so it is not in the executed/dependency set;
    # editing it must NOT re-run (proves function-level, not file-level,
    # precision even though all functions share one file).
    let rootUnexec = makeSourceRoot()
    var cacheUnexec = initCache(rootUnexec / "cache.json")
    check record(cacheUnexec, "ruby_test", traceDir, rootUnexec).isOk
    editFunctionLine(rootUnexec, "unused_c", "def unused_c(x); x - 123456; end")
    let decUnexec = decide("ruby_test", traceDir, rootUnexec, cacheUnexec)
    check decUnexec.kind == idSkipUnchanged

  test "ctfs_read_error_falls_back_to_rerun":
    # A corrupt/missing .ct, or ct-print unavailable, ⇒ re-run / Err, NEVER a
    # skip. We exercise three failure modes.

    # (i) A corrupt .ct bundle: record must Err (ct-print fails / no events),
    #     so no skip-eligible entry is ever recorded.
    let corruptDir = freshTempDir("repro_ct_m12_corrupt_")
    writeFile(corruptDir / "broken.ct", "this is not a valid CTFS container")
    writeFile(corruptDir / "trace_db_metadata.json",
      """{"format":"ctfs","recorder_backend":"ctfs-interpreted"}""")
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    let recCorrupt = record(cache, "ruby_test", corruptDir, root)
    check recCorrupt.isErr  # never records from an unreadable bundle

    # (ii) Now record a GOOD entry, then decide against a trace dir whose bundle
    #      is missing entirely ⇒ fail-safe re-run (never a skip).
    let goodTrace = makeCtfsTraceDir()
    check record(cache, "ruby_test", goodTrace, root).isOk
    let emptyDir = freshTempDir("repro_ct_m12_empty_")
    writeFile(emptyDir / "trace_db_metadata.json",
      """{"format":"ctfs","recorder_backend":"ctfs-interpreted"}""")
    let decMissing = decide("ruby_test", emptyDir, root, cache)
    check decMissing.kind == idRerunFailSafe
    check isRerun(decMissing)
    check decMissing.kind != idSkipUnchanged

    # (iii) ct-print unavailable ⇒ Err. We point CT_PRINT at a non-existent file
    #       AND temporarily hide PATH/known-build resolution by setting CT_PRINT
    #       to a bogus path; resolveCtPrint then Errs, so the reader Errs.
    let savedCtPrint = getEnv(CtPrintEnvVar)
    putEnv(CtPrintEnvVar, "/nonexistent/ct-print-binary")
    let readNoTool = readExecutedFunctionsCtfs(ctBundle)
    # Restore the env BEFORE asserting so a failure cannot leak the override.
    if savedCtPrint.len > 0: putEnv(CtPrintEnvVar, savedCtPrint)
    else: delEnv(CtPrintEnvVar)
    check readNoTool.isErr  # ct-print unavailable ⇒ Err ⇒ engine re-runs
