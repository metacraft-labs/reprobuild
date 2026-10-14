## Gradual-Nix-To-Reprobuild-Migration GM4b gate:
## `e2e_home_profile_resolves_like_uses`.
##
## For a fixture set of packages on Linux, macOS and Windows targets, a home
## profile and a recipe's `uses:` select the same realization — the same
## record and the same lock identity — or both fail
## (Provisioning-Contributions.md §"Profile Package References").
##
## The two sides are produced the way production produces them:
##
## * RECIPE: a real recipe module `uses:` the fixture packages and is
##   compiled through the real interface extractor
##   (`extractInterfaceFromModule`); its `InterfaceToolUse` records go through
##   the `uses:` selection entry points (`selectTarballProvisioning`,
##   `selectNixProvisioning`, `selectScoopProvisioning`) and, where the `uses:`
##   provisioning edge realizes the record, the real acquisition plans
##   (`tarballAcquisitionPlan`, `nixAcquisitionPlan`, `scoopAcquisitionPlan`),
##   whose lock identity is the one a recipe's action carries.
## * HOME: a real `home.nim` (text form, loaded by the apply pipeline's own
##   loader) is resolved by `resolveProfileSelections` — the library entry
##   point `repro home apply --plan` and apply share — for an explicit target
##   context, under an `adapterPreference:` selection policy.
##
## Fixture packages: real stdlib definitions (`just`, `gh`, `jdk`, `python3`,
## `7zip`) plus `gm4bcontrib` (`gm4b_contribution_fixture.nim`), which adds
## an external contribution (contributor-prefixed lock identity) and an
## ambiguous Windows tarball.
##
## The host's PATH and Scoop are deliberately out of the comparison: the
## profile is evaluated for a host name that is not this machine, so the
## `path` kind is ineligible on every target. That is what makes the result
## identical on any machine this test runs on.
##
## Vacuity guard: the comparison counts every (package, target, policy) cell;
## it must see selections of all three declared kinds, at least one
## contributor-prefixed lock identity, at least one ambiguity and at least one
## refusal, or the test fails before comparing anything trivially equal.
##
## Falsifying mutation (performed 2026-10-13, see the milestone file):
## reintroducing a per-platform chain for home apply — `selectionPolicyFor`
## returning `[nix, path]` for a macOS target without an `adapterPreference`
## entry, the pre-GM4b `MacosDefaultChain` — makes the default-policy case
## diverge on aarch64-macos (`just`, `gh`, `python3`: the profile selects nix,
## `uses:` in the first kind that serves the target selects the tarball).
##
## Mocks: none. Nothing is downloaded or realized; selection is static
## metadata by design.

import std/[options, os, sequtils, strutils, tables, tempfiles, unittest]

import repro_interface_artifacts
import repro_tool_profiles
import repro_home_apply
import repro_home_intent
import ./gm4b_contribution_fixture

const FixtureModule = currentSourcePath().parentDir() /
  "gm4b_contribution_fixture"

const FixturePackages = ["just", "gh", "jdk", "python3", "7zip",
  "gm4bcontrib"]

type
  Target = object
    name: string        ## ``describeTarget`` spelling
    platform: string    ## ``HostContext.platform``
    arch: string        ## ``HostContext.arch``
    adapterKey: string  ## ``adapterPreference:`` key
    realization: RealizationTarget

  Outcome = object
    selected: bool
    kind: RealizationKind
    record: string      ## tarball url | nix selector | scoop bucket/app
    lockIdentity: string
    ambiguous: bool
    note: string

let Targets = @[
  Target(name: "x86_64-linux", platform: "linux", arch: "x86_64",
    adapterKey: "linux",
    realization: realizationTargetFor(pcX86_64, poLinux, mlX86_64_v1)),
  Target(name: "aarch64-macos", platform: "macos", arch: "arm64",
    adapterKey: "darwin",
    realization: realizationTargetFor(pcAArch64, poMacos)),
  Target(name: "x86_64-windows", platform: "windows", arch: "x86_64",
    adapterKey: "windows",
    realization: realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1))]

proc `$`(o: Outcome): string =
  if o.selected:
    $o.kind & " " & o.record & " [" & o.lockIdentity.replace("\n", "\\n") &
      "]"
  elif o.ambiguous:
    "ambiguous (" & o.note & ")"
  else:
    "none (" & o.note & ")"

proc sameOutcome(a, b: Outcome): bool =
  if a.selected != b.selected:
    return false
  if a.selected:
    return a.kind == b.kind and a.record == b.record and
      a.lockIdentity == b.lockIdentity
  a.ambiguous == b.ambiguous

# ---------------------------------------------------------------------------
# Recipe side: real interface extraction + the `uses:` entry points
# ---------------------------------------------------------------------------

proc extractRecipeUses(scratch: string): Table[string, InterfaceToolUse] =
  let project = scratch / "recipe"
  createDir(project)
  var uses = ""
  for p in FixturePackages:
    uses.add("    \"" & p & "\"\n")
  writeFile(project / "repro.nim", """
import repro_project_dsl
import repro_dsl_stdlib/packages/jdk
import repro_dsl_stdlib/packages/pkg_7zip
import """ & "\"" & FixtureModule & "\"" & """


package gm4bResolvesLikeUses:
  defaultToolProvisioning "tarball"
  uses:
""" & uses)
  let artifactPath = scratch / "out" / "project-interface.rbsz"
  let stubPath = scratch / "out" / "project-interface.nim"
  createDir(artifactPath.parentDir)
  let artifact = extractInterfaceFromModule(project / "repro.nim",
    artifactPath, stubPath, getCurrentDir(), useExtractionCache = false)
  for use in artifact.projectInterface.toolUses:
    result[use.packageSelector] = use

proc recipeOutcome(useDef: InterfaceToolUse; kind: RealizationKind;
                   target: RealizationTarget): Outcome =
  ## What a recipe's `uses:` selects in provisioning mode ``kind``.
  try:
    case kind
    of rkTarball:
      let record = selectTarballProvisioning(useDef, target = target)
      result = Outcome(selected: true, kind: rkTarball, record: record.url,
        lockIdentity: contributorLockIdentity(record.contributor,
          tarballRealizationLockIdentity(record)))
      if archiveInstallerFeatures(record).len == 0:
        # The real acquisition plan carries the same identity.
        check tarballAcquisitionPlan(useDef, target = target).lockIdentity ==
          result.lockIdentity
      else:
        # An installer-class record is SELECTED alike; only the `uses:`
        # provisioning edge refuses to realize it, and says which record.
        try:
          discard tarballAcquisitionPlan(useDef, target = target)
          check false
        except ValueError as err:
          check record.url in err.msg
          check "realized by `repro home apply` only" in err.msg
    of rkNix:
      let record = selectNixProvisioning(useDef, target)
      let plan = nixAcquisitionPlan(useDef, target)
      result = Outcome(selected: true, kind: rkNix, record: record.selector,
        lockIdentity: plan.lockIdentity)
    of rkScoop:
      let record = selectScoopProvisioning(useDef, target)
      let plan = scoopAcquisitionPlan(useDef, target)
      result = Outcome(selected: true, kind: rkScoop,
        record: record.bucket & "/" & record.app,
        lockIdentity: plan.lockIdentity)
    of rkPath:
      doAssert false, "path is host inventory, not a recipe mode compared here"
  except ValueError as err:
    result = Outcome(selected: false, ambiguous: "ambiguous" in err.msg,
      note: err.msg)

proc expectedDefault(useDef: InterfaceToolUse; target: RealizationTarget):
    Outcome =
  ## The oracle for the default policy, computed from the `uses:` side:
  ## the first declared kind, in ``DefaultSelectionPolicy`` order, that a
  ## recipe in that mode selects; an ambiguity stops the walk (it never
  ## falls through). ``path`` is excluded — the profile under test is not
  ## evaluated for this machine.
  result = Outcome(selected: false, note: "no kind selects")
  for kind in DefaultSelectionPolicy:
    if kind == rkPath:
      continue
    let o = recipeOutcome(useDef, kind, target)
    if o.selected or o.ambiguous:
      return o

# ---------------------------------------------------------------------------
# Home side: a real home.nim through the apply pipeline's resolver
# ---------------------------------------------------------------------------

proc homeOutcomes(scratch: string; target: Target;
                  policy: seq[RealizationKind]):
    tuple[outcomes: Table[string, Outcome]; policySource: string] =
  let dir = scratch / ("home-" & target.name & "-" &
    (if policy.len == 0: "default" else: policy.mapIt($it).join("-")))
  createDir(dir)
  var body = "import repro/profile\n\nprofile \"gm4b\":\n"
  if policy.len > 0:
    body.add("  adapterPreference:\n    " & target.adapterKey & ": [" &
      policy.mapIt($it).join(", ") & "]\n\n")
  body.add("  activity default:\n")
  for p in FixturePackages:
    # ``7zip`` is not a Nim identifier, so the profile names it as a
    # string; the others stay bare.
    if p.validIdentifier: body.add("    " & p & "\n")
    else: body.add("    \"" & p & "\"\n")
  writeFile(dir / "home.nim", body)
  var opts: ApplyOptions
  opts.profileDir = dir
  opts.profilePath = dir / "home.nim"
  opts.stateDir = dir / "state"
  opts.storeRoot = dir / "store"
  opts.homeDir = dir / "home"
  # Not this machine: the host inventory (PATH, Scoop) is not consulted.
  opts.host = "gm4b-not-this-host"
  opts.targetContext = HostContext(platform: target.platform,
    arch: target.arch, host: opts.host)
  opts.hasTargetContext = true
  let selections = resolveProfileSelections(opts)
  check selections.target == target.name
  result.policySource = selections.policySource
  for pv in selections.previews:
    if pv.resolved:
      let s = pv.resolution.selection
      let record =
        case s.kind
        of rkTarball: s.tarball.url
        of rkNix: s.nix.selector
        of rkScoop: s.scoop.bucket & "/" & s.scoop.app
        of rkPath: s.pathExecutable
      result.outcomes[pv.packageId] = Outcome(selected: true, kind: s.kind,
        record: record, lockIdentity: s.lockIdentity)
    else:
      result.outcomes[pv.packageId] = Outcome(selected: false,
        ambiguous: pv.detail.startsWith("ambiguous-realization"),
        note: pv.detail)

suite "GM4b: e2e_home_profile_resolves_like_uses":
  let scratch = createTempDir("repro-gm4b-like-uses-", "")
  let savedContributor = getEnv("REPRO_PROVISIONING_CONTRIBUTOR")
  let hadContributor = existsEnv("REPRO_PROVISIONING_CONTRIBUTOR")
  delEnv("REPRO_PROVISIONING_CONTRIBUTOR")
  let recipe = extractRecipeUses(scratch)

  test "the recipe projects every fixture package (precondition)":
    for p in FixturePackages:
      checkpoint p
      check p in recipe
    # The contribution reached the recipe's projection.
    check recipe["gm4bcontrib"].tarballProvisioning.anyIt(
      it.contributor == Gm4bContributor)

  test "e2e_home_profile_resolves_like_uses: single-kind policies select " &
      "the same record and lock identity as uses: in that mode":
    var compared, selectedCells, ambiguousCells, refusedCells = 0
    var kindsSeen: set[RealizationKind]
    var contributorLock = false
    for target in Targets:
      for kind in [rkTarball, rkNix, rkScoop]:
        let home = homeOutcomes(scratch, target, @[kind])
        check home.policySource == "adapterPreference." & target.adapterKey
        for p in FixturePackages:
          let want = recipeOutcome(recipe[p], kind, target.realization)
          check p in home.outcomes
          let got = home.outcomes[p]
          checkpoint target.name & " [" & $kind & "] " & p & ": uses: " &
            $want & " | home: " & $got
          check sameOutcome(want, got)
          inc compared
          if got.selected:
            inc selectedCells
            kindsSeen.incl(got.kind)
            if got.lockIdentity.startsWith("contributor:" & Gm4bContributor):
              contributorLock = true
          elif got.ambiguous:
            inc ambiguousCells
          else:
            inc refusedCells
    # Vacuity guard.
    check compared == Targets.len * 3 * FixturePackages.len
    check selectedCells >= 15
    check kindsSeen == {rkTarball, rkNix, rkScoop}
    check contributorLock
    check ambiguousCells >= 1
    check refusedCells >= 1

  test "e2e_home_profile_resolves_like_uses: the default policy selects, on " &
      "every platform, the first kind uses: can select":
    var compared = 0
    var tarballOnMac = false
    for target in Targets:
      let home = homeOutcomes(scratch, target, @[])
      check home.policySource == "default"
      for p in FixturePackages:
        let want = expectedDefault(recipe[p], target.realization)
        let got = home.outcomes[p]
        checkpoint target.name & " [default] " & p & ": uses: " & $want &
          " | home: " & $got
        check sameOutcome(want, got)
        inc compared
        if target.name == "aarch64-macos" and got.selected and
            got.kind == rkTarball:
          tarballOnMac = true
    check compared == Targets.len * FixturePackages.len
    # The macOS cell the falsifying mutation flips must exist.
    check tarballOnMac

  test "a contribution's lock identity carries its contributor":
    let home = homeOutcomes(scratch, Targets[1], @[rkTarball])
    let got = home.outcomes["gm4bcontrib"]
    check got.selected
    check got.record ==
      "https://example.invalid/a/gm4bcontrib-1.0-macos-arm64.tar.gz"
    check got.lockIdentity == "contributor:" & Gm4bContributor & "\n" &
      "sha256:" & Gm4bMacSha

  test "an in-package realization keeps the bare lock identity":
    let home = homeOutcomes(scratch, Targets[0], @[rkTarball])
    check home.outcomes["gm4bcontrib"].lockIdentity == "sha256:" & Gm4bLinuxSha

  test "ambiguity does not fall through to the next kind":
    # Windows tarball: in-package and contribution A both offer one.
    let home = homeOutcomes(scratch, Targets[2], @[rkTarball, rkScoop])
    let got = home.outcomes["gm4bcontrib"]
    check not got.selected
    check got.ambiguous
    check "canonical-package" in got.note
    check Gm4bContributor in got.note

  if hadContributor:
    putEnv("REPRO_PROVISIONING_CONTRIBUTOR", savedContributor)
  removeDir(scratch)
