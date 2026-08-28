## NLF-DIA-2 — two versions in one link, forbidden, and a diagnostic that says
## every one of the things §9.4 requires it to say.
##
## Named-Lock-Files NLF-M8. Corpus case **NLF-DIA-2**:
##
## > One executable `app` whose closure reaches `libfoo 2.0.0` via
## > `libimaging` and `libfoo 1.4.2` via `libreport`. Constraints genuinely
## > irreconcilable (`>=2.0 <3.0` and `>=1.4 <2.0`). `libfoo` declares
## > `multiVersion forbidden`. **Expect.** Build fails. The diagnostic names
## > **both versions**, **both dependency paths**, the file:line of `libfoo`'s
## > `multiVersion` declaration, and states that unification was attempted and
## > why it failed.
##
## ## Why each element is asserted SEPARATELY
##
## The corpus is explicit that a non-zero exit is not the assertion:
##
## > Catches three separately plausible defects, and the case should assert on
## > each element rather than merely on non-zero exit:
## >   1. a bare unsat report ("no solution found") …
## >   2. an error naming the *packages* but not the *paths* …
## >   3. no mention that unification was attempted …
##
## Each of the three has its own `test` block below, so a regression in one
## cannot be masked by the other two. A single `check "libfoo" in message`
## would pass under all three defects at once.
##
## ## Paired with NLF-DIA-3
##
## `t_multi_version_allowed_builds` runs the SAME workspace with `libfoo`
## declaring `multiVersion allowed`. The pair distinguishes "property ignored"
## from "property inverted": an implementation that never reads the property
## fails DIA-3 and passes this one; an implementation that reads it backwards
## fails this one and passes DIA-3.
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
  DeclFile = "packages/libfoo/repro.nim"
  DeclLine = 14
  Published = ["1.0.0", "1.4.2", "1.9.0", "2.0.0", "2.5.0"]

proc workspace(): M8Recipe =
  M8Recipe(
    packages: @[
      m8pkg(App, @["1.0.0"], @[m8dep(LibImaging, ">=3.0 <4.0"),
                               m8dep(LibReport, ">=0.9 <1.0")]),
      m8pkg(LibImaging, @["3.1.0"], @[m8dep(LibFoo, ">=2.0 <3.0")]),
      m8pkg(LibReport, @["0.9.4"], @[m8dep(LibFoo, ">=1.4 <2.0")]),
      m8pkg(LibFoo, @Published, multiVersion = mvForbidden,
        sourceFile = DeclFile, sourceLine = DeclLine)],
    artifacts: @[m8artifact(Binary, App)])

proc diagnostic(): string =
  let solved = solveDiamond(workspace())
  renderColinkingError(solved.conflictFor(Binary, LibFoo))

suite "NLF-DIA-2 two versions in one link, forbidden, clear error":

  setup:
    resetLockFileDeclarations()

  test "the solve SPLITS rather than reporting a bare unsat":
    # Corpus defect (1), and the one an ASP solver produces by default if
    # nobody does the work. §9.4: "the solver MUST NOT report a bare unsat".
    # Before NLF-M8 this workspace had one `package_chosen/2` for `libfoo` and
    # two irreconcilable range constraints on it, so `solve` raised
    # `EUnsatisfiable` and there was nothing to diagnose.
    var raised = ""
    var solved: M8Solved
    try:
      solved = solveDiamond(workspace())
    except CatchableError as err:
      raised = err.msg
    checkpoint("solve raised: " & raised)
    check raised.len == 0
    check solved.solvedVersionsOf(LibFoo).len == 2

  test "one binary reaches BOTH versions and a conflict is reported":
    let solved = solveDiamond(workspace())
    check solved.versionsReached(Binary, LibFoo).len == 2
    check solved.hasConflict(Binary, LibFoo)

  test "the diagnostic names BOTH versions":
    let solved = solveDiamond(workspace())
    let versions = solved.versionsReached(Binary, LibFoo)
    let message = renderColinkingError(solved.conflictFor(Binary, LibFoo))
    checkpoint(message)
    check versions.len == 2
    for v in versions:
      check (LibFoo & " " & v) in message

  test "the diagnostic names BOTH dependency PATHS, not just the packages":
    # Corpus defect (2). §9.4: "'Two things want different `libfoo`' is not
    # actionable; '`app -> libimaging -> libfoo`' tells the author which
    # dependency to move."
    #
    # Asserting on the full arrow-joined path rather than on the presence of
    # the intermediate NAMES is the point: an error that merely listed
    # `libimaging` and `libreport` somewhere in its text would pass a
    # substring check for each name while telling the author nothing about
    # which chain to break.
    let message = diagnostic()
    checkpoint(message)
    check (App & "  ->  " & LibImaging) in message
    check (App & "  ->  " & LibReport) in message
    check ("->  " & LibFoo & " >=2.0 <3.0") in message
    check ("->  " & LibFoo & " >=1.4 <2.0") in message

  test "the diagnostic cites the declaration's file:line":
    let message = diagnostic()
    checkpoint(message)
    check (DeclFile & ":" & $DeclLine) in message
    check "multiVersion forbidden" in message

  test "the diagnostic states that unification was ATTEMPTED, and why it failed":
    # Corpus defect (3). §9.4: "Under §9.1 a co-linkage error means the solver
    # already tried and could not; a reader who does not know that will
    # reasonably assume the tool simply refused."
    let message = diagnostic()
    checkpoint(message)
    check "unification was attempted" in message
    check "no version satisfies both" in message
    check "`>=1.4 <2.0`" in message
    check "`>=2.0 <3.0`" in message

  test "the resolutions block offers all THREE remedies":
    # §9.4: "the block should carry three kinds of remedy, not two: relax a
    # constraint, declare `multiVersion allowed` if it is genuinely safe, or
    # **separate the consumers into different lock files**". The third is the
    # one an implementation drops, and dropping it "hides the feature at the
    # exact moment it would help".
    let message = diagnostic()
    checkpoint(message)
    check "resolutions:" in message
    check "relax one constraint" in message
    check "multiVersion allowed" in message
    check "different lock files" in message
