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

  test "body_runs_under_any_protocol_mode":
    # The test body executes identically regardless of how the binary
    # was invoked. Run directly (no protocol flag) the mode is
    # pmDefault; run through the parallel harness the binary is invoked
    # with ``--run`` so the mode is pmRunOne. Either way the body runs
    # and ordinary ``check`` assertions behave like std/unittest. (The
    # pmDefault → std/unittest delegation contract is verified
    # end-to-end against a dedicated fixture in
    # ``t_backward_compat_std_unittest_test_runs_unchanged``; asserting
    # this binary's OWN mode here would wrongly fail under the harness.)
    let mode = currentProtocolMode()
    check mode in {pmDefault, pmRunOne}
    check 1 + 1 == 2
