## M15 — LIVE native recording via compile-time instrumentation drives the engine.
##
## This is the GENUINE live native incremental decision on arm64-macOS, mirroring
## the live Ruby/Python/JS tests (`t_live_js.nim`). There is NO platform gate, NO
## `unittest.skip`, NO hand-crafted trace: the test compiles a real C program with
## `-finstrument-functions` + the committed M14 recorder runtime
## (`recordNativeInstrumentedLive`), RUNS it so the executed-function set is
## captured for real, and then drives the engine's native incremental decision
## (instruction-byte shallow hash, M7) end-to-end:
##
##   1. the executed set is exactly {used_a, used_b, main} (unused_c ABSENT),
##   2. a correct SKIP            (recompile unchanged ⇒ idSkipUnchanged),
##   3. a correct RE-RUN          (edit the EXECUTED used_a, recompile ⇒
##                                 idRerunChanged naming used_a),
##   4. a correct SKIP            (edit the UNEXECUTED unused_c, recompile ⇒
##                                 idSkipUnchanged — function-level precision at
##                                 the machine-code level).
##
## # Why the native shallow hash is over a CLEAN binary (not the instrumented one)
##
## `-finstrument-functions` injects `__cyg_profile_func_enter/exit` calls into
## every function; those calls are pc-relative to the linked-in runtime, so ANY
## edit that changes total code size relocates the runtime relative to every
## instrumented function and changes their bytes. Hashing the instrumented binary
## would therefore re-hash the executed functions on the unrelated `unused_c` edit
## (a SAFE but useless re-run). So the harness records a CLEAN, non-instrumented
## binary of the same source for hashing (instrumentation is a DISCOVERY tool
## only) — see `native_trace.instrumentHashBinaryPath`. The clean binary's
## executed leaves + `main` (which calls only the position-independent leaves, no
## external function) keep byte-identical machine code across the `unused_c` edit,
## so the skip is GENUINE, not a coincidental re-run.
##
## # Why each "edit" step RECOMPILES into a fresh trace dir
##
## The native shallow hash is over the compiled binary, so an edit only takes
## effect after a recompile. Each step records a fresh recording of the same
## source (baseline), then produces a SEPARATE recording of the edited source and
## decides against THAT trace dir — `decide` rebinds the cached native deps onto
## the CURRENT trace's recorded binary (the native analogue of the source path's
## sourceRoot rebind), so it always hashes the freshly-rebuilt binary. The
## recorded program's source is captured INSIDE the trace dir, so the edit mirrors
## against the path the recording actually used — no macOS /private/var vs
## /var/folders mismatch can cause a false skip.

import std/[unittest, os, strutils, sets]
import repro_ct_incremental
import live_record

const
  # A 4-function C program. `main` calls used_a + used_b and NOT unused_c, so the
  # instrumentation capture's executed set is exactly {used_a, used_b, main}.
  # `noinline` keeps each function a distinct, separately-entered, separately-
  # hashable unit. CRUCIAL for the skip-on-unexecuted-edit precision: `main` calls
  # ONLY the two position-independent leaves (no printf / no external call), so a
  # clean-binary hash of `main` is invariant to an `unused_c` edit's relocation
  # (main's only pc-relative refs are to used_a/used_b, whose RELATIVE distance to
  # main is unchanged). `unused_c` is LAST so its edit cannot shift the executed
  # functions within the source's own code region either.
  baseProgram = """
__attribute__((noinline)) int used_a(int x) { return x + 1; }
__attribute__((noinline)) int used_b(int x) { return x * 2; }
int main(void) { volatile int r = used_a(2) + used_b(3); (void)r; return 0; }
__attribute__((noinline)) int unused_c(int x) { return x - 99; }
"""

  # used_a edited: a genuinely different body ⇒ different compiled instruction
  # bytes ⇒ a changed shallow hash ⇒ a re-run naming used_a.
  usedAEditedProgram = """
__attribute__((noinline)) int used_a(int x) { int s = x; for (int i = 0; i < x; i++) s += i * 3 + 7; return s + 1000; }
__attribute__((noinline)) int used_b(int x) { return x * 2; }
int main(void) { volatile int r = used_a(2) + used_b(3); (void)r; return 0; }
__attribute__((noinline)) int unused_c(int x) { return x - 99; }
"""

  # unused_c edited (NEVER executed): a different body, but it is not in the
  # executed set, so the decision must SKIP. The clean-binary hashes of the
  # executed {used_a, used_b, main} are byte-identical across this edit.
  unusedCEditedProgram = """
__attribute__((noinline)) int used_a(int x) { return x + 1; }
__attribute__((noinline)) int used_b(int x) { return x * 2; }
int main(void) { volatile int r = used_a(2) + used_b(3); (void)r; return 0; }
__attribute__((noinline)) int unused_c(int x) { int s = 0; for (int i = 0; i < x; i++) s += i * 7 - 3; return s - 123456; }
"""

proc nameSet(fns: seq[ExecutedFunction]): HashSet[string] =
  result = initHashSet[string]()
  for f in fns:
    result.incl f.name

proc recordOrFail(program: string): RecorderOutcome =
  ## Record a program live via instrumentation, failing LOUDLY (never gating) on
  ## this arm64-macOS host: the instrumentation path is genuinely live here, so a
  ## `roGated` outcome is a real toolchain regression, not a platform limitation.
  let rec = recordNativeInstrumentedLive(program)
  if rec.kind == roGated:
    echo "\n=========== M15 NATIVE LIVE-RECORDING FAILURE ==========="
    echo "Compile-time instrumentation native recording failed on a host where"
    echo "it is expected to be LIVE (arm64-macOS). This is a toolchain"
    echo "regression, NOT a legitimate platform gate. Captured diagnostic:"
    echo rec.diagnostic
    echo "========================================================\n"
  doAssert rec.kind == roSuccess,
    "native instrumentation live recording did not succeed (see diagnostic)"
  rec

suite "M15 live native recording (compile-time instrumentation)":

  test "live_native_instrumented_decides_end_to_end":
    # --- executed-set assertion (genuine instrumentation capture) ---
    let recBase = recordOrFail(baseProgram)

    # The trace dir routes to the native instruction-byte backend.
    let backend = detectBackend(recBase.traceDir)
    check backend.isOk
    check backend.get() == tbNativeDwarf

    let execRes = readExecutedFunctionsNativeAny(recBase.traceDir)
    check execRes.isOk
    let names = nameSet(execRes.get())
    check "used_a" in names
    check "used_b" in names
    check "main" in names
    # The load-bearing exclusion: an UNEXECUTED function must not appear.
    check "unused_c" notin names

    # --- a correct SKIP: recompile unchanged ⇒ idSkipUnchanged ---
    block correctSkip:
      let root = freshLiveDir("repro_ct_live_native_instr_root_")
      var cache = initCache(root / "cache.json")
      check record(cache, "native_live", recBase.traceDir, root).isOk
      # A fresh identical recording (recompile of the SAME source). The clean
      # recorded binary's per-function bytes are stable across identical rebuilds.
      let recAgain = recordOrFail(baseProgram)
      check decide("native_live", recAgain.traceDir, root, cache).kind ==
        idSkipUnchanged

    # --- a correct RE-RUN: edit the EXECUTED used_a, recompile ⇒ idRerunChanged ---
    block correctRerun:
      let root = freshLiveDir("repro_ct_live_native_instr_root_")
      var cache = initCache(root / "cache.json")
      check record(cache, "native_live", recBase.traceDir, root).isOk
      let recEdited = recordOrFail(usedAEditedProgram)
      let dec = decide("native_live", recEdited.traceDir, root, cache)
      check dec.kind == idRerunChanged
      check "used_a" in dec.changedFuncs
      # used_b and main were not edited; precision means they are NOT named.
      check "used_b" notin dec.changedFuncs

    # --- a correct SKIP: edit the UNEXECUTED unused_c, recompile ⇒ idSkipUnchanged ---
    block correctSkipUnexecuted:
      let root = freshLiveDir("repro_ct_live_native_instr_root_")
      var cache = initCache(root / "cache.json")
      check record(cache, "native_live", recBase.traceDir, root).isOk
      let recEdited = recordOrFail(unusedCEditedProgram)
      check decide("native_live", recEdited.traceDir, root, cache).kind ==
        idSkipUnchanged
