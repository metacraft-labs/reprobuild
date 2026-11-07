## M83 Phase F1 smoke tests for the sibling-module resolution path.
##
## These tests live next to the other `repro_profile_compile/`
## smoke tests and drive the `compileProfileBinary` proc that the
## helper subcommand runs.
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
##
## Removed with the import-scan freshness key: the cases that asserted the
## `discoverProfileSources` walk and the `computeProfileDigest` digest covered
## the module closure. The property they stood for — editing ANY module in the
## closure, leaf or outer, recompiles the profile — is asserted against the
## monitored edge in `tests/e2e/m83/t_e2e_profile_modules.nim`, from what
## io-mon observed `nim` read rather than from a text walk.
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

const SelfContainedDependencyHomeNim = """
import repro_profile

profile "selfContainedDependencies":
  activity default:
    "dependency-path-smoke"
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

  test "profile compile resolves vendored SSZ dependencies explicitly":
    let dir = createTempDir("repro-m83-f1-dependency-paths-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    discard writeProfileFile(dir, "home.nim",
      SelfContainedDependencyHomeNim)

    # Poison every config.nims environment override in the SSZ dependency
    # closure, plus Nim's global Nimble package root. The spawned compiler
    # must use the repo-local source paths carried by profileNimPaths, not a
    # developer checkout, dev-shell path, or globally installed package that
    # happens to be available on the host.
    const DependencyEnvVars = [
      "NIMBLE_DIR",
      "FASTSTREAMS_SRC",
      "NIM_STEW_SRC",
      "NIM_SERIALIZATION_SRC",
      "NIM_JSON_SERIALIZATION_SRC",
      "SSZ_SERIALIZATION_SRC",
      "RESULTS_SRC",
      "STINT_SRC",
    ]
    var prior: seq[tuple[name, value: string; existed: bool]]
    for name in DependencyEnvVars:
      prior.add((name: name, value: getEnv(name), existed: existsEnv(name)))
      putEnv(name, dir / "missing-" & name.toLowerAscii())
    defer:
      for saved in prior:
        if saved.existed:
          putEnv(saved.name, saved.value)
        else:
          delEnv(saved.name)

    var res: tuple[jsonOutput: string; binary: string]
    try:
      res = compileExample(dir, "home.nim")
    except CompileFailure as err:
      checkpoint(err.stderrText)
      raise
    let j = parseJson(res.jsonOutput.strip())
    check j["name"].getStr() == "selfContainedDependencies"
    check j["activities"].len == 1
    check packageNames(j, "default") == @["dependency-path-smoke"]

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
