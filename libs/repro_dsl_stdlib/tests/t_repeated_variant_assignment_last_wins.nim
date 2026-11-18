## A variant assigned twice on the command line has one value, the last, for
## every reader of `REPRO_VARIANTS`.
##
## CLI/build.md §"Cross Targets: `--target`": `--target=<triple>` writes the
## same `targetTriple=` assignment `--variant` does, after the `--variant`
## ones, and "a command line that assigns `targetTriple` more than once builds
## for the last assignment". Configurable-System.md §"Priorities And
## Contributions" is the rule underneath: at equal priority (every
## `REPRO_VARIANTS` entry is `prSet`) a scalar's last write wins.
##
## Four readers had to agree and did not (reprobuild-pm issue
## `2026-11-17-two-readers-of-repro-variants-disagree-on-a-repeated-target-triple`):
##
## - `toolchain_policy.targetTripleFromEnv`, the stdlib's fallback for a recipe
##   that never declared `targetTriple`, took the FIRST assignment;
## - `operations/buildtype.currentBuildType`'s env fallback took the FIRST;
## - the solver received BOTH as `set` contributions of equal weight, so which
##   one a declared variant resolved to was clingo's tie-break, not the command
##   line's;
## - `target_object_check.objectCheckTripleFromVariants`, which holds the
##   build's published objects to a triple, took the LAST;
## - `install_mirror_resolver.activeTargetTripleTag`, which names the install
##   mirror (`install@<triple>`) and the platform of a source-built package's
##   cache identity, took the FIRST;
## - the lowered-graph and nimcache keys (`canonicalVariantAssignments`,
##   `activeVariantSignature`) sorted the raw entries, so `--release --debug`
##   and `--debug --release` shared a key although they are different builds.
##
## So `repro build --variant targetTriple=A --target=B` built for `A` and
## checked the outputs against `B`. Every case below puts the two assignments
## in one env value, the shape that command line produces.
##
## Test-double policy: NO mocks, doubles, or fakes. The env is the real
## transport the CLI writes; the solver half reads the real rendered solver
## inputs (`currentSolverInputsFixture`, the text `inputsDigest` is taken over),
## because the defect is in what the solver is FED -- two equal-weight `set`
## values -- and a solve alone would make the red half depend on clingo's
## tie-break. One case also runs the real clingo solve through the real
## `finalizeVariants()`, so the green half is the solved answer itself.

import std/[os, strutils, tables, unittest]

import repro_core/target_object_check
import repro_core/variant_assignments
import repro_project_dsl/install_mirror_resolver
import repro_dsl_stdlib/configurables/api
import repro_dsl_stdlib/configurables/variants
import repro_dsl_stdlib/configurables/types
import repro_dsl_stdlib/operations/buildtype
import repro_dsl_stdlib/toolchain_policy

const
  First = "riscv64-unknown-linux-gnu"
  Last = "armv7-unknown-linux-musleabihf"
  Twice = "targetTriple=" & First & ",buildType=release,targetTriple=" & Last

template withVariantsEnv(value: string; body: untyped) =
  let saved = getEnv("REPRO_VARIANTS")
  let wasSet = existsEnv("REPRO_VARIANTS")
  putEnv("REPRO_VARIANTS", value)
  resetVariantState()
  try:
    body
  finally:
    resetVariantState()
    if wasSet: putEnv("REPRO_VARIANTS", saved)
    else: delEnv("REPRO_VARIANTS")

proc variantBlock(fixture, name: string): string =
  ## The rendered block for `variant <name>`, up to the next blank line.
  var collecting = false
  for line in fixture.splitLines():
    if line.startsWith("variant "):
      collecting = line.strip() == "variant " & name
      if collecting:
        result.add(line & "\n")
      continue
    if collecting:
      if line.len == 0 or line.startsWith("package "):
        return
      result.add(line & "\n")

suite "a repeated targetTriple assignment: the last one wins everywhere":

  test "the stdlib's fallback reader takes the last assignment":
    withVariantsEnv(Twice):
      check targetTripleFromEnv() == Last

  test "the object check takes the same assignment as the build":
    withVariantsEnv(Twice):
      check objectCheckTripleFromVariants(getEnv("REPRO_VARIANTS")) == Last
      check objectCheckTripleFromVariants(getEnv("REPRO_VARIANTS")) ==
        targetTripleFromEnv()

  test "the solver is fed one set contribution, the last":
    withVariantsEnv(Twice):
      discard variantImpl[string]("native", "targetTriple",
        captureSite(ckDefault))
      let triple = variantBlock(currentSolverInputsFixture(), "targetTriple")
      check triple.len > 0
      check ("set: " & Last) in triple
      check ("set: " & First) notin triple

  test "the install mirror and cache identity name the last assignment":
    withVariantsEnv(Twice):
      check activeTargetTripleTag() == Last
      check installMirrorSubpath().endsWith(InstallMirrorTargetSeparator & Last)

  test "a declared targetTriple solves to the last assignment":
    withVariantsEnv(Twice):
      discard variantImpl[string]("native", "targetTriple",
        captureSite(ckDefault))
      finalizeVariants()
      check hasSolverSolution()
      check lastSolverSolution().variants["targetTriple"] == Last

  test "a single assignment is unchanged":
    withVariantsEnv("targetTriple=" & Last):
      check targetTripleFromEnv() == Last
    withVariantsEnv("buildType=release"):
      check targetTripleFromEnv() == ""

suite "the rule is the variant's, not targetTriple's":

  test "buildType's env fallback takes the last assignment":
    withVariantsEnv("buildType=release,buildType=debug"):
      check currentBuildType() == btDebug
    withVariantsEnv("buildType=debug,buildType=release"):
      check currentBuildType() == btRelease

  test "the cache keys name the assignment in force, not the raw entries":
    let releaseThenDebug = "buildType=release,buildType=debug"
    let debugThenRelease = "buildType=debug,buildType=release"
    check canonicalVariantAssignmentsOf(releaseThenDebug) == "buildType=debug"
    check canonicalVariantAssignmentsOf(debugThenRelease) == "buildType=release"
    check canonicalVariantAssignmentsOf(Twice) ==
      "buildType=release,targetTriple=" & Last
    # Unrepeated names: the sorted, de-duplicated form keys always had.
    check canonicalVariantAssignmentsOf("b=2,a=1,b=2") == "a=1,b=2"
    check canonicalVariantAssignmentsOf("") == ""

  test "a later addVariantCliOverride replaces an earlier one":
    withVariantsEnv(""):
      addVariantCliOverride("targetTriple", First)
      addVariantCliOverride("targetTriple", Last)
      var values: seq[string]
      for entry in pendingVariantCliOverrides():
        if entry.name == "targetTriple":
          values.add(entry.value)
      check values == @[Last]

  test "an explicit override is not replaced by the env parsed after it":
    withVariantsEnv("targetTriple=" & First):
      addVariantCliOverride("targetTriple", Last)
      discard variantImpl[string]("native", "targetTriple",
        captureSite(ckDefault))
      let triple = variantBlock(currentSolverInputsFixture(), "targetTriple")
      check ("set: " & Last) in triple
      check ("set: " & First) notin triple
