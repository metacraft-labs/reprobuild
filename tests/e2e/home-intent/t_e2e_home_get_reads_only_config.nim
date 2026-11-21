## `repro home get` reads only `config:` (reprobuild-pm issue
## 2026-10-18-home-get-refuses-a-profile-for-constructs-unrelated-to-config;
## contract: Home-Profile-Intent-Layer.md §Constructs the inspector steps
## over, CLI/home/get.md).
##
## Through the real `build/bin/repro`, on profiles composed the way
## zah/dotfiles' home.nim is:
##
## `e2e_get_steps_over_constructs_outside_config`:
##
## * a helper call in an activity body, an activity `stow:` block and a
##   `const ... = staticRead(...)` before the `profile` header do not stop
##   `get`: it prints the literal `config:` value, exit 0, with the guarded
##   override that applies on the test host resolved last-write-wins and the
##   overridden assignment named on stderr;
## * an unassigned key in a profile whose activities compose helper calls is
##   reported unassigned (exit 1), not as "not enabled": a helper may enable
##   the package, which the text reader cannot see. Without helper calls the
##   "not enabled" diagnosis is kept (exit 1).
##
## Negative control: `repro home set` still refuses the profile with an
## activity helper call (its stated reason: the helper may enable the
## package it validates against), file unchanged.
##
## `e2e_get_answers_a_config_helper_from_the_compiled_profile`: a helper call
## in `config:` -- the one construct that may assign the key -- makes `get`
## compile the profile and answer from it (the helper's assignment wins over
## an earlier literal one); the compiled profile also makes "not enabled"
## exact again. A profile that does not compile is reported as such. After
## `repro home apply` the generation's value is printed; once `home.nim` is
## edited and not applied, `get` refuses, naming the helper call, instead of
## printing the unapplied value; after the next apply it prints the new one.
##
## Before the fix `get` used the strict `loadProfile`, which refused the
## first construct it met anywhere: the activity helper call, or the `const`
## at line 2, and refused every profile with a helper call in `config:`.
##
## No mocks: the real binary, the real inspector and the real profile compile
## edge on a sandbox profile (`profile_compile_edge_harness`); the apply
## binds its packages to fixture executables through
## `REPRO_TEST_PACKAGE_SOURCE` (`fixturePackageEnv`) inside the sandbox's
## isolated HOME, state and store. Platforms: every host.

import std/[strutils, unittest]
from repro_core/paths import extendedPath

import ../m83/profile_compile_edge_harness

const Tools = """
import repro_profile

proc baseTools*(): seq[ActivityElement] =
  @[package "gnm-helper-base"]

template gnmIdentity*(targetOverrides: var seq[ConfigOverride];
                      name: string) =
  targetOverrides.add ConfigOverride(pkg: "git", key: "userName",
    value: strValue(name))
"""

const Composed = """
import repro_profile
import ./modules/gnm_tools

const gnmPayload = staticRead("stow/gnmcfg/.gnmcfg")

profile "probe":
  activity default:
    ripgrep
    baseTools()        # helper splat in an ACTIVITY body
    stow:
      "gnmcfg"

  config:
    git:
      userName = "Probe"
      when linux() or macos() or windows():
        userName = "Probe Host"
"""

const ConfigHelper = """
import repro_profile
import ./modules/gnm_tools

profile "probe":
  activity default:
    ripgrep
    baseTools()

  config:
    git:
      userName = "Probe"
    gnmIdentity(name = "From Helper")
"""

const NoHelpers = """
import repro_profile

profile "probe":
  activity default:
    ripgrep

  config:
    git:
      userName = "Probe"
"""

proc show(label: string; r: ReproRun) =
  checkpoint label & " (exit " & $r.exitCode & ")\n--- stdout\n" & r.stdout &
    "\n--- stderr\n" & r.stderr

proc sandbox(label, text: string): ProfileSandbox =
  result = newProfileSandbox(label, text)
  result.writeProfileFile("modules/gnm_tools.nim", Tools)
  result.writeProfileFile("stow/gnmcfg/.gnmcfg", "cfg\n")

suite "home get reads only config:":

  test "e2e_get_steps_over_constructs_outside_config":
    let sb = sandbox("gnm-rd-get", Composed)
    defer: sb.dispose()
    let got = sb.runRepro(["home", "get", "git.userName"])
    show("get git.userName (composed)", got)
    check got.exitCode == 0
    check got.stdout.strip() == "Probe Host"
    check got.stderr.contains("git.userName is assigned 2 times on this " &
      "host; the last assignment (home.nim:17) wins over home.nim:15")
    check not got.stderr.contains("unstructured")

    # An unassigned key: unassigned, not "not enabled" -- `baseTools()` may
    # enable the package.
    let unset = sb.runRepro(["home", "get", "fd.flags"])
    show("get fd.flags (composed)", unset)
    check unset.exitCode == 1
    check unset.stderr.contains("no value recorded for `fd.flags`")
    check not unset.stderr.contains("is not enabled")

    # Negative control: `set` still refuses an activity helper call.
    let before = readFile(extendedPath(sb.profilePath))
    let setRun = sb.runRepro(["home", "set", "git.userName", "x",
      "--no-apply"])
    show("set git.userName (composed)", setRun)
    check setRun.exitCode == 1
    check setRun.stderr.contains("unstructured profile")
    check readFile(extendedPath(sb.profilePath)) == before

    # Without helper calls the "not enabled" diagnosis is kept.
    let plain = sandbox("gnm-rd-get-plain", NoHelpers)
    defer: plain.dispose()
    let plainGot = plain.runRepro(["home", "get", "git.userName"])
    show("get git.userName (no helpers)", plainGot)
    check plainGot.exitCode == 0
    check plainGot.stdout.strip() == "Probe"
    let notEnabled = plain.runRepro(["home", "get", "fd.flags"])
    show("get fd.flags (no helpers)", notEnabled)
    check notEnabled.exitCode == 1
    check notEnabled.stderr.contains("package `fd` is not enabled")

  test "e2e_get_answers_a_config_helper_from_the_compiled_profile":
    # A helper call in `config:` may assign the key, and only the compiled
    # profile knows what it assigns: `get` compiles the profile and answers
    # from it, as `list` / `why` do. zah/dotfiles assigns `git.userName`
    # this way (`gitIdentity(...)` in `config:`).
    let cfg = sandbox("gnm-rd-get-cfg", ConfigHelper)
    defer: cfg.dispose()
    let got = cfg.runRepro(["home", "get", "git.userName"])
    show("get git.userName (config helper)", got)
    check got.exitCode == 0
    check got.stdout.strip() == "From Helper"
    check got.stderr.contains("git.userName is assigned 2 times on this " &
      "host in the compiled profile")
    check not got.stderr.contains("unstructured")
    # The compiled profile knows what the activity helper enables, so the
    # "not enabled" diagnosis is exact again: `gnm-helper-base` (enabled
    # by `baseTools()`) has no value; `fd` is not enabled.
    let helperPkg = cfg.runRepro(["home", "get", "gnm-helper-base.flags"])
    show("get gnm-helper-base.flags (config helper)", helperPkg)
    check helperPkg.exitCode == 1
    check helperPkg.stderr.contains(
      "no value recorded for `gnm-helper-base.flags`")
    let notEnabled = cfg.runRepro(["home", "get", "fd.flags"])
    show("get fd.flags (config helper)", notEnabled)
    check notEnabled.exitCode == 1
    check notEnabled.stderr.contains("package `fd` is not enabled")

    # A profile that does not compile: the compile diagnostic, exit 1,
    # nothing on stdout.
    let broken = sandbox("gnm-rd-get-broken",
      ConfigHelper.replace("gnmIdentity(", "gnmNoSuchHelper("))
    defer: broken.dispose()
    let brokenGet = broken.runRepro(["home", "get", "git.userName"])
    show("get git.userName (does not compile)", brokenGet)
    check brokenGet.exitCode == 1
    check brokenGet.stdout.strip() == ""
    check brokenGet.stderr.contains("repro home get: profile compilation " &
      "failed for " & broken.profilePath)
    check brokenGet.stderr.contains("gnmNoSuchHelper")

    # With a current generation, `get` reads the recorded activation
    # (interpretation B). The on-disk profile is the one it snapshotted, so
    # compiling it answers for the generation.
    let env = cfg.fixturePackageEnv(["ripgrep", "gnm-helper-base"])
    let applied = cfg.runRepro(["home", "apply"], extraEnv = env)
    show("apply (config helper)", applied)
    require applied.exitCode == 0
    let fromGen = cfg.runRepro(["home", "get", "git.userName"])
    show("get git.userName (after apply)", fromGen)
    check fromGen.exitCode == 0
    check fromGen.stdout.strip() == "From Helper"

    # Edited and not applied: the generation's profile is no longer the one
    # on disk and cannot be compiled from its snapshot, so `get` refuses,
    # naming the helper call, rather than answer with the unapplied value.
    let edited = ConfigHelper.replace("From Helper", "Edited")
    cfg.writeProfileFile("home.nim", edited)
    let stale = cfg.runRepro(["home", "get", "git.userName"])
    show("get git.userName (edited, not applied)", stale)
    check stale.exitCode == 1
    check stale.stdout.strip() == ""
    check stale.stderr.contains("unstructured profile at " &
      cfg.profilePath & ":12")
    check stale.stderr.contains("helper call `gnmIdentity(name = " &
      "\"From Helper\")` (" & cfg.profilePath & ":12) in `config:`")
    check stale.stderr.contains("differs from the one on disk")
    check not stale.stdout.contains("Edited")

    # Applied: the new value.
    let reapplied = cfg.runRepro(["home", "apply"], extraEnv = env)
    show("apply (edited)", reapplied)
    require reapplied.exitCode == 0
    let fresh = cfg.runRepro(["home", "get", "git.userName"])
    show("get git.userName (after second apply)", fresh)
    check fresh.exitCode == 0
    check fresh.stdout.strip() == "Edited"
