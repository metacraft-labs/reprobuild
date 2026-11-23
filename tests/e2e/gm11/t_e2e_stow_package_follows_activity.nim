## GM11: a `stow/` package an activity claims is materialized only on hosts
## that select the activity (reprobuild-pm spec Home-Profile-Intent-Layer.md
## §Stow-Style Dotfile Support, "Packages that belong to an activity";
## Gradual-Nix-To-Reprobuild-Migration.md §Hosts).
##
## Primary assertion -- `e2e_stow_package_follows_activity`: a fixture
## profile has three stow packages -- `common` (claimed by nobody), `kitty`
## (claimed by `desktop_core`) and `rdp` (claimed by `desktop_core`, and by
## `default` under `when windows():`) -- and two hosts, `gm11-desktop`
## (selects `desktop_core`) and `gm11-server` (`default` only). Through the
## real `build/bin/repro`:
##
## * `repro home facts --host gm11-desktop` lists the files of all three
##   packages; `--host gm11-server` lists `common`'s only when the plan
##   targets Linux or macOS, and `common`'s and `rdp`'s when it targets
##   Windows (the guarded claim below);
## * the guarded claim holds where its guard does: the server planned for a
##   Windows target (`--target x86_64-windows`) gets `rdp` again, and not
##   `kitty`;
## * `repro home export` carries the claims as `intent.stowScopes`, in
##   declaration order, each with its activity and guard;
## * a real `repro home apply --host gm11-desktop` links all three packages
##   into the sandbox HOME; the next `repro home apply --host gm11-server`
##   removes the `kitty` link (and the `rdp` one off Windows) and keeps
##   `common`'s -- the files follow the selection.
##
## Which server files are expected. The native legs (`facts` without
## `--target`, and the real apply) plan for the platform the test runs on,
## so the server's expected set is computed from the `system` the facts
## report for that plan (`expectedServerFiles`), not hard-coded: on a Windows
## host the guarded `rdp` claim holds natively too (reprobuild-pm issue
## 2026-10-25-gm11-stow-follows-activity-gate-assumes-a-non-windows-host).
## The reported `system` is itself checked against the platform the test was
## compiled for, so a planner that targeted the wrong platform cannot choose
## its own expectation; off Windows the set is still asserted to be exactly
## `common`'s.
##
## Negative control (same profile): the unclaimed package `common` reaches
## both hosts.
##
## Falsifying mutation, performed by the test itself on every run: the same
## profile and stow tree with the `stow:` blocks removed. The server then
## gets `kitty` and `rdp` too -- so it is the claim, not anything else about
## the fixture, that kept them off it. (Code mutations performed when this
## gate was written are recorded in the milestone file.)
##
## Vacuity: both hosts' file sets are non-empty and differ; every file the
## test looks for is checked present or absent per host.
##
## `e2e_stow_claims_refused_when_malformed` -- refusals, each before anything
## is written to HOME: a claim of a package the stow tree does not have (at
## plan time, naming the package and the packages that exist); a `stow:`
## block under a `when` of the activity body, a path instead of a package
## name, a package claimed twice by one activity and an entry that is not a
## string literal (at compile time, naming the rule).
##
## No mocks: the real `build/bin/repro`, the real profile compile edge, the
## real planner and the real stow materializer, all in the harness's isolated
## sandbox (its own HOME, state and store). Platforms: every host -- the
## `--target x86_64-windows` leg covers the guarded claim from any host; on a
## Windows host the native legs cover it as well.

import std/[algorithm, json, os, sequtils, strutils, unittest]
from repro_core/paths import extendedPath

import ../m83/profile_compile_edge_harness

const ScopedProfile = """
import repro_profile

profile "gm11Stow":
  activity default:
    stow:
      when windows():
        "rdp"

  activity desktop_core:
    stow:
      "kitty"
      "rdp"

  hosts:
    "gm11-desktop": [desktop_core]
    "gm11-server": [default]
"""

const UnclaimedProfile = """
import repro_profile

profile "gm11Stow":
  activity default:
    discard

  activity desktop_core:
    discard

  hosts:
    "gm11-desktop": [desktop_core]
    "gm11-server": [default]
"""
  ## `ScopedProfile` without its `stow:` blocks: the falsifying mutation.

const
  StowFiles = [
    ("common", ".gm11-common", "common = 1\n"),
    ("kitty", ".config/kitty/kitty.conf", "font_size 12\n"),
    ("rdp", "Remote-Desktops/server.rdp", "full address:s:server\n")]
  CommonFiles = ["~/.gm11-common"]
  DesktopFiles = ["~/.config/kitty/kitty.conf", "~/.gm11-common",
    "~/Remote-Desktops/server.rdp"]
  ServerFiles = ["~/.gm11-common"]
  WindowsServerFiles = ["~/.gm11-common", "~/Remote-Desktops/server.rdp"]

proc show(label: string; r: ReproRun) =
  checkpoint(label & " -> exit " & $r.exitCode & "\n--- stdout\n" &
    r.stdout & "\n--- stderr\n" & r.stderr)

proc writeStowTree(sb: ProfileSandbox) =
  for (package, rel, content) in StowFiles:
    sb.writeProfileFile("stow/" & package & "/" & rel, content)

type StowFacts = object
  system: string
    ## The platform the plan targeted, as `repro home facts` reports it
    ## (`x86_64-linux`, `aarch64-darwin`, `x86_64-windows`, ...).
  files: seq[string]
    ## The `~/...` files of the fixture's stow packages it would write.

proc targetsWindows(system: string): bool =
  system.endsWith("-windows")

proc expectedServerFiles(system: string): seq[string] =
  ## What `gm11-server` (`default` only) gets from a plan for `system`:
  ## `common`, plus `rdp` where `default`'s `when windows():` claim holds.
  if system.targetsWindows: @WindowsServerFiles else: @ServerFiles

proc stowFactsFor(sb: ProfileSandbox; host: string; target = ""): StowFacts =
  ## The platform `repro home facts` planned `host` for, and the stow files
  ## it says an apply would write.
  var args = @["home", "facts", "--host", host]
  if target.len > 0:
    args.add ["--target", target]
  let run = sb.runRepro(args, host = "")
  show("facts --host " & host & " " & target, run)
  require run.exitCode == 0
  let facts = parseJson(run.stdout)
  result.system = facts["system"].getStr
  let known = StowFiles.mapIt("~/" & it[1])
  for f in facts["categories"]["files"]:
    let id = f["id"].getStr
    if id in known:
      result.files.add id
  result.files.sort()

proc stowFilesFor(sb: ProfileSandbox; host: string; target = ""): seq[string] =
  sb.stowFactsFor(host, target).files

suite "GM11: activity-scoped stow packages follow host selection":

  test "e2e_stow_package_follows_activity":
    let sb = newProfileSandbox("gm11-stow", ScopedProfile)
    defer: sb.dispose()
    sb.writeStowTree()

    # --- the planner ------------------------------------------------------
    let desktop = sb.stowFilesFor("gm11-desktop")
    let serverFacts = sb.stowFactsFor("gm11-server")
    let server = serverFacts.files
    checkpoint("desktop gets " & $desktop & ", server (" &
      serverFacts.system & ") gets " & $server)
    # The native plan targets the platform this test runs on, and the
    # expected server set is derived from it, so check that it really does.
    require serverFacts.system.len > 0
    check serverFacts.system.targetsWindows == defined(windows)
    let expectedServer = expectedServerFiles(serverFacts.system)
    check desktop == @DesktopFiles
    check server == expectedServer
    when not defined(windows):
      # Off Windows the native server set is exactly `common`'s.
      check server == @ServerFiles
    # Negative control: the unclaimed package reaches both hosts.
    for f in CommonFiles:
      check f in desktop
      check f in server
    # Vacuity: different, non-empty sets.
    check desktop.len > 0 and server.len > 0
    check desktop != server

    # --- a guarded claim holds where its guard does ------------------------
    # `default` claims `rdp` under `when windows():`; the server planned for
    # a Windows target gets it back (and still not `kitty`).
    let windowsServer = sb.stowFactsFor("gm11-server", "x86_64-windows")
    check windowsServer.system == "x86_64-windows"
    check windowsServer.files == @WindowsServerFiles
    check windowsServer.files == expectedServerFiles(windowsServer.system)

    # --- the export carries the claims, in declaration order ---------------
    let exported = sb.runRepro(["home", "export", "--host", "gm11-desktop",
      "--format", "json"], host = "")
    show("export --host gm11-desktop", exported)
    require exported.exitCode == 0
    check parseJson(exported.stdout)["intent"]["stowScopes"] == %*[
      {"package": "rdp", "activity": "default", "guard": "windows"},
      {"package": "kitty", "activity": "desktop_core", "guard": nil},
      {"package": "rdp", "activity": "desktop_core", "guard": nil}]

    # --- a real apply: the links follow the selection ----------------------
    let desktopApply = sb.runRepro(["home", "apply", "--host",
      "gm11-desktop"], host = "")
    show("apply --host gm11-desktop", desktopApply)
    require desktopApply.exitCode == 0
    for (package, rel, content) in StowFiles:
      checkpoint("after desktop apply: " & rel)
      let path = sb.homeDir / rel
      check fileExists(extendedPath(path))
      if fileExists(extendedPath(path)):
        check readFile(extendedPath(path)) == content
    let serverApply = sb.runRepro(["home", "apply", "--host", "gm11-server"],
      host = "")
    show("apply --host gm11-server", serverApply)
    require serverApply.exitCode == 0
    for (package, rel, content) in StowFiles:
      checkpoint("after server apply: " & rel)
      check fileExists(extendedPath(sb.homeDir / rel)) ==
        (("~/" & rel) in expectedServer)

    # --- the falsifying mutation: no claims ---------------------------------
    let unclaimed = newProfileSandbox("gm11-unclaimed", UnclaimedProfile)
    defer: unclaimed.dispose()
    unclaimed.writeStowTree()
    let unclaimedServer = unclaimed.stowFilesFor("gm11-server")
    checkpoint("without claims the server gets " & $unclaimedServer)
    check unclaimedServer == @DesktopFiles

  test "e2e_stow_claims_refused_when_malformed":
    const MissingPackage = """
import repro_profile

profile "gm11Missing":
  activity desktop_core:
    stow:
      "kity"

  hosts:
    "gm11-desktop": [desktop_core]
"""
    const UnderWhen = """
import repro_profile

profile "gm11UnderWhen":
  activity desktop_core:
    when linux():
      stow:
        "kitty"

  hosts:
    "gm11-desktop": [desktop_core]
"""
    const PathName = """
import repro_profile

profile "gm11Path":
  activity desktop_core:
    stow:
      "kitty/.config"

  hosts:
    "gm11-desktop": [desktop_core]
"""
    const Twice = """
import repro_profile

profile "gm11Twice":
  activity desktop_core:
    stow:
      "kitty"
    stow:
      "kitty"

  hosts:
    "gm11-desktop": [desktop_core]
"""
    const NotLiteral = """
import repro_profile

const pkg = "kitty"

profile "gm11NotLiteral":
  activity desktop_core:
    stow:
      pkg

  hosts:
    "gm11-desktop": [desktop_core]
"""
    for (label, text, needle) in [
        ("missing-package", MissingPackage,
         "claims stow package `kity`, but the profile's stow/ tree has no " &
         "such package directory (packages: common, kitty, rdp)"),
        ("under-when", UnderWhen,
         "`stow:` block must sit directly in the activity body"),
        ("path-name", PathName, "is a path; name one immediate subdirectory"),
        ("twice", Twice, "claims stow package `kitty` twice"),
        ("not-literal", NotLiteral,
         "a `stow:` block lists `stow/` package names as string literals")]:
      let sb = newProfileSandbox("gm11-" & label, text)
      defer: sb.dispose()
      sb.writeStowTree()
      let run = sb.runRepro(["home", "apply", "--host", "gm11-desktop"],
        host = "")
      show(label, run)
      check run.exitCode != 0
      check (run.stdout & run.stderr).contains(needle)
      for (package, rel, content) in StowFiles:
        check not fileExists(extendedPath(sb.homeDir / rel))
