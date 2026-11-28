## The same tests over `std/unittest` alone. The `std/unittest` of the
## codetracer Nim fork reprobuild pins answers the tests entry itself, so
## this binary is listed and run per test like the shim's. The suite body
## prints a line of its own, which must not reach the list.

import std/unittest

suite "math":
  echo "CSM14SUITE math"

  test "add":
    echo "CSM14SHIM math::add"

  test "mul":
    echo "CSM14SHIM math::mul" # mul's body

test "loose":
  echo "CSM14SHIM loose"
