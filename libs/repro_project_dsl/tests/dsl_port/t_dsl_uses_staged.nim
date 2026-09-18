## A dependency block's `when`s are resolved by the COMPILER.
##
## `uses:` / `buildDeps:` / `nativeBuildDeps:` / `runtimeDeps:` are staged the
## way `DSL-Macro-Authoring-Guide.md` prescribes and `platforms` /
## `defaultToolProvisioning` already are: stage 1 lowers the block into an
## ordinary Nim expression that builds the list, stage 2 receives the entries
## through a `static seq[PackageUseDef]` parameter. Each `when` is copied into
## that expression with its condition untouched, so which branch contributes is
## Nim's answer.
##
## What this replaces is the reason the test exists. `collectUsesGated` used to
## decide the branch itself, from `compileTimeConditionValue` -- a hand-written
## evaluator that modelled `true`/`false`, `defined()`, `not`, `and`, `or` and
## nothing else. Everything else in Nim's condition grammar evaluated to
## `false`, and the predicate returned a plain `bool`, so "this condition is
## false" and "I do not understand this condition" were the same answer. A
## dependency behind a condition it did not model was therefore DROPPED from
## the dependency floor -- no error, no warning -- and with an `else:` present
## the block recorded the opposite of what the author wrote.
##
## Every fixture below whose name starts `ctf` (compiler-the-folder) is a
## condition the old evaluator could not model. Run this suite against the
## pre-staging macro and they fail: the entries are missing, and
## `ctfElseChain` records `"else-branch-tool"` where the source says
## `"then-branch-tool"`.

import std/unittest

import repro_project_dsl

const FixtureLevel = 3
  ## A `const` comparison: `when FixtureLevel == 3` is the guide's own example
  ## of a condition the hand-rolled evaluator answered `false` to.

const FixtureConstraint = "computed-constraint >=1.0"
  ## A constraint named rather than spelled, for the checklist's "does
  ## `form someComputedValue` work, without a second code path?".

func fixtureWantsExtras(): bool = FixtureLevel >= 2
  ## A call to a `func` -- also outside the old grammar.

# ---------------------------------------------------------------------------
# Conditions the predecessor could not model.
# ---------------------------------------------------------------------------

package ctfConstComparison:
  uses:
    "unconditional-tool"
    when FixtureLevel == 3:
      "const-comparison-tool"
    when FixtureLevel == 99:
      "unreachable-tool"
    when declared(FixtureConstraint):
      "declared-tool"
    when compiles(FixtureLevel + 1):
      "compiles-tool"
    when fixtureWantsExtras():
      "func-call-tool"
  build:
    discard

package ctfElseChain:
  ## The worst of the old failure modes, and the one that is not a dropped
  ## entry but a wrong one: an unmodelled condition was `false`, so the `else`
  ## was taken and the recipe recorded the opposite of what it says.
  uses:
    when FixtureLevel == 3:
      "then-branch-tool"
    else:
      "else-branch-tool"
  build:
    discard

package ctfElifChain:
  uses:
    when FixtureLevel == 1:
      "level-one-tool"
    elif FixtureLevel == 3:
      "level-three-tool"
    else:
      "fallback-tool"
  build:
    discard

package ctfNestedWhen:
  uses:
    when FixtureLevel >= 2:
      "outer-tool"
      when FixtureLevel == 3:
        "inner-tool"
  build:
    discard

package ctfComputedConstraint:
  ## Not a `when` at all: the entry itself is an expression. Stage 2 cannot
  ## tell it from a literal, which is the property staging is for.
  uses:
    FixtureConstraint
    "literal-constraint >=2.0"
  build:
    discard

package ctfAcrossBlocks:
  ## The same treatment for the other three spellings, each keeping its own
  ## list -- NLF-M7 §4.6's distinction must survive the restaging.
  buildDeps:
    when FixtureLevel == 3:
      "build-dep-tool"
  nativeBuildDeps:
    when FixtureLevel == 3:
      "native-dep-tool"
    "native-always-tool"
  runtimeDeps:
    when FixtureLevel == 3:
      "runtime-dep-tool"
  build:
    discard

# ---------------------------------------------------------------------------
# The shapes the shipped recipes write. These worked before and must work
# identically: `codetracer-cairo-recorder`, `codetracer-evm-recorder` and five
# more sibling recorders gate `gcc` / `clang` / `pkg-config` / `openssl` on
# exactly this.
# ---------------------------------------------------------------------------

package hostGatedPkg:
  uses:
    "portable-tool"
    when defined(linux):
      "gcc"
    when defined(macosx):
      "clang"
    when not defined(windows):
      "pkg-config"
      "openssl"
  build:
    discard

package emptyDepsPkg:
  ## The ~250 recipes whose dependency block is a bare `discard`.
  buildDeps:
    discard
  build:
    discard

package noDepsPkg:
  build:
    discard

# ---------------------------------------------------------------------------
# Structure the walk still owns: an `if` / `case` on a VARIANT is not a
# compile-time question -- the solver answers it -- so those arms keep
# lowering to gate metadata rather than to a Nim conditional.
# ---------------------------------------------------------------------------

package variantGatedPkg:
  config:
    compiler: variant string = "gcc"
  uses:
    case compiler.value:
    of "gcc": "gcc >=12 <16"
    of "clang": "clang >=16 <19"
  build:
    discard

proc usesOf(packageName: string): seq[PackageUseDef] =
  for pkg in registeredPackages():
    if pkg.packageName == packageName:
      return pkg.toolUses
  @[]

proc nativeOf(packageName: string): seq[PackageUseDef] =
  for pkg in registeredPackages():
    if pkg.packageName == packageName:
      return pkg.nativeBuildDeps
  @[]

proc runtimeOf(packageName: string): seq[PackageUseDef] =
  for pkg in registeredPackages():
    if pkg.packageName == packageName:
      return pkg.runtimeDeps
  @[]

proc constraints(entries: seq[PackageUseDef]): seq[string] =
  for entry in entries:
    result.add(entry.rawConstraint)

proc isRegistered(packageName: string): bool =
  for pkg in registeredPackages():
    if pkg.packageName == packageName:
      return true
  false

suite "uses: conditions are evaluated by the compiler":

  test "every fixture package registered":
    # Without this, a lookup typo would return an empty seq and the
    # emptiness checks below would pass against nothing at all.
    for name in ["ctfConstComparison", "ctfElseChain", "ctfElifChain",
                 "ctfNestedWhen", "ctfComputedConstraint", "ctfAcrossBlocks",
                 "hostGatedPkg", "emptyDepsPkg", "noDepsPkg",
                 "variantGatedPkg"]:
      check isRegistered(name)

  test "a const comparison selects its branch":
    # `when FixtureLevel == 3:` -- the guide's example of the gap. The old
    # evaluator answered `false` and the entry vanished.
    let got = constraints(usesOf("ctfConstComparison"))
    check "const-comparison-tool" in got
    check "unreachable-tool" notin got

  test "declared(), compiles() and a func call select their branches":
    let got = constraints(usesOf("ctfConstComparison"))
    check "declared-tool" in got
    check "compiles-tool" in got
    check "func-call-tool" in got

  test "the unconditional entries are still there, in source order":
    check constraints(usesOf("ctfConstComparison")) ==
      @["unconditional-tool", "const-comparison-tool", "declared-tool",
        "compiles-tool", "func-call-tool"]

  test "an else arm is not taken when the then arm is true":
    # The old behaviour was not a missing entry but a WRONG one: the
    # unmodelled condition was false, so this recorded "else-branch-tool".
    check constraints(usesOf("ctfElseChain")) == @["then-branch-tool"]

  test "an elif cascade picks the branch Nim picks":
    check constraints(usesOf("ctfElifChain")) == @["level-three-tool"]

  test "a when nested inside a when contributes both levels":
    check constraints(usesOf("ctfNestedWhen")) == @["outer-tool", "inner-tool"]

  test "an entry may be an expression rather than a literal":
    check constraints(usesOf("ctfComputedConstraint")) ==
      @[FixtureConstraint, "literal-constraint >=2.0"]

  test "each block keeps its own list and its own depKind":
    check constraints(usesOf("ctfAcrossBlocks")) == @["build-dep-tool"]
    check constraints(nativeOf("ctfAcrossBlocks")) ==
      @["native-dep-tool", "native-always-tool"]
    check constraints(runtimeOf("ctfAcrossBlocks")) == @["runtime-dep-tool"]
    for entry in usesOf("ctfAcrossBlocks"):
      check entry.depKind == "target"
    for entry in nativeOf("ctfAcrossBlocks"):
      check entry.depKind == "native"
    for entry in runtimeOf("ctfAcrossBlocks"):
      check entry.depKind == "runtime"

suite "the shipped recipe shapes are unchanged":

  test "defined() gating still selects per host":
    let got = constraints(usesOf("hostGatedPkg"))
    check "portable-tool" in got
    when defined(linux):
      check "gcc" in got
      check "clang" notin got
      check "pkg-config" in got
      check "openssl" in got
    elif defined(macosx):
      check "clang" in got
      check "gcc" notin got
      check "pkg-config" in got
      check "openssl" in got
    else:
      check "gcc" notin got
      check "clang" notin got
      check "pkg-config" notin got
      check "openssl" notin got

  test "a block containing only discard declares nothing":
    check usesOf("emptyDepsPkg").len == 0

  test "a package with no dependency block declares nothing":
    check usesOf("noDepsPkg").len == 0
    check nativeOf("noDepsPkg").len == 0
    check runtimeOf("noDepsPkg").len == 0

  test "entries still point at the author's line":
    # Staging is not paid for with diagnostics: the constraint node is still
    # here at macro time, so the recorded location is the author's own -- each
    # entry on its own line, in the order they were written.
    let got = usesOf("hostGatedPkg")
    check got.len >= 1
    var previousLine = 0
    for entry in got:
      check entry.sourceFile.len > 0
      check entry.sourceLine > previousLine
      previousLine = entry.sourceLine

  test "the selector is the first token of the constraint":
    for entry in usesOf("ctfComputedConstraint"):
      check entry.packageSelector == entry.executableName
    check usesOf("ctfComputedConstraint")[0].packageSelector ==
      "computed-constraint"

suite "a variant arm is still a gate, not a compile-time branch":

  test "case <variant>.value: arms lower to per-value gates":
    # A variant's value is decided by the SOLVER; there is no compile-time
    # answer, so this must NOT become a Nim `case`. Both arms contribute,
    # each carrying the gate that activates it.
    let got = usesOf("variantGatedPkg")
    check got.len == 2
    check got[0].rawConstraint == "gcc >=12 <16"
    check got[0].gateVariant == "compiler"
    check got[0].gateValue == "gcc"
    check got[1].rawConstraint == "clang >=16 <19"
    check got[1].gateVariant == "compiler"
    check got[1].gateValue == "clang"

suite "the staging machinery stays out of the consumer's namespace":

  test "importing the DSL binds neither helper":
    # The guide requires this assertion by name: the emitted code reaches
    # `usesEntryDef` through `bindSym`, which binds the symbol rather than
    # looking a name up at the expansion site, so neither it nor its helpers
    # need to be exported. Without the check the design silently regresses to
    # module-level exports and nothing notices.
    check not declared(usesEntryDef)
    check not declared(usesConstraintSelector)
    # NoPackageUses is a stage-1 sentinel, not vocabulary: stage 1 `bindSym`s it
  # as the default for a package with no dependency block, so it must be
  # module-level and exported -- exactly as NoPlatformConstraints already is.
  # The guide's non-leak rule covers the VOCABULARY an author writes
  # (`windows`, `tarball`), which is what would collide in a consumer's
  # namespace. A sentinel the author never names does not.
  check declared(NoPackageUses)
