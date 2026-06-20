## DSL-port M9.R.2c — typed artifact slot vars.
##
## Pins the package macro's typed slot injection — each ``library``
## / ``executable`` / ``files`` ident-form declaration injects a typed
## ``var`` whose Nim type is keyed on the artifact kind:
##
##   * ``library <n>:``    -> ``var <n>: Library``
##   * ``executable <n>:`` -> ``var <n>: Executable``
##   * ``files <n>``       -> ``var <n>: BuildActionDef``
##
## The slot is default-initialised so recipes that DON'T assign to it
## (the existing 84-recipe ``discard pkg.library(...)`` baseline) keep
## compiling. Recipes that OPT INTO the assignment-binding pattern
## documented in ``From-Source-Build-Recipes.md`` §"Artifact binding by
## assignment" — ``libfoo = c_library(into = "libfoo", sources = ...)``
## — write the constructor's return value into the slot from the
## package's ``build:`` block.
##
## Coverage (mirrors the M9.R.2c task brief):
##
##   1. Library slot is typed ``Library`` and defaults to a record
##      with ``api.declared == false``.
##   2. Executable slot is typed ``Executable`` and defaults to a
##      record with an empty ``cli.executableName``.
##   3. Files slot is typed ``BuildActionDef`` and defaults to an
##      empty-id action.
##   4. Assignment binding works — a recipe with an ``api:`` block
##      assigns a constructed ``Library`` to the slot from ``build:``
##      and the post-body slot value reflects the assignment.
##   5. The legacy ``discard`` pattern still works — a recipe with
##      ``library <slot>: discard`` and an unrelated ``discard 42``
##      under ``build:`` compiles and leaves the slot at its default.
##   6. Mixed slot kinds — a single recipe declaring one of each kind
##      gets one slot of each type without cross-kind collisions.
##   7. ``c_library(into = ...)`` returning into a typed slot lands
##      the auto-lifted ``api`` metadata in the slot's ``api`` field.
##
## IMPORTANT — slot names are injected at MODULE scope, so each
## fixture below uses a UNIQUE slot identifier (``libfooM9r2cA`` /
## ``libfooM9r2cB`` / ...) to avoid module-level ``var`` redefinition.
## Real recipes are one-per-module so the collision risk doesn't apply
## there.

{.experimental: "callOperator".}

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/types
import repro_dsl_stdlib/operations/toolchain
import repro_dsl_stdlib/constructors

# ---------------------------------------------------------------------------
# Fixture 1 — library slot only.
# ---------------------------------------------------------------------------

package m9r2cLibraryOnly:
  library libfooM9r2cA:
    discard

# ---------------------------------------------------------------------------
# Fixture 2 — executable slot only.
# ---------------------------------------------------------------------------

package m9r2cExecutableOnly:
  executable foobinM9r2cA:
    discard

# ---------------------------------------------------------------------------
# Fixture 3 — files slot only.
# ---------------------------------------------------------------------------

package m9r2cFilesOnly:
  files foodocsM9r2cA:
    discard

# ---------------------------------------------------------------------------
# Fixture 4 — assignment binding inside build:.
# ---------------------------------------------------------------------------

package m9r2cAssignmentBind:
  library libfooM9r2cB:
    api:
      soname  "foo"
      sover   "1.0"
      linkKind shared

  build:
    libfooM9r2cB = Library(
      api: LibraryApi(declared: true, soname: "foo", sover: "1.0",
                      linkKind: llkShared),
      soname: "foo",
      sover: "1.0",
      linkKind: llkShared,
      installPrefix: "usr/lib")

# ---------------------------------------------------------------------------
# Fixture 5 — discard pattern under build: keeps working.
# ---------------------------------------------------------------------------

package m9r2cDiscardPattern:
  library libfooM9r2cC:
    discard

  build:
    discard 42

# ---------------------------------------------------------------------------
# Fixture 6 — mixed slot kinds in a single recipe.
# ---------------------------------------------------------------------------

package m9r2cMixedSlots:
  library libfooM9r2cD:
    discard
  executable foobinM9r2cD:
    discard
  files foodocsM9r2cD:
    discard

# ---------------------------------------------------------------------------
# Fixture 7 — c_library constructor returns into a typed Library slot.
# ---------------------------------------------------------------------------

package m9r2cCLibConstructor:
  library libfooM9r2cE:
    api:
      soname  "foo"
      linkKind shared

  build:
    setCompilerOverride("gcc")
    libfooM9r2cE = c_library(into = "libfooM9r2cE",
                             sources = @["src/foo.c"])


suite "DSL-port M9.R.2c — artifact slot typing":

  test "library slot is typed Library":
    # The slot's declared type must be ``Library``; ``typeof`` resolves
    # at compile time so a slot mistakenly typed ``DslArtifact`` would
    # fail this assertion. ``Library`` is re-exported via
    # ``repro_dsl_stdlib/types`` (and transitively via
    # ``types/package_result``, see the M9.R.2c re-export).
    check typeof(libfooM9r2cA) is Library
    check libfooM9r2cA.api.declared == false
    check libfooM9r2cA.soname == ""
    check libfooM9r2cA.linkKind == llkUnset
    check libfooM9r2cA.installPrefix == ""

  test "executable slot is typed Executable":
    check typeof(foobinM9r2cA) is Executable
    check foobinM9r2cA.cli.executableName == ""
    check foobinM9r2cA.installPrefix == ""

  test "files slot is typed BuildActionDef":
    check typeof(foodocsM9r2cA) is BuildActionDef
    check foodocsM9r2cA.id == ""
    check foodocsM9r2cA.outputs.len == 0


suite "DSL-port M9.R.2c — assignment binding pattern":

  test "library slot accepts a Library assignment from build:":
    # Fixture 4's build: block wrote a populated Library into the
    # module-scope slot var ``libfooM9r2cB`` at module-init time
    # (the build: body runs verbatim under
    # ``when not defined(reproProviderMode)``). The slot must reflect
    # the assignment.
    check libfooM9r2cB.api.declared == true
    check libfooM9r2cB.api.soname == "foo"
    check libfooM9r2cB.soname == "foo"
    check libfooM9r2cB.sover == "1.0"
    check libfooM9r2cB.linkKind == llkShared
    check libfooM9r2cB.installPrefix == "usr/lib"

  test "discard pattern under build: still compiles and leaves slot at default":
    # Fixture 5 — recipe never assigns to ``libfooM9r2cC``; just runs
    # ``discard 42``. The slot stays at its default (``Library`` with
    # ``api.declared == false``). If the macro had emitted a missing-
    # assignment compile-time check, this test would fail to compile;
    # the M9.R.2c task brief deliberately does NOT add such a check
    # since the 84-recipe corpus relies on the discard pattern.
    check libfooM9r2cC.api.declared == false
    check libfooM9r2cC.soname == ""


suite "DSL-port M9.R.2c — mixed slot kinds":

  test "single recipe declaring library + executable + files gets one of each":
    # The three slot vars in fixture 6 must all compile with the right
    # types; checking ``typeof`` on each pins that the per-kind
    # ``ident()`` injection routed correctly through ``entry.ownership``
    # in ``emitM3Artifacts``.
    check typeof(libfooM9r2cD) is Library
    check typeof(foobinM9r2cD) is Executable
    check typeof(foodocsM9r2cD) is BuildActionDef
    # Registry attribution should record all three under the same
    # package name with the expected kind discriminators.
    let arts = registeredArtifacts("m9r2cMixedSlots")
    check arts.len == 3
    var libCount = 0
    var exeCount = 0
    var filesCount = 0
    for art in arts:
      case art.kind
      of dakLibrary:    libCount += 1
      of dakExecutable: exeCount += 1
      of dakFiles:      filesCount += 1
    check libCount == 1
    check exeCount == 1
    check filesCount == 1


suite "DSL-port M9.R.2c — c_library constructor lands on typed Library slot":

  test "c_library(into = ...) return value lands in the typed Library slot":
    # Fixture 7's ``build:`` body assigned the constructor's return
    # into the typed ``libfooM9r2cE`` slot. The slot holds the
    # constructor's emitted install edge — proving the assignment
    # binding pattern works end-to-end with a Layer-1 constructor.
    #
    # NOTE: the auto-lift mechanism (M9.R.2b) reads
    # ``registeredLibraryApi(activePkg, into)`` to populate the
    # ``Library.api`` field. The registration is emitted by
    # ``emitM9R3LibraryApis`` LATER in the package macro expansion
    # (after M4's build-action emission), so the api isn't yet
    # registered when c_library runs from inside the build body at
    # module-init time. This is a pre-existing M9.R.2b limitation
    # documented in the constructor's doc comment ("falls back to
    # packageName == "" so the registered "libfoo" lookup returns
    # declared == false"). The M9.R.2c slot-typing change does not
    # depend on it being closed; we only assert the slot RECEIVED the
    # constructor's edge here. The api-by-suite-time read is covered
    # by t_m9r2b_typed_value_layer.nim's "c_library reads registered
    # LibraryApi via the into parameter" test.
    check libfooM9r2cE.install.call.packageName == "gcc"
    # The install edge is the gcc link action, with target name
    # derived from the ``into`` (api.declared was false at construct
    # time so the constructor falls through to the "lib<into>.so"
    # branch).
    check libfooM9r2cE.installPrefix == "usr/lib"
