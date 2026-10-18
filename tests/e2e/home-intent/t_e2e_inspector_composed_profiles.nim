## `repro home list` / `why` / `add` / `remove` / `enable` / `disable` on a
## profile that composes helpers (reprobuild-pm issues
## 2026-10-13-home-list-and-why-reject-profiles-that-compose-helpers,
## 2026-10-15-home-enable-disable-refuse-hosts-edit-in-profiles-that-compose-helpers,
## 2026-10-17-home-inspector-rejects-activity-resources-blocks; contract:
## Home-Profile-Intent-Layer.md §Constructs the inspector steps over and
## §CLI Edit Semantics, CLI/home/list.md, why.md, remove.md, enable.md).
##
## The `composed` fixture has every construct zah/dotfiles' home.nim uses
## that the text inspector cannot read: a `const` read with `staticRead`
## before the `profile` header, helper calls in activity bodies (a helper
## module whose elements are `guarded(...)`), an activity `stow:` block (one
## with a `when` inside), an activity `resources:` block (with a multi-line
## constructor call), an activity whose body is only a `resources:` block,
## a helper call in `config:`, constructor calls in the profile-level
## `resources:` (multi-line, one with a `)` inside a string and another in a
## trailing comment) and a resource helper call, and `hosts:` lists that
## span lines in both the flat and the block form. Gates, all through the
## real `build/bin/repro`:
##
## * `e2e_list_why_read_the_compiled_profile`: `list` names the packages the
##   helpers contribute, each with its activity, guard and state, and its
##   `enabled` lines are exactly the `[package]` section of `repro home apply
##   --plan` for the same host (two hosts); `why` explains a helper's
##   package. A reference under a nested `when` is reported `ignored` and is
##   indeed not planned (the planner reads one guard level; issue
##   2026-10-18-home-planner-drops-packages-under-nested-activity-guards).
## * `e2e_add_remove_step_over_composed_constructs`: `add` writes the package
##   line beside the helper calls and before the activity's `stow:` /
##   `resources:` blocks -- every other byte of the file kept -- and the
##   edited profile still compiles and lists the package; `remove` restores
##   the original bytes; `remove` of a package only a helper contributes
##   exits 1, names the helper calls in scope (with their lines) and leaves
##   the file unchanged.
## * `e2e_enable_disable_keep_the_host_list_layout`: edits of multi-line,
##   commented and empty host lists, compared byte-for-byte with the
##   expected file (wrapping at column 80 included); the composed fixture's
##   edits compile and select what they say.
##
## Negative controls: `repro home set` still refuses the composed profile
## (it reads `config:`, where a helper call may assign the key); `add` still
## refuses a `for` loop in an activity body, while `enable` edits that
## profile's `hosts:` (it reads nothing else); a host list that never closes
## is refused with the file unchanged; `remove` of an absent package in a
## profile without helper calls is still exit 0.
##
## Falsifying mutations performed when this gate was written (M1-M9) are
## recorded in the resolution of reprobuild-pm issue
## 2026-10-13-home-list-and-why-reject-profiles-that-compose-helpers.
##
## No mocks: the real binary, the real profile compile edge, an isolated
## sandbox (`profile_compile_edge_harness`). Packages are bound to fixture
## executables through the documented `REPRO_TEST_PACKAGE_SOURCE` seam
## (`fixturePackageEnv`) so `apply --plan` resolves them without network
## access; nothing is applied. Platforms: every host -- guard expectations
## are computed for the platform the test runs on.

import std/[json, sets, strutils, unittest]
from repro_core/paths import extendedPath

import ../m83/profile_compile_edge_harness

const ToolsModule = """
import repro_profile

proc baseTools*(): seq[ActivityElement] =
  @[package "gnm-helper-base",
    guarded(linux(), [package "gnm-helper-linux"]),
    guarded(windows(), [package "gnm-helper-windows"])]

proc deskTools*(): seq[ActivityElement] =
  @[package "gnm-helper-desk"]

template gnmIdentity*(targetOverrides: var seq[ConfigOverride];
                      name: string) =
  targetOverrides.add ConfigOverride(pkg: "git", key: "userName",
    value: strValue(name))

template gnmShell*(targetResources: var seq[ResourceIntent]) =
  fsUserFile(targetResources, hostFile = "~/.gnm-shell", content = "s\n",
    address = "gnmShell")
"""

const Composed = """
# A profile composed the way zah/dotfiles' home.nim is.
import repro_profile
import ./modules/gnm_tools

const gnmPayload = staticRead("stow/gnmcfg/.gnmcfg")

profile "gnmComposed":
  activity default:
    baseTools()             # helper splat
    ripgrep
    stow:
      when windows():
        "gnmwin"

  activity desktop:
    deskTools()
    `gnm-direct-desk`

    # The stow packages and resources that belong to the desktop.
    stow:
      "gnmcfg"

    resources:
      when linux():
        fsUserFile(hostFile = "~/.gnm-desktop",
          content = "desk\n",
          address = "gnmDesktop")

  activity extra:
    resources:
      fsUserFile(hostFile = "~/.gnm-extra", content = "e\n",
        address = "gnmExtra")

  config:
    gnmIdentity(name = "Gnm Tester")

  resources:
    when linux():
      fsUserFile(
        hostFile = "~/.gnm-payload",
        content = gnmPayload,
        address = "gnmPayload")
      fsUserFile(hostFile = "~/.gnm-paren)", content = "(no paren\n",
        address = "gnmParen")  # a ) in a comment
    gnmShell()

  hosts:
    "gnm-wide":       [default, desktop,
                       extra]
    "gnm-block":
      activities: [default,
                   desktop]
      system: managedElsewhere("example/infra")
    "gnm-flat": [default]
"""

const Nested = """
import repro_profile

profile "gnmNested":
  activity default:
    `gnm-outer`
    when linux() or macos() or windows():
      `gnm-one-level`
      when linux() or macos() or windows():
        `gnm-nested`
"""

const HostLayouts = """
import repro_profile

profile "gnmHosts":
  activity default:
    ripgrep
    for pkg in ["x"]:
      pkg

  hosts:
    "long-list": [default,
                  alpha_activity_name, beta_activity_name, gamma_activity_nm]
    "single": [default, alpha_activity_name]   # trailing comment
    "only": [alpha_activity_name]
"""

const Packages = ["gnm-helper-base", "gnm-helper-linux",
  "gnm-helper-windows", "ripgrep", "gnm-helper-desk", "gnm-direct-desk",
  "gnm-added", "gnm-outer", "gnm-one-level", "gnm-nested"]

proc show(label: string; r: ReproRun) =
  checkpoint label & " (exit " & $r.exitCode & ")\n--- stdout\n" & r.stdout &
    "\n--- stderr\n" & r.stderr

proc composedSandbox(label: string): ProfileSandbox =
  result = newProfileSandbox(label, Composed)
  result.writeProfileFile("modules/gnm_tools.nim", ToolsModule)
  result.writeProfileFile("stow/gnmcfg/.gnmcfg", "cfg\n")
  result.writeProfileFile("stow/gnmwin/.gnmwin", "win\n")

proc profileText(sb: ProfileSandbox): string =
  readFile(extendedPath(sb.profilePath))

proc listedAs(listing, state, pkg, activity: string; guard = ""): bool =
  ## Whether `repro home list` printed exactly this reference line.
  let line = "  " & alignLeft(state, 8) & " " & pkg & "  activity=" &
    activity & (if guard.len > 0: "  when " & guard else: "")
  line in listing.splitLines()

proc enabledPackages(listing: string): HashSet[string] =
  for line in listing.splitLines():
    if line.startsWith("  enabled  "):
      result.incl line["  enabled  ".len .. ^1].split("  ")[0]

proc plannedPackages(plan: string): HashSet[string] =
  ## The package names of `repro home apply --plan`'s `[package]` section.
  var inSection = false
  for line in plan.splitLines():
    if line.strip() == "[package]":
      inSection = true
      continue
    if inSection:
      # `    <decision>  <package>  (<detail>)`
      if not line.startsWith("    "):
        break
      let words = line.strip().splitWhitespace()
      if words.len >= 2:
        result.incl words[1]

const
  OnLinux = defined(linux)
  OnWindows = defined(windows)

suite "inspector: profiles that compose helpers":

  test "e2e_list_why_read_the_compiled_profile":
    let sb = composedSandbox("gnm-ra-list")
    defer: sb.dispose()
    let env = sb.fixturePackageEnv(Packages)
    let before = sb.profileText()
    for host in ["gnm-wide", "gnm-flat"]:
      let listed = sb.runRepro(["home", "list"], host = host, extraEnv = env)
      show("list " & host, listed)
      require listed.exitCode == 0
      let l = listed.stdout
      check l.contains("repro home list: profile=" & sb.profilePath &
        " host=" & host)
      check l.contains("  guards evaluated for platform=")
      # Packages only the helper calls contribute, with their guards.
      check listedAs(l, "enabled", "gnm-helper-base", "default")
      check listedAs(l, (if OnLinux: "enabled" else: "excluded"),
        "gnm-helper-linux", "default", "linux")
      check listedAs(l, (if OnWindows: "enabled" else: "excluded"),
        "gnm-helper-windows", "default", "windows")
      check listedAs(l, "enabled", "ripgrep", "default")
      let deskState = if host == "gnm-wide": "enabled" else: "inactive"
      check listedAs(l, deskState, "gnm-helper-desk", "desktop")
      check listedAs(l, deskState, "gnm-direct-desk", "desktop")
      # The enabled lines are exactly what the planner plans.
      let plan = sb.runRepro(["home", "apply", "--plan"], host = host,
        extraEnv = env)
      show("apply --plan " & host, plan)
      require plan.exitCode == 0
      let planned = plannedPackages(plan.stdout)
      check planned.len >= 2
      check enabledPackages(l) == planned
    let why = sb.runRepro(["home", "why", "gnm-helper-desk"],
      host = "gnm-flat", extraEnv = env)
    show("why gnm-helper-desk (gnm-flat)", why)
    check why.exitCode == 0
    check why.stdout.contains("package `gnm-helper-desk` <- activity " &
      "`desktop` [NOT enabled on host `gnm-flat`")
    check why.stdout.contains("is declared but NOT active on `gnm-flat`")
    let whyLinux = sb.runRepro(["home", "why", "gnm-helper-linux"],
      host = "gnm-wide", extraEnv = env)
    show("why gnm-helper-linux", whyLinux)
    check whyLinux.exitCode == 0
    check whyLinux.stdout.contains("<- activity `default` under when linux [" &
      (if OnLinux: "ENABLED on host `gnm-wide`]"
       else: "activity enabled on host `gnm-wide`, but the guard does not hold"))
    let absent = sb.runRepro(["home", "why", "gnm-not-here"],
      host = "gnm-wide", extraEnv = env)
    check absent.exitCode == 0
    check absent.stdout.contains("is NOT declared in any activity")
    check sb.profileText() == before

    # Nested guards: `list` reports what the planner does with them.
    let nested = newProfileSandbox("gnm-ra-nested", Nested)
    defer: nested.dispose()
    let nestedEnv = nested.fixturePackageEnv(Packages)
    let nl = nested.runRepro(["home", "list"], extraEnv = nestedEnv)
    show("list (nested)", nl)
    require nl.exitCode == 0
    check listedAs(nl.stdout, "enabled", "gnm-outer", "default")
    check listedAs(nl.stdout, "enabled", "gnm-one-level", "default",
      "linux or macos or windows")
    check listedAs(nl.stdout, "ignored", "gnm-nested", "default",
      "(linux or macos or windows) and (linux or macos or windows)")
    let np = nested.runRepro(["home", "apply", "--plan"],
      extraEnv = nestedEnv)
    show("apply --plan (nested)", np)
    require np.exitCode == 0
    check enabledPackages(nl.stdout) == plannedPackages(np.stdout)
    check "gnm-nested" notin plannedPackages(np.stdout)

  test "e2e_add_remove_step_over_composed_constructs":
    let sb = composedSandbox("gnm-ra-addrm")
    defer: sb.dispose()
    let env = sb.fixturePackageEnv(Packages)
    let original = sb.profileText()
    proc home(args: varargs[string]): ReproRun =
      result = sb.runRepro(@["home"] & @args, host = "gnm-wide",
        extraEnv = env)
      show(args.join(" "), result)

    # Into an activity with helper calls and stow:/resources: blocks: after
    # the last element, before the blocks.
    check home("add", "gnm-added", "--activity", "desktop",
      "--no-apply").exitCode == 0
    let added = original.replace("    `gnm-direct-desk`\n",
      "    `gnm-direct-desk`\n    `gnm-added`\n")
    check added != original
    check sb.profileText() == added
    let listed = home("list")
    require listed.exitCode == 0
    check listedAs(listed.stdout, "enabled", "gnm-added", "desktop")
    check home("remove", "gnm-added", "--activity", "desktop",
      "--no-apply").exitCode == 0
    check sb.profileText() == original

    # A new `when` block goes before the activity's `stow:` block.
    check home("add", "gnm-added", "--when", "windows",
      "--no-apply").exitCode == 0
    check sb.profileText() == original.replace("    ripgrep\n",
      "    ripgrep\n    when windows:\n      `gnm-added`\n")
    writeFile(extendedPath(sb.profilePath), original)

    # An activity whose body is only a `resources:` block.
    check home("add", "gnm-added", "--activity", "extra",
      "--no-apply").exitCode == 0
    check sb.profileText() == original.replace("  activity extra:\n",
      "  activity extra:\n    `gnm-added`\n")
    let listed2 = home("list", "--host", "gnm-wide")
    require listed2.exitCode == 0
    check listedAs(listed2.stdout, "enabled", "gnm-added", "extra")
    writeFile(extendedPath(sb.profilePath), original)

    # A package line is removed as before.
    check home("remove", "ripgrep", "--no-apply").exitCode == 0
    check sb.profileText() == original.replace("    ripgrep\n", "")
    writeFile(extendedPath(sb.profilePath), original)

    # A package only a helper contributes: refused, every call in scope
    # named with its line, file unchanged.
    let helperOnly = home("remove", "gnm-helper-base", "--no-apply")
    check helperOnly.exitCode == 1
    check helperOnly.stderr.contains("`gnm-helper-base` has no package line")
    check helperOnly.stderr.contains("activity default: helper call " &
      "`baseTools()` (" & sb.profilePath & ":9)")
    check helperOnly.stderr.contains("activity desktop: helper call " &
      "`deskTools()` (" & sb.profilePath & ":16)")
    check sb.profileText() == original
    let scoped = home("remove", "gnm-helper-base", "--activity", "default",
      "--no-apply")
    check scoped.exitCode == 1
    check scoped.stderr.contains("`baseTools()`")
    check not scoped.stderr.contains("`deskTools()`")
    check sb.profileText() == original

    # Negative control: `set` reads `config:`, where `gnmIdentity(...)` may
    # assign the key, so it still refuses this profile, naming what it saw.
    let setRun = home("set", "git.userName", "x", "--no-apply")
    check setRun.exitCode == 1
    check setRun.stderr.contains("unstructured profile")
    check sb.profileText() == original

    # Negative control: no helper call in scope -> an absent package is
    # still not an error.
    let flat = newProfileSandbox("gnm-ra-flat",
      "import repro_profile\n\nprofile \"gnmFlat\":\n  activity default:\n" &
      "    ripgrep\n")
    defer: flat.dispose()
    let flatBefore = flat.profileText()
    let absent = flat.runRepro(["home", "remove", "gnm-not-here",
      "--no-apply"])
    show("remove absent (no helpers)", absent)
    check absent.exitCode == 0
    check flat.profileText() == flatBefore

  test "e2e_enable_disable_keep_the_host_list_layout":
    let hosts = newProfileSandbox("gnm-ra-hosts", HostLayouts)
    defer: hosts.dispose()
    let original = hosts.profileText()
    proc edit(args: varargs[string]): string =
      writeFile(extendedPath(hosts.profilePath), original)
      let r = hosts.runRepro(@["home"] & @args & @["--no-apply"])
      show(args.join(" "), r)
      check r.exitCode == 0
      hosts.profileText()
    # Negative control: the `for` loop is still refused by `add`...
    let addRun = hosts.runRepro(["home", "add", "fd", "--no-apply"])
    show("add (for loop)", addRun)
    check addRun.exitCode == 1
    check addRun.stderr.contains("Nim `for` keyword")
    check hosts.profileText() == original
    # ... while enable / disable edit `hosts:` without reading it.
    const LongTail = "                  alpha_activity_name, " &
      "beta_activity_name, gamma_activity_nm]\n"
    check edit("enable", "delta", "--host", "long-list") ==
      original.replace(LongTail, LongTail[0 ..< LongTail.len - 2] & ",\n" &
        "                  delta]\n")
    check edit("disable", "gamma_activity_nm", "--host", "long-list") ==
      original.replace(LongTail,
        "                  alpha_activity_name, beta_activity_name]\n")
    check edit("disable", "alpha_activity_name", "--host", "long-list") ==
      original.replace(LongTail,
        "                  beta_activity_name, gamma_activity_nm]\n")
    check edit("enable", "extra", "--host", "single") ==
      original.replace("[default, alpha_activity_name]   #",
        "[default, alpha_activity_name, extra]   #")
    check edit("disable", "alpha_activity_name", "--host", "only") ==
      original.replace("\"only\": [alpha_activity_name]", "\"only\": []")
    check edit("enable", "alpha_activity_name", "--host", "new-host") ==
      original & "    \"new-host\": [alpha_activity_name]\n"
    # Already enabled / not present: unchanged.
    check edit("enable", "alpha_activity_name", "--host", "single") == original
    check edit("disable", "zeta", "--host", "single") == original
    # A host list that never closes is refused, file unchanged.
    let broken = original.replace("\"only\": [alpha_activity_name]",
      "\"only\": [alpha_activity_name,")
    writeFile(extendedPath(hosts.profilePath), broken)
    let refused = hosts.runRepro(["home", "enable", "beta_activity_name",
      "--host", "single", "--no-apply"])
    show("enable (unclosed list)", refused)
    check refused.exitCode == 1
    check refused.stderr.contains("[alpha_activity_name,")
    check hosts.profileText() == broken

    # The composed profile: multi-line flat and block-form entries.
    let sb = composedSandbox("gnm-ra-enable")
    defer: sb.dispose()
    let env = sb.fixturePackageEnv(Packages)
    let composed = sb.profileText()
    let en = sb.runRepro(["home", "enable", "extra", "--host", "gnm-block",
      "--no-apply"], host = "gnm-wide", extraEnv = env)
    show("enable extra --host gnm-block", en)
    check en.exitCode == 0
    let dis = sb.runRepro(["home", "disable", "extra", "--host", "gnm-wide",
      "--no-apply"], host = "gnm-wide", extraEnv = env)
    show("disable extra --host gnm-wide", dis)
    check dis.exitCode == 0
    let expected = composed.replace(
      "    \"gnm-wide\":       [default, desktop,\n" &
      "                       extra]\n",
      "    \"gnm-wide\":       [default, desktop]\n").replace(
      "                   desktop]\n", "                   desktop, extra]\n")
    check expected != composed
    check sb.profileText() == expected
    # The edits compile and select what they say.
    let exported = sb.runRepro(["home", "export", "--format", "json"],
      host = "gnm-block", extraEnv = env)
    show("export (gnm-block)", exported)
    require exported.exitCode == 0
    check parseJson(exported.stdout)["selection"]["activities"] ==
      %*["default", "desktop", "extra"]
    let wide = sb.runRepro(["home", "list"], host = "gnm-wide",
      extraEnv = env)
    require wide.exitCode == 0
    check listedAs(wide.stdout, "enabled", "gnm-helper-desk", "desktop")
