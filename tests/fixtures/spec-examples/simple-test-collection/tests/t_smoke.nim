import std/unittest

import ../src/lib

suite "smoke":
  test "library is importable":
    check add(2, 2) == 4

  test "subtract works":
    check subtract(5, 3) == 2
