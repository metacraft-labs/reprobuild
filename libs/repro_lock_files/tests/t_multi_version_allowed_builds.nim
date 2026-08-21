## NLF-DIA-3 — the same link, the same two versions, and `multiVersion
## allowed`: it builds.
##
## Named-Lock-Files NLF-M8. Corpus case **NLF-DIA-3**:
##
## > As NLF-DIA-2, but `libfoo` declares `multiVersion allowed`. **Expect.**
## > Builds. Both versions present in the link. No error, no warning.
##
## ## Why this case exists alongside NLF-DIA-2
##
## > Catches the property being parsed but not consumed — a plausible partial
## > implementation that reads `multiVersion` into the model and never reaches
## > it from the solver. Note this case fails *loudly* under that defect,
## > which is why it is worth having alongside NLF-DIA-2: the pair
## > distinguishes "property ignored" from "property inverted".
##
## The workspace below is byte-for-byte NLF-DIA-2's except for the one
## `multiVersion` token, and that is deliberate: if anything else differed,
## a disagreement between the two cases could be attributed to the difference
## rather than to the property.
##
## ## "No error, no warning" — and yet a split report
##
## The corpus says no error and no warning. It does NOT say no report, and
## NLF-DIA-7 requires the split to be visible. The two are consistent because
## they are different things: the ERROR is a refusal, the REPORT is
## observability. `multiVersion allowed` withdraws the objection; it does not
## make the second copy of the library stop existing, and §8's argument that
## trimming is not needed at v1 depends on explosion being visible. So this
## case asserts on the absence of a CONFLICT and NLF-DIA-7 asserts on the
## presence of a REPORT, over the same shape.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m8_fixture`'s header.

import std/[unittest]

import ./nlf_m8_fixture

const
  App = "app"
  LibImaging = "libimaging"
  LibReport = "libreport"
  LibFoo = "libfoo"
  Binary = "build/app"
  Published = ["1.0.0", "1.4.2", "1.9.0", "2.0.0", "2.5.0"]

proc workspace(policy: MultiVersionPolicy): M8Recipe =
  M8Recipe(
    packages: @[
      m8pkg(App, @["1.0.0"], @[m8dep(LibImaging, ">=3.0 <4.0"),
                               m8dep(LibReport, ">=0.9 <1.0")]),
      m8pkg(LibImaging, @["3.1.0"], @[m8dep(LibFoo, ">=2.0 <3.0")]),
      m8pkg(LibReport, @["0.9.4"], @[m8dep(LibFoo, ">=1.4 <2.0")]),
      m8pkg(LibFoo, @Published, multiVersion = policy)],
    artifacts: @[m8artifact(Binary, App)])

suite "NLF-DIA-3 two versions in one link, permitted, allowed":

  setup:
    resetLockFileDeclarations()

  test "both versions are present in the one link":
    let solved = solveDiamond(workspace(mvAllowed))
    check solved.versionsReached(Binary, LibFoo).len == 2

  test "no co-linking error is reported":
    let solved = solveDiamond(workspace(mvAllowed))
    for conflict in solved.conflicts:
      checkpoint(renderColinkingError(conflict))
    check solved.conflicts.len == 0

  test "the CONTROL: the same workspace with `forbidden` does error":
    # This is what makes the assertion above an assertion about the property
    # rather than about the check being absent. The only difference between
    # the two solves is the token; if both were silent, the property would be
    # parsed and never consumed, which is exactly the defect the corpus names.
    let allowed = solveDiamond(workspace(mvAllowed))
    let forbidden = solveDiamond(workspace(mvForbidden))
    check allowed.conflicts.len == 0
    check forbidden.conflicts.len == 1
    check forbidden.hasConflict(Binary, LibFoo)
    # And the two solves agree about the SHAPE of the graph, so the
    # difference above cannot be attributed to one of them having solved
    # something else.
    check allowed.versionsReached(Binary, LibFoo) ==
      forbidden.versionsReached(Binary, LibFoo)
