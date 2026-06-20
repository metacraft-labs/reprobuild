## M10 tests — the full language → strategy matrix (the final milestone).
##
## Phase 2's point: ONE engine + ONE dispatch table cover every CodeTracer
## language by classifying each into one of exactly TWO mechanisms (or DUAL, for
## Nim), with only the strategy varying. These tests:
##
##   1. `language_strategy_table_covers_matrix` — every language group in the
##      CodeTracer Language-Support-Matrix
##      (`codetracer-specs/Language-Support-Matrix.md`) resolves through
##      `languageStrategy` to the EXPECTED mechanism, every entry is cited, and an
##      unknown/empty language fails safe with an `Err` (never a guess).
##
##   2. `representative_language_per_group_decides_end_to_end` — one INTERPRETED
##      language (Python, reusing the M3 fixture), one NATIVE language (C, reusing
##      the M8 fixture, real compiled binary), and Nim DUAL (reusing the M9
##      fixtures) are each driven THROUGH the table into the SAME engine and make
##      a correct skip AND a correct rerun. The table tells us the expected
##      backend; `detectBackend` (authoritative) confirms it; the engine decides.
##
##   3. `full_phase2_suite_has_no_regressions` — the M5/M10 guard: with
##      `--ct-incremental` absent the watch decision is the byte-for-byte legacy
##      run path (asserted in code via the disabled `WatchCtIncrementalGate`). The
##      whole-suite regression run + `repro_cli_support` checks are done as part of
##      verification (documented in the milestones file).
##
## Platform: arm64 macOS ⇒ Mach-O for the native/Nim-native paths; `nm`/`otool`
## drive the native function table (see native_hash.nim). The assertions are on
## decisions/hashes, so they also hold on the ELF (Linux) branch.

import std/[unittest, os, strutils, times, osproc, json, tables]
import repro_ct_incremental

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"

var tempCounter = 0

proc freshTempDir(prefix: string): string =
  inc tempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let dir = getTempDir() / (prefix & "_" & $stamp & "_" & $tempCounter)
  createDir(dir)
  dir

# ---------------------------------------------------------------------------
# Test 1 — the table covers the matrix
# ---------------------------------------------------------------------------

suite "M10: language-strategy table covers the matrix":

  test "language_strategy_table_covers_matrix":
    # The matrix groups, ENCODED here so this test FAILS if a group becomes
    # unclassified or its mechanism drifts. Citations into
    # codetracer-specs/Language-Support-Matrix.md are in language_matrix.nim.

    # --- INTERPRETED / source group ⇒ tbSourceInterpreted -------------------
    const interpreted = [
      "Python", "Ruby", "JavaScript", "TypeScript", "Lua", "WASM"]
    for lang in interpreted:
      let s = languageStrategy(lang)
      check s.isOk
      check s.get().mechanism == lmSourceInterpreted
      check s.get().backends == @[tbSourceInterpreted]
      check s.get().discovery == ddCanonicalFunctionCall
      check s.get().shallowHash == shSourceText
      # Every entry must cite the matrix (auditability).
      check s.get().matrixCitation.contains(MatrixDoc)
      check s.get().matrixCitation.len > MatrixDoc.len

    # --- NATIVE / DWARF group ⇒ tbNativeDwarf -------------------------------
    const native = [
      "C", "C++", "Rust", "Go", "Pascal", "D", "Fortran", "Ada",
      "Crystal", "Odin", "V"]
    for lang in native:
      let s = languageStrategy(lang)
      check s.isOk
      check s.get().mechanism == lmNativeDwarf
      check s.get().backends == @[tbNativeDwarf]
      check s.get().discovery == ddNativeCalltrace
      check s.get().shallowHash == shInstructionBytes
      check s.get().matrixCitation.contains(MatrixDoc)

    # --- DUAL (Nim) — both backends valid, chosen per-trace -----------------
    let nim = languageStrategy("Nim")
    check nim.isOk
    check nim.get().mechanism == lmDual
    # Models Nim as EITHER backend; the per-trace backend (detectBackend) wins.
    check tbSourceInterpreted in nim.get().backends
    check tbNativeDwarf in nim.get().backends
    check nim.get().discovery == ddPerTrace
    check nim.get().shallowHash == shPerTrace
    # backendIsExpected accepts BOTH for Nim — the advisory validation hook.
    check backendIsExpected(nim.get(), tbSourceInterpreted)
    check backendIsExpected(nim.get(), tbNativeDwarf)
    # A single-mechanism language rejects the other backend (advisory only).
    check backendIsExpected(languageStrategy("Python").get(), tbSourceInterpreted)
    check (not backendIsExpected(languageStrategy("Python").get(), tbNativeDwarf))
    check backendIsExpected(languageStrategy("Rust").get(), tbNativeDwarf)
    check (not backendIsExpected(languageStrategy("Rust").get(), tbSourceInterpreted))

    # --- Aliases resolve ----------------------------------------------------
    check languageStrategy("cpp").get().mechanism == lmNativeDwarf
    check languageStrategy("js").get().mechanism == lmSourceInterpreted
    check languageStrategy("golang").get().mechanism == lmNativeDwarf
    check languageStrategy("webassembly").get().mechanism == lmSourceInterpreted

    # --- Unknown / empty ⇒ fail-safe Err, NEVER a guessed strategy ----------
    check languageStrategy("Brainfuck").isErr
    check languageStrategy("").isErr
    check languageStrategy("   ").isErr
    # The error names the matrix doc so the operator knows where to look.
    check languageStrategy("Whitespace").error.contains(MatrixDoc)

    # --- Coverage is non-trivial and totally classified ---------------------
    # Every key in the table resolves and lands in exactly one mechanism (no
    # unclassified entries possible — the enum + Result make it total).
    let langs = supportedLanguages()
    check langs.len >= (interpreted.len + native.len + 1)  # +1 for Nim
    for k in langs:
      let s = languageStrategy(k)
      check s.isOk
      check s.get().mechanism in {lmSourceInterpreted, lmNativeDwarf, lmDual}

# ---------------------------------------------------------------------------
# Test 2 — representative language per group, end to end through the table
# ---------------------------------------------------------------------------

const matrixTestId = "fixture::matrix"

# --- INTERPRETED representative: Python (M3 fixture) -------------------------

const
  pyFixture = fixturesDir / "m3_python_funcs"
  pyTraceDir = pyFixture / "trace"
  pyRelSource = "fixtures/m3_python_funcs/src/three_funcs.py"
  pySrcFile = pyFixture / "src" / "three_funcs.py"

proc pyMakeSourceRoot(srcText: string): string =
  let root = freshTempDir("repro_ct_m10_py")
  let dst = root / pyRelSource
  createDir(dst.parentDir)
  writeFile(dst, srcText)
  root

proc pyEditBody(srcText, funcName, newBodyLine: string): string =
  ## Replace the body line after `def <funcName>():`.
  var lines = srcText.split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip().startsWith("def " & funcName):
      doAssert i + 1 < lines.len
      lines[i + 1] = "    " & newBodyLine
      return lines.join("\n")
  doAssert false, "def not found: " & funcName
  ""

# --- NATIVE representative: C (M8 fixture) ----------------------------------

const
  cFixture = fixturesDir / "m8_native_c"
  cSource = cFixture / "src" / "native_funcs.c"
  cBuild = cFixture / "build.sh"
  cExecuted = ["used_a", "used_b"]   # the two pure leaves (main excluded)

proc cCompileInto(dir, sourceText: string): string =
  createDir(dir)
  let src = dir / "prog.c"
  let binPath = dir / "prog"
  writeFile(src, sourceText)
  let (output, code) = execCmdEx(
    "bash " & quoteShell(cBuild) & " " & quoteShell(src) & " " & quoteShell(binPath))
  if code != 0: echo "C build failed:\n", output
  check code == 0
  check fileExists(binPath)
  binPath

proc cWriteNativeTrace(traceDir, binary: string; executed: openArray[string]) =
  createDir(traceDir)
  var calls = newJArray()
  var pc = 0x1000
  for name in executed:
    var c = newJObject()
    c["functionName"] = newJString(name)
    c["calleePc"] = newJInt(pc)
    calls.add c
    pc += 16
  var root = newJObject()
  root["binary"] = newJString(binary)
  root["calls"] = calls
  writeFile(traceDir / NativeCalltraceFile, root.pretty())
  writeFile(traceDir / "trace_db_metadata.json",
    """{"format":"ctfs","note":"M10 native C representative."}""")

proc cEditFunc(srcText, funcName, newBody: string): string =
  ## Replace the single-line body of a C function `int <funcName>(...) { ... }`.
  var lines = srcText.split('\n')
  for i in 0 ..< lines.len:
    if lines[i].contains(" " & funcName & "(") and lines[i].contains("{"):
      doAssert i + 1 < lines.len
      lines[i + 1] = "  " & newBody
      return lines.join("\n")
  doAssert false, "C function not found: " & funcName
  ""

# --- Nim DUAL representative (M9 fixture) -----------------------------------

const
  nimFixture = fixturesDir / "m9_nim_dual"
  nimSource = nimFixture / "src" / "calc.nim"
  nimBuild = nimFixture / "build.sh"
  nimSourceTraceDir = nimFixture / "trace_source"
  nimRelSource = "fixtures/m9_nim_dual/src/calc.nim"
  nimExecuted = ["usedA", "usedB"]

proc nimMakeSourceRoot(srcText: string): string =
  let root = freshTempDir("repro_ct_m10_nim_src")
  let dst = root / nimRelSource
  createDir(dst.parentDir)
  writeFile(dst, srcText)
  root

proc nimEditBody(srcText, procName, newBodyLine: string): string =
  var lines = srcText.split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip().startsWith("proc " & procName):
      doAssert i + 1 < lines.len
      lines[i + 1] = "  " & newBodyLine
      return lines.join("\n")
  doAssert false, "proc not found: " & procName
  ""

proc nimCompileInto(dir, sourceText: string): string =
  createDir(dir)
  let src = dir / "calc.nim"
  let binPath = dir / "calc"
  writeFile(src, sourceText)
  let (output, code) = execCmdEx(
    "bash " & quoteShell(nimBuild) & " " & quoteShell(src) & " " & quoteShell(binPath))
  if code != 0: echo "nim build failed:\n", output
  check code == 0
  check fileExists(binPath)
  binPath

proc nimSymbolEncodesProc(sym, baseName: string): bool =
  let idx = sym.find(baseName)
  if idx < 0: return false
  let afterIdx = idx + baseName.len
  if afterIdx < sym.len:
    let c = sym[afterIdx]
    if c.isAlphaAscii() and c != 'E': return false
  true

proc nimMangledName(binary, baseName: string): string =
  let tableRes = nativeFunctionTable(binary)
  check tableRes.isOk
  var matches: seq[string]
  for sym in tableRes.get().keys:
    if nimSymbolEncodesProc(sym, baseName): matches.add sym
  check matches.len == 1
  matches[0]

proc nimWriteNativeTrace(traceDir, binary: string; executedMangled: openArray[string]) =
  createDir(traceDir)
  var calls = newJArray()
  var pc = 0x1000
  for name in executedMangled:
    var c = newJObject()
    c["functionName"] = newJString(name)
    c["calleePc"] = newJInt(pc)
    calls.add c
    pc += 16
  var root = newJObject()
  root["binary"] = newJString(binary)
  root["calls"] = calls
  writeFile(traceDir / NativeCalltraceFile, root.pretty())
  writeFile(traceDir / "trace_db_metadata.json",
    """{"format":"ctfs","note":"M10 Nim native representative."}""")

proc nimExecutedMangledFor(binary: string): seq[string] =
  for base in nimExecuted: result.add nimMangledName(binary, base)

proc freshCache(dir: string): IncrementalCache =
  initCache(dir / "cache.json")

suite "M10: representative language per mechanism group, end to end":

  test "representative_language_per_group_decides_end_to_end":

    # ===================================================================== #
    # GROUP 1 — INTERPRETED (Python), through the table → engine.
    # ===================================================================== #
    block interpretedGroup:
      # The table classifies Python as the SOURCE/interpreted mechanism...
      let strat = languageStrategy("Python")
      check strat.isOk
      check strat.get().mechanism == lmSourceInterpreted
      # ...and detectBackend (AUTHORITATIVE) agrees for the committed trace,
      # validated through the advisory hook.
      let detected = detectBackend(pyTraceDir)
      check detected.isOk
      check detected.get() == tbSourceInterpreted
      check backendIsExpected(strat.get(), detected.get())

      let pristine = readFile(pySrcFile)

      # CORRECT RERUN: edit an EXECUTED function (used_a) ⇒ idRerunChanged.
      block rerun:
        let root = pyMakeSourceRoot(pristine)
        var cache = freshCache(root)
        check record(cache, matrixTestId, pyTraceDir, root).isOk
        writeFile(root / pyRelSource, pyEditBody(pristine, "used_a", "return 999"))
        let d = decide(matrixTestId, pyTraceDir, root, cache)
        check d.kind == idRerunChanged
        check "used_a" in d.changedFuncs
        check "used_b" notin d.changedFuncs

      # CORRECT SKIP: edit an UNEXECUTED function (unused_c) ⇒ idSkipUnchanged.
      block skip:
        let root = pyMakeSourceRoot(pristine)
        var cache = freshCache(root)
        check record(cache, matrixTestId, pyTraceDir, root).isOk
        writeFile(root / pyRelSource, pyEditBody(pristine, "unused_c", "return 1234"))
        let d = decide(matrixTestId, pyTraceDir, root, cache)
        check d.kind == idSkipUnchanged

    # ===================================================================== #
    # GROUP 2 — NATIVE (C), through the table → engine, real compiled binary.
    # ===================================================================== #
    block nativeGroup:
      let strat = languageStrategy("C")
      check strat.isOk
      check strat.get().mechanism == lmNativeDwarf

      let pristine = readFile(cSource)
      let dir = freshTempDir("repro_ct_m10_c")
      let binOrig = cCompileInto(dir / "orig", pristine)
      let traceOrig = dir / "trace_orig"
      cWriteNativeTrace(traceOrig, binOrig, cExecuted)

      # detectBackend (AUTHORITATIVE) routes this to native; the table agrees.
      let detected = detectBackend(traceOrig)
      check detected.isOk
      check detected.get() == tbNativeDwarf
      check backendIsExpected(strat.get(), detected.get())

      # CORRECT RERUN: edit + rebuild an EXECUTED function (used_a).
      block rerun:
        var cache = freshCache(dir / "rerun")
        check record(cache, matrixTestId, traceOrig, "/nonexistent").isOk
        let editedSrc = cEditFunc(pristine, "used_a",
          "int s = 0; for (int i = 0; i < 5; i++) s += i; return s + 100;")
        let binEdited = cCompileInto(dir / "edited_a", editedSrc)
        let traceEdited = dir / "trace_edited_a"
        cWriteNativeTrace(traceEdited, binEdited, cExecuted)
        let d = decide(matrixTestId, traceEdited, "/nonexistent", cache)
        check d.kind == idRerunChanged
        check "used_a" in d.changedFuncs

      # CORRECT SKIP: edit + rebuild an UNEXECUTED function (unused_c).
      block skip:
        var cache = freshCache(dir / "skip")
        check record(cache, matrixTestId, traceOrig, "/nonexistent").isOk
        let editedSrc = cEditFunc(pristine, "unused_c",
          "int s = 0; for (int i = 0; i < 50; i++) s += i*i; return s;")
        let binEdited = cCompileInto(dir / "edited_c", editedSrc)
        let traceEdited = dir / "trace_edited_c"
        cWriteNativeTrace(traceEdited, binEdited, cExecuted)
        # Guard: the executed leaves' instruction-byte hashes are genuinely
        # unchanged across the unused_c edit, so the skip is real.
        for name in cExecuted:
          let hOrig = shallowHashNative(binOrig, name)
          let hEdited = shallowHashNative(binEdited, name)
          check hOrig.isOk and hEdited.isOk
          check hOrig.get() == hEdited.get()
        let d = decide(matrixTestId, traceEdited, "/nonexistent", cache)
        check d.kind == idSkipUnchanged

    # ===================================================================== #
    # GROUP 3 — Nim DUAL: SAME program, BOTH backends chosen by detectBackend.
    # ===================================================================== #
    block nimDualGroup:
      let strat = languageStrategy("Nim")
      check strat.isOk
      check strat.get().mechanism == lmDual
      # The table models Nim as EITHER; the per-trace backend wins.

      let pristine = readFile(nimSource)

      # --- DUAL ARM A: SOURCE-traced Nim ⇒ tbSourceInterpreted ⇒ source hash.
      block sourceArm:
        let detected = detectBackend(nimSourceTraceDir)
        check detected.isOk
        check detected.get() == tbSourceInterpreted
        check backendIsExpected(strat.get(), detected.get())

        # CORRECT RERUN: edit an EXECUTED proc (usedA).
        block rerun:
          let root = nimMakeSourceRoot(pristine)
          var cache = freshCache(root)
          check record(cache, matrixTestId, nimSourceTraceDir, root).isOk
          writeFile(root / nimRelSource, nimEditBody(pristine, "usedA", "result = 42 + 99"))
          let d = decide(matrixTestId, nimSourceTraceDir, root, cache)
          check d.kind == idRerunChanged
          check "usedA" in d.changedFuncs
        # CORRECT SKIP: edit an UNEXECUTED proc (unusedC).
        block skip:
          let root = nimMakeSourceRoot(pristine)
          var cache = freshCache(root)
          check record(cache, matrixTestId, nimSourceTraceDir, root).isOk
          writeFile(root / nimRelSource, nimEditBody(pristine, "unusedC", "result = 777"))
          let d = decide(matrixTestId, nimSourceTraceDir, root, cache)
          check d.kind == idSkipUnchanged

      # --- DUAL ARM B: NATIVE-traced Nim ⇒ tbNativeDwarf ⇒ instruction hash.
      block nativeArm:
        let dir = freshTempDir("repro_ct_m10_nim_nat")
        let binOrig = nimCompileInto(dir / "orig", pristine)
        let traceOrig = dir / "trace_orig"
        nimWriteNativeTrace(traceOrig, binOrig, nimExecutedMangledFor(binOrig))

        let detected = detectBackend(traceOrig)
        check detected.isOk
        check detected.get() == tbNativeDwarf
        check backendIsExpected(strat.get(), detected.get())

        # CORRECT RERUN: edit + rebuild an EXECUTED proc (usedA).
        block rerun:
          var cache = freshCache(dir / "rerun")
          check record(cache, matrixTestId, traceOrig, "/nonexistent").isOk
          let editedSrc = nimEditBody(pristine, "usedA",
            "result = 0\n  for i in 0 ..< 5: result += i\n  result += 100")
          let binEdited = nimCompileInto(dir / "edited_a", editedSrc)
          let traceEdited = dir / "trace_edited_a"
          nimWriteNativeTrace(traceEdited, binEdited, nimExecutedMangledFor(binEdited))
          let d = decide(matrixTestId, traceEdited, "/nonexistent", cache)
          check d.kind == idRerunChanged
          check nimMangledName(binOrig, "usedA") in d.changedFuncs

        # CORRECT SKIP: edit + rebuild an UNEXECUTED proc (unusedC).
        block skip:
          var cache = freshCache(dir / "skip")
          let execOrig = nimExecutedMangledFor(binOrig)
          check record(cache, matrixTestId, traceOrig, "/nonexistent").isOk
          let editedSrc = nimEditBody(pristine, "unusedC",
            "result = 0\n  for i in 0 ..< 200: result += i*i*i\n  result += 99")
          let binEdited = nimCompileInto(dir / "edited_c", editedSrc)
          let traceEdited = dir / "trace_edited_c"
          let execEdited = nimExecutedMangledFor(binEdited)
          nimWriteNativeTrace(traceEdited, binEdited, execEdited)
          # Guards (mirror M9): names + bytes of executed leaves stable.
          check execEdited == execOrig
          for name in execOrig:
            let hOrig = shallowHashNative(binOrig, name)
            let hEdited = shallowHashNative(binEdited, name)
            check hOrig.isOk and hEdited.isOk
            check hOrig.get() == hEdited.get()
          let d = decide(matrixTestId, traceEdited, "/nonexistent", cache)
          check d.kind == idSkipUnchanged

# ---------------------------------------------------------------------------
# Test 3 — no Phase-2 regression: the legacy gate
# ---------------------------------------------------------------------------

suite "M10: full Phase-2 suite has no regressions":

  test "full_phase2_suite_has_no_regressions":
    # PART (a) — the M5 gate assertion, re-verified at the engine level: with the
    # --ct-incremental feature DISABLED (the legacy default), the watch decision
    # is the byte-for-byte legacy RUN path. A default WatchCtIncrementalGate is
    # disabled and short-circuits to weaRun WITHOUT consulting the incremental
    # engine — so the no-flag path can NEVER skip a test.
    var gate = WatchCtIncrementalGate()
    check (not gate.enabled)
    let root = freshTempDir("repro_ct_m10_gate")
    # The trace dir / cache path are irrelevant: a disabled gate never reads them.
    let v = gatedWatchDecision(gate, matrixTestId,
      pyTraceDir, root, root / "cache.json")
    check v.action == weaRun
    check v.reason == "ct-incremental-disabled"

    # And ENABLING the gate delegates to the real seam (proves the gate is the
    # only thing standing between legacy and incremental — not a separate code
    # path that could drift). With no cache entry, the verdict is a fresh RUN.
    var enabledGate = WatchCtIncrementalGate(enabled: true)
    let pristine = readFile(pySrcFile)
    let sroot = pyMakeSourceRoot(pristine)
    let cachePath = sroot / "cache.json"
    let v2 = gatedWatchDecision(enabledGate, matrixTestId, pyTraceDir, sroot, cachePath)
    check v2.action == weaRun
    check v2.reason == "fresh"

    # PART (b) — the whole-suite regression run + repro_cli_support standalone
    # checks are performed during verification (all M0-M9 lib test files +
    # repro_cli_support/tests/t_watch_ct_incremental_flags.nim +
    # `nim check libs/repro_cli_support/src/repro_cli_support.nim` exit 0), and
    # documented in docs/Trace-Based-Incremental-Testing.milestones.org (M10).
