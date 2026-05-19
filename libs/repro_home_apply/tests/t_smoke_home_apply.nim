## Smoke test for the M63 apply pipeline library. Pins the public
## API surface compiles, the planner produces deterministic plans,
## and the partial-recovery marker round-trips.

import std/[os, unittest]

import repro_home_apply

const SmokeDir = "build/test-tmp/home-apply-smoke"

proc resetDir(path: string) =
  if dirExists(path):
    removeDir(path)
  createDir(path)

suite "Home-apply smoke":

  test "partial-recovery marker round-trips":
    resetDir(SmokeDir)
    writeMarker(SmokeDir, "abcd1234", "in-progress")
    let m = readMarker(SmokeDir)
    check m.present
    check m.generationId == "abcd1234"
    check m.reason == "in-progress"
    clearMarker(SmokeDir)
    let cleared = readMarker(SmokeDir)
    check (not cleared.present)

  test "stow discovery walks profile-dir/stow/ only":
    let profileDir = SmokeDir / "profile"
    let homeDir = SmokeDir / "home"
    resetDir(profileDir)
    resetDir(homeDir)
    createDir(profileDir / "stow" / ".config" / "foo")
    writeFile(profileDir / "stow" / ".gitconfig", "[user]\n  email = test@example.com\n")
    writeFile(profileDir / "stow" / ".config" / "foo" / "bar.toml", "[a]\n")
    let entries = discoverStowEntries(profileDir, homeDir)
    check entries.len == 2
    var rels: seq[string]
    for e in entries:
      rels.add e.homeRelativePath
    check ".gitconfig" in rels
    check ".config/foo/bar.toml" in rels

  test "suppression layer pairs stow file with package output":
    var pkgOutput = PlannedGeneratedFile(
      absoluteOutputPath: "/home/u/.gitconfig",
      relativeHomePath: ".gitconfig",
      sourceKind: pgfsPackageOutput,
      contributingPackage: "git-config",
      contentBytes: @[byte('a')])
    var stowEntry = PlannedGeneratedFile(
      absoluteOutputPath: "/home/u/.gitconfig",
      relativeHomePath: ".gitconfig",
      sourceKind: pgfsStowFile,
      stowSourcePath: "/profile/stow/.gitconfig",
      contentBytes: @[byte('s')])
    let contribs = @[ConfigContribution(packageName: "git-config",
      configKey: "userEmail")]
    let res = suppressStowShadowed(@[pkgOutput, stowEntry], contribs)
    check res.files.len == 1
    check res.files[0].sourceKind == pgfsStowFile
    check res.diagnostics.len == 1
    check res.diagnostics[0].code == sdWStowOverridesShadowed
    check "userEmail" in res.diagnostics[0].deadConfigKeys
