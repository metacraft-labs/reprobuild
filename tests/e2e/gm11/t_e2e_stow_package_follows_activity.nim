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
##   packages; `--host gm11-server` lists `common`'s only;
## * the guarded claim holds where its guard does: the server planned for a
##   Windows target (`--target x86_64-windows`) gets `rdp` again, and not
##   `kitty`;
## * `repro home export` carries the claims as `intent.stowScopes`, in
##   declaration order, each with its activity and guard;
## * a real `repro home apply --host gm11-desktop` links all three packages
##   into the sandbox HOME; the next `repro home apply --host gm11-server`
##   removes the `kitty` and `rdp` links and keeps `common`'s -- the files
##   follow the selection.
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
## Windows leg is a planning target, not the platform the test runs on.

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

proc stowFilesFor(sb: ProfileSandbox; host: string; target = ""): seq[string] =
  ## The `~/...` files of the fixture's stow packages that `repro home facts`
  ## says an apply for `host` would write.
  var args = @["home", "facts", "--host", host]
  if target.len > 0:
    args.add ["--target", target]
  let run = sb.runRepro(args, host = "")
  show("facts --host " & host & " " & target, run)
  require run.exitCode == 0
  let known = StowFiles.mapIt("~/" & it[1])
  for f in parseJson(run.stdout)["categories"]["files"]:
    let id = f["id"].getStr
    if id in known:
      result.add id
  result.sort()

suite "GM11: activity-scoped stow packages follow host selection":

  test "e2e_stow_package_follows_activity":
    let sb = newProfileSandbox("gm11-stow", ScopedProfile)
    defer: sb.dispose()
    sb.writeStowTree()

    # --- the planner ------------------------------------------------------
    let desktop = sb.stowFilesFor("gm11-desktop")
    let server = sb.stowFilesFor("gm11-server")
    checkpoint("desktop gets " & $desktop & ", server gets " & $server)
    check desktop == @DesktopFiles
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
    let windowsServer = sb.stowFilesFor("gm11-server", "x86_64-windows")
    check windowsServer == @WindowsServerFiles

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
        (("~/" & rel) in ServerFiles)

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
