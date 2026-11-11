## `repro home apply --plan` reports a package of an applied concern that has
## no realization on this host apart from drift, and fails on it whatever
## `--allow-drift` / `--reconcile-drift` say: the real apply fails on that
## package, and those flags accept or reconcile drift of an existing object,
## which an unrealizable package is not.
##
## Through the real `build/bin/repro`, a profile names a package no
## definition in scope realizes and declares a whole-object resource over a
## file that already holds other content (one ordinary drift):
##
## * `e2e_plan_counts_an_unrealizable_package_apart_from_drift` -- the
##   summary counts the drift and the unrealizable package separately (the
##   drift count equals the drift rows), and `--plan`, `--plan --allow-drift`
##   and `--plan --reconcile-drift` all exit 1 naming the package. The real
##   apply fails on the same package. With the package removed, the same plan
##   under `--allow-drift` exits 0 and mentions no unrealizable package.
## * `e2e_unrealizable_package_of_a_concern_not_applied_does_not_fail_the_plan`
##   -- on a host whose `applies:` leaves out `packages`, the same package is
##   shown, is not counted, and the plan exits 0.
##
## Before the fix the package was counted as drift: the summary read
## "2 drift(s)" for one drift row and `--plan --allow-drift` exited 0 for a
## plan whose apply fails at package resolution.
##
## No mocks: the real `build/bin/repro`, the real profile compile edge and
## the real planner, in the harness's isolated sandbox (its own HOME, state
## and store). Platforms: every host.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_home_generations

import ../m83/profile_compile_edge_harness

const
  Unrealizable = "repro-unrealizable-fixture"
    ## Defined by nothing in scope: no host inventory realizes it.
  Theirs = "someone else's content\n"
  Resources = "\n  resources:\n" &
    "    fsUserFile(hostFile = \"~/.unreal-gitconfig\", " &
    "content = \"declared\\n\", address = \"gitconfig\")\n"

proc profileWith(packages: string; applies = ""): string =
  result = "import repro_profile\n\nprofile \"unrealizablePackage\":\n" &
    "  activity default:\n    " & packages & "\n"
  if applies.len > 0:
    result.add("\n  hosts:\n    \"" & DefaultSandboxHost & "\":\n" &
      "      activities: [default]\n      applies: [" & applies & "]\n")
  result.add(Resources)

proc show(label: string; r: ReproRun) =
  checkpoint(label & " -> exit " & $r.exitCode & "\n--- stdout\n" &
    r.stdout & "\n--- stderr\n" & r.stderr)

proc both(r: ReproRun): string = r.stdout & r.stderr

proc rowCount(output, verb: string): int =
  for line in output.splitLines():
    if line.strip().startsWith(verb & "  "):
      inc result

proc missingRow(output: string; prefix = ""): string =
  ## The package's `missing` row; `prefix` is the `[package] ` a row of a
  ## concern the host does not apply carries.
  for line in output.splitLines():
    if line.strip().startsWith(prefix & "missing  " & Unrealizable & "  "):
      return line.strip()
  ""

const UnrealizableMessage = "package(s) of an applied concern have no " &
  "realization on this host, so the apply would fail: "

suite "home apply --plan: an unrealizable package is not drift":

  test "e2e_plan_counts_an_unrealizable_package_apart_from_drift":
    let sb = newProfileSandbox("unrealizable",
      profileWith("`" & Unrealizable & "`"))
    defer: sb.dispose()

    # The real apply fails on the package (before any drift is written).
    let applied = sb.runRepro(["home", "apply"])
    show("apply", applied)
    check applied.exitCode != 0
    check Unrealizable in applied.both
    check readCurrentGenerationId(sb.stateDir).len == 0

    writeFile(extendedPath(sb.homeDir / ".unreal-gitconfig"), Theirs)
    for flags in [@[], @["--allow-drift"], @["--reconcile-drift"]]:
      let plan = sb.runRepro(@["home", "apply", "--plan"] & flags)
      show("apply --plan " & flags.join(" "), plan)
      check plan.exitCode == 1
      let row = missingRow(plan.stdout)
      checkpoint("missing row: " & row)
      check row.len > 0
      # The drift count equals the drift rows; the package is counted apart.
      let drifts = rowCount(plan.stdout, "conflict-drift")
      if flags == @["--reconcile-drift"]:
        check drifts == 0
      else:
        check drifts == 1
      check ($drifts & " drift(s), 1 unrealizable package(s)") in plan.stdout
      check ("1 " & UnrealizableMessage & Unrealizable) in plan.stderr
      # Drift is reported as drift only when it is not accepted.
      check ("drift item(s) detected" in plan.stderr) == (flags.len == 0)

    # Positive control: the same plan without the package is accepted.
    writeFile(extendedPath(sb.profilePath), profileWith("discard"))
    let accepted = sb.runRepro(["home", "apply", "--plan", "--allow-drift"])
    show("apply --plan --allow-drift, no package", accepted)
    check accepted.exitCode == 0
    check rowCount(accepted.stdout, "conflict-drift") == 1
    check "1 drift(s)\n" in accepted.stdout
    check "unrealizable package(s)" notin accepted.both
    check "have no realization on this host" notin accepted.both
    check readFile(extendedPath(sb.homeDir / ".unreal-gitconfig")) == Theirs

  test "e2e_unrealizable_package_of_a_concern_not_applied_does_not_fail_" &
      "the_plan":
    let sb = newProfileSandbox("unrealizable-not-applied",
      profileWith("`" & Unrealizable & "`", applies = "files"))
    defer: sb.dispose()
    let plan = sb.runRepro(["home", "apply", "--plan"])
    show("apply --plan, applies: [files]", plan)
    check plan.exitCode == 0
    check missingRow(plan.stdout, "[package] ").len > 0
    check "0 drift(s)\n" in plan.stdout
    check "unrealizable package(s)" notin plan.both
    check "have no realization on this host" notin plan.both
