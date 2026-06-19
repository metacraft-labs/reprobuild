## M9.L.0 + M9.R.6.1 verification: from-source Meson (Tier 2b)
## convention.
##
## Pins the convention's narrowed wiring:
##
##   * the M9.H ``registeredFetchSpec`` registry (fetch: block) → fetch
##     BuildAction emitted by the shared
##     ``conventions/fetch_action.emitFetchAction`` helper;
##   * the M9.R.6.1 synthesis sentinel action that depends on the fetch
##     action and stamps the binary-cache identity. The configure /
##     compile / install / stage-copy actions are NO LONGER produced by
##     this convention — they live in the recipe's explicit ``build:``
##     block via the M9.R.2b ``meson_package(...)`` constructor.
##   * the per-recipe ``executable <name>:`` declarations are extracted
##     by ``recognize`` for sanity but no per-artifact stage-copy edge
##     is emitted at convention level.
##
## The test runs against the **real production dbus-broker recipe**
## under ``recipes/packages/source/dbus-broker/`` (vendored tarball)
## and exercises ``recognize`` + ``emitFragment`` end-to-end.

import std/[options, os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_meson as
  from_source_meson_convention

# Side-effect import: triggers the dbus-broker recipe's package macro
# which registers the fetch spec + executable artifacts under the
# ``dbusBrokerSource`` key at module init time. The path is relative
# to this test file's location; ``../../..`` lands at the reprobuild
# repo root, and ``recipes/...`` from there.
import "../../../recipes/packages/source/dbus-broker/repro"

const
  ## parentDir four times from
  ## ``libs/repro_standard_provider/tests/test_from_source_meson_convention.nim``
  ## lands at the reprobuild repo root.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
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

proc findById(actions: seq[BuildActionDef]; id: string): BuildActionDef =
  for a in actions:
    if a.id == id:
      return a
  raise newException(ValueError, "action not found: " & id)

suite "from-source-meson convention M9.R.6.1 — dbus-broker":

  test "convention name is 'from-source-meson'":
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    check conv.name == "from-source-meson"

  test "recognize: positive — dbus-broker source recipe":
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    check fileExists(DbusBrokerRecipe / "repro.nim")
    let spec = registeredFetchSpec("dbusBrokerSource")
    check spec.url.len > 0
    check not fileExists(extendedPath(DbusBrokerRecipe / "meson.build"))
    let request = dummyRequest(DbusBrokerRecipe)
    check conv.recognize(DbusBrokerRecipe, request)

  test "emitFragment: returns EXACTLY fetch + synthesis sentinel (M9.R.6.1)":
    # M9.R.6.1 narrowed contract — emitFragment emits TWO actions only:
    #   1. fetch (``ccpp-fetch-<package>``)
    #   2. synthesis sentinel (``from-source-meson-sentinel``)
    # The configure / compile / install / stage-copy actions live in
    # the recipe's explicit ``build:`` block (or, for option-free
    # recipes, the stdlib synthesis path).
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
    # Defensive: the legacy 5-stage action ids must be absent.
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

  test "emitFragment: sentinel depends on fetch action":
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)
    let sentinel = findById(actions, "from-source-meson-sentinel")
    check sentinel.deps == @["ccpp-fetch-dbusBrokerSource"]

  test "emitFragment: sentinel carries publishToBinaryCache + identity (M9.R.6.1)":
    # M9.R.6.1: the binary-cache identity moved off the install + stage
    # edges (now gone) onto the sentinel. The engine's
    # ``BinaryCachePublisher`` hook fires after the sentinel succeeds.
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)
    let sentinel = findById(actions, "from-source-meson-sentinel")
    check sentinel.publishToBinaryCache == true
    check sentinel.cacheEntryIdentity.isSome
    let identity = sentinel.cacheEntryIdentity.get()
    check identity.packageName == "dbusBrokerSource"
    check identity.packageVersion == "36"
    check identity.toolchain.name == "meson"
    check identity.providerRevision.len == 32
    for ch in identity.providerRevision:
      check ch in {'0'..'9', 'a'..'f'}

  test "emitFragment: identity is stable across calls":
    # The cache-entry identity is a pure function of recipe identity.
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragmentA = conv.emitFragment(DbusBrokerRecipe, request)
    let fragmentB = conv.emitFragment(DbusBrokerRecipe, request)
    let sentA = findById(extractActions(fragmentA),
      "from-source-meson-sentinel")
    let sentB = findById(extractActions(fragmentB),
      "from-source-meson-sentinel")
    let identA = sentA.cacheEntryIdentity.get()
    let identB = sentB.cacheEntryIdentity.get()
    check identA.packageName == identB.packageName
    check identA.packageVersion == identB.packageVersion
    check identA.toolchain.name == identB.toolchain.name
    check identA.providerRevision == identB.providerRevision

  test "emitFragment: fetch action's argv carries the recipe's URL + sha256":
    let conv = from_source_meson_convention.fromSourceMesonConvention()
    let request = dummyRequest(DbusBrokerRecipe)
    let fragment = conv.emitFragment(DbusBrokerRecipe, request)
    let actions = extractActions(fragment)
    let fetch = findById(actions, "ccpp-fetch-dbusBrokerSource")
    var argvJoined = ""
    for arg in fetch.call.arguments:
      if arg.name == "argv":
        argvJoined = arg.encodedValue.replace("\x1f", " ")
    check argvJoined.contains("dbus-broker-v36.tar.gz")
    check argvJoined.contains(
      "5058a81eea8086636ef09a670d103e35e650a6f0200aadc2f59f3fb6e76c37b8")
