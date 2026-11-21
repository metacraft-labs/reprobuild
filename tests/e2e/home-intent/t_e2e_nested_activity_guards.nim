## Nested `when` guards in an activity body are planned where every guard
## holds (reprobuild-pm issue
## 2026-10-18-home-planner-drops-packages-under-nested-activity-guards;
## Home-Profile-Intent-Layer.md §`when` and `if` predicates: "`when` blocks
## nest", the `raspi-tools` example; Core-Invariants.md §Unrecognised Input
## Is Rejected, Not Skipped).
##
## `e2e_nested_guards_conjoin`, through the real `build/bin/repro`, on a
## profile that nests guards both ways the profile macro accepts them -- a
## `when` inside a `when` (two and three levels) and a `guarded(...)` inside
## a `guarded(...)` from a helper module -- with guards that always hold on
## the test host (`linux() or macos() or windows()`) and one that never does
## (`bsd()`):
##
## * `repro home apply --plan` plans every package whose guards all hold, at
##   any depth, and none of those under a false guard (inner or outer);
## * `repro home list` states each reference `enabled` / `excluded`, its
##   guard shown as the conjunction, and its `enabled` lines are exactly the
##   plan's `[package]` section; `why` explains a nested package;
## * `repro home export --target <this system>` (Reprobuild's evaluation,
##   which the Nix reader `nix/lib/intent.nix` must reproduce -- checked
##   against the committed fixtures by `t_e2e_nix_reads_intent_like_export`
##   and the flake check `lib-tests`) evaluates the same packages;
## * an unselected activity's nested packages are `inactive`.
##
## Before the fix the planner read one guard level: the nested packages were
## not planned and `list` reported them `ignored`.
##
## No mocks: the real binary, the real profile compile edge, an isolated
## sandbox (`profile_compile_edge_harness`); packages are bound to fixture
## executables through `REPRO_TEST_PACKAGE_SOURCE` (`fixturePackageEnv`);
## nothing is applied. Platforms: every host (the guards are chosen to hold,
## or not, on Linux, macOS and Windows alike).

import std/[json, sets, strutils, unittest]

import repro_profile_compile

import ../m83/profile_compile_edge_harness

const Tools = """
import repro_profile

proc nestedTools*(): seq[ActivityElement] =
  @[guarded(linux() or macos() or windows(), [
      package "gnm-helper-one",
      guarded(linux() or macos() or windows(), [
        package "gnm-helper-two"]),
      guarded(bsd(), [package "gnm-helper-inner-false"])])]
"""

const Profile = """
import repro_profile
import ./modules/nested_tools

profile "gnmNested":
  activity default:
    `gnm-outer`
    nestedTools()
    when linux() or macos() or windows():
      `gnm-one-level`
      when linux() or macos() or windows():
        `gnm-nested`
        when linux() or macos() or windows():
          `gnm-three-deep`
      when bsd():
        `gnm-inner-false`
    when bsd():
      when linux() or macos() or windows():
        `gnm-outer-false`

  activity extra:
    when linux() or macos() or windows():
      when linux() or macos() or windows():
        `gnm-unselected-nested`

  hosts:
    "gnm-host": [default]
"""

const
  Always = "linux or macos or windows"
  Planned = ["gnm-outer", "gnm-one-level", "gnm-nested", "gnm-three-deep",
    "gnm-helper-one", "gnm-helper-two"]
  NotPlanned = ["gnm-inner-false", "gnm-outer-false",
    "gnm-helper-inner-false", "gnm-unselected-nested"]

proc show(label: string; r: ReproRun) =
  checkpoint label & " (exit " & $r.exitCode & ")\n--- stdout\n" & r.stdout &
    "\n--- stderr\n" & r.stderr

proc listedAs(listing, state, pkg, activity: string; guard = ""): bool =
  let line = "  " & alignLeft(state, 8) & " " & pkg & "  activity=" &
    activity & (if guard.len > 0: "  when " & guard else: "")
  line in listing.splitLines()

proc enabledPackages(listing: string): HashSet[string] =
  for line in listing.splitLines():
    if line.startsWith("  enabled  "):
      result.incl line["  enabled  ".len .. ^1].split("  ")[0]

proc plannedPackages(plan: string): HashSet[string] =
  var inSection = false
  for line in plan.splitLines():
    if line.strip() == "[package]":
      inSection = true
      continue
    if inSection:
      if not line.startsWith("    "):
        break
      let words = line.strip().splitWhitespace()
      if words.len >= 2:
        result.incl words[1]

suite "home planner: nested activity guards":

  test "e2e_nested_guards_conjoin":
    let sb = newProfileSandbox("gnm-rd-nested", Profile)
    defer: sb.dispose()
    sb.writeProfileFile("modules/nested_tools.nim", Tools)
    let env = sb.fixturePackageEnv(@Planned & @NotPlanned)

    let plan = sb.runRepro(["home", "apply", "--plan"], host = "gnm-host",
      extraEnv = env)
    show("apply --plan", plan)
    require plan.exitCode == 0
    let planned = plannedPackages(plan.stdout)
    for pkg in Planned:
      check pkg in planned
    for pkg in NotPlanned:
      check pkg notin planned

    let listed = sb.runRepro(["home", "list"], host = "gnm-host",
      extraEnv = env)
    show("list", listed)
    require listed.exitCode == 0
    let l = listed.stdout
    check enabledPackages(l) == planned
    check not l.contains("ignored")
    check listedAs(l, "enabled", "gnm-outer", "default")
    check listedAs(l, "enabled", "gnm-one-level", "default", Always)
    check listedAs(l, "enabled", "gnm-nested", "default",
      "(" & Always & ") and (" & Always & ")")
    check listedAs(l, "enabled", "gnm-three-deep", "default",
      "(" & Always & ") and (" & Always & ") and (" & Always & ")")
    check listedAs(l, "excluded", "gnm-inner-false", "default",
      "(" & Always & ") and (bsd)")
    check listedAs(l, "excluded", "gnm-outer-false", "default",
      "(bsd) and (" & Always & ")")
    check listedAs(l, "enabled", "gnm-helper-two", "default",
      "(" & Always & ") and (" & Always & ")")
    check listedAs(l, "excluded", "gnm-helper-inner-false", "default",
      "(" & Always & ") and (bsd)")
    check listedAs(l, "inactive", "gnm-unselected-nested", "extra",
      "(" & Always & ") and (" & Always & ")")

    let why = sb.runRepro(["home", "why", "gnm-nested"], host = "gnm-host",
      extraEnv = env)
    show("why gnm-nested", why)
    check why.exitCode == 0
    check why.stdout.contains("package `gnm-nested` <- activity `default` " &
      "under when (" & Always & ") and (" & Always &
      ") [ENABLED on host `gnm-host`]")
    let whyFalse = sb.runRepro(["home", "why", "gnm-inner-false"],
      host = "gnm-host", extraEnv = env)
    show("why gnm-inner-false", whyFalse)
    check whyFalse.exitCode == 0
    check whyFalse.stdout.contains("but the guard does not hold")

    let exported = sb.runRepro(["home", "export", "--host", "gnm-host",
      "--target", compilingPlatformSystem()], host = "", extraEnv = env)
    show("export --target", exported)
    require exported.exitCode == 0
    var evaluated = initHashSet[string]()
    for p in parseJson(exported.stdout)["evaluation"]["packages"]:
      evaluated.incl p["name"].getStr
    check evaluated == planned
