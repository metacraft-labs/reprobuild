## DSL-port M9.R.6 — convention-narrowing + default-build-synthesis
## regression suite.
##
## Pins the load-bearing pieces of M9.R.6:
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
##   3. **Per-convention dispatch.** The four ``synthesize<X>Package``
##      entry points wrap the M9.R.2b ``meson_package`` /
##      ``cmake_package`` / ``autotools_package`` constructors and
##      thread the legacy flag-channel values (``mesonOptions:`` /
##      ``cmakeFlags:`` / ``configureFlags:`` /``makeFlags:``) through
##      as constructor arguments.
##
##   4. **Custom recipe raise.** ``raiseCustomBuildRequired`` raises a
##      ``ValueError`` with the recipe name + an actionable error
##      message naming the ``shell()`` action surface.
##
##   5. **Backward-decode of ``registeredBuildFlags``.** The M9.I
##      ``registeredBuildFlags`` registry is still populated by recipes
##      that spell ``mesonOptions:`` etc.; the deprecation comment
##      lands but the accessor still returns the registered options.
##
##   6. **Recognition via registry.** The convention layer's
##      ``recognize`` proc now consults
##      ``registeredNativeBuildDeps`` BEFORE falling back to the
##      source-text scanner. Verified indirectly via the synthesis
##      layer's same lookup (the convention-side check is exercised
##      end-to-end by the existing
##      ``test_from_source_meson_convention.nim`` /
##      ``test_from_source_cmake_convention.nim`` suites).

import std/[unittest, strutils]

import repro_project_dsl
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
  mesonOptions:
    "-Dfoo=true"
    "--buildtype=release"
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
  cmakeFlags:
    "-DBUILD_SHARED_LIBS=ON"
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
  configureFlags:
    "--enable-shared"
  executable autoBaz:
    discard

package m9r6MakeFixture:
  fetch:
    url: "https://example.com/make-fixture.tar.gz"
    sha256: "0000000000000000000000000000000000000000000000000000000000000004"
  nativeBuildDeps:
    "make"
    "gcc"
  makeFlags:
    "PREFIX=/usr"
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

  test "synthesizeMesonPackage: returns MesonPackageResult driven by legacy options":
    let result = synthesizeMesonPackage(
      packageName = "m9r6MesonFixture",
      srcDir = "/tmp/m9r6-meson-fixture")
    # MesonPackageResult has buildEdge / compileEdge / installEdge —
    # we don't pin the action shape (M9.R.2b owns that) but we do
    # check the result type's fields are populated.
    check result.destdir.len > 0

  test "synthesizeCmakePackage: returns CmakePackageResult driven by legacy flags":
    let result = synthesizeCmakePackage(
      packageName = "m9r6CmakeFixture",
      srcDir = "/tmp/m9r6-cmake-fixture")
    check result.destdir.len > 0

  test "synthesizeAutotoolsPackage: returns AutotoolsPackageResult driven by legacy flags":
    let result = synthesizeAutotoolsPackage(
      packageName = "m9r6AutotoolsFixture",
      srcDir = "/tmp/m9r6-autotools-fixture")
    check result.destdir.len > 0

  test "legacyMesonOptions: backward-decode retained for ``mesonOptions:``":
    # The M9.I ``registeredBuildFlags`` registry is still populated
    # by the ``mesonOptions:`` parser arm. M9.R.6 retires the public
    # accessor in spirit (deprecation comment) but the M9.R.5b sweep
    # is what actually empties the registry. Until then, the
    # synthesis layer reads it via ``legacyMesonOptions``.
    let options = legacyMesonOptions("m9r6MesonFixture")
    check options.len == 2
    check "-Dfoo=true" in options
    check "--buildtype=release" in options

  test "legacyCmakeFlags: backward-decode retained for ``cmakeFlags:``":
    let flags = legacyCmakeFlags("m9r6CmakeFixture")
    check flags.len == 1
    check "-DBUILD_SHARED_LIBS=ON" in flags

  test "legacyConfigureFlags: backward-decode retained for ``configureFlags:``":
    let flags = legacyConfigureFlags("m9r6AutotoolsFixture")
    check flags.len == 1
    check "--enable-shared" in flags

  test "legacyMakeFlags: backward-decode retained for ``makeFlags:``":
    let flags = legacyMakeFlags("m9r6MakeFixture")
    check flags.len == 1
    check "PREFIX=/usr" in flags

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
