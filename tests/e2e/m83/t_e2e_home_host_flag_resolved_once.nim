## GM8: every `repro home` command resolves the host identity through ONE
## resolver (`host_identity.selectHost`, reached through the CLI's
## `resolveCommandHost`), and `repro home apply`, `apply --plan` and `plan`
## take `--host` like `list`, `why`, `enable`, `disable`, `export` and
## `facts` already did (Home-Profile-Intent-Layer.md §Host Identity).
##
## The profile has two declared hosts that select different activities
## (`gm8-alpha` adds `extra`, which carries the package `gm8-extra`) and a
## resource guarded by `host == "gm8-alpha"`. Gates:
##
## * `e2e_home_apply_plan_accepts_host`: `repro home apply --plan --host H`
##   plans H's selection -- `gm8-extra` for alpha, not for beta -- and prints
##   exactly what `REPRO_HOST=H repro home apply --plan` prints.
## * `e2e_home_plan_accepts_host`: `repro home plan --host H` evaluates the
##   resource guards for H: `alphaOnly` for alpha only.
## * `e2e_home_apply_accepts_host`: a real `repro home apply --host H` into
##   the sandbox HOME records generation host H (`repro home history`) and
##   installs H's packages: `gm8-extra`'s launcher after alpha, gone after
##   beta.
## * `e2e_home_host_conflict_refused_everywhere`: `$REPRO_HOST=gm8-alpha`
##   with `--host gm8-beta` is refused (exit 2, naming the conflict) by
##   every command that acts AS the host -- apply, apply --plan, plan,
##   export, facts, list, why -- and nothing changes: no generation, the
##   profile's bytes as they were. The same name in both is accepted.
##   `enable` / `disable` are the documented exception: their `--host` names
##   the TARGET entry (and remote-apply host), so with `$REPRO_HOST` set to
##   another host they edit exactly the named entry.
## * `e2e_home_undeclared_host_refused`: spec Open question 6 (answered by
##   GM8). `--host gm8-gamma`, which the registry does not name, is refused
##   by apply, apply --plan, plan, export, facts, list and why, naming the
##   declared hosts; a real apply creates no generation. Negative control:
##   the same profile WITHOUT a `hosts:` registry plans `gm8-gamma` with
##   `default` alone (a host-agnostic profile has no registry to miss).
##
## Falsifying mutations (performed when this gate was written; see the
## milestone file): (a) `runHomeApply` not calling `resolveCommandHost`, so
## `--host` is parsed but not installed -- the apply plans the machine's own
## identity and the first two gates go red; (b) `selectHost` without the
## `$REPRO_HOST` conflict check -- every conflict case exits 0; (c)
## `enabledActivitiesFor` without the undeclared-host refusal -- gamma plans
## `default` alone and the last gate goes red.
##
## No mocks: the real `build/bin/repro`, the real profile compile edge and
## the real store, all in the harness's isolated sandbox. Packages are bound
## to fixture executables through the documented `REPRO_TEST_PACKAGE_SOURCE`
## seam (`fixturePackageEnv`), so the real `path` realization installs them
## without network access. Platforms: every host (launchers are checked the
## way the GM4 rollback gate checks them).

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_home_generations

import ./profile_compile_edge_harness

const ProfileText = """
import repro_profile

profile "gm8HostFlag":
  activity default:
    `gm8-base`

  activity extra:
    `gm8-extra`

  resources:
    when host == "gm8-alpha":
      fsUserFile(hostFile = "~/.gm8-alpha-only", content = "alpha\n",
        address = "alphaOnly")

  hosts:
    "gm8-alpha": [extra]
    "gm8-beta":  [default]
"""

const TextualProfileText = """
import repro_profile

profile "gm8Textual":
  activity default:
    `gm8-base`

  activity extra:
    `gm8-extra`

  hosts:
    "gm8-alpha": [extra]
    "gm8-beta":  [default]
"""
  ## The same selection without the `resources:` block, for `list` and `why`:
  ## they read the profile with the structural (text) parser, which does not
  ## read a constructor-call resource.

const RegistryFreeProfileText = """
import repro_profile

profile "gm8NoRegistry":
  activity default:
    `gm8-base`

  activity extra:
    `gm8-extra`
"""

const Packages = ["gm8-base", "gm8-extra"]

proc launcherPresent(sb: ProfileSandbox; command: string): bool =
  when defined(windows):
    let stable = sb.stateDir / "bin"
    fileExists(stable / (command & ".exe")) or
      fileExists(stable / (command & ".cmd"))
  else:
    let active = readCurrentGenerationId(sb.stateDir)
    if active.len == 0: return false
    fileExists(generationDir(sb.stateDir, active) / "bin" / command)

proc show(label: string; r: ReproRun) =
  checkpoint(label & " -> exit " & $r.exitCode & "\n--- stdout\n" &
    r.stdout & "\n--- stderr\n" & r.stderr)

proc plansPackage(r: ReproRun; pkg: string): bool =
  ## The `--plan` preview names the package on one of its package lines.
  for line in r.stdout.splitLines():
    let words = line.strip().splitWhitespace()
    if words.len >= 2 and words[1] == pkg:
      return true
  false

suite "GM8: one host resolver for every repro home command":

  test "e2e_home_apply_plan_accepts_host":
    let sb = newProfileSandbox("gm8-plan-host", ProfileText)
    defer: sb.dispose()
    let env = sb.fixturePackageEnv(Packages)
    let alpha = sb.runRepro(["home", "apply", "--plan", "--host",
      "gm8-alpha"], host = "", extraEnv = env)
    show("apply --plan --host gm8-alpha", alpha)
    check alpha.exitCode == 0
    check alpha.plansPackage("gm8-base")
    check alpha.plansPackage("gm8-extra")
    let beta = sb.runRepro(["home", "apply", "--plan", "--host=gm8-beta"],
      host = "", extraEnv = env)
    show("apply --plan --host=gm8-beta", beta)
    check beta.exitCode == 0
    check beta.plansPackage("gm8-base")
    check not beta.plansPackage("gm8-extra")
    # `--host` and `$REPRO_HOST` select alike: one resolver.
    let viaEnv = sb.runRepro(["home", "apply", "--plan"], host = "gm8-alpha",
      extraEnv = env)
    show("REPRO_HOST=gm8-alpha apply --plan", viaEnv)
    check viaEnv.exitCode == 0
    check viaEnv.stdout == alpha.stdout
    # Both, naming the same host: accepted.
    let both = sb.runRepro(["home", "apply", "--plan", "--host", "gm8-alpha"],
      host = "gm8-alpha", extraEnv = env)
    show("REPRO_HOST=gm8-alpha apply --plan --host gm8-alpha", both)
    check both.exitCode == 0
    check both.stdout == alpha.stdout
    # An empty --host is refused, not read as "no flag".
    let empty = sb.runRepro(["home", "apply", "--plan", "--host="], host = "",
      extraEnv = env)
    show("apply --plan --host=", empty)
    check empty.exitCode == 2
    check empty.stderr.contains("--host needs a non-empty name")

  test "e2e_home_plan_accepts_host":
    let sb = newProfileSandbox("gm8-resource-plan-host", ProfileText)
    defer: sb.dispose()
    let alpha = sb.runRepro(["home", "plan", "--host", "gm8-alpha"],
      host = "")
    show("plan --host gm8-alpha", alpha)
    check alpha.exitCode == 0
    check alpha.stdout.contains("alphaOnly")
    let beta = sb.runRepro(["home", "plan", "--host", "gm8-beta"], host = "")
    show("plan --host gm8-beta", beta)
    check beta.exitCode == 0
    check not beta.stdout.contains("alphaOnly")
    # Vacuity: the plan has content for beta too (it is not just empty).
    check beta.stdout.strip().len > 0

  test "e2e_home_apply_accepts_host":
    let sb = newProfileSandbox("gm8-apply-host", ProfileText)
    defer: sb.dispose()
    let env = sb.fixturePackageEnv(Packages)
    let alpha = sb.runRepro(["home", "apply", "--host", "gm8-alpha"],
      host = "", extraEnv = env)
    show("apply --host gm8-alpha", alpha)
    require alpha.exitCode == 0
    check sb.launcherPresent("gm8-base")
    check sb.launcherPresent("gm8-extra")
    check fileExists(extendedPath(sb.homeDir / ".gm8-alpha-only"))
    let history1 = sb.runRepro(["home", "history"], host = "",
      extraEnv = env)
    show("history", history1)
    check history1.stdout.contains("host=gm8-alpha")

    let beta = sb.runRepro(["home", "apply", "--host", "gm8-beta"],
      host = "", extraEnv = env)
    show("apply --host gm8-beta", beta)
    require beta.exitCode == 0
    check sb.launcherPresent("gm8-base")
    check not sb.launcherPresent("gm8-extra")
    check not fileExists(extendedPath(sb.homeDir / ".gm8-alpha-only"))
    let history2 = sb.runRepro(["home", "history"], host = "",
      extraEnv = env)
    show("history", history2)
    check history2.stdout.contains("host=gm8-beta")

  test "e2e_home_host_conflict_refused_everywhere":
    let sb = newProfileSandbox("gm8-host-conflict", ProfileText)
    defer: sb.dispose()
    let env = sb.fixturePackageEnv(Packages)
    let profileBefore = readFile(extendedPath(sb.profilePath))
    let commands = @[
      @["home", "apply", "--host", "gm8-beta"],
      @["home", "apply", "--plan", "--host", "gm8-beta"],
      @["home", "plan", "--host", "gm8-beta"],
      @["home", "export", "--host", "gm8-beta"],
      @["home", "facts", "--host", "gm8-beta"],
      @["home", "list", "--host", "gm8-beta"],
      @["home", "why", "gm8-extra", "--host", "gm8-beta"]]
    for args in commands:
      let r = sb.runRepro(args, host = "gm8-alpha", extraEnv = env)
      show(args.join(" ") & " (REPRO_HOST=gm8-alpha)", r)
      check r.exitCode == 2
      check r.stderr.contains("--host gm8-beta conflicts with " &
        "$REPRO_HOST=gm8-alpha")
      check r.stdout.len == 0
    check readCurrentGenerationId(sb.stateDir).len == 0
    check readFile(extendedPath(sb.profilePath)) == profileBefore

    # enable / disable: --host is the target entry, not this machine.
    let textual = newProfileSandbox("gm8-enable-target", TextualProfileText)
    defer: textual.dispose()
    let enabled = textual.runRepro(["home", "enable", "extra", "--host",
      "gm8-beta", "--no-apply"], host = "gm8-alpha")
    show("enable extra --host gm8-beta (REPRO_HOST=gm8-alpha)", enabled)
    check enabled.exitCode == 0
    let edited = readFile(extendedPath(textual.profilePath))
    check edited.contains("\"gm8-beta\":  [default, extra]") or
      edited.contains("\"gm8-beta\": [default, extra]")
    check edited.contains("\"gm8-alpha\": [extra]")
    check readCurrentGenerationId(textual.stateDir).len == 0

  test "e2e_home_undeclared_host_refused":
    let sb = newProfileSandbox("gm8-undeclared-host", ProfileText)
    defer: sb.dispose()
    let env = sb.fixturePackageEnv(Packages)
    let commands = @[
      @["home", "apply", "--host", "gm8-gamma"],
      @["home", "apply", "--plan", "--host", "gm8-gamma"],
      @["home", "plan", "--host", "gm8-gamma"],
      @["home", "export", "--host", "gm8-gamma"],
      @["home", "facts", "--host", "gm8-gamma"]]
    const Refusal = "host `gm8-gamma` is not declared in the profile's " &
      "hosts: registry (declared: gm8-alpha, gm8-beta)"
    for args in commands:
      let r = sb.runRepro(args, host = "", extraEnv = env)
      show(args.join(" "), r)
      check r.exitCode == 1
      check r.stderr.contains(Refusal)
    let textual = newProfileSandbox("gm8-undeclared-list", TextualProfileText)
    defer: textual.dispose()
    for args in [@["home", "list", "--host", "gm8-gamma"],
                 @["home", "why", "gm8-base", "--host", "gm8-gamma"]]:
      let r = textual.runRepro(args, host = "")
      show(args.join(" "), r)
      check r.exitCode == 1
      check r.stderr.contains(Refusal)
    # Vacuity for the textual profile: a declared host lists normally.
    let listed = textual.runRepro(["home", "list", "--host", "gm8-alpha"],
      host = "")
    show("list --host gm8-alpha", listed)
    check listed.exitCode == 0
    check listed.stdout.contains("enabled  gm8-extra")
    check readCurrentGenerationId(sb.stateDir).len == 0
    check not fileExists(extendedPath(sb.homeDir / ".gm8-alpha-only"))
    # $REPRO_HOST is refused the same way as --host.
    let viaEnv = sb.runRepro(["home", "apply", "--plan"], host = "gm8-gamma",
      extraEnv = env)
    show("REPRO_HOST=gm8-gamma apply --plan", viaEnv)
    check viaEnv.exitCode == 1
    check viaEnv.stderr.contains("is not declared")

    # Negative control: a profile without a registry is host-agnostic.
    let free = newProfileSandbox("gm8-no-registry", RegistryFreeProfileText)
    defer: free.dispose()
    let freeEnv = free.fixturePackageEnv(Packages)
    let planned = free.runRepro(["home", "apply", "--plan", "--host",
      "gm8-gamma"], host = "", extraEnv = freeEnv)
    show("no registry: apply --plan --host gm8-gamma", planned)
    check planned.exitCode == 0
    check planned.plansPackage("gm8-base")
    check not planned.plansPackage("gm8-extra")
