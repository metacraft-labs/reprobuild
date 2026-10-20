## Every built-in catalog ``tarball`` arm declares the version of the tool it
## realizes, and the ranged ``uses:`` the catalogs write resolve against them.
##
## Provisioning-Contributions.md §"Resolution": "A record with no version is
## eligible only when the constraint has no range." Since reprobuild
## b5eda6c0c checks a ``uses "<pkg> <range>"`` against the acquired
## realization, an arm without ``version`` cannot serve any ranged request,
## and most stdlib arms had none. gemini-cli's ``uses "npm >=10"`` failed
## under ``--tool-provisioning=tarball`` with "no tarball realization
## satisfies range '>=10' for x86_64-windows (offered: unversioned)", and so
## would every ``make``, ``bash`` and ``openssl`` range in reprobuild's own
## ``recipes/`` (reprobuild-pm/issues/
## 2026-10-20-stdlib-tarball-arms-declare-no-version-so-every-ranged-uses-is-refused.md).
##
## The version is the TOOL's, not the archive's: ``npm`` ships inside Node's
## archive and ``bash`` inside PortableGit's, and a range in ``uses:`` is
## about npm and bash. This guard cannot tell the two apart; it can only
## refuse the arm that declares neither, which is the failure that reached a
## downstream build.
##
## No mocks: the real registered catalog (``catalog_tarball_packages``, the
## same enrolment the conformance sweeps use), the real recipe sources and the
## production acquisition planner. Offline: nothing is downloaded.
##
## Falsifiable: delete ``version`` from any arm and the first case names it;
## delete it from npm's Windows arm and the third case also reports the
## refusal gemini-cli hit.

import std/[os, sets, strutils, tables, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles
import repro_dsl_stdlib/catalog_tarball_packages

const UnversionedArmPackages = {
  "emcc": "the arms realize emsdk's installer scripts (``emsdk.bat`` / " &
    "``emsdk``), not emcc: emcc arrives later through ``emsdk install``, " &
    "so the archive carries no emcc to take a version from",
  "rustup": "the arms realize the Rust standalone distribution and expose " &
    "``cargo``; the archive does not contain rustup at all",
  "stylus": "the arms realize Node.js and expose ``node``; stylus itself " &
    "arrives through the project's own ``yarn install``",
  "piper-voice-lessac-medium": "a Hugging Face ``resolve/main`` model " &
    "file: upstream publishes no version, only the moving ``main``",
  "piper-voice-lessac-medium-config": "a Hugging Face ``resolve/main`` " &
    "file: upstream publishes no version, only the moving ``main``",
  "whisper-ggml-base": "a Hugging Face ``resolve/main`` model file: " &
    "upstream publishes no version, only the moving ``main``",
}.toTable
  ## Packages whose arms may stay unversioned, each with the reason no
  ## version can be read from the artifact. An arm listed here cannot serve a
  ## ranged ``uses:``; it is listed so that is a decision, not an omission.

const DownstreamRangedUses = [
  ("npm", ">=10"), # reprobuild-packages packages/source/gemini-cli
]
  ## Ranged uses the issue observed in a catalog outside this repository,
  ## checked beside those scanned from ``recipes/``.

proc repoRoot(): string =
  ## The reprobuild repo root, found by walking up from this test file until a
  ## directory holds both ``libs/`` and ``apps/``.
  result = currentSourcePath.parentDir
  for _ in 0 ..< 8:
    if dirExists(result / "libs") and dirExists(result / "apps"):
      return result
    result = result.parentDir
  raiseAssert("could not locate the reprobuild repo root from " &
    currentSourcePath)

proc packagesWithTarballArms(): Table[string, PackageDef] =
  for pkg in registeredPackages():
    if pkg.tarballProvisioning.len > 0:
      result[pkg.packageName] = pkg

proc rangedLiterals(text: string): seq[(string, string)] =
  ## Every one-line string literal of the form ``"<selector> <range>"``,
  ## where the range starts with a range operator. That is how a recipe
  ## spells a ranged ``uses:`` entry.
  for line in text.splitLines:
    var i = 0
    while true:
      let open = line.find('"', i)
      if open < 0: break
      let close = line.find('"', open + 1)
      if close < 0: break
      let body = line[open + 1 ..< close].strip()
      let space = body.find(Whitespace)
      if space > 0:
        let selector = body[0 ..< space]
        let range = body[space + 1 .. ^1].strip()
        if range.len > 0 and range[0] in {'<', '>', '=', '^', '~'}:
          result.add((selector, range))
      i = close + 1

proc recipeRangedUses(): seq[(string, string)] =
  let dir = repoRoot() / "recipes"
  doAssert dirExists(dir), "recipe directory is missing: " & dir
  for path in walkDirRec(dir):
    if path.endsWith(".nim"):
      for pair in rangedLiterals(readFile(path)):
        if pair notin result:
          result.add(pair)

proc rangedToolUse(pkg: PackageDef; range: string): InterfaceToolUse =
  let constraint = pkg.packageName & " " & range
  let iface = toProjectInterface(PackageDef(
    packageName: "rangedUseConsumer",
    toolUses: @[PackageUseDef(
      rawConstraint: constraint, packageSelector: pkg.packageName,
      executableName: pkg.packageName)]),
    [pkg])
  doAssert iface.toolUses.len == 1, "expected one tool use for " & constraint
  iface.toolUses[0]

proc armTargets(pkg: PackageDef): seq[RealizationTarget] =
  ## One target per concrete platform the package has an arm for.
  var seen = initHashSet[string]()
  for arm in pkg.tarballProvisioning:
    if arm.cpu == "any" or arm.os == "any": continue
    if not seen.containsOrIncl(arm.cpu & "-" & arm.os):
      let cpu = parseEnum[PlatformCpu](arm.cpu)
      result.add(realizationTargetFor(cpu, parseEnum[PlatformOs](arm.os),
        baselineMicroarchLevel(cpu)))

suite "every catalog tarball arm declares a version":

  test "an arm without a version belongs to a listed package":
    var arms = 0
    var missing: seq[string] = @[]
    for pkg in registeredPackages():
      for arm in pkg.tarballProvisioning:
        inc arms
        if arm.detail.version.len == 0 and
            pkg.packageName notin UnversionedArmPackages:
          missing.add(pkg.packageName & " (" & arm.cpu & "-" & arm.os &
            ", " & extractFilename(arm.sourceFile) & ":" & $arm.sourceLine &
            ")")
    # A registry that enumerated nothing would pass vacuously.
    check arms >= 200
    checkpoint("tarball arms registered: " & $arms)
    if missing.len > 0:
      checkpoint("declare ``version`` (the tool's, read from the artifact) " &
        "on: " & missing.join("; "))
    check missing.len == 0

  test "every listed package still has an unversioned arm":
    # Once a listed package gains versions on all its arms, its entry only
    # hides the next regression and must go.
    let packages = packagesWithTarballArms()
    var stale: seq[string] = @[]
    for name in UnversionedArmPackages.keys:
      var unversioned = false
      if name in packages:
        for arm in packages[name].tarballProvisioning:
          if arm.detail.version.len == 0:
            unversioned = true
      if not unversioned:
        stale.add(name)
    if stale.len > 0:
      checkpoint("remove from UnversionedArmPackages: " & stale.join(", "))
    check stale.len == 0

  test "ranged uses resolve on every platform the package has an arm for":
    let packages = packagesWithTarballArms()
    var uses = recipeRangedUses()
    for pair in DownstreamRangedUses:
      if pair notin uses:
        uses.add(pair)
    var checked = initHashSet[string]()
    var refused: seq[string] = @[]
    for (selector, range) in uses:
      if selector notin packages: continue
      checked.incl(selector)
      let pkg = packages[selector]
      let useDef = rangedToolUse(pkg, range)
      for target in armTargets(pkg):
        try:
          discard tarballAcquisitionPlan(useDef, target = target)
        except ValueError as err:
          refused.add(err.msg)
    # The issue's cases: if the scan stopped finding them, it found nothing.
    for name in ["make", "bash", "openssl", "npm"]:
      check name in checked
    checkpoint("ranged uses checked for: " & $checked)
    if refused.len > 0:
      checkpoint(refused.join("\n"))
    check refused.len == 0
