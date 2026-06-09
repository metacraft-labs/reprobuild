import std/unittest

import ../src/server

suite "tls":
  test "tls-enabled build path":
    when not defined(useTls):
      check false # the `test` template's variant-conditioned enrollment
                  # should have dropped this test entirely when
                  # enableTLS == false; reaching this branch means the
                  # variant guard was not honoured.
    else:
      check startServer(8443) == true
