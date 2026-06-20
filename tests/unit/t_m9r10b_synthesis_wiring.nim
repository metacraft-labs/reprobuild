## DSL-port M9.R.10b — default-build synthesis wiring regression test.
##
## Pins the package macro's wiring of the M9.R.6 synthesis layer:
##
##   1. **Synthesis fires when fetch: declared without an explicit
##      build:** A recipe that declares ``fetch:`` AND
##      ``nativeBuildDeps:`` listing a recognised convention tool
##      (``meson`` / ``cmake`` / ``autoconf`` / ``make``) AND no
##      explicit ``build:`` block produces a registered build action
##      via the M9.R.10b synthesis emission. The synthesised body slices
##      the constructor result into the declared executable / library /
##      files artifact slots.
##
##   2. **Synthesis is skipped when an explicit ``build:`` block is
##      present.** The recipe owns its build pipeline; the M9.R.10b
##      emitter declines and emits no extra dispatch.
##
##   3. **Custom-convention recipes (sh / perl / python toolset) with
##      no ``build:`` raise ``raiseCustomBuildRequired`` at module init.**
##      The runtime path documents the recipe name + the actionable
##      remediation. The synthesis gate's
##      ``shouldSynthesizeDefaultBuild`` returns ``false`` for custom,
##      so the dispatch arm calls ``raiseCustomBuildRequired`` directly.
##
##   4. **Compile-time gate works.** Recipes that did NOT import
##      ``repro_dsl_stdlib/synthesis`` produce no emission at all (the
##      ``when compiles(defaultBuildConventionFor(...)):`` guard kicks
##      in). The standalone ``compiles`` check + a fixture verifies the
##      gate's behaviour at the emitter boundary.
##
## See ``reprobuild-specs/From-Source-DSL-Realignment.milestones.org``
## §M9.R.10b.

import std/[unittest, options, strutils]

import repro_project_dsl
import repro_dsl_stdlib/types
import repro_dsl_stdlib/synthesis
# DSL-port M9.R.6 / M9.R.2b — pull the typed constructors into scope so
# the synthesised dispatch's ``meson_package`` / ``cmake_package`` /
# ``autotools_package`` references resolve at module-init time.
import repro_dsl_stdlib/constructors

# ---------------------------------------------------------------------------
# Fixtures — each exercises one dispatch arm.
# ---------------------------------------------------------------------------

package m9r10bMesonSynthFixture:
  ## Meson + ninja + gcc; no explicit ``build:``. The M9.R.10b
  ## emitter must inject a synthesised dispatch that calls
  ## ``synthesizeMesonPackage`` at module init.
  fetch:
    url: "https://example.com/meson-synth-fixture.tar.gz"
    sha256: "0000000000000000000000000000000000000000000000000000000000000a01"
  nativeBuildDeps:
    "meson >=1.3"
    "ninja >=1.10"
    "gcc"
  executable mesonSynthFoo:
    discard

package m9r10bCmakeSynthFixture:
  fetch:
    url: "https://example.com/cmake-synth-fixture.tar.gz"
    sha256: "0000000000000000000000000000000000000000000000000000000000000a02"
  nativeBuildDeps:
    "cmake >=3.20"
    "ninja"
    "gcc"
  library cmakeSynthBar:
    discard

package m9r10bAutotoolsSynthFixture:
  fetch:
    url: "https://example.com/autotools-synth-fixture.tar.gz"
    sha256: "0000000000000000000000000000000000000000000000000000000000000a03"
  nativeBuildDeps:
    "autoconf"
    "automake"
    "make"
    "gcc"
  executable autotoolsSynthBaz:
    discard

package m9r10bExplicitBuildFixture:
  ## Has both ``fetch:`` AND an explicit ``build:``. Synthesis must
  ## NOT fire — only the explicit build action is registered.
  fetch:
    url: "https://example.com/explicit-build-fixture.tar.gz"
    sha256: "0000000000000000000000000000000000000000000000000000000000000a04"
  nativeBuildDeps:
    "meson"
    "ninja"
    "gcc"
  executable explicitBuildFoo:
    discard

  build:
    ## Explicit build body — synthesis declines.
    setCurrentOwningPackageOverride("m9r10bExplicitBuildFixture")
    try:
      let pkg = meson_package(srcDir = "./src")
      discard pkg.executable("explicitBuildFoo")
    finally:
      clearCurrentOwningPackageOverride()

package m9r10bNoToolSynthFixture:
  ## Has ``fetch:`` but ``nativeBuildDeps:`` lists nothing the
  ## synthesis layer recognises (no meson / cmake / autotools / make /
  ## custom-driver). The dispatch returns "" at runtime and the
  ## emission falls through to the discard arm without registering a
  ## synthesised action.
  fetch:
    url: "https://example.com/no-tool-synth-fixture.tar.gz"
    sha256: "0000000000000000000000000000000000000000000000000000000000000a06"
  nativeBuildDeps:
    "gcc >=11"
  executable noToolSynthQuux:
    discard

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "DSL-port M9.R.10b — default-build synthesis wiring":

  test "meson-convention fixture registers synthesised build action":
    # The M9.R.10b emitter dispatches via ``ConventionMeson``. The
    # synthesised body wraps the dispatch in
    # ``beginBuildContext`` / ``registerBuildAction`` /
    # ``endBuildContext`` per the emitM4BuildActions pattern. We
    # observe the registration through the dsl-port-runtime registry.
    let actions = registeredBuildActions("m9r10bMesonSynthFixture")
    check actions.len >= 1
    var sawSynthAction = false
    for action in actions:
      if action.bodyRepr.contains("default-build-synthesis"):
        sawSynthAction = true
        # The synthesised action is package-level (empty artifactName).
        check action.artifactName == ""
    check sawSynthAction

  test "cmake-convention fixture registers synthesised build action":
    let actions = registeredBuildActions("m9r10bCmakeSynthFixture")
    check actions.len >= 1
    var sawSynthAction = false
    for action in actions:
      if action.bodyRepr.contains("default-build-synthesis"):
        sawSynthAction = true
    check sawSynthAction

  test "autotools-convention fixture registers synthesised build action":
    let actions = registeredBuildActions("m9r10bAutotoolsSynthFixture")
    check actions.len >= 1
    var sawSynthAction = false
    for action in actions:
      if action.bodyRepr.contains("default-build-synthesis"):
        sawSynthAction = true
    check sawSynthAction

  test "explicit build: opts out of synthesis":
    # M9.R.10b explicitly checks for soM4Build at compile time; the
    # synthesis emission is suppressed for recipes with their own
    # ``build:`` body. The explicit build action still registers via
    # ``emitM4BuildActions``.
    let actions = registeredBuildActions("m9r10bExplicitBuildFixture")
    check actions.len >= 1
    var sawSynthAction = false
    for action in actions:
      if action.bodyRepr.contains("default-build-synthesis"):
        sawSynthAction = true
    # The compile-time gate prevents the synthesis action from being
    # emitted at all.
    check not sawSynthAction

  test "no-tool fixture: synthesis declines at runtime":
    # The recipe declares ``fetch:`` but no recognised convention tool.
    # The compile-time M9.R.10b emission fires (because the gate keys
    # off ``fetch:`` presence), but at runtime
    # ``defaultBuildConventionFor`` returns "" and the case branch
    # falls through to the ``else: discard`` arm — no synthesizer is
    # invoked. The ``registerBuildAction`` row still appears (so the
    # registry reflects that synthesis WAS attempted) but no Meson /
    # CMake / Autotools constructor edge is created.
    let conv = defaultBuildConventionFor("m9r10bNoToolSynthFixture")
    check conv == ""

  test "raiseCustomBuildRequired: stable shape for custom-only deps":
    # Direct sanity check on the runtime helper used by the M9.R.10b
    # dispatch arm. The synthesised emission calls this raiser when
    # the recipe resolves to ConventionCustom — we exercise the raiser
    # in isolation rather than embedding a custom-convention fixture
    # (the embedded fixture would crash the test binary's module init).
    var caught = false
    try:
      raiseCustomBuildRequired("m9r10bSyntheticCustomFixture")
    except ValueError as e:
      caught = true
      check e.msg.contains("m9r10bSyntheticCustomFixture")
      check e.msg.contains("build:")
      check e.msg.contains("shell(")
    check caught

  test "synthesis emitter is a compile-time gate":
    # The M9.R.10b emission is suppressed at compile time when the
    # recipe declares no ``fetch:`` block — the ``hasFetchBlock``
    # short-circuit returns the empty StmtList. This is exercised by
    # the existing dsl_port test suite: every recipe without ``fetch:``
    # compiles cleanly and registers no synth action.
    #
    # Pin the contract here by direct inspection of the public
    # synthesis API: ``shouldSynthesizeDefaultBuild`` returns false
    # when ``hasFetchBlock = false`` regardless of the package's
    # nativeBuildDeps registry.
    check shouldSynthesizeDefaultBuild(
      packageName = "m9r10bMesonSynthFixture",
      hasExplicitBuild = false,
      hasFetchBlock = false) == false

  test "compile-time gate: convention dispatch resolves declared tool":
    # End-to-end: the recipe's ``nativeBuildDeps:`` list is consulted
    # by ``defaultBuildConventionFor`` at module init. This is the same
    # lookup the M9.R.10b emission uses internally.
    check defaultBuildConventionFor("m9r10bMesonSynthFixture") ==
      ConventionMeson
    check defaultBuildConventionFor("m9r10bCmakeSynthFixture") ==
      ConventionCmake
    check defaultBuildConventionFor("m9r10bAutotoolsSynthFixture") ==
      ConventionAutotools
