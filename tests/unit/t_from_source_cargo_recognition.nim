## What the from-source Cargo convention claims, and what it declines.
##
## Recognition is the part of a convention that goes wrong silently. A
## convention that claims too much steals a project from the sibling that
## understands it; one that claims too little leaves a recipe unbuilt with
## no diagnostic naming the convention that should have taken it. Both
## failures surface far from here, so the contract is asserted directly.
##
## The discriminator is `cargo` in `nativeBuildDeps` plus a registered
## `fetch:` spec. Everything else below is a case where one of those is
## present and the answer is still no.

import std/[os, strutils, tempfiles, unittest]

import repro_project_dsl
import repro_provider_runtime
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_cargo

const RecipeText = """
import repro_project_dsl

package justSource:
  fetch:
    url: "https://static.crates.io/crates/just/just-1.51.0.crate"
    sha256: "1111111111111111111111111111111111111111111111111111111111111111"
    extractStrip: 1

  nativeBuildDeps:
    "cargo >=1.92"
    "rustc >=1.92"

  executable just:
    discard
"""

proc recipeRoot(recipe: string; extraFiles: seq[(string, string)] = @[]):
    string =
  result = createTempDir("repro-fsc-", "")
  writeFile(result / "repro.nim", recipe)
  for (name, content) in extraFiles:
    createDir(result / name.parentDir)
    writeFile(result / name, content)

proc registerRecipe(packageName: string; deps: seq[string];
                    withFetch = true) =
  ## Put the recipe's declarations into the registries recognition reads.
  ##
  ## Recognition runs before the recipe is compiled, so it consults the
  ## registries the DSL populates rather than the recipe object — which is
  ## why a test has to populate them the same way.
  resetDslPortFetchState()
  resetDslPortPackageDepsState()
  if withFetch:
    registerFetchSpec(packageName,
      "https://static.crates.io/crates/just/just-1.51.0.crate", "",
      dshaSha256,
      "1111111111111111111111111111111111111111111111111111111111111111",
      dfkTarball, 1, "")
  for constraint in deps:
    registerPackageDep(packageName, "native", constraint)

let cargoConvention = fromSourceCargoConvention()
let request = ProviderGraphRequest()

suite "from-source-cargo recognition":
  test "a fetched cargo recipe is claimed":
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("justSource", @["cargo >=1.92", "rustc >=1.92"])
    check cargoConvention.recognize(root, request)

  test "the version constraint does not hide the driver":
    # `nativeBuildDeps` entries carry constraints. Matching the whole
    # string would recognise only the unconstrained spelling, and a recipe
    # that pinned its cargo would fall through to whichever sibling claimed
    # it next.
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("justSource", @["cargo>=1.92"])
    check cargoConvention.recognize(root, request)

  test "a recipe with no fetch spec is declined":
    # Without a fetch there is no source to vendor against, and the recipe
    # is an in-tree project the `rust` convention builds in place.
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("justSource", @["cargo >=1.92"], withFetch = false)
    check (not cargoConvention.recognize(root, request))

  test "a recipe that does not name cargo is declined":
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("justSource", @["rustc >=1.92"])
    check (not cargoConvention.recognize(root, request))

  test "a recipe driving make is left to its sibling":
    # A Makefile wrapping cargo is a from-source-make recipe: the Makefile
    # is what runs, and this convention's vendor step would pin a closure
    # nothing consumes.
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("justSource", @["cargo >=1.92", "make >=4.3"])
    check (not cargoConvention.recognize(root, request))

  test "a root Cargo.toml means an in-tree workspace, not a from-source recipe":
    # A from-source recipe's Cargo.toml arrives inside the fetched tarball,
    # under `src/`, so it is never at the root when recognition runs. One
    # that IS at the root is a workspace the `rust` convention builds in
    # place.
    let root = recipeRoot(RecipeText,
      @[("Cargo.toml", "[package]\nname = \"x\"\n")])
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("justSource", @["cargo >=1.92"])
    check (not cargoConvention.recognize(root, request))

  test "a recipe declaring no members is declined":
    # Nothing to stage means nothing this convention can produce.
    let memberless = RecipeText.replace(
      "  executable just:\n    discard\n", "")
    let root = recipeRoot(memberless)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("justSource", @["cargo >=1.92"])
    check (not cargoConvention.recognize(root, request))

  test "a commented-out member does not count":
    # The member scan is a text scan, because recognition runs before the
    # recipe is compiled. Comment stripping is what keeps that honest.
    let commented = RecipeText.replace(
      "  executable just:", "  # executable just:")
    let root = recipeRoot(commented)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("justSource", @["cargo >=1.92"])
    check (not cargoConvention.recognize(root, request))
