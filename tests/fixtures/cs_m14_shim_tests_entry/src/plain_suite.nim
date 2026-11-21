## The same suite over `std/unittest` alone: no tests entry. It is run as a
## whole.

import std/unittest

suite "math":
  test "add":
    echo "CSM14SHIM math::add"

  test "mul":
    echo "CSM14SHIM math::mul" # mul's body
