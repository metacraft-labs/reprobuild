## What the from-source Go convention claims, and what it declines.
##
## Same contract shape as its cargo sibling, and asserted for the same
## reason: recognition is where a convention goes wrong silently. Claiming
## too much steals a project from the sibling that understands it; claiming
## too little leaves a recipe unbuilt with no diagnostic naming the
## convention that should have taken it.
##
## Two declines are specific to Go and worth pinning. A root `go.mod` means
## a module built in place, which the in-tree convention handles — a
## from-source recipe's `go.mod` arrives inside the fetched tarball. And a
## recipe naming both `go` and `cargo` is ambiguous about which toolchain
## produces the artefact, so it is declined rather than guessed at.

import std/[os, strutils, tempfiles, unittest]

import repro_project_dsl
import repro_provider_runtime
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_go

const RecipeText = """
import repro_project_dsl

package shfmtSource:
  fetch:
    url: "https://github.com/mvdan/sh/archive/refs/tags/v3.12.0.tar.gz"
    sha256: "2222222222222222222222222222222222222222222222222222222222222222"
    extractStrip: 1

  nativeBuildDeps:
    "go >=1.23"

  executable shfmt:
    discard
"""

proc recipeRoot(recipe: string; extraFiles: seq[(string, string)] = @[]):
    string =
  result = createTempDir("repro-fsg-", "")
  writeFile(result / "repro.nim", recipe)
  for (name, content) in extraFiles:
    createDir(result / name.parentDir)
    writeFile(result / name, content)

proc registerRecipe(packageName: string; deps: seq[string];
                    withFetch = true) =
  ## Populate the registries recognition reads.
  ##
  ## Recognition runs before the recipe is compiled, so it consults the
  ## registries the DSL fills rather than the recipe object.
  resetDslPortFetchState()
  resetDslPortPackageDepsState()
  if withFetch:
    registerFetchSpec(packageName,
      "https://github.com/mvdan/sh/archive/refs/tags/v3.12.0.tar.gz", "",
      dshaSha256,
      "2222222222222222222222222222222222222222222222222222222222222222",
      dfkTarball, 1, "")
  for constraint in deps:
    registerPackageDep(packageName, "native", constraint)

let goConvention = fromSourceGoConvention()
let request = ProviderGraphRequest()

suite "from-source-go recognition":
  test "a fetched go recipe is claimed":
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("shfmtSource", @["go >=1.23"])
    check goConvention.recognize(root, request)

  test "the version constraint does not hide the driver":
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("shfmtSource", @["go>=1.23"])
    check goConvention.recognize(root, request)

  test "a recipe with no fetch spec is declined":
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("shfmtSource", @["go >=1.23"], withFetch = false)
    check (not goConvention.recognize(root, request))

  test "a recipe that does not name go is declined":
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("shfmtSource", @["gcc >=11"])
    check (not goConvention.recognize(root, request))

  test "a recipe naming both go and cargo is declined, not guessed at":
    # Which toolchain produces the artefact is not derivable from the
    # declaration, and picking one would make the answer depend on
    # registration order.
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("shfmtSource", @["go >=1.23", "cargo >=1.92"])
    check (not goConvention.recognize(root, request))

  test "a root go.mod means an in-tree module, not a from-source recipe":
    # A from-source recipe's `go.mod` arrives inside the fetched tarball,
    # under `src/`, so it is never at the root when recognition runs. One
    # that IS at the root is a module the in-tree `go` convention builds
    # in place.
    let root = recipeRoot(RecipeText,
      @[("go.mod", "module example.invalid/x\n\ngo 1.23\n")])
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("shfmtSource", @["go >=1.23"])
    check (not goConvention.recognize(root, request))

  test "a recipe declaring no members is declined":
    let memberless = RecipeText.replace(
      "  executable shfmt:\n    discard\n", "")
    let root = recipeRoot(memberless)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("shfmtSource", @["go >=1.23"])
    check (not goConvention.recognize(root, request))

  test "a files-only recipe is claimed":
    # `go build` produces commands, but a Go module packaged for its data
    # alone is still this convention's: there is no `library` member kind
    # here, so `files` is the other thing a recipe can declare.
    let filesOnly = RecipeText.replace(
      "  executable shfmt:", "  files shfmtData:")
    let root = recipeRoot(filesOnly)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("shfmtSource", @["go >=1.23"])
    check goConvention.recognize(root, request)
