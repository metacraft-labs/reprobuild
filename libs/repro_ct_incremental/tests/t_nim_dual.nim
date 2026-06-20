## M9 tests — Nim's DUAL recording path.
##
## Nim is the one CodeTracer language recordable BOTH ways. The SAME `calc.nim`
## fixture is driven through the SAME `record()`/`decide()` engine on two
## different traces, and the engine picks the shallow-hash strategy PER TRACE
## from `detectBackend` alone — never from the language name:
##
##   * SOURCE path  (`fixtures/m9_nim_dual/trace_source/`, canonical
##     Function/Call records ⇒ `tbSourceInterpreted`): the `.nim` SOURCE
##     extractor hashes proc bodies as TEXT. Editing an executed proc's body
##     re-runs; editing an unexecuted proc skips.
##
##   * NATIVE path  (`fixtures/m9_nim_dual/trace_native/`, native calltrace +
##     native structural signal ⇒ `tbNativeDwarf`): the SAME calc.nim is
##     compiled with `nim c` to a real binary and each executed proc is hashed
##     from its COMPILED INSTRUCTION BYTES (`shallowHashNative`). Editing +
##     rebuilding an executed proc re-runs; editing an unexecuted proc skips —
##     via instruction bytes, NOT source.
##
## # The Nim native name-matching requirement (the M9 crux)
##
## Nim MANGLES proc names when compiling via C: `usedA` becomes
## `usedA__<modulehash>_uN`. The `_uN` suffix is a DECLARATION-ORDER counter, so
## it is build-specific — editing an EARLIER proc renumbers the symbols of LATER
## procs. Therefore the native calltrace's `functionName`s cannot be hardcoded:
## the test discovers them by running `nm` on the freshly-built binary
## (`mangledName`) so every name matches a real symbol `shallowHashNative` can
## locate. The fixture's source order (usedA, usedB, then unusedC, then
## mainCalc) keeps the EXECUTED leaves' suffixes stable across an unusedC edit
## (only symbols declared AFTER unusedC renumber), so the unexecuted-edit case
## genuinely skips. This is verified empirically by the guards below.
##
## Platform: arm64 macOS ⇒ Mach-O; `nm`/`otool` drive the native function table
## (see native_hash.nim). The tests assert on decisions/hashes, not raw
## addresses, so they also hold on the ELF (Linux) branch.

import std/[unittest, os, strutils, times, osproc, json, tables]
import repro_ct_incremental

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  nimFixture = fixturesDir / "m9_nim_dual"
  fixtureSource = nimFixture / "src" / "calc.nim"
  buildScript = nimFixture / "build.sh"
  sourceTraceDir = nimFixture / "trace_source"
  # Source path as the canonical trace records it (leading slash stripped),
  # i.e. where the temp source copy must live under the test's sourceRoot.
  relSource = "fixtures/m9_nim_dual/src/calc.nim"

  # The executed set on BOTH paths is the two pure POSITION-INDEPENDENT leaves.
  # (On the SOURCE path the committed trace additionally executes mainCalc, but
  # the native executed set is exactly the leaves — see ExecutedBaseNames.)
  ExecutedBaseNames = ["usedA", "usedB"]

var tempCounter = 0

proc freshTempDir(prefix: string): string =
  inc tempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let dir = getTempDir() / (prefix & "_" & $stamp & "_" & $tempCounter)
  createDir(dir)
  dir

# ---------------------------------------------------------------------------
# SOURCE-path helpers (mirror the M3 multilang tests)
# ---------------------------------------------------------------------------

proc makeSourceRoot(srcText: string): string =
  ## Fresh temp dir with `srcText` written to the trace-expected relative path.
  let root = freshTempDir("repro_ct_m9_src")
  let dst = root / relSource
  createDir(dst.parentDir)
  writeFile(dst, srcText)
  root

proc nimEditBody(srcText, procName, newBodyLine: string): string =
  ## Replace the single body line immediately after `proc <procName>`'s
  ## definition line (the fixture procs are `proc <name>...:\n  <body>`).
  var lines = srcText.split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip().startsWith("proc " & procName):
      doAssert i + 1 < lines.len, "no body line after proc " & procName
      lines[i + 1] = "  " & newBodyLine
      return lines.join("\n")
  doAssert false, "proc not found: " & procName
  ""

# ---------------------------------------------------------------------------
# NATIVE-path helpers (mirror the M8 native tests, plus Nim name discovery)
# ---------------------------------------------------------------------------

proc compileInto(dir, sourceText: string): string =
  ## Build `sourceText` (a calc.nim variant) into `<dir>/calc` via the fixture's
  ## build.sh (`nim c` with the leaf-stabilising flags). Returns the binary path.
  createDir(dir)
  let src = dir / "calc.nim"
  let binPath = dir / "calc"
  writeFile(src, sourceText)
  let (output, code) = execCmdEx(
    "bash " & quoteShell(buildScript) & " " &
    quoteShell(src) & " " & quoteShell(binPath))
  if code != 0:
    echo "nim build failed:\n", output
  check code == 0
  check fileExists(binPath)
  binPath

proc symbolEncodesProc(sym, baseName: string): bool =
  ## Does the mangled symbol `sym` encode the Nim proc `baseName`? Nim's C
  ## backend uses one of TWO manglings depending on flags, and BOTH are matched
  ## here (the point of M9 is that the name is DISCOVERED from the binary, not
  ## assumed):
  ##
  ##   * `-g` (this fixture, for DWARF symbols) ⇒ an Itanium-style
  ##     `_ZN<len>calc<len>usedAE...` form, where the proc appears as the
  ##     length-prefixed component `<digits>usedA` terminated by `E` or another
  ##     length digit. This form carries NO declaration-order suffix, so it is
  ##     STABLE across edits — the property the executed-leaf skip relies on.
  ##   * legacy/`--debugger:off` ⇒ `usedA__<modulehash>_uN`, with a build-
  ##     specific `_uN` declaration-order suffix.
  ##
  ## We accept either: the base name must appear as a delimited identifier
  ## component — preceded by a non-identifier char (a length digit, `_`, or the
  ## `_ZN` boundary) and followed by `E`, `_`, a digit, or end-of-symbol — so a
  ## proc named `usedA` never accidentally matches `usedAB`.
  let idx = sym.find(baseName)
  if idx < 0:
    return false
  let afterIdx = idx + baseName.len
  # The char AFTER the base name must not continue the identifier with a letter
  # (so `usedA` does not match inside `usedAB`). A following digit is fine (the
  # next Itanium length), as are `E` (Itanium component end) and `_` (legacy).
  if afterIdx < sym.len:
    let c = sym[afterIdx]
    if c.isAlphaAscii() and c != 'E':
      return false
  true

proc mangledName(binary, baseName: string): string =
  ## Discover the MANGLED symbol Nim emitted for the proc `baseName` in this
  ## specific `binary`, by scanning the binary's function table (read via `nm`)
  ## for the unique symbol that encodes `baseName` (see `symbolEncodesProc`).
  ## The name MUST be read from the binary under test — never hardcoded — because
  ## Nim mangles proc names and the exact form is build/flag specific. Fails
  ## loudly if zero or more than one symbol matches.
  let tableRes = nativeFunctionTable(binary)
  check tableRes.isOk
  var matches: seq[string]
  for sym in tableRes.get().keys:
    if symbolEncodesProc(sym, baseName):
      matches.add sym
  if matches.len != 1:
    echo "expected exactly one symbol encoding '", baseName, "' in ", binary,
      ", got: ", matches
  check matches.len == 1
  matches[0]

proc writeNativeTrace(traceDir, binary: string; executedMangled: openArray[string]) =
  ## Hand-craft a native calltrace (`native_calltrace.json`) pointing `binary`
  ## at the freshly-built executable and listing exactly the EXECUTED functions
  ## by their MANGLED names (discovered via `mangledName`). A native structural
  ## signal (`trace_db_metadata.json`) is dropped so `detectBackend` routes to
  ## the native backend.
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
    """{"format":"ctfs","note":"M9 Nim native fixture: structural native signal."}""")

proc executedMangledFor(binary: string): seq[string] =
  ## The mangled symbol names of the executed leaves in `binary`.
  for base in ExecutedBaseNames:
    result.add mangledName(binary, base)

proc freshCache(dir: string): IncrementalCache =
  initCache(dir / "cache.json")

const testId = "fixture::calc"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M9: Nim dual recording path":

  test "source_trace_deflines_match_calc_nim":
    # GUARD: the committed source trace's Function defLines must point at the
    # actual `proc` lines in calc.nim, so each executed proc extracts a NON-EMPTY
    # body. (A doc-comment edit that shifts the proc lines without updating
    # trace_source/trace.json would otherwise silently make every body extract to
    # the "missing" sentinel — a false re-run, or worse a coincidental match.)
    let lines = readFile(fixtureSource).split('\n')
    let execRes = readExecutedFunctions(sourceTraceDir)
    check execRes.isOk
    for fn in execRes.get():
      # The recorded defLine line itself must start the named proc.
      check fn.defLine >= 1 and fn.defLine <= lines.len
      check lines[fn.defLine - 1].strip().startsWith("proc " & fn.name)
      # And the source extractor must capture a non-empty body there.
      let body = extractFunctionBody("calc.nim", lines, fn.defLine)
      check body.isOk
      check body.value.strip().len > 0

  test "nim_source_traced_uses_source_hash_and_decides":
    # SOURCE path over trace_source/ + calc.nim: editing an EXECUTED proc body
    # re-runs (source-text precision); editing an UNEXECUTED proc skips.
    let pristine = readFile(fixtureSource)

    block executedEdit:
      let root = makeSourceRoot(pristine)
      var cache = freshCache(root)
      check record(cache, testId, sourceTraceDir, root).isOk
      # Edit an EXECUTED proc (usedA) body.
      writeFile(root / relSource, nimEditBody(pristine, "usedA", "result = 42 + 99"))
      let d = decide(testId, sourceTraceDir, root, cache)
      check d.kind == idRerunChanged
      check "usedA" in d.changedFuncs
      # Function-level precision: a sibling executed leaf is NOT listed.
      check "usedB" notin d.changedFuncs

    block unexecutedEdit:
      let root = makeSourceRoot(pristine)
      var cache = freshCache(root)
      check record(cache, testId, sourceTraceDir, root).isOk
      # Edit an UNEXECUTED proc (unusedC) — not in the executed set ⇒ skip.
      writeFile(root / relSource, nimEditBody(pristine, "unusedC", "result = 777"))
      let d = decide(testId, sourceTraceDir, root, cache)
      check d.kind == idSkipUnchanged

  test "nim_native_traced_uses_instruction_hash_and_decides":
    # NATIVE path: compile calc.nim, record against the binary; editing +
    # rebuilding an EXECUTED proc re-runs, an UNEXECUTED one skips — via
    # instruction bytes, NOT source.
    let pristine = readFile(fixtureSource)

    block executedEdit:
      let dir = freshTempDir("repro_ct_m9_nat_exec")
      let binOrig = compileInto(dir / "orig", pristine)
      let traceOrig = dir / "trace_orig"
      writeNativeTrace(traceOrig, binOrig, executedMangledFor(binOrig))

      var cache = freshCache(dir)
      # sourceRoot is IGNORED on the native route (deps carry the binary in
      # dep.file). Pass a dummy to prove the source tree is never touched.
      check record(cache, testId, traceOrig, "/nonexistent-source-root").isOk

      # Edit + rebuild an EXECUTED proc (usedA): change its body so its compiled
      # instruction bytes change.
      let editedSrc = nimEditBody(pristine, "usedA",
        "result = 0\n  for i in 0 ..< 5: result += i\n  result += 100")
      let binEdited = compileInto(dir / "edited", editedSrc)
      let traceEdited = dir / "trace_edited"
      # usedA's own symbol suffix is stable (it is the FIRST proc); discover the
      # executed leaves' names from the EDITED binary so the calltrace matches it.
      writeNativeTrace(traceEdited, binEdited, executedMangledFor(binEdited))

      let d = decide(testId, traceEdited, "/nonexistent-source-root", cache)
      check d.kind == idRerunChanged
      # The cached dep keyed on the original usedA mangled name; on the edited
      # binary usedA's bytes changed, so the (same-named) usedA dep re-hashes.
      let usedAName = mangledName(binOrig, "usedA")
      check usedAName in d.changedFuncs

    block unexecutedEdit:
      let dir = freshTempDir("repro_ct_m9_nat_unexec")
      let binOrig = compileInto(dir / "orig", pristine)
      let traceOrig = dir / "trace_orig"
      let execOrig = executedMangledFor(binOrig)
      writeNativeTrace(traceOrig, binOrig, execOrig)

      var cache = freshCache(dir)
      check record(cache, testId, traceOrig, "/unused").isOk

      # Edit + rebuild an UNEXECUTED proc (unusedC). It is declared AFTER the
      # executed leaves, so growing it must NOT change the leaves' instruction
      # bytes NOR renumber their `_uN` suffixes.
      let editedSrc = nimEditBody(pristine, "unusedC",
        "result = 0\n  for i in 0 ..< 200: result += i*i*i\n  result += 99")
      let binEdited = compileInto(dir / "edited", editedSrc)
      let traceEdited = dir / "trace_edited"
      let execEdited = executedMangledFor(binEdited)
      writeNativeTrace(traceEdited, binEdited, execEdited)

      # GUARD 1 (names stable): the executed leaves keep the SAME mangled symbol
      # names across the unusedC edit (so the cached deps still resolve). If a
      # regression renumbered them, this fails loudly rather than silently
      # re-running for the wrong reason.
      check execEdited == execOrig

      # GUARD 2 (bytes stable): the executed leaves' instruction-byte hashes are
      # GENUINELY unchanged across the unusedC edit — so the skip is real, not a
      # coincidental re-run.
      for name in execOrig:
        let hOrig = shallowHashNative(binOrig, name)
        let hEdited = shallowHashNative(binEdited, name)
        check hOrig.isOk and hEdited.isOk
        check hOrig.get() == hEdited.get()

      # GUARD 3 (the edit is real): unusedC's OWN instruction-byte hash changed.
      let cName = mangledName(binOrig, "unusedC")
      let cEdited = mangledName(binEdited, "unusedC")
      let hcOrig = shallowHashNative(binOrig, cName)
      let hcEdited = shallowHashNative(binEdited, cEdited)
      check hcOrig.isOk and hcEdited.isOk
      check hcOrig.get() != hcEdited.get()

      let d = decide(testId, traceEdited, "/unused", cache)
      check d.kind == idSkipUnchanged

  test "same_nim_program_different_backend_picks_different_strategy":
    # detectBackend drives source-vs-native hashing for the SAME calc.nim. The
    # committed source-trace dir detects as tbSourceInterpreted; a native trace
    # dir (built at test time) detects as tbNativeDwarf. No language-name
    # branching anywhere — the strategy follows the BACKEND alone.
    let pristine = readFile(fixtureSource)

    # (a) The committed source trace ⇒ tbSourceInterpreted.
    let srcBackend = detectBackend(sourceTraceDir)
    check srcBackend.isOk
    check srcBackend.get() == tbSourceInterpreted

    # (b) A native trace built from the SAME program ⇒ tbNativeDwarf.
    let dir = freshTempDir("repro_ct_m9_strat")
    let bin = compileInto(dir / "bin", pristine)
    let natTrace = dir / "trace_native"
    writeNativeTrace(natTrace, bin, executedMangledFor(bin))
    let natBackend = detectBackend(natTrace)
    check natBackend.isOk
    check natBackend.get() == tbNativeDwarf

    # (c) The strategies are GENUINELY different. Demonstrate with an edit that
    # changes the SOURCE TEXT but NOT the compiled instruction bytes of an
    # executed leaf: a pure-whitespace/comment edit to usedA's body line. The
    # SOURCE hasher (text) sees a change; the NATIVE hasher (bytes) does not.
    #
    # usedA: `result = 1 + 1`  ->  `result = 1 + 1   # comment, same value`
    let commentedSrc = nimEditBody(pristine, "usedA",
      "result = 1 + 1   ## a comment that changes the SOURCE TEXT only")

    # SOURCE side: record pristine, then decide with the commented source ⇒ the
    # source-text hash of usedA changed ⇒ re-run.
    let srcRoot = makeSourceRoot(pristine)
    var srcCache = freshCache(srcRoot)
    check record(srcCache, testId, sourceTraceDir, srcRoot).isOk
    writeFile(srcRoot / relSource, commentedSrc)
    let srcDecision = decide(testId, sourceTraceDir, srcRoot, srcCache)
    check srcDecision.kind == idRerunChanged
    check "usedA" in srcDecision.changedFuncs

    # NATIVE side: the SAME comment edit compiles to BYTE-IDENTICAL machine code
    # (a comment is not emitted), so the native instruction-byte hash of usedA is
    # UNCHANGED ⇒ skip. This is the same program, the same edit, the OPPOSITE
    # decision — proving the strategy chosen per trace is genuinely different.
    let binCommented = compileInto(dir / "commented", commentedSrc)
    let usedAName = mangledName(bin, "usedA")
    let usedANameC = mangledName(binCommented, "usedA")
    check usedAName == usedANameC  # the comment edit did not renumber usedA
    let hPlain = shallowHashNative(bin, usedAName)
    let hComment = shallowHashNative(binCommented, usedANameC)
    check hPlain.isOk and hComment.isOk
    check hPlain.get() == hComment.get()  # instruction bytes identical

    # And drive it through the engine end-to-end: record native against `bin`,
    # decide against the byte-identical commented build ⇒ idSkipUnchanged.
    let natCache = block:
      var c = freshCache(dir / "natcache")
      check record(c, testId, natTrace, "/unused").isOk
      c
    let natTraceCommented = dir / "trace_native_commented"
    writeNativeTrace(natTraceCommented, binCommented, executedMangledFor(binCommented))
    let natDecision = decide(testId, natTraceCommented, "/unused", natCache)
    check natDecision.kind == idSkipUnchanged
