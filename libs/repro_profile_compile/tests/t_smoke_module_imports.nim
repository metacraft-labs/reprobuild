## M83 Phase F1 smoke tests for the sibling-module resolution path.
##
## These tests live next to the other `repro_profile_compile/`
## smoke tests because the module-resolution machinery is owned by
## `repro_profile_compile/sources.nim` (the source-discovery walker
## + digest) and exercised end-to-end by the `compileProfileBinary`
## proc that the helper subcommand drives.
##
## Coverage:
##
##   - A `home.nim` that imports a single sibling module compiles
##     successfully through `compileProfileBinary` and emits a JSON
##     `ProfileIntent` that includes the helper's contribution.
##   - A sibling module that itself imports another sibling
##     compiles successfully (transitive import resolution works).
##   - A module that exports a proc returning `seq[ActivityElement]`
##     splats correctly into an activity body via the M83 Phase F1
##     "splat" macro convention.
##   - A module-author error (e.g. a template body that does not
##     type-check) surfaces a clean Nim diagnostic via
##     `CompileFailure.stderrText` instead of a silent failure.
##   - The source digest covers EVERY transitively-imported module;
##     touching a deeply-nested leaf invalidates the digest.
##
## Each test compiles its profile on the fly via the same
## `compileProfileBinary` proc the production helper subcommand
## uses, so the tests guard the real code path.

import std/[json, os, strutils, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_profile_compile

# ---------------------------------------------------------------------------
# Tiny helpers.
# ---------------------------------------------------------------------------

# Compile-time anchor: this file lives at
# `libs/repro_profile_compile/tests/t_smoke_module_imports.nim`, so the
# project root is three `parentDir` hops up. We use this instead of
# `reprobuildRepoRoot()` because the latter's compile-time fallback is
# computed against a different file's depth in the tree and would
# overshoot from a test's perspective; in production callers always
# pass `repoRoot` explicitly through `ProfileCompileOptions`.
const ProjectRoot = currentSourcePath().parentDir.parentDir.parentDir.
  parentDir

proc writeProfileFile(dir, relPath, body: string): string =
  result = dir / relPath
  let parent = result.parentDir
  if not dirExists(extendedPath(parent)):
    createDir(extendedPath(parent))
  writeFile(extendedPath(result), body)

proc compileExample(dir, relProfile: string):
    tuple[jsonOutput: string; binary: string] =
  let profile = dir / relProfile
  let nimcache = dir / "nimcache"
  let exeName =
    when defined(windows): "profile.exe"
    else: "profile"
  let bin = dir / exeName
  let res = compileProfileBinary(profile, nimcache, bin, ProjectRoot)
  result.jsonOutput = res.jsonOutput
  result.binary = bin

proc countPackageRefs(j: JsonNode; activityName: string): int =
  for act in j["activities"]:
    if act["name"].getStr() == activityName:
      for el in act["body"]:
        if el["kind"].getStr() == "packageRef":
          inc result
      return result

proc packageNames(j: JsonNode; activityName: string): seq[string] =
  for act in j["activities"]:
    if act["name"].getStr() == activityName:
      for el in act["body"]:
        if el["kind"].getStr() == "packageRef":
          result.add(el["name"].getStr())
      return result

# ---------------------------------------------------------------------------
# 1. Single sibling-module import — splat composition.
# ---------------------------------------------------------------------------

const SimpleHomeNim = """
import repro_profile
import ./modules/single_helper

profile "smokeSingle":
  activity default:
    singleHelperBundle()
"""

const SimpleHelperNim = """
import repro_profile

proc singleHelperBundle*(): seq[ActivityElement] =
  @[
    package "alpha",
    package "beta",
  ]
"""

suite "M83 Phase F1: single sibling-module compile":

  test "home.nim importing one sibling compiles successfully":
    let dir = createTempDir("repro-m83-f1-single-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    discard writeProfileFile(dir, "home.nim", SimpleHomeNim)
    discard writeProfileFile(dir, "modules/single_helper.nim",
      SimpleHelperNim)
    let res = compileExample(dir, "home.nim")
    let j = parseJson(res.jsonOutput.strip())
    check j["name"].getStr() == "smokeSingle"
    check countPackageRefs(j, "default") == 2

  test "single-import splat inlines every returned element":
    let dir = createTempDir("repro-m83-f1-single-splat-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    discard writeProfileFile(dir, "home.nim", SimpleHomeNim)
    discard writeProfileFile(dir, "modules/single_helper.nim",
      SimpleHelperNim)
    let res = compileExample(dir, "home.nim")
    let j = parseJson(res.jsonOutput.strip())
    let names = packageNames(j, "default")
    check "alpha" in names
    check "beta" in names

  test "discoverProfileSources finds the single sibling module":
    let dir = createTempDir("repro-m83-f1-single-disc-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    discard writeProfileFile(dir, "home.nim", SimpleHomeNim)
    discard writeProfileFile(dir, "modules/single_helper.nim",
      SimpleHelperNim)
    let sources = discoverProfileSources(dir / "home.nim")
    check sources.len == 2
    var found = false
    for s in sources:
      if s.endsWith("single_helper.nim"):
        found = true
    check found

# ---------------------------------------------------------------------------
# 2. Transitive sibling imports — a module importing another module.
# ---------------------------------------------------------------------------

const TransitiveHomeNim = """
import repro_profile
import ./modules/outer

profile "smokeTransitive":
  activity default:
    outerBundle()
"""

const TransitiveOuterNim = """
import repro_profile
import ./inner

proc outerBundle*(): seq[ActivityElement] =
  result = innerBundle()
  result.add package("outer-pkg")
"""

const TransitiveInnerNim = """
import repro_profile

proc innerBundle*(): seq[ActivityElement] =
  @[
    package "inner-pkg",
  ]
"""

suite "M83 Phase F1: transitive sibling-module compile":

  test "module importing another module compiles successfully":
    let dir = createTempDir("repro-m83-f1-trans-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    discard writeProfileFile(dir, "home.nim", TransitiveHomeNim)
    discard writeProfileFile(dir, "modules/outer.nim",
      TransitiveOuterNim)
    discard writeProfileFile(dir, "modules/inner.nim",
      TransitiveInnerNim)
    let res = compileExample(dir, "home.nim")
    let j = parseJson(res.jsonOutput.strip())
    check j["name"].getStr() == "smokeTransitive"
    let names = packageNames(j, "default")
    check "inner-pkg" in names
    check "outer-pkg" in names

  test "discoverProfileSources walks the transitive closure":
    let dir = createTempDir("repro-m83-f1-trans-disc-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    discard writeProfileFile(dir, "home.nim", TransitiveHomeNim)
    discard writeProfileFile(dir, "modules/outer.nim",
      TransitiveOuterNim)
    discard writeProfileFile(dir, "modules/inner.nim",
      TransitiveInnerNim)
    let sources = discoverProfileSources(dir / "home.nim")
    check sources.len == 3
    var hasInner, hasOuter = false
    for s in sources:
      if s.endsWith("inner.nim"): hasInner = true
      if s.endsWith("outer.nim"): hasOuter = true
    check hasInner
    check hasOuter

# ---------------------------------------------------------------------------
# 3. Activity-body splat composes multiple helper calls.
# ---------------------------------------------------------------------------

const MultiSplatHomeNim = """
import repro_profile
import ./modules/multi_a
import ./modules/multi_b

profile "smokeMulti":
  activity default:
    multiABundle()
    multiBBundle()
    inlineExtra
"""

const MultiAHelperNim = """
import repro_profile

proc multiABundle*(): seq[ActivityElement] =
  @[
    package "a-one",
    package "a-two",
  ]
"""

const MultiBHelperNim = """
import repro_profile

proc multiBBundle*(): seq[ActivityElement] =
  @[
    package "b-one",
  ]
"""

# NOTE: bare identifiers in an activity body must be valid Nim
# identifiers; package names with hyphens are passed as string
# literals (the macro's nnkStrLit branch handles them). The helper
# return values are strings so they may contain any characters.

suite "M83 Phase F1: activity-body splat composition":

  test "multiple splat calls + bare idents compose in order":
    let dir = createTempDir("repro-m83-f1-multi-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    discard writeProfileFile(dir, "home.nim", MultiSplatHomeNim)
    discard writeProfileFile(dir, "modules/multi_a.nim",
      MultiAHelperNim)
    discard writeProfileFile(dir, "modules/multi_b.nim",
      MultiBHelperNim)
    let res = compileExample(dir, "home.nim")
    let j = parseJson(res.jsonOutput.strip())
    let names = packageNames(j, "default")
    # Splat order: A's two, B's one, then the bare ident.
    check names == @["a-one", "a-two", "b-one", "inlineExtra"]

# ---------------------------------------------------------------------------
# 4. Module-author error surfaces a clean Nim diagnostic.
# ---------------------------------------------------------------------------

const BrokenHomeNim = """
import repro_profile
import ./modules/broken

profile "smokeBroken":
  activity default:
    brokenBundle()
"""

const BrokenHelperNim = """
import repro_profile

proc brokenBundle*(): seq[ActivityElement] =
  ## Type-error: returns a seq[int] but the signature says
  ## seq[ActivityElement]. The compile must fail with a clean Nim
  ## diagnostic, not a silent bad-bytes outcome.
  @[1, 2, 3]
"""

suite "M83 Phase F1: module-author error surfaces cleanly":

  test "bad helper body raises CompileFailure with nim diagnostics":
    let dir = createTempDir("repro-m83-f1-broken-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    discard writeProfileFile(dir, "home.nim", BrokenHomeNim)
    discard writeProfileFile(dir, "modules/broken.nim",
      BrokenHelperNim)
    let profile = dir / "home.nim"
    let nimcache = dir / "nimcache"
    let exeName =
      when defined(windows): "profile.exe"
      else: "profile"
    let bin = dir / exeName
    var caught = false
    var diag = ""
    try:
      discard compileProfileBinary(profile, nimcache, bin, ProjectRoot)
    except CompileFailure as err:
      caught = true
      diag = err.stderrText
    check caught
    # The Nim diagnostic must mention the module-author's source
    # file so the user knows where to look — the error is reported
    # against `broken.nim`, not the macro library.
    check "broken" in diag

# ---------------------------------------------------------------------------
# 5. Source-digest covers the transitive closure.
# ---------------------------------------------------------------------------

suite "M83 Phase F1: source digest covers the closure":

  test "touching a leaf module changes the source digest":
    let dir = createTempDir("repro-m83-f1-digest-leaf-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    discard writeProfileFile(dir, "home.nim", TransitiveHomeNim)
    discard writeProfileFile(dir, "modules/outer.nim",
      TransitiveOuterNim)
    let leafPath = writeProfileFile(dir, "modules/inner.nim",
      TransitiveInnerNim)

    let sourcesBefore = discoverProfileSources(dir / "home.nim")
    let before = computeProfileDigest(sourcesBefore, dir)

    var contents = readFile(extendedPath(leafPath))
    contents.add("\n## touch leaf to perturb digest\n")
    writeFile(extendedPath(leafPath), contents)

    let sourcesAfter = discoverProfileSources(dir / "home.nim")
    let after = computeProfileDigest(sourcesAfter, dir)
    check before.digestHex != after.digestHex

  test "touching outer module also changes the source digest":
    let dir = createTempDir("repro-m83-f1-digest-outer-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    discard writeProfileFile(dir, "home.nim", TransitiveHomeNim)
    let outerPath = writeProfileFile(dir, "modules/outer.nim",
      TransitiveOuterNim)
    discard writeProfileFile(dir, "modules/inner.nim",
      TransitiveInnerNim)

    let before = computeProfileDigest(
      discoverProfileSources(dir / "home.nim"), dir)

    var contents = readFile(extendedPath(outerPath))
    contents.add("\n## touch outer to perturb digest\n")
    writeFile(extendedPath(outerPath), contents)

    let after = computeProfileDigest(
      discoverProfileSources(dir / "home.nim"), dir)
    check before.digestHex != after.digestHex

  test "digest is stable across re-reads of unchanged sources":
    let dir = createTempDir("repro-m83-f1-digest-stable-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    discard writeProfileFile(dir, "home.nim", TransitiveHomeNim)
    discard writeProfileFile(dir, "modules/outer.nim",
      TransitiveOuterNim)
    discard writeProfileFile(dir, "modules/inner.nim",
      TransitiveInnerNim)
    let sources = discoverProfileSources(dir / "home.nim")
    let d1 = computeProfileDigest(sources, dir)
    let d2 = computeProfileDigest(sources, dir)
    check d1.digestHex == d2.digestHex
    check d1.manifest == d2.manifest

  test "digest manifest lists every module in the closure":
    let dir = createTempDir("repro-m83-f1-digest-manifest-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    discard writeProfileFile(dir, "home.nim", TransitiveHomeNim)
    discard writeProfileFile(dir, "modules/outer.nim",
      TransitiveOuterNim)
    discard writeProfileFile(dir, "modules/inner.nim",
      TransitiveInnerNim)
    let sources = discoverProfileSources(dir / "home.nim")
    let digest = computeProfileDigest(sources, dir)
    var paths: seq[string]
    for line in digest.manifest.strip().splitLines():
      let parts = line.split('\t')
      check parts.len == 2
      paths.add(parts[0])
    check "home.nim" in paths
    check "modules/outer.nim" in paths or
      "modules\\outer.nim" in paths
    check "modules/inner.nim" in paths or
      "modules\\inner.nim" in paths

# ---------------------------------------------------------------------------
# 6. Single sibling — splat semantics with mixed bare-ident packages.
# ---------------------------------------------------------------------------

const MixedHomeNim = """
import repro_profile
import ./modules/single_helper

profile "smokeMixed":
  activity default:
    leadingPkg
    singleHelperBundle()
    trailingPkg
"""

suite "M83 Phase F1: mixed splat + bare idents":

  test "splat interleaves correctly between bare idents":
    let dir = createTempDir("repro-m83-f1-mixed-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    discard writeProfileFile(dir, "home.nim", MixedHomeNim)
    discard writeProfileFile(dir, "modules/single_helper.nim",
      SimpleHelperNim)
    let res = compileExample(dir, "home.nim")
    let j = parseJson(res.jsonOutput.strip())
    let names = packageNames(j, "default")
    check names == @["leadingPkg", "alpha", "beta", "trailingPkg"]
