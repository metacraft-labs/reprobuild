## GM7: the one concern classification (repro_home_resources/concerns;
## reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md §Concern-scoped
## apply, "The concerns").
##
## * every resource kind has exactly the concern the spec's table gives it
##   (the `case` in `concernOfResourceKind` is exhaustive, so a new kind
##   without a concern does not compile; this pins the VALUES);
## * a synthesized package resource (`home.package.<id>.*`) takes its
##   package's concern -- `applications` exactly when the same generation
##   placed that package's bundle -- however its own kind is classified;
## * a recorded kind this build does not know is refused, not guessed;
## * the vocabulary refuses unknown and repeated names.
##
## Pure functions over in-memory records: no driver, filesystem or process
## is involved, so nothing is mocked.

import std/[sets, strutils, unittest]

import repro_home_generations
import repro_home_resources

suite "GM7: concern classification":

  test "every resource kind has the spec's concern":
    check concernOfResourceKind(rkFsUserFile) == hcFiles
    for k in [rkEnvUserVariable, rkEnvUserPath, rkShellIntegration,
              rkFsManagedBlock]:
      check concernOfResourceKind(k) == hcEnvironment
    for k in [rkSystemdUserUnit, rkLaunchdUserAgent, rkWindowsStartup]:
      check concernOfResourceKind(k) == hcServices
    for k in [rkMacosUserDefault, rkLinuxGsettings, rkLinuxDconfKey,
              rkLinuxKdeConfigKey, rkWindowsRegistryValue, rkVscodeExtension]:
      check concernOfResourceKind(k) == hcSettings
    for k in [rkHomebrewCask, rkHomebrewFormula, rkMacosAppBundle]:
      check concernOfResourceKind(k) == hcApplications
    # The published table covers every kind once.
    var seen: seq[string]
    for (kind, _) in resourceKindConcerns():
      check kind notin seen
      seen.add kind
    check seen.len == ord(high(ResourceKind)) - ord(low(ResourceKind)) + 1

  test "synthesized package resources take their package's concern":
    var manifest: ActivationManifest
    manifest.resourceBindings = @[
      ResourceBinding(resourceAddress: appBundleAddress("ghostty"),
        resourceKind: $rkMacosAppBundle),
      ResourceBinding(resourceAddress: "home.package.ghostty.bin",
        resourceKind: $rkEnvUserPath),
      ResourceBinding(resourceAddress: "home.package.jdk.env.JAVA_HOME",
        resourceKind: $rkEnvUserVariable),
      ResourceBinding(resourceAddress: "profile.env.userPath.local",
        resourceKind: $rkEnvUserPath)]
    let apps = applicationPackagesOf(manifest)
    check apps == toHashSet(["ghostty"])
    let rb = manifest.resourceBindings
    check concernOfBinding(rb[0], apps) == hcApplications
    check concernOfBinding(rb[1], apps) == hcApplications
    check concernOfBinding(rb[2], apps) == hcPackages
    check concernOfBinding(rb[3], apps) == hcEnvironment
    # A package id that is a prefix of another is not confused with it.
    check concernOfSynthesized("home.package.ghostty-cli.bin", apps) ==
      hcPackages

  test "an unknown recorded kind is refused":
    expect ValueError:
      discard concernOfBinding(ResourceBinding(resourceAddress: "x",
        resourceKind: "fs.somethingNew"), initHashSet[string]())

  test "the vocabulary refuses unknown and repeated names":
    check concernListProblem(["applications", "files"]) == ""
    check concernListProblem([]) == ""
    check "unknown concern `apps`" in concernListProblem(["apps"])
    check "named twice" in concernListProblem(["files", "files"])
    check toConcernSet(["files", "packages"]) == {hcFiles, hcPackages}
    check concernNames({hcSettings, hcPackages}) == @["packages", "settings"]
    expect ValueError:
      discard toConcernSet(["Packages"])

  test "a manifest without a declaration owns every concern":
    var m: ActivationManifest
    check ownedConcernsOf(m) == AllHomeConcerns
    m.concernsDeclared = true
    m.ownedConcerns = @["applications"]
    check ownedConcernsOf(m) == {hcApplications}
