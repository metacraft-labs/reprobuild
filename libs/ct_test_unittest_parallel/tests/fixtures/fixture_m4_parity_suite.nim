## Fixture binary for the M4 ct-test-runner parity + partition tests.
##
## Declares FIVE deterministic test cases across two suites:
##
## * ``alpha::pass_a``  — passes
## * ``alpha::pass_b``  — passes
## * ``alpha::skip_c``  — skips via ``skip()``
## * ``beta::pass_d``   — passes
## * ``beta::pass_e``   — passes
##
## Used by the M4 parity and partition-file verification tests:
##
## * ``t_ct_test_runner_full_suite_parity`` builds one copy, runs it
##   through both the M3 internal runner and the new ct-test-runner,
##   and asserts the pass/fail/skip totals match exactly.
## * ``t_ct_test_runner_partition_file_mode`` builds one copy, writes
##   a partition file naming three of the five tests, and asserts
##   exactly those three execute.

import ct_test_unittest_parallel

suite "alpha":
  test "pass_a":
    check 1 + 1 == 2

  test "pass_b":
    check "hello".len == 5

  test "skip_c":
    skip()

suite "beta":
  test "pass_d":
    check 10 - 4 == 6

  test "pass_e":
    check 7 * 6 == 42
