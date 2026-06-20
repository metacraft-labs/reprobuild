## M8 tests — end-to-end native incremental decision.
##
## These are REAL: each test compiles the `m8_native_c` C fixture (or an edited
## copy) with the dev shell's `cc` into a temp dir, hand-crafts a native
## calltrace pointing at the freshly-built binary, then drives the SAME
## `record()` / `decide()` engine the Phase-1 source tests use — routed through
## the native backend seams (native dependency discovery +
## instruction-byte shallow hashing) by `detectBackend`.
##
## The four M8 deliverable tests:
##   1. native_unchanged_binary_skips
##   2. native_changing_an_executed_function_reruns
##   3. native_changing_an_unexecuted_function_skips
##   4. native_missing_binary_falls_back_to_rerun
##
## Plus supporting guards that keep the fixture honest (the executed set is
## exactly the two leaves, and the executed-function hashes are genuinely stable
## across the unexecuted-function edit — so the skip in (3) is real, not a
## coincidental re-run).
##
## Platform: on this host (arm64 macOS) the fixture compiles to Mach-O; the
## native function table + shallow hash use `nm`/`otool` (see `native_hash.nim`).
## The tests assert on decisions/hashes, not raw addresses, so they also pass on
## the ELF (Linux) branch.

import std/[unittest, os, strutils, times, osproc, json]
import repro_ct_incremental

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  nativeFixture = fixturesDir / "m8_native_c"
  fixtureSource = nativeFixture / "src" / "native_funcs.c"
  buildScript = nativeFixture / "build.sh"

var tempCounter = 0

proc freshTempDir(): string =
  ## A unique temp dir for one build + trace, left on failure for inspection.
  inc tempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let dir = getTempDir() / ("repro_ct_m8_" & $stamp & "_" & $tempCounter)
  createDir(dir)
  dir

proc compileInto(dir, sourceText: string): string =
  ## Build `sourceText` into `<dir>/prog` via the fixture's build.sh; return the
  ## binary path. A broken toolchain surfaces loudly (never a silent "no change").
  createDir(dir)
  let src = dir / "prog.c"
  let binPath = dir / "prog"
  writeFile(src, sourceText)
  let (output, code) = execCmdEx(
    "bash " & quoteShell(buildScript) & " " &
    quoteShell(src) & " " & quoteShell(binPath))
  check code == 0
  if code != 0:
    echo "build failed:\n", output
  check fileExists(binPath)
  binPath

proc writeNativeTrace(traceDir, binary: string;
                      executed: openArray[string]) =
  ## Hand-craft a native calltrace (`native_calltrace.json`) in the documented
  ## prototype shape, pointing `binary` at the freshly-built executable and
  ## listing exactly the EXECUTED function names. A native trace dir is also
  ## marked by a native structural signal so `detectBackend` routes to the
  ## native backend — we drop a `trace_db_metadata.json` sidecar for that (the
  ## same signal the m6 `native_dbmeta` fixture uses).
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
  # Native structural signal so detectBackend selects tbNativeDwarf.
  writeFile(traceDir / "trace_db_metadata.json",
    """{"format":"ctfs","note":"M8 native fixture: structural native signal."}""")

proc editedExecutedSource(): string =
  ## Edit an EXECUTED function (`used_a`): `return 1` → a loop. Changes used_a's
  ## emitted instruction bytes while leaving used_b/unused_c untouched.
  let original = readFile(fixtureSource)
  let edited = original.replace(
    "__attribute__((noinline)) int used_a(void) {\n  return 1;\n}",
    "__attribute__((noinline)) int used_a(void) {\n  int s = 0;\n  for (int i = 0; i < 10; i++) s += i;\n  return s + 1;\n}")
  doAssert edited != original, "used_a edit did not apply — fixture changed?"
  edited

proc editedUnexecutedSource(): string =
  ## Edit the UNEXECUTED function (`unused_c`): grow it with a loop. Must NOT
  ## change the instruction bytes of the executed leaves used_a/used_b (they are
  ## position-independent), so the test still SKIPS — see the fixture README.
  let original = readFile(fixtureSource)
  let edited = original.replace(
    "__attribute__((noinline)) int unused_c(void) {\n  return 99;\n}",
    "__attribute__((noinline)) int unused_c(void) {\n  volatile int s = 0;\n  for (int i = 0; i < 200; i++) s += i * i * i;\n  return s + 99;\n}")
  doAssert edited != original, "unused_c edit did not apply — fixture changed?"
  edited

# The test's executed set: the two pure leaves. main is deliberately excluded
# so the executed set carries no call-containing (relocation-sensitive) function.
const ExecutedSet = ["used_a", "used_b"]

proc freshCache(dir: string): IncrementalCache =
  initCache(dir / "cache.json")

suite "M8 native end-to-end incremental decision":

  test "native_unchanged_binary_skips":
    # record() then decide() with the identical rebuilt binary ⇒ idSkipUnchanged.
    let dir = freshTempDir()
    let binA = compileInto(dir / "a", readFile(fixtureSource))
    let traceA = dir / "trace_a"
    writeNativeTrace(traceA, binA, ExecutedSet)

    var cache = freshCache(dir)
    # sourceRoot is IGNORED on the native route (deps carry the binary in
    # dep.file); pass a dummy to prove the source path is never touched.
    let recRes = record(cache, "native_test", traceA, "/nonexistent-source-root")
    check recRes.isOk

    # Rebuild the SAME source into a fresh binary (a real watch cycle rebuilds).
    let binB = compileInto(dir / "b", readFile(fixtureSource))
    let traceB = dir / "trace_b"
    writeNativeTrace(traceB, binB, ExecutedSet)

    let decision = decide("native_test", traceB, "/nonexistent-source-root", cache)
    check decision.kind == idSkipUnchanged

  test "native_changing_an_executed_function_reruns":
    # Edit + rebuild an EXECUTED function (used_a) ⇒ idRerunChanged naming it.
    let dir = freshTempDir()
    let binOrig = compileInto(dir / "orig", readFile(fixtureSource))
    let traceOrig = dir / "trace_orig"
    writeNativeTrace(traceOrig, binOrig, ExecutedSet)

    var cache = freshCache(dir)
    check record(cache, "native_test", traceOrig, "/unused").isOk

    let binEdited = compileInto(dir / "edited", editedExecutedSource())
    let traceEdited = dir / "trace_edited"
    writeNativeTrace(traceEdited, binEdited, ExecutedSet)

    let decision = decide("native_test", traceEdited, "/unused", cache)
    check decision.kind == idRerunChanged
    check "used_a" in decision.changedFuncs
    # used_b (also executed) is a leaf unaffected by the used_a edit ⇒ not listed.
    check "used_b" notin decision.changedFuncs

  test "native_changing_an_unexecuted_function_skips":
    # Edit + rebuild a function the test did NOT execute (unused_c) ⇒
    # idSkipUnchanged. This is native function-level precision at the
    # machine-code level: unused_c is not in the executed set, and editing it
    # does not change the executed leaves' instruction bytes.
    let dir = freshTempDir()
    let binOrig = compileInto(dir / "orig", readFile(fixtureSource))
    let traceOrig = dir / "trace_orig"
    writeNativeTrace(traceOrig, binOrig, ExecutedSet)

    var cache = freshCache(dir)
    check record(cache, "native_test", traceOrig, "/unused").isOk

    let binEdited = compileInto(dir / "edited", editedUnexecutedSource())
    let traceEdited = dir / "trace_edited"
    writeNativeTrace(traceEdited, binEdited, ExecutedSet)

    # GUARD (keeps the skip honest, not coincidental): the executed functions'
    # instruction-byte hashes are GENUINELY unchanged across the unused_c edit.
    # If a regression made an executed leaf relocation-sensitive, this fails
    # loudly here rather than the decision silently re-running for the wrong
    # reason.
    for fn in ExecutedSet:
      let hOrig = shallowHashNative(binOrig, fn)
      let hEdited = shallowHashNative(binEdited, fn)
      check hOrig.isOk and hEdited.isOk
      check hOrig.get() == hEdited.get()
    # And unused_c's OWN hash DID change (so the edit is real, not a no-op).
    let cOrig = shallowHashNative(binOrig, "unused_c")
    let cEdited = shallowHashNative(binEdited, "unused_c")
    check cOrig.isOk and cEdited.isOk
    check cOrig.get() != cEdited.get()

    let decision = decide("native_test", traceEdited, "/unused", cache)
    check decision.kind == idSkipUnchanged

  test "native_missing_binary_falls_back_to_rerun":
    # A missing/unreadable binary ⇒ re-run, never skip.
    let dir = freshTempDir()
    let binOrig = compileInto(dir / "orig", readFile(fixtureSource))
    let traceOrig = dir / "trace_orig"
    writeNativeTrace(traceOrig, binOrig, ExecutedSet)

    var cache = freshCache(dir)
    check record(cache, "native_test", traceOrig, "/unused").isOk

    # The decide-time trace points at a binary that does NOT exist. The native
    # calltrace file itself is present and readable (so the readability guard
    # passes), but the binary the deps reference is gone.
    let traceMissing = dir / "trace_missing"
    writeNativeTrace(traceMissing, dir / "no_such_binary", ExecutedSet)

    let decision = decide("native_test", traceMissing, "/unused", cache)
    # Never a skip. The missing binary makes every dep's current shallow hash the
    # reserved "missing" sentinel, so the deps read as changed ⇒ idRerunChanged.
    check decision.kind != idSkipUnchanged
    check isRerun(decision)
    check decision.kind == idRerunChanged

  # ---- Supporting guards ----------------------------------------------------

  test "native_executed_set_matches_fixture_calltrace":
    # The native dependency reader returns exactly the executed set, keyed on
    # (name + owning binary), with defLine 0 (the documented native convention).
    let dir = freshTempDir()
    let bin = compileInto(dir / "x", readFile(fixtureSource))
    let trace = dir / "trace"
    writeNativeTrace(trace, bin, ExecutedSet)

    let execRes = readExecutedFunctionsNative(trace)
    check execRes.isOk
    let funcs = execRes.get()
    check funcs.len == ExecutedSet.len
    var names: seq[string]
    for f in funcs:
      names.add f.name
      check f.file == bin      # file carries the BINARY path, not a source path
      check f.defLine == 0     # unused for native
    check "used_a" in names
    check "used_b" in names
    check "main" notin names   # main deliberately not executed
    check "unused_c" notin names

  test "native_detect_routes_through_native_backend":
    # The hand-crafted native trace dir detects as tbNativeDwarf (so decide/record
    # route through the native seams, not the source ones).
    let dir = freshTempDir()
    let bin = compileInto(dir / "x", readFile(fixtureSource))
    let trace = dir / "trace"
    writeNativeTrace(trace, bin, ExecutedSet)
    let backend = detectBackend(trace)
    check backend.isOk
    check backend.get() == tbNativeDwarf

  test "native_missing_calltrace_file_fails_safe":
    # A native trace dir whose native_calltrace.json is absent ⇒ decide
    # fail-safes to a re-run (never a skip), and record Errs.
    let dir = freshTempDir()
    let bin = compileInto(dir / "x", readFile(fixtureSource))
    let trace = dir / "trace"
    writeNativeTrace(trace, bin, ExecutedSet)

    var cache = freshCache(dir)
    check record(cache, "native_test", trace, "/unused").isOk

    # Now delete the calltrace, keeping the native structural signal so the
    # backend still detects native but the payload is gone.
    removeFile(trace / NativeCalltraceFile)
    let decision = decide("native_test", trace, "/unused", cache)
    check decision.kind == idRerunFailSafe
    check isRerun(decision)

    # And recording against a dir missing the calltrace Errs (never records a
    # skip-eligible entry from an unreadable native trace).
    let dir2 = freshTempDir()
    writeFile(dir2 / "trace_db_metadata.json", "{}")  # native signal, no calltrace
    var cache2 = freshCache(dir2)
    check record(cache2, "native_test", dir2, "/unused").isErr
