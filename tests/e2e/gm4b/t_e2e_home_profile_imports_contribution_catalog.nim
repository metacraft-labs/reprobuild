## Gradual-Nix-To-Reprobuild-Migration GM4b follow-up gate:
## `e2e_home_profile_imports_contribution_catalog`.
##
## A home profile that imports a provisioning-contribution catalog in its
## `catalogs:` section resolves a package whose ONLY realization for the
## target comes from that catalog to the same contribution, and the same
## lock identity, as a recipe that imports the same catalog -- and records
## that identity in `home.lock` when it applies
## (Provisioning-Contributions.md §"Profile Package References").
##
## Fixtures, all written at test time into one scratch directory, laid out
## the way a workspace lays out sibling checkouts:
##
## * `reprobuild-packages/packages/interfaces/gm4bimported/repro.nim` -- the
##   canonical definition, reached by the catalog lookup from the profile
##   and from the recipe. Its only realization is an archive for an OS that
##   is NOT this host, so for this host the package is DEFINED but has no
##   realization of its own;
## * `gm4b-contribution-catalog/repro.nim` -- a contribution catalog whose
##   `provisioningFor "gm4bimported"` adds a raw `file://` archive for this
##   host, pinned to the definition's interface fingerprint (read off a
##   first extraction, as a publisher pins it);
## * `profile-*/home.nim` -- the profiles, `catalogs:
##   "../gm4b-contribution-catalog/repro"`;
## * `recipe-*/repro.nim` -- `import "../gm4b-contribution-catalog/repro"`
##   and `uses: "gm4bimported"`.
##
## Routes, all production code:
##
## 1. RECIPE: the real interface extractor (`extractInterfaceFromModule`)
##    and the `uses:` selection entry point (`selectTarballProvisioning`)
##    with the lock identity a recipe's action carries;
## 2. LIBRARY: `resolveProfileSelections` -- what `--plan` and apply
##    share -- on the profile read by the apply pipeline's text loader;
## 3. CLI: `build/bin/repro home apply --plan` on the profile compiled by
##    the profile compile (the `profile` macro and the RBPI codec carry the
##    section);
## 4. APPLY: a real `runApply` into a scratch HOME/state/store realizes the
##    contribution's archive and writes `home.lock`, whose record carries
##    the recipe's contributor and lock identity.
##
## Vacuity guard: the recipe side must select the contribution's record
## (contributor-prefixed lock identity, `file://` URL) and must NOT select
## anything for this host without the import, so the comparison is between
## two non-trivial selections that depend on the import.
##
## Negative control: the same profile without `catalogs:` reports
## `gm4bimported` as a MISSING REALIZATION naming the target (the
## definition is in scope), never "unknown package" -- in the library and
## the CLI -- while a stdlib package in it still resolves. A `catalogs:`
## entry naming a module that does not exist fails the plan naming the
## entry instead of resolving without it.
##
## Falsifying mutation (performed, see the milestone file):
## `packageResolutionContext` not passing `plan.catalogImports` to
## `projectCatalogPackages` makes the library, CLI and apply cases fail
## (`missing-realization`) while the negative control still passes.
##
## Mocks: none. The archive is a local file reached through a `file://`
## URL, so the apply realizes it without the network; HOME, the profile,
## state and store are scratch directories, and the profile is evaluated
## for a host NAME that is not this machine in the library case so the PATH
## inventory takes no part.

import std/[options, os, osproc, sequtils, streams, strtabs, strutils,
  tempfiles, unittest]
from repro_core/paths import extendedPath
import nimcrypto/sha2 as fixtureSha2

import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles
import repro_home_apply
import repro_home_intent

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir()
  .parentDir()

const
  Contributor = "github:example/gm4b-contribution-catalog"
  PackageName = "gm4bimported"
  ImportEntry = "../gm4b-contribution-catalog/repro"

let hostOs =
  when defined(windows): "windows"
  elif defined(macosx): "macos"
  else: "linux"
let otherOs = if hostOs == "windows": "linux" else: "windows"
let here = currentHostContext()

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

let root = createTempDir("repro-gm4b-catalog-imports-", "")
let payload = root / "payload" / PackageName
createDir(payload.parentDir)
writeFile(payload, "#!/bin/sh\necho gm4bimported\n")
setFilePermissions(payload, {fpUserRead, fpUserWrite, fpUserExec})
let payloadUrl = "file://" & payload
let payloadSha = ($fixtureSha2.sha256.digest(readFile(payload))).toLowerAscii()

let definitionDir = root / "reprobuild-packages" / "packages" / "interfaces" /
  PackageName
createDir(definitionDir)
writeFile(definitionDir / "repro.nim", """
import repro_project_dsl

package gm4bimported:
  provisioning:
    tarball url = "https://example.invalid/gm4bimported-1.0-""" & otherOs &
      """.tar.gz",
      sha256 = "6666666666666666666666666666666666666666666666666666666666666666",
      archiveType = "tar.gz",
      executablePath = "bin/gm4bimported",
      packageId = "gm4bimported@1.0",
      version = "1.0",
      cpu = "x86_64",
      os = """ & "\"" & otherOs & "\"\n")

proc contributionCatalogText(fingerprintLine: string): string =
  "import repro_project_dsl\n\n" &
    "provisioningFor \"" & PackageName & "\":\n" &
    "  " & fingerprintLine & "\n" &
    "  contributor \"" & Contributor & "\"\n" &
    "  tarball url = \"" & payloadUrl & "\",\n" &
    "    sha256 = \"" & payloadSha & "\",\n" &
    "    archiveType = \"raw\",\n" &
    "    executablePath = \"" & PackageName & "\",\n" &
    "    packageId = \"" & PackageName & "@1.0\",\n" &
    "    version = \"1.0\",\n" &
    "    cpu = \"any\",\n" &
    "    os = \"" & hostOs & "\"\n"

let catalogDir = root / "gm4b-contribution-catalog"
createDir(catalogDir)

proc extractRecipe(label: string; withImport: bool): InterfaceToolUse =
  ## A recipe beside the profile, compiled through the real extractor; its
  ## projected ``uses: "gm4bimported"``.
  let dir = root / ("recipe-" & label)
  createDir(dir)
  writeFile(dir / "repro.nim", "import repro_project_dsl\n" &
    (if withImport: "import \"" & ImportEntry & "\"\n" else: "") &
    "\npackage gm4bImportsRecipe:\n  defaultToolProvisioning \"tarball\"\n" &
    "  uses:\n    \"" & PackageName & "\"\n" &
    "    \"just\"\n")
  let artifact = extractInterfaceFromModule(dir / "repro.nim",
    dir / "project-interface.rbsz", dir / "project-interface.nim",
    workDir = ProjectRoot, scratchDir = dir / "work", consumerRoot = dir,
    useExtractionCache = false)
  for use in artifact.projectInterface.toolUses:
    if use.packageSelector == PackageName:
      return use
  doAssert false, "the recipe projects no use of " & PackageName

# The catalog is published PINNED to the definition's interface
# fingerprint: a first extraction binds a development contribution to the
# active definition, and the catalog is rewritten with that fingerprint.
template withNoCatalogRoot(body: untyped) =
  ## The lookup walks to the `reprobuild-packages` beside the recipe and the
  ## profile, as in a workspace; an exported root would replace it.
  let hadRoot = existsEnv(ReprobuildPackagesRootEnv)
  let savedRoot = getEnv(ReprobuildPackagesRootEnv)
  delEnv(ReprobuildPackagesRootEnv)
  try:
    body
  finally:
    if hadRoot: putEnv(ReprobuildPackagesRootEnv, savedRoot)

var pinnedFingerprint = ""
withNoCatalogRoot:
  writeFile(catalogDir / "repro.nim",
    contributionCatalogText("developInterface"))
  let dir = root / "recipe-pin"
  createDir(dir)
  writeFile(dir / "repro.nim", "import repro_project_dsl\nimport \"" &
    ImportEntry & "\"\n\npackage gm4bPin:\n  uses:\n    \"" & PackageName &
    "\"\n")
  let artifact = extractInterfaceFromModule(dir / "repro.nim",
    dir / "project-interface.rbsz", dir / "project-interface.nim",
    workDir = ProjectRoot, scratchDir = dir / "work", consumerRoot = dir,
    useExtractionCache = false)
  for c in artifact.projectInterface.provisioningContributions:
    if c.targetPackage == PackageName:
      pinnedFingerprint = c.targetInterfaceFingerprint
doAssert pinnedFingerprint.len == 64,
  "could not read the definition's interface fingerprint"
writeFile(catalogDir / "repro.nim", contributionCatalogText(
  "interfaceFingerprint \"" & pinnedFingerprint & "\""))

proc profileText(withCatalogs: bool; textForm: bool;
                 entry = ImportEntry): string =
  result = (if textForm: "import repro/profile\n\n"
            else: "import repro_profile\n\n") &
    "profile \"gm4bCatalogImports\":\n"
  if withCatalogs:
    result.add("  catalogs:\n    \"" & entry & "\"\n\n")
  result.add("  activity default:\n    " & PackageName & "\n    just\n")

proc writeProfile(dir: string; withCatalogs: bool; textForm: bool;
                  entry = ImportEntry) =
  createDir(dir)
  writeFile(dir / "home.nim", profileText(withCatalogs, textForm, entry))

proc librarySelections(label: string; withCatalogs: bool;
                       entry = ImportEntry): ProfileSelections =
  ## The profile lives in ``<root>/<label>`` so the catalog lookup and the
  ## `catalogs:` entry resolve against the scratch root, as for the recipe.
  let dir = root / label
  writeProfile(dir, withCatalogs, textForm = true, entry)
  var opts: ApplyOptions
  opts.profileDir = dir
  opts.profilePath = dir / "home.nim"
  opts.stateDir = dir / "state"
  opts.storeRoot = dir / "store"
  opts.homeDir = dir / "home"
  # This machine's platform, another host NAME: the PATH is not consulted.
  opts.host = "gm4b-imports-not-this-host"
  opts.targetContext = HostContext(platform: here.platform, arch: here.arch,
    host: opts.host)
  opts.hasTargetContext = true
  resolveProfileSelections(opts)

proc preview(selections: ProfileSelections; packageId: string):
    PackagePreview =
  for pv in selections.previews:
    if pv.packageId == packageId:
      return pv
  doAssert false, "no preview for " & packageId

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  result = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(extendedPath(result)),
    "repro binary not found at " & result & "; build with `just build` first"

proc runPlan(label: string; withCatalogs: bool):
    tuple[exitCode: int; output: string] =
  let dir = root / label
  writeProfile(dir, withCatalogs, textForm = false)
  let homeDir = dir / "home"
  for d in [homeDir, dir / "state", dir / "store"]:
    createDir(extendedPath(d))
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env["HOME"] = homeDir
  env["USERPROFILE"] = homeDir
  env["REPRO_HOME_PROFILE_DIR"] = dir
  env["REPRO_HOME_STATE_DIR"] = dir / "state"
  env["REPRO_STORE_ROOT"] = dir / "store"
  env["REPRO_HOST"] = "gm4b-imports-plan"
  if env.hasKey(ReprobuildPackagesRootEnv):
    env.del(ReprobuildPackagesRootEnv)
  let p = startProcess(reproBinary(), workingDir = dir,
    args = @["home", "apply", "--plan", "--allow-drift",
             "--target-platform", here.platform, "--target-arch", here.arch],
    env = env, options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (exitCode: code, output: output)

proc packageLine(output, packageId: string): string =
  for line in output.splitLines():
    let t = line.strip()
    for action in ["realize  ", "cache-hit  ", "missing  "]:
      if t.startsWith(action & packageId & "  "):
        return t
  ""

# ---------------------------------------------------------------------------
# The recipe side (the oracle)
# ---------------------------------------------------------------------------

let hostTarget = profileRealizationTarget(here.platform, here.arch,
  isHost = false)
var recipeWith, recipeWithout: InterfaceToolUse
withNoCatalogRoot:
  recipeWith = extractRecipe("with-import", withImport = true)
  recipeWithout = extractRecipe("without-import", withImport = false)

suite "GM4b: e2e_home_profile_imports_contribution_catalog":

  setup:
    # The runner executes each case in its own process. Derive the recipe
    # oracle for this case rather than relying on the vacuity guard to have
    # run first; an empty oracle would only compare against fixture defaults.
    let recipeRecord = selectTarballProvisioning(recipeWith,
      target = hostTarget)
    let recipeLock = contributorLockIdentity(recipeRecord.contributor,
      tarballRealizationLockIdentity(recipeRecord))

  test "the recipe that imports the catalog selects its contribution; " &
      "without the import nothing serves this host (vacuity guard)":
    let record = selectTarballProvisioning(recipeWith, target = hostTarget)
    check record.contributor == Contributor
    check record.url == payloadUrl
    check recipeLock.startsWith("contributor:" & Contributor & "\n")
    # The real acquisition plan carries the same identity.
    check tarballAcquisitionPlan(recipeWith, target = hostTarget).
      lockIdentity == recipeLock
    # The definition alone has no realization for this host.
    check recipeWithout.tarballProvisioning.len == 1
    check recipeWithout.tarballProvisioning.allIt(it.contributor.len == 0)
    expect ValueError:
      discard selectTarballProvisioning(recipeWithout, target = hostTarget)

  test "a profile importing the catalog selects the same contribution and " &
      "lock identity as the recipe":
    withNoCatalogRoot:
      let selections = librarySelections("profile-lib", withCatalogs = true)
      let pv = selections.preview(PackageName)
      checkpoint(pv.detail)
      check pv.resolved
      if pv.resolved:
        let s = pv.resolution.selection
        check s.kind == rkTarball
        check s.tarball.contributor == Contributor
        check s.tarball.url == recipeRecord.url
        check s.tarball.sha256 == recipeRecord.sha256
        check s.tarball.location == recipeRecord.location
        check s.lockIdentity == recipeLock
      # A bundled stdlib reference is projected through the same recipe
      # and still resolves.
      let just = selections.preview("just")
      checkpoint(just.detail)
      check just.resolved and just.resolution.selection.kind == rkTarball

  test "repro home apply --plan on the compiled profile plans the " &
      "contribution":
    let res = runPlan("profile-cli", withCatalogs = true)
    checkpoint(res.output)
    check res.exitCode == 0
    let line = packageLine(res.output, PackageName)
    checkpoint("line: " & line)
    check line.startsWith("realize  " & PackageName & "  ")
    check ("tarball " & payloadUrl & " @1.0 (sha256)") in line
    check packageLine(res.output, "just").startsWith("realize  just  ")

  test "a real apply realizes the contribution and records the recipe's " &
      "contributor and lock identity in home.lock":
    withNoCatalogRoot:
      let dir = root / "profile-apply"
      writeProfile(dir, withCatalogs = true, textForm = true)
      for d in ["state", "store", "home"]:
        createDir(dir / d)
      var opts: ApplyOptions
      opts.profileDir = dir
      opts.profilePath = dir / "home.nim"
      opts.stateDir = dir / "state"
      opts.storeRoot = dir / "store"
      opts.homeDir = dir / "home"
      opts.host = currentHost()
      opts.activationTimestamp = 1000
      let savedCache = getEnv("REPRO_CACHE_DISABLE")
      let savedRc = getEnv("REPRO_HOME_POSIX_PATH_RC")
      putEnv("REPRO_CACHE_DISABLE", "1")
      putEnv("REPRO_HOME_POSIX_PATH_RC", dir / "home" / ".profile-path-rc")
      try:
        let outcome = runApply(opts)
        check outcome.kind == aokFreshApplied
      finally:
        if savedCache.len > 0: putEnv("REPRO_CACHE_DISABLE", savedCache)
        else: delEnv("REPRO_CACHE_DISABLE")
        if savedRc.len > 0: putEnv("REPRO_HOME_POSIX_PATH_RC", savedRc)
        else: delEnv("REPRO_HOME_POSIX_PATH_RC")
      let lock = readHomeProfileLock(homeProfileLockPath(dir))
      check lock.isSome
      var found = false
      if lock.isSome:
        for t in lock.get.targets:
          for p in t.packages:
            if p.package == PackageName:
              found = true
              check t.target == describeTarget(hostTarget)
              check p.kind == rkTarball
              check p.contributor == Contributor
              check p.lockIdentity == recipeLock
              check not p.ambient
      check found

  test "negative control: without the import the reference is a missing " &
      "realization, not an unknown package":
    withNoCatalogRoot:
      let selections = librarySelections("profile-none", withCatalogs = false)
      let pv = selections.preview(PackageName)
      checkpoint(pv.detail)
      check not pv.resolved
      check pv.detail.startsWith("missing-realization")
      check describeTarget(hostTarget) in pv.detail
      check "unknown-package" notin pv.detail
      let just = selections.preview("just")
      check just.resolved and just.resolution.selection.kind == rkTarball
    let res = runPlan("profile-cli-none", withCatalogs = false)
    checkpoint(res.output)
    let line = packageLine(res.output, PackageName)
    checkpoint("line: " & line)
    check line.startsWith("missing  " & PackageName & "  (missing-realization")
    check packageLine(res.output, "just").startsWith("realize  just  ")

  test "a catalogs: entry naming no module fails the plan, naming the entry":
    withNoCatalogRoot:
      var refused = false
      try:
        discard librarySelections("profile-bad", withCatalogs = true,
          entry = "../no-such-catalog/repro")
      except CatchableError as err:
        refused = true
        checkpoint err.msg
        check "\"../no-such-catalog/repro\"" in err.msg
        check "does not exist" in err.msg
      check refused

removeDir(root)
