## Smoke test for ct_test_interface — confirms the type declarations
## compile and that object-constructor syntax works (a precondition
## for reprobuild's typed-output binding shape
## ``<HandleType>(path: <value>)``).

import std/unittest

import ct_test_interface

suite "t_smoke_ct_test_interface":
  test "t_smoke_ct_test_interface":
    let b = TestBinary(path: "/tmp/binary")
    check b.path == "/tmp/binary"

    let r = TestResultsHandle(path: "/tmp/results.json")
    check r.path == "/tmp/results.json"

    let c = TestCatalogHandle(path: "/tmp/catalog.json")
    check c.path == "/tmp/catalog.json"

    let id: TestId = "mySuite::myTest"
    check id == "mySuite::myTest"
