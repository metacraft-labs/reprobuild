## The vendor emitters report the committed files they read as inputs of
## the graph evaluation.
##
## `emitNpmVendorAction` reads `npm-build-closure.manifest` and the optional
## committed lock at emission time and bakes what it read into the action's
## program (its up-to-date token and archive count); `emitCargoVendorAction`
## bakes the manifest's git sources into the `.cargo/config.toml` it writes.
## The action declaring the file as an input does not help: the action
## re-runs, but the program it runs is the one emitted for the OLD content.
## Only an evaluation input invalidates the cached provider graph, so the
## engine re-invokes the provider and a new program is emitted.
##
## Observed before the fix (reprobuild-specs issue "The vendor emitters read
## their closure manifest without reporting it as an evaluation input"):
## replacing a 100-entry manifest with a 1464-entry one, `repro.nim`
## untouched, built with `providerInvocations: 0`; the vendor step reported
## its private cache up to date and left 96 of 1340 archives.
##
## Each case drives a real `buildPackageFragment` (directly, as a recipe's
## `build:` block does, or through the from-source convention) and then
## applies the engine's staleness rule to the fragment's `evaluationInputs`:
## a `gevFileRead` input is stale when the file's content digest moved.

import std/[os, strutils, tempfiles, unittest]

import repro_core/cargo_lock
import repro_project_dsl
import repro_project_dsl/cargo_vendor
import repro_project_dsl/npm_vendor
import repro_provider_runtime
import repro_standard_provider/conventions/from_source_cargo
import repro_standard_provider/conventions/from_source_npm

const
  NpmManifestA = "# fixture closure\n" &
    "node_modules/a 73cb3858a687a8494ca3323053016282f3dad39d42cf62ca4e79dda2aac7d9ac " &
    "https://registry.npmjs.org/a/-/a-1.0.0.tgz\n"
  NpmManifestB = NpmManifestA &
    "node_modules/b 73cb3858a687a8494ca3323053016282f3dad39d42cf62ca4e79dda2aac7d9ac " &
    "https://registry.npmjs.org/b/-/b-1.0.0.tgz\n"
  CargoManifestA = "# repro cargo vendor manifest v1\n" &
    "https://static.crates.io/crates/camino/camino-1.1.9.crate\t" &
    "8b96ec4966b5813e2c0507c1f86115c8c5abaadc3980879c3424042a02fd1ad3\t" &
    "camino-1.1.9\n"
  CargoManifestB = CargoManifestA &
    "git\tgit+https://github.com/dylanhart/ulid-rs?tag=v1.1.3#" &
    "a33a00f8dadbade0fd55b82ccb392589b7e3006d\t.\tulid-1.1.3\n"
  CargoGitSourceBlock =
    "[source.\"git+https://github.com/dylanhart/ulid-rs?tag=v1.1.3\"]"
  FakeSha256 =
    "1111111111111111111111111111111111111111111111111111111111111111"
  NpmRecipe = """
import repro_project_dsl

package probeNpm:
  fetch:
    url: "https://example.invalid/probe-1.0.0.tar.gz"
    sha256: "1111111111111111111111111111111111111111111111111111111111111111"
    extractStrip: 1

  nativeBuildDeps:
    "node >=20"
    "npm >=10"

  executable probe:
    discard
"""
  CargoRecipe = """
import repro_project_dsl

package probeCargo:
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

proc recipeRoot(files: openArray[(string, string)]): string =
  result = createTempDir("repro-vendor-inputs-", "")
  for (name, content) in files:
    writeFile(result / name, content)

proc requestFor(root: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "probe.root",
    entryPointBodyHash: "probe.build.v1",
    reason: girExplicitUserRequest,
    arguments: root,
    namespace: "project-probe")

proc probePackage(root: string): PackageDef =
  PackageDef(packageName: "probe", sourceFile: root / "repro.nim")

proc fileReads(fragment: GraphFragment): seq[string] =
  for input in fragment.evaluationInputs:
    if input.kind == gevFileRead:
      result.add(input.identity)

proc stale(fragment: GraphFragment): bool =
  ## The engine's rule for a `gevFileRead` evaluation input
  ## (`providerSnapshotInputsFresh`, `detectEvaluationInputChanges`).
  for input in fragment.evaluationInputs:
    if input.kind == gevFileRead and
        fileContentDigest(input.identity) != input.digest:
      return true
  false

proc scriptOf(fragment: GraphFragment; actionPrefix: string): string =
  ## The emitted program of the first action whose stable name starts with
  ## `actionPrefix`, as it travels in the fragment.
  for node in fragment.nodes:
    if node.kind == gnkAction and node.stableName.startsWith(actionPrefix):
      return node.payload
  ""

proc registerFetch(packageName, url: string; nativeDeps: openArray[string]) =
  resetDslPortFetchState()
  resetDslPortPackageDepsState()
  registerFetchSpec(packageName, url, "", dshaSha256, FakeSha256,
    dfkTarball, 1, "")
  for constraint in nativeDeps:
    registerPackageDep(packageName, "native", constraint)

suite "vendor manifests are evaluation inputs":
  test "npm: the manifest and the committed lock are reported":
    let root = recipeRoot([("repro.nim", ""),
      (NpmBuildClosureManifestName, NpmManifestA)])
    defer:
      try: removeDir(root) except CatchableError: discard
    let emit = proc () =
      discard emitNpmVendorAction(root, "probe", "", "")
    let fragment = buildPackageFragment(probePackage(root), requestFor(root),
      emit, includeDefault = false)
    let reads = fileReads(fragment)
    check npmBuildClosureManifestPath(root) in reads
    # Reported although absent: committing one later must invalidate.
    check npmBuildClosureLockPath(root) in reads
    check not stale(fragment)

    # Replacing the manifest, and nothing else, invalidates the graph ...
    writeFile(npmBuildClosureManifestPath(root), NpmManifestB)
    check stale(fragment)
    # ... and the program a re-evaluation emits is a different one, which is
    # why reusing the old graph ran the wrong program.
    let refreshed = buildPackageFragment(probePackage(root),
      requestFor(root), emit, includeDefault = false)
    check not stale(refreshed)
    check scriptOf(refreshed, "npm-vendor-") != scriptOf(fragment, "npm-vendor-")

    # So does committing a lock.
    writeFile(npmBuildClosureLockPath(root), "{}\n")
    check stale(refreshed)

  test "npm: the from-source convention's fragment reports the manifest":
    let root = recipeRoot([("repro.nim", NpmRecipe),
      (NpmBuildClosureManifestName, NpmManifestA)])
    defer:
      try: removeDir(root) except CatchableError: discard
    registerFetch("probeNpm", "https://example.invalid/probe-1.0.0.tar.gz",
      ["node >=20", "npm >=10"])
    let convention = fromSourceNpmConvention()
    check convention.recognize(root, requestFor(root))
    let fragment = convention.emitFragment(root, requestFor(root))
    check npmBuildClosureManifestPath(root) in fileReads(fragment)
    check not stale(fragment)
    writeFile(npmBuildClosureManifestPath(root), NpmManifestB)
    check stale(fragment)

  test "cargo: the manifest is reported, and a new git source invalidates":
    let root = recipeRoot([("repro.nim", ""),
      (CargoVendorManifestName, CargoManifestA)])
    defer:
      try: removeDir(root) except CatchableError: discard
    let emit = proc () =
      # The constructor's shape: read the manifest, then emit from it.
      discard emitCargoVendorAction(root, "probe", readVendorManifest(root),
        "", "")
    let fragment = buildPackageFragment(probePackage(root), requestFor(root),
      emit, includeDefault = false)
    check cargoVendorManifestPath(root) in fileReads(fragment)
    check not stale(fragment)
    check not scriptOf(fragment, "cargo-vendor-").contains(CargoGitSourceBlock)

    # A git source added to the manifest reaches the config only through a
    # re-evaluation: the old program writes the old config, and cargo goes
    # to the network for the new source.
    writeFile(cargoVendorManifestPath(root), CargoManifestB)
    check stale(fragment)
    let refreshed = buildPackageFragment(probePackage(root),
      requestFor(root), emit, includeDefault = false)
    check scriptOf(refreshed, "cargo-vendor-").contains(CargoGitSourceBlock)

  test "cargo: the convention reports the manifest it read before the reset":
    # The convention reads the manifest BEFORE `buildPackageFragment` resets
    # the input registry, so the report has to come from the emitter, which
    # runs inside the evaluation.
    let root = recipeRoot([("repro.nim", CargoRecipe),
      (CargoVendorManifestName, CargoManifestA)])
    defer:
      try: removeDir(root) except CatchableError: discard
    registerFetch("probeCargo",
      "https://static.crates.io/crates/just/just-1.51.0.crate",
      ["cargo >=1.92", "rustc >=1.92"])
    let convention = fromSourceCargoConvention()
    check convention.recognize(root, requestFor(root))
    let fragment = convention.emitFragment(root, requestFor(root))
    check cargoVendorManifestPath(root) in fileReads(fragment)
    check not stale(fragment)
    writeFile(cargoVendorManifestPath(root), CargoManifestB)
    check stale(fragment)
