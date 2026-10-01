## ``skip("why")`` compiles, and skips, on the stock ``std/unittest`` as well as
## on the CodeTracer Nim fork's.
##
## The defect: the fork's ``skip`` takes a reason and stock Nim's does not, so
## a test calling ``skip("why")`` compiled only under the fork, and on Windows
## -- which builds with the stock compiler -- the whole file failed to compile
## (``t_bootstrap_nim_monitoring``, ``t_tarball_provisioning_cold_store_extractors``).
## ``repro_test_support/reasoned_skip`` supplies the reason-carrying form only
## where ``std/unittest`` lacks it.
##
## THIS FILE IS ITS OWN FIRST ASSERTION: before that module existed it did not
## compile under stock Nim. The cases below then check that the call is a real
## skip on whichever ``std/unittest`` is in use -- a template that compiled and
## did nothing would let a guarded test body run on as a pass -- and that the
## module took the arm its compiler calls for.
##
## No mocks. The verdict is read from ``std/unittest``'s own formatter
## callback, the same channel the console and JUnit formatters are driven by.

import std/[macros, unittest]
import repro_test_support/reasoned_skip

type StatusRecorder = ref object of OutputFormatter
  statuses: seq[(string, TestStatus)]

method testEnded*(formatter: StatusRecorder; testResult: TestResult) =
  formatter.statuses.add((testResult.testName, testResult.status))

let recorder = StatusRecorder()
# Registering any formatter suppresses the default console one, so it is
# registered explicitly: the run's own output is part of the evidence.
addOutputFormatter(defaultConsoleFormatter())
addOutputFormatter(recorder)

proc recordedStatus(name: string): seq[TestStatus] =
  for (testName, status) in recorder.statuses:
    if testName == name:
      result.add(status)

macro stdSkipParameterCount(): int =
  ## The parameter count of ``std/unittest``'s own ``skip``, asked
  ## independently of the module under test.
  let found = bindSym("skip", brOpen)
  var candidates: seq[NimNode] = @[]
  if found.kind == nnkSym:
    candidates.add(found)
  else:
    for child in found:
      candidates.add(child)
  var count = 0
  for candidate in candidates:
    let impl = candidate.getImpl
    # The module under test declares its ``skip`` generic; ``std/unittest``'s
    # (stock or fork) is not, which is how the two are told apart here.
    if impl.kind == nnkTemplateDef and impl[2].kind == nnkEmpty:
      count = impl.params.len - 1
  newLit(count)

suite "reasoned skip":
  test "a skip with a literal reason":
    skip("this case is skipped on purpose")

  test "a skip with a composed reason":
    skip("not on " & hostOS & "/" & hostCPU & " -- skipped on purpose")

  test "a bare skip still resolves to std/unittest's":
    skip()

  test "every case above was recorded as skipped, once":
    for name in ["a skip with a literal reason",
                 "a skip with a composed reason",
                 "a bare skip still resolves to std/unittest's"]:
      checkpoint(name)
      check recordedStatus(name) == @[TestStatus.SKIPPED]

  test "the module declares its skip only where std/unittest has none":
    check UnittestSkipTakesReason == (stdSkipParameterCount() == 1)
