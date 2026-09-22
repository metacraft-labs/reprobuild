## What the from-source npm convention claims, and what it declines.
##
## The npm sibling of `t_from_source_cargo_recognition`. Recognition is the
## part of a convention that fails silently — claim too much and a project is
## stolen from the sibling that understands it, claim too little and a recipe
## goes unbuilt with no diagnostic. So the contract is asserted directly.
##
## The discriminators are: a registered `fetch:` spec, `node` in
## `nativeBuildDeps`, a committed `npm-build-closure.manifest` beside the
## recipe, and NO in-tree root `package.json` and no competing from-source
## driver. Every case below flips exactly one and checks the answer.

import std/[os, tempfiles, unittest]

import repro_project_dsl
import repro_provider_runtime
import repro_standard_provider/convention
import repro_standard_provider/conventions/from_source_npm

const RecipeText = """
import repro_project_dsl
import repro_dsl_stdlib/constructors

package geminiCliSource:
  fetch:
    url: "https://github.com/google-gemini/gemini-cli/archive/refs/tags/v0.59.0.tar.gz"
    sha256: "1111111111111111111111111111111111111111111111111111111111111111"
    extractStrip: 1

  nativeBuildDeps:
    "node >=20"
    "npm >=10"

  executable gemini:
    discard
"""

proc recipeRoot(recipe: string; withManifest = true;
                extraFiles: seq[(string, string)] = @[]): string =
  result = createTempDir("repro-fsn-", "")
  writeFile(result / "repro.nim", recipe)
  if withManifest:
    # A one-line stand-in for the real closure manifest — recognition only
    # checks the file EXISTS (the positive statement that a closure was
    # pinned), it does not parse it.
    writeFile(result / "npm-build-closure.manifest",
      "# https://registry.npmjs.org/x/-/x-1.0.0.tgz  sha256:00\n")
  for (name, content) in extraFiles:
    createDir(result / name.parentDir)
    writeFile(result / name, content)

proc registerRecipe(packageName: string; deps: seq[string];
                    withFetch = true) =
  ## Populate the registries recognition reads. Recognition runs before the
  ## recipe is compiled, so it consults these rather than the recipe object.
  resetDslPortFetchState()
  resetDslPortPackageDepsState()
  if withFetch:
    registerFetchSpec(packageName,
      "https://github.com/google-gemini/gemini-cli/archive/refs/tags/v0.59.0.tar.gz",
      "", dshaSha256,
      "1111111111111111111111111111111111111111111111111111111111111111",
      dfkTarball, 1, "")
  for constraint in deps:
    registerPackageDep(packageName, "native", constraint)

let npmConvention = fromSourceNpmConvention()
let request = ProviderGraphRequest()

suite "from-source-npm recognition":
  test "a fetched node recipe with a pinned closure is claimed":
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("geminiCliSource", @["node >=20", "npm >=10"])
    check npmConvention.recognize(root, request)

  test "the version constraint does not hide the driver":
    # `node>=20` with no space must still recognise as the `node` driver;
    # matching the whole string would only claim the unconstrained spelling.
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("geminiCliSource", @["node>=20"])
    check npmConvention.recognize(root, request)

  test "a recipe with no fetch spec is declined":
    # No fetch means no source to vendor; an in-tree JS project is the
    # jsts convention's, not this one's.
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("geminiCliSource", @["node >=20"], withFetch = false)
    check (not npmConvention.recognize(root, request))

  test "a recipe that does not name node is declined":
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("geminiCliSource", @["python3 >=3.11"])
    check (not npmConvention.recognize(root, request))

  test "a recipe also driving cargo is left to its sibling":
    # A recipe naming a competing from-source driver is that driver's; this
    # convention's npm vendor would pin a closure nothing consumes.
    let root = recipeRoot(RecipeText)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("geminiCliSource", @["node >=20", "cargo >=1.94"])
    check (not npmConvention.recognize(root, request))

  test "a recipe with no committed closure manifest is declined":
    # The manifest's ABSENCE is exactly the failure mode this convention
    # exists to prevent: an npm build that resolves only where the registry
    # cache is already warm. No manifest, no claim.
    let root = recipeRoot(RecipeText, withManifest = false)
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("geminiCliSource", @["node >=20"])
    check (not npmConvention.recognize(root, request))

  test "a root package.json means an in-tree project, not a from-source recipe":
    # A from-source recipe's package.json arrives inside the fetched tarball,
    # never at the project root when recognition runs. One that IS at the
    # root is what the in-tree jsts convention builds in place.
    let root = recipeRoot(RecipeText,
      extraFiles = @[("package.json", "{\"name\":\"x\"}\n")])
    defer:
      try: removeDir(root) except CatchableError: discard
    registerRecipe("geminiCliSource", @["node >=20"])
    check (not npmConvention.recognize(root, request))
