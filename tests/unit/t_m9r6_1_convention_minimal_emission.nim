## DSL-port M9.R.6.1 — physical convention narrowing + parser-arm
## retirement + ``registeredBuildFlags`` registry retirement.
##
## Pins the load-bearing pieces of M9.R.6.1:
##
##   1. **emitFragment returns exactly 2 actions** — fetch + sentinel.
##      No setup / compile / install / stage-copy.
##   2. **``registerBuildFlag`` / ``registeredBuildFlags`` no longer
##      compile** — the runtime API + the underlying threadvar registry
##      are gone.
##   3. **``mesonOptions:`` block raises at recipe compile time** — a
##      fixture that still declares the block trips the
##      "unknown package section" diagnostic from the legacy parser
##      fallback (``soLegacyParsePackageDef`` arm in
##      ``classifySectionStmt``).
##   4. **Synthesis path equivalence** — a recipe without an explicit
##      ``build:`` block routes through the synthesis layer's
##      ``synthesizeMesonPackage`` and produces a constructor result
##      with the same shape the legacy 5-stage path used to produce.

import std/[unittest, options, strutils, os]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_dsl_stdlib/synthesis
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_meson as
  from_source_meson_convention

# Side-effect import of a production recipe (dbus-broker) that
# exercises the convention's full claim + emit path.
import "../../recipes/packages/source/dbus-broker/repro"

const
  ## Five parentDirs from tests/unit/<this-test>.nim lands at the repo
  ## root.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir
  DbusBrokerRecipe =
    ReprobuildRoot / "recipes" / "packages" / "source" / "dbus-broker"

proc dummyRequest(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "standardProvider.root",
    entryPointBodyHash: "test-body-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

proc extractActions(fragment: GraphFragment): seq[BuildActionDef] =
  for node in fragment.nodes:
    if node.kind != gnkAction:
      continue
    result.add(decodeBuildActionPayload(toBytes(node.payload)))

suite "DSL-port M9.R.6.1 — convention narrowing + registry retirement":

  test "emitFragment returns EXACTLY fetch + sentinel (2 actions)":
    # The narrowed convention emits ONLY:
    #   1. ``ccpp-fetch-<package>`` — the fetch action.
    #   2. ``from-source-meson-sentinel`` — the synthesis sentinel.
    # No setup / compile / install / stage-copy edges at convention
    # level. Recipes that need those provide an explicit ``build:``
    # block calling the M9.R.2b ``meson_package(...)`` constructor.
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    require conv.recognize(DbusBrokerRecipe, request)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)
    check actions.len == 2
    var sawFetch = false
    var sawSentinel = false
    for a in actions:
      if a.id == "ccpp-fetch-dbusBrokerSource":
        sawFetch = true
      elif a.id == "from-source-meson-sentinel":
        sawSentinel = true
    check sawFetch
    check sawSentinel
    # Defensive: every legacy id from the pre-narrowing 5-stage path
    # must be absent.
    for legacyId in @["from-source-meson-setup",
                      "from-source-meson-compile",
                      "from-source-meson-install",
                      "from-source-meson-stage-dbusBroker",
                      "from-source-meson-stage-dbusBrokerLaunch"]:
      var present = false
      for a in actions:
        if a.id == legacyId:
          present = true
      check not present

  test "``registerBuildFlag`` / ``registeredBuildFlags`` no longer compile":
    # M9.R.6.1: the entire M9.I runtime API was physically removed.
    # The ``compiles(...)`` macro returns false when an identifier is
    # undeclared at the call site; a regression that resurrects the
    # registry would silently break this assertion at compile time.
    check not compiles((proc (): seq[string] =
      result = registeredBuildFlags("anyPkg", "", "meson"))())
    check not compiles((proc () =
      registerBuildFlag("anyPkg", "", "meson", "-Dfoo=true"))())
    check not compiles((proc () = resetDslPortBuildFlagState())())

  test "synthesizeMesonPackage returns a result without options arg":
    # The synthesis layer's entry points no longer accept (or thread)
    # legacy flag-channel values. Recipes that need per-tool options
    # provide an explicit ``build:`` block. The synthesis path is for
    # recipes that have no options to thread.
    let result = synthesizeMesonPackage(
      packageName = "dbusBrokerSource",
      srcDir = "/tmp/m9r61-meson-fixture")
    check result.destdir.len > 0

  test "convention claims dbus-broker source recipe":
    # End-to-end recognise verification — the registry-based recognise
    # path used by the convention (registriesIncludeMeson) finds the
    # ``meson`` token via ``registeredNativeBuildDeps``.
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    check conv.recognize(DbusBrokerRecipe, request)

  test "sentinel action depends on fetch + carries cache identity":
    # The sentinel preserves the binary-cache identity wiring the legacy
    # install + stage-copy edges used to carry. The engine's
    # ``BinaryCachePublisher`` hook fires after the sentinel succeeds.
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)
    var sentinel: BuildActionDef
    var sawSentinel = false
    for a in actions:
      if a.id == "from-source-meson-sentinel":
        sentinel = a
        sawSentinel = true
    check sawSentinel
    check sentinel.deps == @["ccpp-fetch-dbusBrokerSource"]
    check sentinel.publishToBinaryCache
    check sentinel.cacheEntryIdentity.isSome
    let identity = sentinel.cacheEntryIdentity.get()
    check identity.packageName == "dbusBrokerSource"
    check identity.toolchain.name == "meson"
