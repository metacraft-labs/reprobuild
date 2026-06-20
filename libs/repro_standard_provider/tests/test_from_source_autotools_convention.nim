## M9.L.2 + M9.R.6.1 verification: from-source Autotools (Tier 2b)
## convention.
##
## Pins the convention's narrowed wiring:
##
##   * the M9.H ``registeredFetchSpec`` registry (fetch: block) → fetch
##     BuildAction;
##   * the M9.R.6.1 synthesis sentinel action.
##
## The configure / build / install / stage-copy actions are NO LONGER
## emitted by this convention — they live in the recipe's explicit
## ``build:`` block via ``autotools_package(...)``.

import std/[options, os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_autotools as
  from_source_autotools_convention

import "../../../recipes/packages/source/expat/repro"

const
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  ExpatRecipe =
    ReprobuildRoot / "recipes" / "packages" / "source" / "expat"

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

suite "from-source-autotools convention M9.R.6.1 — expat":

  test "convention name is 'from-source-autotools'":
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    check conv.name == "from-source-autotools"

  test "recognize: positive — expat source recipe":
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    check fileExists(ExpatRecipe / "repro.nim")
    let spec = registeredFetchSpec("expatSource")
    check spec.url.len > 0
    let request = dummyRequest(ExpatRecipe)
    check conv.recognize(ExpatRecipe, request)

  test "emitFragment: returns EXACTLY fetch + synthesis sentinel (M9.R.6.1)":
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    require conv.recognize(ExpatRecipe, request)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)
    check actions.len == 2
    var sawFetch = false
    var sawSentinel = false
    for a in actions:
      if a.id == "ccpp-fetch-expatSource":
        sawFetch = true
      elif a.id == "from-source-autotools-sentinel":
        sawSentinel = true
    check sawFetch
    check sawSentinel
    # Defensive: the legacy 5-stage action ids must be absent.
    for legacyId in @["from-source-autotools-configure",
                      "from-source-autotools-build",
                      "from-source-autotools-install"]:
      var present = false
      for a in actions:
        if a.id == legacyId:
          present = true
      check not present

  test "emitFragment: sentinel depends on fetch action":
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)
    let sentinel = findById(actions, "from-source-autotools-sentinel")
    check sentinel.deps == @["ccpp-fetch-expatSource"]

  test "emitFragment: sentinel carries publishToBinaryCache + identity":
    let conv = from_source_autotools_convention.fromSourceAutotoolsConvention()
    let request = dummyRequest(ExpatRecipe)
    let fragment = conv.emitFragment(ExpatRecipe, request)
    let actions = extractActions(fragment)
    let sentinel = findById(actions, "from-source-autotools-sentinel")
    check sentinel.publishToBinaryCache == true
    check sentinel.cacheEntryIdentity.isSome
    let identity = sentinel.cacheEntryIdentity.get()
    check identity.packageName == "expatSource"
    check identity.toolchain.name == "autotools"
