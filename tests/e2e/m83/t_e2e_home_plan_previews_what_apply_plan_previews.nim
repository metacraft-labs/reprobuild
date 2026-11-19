## `repro home plan` previews what `repro home apply` would do: the same
## preview `repro home apply --plan` prints -- packages, launchers, stow,
## generated files, managed blocks and resources -- through the one
## procedure (CLI/home/plan.md; Core-Invariants.md §One Implementation Per
## Concern). Regression test for reprobuild-pm
## `issues/2026-11-17-home-plan-omits-the-packages-that-home-apply-plan-previews.md`:
## `repro home plan` planned the `resources:` block alone, so a profile of
## packages printed `0 resource(s) planned` while `apply --plan` previewed
## the packages and their launchers.
##
## Gates:
##
## * `e2e_home_plan_lists_the_packages_apply_plan_lists`: a profile whose host
##   selects two packages and declares one resource. `repro home plan` prints
##   exactly what `repro home apply --plan` prints, but for the command named
##   in the header, and that text has a `[package]` and a `[launcher]` line
##   for each package and the resource under `[resource]`. The same holds for
##   the issue's own case, a host whose `hosts:` entry says
##   `applies: [packages]`. `--json` carries the package operations.
## * `e2e_home_plan_fails_on_an_unrealizable_package_as_apply_plan_does`:
##   without the package fixtures neither package has a realization; both
##   commands exit 1 and name both packages, so `repro home plan` no longer
##   reports a clean plan for an apply that would fail.
##
## Falsifying mutation (performed when this gate was written): restoring
## `runHomePlan`'s own resource-only planner makes the first gate fail on the
## `[package]` line and the second exit 0.
##
## No mocks: the real `build/bin/repro`, the real profile compile edge and
## the real planner, in the harness's isolated sandbox. Packages are bound to
## fixture executables through the documented `REPRO_TEST_PACKAGE_SOURCE`
## seam (`fixturePackageEnv`), as the GM8 host-flag gate binds them.
## Platforms: every host.

import std/[json, strutils, unittest]

import ./profile_compile_edge_harness

const ProfileText = """
import repro_profile

profile "homePlanPreview":
  activity default:
    `hpp-alpha`
    `hpp-beta`

  resources:
    fsUserFile(hostFile = "~/.hpp-rc", content = "hpp\n", address = "hppRc")

  hosts:
    "hpp-all": [default]
    "hpp-pkgs":
      activities: [default]
      applies: [packages]
"""

const Packages = ["hpp-alpha", "hpp-beta"]

proc show(label: string; r: ReproRun) =
  checkpoint(label & " -> exit " & $r.exitCode & "\n--- stdout\n" &
    r.stdout & "\n--- stderr\n" & r.stderr)

proc linesUnder(text, header: string): seq[string] =
  ## The item lines of the `  [<header>]` section of a preview.
  var inside = false
  for line in text.splitLines():
    if line.startsWith("  [") and not line.startsWith("   "):
      inside = line.strip() == "[" & header & "]"
    elif inside and line.startsWith("    "):
      result.add line.strip()

proc names(lines: seq[string]): seq[string] =
  for line in lines:
    let words = line.splitWhitespace()
    if words.len >= 2:
      result.add words[1]

suite "repro home plan is the apply --plan preview":

  test "e2e_home_plan_lists_the_packages_apply_plan_lists":
    let sb = newProfileSandbox("home-plan-preview", ProfileText)
    defer: sb.dispose()
    let env = sb.fixturePackageEnv(Packages)
    for host in ["hpp-all", "hpp-pkgs"]:
      let plan = sb.runRepro(["home", "plan", "--host", host], host = "",
        extraEnv = env)
      show("plan --host " & host, plan)
      let applyPlan = sb.runRepro(["home", "apply", "--plan", "--host", host],
        host = "", extraEnv = env)
      show("apply --plan --host " & host, applyPlan)
      check plan.exitCode == 0
      check applyPlan.exitCode == 0
      check plan.stdout.startsWith("repro home plan: ")
      # One preview: identical but for the command the header names.
      check plan.stdout == applyPlan.stdout.replace(
        "repro home apply --plan: ", "repro home plan: ")
      # The packages and their launchers -- what the defect dropped.
      check names(plan.stdout.linesUnder("package")) == @Packages
      check names(plan.stdout.linesUnder("launcher")) == @Packages
      if host == "hpp-all":
        check names(plan.stdout.linesUnder("resource")) == @["hppRc"]
      else:
        # `applies: [packages]`: the file resource belongs to `files`, so it
        # is planned but listed as not applied, never as a `[resource]`.
        check plan.stdout.contains("concerns applied: packages")
        check plan.stdout.linesUnder("resource").len == 0
        check plan.stdout.contains("hppRc")

    let json = sb.runRepro(["home", "plan", "--host", "hpp-all", "--json"],
      host = "", extraEnv = env)
    show("plan --json", json)
    check json.exitCode == 0
    let doc = parseJson(json.stdout)
    check doc{"schemaId"}.getStr() == "reprobuild.home.plan.v2"
    var packages, resources: seq[string]
    for op in doc{"operations"}.getElems():
      case op{"category"}.getStr()
      of "package": packages.add op{"name"}.getStr()
      of "resource":
        # A released record carries `resource: null`; a fresh sandbox has
        # none, so every resource entry here is a planner decision.
        let decision = op{"resource"}
        check decision != nil and decision.kind == JObject
        if decision != nil and decision.kind == JObject:
          resources.add decision{"address"}.getStr()
          check decision{"action"}.getStr() == "create"
      else: discard
    check packages == @Packages
    check resources == @["hppRc"]
    check doc{"operationCount"}.getInt() == doc{"operations"}.getElems().len
    check not doc{"fails"}.getBool()

  test "e2e_home_plan_fails_on_an_unrealizable_package_as_apply_plan_does":
    let sb = newProfileSandbox("home-plan-unrealizable", ProfileText)
    defer: sb.dispose()
    for args in [@["home", "plan", "--host", "hpp-all"],
                 @["home", "apply", "--plan", "--host", "hpp-all"]]:
      let r = sb.runRepro(args, host = "")
      show(args.join(" "), r)
      check r.exitCode == 1
      for pkg in Packages:
        check r.stderr.contains(pkg)
      check r.stderr.contains("no realization")
