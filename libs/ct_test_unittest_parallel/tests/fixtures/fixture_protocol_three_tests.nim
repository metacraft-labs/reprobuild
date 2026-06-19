## Fixture test binary used by the M2 protocol verification tests.
##
## Declares THREE tests across TWO suites with deterministic outcomes:
##
## * ``arithmetic::addition`` — passes
## * ``arithmetic::subtraction_fails`` — fails (intentional)
## * ``markers::skipped`` — skips
##
## The M2 verification tests build this fixture once, then drive it
## via ``--list-json``, ``--run "..."``, and the
## ``NIMTEST_RESULT_FILE`` env var to check that the Tier-1 Standard
## protocol shapes work as specified.

import ct_test_unittest_parallel

suite "arithmetic":
  test "addition":
    check 2 + 2 == 4

  test "subtraction_fails":
    check 5 - 3 == 99

suite "markers":
  test "skipped":
    skip()
