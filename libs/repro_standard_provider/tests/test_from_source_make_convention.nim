## M9.L.3 + M9.R.6.1 verification: from-source plain-Make / kbuild
## (Tier 2b) convention.
##
## Pins the convention's narrowed wiring:
##
##   * the M9.H ``registeredFetchSpec`` registry (fetch: block) → fetch
##     BuildAction;
##   * the M9.R.6.1 synthesis sentinel action.
##
## The build / install / stage-copy actions are NO LONGER emitted by
## this convention — they live in the recipe's explicit ``build:`` block
## (typically via ``autotools_package(...)`` or a hand-rolled
## ``shell()`` chain for raw-Makefile / kbuild recipes).

import std/[options, os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_make as
  from_source_make_convention

import "../../../recipes/packages/source/libcap/repro"
import "../../../recipes/packages/source/kernel/repro"

const
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  LibcapRecipe =
    ReprobuildRoot / "recipes" / "packages" / "source" / "libcap"
  KernelRecipe =
    ReprobuildRoot / "recipes" / "packages" / "source" / "kernel"

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

suite "from-source-make convention M9.R.6.1 — libcap":

  test "convention name is 'from-source-make'":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    check conv.name == "from-source-make"

  test "recognize: positive — libcap source recipe":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    check fileExists(LibcapRecipe / "repro.nim")
    let spec = registeredFetchSpec("libcapSource")
    check spec.url.len > 0
    let request = dummyRequest(LibcapRecipe)
    check conv.recognize(LibcapRecipe, request)

  test "emitFragment: returns EXACTLY fetch + synthesis sentinel (M9.R.6.1)":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(LibcapRecipe)
    require conv.recognize(LibcapRecipe, request)
    let fragment = conv.emitFragment(LibcapRecipe, request)
    let actions = extractActions(fragment)
    check actions.len == 2
    var sawFetch = false
    var sawSentinel = false
    for a in actions:
      if a.id == "ccpp-fetch-libcapSource":
        sawFetch = true
      elif a.id == "from-source-make-sentinel":
        sawSentinel = true
    check sawFetch
    check sawSentinel
    # Defensive: the legacy 5-stage action ids must be absent.
    for legacyId in @["from-source-make-build",
                      "from-source-make-install"]:
      var present = false
      for a in actions:
        if a.id == legacyId:
          present = true
      check not present

  test "emitFragment: sentinel carries publishToBinaryCache + identity":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(LibcapRecipe)
    let fragment = conv.emitFragment(LibcapRecipe, request)
    let actions = extractActions(fragment)
    let sentinel = findById(actions, "from-source-make-sentinel")
    check sentinel.publishToBinaryCache == true
    check sentinel.cacheEntryIdentity.isSome
    let identity = sentinel.cacheEntryIdentity.get()
    check identity.packageName == "libcapSource"
    check identity.toolchain.name == "make"

suite "from-source-make convention M9.R.6.1 — kernel":

  test "recognize: positive — kernel source recipe":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    check fileExists(KernelRecipe / "repro.nim")
    let spec = registeredFetchSpec("kernelSource")
    check spec.url.len > 0
    let request = dummyRequest(KernelRecipe)
    check conv.recognize(KernelRecipe, request)

  test "emitFragment: kernel recipe emits fetch + sentinel only":
    let conv = from_source_make_convention.fromSourceMakeConvention()
    let request = dummyRequest(KernelRecipe)
    require conv.recognize(KernelRecipe, request)
    let fragment = conv.emitFragment(KernelRecipe, request)
    let actions = extractActions(fragment)
    check actions.len == 2
    var sawFetch = false
    var sawSentinel = false
    for a in actions:
      if a.id == "ccpp-fetch-kernelSource":
        sawFetch = true
      elif a.id == "from-source-make-sentinel":
        sawSentinel = true
    check sawFetch
    check sawSentinel
