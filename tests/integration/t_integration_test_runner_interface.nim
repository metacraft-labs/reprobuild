## Spec-Implementation M3 — ``TestRunner`` interface integration test.
##
## Asserts:
##   1. The default ``TestRunner`` is fully populated (``validate``
##      passes) and reports the canonical adapter identity name.
##   2. A custom ``TestRunner`` built via ``newTestRunner`` accepts
##      adapter-defined ``run`` / ``list`` / ``enumerate`` procs and
##      returns the values those procs produce.
##   3. The default runner's ``list`` and ``enumerate`` surface
##      degrades gracefully for an empty-path binary (returns empty
##      sequences rather than raising).

import std/unittest

import repro_dsl_stdlib/interfaces/test_runner

suite "Spec-Implementation M3: TestRunner interface":

  test "defaultTestRunner is fully populated":
    let runner = defaultTestRunner()
    validate(runner)
    check runner.name == "default-test-runner"
    check runner.run != nil
    check runner.list != nil
    check runner.enumerate != nil

  test "custom TestRunner routes the run/list/enumerate vtable":
    var ranWith = ""
    proc customRun(binary: TestBinary; filter: string): ExitCode =
      ranWith = binary.path & ":" & filter
      42
    proc customList(binary: TestBinary): seq[TestCase] =
      @[TestCase(qualifiedName: "suite.A", displayName: "A"),
        TestCase(qualifiedName: "suite.B", displayName: "B")]
    proc customEnumerate(binary: TestBinary): seq[QualifiedName] =
      @["suite.A", "suite.B"]
    let runner = newTestRunner(
      name = "custom",
      run = customRun,
      list = customList,
      enumerate = customEnumerate)
    validate(runner)
    let binary = TestBinary(path: "/tmp/x", metadata: "")
    check runner.run(binary, "filter-x") == 42
    check ranWith == "/tmp/x:filter-x"
    let cases = runner.list(binary)
    check cases.len == 2
    check cases[0].qualifiedName == "suite.A"
    check cases[1].displayName == "B"
    let names = runner.enumerate(binary)
    check names.len == 2
    check names[1] == "suite.B"

  test "default runner degrades gracefully for empty path":
    let runner = defaultTestRunner()
    let empty = TestBinary(path: "", metadata: "")
    let cases = runner.list(empty)
    check cases.len == 0
    let names = runner.enumerate(empty)
    check names.len == 0
    # ``run`` on an empty path returns the conventional ``-1`` rather
    # than raising — this is the documented graceful-degradation path.
    check runner.run(empty, "") == -1
