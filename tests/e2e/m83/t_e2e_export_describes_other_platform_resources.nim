## A profile exported on any host describes the resources, config overrides
## and packages it guards for a DIFFERENT platform, and evaluating the export
## for that platform yields them.
##
## Primary assertion — `e2e_export_describes_other_platform_resources`: a
## fixture profile selects platforms only with runtime predicates — a
## `when linux(): / elif macos(): / elif windows():` chain and a nested
## `when macos() and arm64():` in `resources:`, `when` chains in `config:`
## both around and inside a package block, an activity-body guard, and a
## helper module that guards an activity element, a config override and a
## resource with `guarded(...)`. Exported on this host:
##
## * the intent carries every platform's elements with their guards as
##   predicate text, whatever platform compiled it;
## * the platform probe reports every target platform `same`: the document
##   describes all of them;
## * evaluated for each of x86_64-linux, aarch64-linux, x86_64-darwin,
##   aarch64-darwin and x86_64-windows — through the CLI
##   (`repro home export --target`) and through the library entry point
##   (`evaluateHomeExport`) on the plain export, which must agree — it yields
##   exactly that platform's resources, config overrides and packages;
## * for the compiling platform the evaluation equals what `repro home plan`
##   plans on this host (its `create` lines).
##
## Vacuity: each platform-specific element is present for its platform and
## absent for every other one, so a guard that selected nothing (or
## everything) fails; the profile has resources for three platforms and an
## architecture-specific one.
##
## Falsifying mutation (performed when this gate was written): turn the
## macOS branch of the `resources:` chain into a compile-time
## `when defined(macosx):`. Compiled on Linux, the macOS resource is gone
## from the intent and the probe reports both darwin platforms `differs`, so
## the darwin evaluations are refused (exit 3) and the gate goes red.
##
## No mocks: real `build/bin/repro`, real Nim (compile and probe), real
## io-mon shim, real filesystem; the `nim` spy is a pass-through counter
## (harness header). Nothing is applied.

import repro_test_support/reasoned_skip

const PlatformSkipReason =
  "[platform N/A] t_e2e_export_describes_other_platform_resources: the nim " &
  "spy and the stderr capture are POSIX shell, and the profile-compile edge " &
  "is verified on Linux, where io-mon is the established backend."

when not defined(linux):
  import std/unittest

  suite "repro home export: other platforms":
    test "e2e_export_describes_other_platform_resources":
      skip(PlatformSkipReason)
else:
  import std/[algorithm, json, strutils, unittest]

  import repro_profile_compile
  import repro_cli_support/home_export

  import ./profile_compile_edge_harness

  const NeutralProfile = """
import repro_profile
import ./modules/platform_tools

profile "gm3Neutral":
  activity default:
    ripgrep
    when macos():
      `gm3-mac-app`

  activity dev:
    platformDevTools()

  config:
    git:
      userName = "gm3"
      when macos():
        credentialHelper = "osxkeychain"
      elif windows():
        credentialHelper = "manager"
      else:
        credentialHelper = "libsecret"
    when linux():
      tmux:
        prefix = "C-a"
    platformConfig()

  resources:
    fsUserFile(hostFile = "~/.gm3-common", content = "everywhere\n",
      address = "common")
    when linux():
      fsUserFile(hostFile = "~/.config/gm3/linux.conf", content = "linux\n",
        address = "platformRc")
    elif macos():
      fsUserFile(hostFile = "~/Library/Preferences/gm3-macos.conf",
        content = "macos\n", address = "platformRc")
    elif windows():
      fsUserFile(hostFile = "~/AppData/Roaming/gm3/windows.conf",
        content = "windows\n", address = "platformRc")
    when macos() and arm64():
      fsUserFile(hostFile = "~/.gm3-apple-silicon", content = "arm64\n",
        address = "appleSilicon")
    platformResources()

  hosts:
    "gm3-host": [dev]
"""

  const PlatformToolsModule = """
import repro_profile

proc platformDevTools*(): seq[ActivityElement] =
  @[package "git",
    guarded(windows(), [package "gm3-windows-terminal"]),
    guarded(linux(), [package "gm3-strace"])]

template platformConfig*(targetOverrides: var seq[ConfigOverride]) =
  guarded(targetOverrides, windows()):
    targetOverrides.add ConfigOverride(pkg: "git", key: "autocrlf",
      value: strValue("true"))

template platformResources*(targetResources: var seq[ResourceIntent]) =
  guarded(targetResources, windows()):
    fsUserFile(targetResources, hostFile = "~/gm3-windows-helper.txt",
      content = "helper\n", address = "windowsHelper")
"""

  type Expected = object
    resources: seq[string]   ## "<address>=<hostFile>", sorted
    config: seq[string]      ## "<pkg>.<key>=<value>", sorted
    packages: seq[string]    ## sorted

  proc sortedCopy(xs: seq[string]): seq[string] =
    result = xs
    result.sort()

  proc expectedFor(system: string): Expected =
    ## What the profile declares on `system`, written out by hand.
    let common = "common=~/.gm3-common"
    let base = @["git.userName=gm3"]
    case system
    of "x86_64-linux", "aarch64-linux":
      result.resources = @[common, "platformRc=~/.config/gm3/linux.conf"]
      result.config = base & @["git.credentialHelper=libsecret",
        "tmux.prefix=C-a"]
      result.packages = @["git", "gm3-strace", "ripgrep"]
    of "aarch64-darwin":
      result.resources = @[common,
        "platformRc=~/Library/Preferences/gm3-macos.conf",
        "appleSilicon=~/.gm3-apple-silicon"]
      result.config = base & @["git.credentialHelper=osxkeychain"]
      result.packages = @["git", "gm3-mac-app", "ripgrep"]
    of "x86_64-darwin":
      result.resources = @[common,
        "platformRc=~/Library/Preferences/gm3-macos.conf"]
      result.config = base & @["git.credentialHelper=osxkeychain"]
      result.packages = @["git", "gm3-mac-app", "ripgrep"]
    of "x86_64-windows", "aarch64-windows":
      result.resources = @[common,
        "platformRc=~/AppData/Roaming/gm3/windows.conf",
        "windowsHelper=~/gm3-windows-helper.txt"]
      result.config = base & @["git.autocrlf=true",
        "git.credentialHelper=manager"]
      result.packages = @["git", "gm3-windows-terminal", "ripgrep"]
    else:
      doAssert false, "no expectation for " & system
    result.resources = sortedCopy(result.resources)
    result.config = sortedCopy(result.config)
    result.packages = sortedCopy(result.packages)

  proc observed(evaluation: JsonNode): Expected =
    for r in evaluation["resources"]:
      result.resources.add r["address"].getStr & "=" &
        r["fields"]["hostFile"]["value"].getStr
    for c in evaluation["configOverrides"]:
      result.config.add c["pkg"].getStr & "." & c["key"].getStr & "=" &
        c["value"]["value"].getStr
    for p in evaluation["packages"]:
      result.packages.add p["name"].getStr
    result.resources = sortedCopy(result.resources)
    result.config = sortedCopy(result.config)
    result.packages = sortedCopy(result.packages)

  const Targets = ["x86_64-linux", "aarch64-linux", "x86_64-darwin",
    "aarch64-darwin", "x86_64-windows"]

  suite "repro home export: other platforms":

    test "e2e_export_describes_other_platform_resources":
      let sb = newProfileSandbox("gm3-neutral", NeutralProfile)
      defer: sb.dispose()
      sb.writeProfileFile("modules/platform_tools.nim", PlatformToolsModule)

      let exportRun = sb.runRepro(["home", "export", "--host", "gm3-host"],
        host = "")
      checkpoint("export stderr:\n" & exportRun.stderr)
      require exportRun.exitCode == 0
      let doc = parseJson(exportRun.stdout)

      # The intent holds every platform's elements, guards as data.
      var guards: seq[string]
      for r in doc["intent"]["resources"]:
        guards.add r["address"].getStr & ":" &
          (if r["guard"].kind == JNull: "-" else: r["guard"].getStr)
      checkpoint("resource guards: " & $guards)
      check doc["intent"]["resources"].len == 6
      check "platformRc:linux" in guards
      check "platformRc:macos and not linux" in guards
      check "platformRc:not linux and not macos and windows" in guards
      check "appleSilicon:arm64 and macos" in guards
      check "windowsHelper:windows" in guards
      check "common:-" in guards

      # The probe evaluated the profile for every platform and found it the
      # same everywhere: the document describes all of them.
      checkpoint("platforms: " & $doc["platforms"] & "\nprobe: " &
        $doc["provenance"]["compile"]["probe"])
      for system in targetSystemNames():
        check doc["platforms"][system].getStr == "same"

      for system in Targets:
        checkpoint("target " & system)
        let cli = sb.runRepro(["home", "export", "--host", "gm3-host",
          "--target", system], host = "")
        checkpoint("stderr:\n" & cli.stderr)
        require cli.exitCode == 0
        let viaCli = parseJson(cli.stdout)["evaluation"]
        let viaLibrary = evaluateHomeExport(doc, system)
        check viaCli == viaLibrary
        check viaCli["target"].getStr == system
        check viaCli["host"].getStr == "gm3-host"
        let got = observed(viaCli)
        let want = expectedFor(system)
        check got.resources == want.resources
        check got.config == want.config
        check got.packages == want.packages

      # Vacuity: every platform-specific element is present for its own
      # platform and absent for every other one.
      for (marker, owners) in [
          ("platformRc=~/.config/gm3/linux.conf",
           @["x86_64-linux", "aarch64-linux"]),
          ("platformRc=~/Library/Preferences/gm3-macos.conf",
           @["x86_64-darwin", "aarch64-darwin"]),
          ("appleSilicon=~/.gm3-apple-silicon", @["aarch64-darwin"]),
          ("platformRc=~/AppData/Roaming/gm3/windows.conf",
           @["x86_64-windows"]),
          ("windowsHelper=~/gm3-windows-helper.txt", @["x86_64-windows"])]:
        for system in Targets:
          let has = marker in observed(evaluateHomeExport(doc, system)).resources
          checkpoint(marker & " on " & system & ": " & $has)
          check has == (system in owners)

      # For the compiling platform the evaluation is what the planner plans
      # on this host.
      let plan = sb.runHomePlan(host = "gm3-host")
      checkpoint("plan output:\n" & plan.output)
      require plan.exitCode == 0
      var planned: seq[string]
      for line in plan.createLines:
        for address in ["common", "platformRc", "appleSilicon",
                        "windowsHelper"]:
          if line.contains(address):
            planned.add address
      var evaluated: seq[string]
      for r in evaluateHomeExport(doc, compilingPlatformSystem())["resources"]:
        evaluated.add r["address"].getStr
      check sortedCopy(planned) == sortedCopy(evaluated)
      check planned.len == 2
