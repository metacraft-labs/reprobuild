## M14 tests — native call trace via compile-time instrumentation.
##
## These are REAL on this arm64-macOS host (no `unittest.skip`, no gate, no
## hand-crafted substitute): each test compiles a genuine C program together with
## the committed C call-recorder runtime (`csrc/ct_instrument_runtime.c`) using
## the dev shell's `cc`, with `-finstrument-functions`, then RUNS it so the
## `__cyg_profile_func_enter` ABI captures the actually-entered functions into a
## log inside a temp trace dir. The reader (`readExecutedFunctionsInstrumented`)
## reads that log back as the de-duplicated executed-function set.
##
## The load-bearing assertion: a 4-function program (`used_a`, `used_b`,
## `unused_c`, `main`, where `main` calls only `used_a` + `used_b`) yields the
## executed set `{used_a, used_b, main}` with `unused_c` ABSENT — derived from a
## genuine instrumentation run on THIS host.
##
## Plus the fail-safe error cases (missing log, empty log, unresolvable capture)
## all return `Err` — so the engine re-runs and never false-skips.

import std/[unittest, os, strutils, times, sets, sequtils, algorithm]
import repro_ct_incremental

# A real 4-function C program. `main` calls used_a + used_b and NOT unused_c, so
# the executed set must be exactly {used_a, used_b, main}. `noinline` keeps each
# function a distinct, separately-entered unit (so the instrumentation hook fires
# per function, not a single inlined main).
const fourFuncC = """
#include <stdio.h>
__attribute__((noinline)) int used_a(int x) { return x + 1; }
__attribute__((noinline)) int used_b(int x) { return x * 2; }
__attribute__((noinline)) int unused_c(int x) { return x - 99; }
int main(void) {
  int r = used_a(2) + used_b(3);
  printf("%d\n", r);
  return 0;
}
"""

var tempCounter = 0

proc freshTempDir(): string =
  ## A unique temp dir for one capture. On macOS this resolves under
  ## /var/folders/… (via /private/var/…); we never depend on the literal path.
  inc tempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let dir = getTempDir() / ("repro_ct_m14_" & $stamp & "_" & $tempCounter)
  createDir(dir)
  dir

proc nameSet(fns: seq[ExecutedFunction]): HashSet[string] =
  result = initHashSet[string]()
  for f in fns:
    result.incl f.name

suite "M14 native call trace via compile-time instrumentation":

  test "instrumented_run_yields_executed_set_excluding_unused":
    # Compile the 4-function program with the recorder runtime, run it, and read
    # back the executed set. It must be exactly {used_a, used_b, main}; unused_c
    # is NEVER entered, so it must be ABSENT.
    let traceDir = freshTempDir()
    let src = traceDir / "prog.c"
    writeFile(src, fourFuncC)

    let runRes = instrumentAndRun(src, traceDir)
    check runRes.isOk
    if runRes.isErr:
      echo "instrumentAndRun failed: ", runRes.error
    require runRes.isOk

    let execRes = readExecutedFunctionsInstrumented(traceDir)
    check execRes.isOk
    if execRes.isErr:
      echo "read failed: ", execRes.error
    require execRes.isOk

    let names = nameSet(execRes.get())
    check "used_a" in names
    check "used_b" in names
    check "main" in names
    # The load-bearing exclusion: an UNEXECUTED function must not appear.
    check "unused_c" notin names

    # Every entry carries the owning binary in `file` and defLine 0 (native
    # convention: deps key on name+binary, not a source line).
    let binary = traceDir / "instrumented_prog"
    for f in execRes.get():
      check f.file == binary
      check f.defLine == 0

  test "executed_set_is_deduplicated_and_name_sorted":
    # A program that calls used_a many times still records the name once, and the
    # set is returned name-sorted (deterministic engine input).
    let traceDir = freshTempDir()
    let src = traceDir / "prog.c"
    writeFile(src, """
__attribute__((noinline)) int used_a(int x) { return x + 1; }
__attribute__((noinline)) int used_b(int x) { return x * 2; }
int main(void) {
  volatile int s = 0;
  for (int i = 0; i < 50; i++) s += used_a(i) + used_b(i);
  (void)s;
  return 0;
}
""")
    let runRes = instrumentAndRun(src, traceDir)
    check runRes.isOk
    let execRes = readExecutedFunctionsInstrumented(traceDir)
    check execRes.isOk
    let fns = execRes.get()
    # De-dup: each name appears at most once.
    let names = fns.mapIt(it.name)
    check names.len == names.toHashSet().len
    # Name-sorted.
    var sorted = names
    sorted.sort(cmp)
    check names == sorted

  test "missing_log_errs":
    # A trace dir with NO capture log ⇒ Err (fail-safe re-run, never a skip).
    let traceDir = freshTempDir()
    let res = readExecutedFunctionsInstrumented(traceDir)
    check res.isErr

  test "empty_log_errs":
    # An empty / whitespace-only log ⇒ Err (no resolvable functions).
    let traceDir = freshTempDir()
    writeFile(traceDir / InstrumentOutFile, "\n   \n\n")
    let res = readExecutedFunctionsInstrumented(traceDir)
    check res.isErr

  test "unresolvable_capture_errs":
    # A log that contains ONLY names absent from the (present) binary's symbol
    # table resolves to an empty dependency set ⇒ Err. We first build a real
    # instrumented binary (so the symbol-table pruning path runs), then overwrite
    # the log with names that are NOT functions of that binary.
    let traceDir = freshTempDir()
    let src = traceDir / "prog.c"
    writeFile(src, fourFuncC)
    let runRes = instrumentAndRun(src, traceDir)
    check runRes.isOk
    # Overwrite the genuine capture with only-bogus names. The binary
    # (instrumented_prog) exists, so the reader builds its symbol table and
    # prunes every bogus name, yielding an empty set ⇒ Err.
    writeFile(traceDir / InstrumentOutFile,
      "this_is_not_a_function_xyz\nanother_phantom_symbol_qpr\n")
    let res = readExecutedFunctionsInstrumented(traceDir)
    check res.isErr

  test "missing_source_errs":
    # Compile-side fail-safe: a non-existent C source ⇒ Err, never a silent build.
    let traceDir = freshTempDir()
    let res = instrumentAndRun(traceDir / "does_not_exist.c", traceDir)
    check res.isErr

  test "nonzero_exit_binary_errs":
    # A run that exits NON-ZERO ⇒ Err (the test "failed", so the engine must not
    # treat its capture as a clean skip baseline).
    let traceDir = freshTempDir()
    let src = traceDir / "prog.c"
    writeFile(src, """
__attribute__((noinline)) int used_a(int x) { return x + 1; }
int main(void) { return used_a(40) + 2; }  /* exits 43, non-zero */
""")
    let res = instrumentAndRun(src, traceDir)
    check res.isErr
