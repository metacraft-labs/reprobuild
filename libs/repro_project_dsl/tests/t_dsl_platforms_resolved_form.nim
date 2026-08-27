## The canonical ``platforms <expr>`` form: the compiler resolves the entries,
## the macro never reads them as text.
##
## PMC-1 shipped ``platforms:`` as a colon block whose entries a macro walked
## with ``identText``. That shape has three defects at once, catalogued in
## ``DSL-Macro-Authoring-Guide.md`` (reprobuild-specs):
##
##   1. ``windows`` is not a symbol, so a typo is whatever the macro's own
##      validation happens to say rather than an undeclared-identifier error
##      with the compiler's caret;
##   2. ``[windows, linux]`` is also an ordinary Nim array expression, so the
##      same source has two readings and nothing in the language arbitrates
##      between them — which one applies depends on which macro is looking;
##   3. ``platforms someComputedSeq`` is impossible, because there is nothing
##      to evaluate an expression with at that point.
##
## The redesign makes the entries ordinary Nim: the ``package`` macro is
## staged, stage 1 wraps the author's expression in a scope where the platform
## vocabulary is bound as ``const``s and hands it to the compiler, and stage 2
## receives VALUES. This file pins the consequences that are observable at
## runtime; the compile-time diagnostics are pinned by
## ``tests/integration/t_platforms_form_diagnostics.nim``, which has to run
## the compiler to see them.
##
## Assertions:
##   1. ``platforms [windows]`` records the coordinate, and the ``##`` doc
##      comment above it becomes ``platformsMessage`` — no ``msg =`` slot.
##   2. ``platforms windows`` (no brackets) is the same declaration.
##   3. ``x86_64 * windows`` narrows to a ``<cpu>-<os>`` coordinate; ``*``
##      because the operation is set intersection.
##   4. A COMPUTED expression works with no second code path — the defect (3)
##      above, made into a passing test. The seq is built by a loop in a
##      ``const`` block, which a source-reading macro could never see through.
##   5. The legacy colon-block form with ``msg =`` still parses, so the
##      recipes that use it keep working.
##   6. The vocabulary does NOT leak: importing the DSL must not put a symbol
##      named ``windows`` into the importer's namespace. Block-scoping is the
##      whole reason the consts are injected by a template instead of being
##      exported, and without this assertion the design could silently
##      regress to module-level consts and every test here would still pass.

import std/[unittest]

import repro_project_dsl

# ---------------------------------------------------------------------------
# (6) The vocabulary is not in scope at module level. This has to be checked
# BEFORE any package block, because a leak would make every `windows` below
# resolve for the wrong reason.
# ---------------------------------------------------------------------------
static:
  doAssert not declared(windows),
    "the platform vocabulary leaked into module scope: `import " &
    "repro_project_dsl` must not bind `windows`"
  doAssert not declared(aarch64),
    "the platform vocabulary leaked into module scope: `import " &
    "repro_project_dsl` must not bind `aarch64`"

# (4) Built by a loop, in a const, outside any package block. Nothing about
# this seq is visible in the source of the `platforms` line that uses it.
const DesktopTargets = withPlatformVocabulary(block:
  var acc: seq[PlatformConstraint] = @[]
  for os in [windows, linux, macos]:
    acc.add(x86_64 * os)
  acc)

package platformsCanonical:
  ## Windows only, and this sentence is the reason a reader gets when
  ## resolution refuses the package.
  platforms [windows]

package platformsBareSingle:
  platforms windows

package platformsPairs:
  platforms [x86_64 * windows, aarch64 * windows]

package platformsComputed:
  platforms DesktopTargets

package platformsLegacyBlock:
  platforms:
    [linux]
    msg = "kept working on purpose"

proc declOf(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

proc coordinates(pkg: PackageDef): seq[string] =
  for c in pkg.declaredPlatforms:
    result.add(c.cpu & "-" & c.os)

suite "the canonical platforms form is resolved by the compiler":

  test "doc comment is the message, and the coordinate is recorded":
    let pkg = declOf("platformsCanonical")
    check pkg.platformsDeclared
    check pkg.coordinates == @["any-windows"]
    # The `##` comment above the declaration, verbatim -- joined across its
    # two source lines. A `msg =` slot would have been a second mechanism for
    # a job Nim's own doc comments already do.
    check pkg.platformsMessage ==
      "Windows only, and this sentence is the reason a reader gets when\n" &
      "resolution refuses the package."

  test "the bracket is optional for a single platform":
    let pkg = declOf("platformsBareSingle")
    check pkg.platformsDeclared
    check pkg.coordinates == @["any-windows"]
    # No doc comment above it, so no message -- absence must not become an
    # empty-string-shaped surprise elsewhere.
    check pkg.platformsMessage == ""

  test "`*` narrows a CPU family by an OS":
    let pkg = declOf("platformsPairs")
    check pkg.coordinates == @["x86_64-windows", "aarch64-windows"]

  test "a computed seq needs no second code path":
    # This is the assertion the single-stage design could not make. The macro
    # sees a value; where the value came from is not its business.
    let pkg = declOf("platformsComputed")
    check pkg.platformsDeclared
    check pkg.coordinates ==
      @["x86_64-windows", "x86_64-linux", "x86_64-macos"]

  test "the legacy colon block with msg = still parses":
    let pkg = declOf("platformsLegacyBlock")
    check pkg.platformsDeclared
    check pkg.coordinates == @["any-linux"]
    check pkg.platformsMessage == "kept working on purpose"

  test "source locations survive the staging":
    # Stage 1 leaves the `platforms` statement in the body precisely so stage
    # 2 can still point diagnostics at the author's line. If it ever stops
    # doing that, the coordinates arrive with no location and every message
    # this milestone produces starts pointing at the macro instead.
    let pkg = declOf("platformsCanonical")
    check pkg.declaredPlatforms[0].sourceFile.len > 0
    check pkg.declaredPlatforms[0].sourceLine > 0
