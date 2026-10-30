## The install mirror is keyed by the target the build compiles for.
##
## ReproOS-Add-On-Mode A15 / From-Source-Build-Recipes.md §"Package-level
## dependency declarations" ("The install mirror is keyed by the target").
## `repro build --target=<triple>` writes `targetTriple=<triple>` into
## `REPRO_VARIANTS`; under it a recipe's producer staging root, the root a
## consumer's `buildDeps:` resolve to, and the hashed-store sidecar's
## platform tag all carry `@<triple>`, and without it nothing changes --
## the three answer exactly what they answered before the suffix existed.
##
## That last property is the one a recipe corpus of several hundred native
## builds depends on, so it is pinned by value here, not inferred. Nothing
## is mocked: the resolver is pure path arithmetic over the environment.

import std/[os, strutils, unittest]

import repro_project_dsl/install_mirror_resolver

const
  Triple = "armv7-unknown-linux-musleabihf"
  Root = "/recipes"

proc withVariants(value: string; body: proc()) =
  let saved = getEnv("REPRO_VARIANTS")
  if value.len > 0: putEnv("REPRO_VARIANTS", value) else: delEnv("REPRO_VARIANTS")
  try: body()
  finally:
    if saved.len > 0: putEnv("REPRO_VARIANTS", saved) else: delEnv("REPRO_VARIANTS")

suite "install mirror root keyed by the target":

  test "a native build keeps the legacy root, byte for byte":
    withVariants("", proc() =
      check installMirrorSubpath() == ".repro/output/install"
      check activeTargetTripleTag() == ""
      check packageInstallMirrorRoot(Root, "openssl") ==
        "/recipes/openssl/.repro/output/install"
      check packageInstallMirrorStagingRoot(Root, "openssl") ==
        "/recipes/openssl/.repro/output/install"
      check not currentRealizationPlatformTag().contains("@"))

  test "`native` and an unrelated variant are native too":
    withVariants("buildType=release,targetTriple=native", proc() =
      check installMirrorSubpath() == ".repro/output/install")
    withVariants("buildType=release", proc() =
      check installMirrorSubpath() == ".repro/output/install")

  test "a cross build's producer and consumer roots carry the triple":
    withVariants("buildType=release,targetTriple=" & Triple, proc() =
      check activeTargetTripleTag() == Triple
      check installMirrorSubpath() == ".repro/output/install@" & Triple
      # The producer writes where the consumer reads: one rule.
      check packageInstallMirrorStagingRoot(Root, "openssl") ==
        "/recipes/openssl/.repro/output/install@" & Triple
      check packageInstallMirrorRoot(Root, "openssl") ==
        packageInstallMirrorStagingRoot(Root, "openssl")
      check packageInstallMirrorLibDirs(Root, "openssl") ==
        @["/recipes/openssl/.repro/output/install@" & Triple & "/usr/lib",
          "/recipes/openssl/.repro/output/install@" & Triple & "/usr/lib64"]
      check currentRealizationPlatformTag().endsWith("@" & Triple))

  test "the host build and the target build of one recipe are two roots":
    var native, cross: string
    withVariants("", proc() = native = packageInstallMirrorRoot(Root, "openssl"))
    withVariants("targetTriple=" & Triple, proc() =
      cross = packageInstallMirrorRoot(Root, "openssl"))
    check native != cross
    check cross.startsWith(native & "@")
