## ``skip(reason)`` on every ``std/unittest`` this suite is compiled with.
##
## THE TWO UNITTESTS. On Linux and macOS the suite is built with the
## CodeTracer Nim fork (``scripts/run_tests.sh`` refuses any other compiler
## there), whose ``std/unittest`` declares ``template skip*(reason = "")`` and
## writes the reason into the protocol result document as ``skipReason``.
## Windows has no flake dev shell and builds with the stock compiler the dev
## environment provisions, whose ``std/unittest`` declares only
## ``template skip*()``. A test that calls ``skip("why")`` against stock
## ``std/unittest`` does not compile at all:
##
##   Error: type mismatch ... Expected one of: template skip() -- extra argument given
##
## so on Windows every case in such a file is lost, not only the skipped one.
##
## THE REASON IS NOT OPTIONAL, which is why the cure is not ``skip()``.
## ``scripts/check_bare_skips.py`` refuses a new bare skip, because a suite run
## is recorded as complete only when every skip says why. Dropping the reason
## to compile on Windows would trade one defect for another.
##
## WHAT THIS MODULE DOES. Import it beside ``std/unittest``. Where the active
## ``std/unittest`` already accepts a reason (the fork), it declares NOTHING:
## the fork's template is the one every call resolves to, so the protocol's
## ``skipReason`` is untouched. Where it does not (stock), it declares a
## ``skip`` that takes the reason, prints it on the test's own output, and
## then delegates to the stock ``skip()`` for the status change -- the stock
## unittest has no protocol document to carry the reason, so the output is the
## only place it can go.
##
## The decision is made on the SIGNATURE of the ``skip`` that ``std/unittest``
## exports, not on a compiler version or a fork-only symbol: the property this
## module exists for is "does that template take an argument", so that is what
## is asked.
##
## WHY A GENERIC PARAMETER. The stock template has no parameter and the
## ``ct_test_unittest_parallel`` shim's has a defaulted one. A file that
## imports both the shim and this module would otherwise see two equally good
## matches for ``skip("why")``. A generic match ranks below a concrete one, so
## the shim's template wins that tie and this one only ever fills the gap.

# Under the fork this module declares nothing a caller uses, and every test
# that imports it would otherwise warn ``imported and not used``.
{.used.}

import std/[macros, unittest]

macro unittestSkipTakesReason(): bool =
  ## ``true`` when ``std/unittest``'s exported ``skip`` declares a parameter.
  let found = bindSym("skip", brOpen)
  var candidates: seq[NimNode] = @[]
  if found.kind == nnkSym:
    candidates.add(found)
  else:
    for child in found:
      candidates.add(child)
  var takesReason = false
  for candidate in candidates:
    let impl = candidate.getImpl
    if impl.kind == nnkTemplateDef and impl.params.len > 1:
      takesReason = true
  newLit(takesReason)

const UnittestSkipTakesReason* = unittestSkipTakesReason()
  ## Exported so a test can assert which arm its compiler took, rather than
  ## a reader having to infer it.

when not UnittestSkipTakesReason:
  template skip*[T: string](reason: T) =
    ## Stock ``std/unittest``: say why, then skip.
    echo "    [SKIPPED] ", reason
    unittest.skip()
