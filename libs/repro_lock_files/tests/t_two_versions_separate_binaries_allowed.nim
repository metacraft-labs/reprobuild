## NLF-DIA-1 — two versions of one library, two separate binaries, allowed.
##
## Named-Lock-Files NLF-M8. Corpus case **NLF-DIA-1**:
##
## > `appA` needs `libfoo 1.x`, `appB` needs `libfoo 2.x`. Two separate
## > executables, no shared link. `libfoo` declares `multiVersion forbidden`
## > (the default). **Expect.** Both build. Both versions of `libfoo` exist in
## > the store simultaneously. **No error.**
##
## ## What this catches, and why it is half of a pair
##
## "A check applied at *workspace* or *lock-file* granularity rather than at
## the link closure. Such an implementation refuses a completely legal
## workspace — the most likely over-strict failure, and one that would make
## the feature unusable in exactly the multi-application repositories it is
## aimed at."
##
## The exit criteria for NLF-M8 require this case and NLF-DIA-4 to be green
## **together**: one says the check is not too strict, the other says it is
## not too permissive, and either alone is satisfiable by a stub. So the
## assertions below are deliberately two-sided. It is not enough that no error
## was reported — a check that never fires would pass that. The workspace must
## also genuinely contain two versions, and `libfoo` must genuinely forbid
## co-linking, or the case would be asserting that a check declined to fire on
## input it had no reason to fire on.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m8_fixture`'s header, which states the policy in full. The solve
## below is real clingo through the real FFI.

import std/[unittest]

import ./nlf_m8_fixture

const
  AppA = "appA"
  AppB = "appB"
  LibFoo = "libfoo"
  BinA = "build/appA"
  BinB = "build/appB"
  Published = ["1.0.0", "1.4.2", "1.9.0", "2.0.0", "2.5.0"]

proc workspace(): M8Recipe =
  M8Recipe(
    packages: @[
      m8pkg(AppA, @["1.0.0"], @[m8dep(LibFoo, ">=1.0 <2.0")]),
      m8pkg(AppB, @["1.0.0"], @[m8dep(LibFoo, ">=2.0 <3.0")]),
      # The declaration is EXPLICIT rather than inherited, so this case
      # isolates the scope rule. NLF-DIA-4 covers the inherited default, and
      # keeping them apart is what lets a failure here be read as "scoped
      # wrong" rather than "resolved wrong".
      m8pkg(LibFoo, @Published, multiVersion = mvForbidden)],
    artifacts: @[m8artifact(BinA, AppA), m8artifact(BinB, AppB)])

suite "NLF-DIA-1 two versions, two separate binaries, allowed":

  setup:
    resetLockFileDeclarations()

  test "the workspace really does carry two versions of libfoo":
    # The premise. Without this the case could pass against an implementation
    # that unified the two apps onto one version — which would be a different
    # (and wrong) answer that happens to produce no error.
    let solved = solveDiamond(workspace())
    check solved.solvedVersionsOf(LibFoo).len == 2

  test "libfoo really does forbid co-linking":
    # The other half of the premise. A check that declined to fire because it
    # read the policy as `allowed` would pass the assertion below for the
    # wrong reason, and that is precisely the "passes for a reason unrelated
    # to what it claims" shape this campaign exists to catch.
    let resolution = resolveMultiVersion(LibraryMultiVersion(
      library: LibFoo, declared: mvForbidden, language: "c"))
    check resolution.policy == mvForbidden
    check not resolution.inherited

  test "neither binary links two versions":
    let solved = solveDiamond(workspace())
    check solved.versionsReached(BinA, LibFoo).len == 1
    check solved.versionsReached(BinB, LibFoo).len == 1
    # And they disagree, which is what makes this two instances rather than
    # one answer read twice.
    check solved.versionsReached(BinA, LibFoo) !=
      solved.versionsReached(BinB, LibFoo)

  test "no co-linking error is reported":
    let solved = solveDiamond(workspace())
    checkpoint("conflicts reported: " & $solved.conflicts.len)
    for conflict in solved.conflicts:
      checkpoint(renderColinkingError(conflict))
    check solved.conflicts.len == 0
    check not solved.hasConflict(BinA, LibFoo)
    check not solved.hasConflict(BinB, LibFoo)
