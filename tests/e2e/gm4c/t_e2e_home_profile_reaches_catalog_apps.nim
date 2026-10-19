## Gradual-Nix-To-Reprobuild-Migration GM4c gate:
## `e2e_home_profile_reaches_catalog_apps`.
##
## A home profile that names `ghostty` (a disk image) and `iterm2` (a zip)
## resolves them to their definitions in the REAL `reprobuild-packages`
## catalog for aarch64-darwin, selects the same records a recipe's
## `uses: "ghostty"` / `uses: "iterm2"` projects, and plans the app-bundle
## install under the strict trust policy
## (Provisioning-Contributions.md §"Profile Package References";
## Store-And-Installation-Layout.md § macOS Application Bundles).
##
## Before this, profile references resolved only against the definitions the
## engine links, so every macOS application definition reported
## `unknown-package` to a profile while a recipe beside it resolved them.
##
## Routes, all production code:
##
## 1. the real CLI — `build/bin/repro home apply --plan --target-platform
##    macos --target-arch arm64` on a compiled `home.nim`. Its plan lines
##    name the catalog's URLs and the `app-bundle` install shape;
## 2. the library entry point the CLI uses (`resolveProfileSelections`),
##    evaluated for a host name that is not this machine, so the PATH never
##    takes part and the result is the same on any host;
## 3. a real recipe module that `uses:` both packages, compiled through the
##    real interface extractor, whose projected records are the records the
##    profile selected — "exactly as `uses:` does".
##
## Where the catalog is looked for follows the profile, as it follows a
## recipe: a `reprobuild-packages` checkout beside the PROFILE's directory
## wins for the names it defines (a fixture catalog built in the test), and
## a name it does not define still reaches the catalog beside the reprobuild
## checkout.
##
## Expected values are written out below, copied from
## `reprobuild-packages/packages/interfaces/{ghostty,iterm2}/repro.nim` at the
## revision `.github/sibling-repos` pins; they are not derived from the
## resolver.
##
## Vacuity guard: both applications must resolve to a `tarball` selection
## with the exact URL and lock identity, routed to the home archive realizer
## with the `app-bundle` method and the declared bundle id and team; and the
## recipe side must carry the same records.
##
## Negative control: with `$REPROBUILD_PACKAGES_ROOT` naming an empty
## directory (the only place the lookup then consults), the same profile
## reports `ghostty` and `iterm2` as unknown packages, and a stdlib package
## in it still resolves — the catalog, not something else, supplied them.
## Karabiner-Elements, defined in the same catalog, resolves to its record
## and is refused naming the realizer it lacks, not reported unknown.
##
## Falsifying mutation (performed for GM4c, engine rebuilt):
## `packageResolutionContext` passing an empty `ProfileCatalog` makes the CLI,
## library and catalog-beside-the-profile cases fail — every application is
## `unknown-package` — while the negative control still passes.
##
## Mocks: none. Nothing is downloaded; selection is static metadata. HOME and
## the state/store/profile directories are scratch directories.

import std/[os, osproc, sequtils, streams, strtabs, strutils, tempfiles,
  unittest]
from repro_core/paths import extendedPath

import repro_project_dsl
import repro_interface_artifacts
import repro_home_apply
import repro_home_intent

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir()
  .parentDir()

const
  GhosttyUrl = "https://release.files.ghostty.org/1.3.1/Ghostty.dmg"
  GhosttyLock = "tarball:ghostty@1.3.1:macos-any:sha256:" &
    "18cff2b0a6cee90eead9c7d3064e808a252a40baf214aa752c1ecb793b8f5f69"
  Iterm2Url = "https://iterm2.com/downloads/stable/iTerm2-3_7_4.zip"
  Iterm2Lock = "tarball:iterm2@3.7.4:macos-any:sha256:" &
    "4bf02ae616752600cd195ca504e55392afb21741cda7314199e375ed8a46f90c"

proc profileBody(name: string; packages: openArray[string];
                 textForm = false): string =
  result = (if textForm: "import repro/profile\n\n"
            else: "import repro_profile\n\n") &
    "profile \"" & name & "\":\n  activity default:\n"
  for p in packages:
    result.add("    " & p & "\n")

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  result = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(extendedPath(result)),
    "repro binary not found at " & result & "; build with `just build` first"

proc runPlan(root: string; packages: openArray[string]):
    tuple[exitCode: int; output: string] =
  let profileDir = root / "profile"
  let homeDir = root / "home"
  for dir in [profileDir, homeDir, root / "state", root / "store"]:
    createDir(extendedPath(dir))
  writeFile(extendedPath(profileDir / "home.nim"),
    profileBody("gm4cCatalogApps", packages))
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env["HOME"] = homeDir
  env["USERPROFILE"] = homeDir
  env["REPRO_HOME_PROFILE_DIR"] = profileDir
  env["REPRO_HOME_STATE_DIR"] = root / "state"
  env["REPRO_STORE_ROOT"] = root / "store"
  env["REPRO_HOST"] = "gm4c-catalog-plan"
  let p = startProcess(reproBinary(), workingDir = root,
    args = @["home", "apply", "--plan", "--allow-drift",
             "--target-platform", "macos", "--target-arch", "arm64"],
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

proc librarySelections(profileDir: string; packages: openArray[string]):
    ProfileSelections =
  createDir(profileDir)
  writeFile(profileDir / "home.nim",
    profileBody("gm4cCatalogApps", packages, textForm = true))
  var opts: ApplyOptions
  opts.profileDir = profileDir
  opts.profilePath = profileDir / "home.nim"
  opts.stateDir = profileDir.parentDir / "state"
  opts.storeRoot = profileDir.parentDir / "store"
  opts.homeDir = profileDir.parentDir / "home"
  opts.host = "gm4c-not-this-host"
  opts.targetContext = HostContext(platform: "macos", arch: "arm64",
    host: opts.host)
  opts.hasTargetContext = true
  resolveProfileSelections(opts)

proc preview(selections: ProfileSelections; packageId: string):
    PackagePreview =
  for pv in selections.previews:
    if pv.packageId == packageId:
      return pv
  doAssert false, "no preview for " & packageId

proc checkApp(pv: PackagePreview; url, lock, bundleId, teamId,
              archiveType: string) =
  checkpoint(pv.packageId & ": " & pv.detail)
  check pv.resolved
  if not pv.resolved:
    return
  let r = pv.resolution
  check r.selection.kind == rkTarball
  check r.selection.tarball.url == url
  check r.selection.lockIdentity == lock
  check r.selection.tarball.archiveType == archiveType
  check r.archiveRoute == arExtract
  check r.archive.installMethod == imAppBundle
  check r.archive.bundleId == bundleId
  check r.archive.teamId == teamId
  check r.archive.digestAlgorithm == "sha256"
  # The record was written in the catalog's interface module.
  check r.selection.tarball.location.file.endsWith(
    "packages/interfaces/" & pv.packageId & "/repro.nim")

template withCatalogRoot(value: string; body: untyped) =
  let hadRoot = existsEnv(ReprobuildPackagesRootEnv)
  let savedRoot = getEnv(ReprobuildPackagesRootEnv)
  if value.len > 0: putEnv(ReprobuildPackagesRootEnv, value)
  else: delEnv(ReprobuildPackagesRootEnv)
  try:
    body
  finally:
    if hadRoot: putEnv(ReprobuildPackagesRootEnv, savedRoot)
    else: delEnv(ReprobuildPackagesRootEnv)

const FixtureCatalogApp = """
import repro_project_dsl

package gm4ccatalogfixture:
  provisioning:
    tarball url = "https://example.invalid/gm4c/Fixture-1.0.dmg",
      sha256 = "5555555555555555555555555555555555555555555555555555555555555555",
      archiveType = "dmg",
      installMethod = "app-bundle",
      appBundle = "Fixture.app",
      bundleId = "dev.reprobuild.gm4c.catalogfixture",
      teamId = "RPBTEST123",
      version = "1.0",
      executablePath = "Fixture.app/Contents/MacOS/Fixture",
      packageId = "gm4ccatalogfixture@1.0",
      cpu = "any",
      os = "macos",
      lockIdentity = "tarball:gm4ccatalogfixture@1.0:macos-any:sha256:5555"
"""

suite "GM4c: e2e_home_profile_reaches_catalog_apps":

  test "repro home apply --plan for aarch64-darwin plans ghostty and " &
      "iterm2 from the reprobuild-packages catalog":
    withCatalogRoot(""):
      let root = createTempDir("repro-gm4c-catalog-cli-", "")
      defer:
        try: removeDir(root) except OSError: discard
      let res = runPlan(root, ["ghostty", "iterm2", "just"])
      checkpoint(res.output)
      check res.exitCode == 0
      let ghostty = packageLine(res.output, "ghostty")
      checkpoint("ghostty line: " & ghostty)
      check ghostty.startsWith("realize  ghostty  ")
      check ("tarball " & GhosttyUrl & " @1.3.1 (sha256, app-bundle)") in
        ghostty
      let iterm2 = packageLine(res.output, "iterm2")
      checkpoint("iterm2 line: " & iterm2)
      check iterm2.startsWith("realize  iterm2  ")
      check ("tarball " & Iterm2Url & " @3.7.4 (sha256, app-bundle)") in
        iterm2
      check packageLine(res.output, "just").startsWith("realize  just  ")
      check "unknown-package" notin res.output

  test "the library selection is the catalog's record, as a recipe's " &
      "uses: projects it":
    withCatalogRoot(""):
      let root = createTempDir("repro-gm4c-catalog-lib-", "")
      defer:
        try: removeDir(root) except OSError: discard
      let selections = librarySelections(root / "profile",
        ["ghostty", "iterm2", "karabiner-elements", "just"])
      check selections.target == "aarch64-macos"
      let ghostty = selections.preview("ghostty")
      checkApp(ghostty, GhosttyUrl, GhosttyLock, "com.mitchellh.ghostty",
        "24VZTF6M5V", "dmg")
      let iterm2 = selections.preview("iterm2")
      checkApp(iterm2, Iterm2Url, Iterm2Lock, "com.googlecode.iterm2",
        "H7V7XYVQ7D", "zip")
      # Defined in the same catalog, selected, and refused for the reason
      # it cannot be realized -- not reported unknown.
      let karabiner = selections.preview("karabiner-elements")
      checkpoint("karabiner-elements: " & karabiner.detail)
      check not karabiner.resolved
      check MacosPkgInstallRefusal in karabiner.detail
      check "unknown-package" notin karabiner.detail
      # A bundled stdlib package is unaffected.
      let just = selections.preview("just")
      check just.resolved and just.resolution.selection.kind == rkTarball

      # The recipe side: a recipe beside the profile that `uses:` both
      # packages, compiled through the real extractor.
      let recipeDir = root / "recipe"
      createDir(recipeDir)
      writeFile(recipeDir / "repro.nim", "import repro_project_dsl\n\n" &
        "package gm4cCatalogRecipe:\n  uses:\n    \"ghostty\"\n" &
        "    \"iterm2\"\n")
      let artifact = extractInterfaceFromModule(recipeDir / "repro.nim",
        recipeDir / "project-interface.rbsz",
        recipeDir / "project-interface.nim",
        workDir = ProjectRoot, scratchDir = recipeDir / "work",
        consumerRoot = recipeDir)
      for (name, pv) in [("ghostty", ghostty), ("iterm2", iterm2)]:
        let uses = artifact.projectInterface.toolUses.filterIt(
          it.packageSelector == name)
        check uses.len == 1
        if uses.len == 1 and pv.resolved:
          check uses[0].tarballProvisioning.len == 1
          let recipeRecord = uses[0].tarballProvisioning[0]
          let profileRecord = pv.resolution.selection.tarball
          check recipeRecord.url == profileRecord.url
          check recipeRecord.sha256 == profileRecord.sha256
          check recipeRecord.lockIdentity == profileRecord.lockIdentity
          check recipeRecord.detail == profileRecord.detail
          check recipeRecord.location == profileRecord.location

  test "a catalog beside the profile is found first, as for a recipe":
    withCatalogRoot(""):
      let root = createTempDir("repro-gm4c-catalog-anchor-", "")
      defer:
        try: removeDir(root) except OSError: discard
      let fixtureDir = root / "reprobuild-packages" / "packages" /
        "interfaces" / "gm4ccatalogfixture"
      createDir(fixtureDir)
      writeFile(fixtureDir / "repro.nim", FixtureCatalogApp)
      let selections = librarySelections(root / "profile",
        ["gm4ccatalogfixture", "ghostty"])
      let fixture = selections.preview("gm4ccatalogfixture")
      checkApp(fixture, "https://example.invalid/gm4c/Fixture-1.0.dmg",
        "tarball:gm4ccatalogfixture@1.0:macos-any:sha256:5555",
        "dev.reprobuild.gm4c.catalogfixture", "RPBTEST123", "dmg")
      if fixture.resolved:
        # The compiler records the resolved path (`/private/tmp` for
        # `/tmp` on macOS).
        check fixture.resolution.selection.tarball.location.file.startsWith(
          expandFilename(root) / "reprobuild-packages")
      # The fixture catalog does not define ghostty; the walk continues to
      # the catalog beside the reprobuild checkout.
      checkApp(selections.preview("ghostty"), GhosttyUrl, GhosttyLock,
        "com.mitchellh.ghostty", "24VZTF6M5V", "dmg")

  test "negative control: with no catalog reachable the applications are " &
      "unknown packages":
    let empty = createTempDir("repro-gm4c-no-catalog-", "")
    defer:
      try: removeDir(empty) except OSError: discard
    withCatalogRoot(empty):
      let selections = librarySelections(empty / "profile",
        ["ghostty", "iterm2", "just"])
      for name in ["ghostty", "iterm2"]:
        let pv = selections.preview(name)
        checkpoint(name & ": " & pv.detail)
        check not pv.resolved
        check pv.detail.startsWith("unknown-package: ")
      let just = selections.preview("just")
      check just.resolved and just.resolution.selection.kind == rkTarball
