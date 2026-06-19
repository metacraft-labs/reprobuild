## Smoke test for ``ct_test_unittest_parallel`` — confirms the shim
## compiles cleanly, registers tests, and runs them in the default
## (no-protocol-flag) mode with std/unittest's standard output.
##
## Protocol-mode behavior is exercised end-to-end in the
## ``t_every_test_binary_speaks_list_json_protocol`` and
## ``t_test_binary_run_one_writes_result_file`` integration tests.

import std/strutils

import ct_test_unittest_parallel

suite "t_smoke_ct_test_unittest_parallel":
  test "registry_populated_at_module_init":
    let tests = registeredTests()
    # At minimum the running test itself is in the registry.
    check tests.len >= 1
    var found = false
    for entry in tests:
      if entry.name == "registry_populated_at_module_init":
        found = true
        check entry.suite == "t_smoke_ct_test_unittest_parallel"
        check entry.file.endsWith("t_smoke_ct_test_unittest_parallel.nim")
        check entry.line > 0
    check found

  test "default_mode_runs_normally":
    # In the absence of --list / --run, currentProtocolMode is
    # pmDefault and the body runs identically to std/unittest.
    check currentProtocolMode() == pmDefault
    check 1 + 1 == 2
