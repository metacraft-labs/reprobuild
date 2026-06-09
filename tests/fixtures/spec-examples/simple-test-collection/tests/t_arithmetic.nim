import std/unittest

import ../src/lib

suite "arithmetic":
  test "add is commutative":
    check add(3, 7) == add(7, 3)

  test "add identity":
    check add(0, 42) == 42
    check add(42, 0) == 42

  test "subtract is inverse of add":
    check subtract(add(10, 5), 5) == 10
