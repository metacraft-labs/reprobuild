## Smoke test for ct_test_nim_unittest — confirms ``NimUnittestBinary``
## constructs cleanly and the typed-tool surface is wired up.
##
## Does NOT exercise the full reprobuild edge-emission machinery — that
## is verified end-to-end in the reprobuild repo's Test-Edges M1 suite
## migration. This test just keeps the library from rotting.

import std/unittest

import ct_test_nim_unittest

suite "t_smoke_ct_test_nim_unittest":
  test "t_smoke_ct_test_nim_unittest":
    let handle = NimUnittestBinary(path: "build/test-bin/foo")
    check handle.path == "build/test-bin/foo"
    # NimUnittestToolId is exported so reprobuild's normalised graph
    # readers can match the action id back to this adapter.
    check NimUnittestToolId == "ct_test_nim_unittest.buildNimUnittest"
