## Baseline fixture for backward-compat verification — uses ONLY
## ``std/unittest`` (no ``ct_test_unittest_parallel`` import). When
## the binary is built with the protocol library on ``--path`` but
## NOT imported, behaviour must be identical to a plain
## ``std/unittest`` binary.

import std/unittest

suite "baseline_suite":
  test "baseline_test_passes":
    check 1 + 1 == 2

  test "baseline_test_arithmetic":
    check 2 * 3 == 6
