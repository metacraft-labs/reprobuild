## M0 tests for `readExecutedFunctions` — the trace→executed-functions reader.
##
## These are the three automated tests specified for M0 in
## `docs/Trace-Based-Incremental-Testing.milestones.org`. They run against the
## hand-built fixtures under `tests/fixtures/`, whose JSON matches the real
## CodeTracer text-JSON trace schema (see the fixture README).

import std/[unittest, os, algorithm]
import repro_ct_incremental

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  threeFuncsTrace = fixturesDir / "m0_three_funcs" / "trace"
  emptyCallsTrace = fixturesDir / "m0_empty_calls"
  malformedTrace = fixturesDir / "m0_malformed"

suite "M0: readExecutedFunctions":

  test "reads_executed_functions_from_fixture_trace":
    ## Over the m0 fixture, the reader returns exactly {main, used_a, used_b}
    ## with correct file + defLine; `unused_c` is absent.
    let res = readExecutedFunctions(threeFuncsTrace)
    check res.isOk
    let funcs = res.value

    # Exactly three executed functions, deterministically name-sorted.
    check funcs.len == 3
    let names = block:
      var s: seq[string]
      for f in funcs: s.add f.name
      s
    check names == @["main", "used_a", "used_b"]
    check isSorted(names)

    # `unused_c` is defined in the trace's Function table but never called,
    # so it must not appear.
    for f in funcs:
      check f.name != "unused_c"

    # File + defLine resolution is correct (path_id -> trace_paths.json,
    # Function.line -> defLine).
    const expectedFile = "/fixtures/m0_three_funcs/src/three_funcs.rb"
    for f in funcs:
      check f.file == expectedFile

    proc lineOf(name: string): int =
      for f in funcs:
        if f.name == name: return f.defLine
      -1
    check lineOf("main") == 28
    check lineOf("used_a") == 16
    check lineOf("used_b") == 20

  test "malformed_trace_returns_err_not_crash":
    ## A truncated/garbage trace dir yields an `Err`, never a crash.
    let res = readExecutedFunctions(malformedTrace)
    check res.isErr
    check res.error.len > 0

    # A wholly missing trace dir is also an Err, not a raise.
    let missing = readExecutedFunctions(fixturesDir / "does_not_exist")
    check missing.isErr

  test "empty_call_stream_returns_empty_set":
    ## A trace with `Function` records but no `Call` records returns an empty
    ## executed set (defensive — a defined-but-never-run program).
    let res = readExecutedFunctions(emptyCallsTrace)
    check res.isOk
    check res.value.len == 0
