## Tests of `ct_test_unittest_parallel`, nothing else: the shim answers
## `--entrypoint=tests --list` and `--run-exact=<name>` itself. Each test
## prints a marker no other test prints, so a run's output says which tests
## it ran. The suite body prints a line of its own, which must not reach the
## list.

import ct_test_unittest_parallel

suite "math":
  echo "CSM14SUITE math"

  test "add":
    echo "CSM14SHIM math::add"

  test "mul":
    echo "CSM14SHIM math::mul" # mul's body

test "loose":
  echo "CSM14SHIM loose"
