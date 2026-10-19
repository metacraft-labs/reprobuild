## What the from-source cabal convention claims, and what it declines.
##
## The Haskell sibling of `t_from_source_npm_recognition`. Recognition fails
## silently -- claim too much and a project is taken from the sibling that
## understands it, claim too little and a recipe goes unbuilt with no
## diagnostic -- so the contract is asserted directly.
##
## The discriminators are: a registered `fetch:` spec, `cabal` in
## `nativeBuildDeps`, a committed `hackage-vendor.manifest` beside the recipe,
## no competing from-source driver, and no in-tree `.cabal` file or
## `cabal.project` at the root. Every case below flips exactly one.
##
## No mocks: each case writes a real recipe directory and populates the real
## registries recognition reads.

import std/[os, tempfiles, unittest]

import repro_project_dsl
import repro_provider_runtime
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_cabal

const RecipeText = """
import repro_project_dsl
import repro_dsl_stdlib/constructors

package nixfmtSource:
  fetch:
    url: "https://github.com/NixOS/nixfmt/archive/refs/tags/v1.2.0.tar.gz"
    sha256: "2b148abdf3c2ae9fca2b5898709cde5e4474e09cb32b892da51651c479f1f73a"
    extractStrip: 1

  nativeBuildDeps:
    "ghc >=9.12"
    "cabal >=3.16"

  executable nixfmt:
    discard
"""

proc recipeRoot(withManifest = true;
                extraFiles: seq[(string, string)] = @[]): string =
  result = createTempDir("repro-fsc-", "")
  writeFile(result / "repro.nim", RecipeText)
  if withManifest:
    # Recognition only checks that the file EXISTS -- the positive statement
    # that the closure was pinned; emission parses it.
    writeFile(result / "hackage-vendor.manifest",
      "# repro hackage vendor manifest v1\n")
  for (name, content) in extraFiles:
    writeFile(result / name, content)

proc registerRecipe(deps: seq[string]; withFetch = true) =
  resetDslPortFetchState()
  resetDslPortPackageDepsState()
  if withFetch:
    registerFetchSpec("nixfmtSource",
      "https://github.com/NixOS/nixfmt/archive/refs/tags/v1.2.0.tar.gz",
      "", dshaSha256,
      "2b148abdf3c2ae9fca2b5898709cde5e4474e09cb32b892da51651c479f1f73a",
      dfkTarball, 1, "")
  for constraint in deps:
    registerPackageDep("nixfmtSource", "native", constraint)

let cabalConvention = fromSourceCabalConvention()
let request = ProviderGraphRequest()

proc claims(deps: seq[string]; withFetch = true; withManifest = true;
            extraFiles: seq[(string, string)] = @[]): bool =
  let root = recipeRoot(withManifest, extraFiles)
  defer:
    try: removeDir(root) except CatchableError: discard
  registerRecipe(deps, withFetch)
  cabalConvention.recognize(root, request)

suite "from-source-cabal recognition":
  test "a fetched cabal recipe with a pinned closure is claimed":
    check claims(@["ghc >=9.12", "cabal >=3.16"])

  test "the version constraint does not hide the driver":
    check claims(@["ghc", "cabal>=3.16"])

  test "a recipe with no fetch spec is declined":
    check (not claims(@["ghc", "cabal"], withFetch = false))

  test "a recipe that does not name cabal is declined":
    # `ghc` alone is not the discriminator: a recipe could drive ghc
    # directly, and this convention's vendor step would pin a closure
    # nothing consumes.
    check (not claims(@["ghc >=9.12"]))

  test "a recipe also driving node is left to its sibling":
    check (not claims(@["cabal", "node >=20"]))

  test "a recipe with no committed closure manifest is declined":
    check (not claims(@["ghc", "cabal"], withManifest = false))

  test "a root .cabal file means an in-tree package":
    check (not claims(@["ghc", "cabal"],
      extraFiles = @[("hello.cabal", "name: hello\n")]))

  test "a root cabal.project means an in-tree project":
    check (not claims(@["ghc", "cabal"],
      extraFiles = @[("cabal.project", "packages: .\n")]))
