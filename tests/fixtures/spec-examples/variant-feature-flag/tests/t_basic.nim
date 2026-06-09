import std/unittest

import ../src/server

suite "basic":
  test "server starts on a port":
    check startServer(8080) == true
