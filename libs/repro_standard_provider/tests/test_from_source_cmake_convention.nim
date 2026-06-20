## M9.L.1 + M9.R.6.1 verification: from-source CMake (Tier 2b)
## convention.
##
## Pins the convention's narrowed wiring:
##
##   * the M9.H ``registeredFetchSpec`` registry (fetch: block) → fetch
##     BuildAction;
##   * the M9.R.6.1 synthesis sentinel action that depends on the fetch
##     action and stamps the binary-cache identity.
##
## The configure / build / install / stage-copy actions are NO LONGER
## emitted by this convention — they live in the recipe's explicit
## ``build:`` block via ``cmake_package(...)``.

import std/[options, os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_cmake as
  from_source_cmake_convention

import "../../../recipes/packages/source/kcoreaddons/repro"

const
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  KcoreaddonsRecipe =
    ReprobuildRoot / "recipes" / "packages" / "source" / "kcoreaddons"

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

suite "from-source-cmake convention M9.R.6.1 — kcoreaddons":

  test "convention name is 'from-source-cmake'":
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    check conv.name == "from-source-cmake"

  test "recognize: positive — kcoreaddons source recipe":
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    check fileExists(KcoreaddonsRecipe / "repro.nim")
    let spec = registeredFetchSpec("kcoreaddonsSource")
    check spec.url.len > 0
    let request = dummyRequest(KcoreaddonsRecipe)
    check conv.recognize(KcoreaddonsRecipe, request)

  test "emitFragment: returns EXACTLY fetch + synthesis sentinel (M9.R.6.1)":
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(KcoreaddonsRecipe)
    require conv.recognize(KcoreaddonsRecipe, request)
    let fragment = conv.emitFragment(KcoreaddonsRecipe, request)
    let actions = extractActions(fragment)
    check actions.len == 2
    var sawFetch = false
    var sawSentinel = false
    for a in actions:
      if a.id == "ccpp-fetch-kcoreaddonsSource":
        sawFetch = true
      elif a.id == "from-source-cmake-sentinel":
        sawSentinel = true
    check sawFetch
    check sawSentinel
    # Defensive: the legacy 5-stage action ids must be absent.
    for legacyId in @["from-source-cmake-configure",
                      "from-source-cmake-build",
                      "from-source-cmake-install"]:
      var present = false
      for a in actions:
        if a.id == legacyId:
          present = true
      check not present

  test "emitFragment: sentinel depends on fetch action":
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(KcoreaddonsRecipe)
    let fragment = conv.emitFragment(KcoreaddonsRecipe, request)
    let actions = extractActions(fragment)
    let sentinel = findById(actions, "from-source-cmake-sentinel")
    check sentinel.deps == @["ccpp-fetch-kcoreaddonsSource"]

  test "emitFragment: sentinel carries publishToBinaryCache + identity":
    let conv = from_source_cmake_convention.fromSourceCmakeConvention()
    let request = dummyRequest(KcoreaddonsRecipe)
    let fragment = conv.emitFragment(KcoreaddonsRecipe, request)
    let actions = extractActions(fragment)
    let sentinel = findById(actions, "from-source-cmake-sentinel")
    check sentinel.publishToBinaryCache == true
    check sentinel.cacheEntryIdentity.isSome
    let identity = sentinel.cacheEntryIdentity.get()
    check identity.packageName == "kcoreaddonsSource"
    check identity.toolchain.name == "cmake"
