## NLF-DIA-5 — a generated source crossing a lock-file boundary is never
## refused, however violently the two graphs disagree.
##
## Named-Lock-Files NLF-M8. Corpus case **NLF-DIA-5**:
##
## > `tablegen` built under `hostTools` emits a `.c` file; `app` under
## > `targetRuntime` compiles it. The two lock files disagree on several
## > packages, including one that `multiVersion forbidden` would refuse if
## > linked. **Expect.** Builds. No error, no annotation required anywhere in
## > either recipe.
##
## ## Why this is the canonical motivating case
##
## > Catches a check applied to *any* cross-lock-file edge rather than to
## > linkage specifically. This is the canonical motivating case of the whole
## > design (§4.3); an implementation that refuses it has inverted the
## > feature's purpose while still passing NLF-DIA-2.
##
## §9.2 case 1 states the rule: "An edge under lock file B consumes the
## *output file* of an edge under A: a generated source, a data table, a tool
## that is executed. No ABI is shared; the artifact is bytes."
##
## The distinction is carried entirely by which of §4.6's three dependency
## lists the edge was written in. `tablegen` is a `nativeBuildDeps:` entry —
## a BUILD-platform tool — so it resolves under `hostTools` and the link-
## closure walk does not follow it. `libfoo` is a `uses:` entry and is
## followed. **No new syntax appears in this recipe**, which is §4.3's claim
## and is asserted below directly: the recipe designates one lock file at one
## artifact and says nothing about the crossing.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m8_fixture`'s header.

import std/[unittest]

import ./nlf_m8_fixture

const
  App = "app"
  Tablegen = "tablegen"
  LibFoo = "libfoo"
  Binary = "build/app"
  TargetRuntime = "targetRuntime"
  Published = ["1.0.0", "1.4.2", "1.9.0", "2.0.0", "2.5.0"]

proc workspace(): M8Recipe =
  M8Recipe(
    packages: @[
      # `tablegen` is a nativeBuildDeps: entry — a tool that RUNS on the
      # build machine and whose output `app` consumes as bytes. `libfoo` is a
      # uses: entry — linked.
      m8pkg(App, @["1.0.0"], @[m8dep(Tablegen, ">=1.0", dpNative),
                               m8dep(LibFoo, ">=1.4 <2.0")]),
      # And the host tool links a version of `libfoo` that the shipped binary
      # could not possibly co-link with.
      m8pkg(Tablegen, @["1.0.0"], @[m8dep(LibFoo, ">=2.0 <3.0")]),
      m8pkg(LibFoo, @Published, multiVersion = mvForbidden)],
    artifacts: @[m8artifact(Binary, App, TargetRuntime)])

suite "NLF-DIA-5 opaque artifact consumption is never refused":

  setup:
    resetLockFileDeclarations()
    discard declareLockFile(TargetRuntime,
      description = "Everything we ship.")

  test "the two lock files really do disagree about libfoo":
    # The premise. If they agreed, the case would be asserting that a check
    # declined to fire on input that gave it no reason to.
    let solved = solveDiamond(workspace())
    check solved.solvedVersionsOf(LibFoo).len == 2

  test "and libfoo really would refuse the co-link":
    let resolution = resolveMultiVersion(LibraryMultiVersion(
      library: LibFoo, declared: mvForbidden, language: "c"))
    check resolution.policy == mvForbidden

  test "the shipped binary's link closure reaches ONE version":
    # The `nativeBuildDeps:` edge is not a link. `tablegen`'s own `libfoo` is
    # in the workspace, in another lock file, and not in this binary.
    let solved = solveDiamond(workspace())
    check solved.versionsReached(Binary, LibFoo).len == 1
    # The host tool is not reached at all through link edges.
    check solved.versionsReached(Binary, Tablegen).len == 0

  test "nothing is refused":
    let solved = solveDiamond(workspace())
    for conflict in solved.conflicts:
      checkpoint(renderColinkingError(conflict))
    check solved.conflicts.len == 0

  test "and the recipe contains no cross-lock-file annotation":
    # §4.3: "the example above contains no cross-lock syntax at all." The
    # recipe designates ONE lock file, at ONE artifact, and nothing else in
    # it mentions lock files — including `libfoo`, which is instantiated
    # under both.
    let r = workspace()
    var designations = 0
    for a in r.artifacts:
      if a.lockFile.len > 0: inc designations
    check designations == 1
    for p in r.packages:
      check p.pinnedLockFile.len == 0
