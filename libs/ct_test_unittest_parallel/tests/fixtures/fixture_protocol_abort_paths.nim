## Fixture test binary for the cases that leave the process from inside
## their body, driven by ``t_test_binary_run_one_writes_result_file``.
##
## * ``abort_paths::passes`` — passes; the control whose result document
##   must be unchanged by the abort handling
## * ``abort_paths::require_fails`` — records a checkpoint, then fails a
##   ``require``, which ``quit``s from inside the body
## * ``abort_paths::quits_in_body`` — calls ``quit(0)`` mid-body
##
## Every case is deliberately named and outcome-fixed: the test asserts
## the exact checkpoint and condition text below.

import ct_test_unittest_parallel

suite "abort_paths":
  test "passes":
    checkpoint "passing case checkpoint"
    check 2 + 2 == 4

  test "require_fails":
    checkpoint "captured build output: abort-paths-marker"
    let observed = 2 + 2
    require observed == 5
    checkpoint "unreachable after require"

  test "quits_in_body":
    quit(0)
