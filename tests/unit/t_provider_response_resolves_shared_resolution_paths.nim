## A dev-env response's shared-service resolutions name THIS copy's files
## once the engine has received them.
##
## Provider-Runtime-Protocol-v1.md, "Paths in responses": a recipe-relative
## provider records the sites its DSL serializes relative to the recipe it
## was compiled from, and the engine resolves a relative name in a response
## against the working directory it launched the provider in. A shared
## service's resolution carries three such facts: the owner's recipe
## directory (`.` in the owner's own provider, `../<owner>` in a consumer
## that includes the owner's recipe), the resolver's site and each
## contribution's `<file>:<line>` site. The engine reads `ownerRecipeDir` to
## find the owner's interface artifact, so a relative value left unresolved
## would be looked up against the CLI's own working directory instead.
##
## Falsifier: drop the `sharedResolutions` loop from
## `resolveRelativeResponsePaths` and every check below goes red.
##
## MOCK POLICY - none. The response is the real wire type, and the resolver
## is the one the engine applies to every response it receives.

import std/[os, unittest]

import repro_provider_runtime/runtime
import repro_provider_runtime/types

proc devEnvResponse(resolution: DevEnvSharedResolution): ProviderGraphResponse =
  result = ProviderGraphResponse(kind: pskDevEnvResult)
  result.devEnv.sharedResolutions = @[resolution]

suite "a dev-env response's shared resolutions resolve at the project root":
  test "relative owner directory, site and contribution sites resolve":
    let root = absolutePath(getTempDir() / "ws" / "consumer")
    var response = devEnvResponse(DevEnvSharedResolution(
      ownerPackage: "owner", serviceName: "idp",
      ownerRecipeDir: "../owner",
      sourceFile: "repro.nim", sourceLine: 12,
      contributionSites: @["repro.nim:14", "lib/extra.nim:3"]))
    response.resolveRelativeResponsePaths(root)
    let resolved = response.devEnv.sharedResolutions[0]
    check resolved.ownerRecipeDir == parentDir(root) / "owner"
    check resolved.sourceFile == root / "repro.nim"
    check resolved.contributionSites ==
      @[root / "repro.nim" & ":14", root / "lib" / "extra.nim" & ":3"]

  test "the owner's own directory resolves to the project root":
    let root = absolutePath(getTempDir() / "ws" / "owner")
    var response = devEnvResponse(DevEnvSharedResolution(
      ownerPackage: "owner", serviceName: "idp", ownerRecipeDir: "."))
    response.resolveRelativeResponsePaths(root)
    check response.devEnv.sharedResolutions[0].ownerRecipeDir == root

  test "absolute and empty values are unchanged":
    # A location-bound provider names everything absolutely, as before, and
    # an unrecorded site stays unrecorded rather than becoming the root.
    let root = absolutePath(getTempDir() / "ws" / "consumer")
    let owner = absolutePath(getTempDir() / "elsewhere" / "owner")
    var response = devEnvResponse(DevEnvSharedResolution(
      ownerPackage: "owner", serviceName: "idp",
      ownerRecipeDir: owner, sourceFile: "",
      contributionSites: @["", owner / "repro.nim" & ":7"]))
    response.resolveRelativeResponsePaths(root)
    let resolved = response.devEnv.sharedResolutions[0]
    check resolved.ownerRecipeDir == owner
    check resolved.sourceFile == ""
    check resolved.contributionSites == @["", owner / "repro.nim" & ":7"]
