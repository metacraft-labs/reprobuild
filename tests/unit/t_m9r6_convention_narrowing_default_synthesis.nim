## DSL-port M9.R.6 — convention-narrowing + default-build-synthesis
## regression suite.
##
## Pins the load-bearing pieces of M9.R.6 (updated for M9.R.6.1):
##
##   1. **Convention dispatch via the registry.** The synthesis layer's
##      ``defaultBuildConventionFor`` reads
##      ``registeredNativeBuildDeps(packageName)`` and returns the
##      canonical convention identity for the recipe — meson > cmake >
##      autotools > make > custom > "".
##
##   2. **Synthesis gate.** ``shouldSynthesizeDefaultBuild`` returns
##      ``true`` only when (a) ``fetch:`` is declared AND (b) no
##      explicit ``build:`` block AND (c) the convention dispatch
##      returns a non-custom value. Custom convention recipes WITHOUT
##      explicit ``build:`` are reported via the synthesis gate's
##      ``false`` return + the ``raiseCustomBuildRequired`` raiser.
##
##   3. **Per-convention dispatch.** The three ``synthesize<X>Package``
##      entry points wrap the M9.R.2b ``meson_package`` /
##      ``cmake_package`` / ``autotools_package`` constructors with NO
##      options argument. Recipes that need per-tool options provide
##      an explicit ``build:`` block calling the constructor with the
##      options inlined.
##
##   4. **Custom recipe raise.** ``raiseCustomBuildRequired`` raises a
##      ``ValueError`` with the recipe name + an actionable error
##      message naming the ``shell()`` action surface.
##
##   5. **Recognition via registry.** The convention layer's
##      ``recognize`` proc now consults
##      ``registeredNativeBuildDeps`` BEFORE falling back to the
##      source-text scanner. Verified indirectly via the synthesis
##      layer's same lookup (the convention-side check is exercised
##      end-to-end by the existing
##      ``test_from_source_meson_convention.nim`` /
##      ``test_from_source_cmake_convention.nim`` suites).
##
## ## M9.R.6.1 changes
##
## The fixtures no longer declare ``mesonOptions:`` / ``cmakeFlags:`` /
## ``configureFlags:`` / ``makeFlags:`` blocks — those parser arms were
## retired in M9.R.6.1 (2026-06-19). The synthesizer entry points no
## longer accept legacy flag-channel inputs. Tests for the
## ``legacy<X>Options`` shims were removed.

import std/[unittest, strutils]

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types
import repro_dsl_stdlib/synthesis

# ---------------------------------------------------------------------------
# Fixtures: synthetic packages exercising each dispatch branch + the
# ``no-fetch`` gate + the ``explicit-build`` opt-out.
# ---------------------------------------------------------------------------

package m9r6MesonFixture:
  fetch:
    url: "https://example.com/meson-fixture.tar.gz"
    sha256: "0000000000000000000000000000000000000000000000000000000000000001"
  nativeBuildDeps:
    "meson >=1.3"
    "ninja >=1.10"
    "gcc"
  executable mesonFoo:
    discard

package m9r6CmakeFixture:
  fetch:
    url: "https://example.com/cmake-fixture.tar.gz"
    sha256: "0000000000000000000000000000000000000000000000000000000000000002"
  nativeBuildDeps:
    "cmake >=3.20"
    "ninja"
    "gcc"
  library cmakeBar:
    discard

package m9r6AutotoolsFixture:
  fetch:
    url: "https://example.com/autotools-fixture.tar.gz"
    sha256: "0000000000000000000000000000000000000000000000000000000000000003"
  nativeBuildDeps:
    "autoconf"
    "automake"
    "make"
    "gcc"
  executable autoBaz:
    discard

package m9r6MakeFixture:
  fetch:
    url: "https://example.com/make-fixture.tar.gz"
    sha256: "0000000000000000000000000000000000000000000000000000000000000004"
  nativeBuildDeps:
    "make"
    "gcc"
  executable makeQux:
    discard

package m9r6CustomFixture:
  fetch:
    url: "https://example.com/custom-fixture.tar.gz"
    sha256: "0000000000000000000000000000000000000000000000000000000000000005"
  nativeBuildDeps:
    "sh"
    "perl"
  executable customWidget:
    discard

package m9r6NoFetchFixture:
  ## No ``fetch:`` block — synthesis must decline regardless of
  ## convention dispatch.
  nativeBuildDeps:
    "meson"
    "ninja"
  executable noFetchWidget:
    discard

package m9r6NoToolFixture:
  ## ``fetch:`` declared but ``nativeBuildDeps:`` lists nothing the
  ## synthesis layer recognises (no meson / cmake / autotools / make /
  ## custom-driver). Dispatch returns "".
  fetch:
    url: "https://example.com/no-tool-fixture.tar.gz"
    sha256: "0000000000000000000000000000000000000000000000000000000000000006"
  nativeBuildDeps:
    "gcc >=11"
  executable noToolWidget:
    discard

suite "DSL-port M9.R.6 — convention narrowing + default-build synthesis":

  test "defaultBuildConventionFor: meson dispatch":
    check defaultBuildConventionFor("m9r6MesonFixture") == ConventionMeson

  test "defaultBuildConventionFor: cmake dispatch":
    check defaultBuildConventionFor("m9r6CmakeFixture") == ConventionCmake

  test "defaultBuildConventionFor: autotools dispatch (autoconf token)":
    check defaultBuildConventionFor("m9r6AutotoolsFixture") ==
      ConventionAutotools

  test "defaultBuildConventionFor: make dispatch (make-only fallback)":
    check defaultBuildConventionFor("m9r6MakeFixture") == ConventionMake

  test "defaultBuildConventionFor: custom dispatch (shell driver token)":
    check defaultBuildConventionFor("m9r6CustomFixture") == ConventionCustom

  test "defaultBuildConventionFor: empty result when no token matches":
    check defaultBuildConventionFor("m9r6NoToolFixture") == ""

  test "defaultBuildConventionFor: unknown package returns empty":
    check defaultBuildConventionFor("m9r6NotARealPackageName") == ""

  test "shouldSynthesizeDefaultBuild: fires for meson without explicit build":
    check shouldSynthesizeDefaultBuild(
      packageName = "m9r6MesonFixture",
      hasExplicitBuild = false,
      hasFetchBlock = true) == true

  test "shouldSynthesizeDefaultBuild: skipped when build: is explicit":
    check shouldSynthesizeDefaultBuild(
      packageName = "m9r6MesonFixture",
      hasExplicitBuild = true,
      hasFetchBlock = true) == false

  test "shouldSynthesizeDefaultBuild: skipped when no fetch: declared":
    check shouldSynthesizeDefaultBuild(
      packageName = "m9r6NoFetchFixture",
      hasExplicitBuild = false,
      hasFetchBlock = false) == false

  test "shouldSynthesizeDefaultBuild: skipped for custom convention recipes":
    # Custom recipes have no canonical pipeline; the gate returns
    # false AND the caller must call ``raiseCustomBuildRequired`` to
    # signal the actionable error.
    check shouldSynthesizeDefaultBuild(
      packageName = "m9r6CustomFixture",
      hasExplicitBuild = false,
      hasFetchBlock = true) == false

  test "shouldSynthesizeDefaultBuild: skipped when no convention matches":
    check shouldSynthesizeDefaultBuild(
      packageName = "m9r6NoToolFixture",
      hasExplicitBuild = false,
      hasFetchBlock = true) == false

  test "raiseCustomBuildRequired: raises ValueError with actionable message":
    var caught = false
    var caughtMessage = ""
    try:
      raiseCustomBuildRequired("m9r6CustomFixture")
    except ValueError as e:
      caught = true
      caughtMessage = e.msg
    check caught
    # The error must name the recipe + the ``shell()`` action surface
    # + the production example so the author has an actionable next
    # step.
    check caughtMessage.contains("m9r6CustomFixture")
    check caughtMessage.contains("build:")
    check caughtMessage.contains("shell(")

  test "synthesizeMesonPackage: returns MesonPackageResult (no options arg)":
    let result = synthesizeMesonPackage(
      packageName = "m9r6MesonFixture",
      srcDir = "/tmp/m9r6-meson-fixture")
    # MesonPackageResult has destdir / installEdge / etc; we don't pin
    # the action shape (M9.R.2b owns that) but we do check the result
    # type's fields are populated.
    check result.destdir.len > 0

  test "synthesizeCmakePackage: returns CmakePackageResult (no options arg)":
    let result = synthesizeCmakePackage(
      packageName = "m9r6CmakeFixture",
      srcDir = "/tmp/m9r6-cmake-fixture")
    check result.destdir.len > 0

  test "synthesizeAutotoolsPackage: returns AutotoolsPackageResult (no options arg)":
    let result = synthesizeAutotoolsPackage(
      packageName = "m9r6AutotoolsFixture",
      srcDir = "/tmp/m9r6-autotools-fixture")
    check result.destdir.len > 0

  test "registry-based recognition: nativeBuildDeps consulted regardless of order":
    # The recognise check reads the registry rather than scanning
    # source text. A recipe that declares its nativeBuildDeps inside
    # a ``case`` / ``when`` branch (or that uses the legacy ``uses:``
    # synonym) still routes correctly because the registry is
    # populated at module-init time before the convention probes it.
    # We exercise the registry-read directly via the synthesis layer's
    # dispatch — the convention layer's ``registriesIncludeMeson``
    # uses the same lookup.
    check defaultBuildConventionFor("m9r6MesonFixture") == ConventionMeson
    # Sanity: the registry holds the ``meson`` token even when the
    # recipe declared more entries.
    let native = registeredNativeBuildDeps("m9r6MesonFixture")
    var sawMeson = false
    for raw in native:
      if raw.startsWith("meson"):
        sawMeson = true
    check sawMeson
