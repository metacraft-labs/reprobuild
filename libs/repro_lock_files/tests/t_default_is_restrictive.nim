## NLF-DIA-4 — a library that declares nothing errors.
##
## Named-Lock-Files NLF-M8. Corpus case **NLF-DIA-4**:
##
## > A library declaring **no** `multiVersion` property at all, reached at two
## > irreconcilable versions in one link. **Expect.** Error, identical in
## > shape to NLF-DIA-2.
##
## ## Why the corpus calls this the highest-value case in the group
##
## > Catches a permissive default — the inversion §9.3 argues against at
## > length. This is the highest-value case in the group, because a permissive
## > default fails *silently at runtime*: an ODR violation that links cleanly.
## > No other case in this corpus detects it, since every other case declares
## > the property explicitly.
##
## That is the whole reason for the `mvUnset` state existing separately from
## `mvForbidden` in the model. A two-valued property whose zero value WAS
## `forbidden` would pass this case and would have nothing to say in
## NLF-DIA-8, which asks where the answer came from. Silence and a written
## `forbidden` must be the same ANSWER and different FACTS.
##
## ## Paired with NLF-DIA-1
##
## The NLF-M8 exit criteria require both green together: NLF-DIA-1 says the
## check is not too strict, this one says it is not too permissive. This file
## therefore asserts the error fires AND that the same workspace with the
## versions reconcilable does not, so "errors" is not being satisfied by a
## check that fires on everything.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m8_fixture`'s header.

import std/[strutils, unittest]

import ./nlf_m8_fixture

const
  App = "app"
  LibImaging = "libimaging"
  LibReport = "libreport"
  LibFoo = "libfoo"
  Binary = "build/app"
  Published = ["1.0.0", "1.4.2", "1.9.0", "2.0.0", "2.5.0"]

proc workspace(reportRange: string): M8Recipe =
  ## `libfoo` declares NOTHING. That is the input under test; every other
  ## field is scaffolding.
  M8Recipe(
    packages: @[
      m8pkg(App, @["1.0.0"], @[m8dep(LibImaging, ">=3.0 <4.0"),
                               m8dep(LibReport, ">=0.9 <1.0")]),
      m8pkg(LibImaging, @["3.1.0"], @[m8dep(LibFoo, ">=2.0 <3.0")]),
      m8pkg(LibReport, @["0.9.4"], @[m8dep(LibFoo, reportRange)]),
      m8pkg(LibFoo, @Published)],
    artifacts: @[m8artifact(Binary, App)])

suite "NLF-DIA-4 the default is restrictive":

  setup:
    resetLockFileDeclarations()

  test "the library really did declare nothing":
    # The premise, asserted rather than assumed. A fixture that quietly
    # stamped `mvForbidden` would make everything below pass while testing
    # NLF-DIA-2 a second time.
    for p in workspace(">=1.4 <2.0").packages:
      if p.name == LibFoo:
        check p.multiVersion == mvUnset

  test "an undeclared library resolves to `forbidden`":
    let resolution = resolveMultiVersion(LibraryMultiVersion(
      library: LibFoo, declared: mvUnset, language: "c"))
    check resolution.policy == mvForbidden

  test "the co-linking error fires":
    let solved = solveDiamond(workspace(">=1.4 <2.0"))
    check solved.versionsReached(Binary, LibFoo).len == 2
    check solved.hasConflict(Binary, LibFoo)

  test "the error is identical in SHAPE to NLF-DIA-2's":
    let message = renderColinkingError(
      solveDiamond(workspace(">=1.4 <2.0")).conflictFor(Binary, LibFoo))
    checkpoint(message)
    check "cannot be linked at two versions into one binary" in message
    check (App & "  ->  " & LibImaging) in message
    check (App & "  ->  " & LibReport) in message
    check "unification was attempted" in message
    check "resolutions:" in message
    check "different lock files" in message

  test "and it does NOT fire when the two demands reconcile":
    # The other side. Without this, "errors" would be satisfiable by a check
    # that refuses every workspace containing an undeclared library, which is
    # every workspace.
    let solved = solveDiamond(workspace(">=2.0 <3.0"))
    for conflict in solved.conflicts:
      checkpoint(renderColinkingError(conflict))
    check solved.versionsReached(Binary, LibFoo).len == 1
    check solved.conflicts.len == 0
