## The production walkers must tolerate stack mappings becoming unreadable
## after their maps snapshot. Real page protection and unmapping reproduce the
## race deterministically; positive controls retain nested signal-frame and
## complete frame-chain detection. Modes 10 and 11 park a thread, with real
## signals, inside the sigreturn trampoline it entered by returning from an
## application handler, and require that frame's saved PC to be reported and
## adjustable: the HLX-M4 gate's tier-2 fault at window+3 under host load.
## allowed_mocks: none.
import std/[osproc, strutils, unittest]
when defined(linux) and defined(amd64):
  import m4_fixture
  from repro_test_support import graphArtifactPath, requireBinary
  suite "integration_hcr_linux_stack_mapping_changes_do_not_fault":
    test "stale readable ranges never license a faulting stack load":
      let binary = requireBinary(graphArtifactPath(
        "build/test-fixtures/hcr-linux-stack-access/stack-access"),
        "reprobuild.test_fixtures.hcr_linux_stack_access")
      for mode in [1, 2, 3, 4, 5, 6, 7, 8, 10, 11]:
        let run = execCmdEx(shellCommand(@[binary, $mode]))
        checkpoint("stack access mode " & $mode & ": " & run.output)
        check run.exitCode == 0
        check run.output.strip() == "stack-access-ok"
      var childFailure = ""
      try:
        discard runFixture(binary, ["9"])
      except IOError as err:
        childFailure = err.msg
      check "exited 139 (signal 11)" in childFailure
      check "no valid JSON result" in childFailure
