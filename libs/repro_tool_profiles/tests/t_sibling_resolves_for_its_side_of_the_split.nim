## A sibling source recipe resolves for its side of the host/target split.
##
## ReproOS-Add-On-Mode A15 / From-Source-Build-Recipes.md §"Package-level
## dependency declarations": under `repro build --target=<triple>` a
## consumer's `buildDeps:` resolve to the sibling's TARGET build (its
## `.repro/output/install@<triple>` mirror) and a `nativeBuildDeps:` entry to
## the sibling's NATIVE build, because the former is linked into the output
## and the latter runs on the build host. Without `--target` both read the
## native mirror. And the recipes root of a catalog checkout is the checkout
## itself, not a sibling checkout of the catalog (reprobuild-pm issue
## 2026-10-30-sibling-source-recipes-resolve-only-for-non-native-deps-in-two-
## modes).
##
## Nothing is mocked: a real recipes root is laid out in a temporary
## directory with one sibling recipe and its two mirrors, and the production
## resolver is asked.

import std/[os, strutils, unittest]

import repro_interface_artifacts
import repro_tool_profiles

const Triple = "armv7-unknown-linux-musleabihf"

proc withVariants(value: string; body: proc()) =
  let saved = getEnv("REPRO_VARIANTS")
  if value.len > 0: putEnv("REPRO_VARIANTS", value) else: delEnv("REPRO_VARIANTS")
  try: body()
  finally:
    if saved.len > 0: putEnv("REPRO_VARIANTS", saved) else: delEnv("REPRO_VARIANTS")

proc layOutSibling(recipes: string): string =
  ## `<recipes>/openssl` with a native and a target mirror, each holding an
  ## executable `openssl` whose text says which it is.
  let dir = recipes / "openssl"
  createDir(dir)
  writeFile(dir / "repro.nim", "# the sibling recipe\n")
  for (subpath, tag) in [(".repro/output/install", "native"),
                         (".repro/output/install@" & Triple, "target")]:
    let bin = dir / subpath / "usr" / "bin"
    createDir(bin)
    writeFile(bin / "openssl", "#!/bin/sh\necho " & tag & "\n")
    setFilePermissions(bin / "openssl", {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  dir

proc dep(kind: string): InterfaceToolUse =
  InterfaceToolUse(packageSelector: "openssl", executableName: "openssl",
                   rawConstraint: "openssl >=3.0", depKind: kind)

suite "a sibling resolves for its side of the split":
  let tmp = getTempDir() / ("t_sibling_split_" & $getCurrentProcessId())
  let recipes = tmp / "packages" / "source"
  createDir(recipes)
  discard layOutSibling(recipes)
  defer: removeDir(tmp)

  test "without a target both sides read the native mirror":
    withVariants("", proc() =
      for kind in ["build", "native", "runtime"]:
        let r = tryResolveFromSourceTool(dep(kind), recipes,
          hostSide = kind == "native")
        check r.kind == rrResolved
        check "/.repro/output/install/usr/bin/openssl" in
          r.profile.resolvedExecutablePath)

  test "under --target a library reads the target mirror, a tool the native one":
    withVariants("targetTriple=" & Triple, proc() =
      let lib = tryResolveFromSourceTool(dep("build"), recipes)
      check lib.kind == rrResolved
      check ("/.repro/output/install@" & Triple & "/usr/bin/openssl") in
        lib.profile.resolvedExecutablePath
      let tool = tryResolveFromSourceTool(dep("native"), recipes, hostSide = true)
      check tool.kind == rrResolved
      check "/.repro/output/install/usr/bin/openssl" in
        tool.profile.resolvedExecutablePath
      # The falsifier: the same tool read without `hostSide` is the target
      # build, which cannot run on the build host.
      let wrong = tryResolveFromSourceTool(dep("native"), recipes)
      check ("@" & Triple) in wrong.profile.resolvedExecutablePath)

  test "a sibling whose target build does not exist needs a build":
    withVariants("targetTriple=aarch64-unknown-linux-musl", proc() =
      let r = tryResolveFromSourceTool(dep("build"), recipes)
      check r.kind == rrNeedsBuild)

  test "a catalog checkout is its own recipes root":
    # `<tmp>/packages/source` exists, so a build run from `<tmp>` must find
    # its siblings there, not in `<parent of tmp>/reprobuild-packages/…`.
    check fromSourceRecipeRoot(tmp) == recipes
