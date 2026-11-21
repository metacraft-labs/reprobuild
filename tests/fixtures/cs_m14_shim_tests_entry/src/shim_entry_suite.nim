## The shim's tests in a `tests:` block of a program built with
## nim-entrypoints, beside a `testCase` and a `main:`. nim-entrypoints
## answers the tests entry and lists the block's tests; the shim runs them.
## The shim is imported first, so it keeps standard output before the
## protocol-carrying `std/unittest` takes it for its own `--list`.

import ct_test_unittest_parallel
import entrypoints
import entrypoints/tests

testCase "alpha":
  echo "CSM14SHIM alpha"

tests:
  suite "math":
    echo "CSM14SUITE math"

    test "add":
      echo "CSM14SHIM math::add"

    test "mul":
      echo "CSM14SHIM math::mul" # mul's body

  test "loose":
    echo "CSM14SHIM loose"

main:
  echo "CSM14SHIM main"
