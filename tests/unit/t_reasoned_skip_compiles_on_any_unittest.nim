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
## compile under stock Nim. Each skipping case then checks, after the call,
## that its own status really is SKIPPED -- a ``skip`` that compiled and did
## nothing would leave it OK and let a guarded body run on as a pass, and that
## check turns it into a FAILURE instead. Each case verifies itself rather
## than a later case collecting the others, because the protocol runner
## executes cases one per process (``--run suite::test``).
##
## The intended outcome of the two skipping cases is therefore [SKIPPED], each
## with its reason; a FAILED there is the defect.
##
## No mocks: the status read is ``std/unittest``'s own per-test status.

import std/[macros, unittest]
import repro_test_support/reasoned_skip

template currentTestStatus(): TestStatus {.dirty.} =
  ## The running case's status, as ``std/unittest`` holds it: a variable in
  ## the stock template, a pointer in the fork's.
  when typeof(testStatusIMPL) is ptr TestStatus:
    testStatusIMPL[]
  else:
    testStatusIMPL

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
  test "a skip with a literal reason is a real skip":
    skip("this case is skipped on purpose")
    check currentTestStatus() == TestStatus.SKIPPED

  test "a skip with a composed reason is a real skip":
    skip("not on " & hostOS & "/" & hostCPU & " -- skipped on purpose")
    check currentTestStatus() == TestStatus.SKIPPED

  test "the module declares its skip only where std/unittest has none":
    check UnittestSkipTakesReason == (stdSkipParameterCount() == 1)
