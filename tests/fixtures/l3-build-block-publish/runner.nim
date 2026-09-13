## L3 PUBLISH-SCOPE provider-mode runner.
##
## Compiled with ``--define:reproProviderMode``. Imports the fixture
## recipe as a NON-main module (so the recipe's own
## ``runPackageProvider`` gate does NOT fire), then drives
## ``buildPackageFragment`` with the recipe directory as the provider
## ``arguments`` — the REAL provider fragment-build path, which sets the
## active project root so ``providerRevision`` resolves exactly as it
## does under a live ``repro build``.
##
## Each JSON line records a real provider-mode action's publication tag,
## identity fields and the result of attempting canonical key derivation.

import std/[json, options, os]

import repro_project_dsl
import repro_provider_runtime
import repro_binary_cache_client/cache_key

import "repro.nim"

proc actionKind(action: BuildActionDef): string =
  ## First output basename is enough to recognise which edge this is in
  ## the test (publicTool / optedOutTool / internalHelper).
  if action.outputs.len > 0:
    extractFilename(action.outputs[0])
  else:
    action.id

when isMainModule:
  let recipeDir =
    if paramCount() >= 1: paramStr(1)
    else: getCurrentDir()
  # Locate the fixture package that the recipe module registered at
  # import time.
  var pkgOpt: Option[PackageDef]
  for p in registeredPackages():
    if p.packageName == "l3pub":
      pkgOpt = some(p)
  doAssert pkgOpt.isSome, "l3pub package not registered"

  let request = ProviderGraphRequest(
    entryPointId: "l3pub.root",
    entryPointBodyHash: "l3pub-body-v1",
    arguments: recipeDir,
    namespace: "l3pub")

  # REAL provider fragment build: sets the active project root, runs the
  # flattened build proc, and returns the emitted fragment. We only need
  # the side effect on the action registry.
  discard buildPackageFragment(pkgOpt.get(), request,
    buildL3pubPackage, includeDefault = false)

  for action in registeredBuildActions():
    let publish = action.publishToBinaryCache and action.cacheEntryIdentity.isSome
    var keyHex = ""
    var pkgName = ""
    var toolchain = ""
    var providerRev = ""
    var identityError = ""
    if action.cacheEntryIdentity.isSome:
      let idy = action.cacheEntryIdentity.get()
      try:
        keyHex = deriveCacheEntryKeyHex(idy)
      except CacheKeyError as error:
        identityError = error.msg
      pkgName = idy.packageName
      toolchain = idy.toolchain.name
      providerRev = idy.providerRevision
    echo $(%*{"action": actionKind(action), "publish": publish, "keyHex": keyHex,
      "packageName": pkgName, "toolchain": toolchain, "providerRevision": providerRev,
      "identityError": identityError})
