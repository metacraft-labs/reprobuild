## The stow plan depends only on the profile's `stow/` tree, never on the
## order the filesystem enumerates it, and a `$HOME` path two stow packages
## map a file to is refused before anything is written (reprobuild-pm issues
## 2026-10-13-stow-discovery-order-follows-directory-enumeration and
## 2026-10-18-two-stow-packages-on-one-home-path-are-not-refused;
## Home-Profile-Intent-Layer.md §Stow-Style Dotfile Support, Discovery).
##
## `e2e_stow_plan_does_not_depend_on_enumeration_order` -- one stow tree
## (five packages, nested and dot-named files, a loose file) is written into
## two sandboxes, once in descending and once in ascending name order. Through
## the real `build/bin/repro`, `repro home apply --plan` of each must print
## the same `[stow]` section, line for line, and that section must be ordered
## by package, then by path within the package (bytewise). The fixture is
## chosen so enumeration order is wrong before the fix wherever this suite
## runs: ZFS and ext4 enumerate by name hash, tmpfs newest first (the two
## creation orders), NTFS case-insensitively (the package `Nvim` sorts first
## bytewise and fourth case-insensitively). Measured before the fix (ZFS,
## home-pc, reprobuild `agents` @ c7e7c56ab): both sandboxes printed the
## packages out of order, and differently. A real `repro home apply` of one
## sandbox then materializes every planned file.
##
## `e2e_two_stow_packages_on_one_path_are_refused` -- two packages with a file
## at one `$HOME` path are refused by `repro home facts`, `apply --plan` and
## `apply` alike, naming the path and both packages, whether the files differ
## or are identical, and `apply` writes nothing to HOME and records no
## generation. Before the fix `facts` and `--plan` exited 0 and `apply`
## linked the first-enumerated package's files, then failed on the second.
## Negative control: the same two packages claimed by two activities, planned
## for a host that selects only one of them, plan cleanly (and the desktop
## host applies) -- only the packages a host gets are compared -- and the host
## selecting both is refused.
##
## No mocks: the real `build/bin/repro`, the real profile compile edge, the
## real planner and the real stow materializer, all in the harness's isolated
## sandbox (its own HOME, state and store). Platforms: every host.

import std/[algorithm, os, sequtils, strutils, unittest]
from repro_core/paths import extendedPath

import repro_home_generations

import ../m83/profile_compile_edge_harness

const PlainProfile = """
import repro_profile

profile "stowOrder":
  activity default:
    discard
"""

const
  Packages = ["zsh", "alacritty", "git", "Nvim", "bin"]
    ## Not in sorted order, mixed case (bytewise: `Nvim` before the
    ## lower-case names).
  PackageFiles = [".zshrc", "z.conf", "a.conf", ".config/sub/b", ".config/a",
    "deep/er/x"]
    ## Each package's files live under a directory named after it, so no two
    ## packages share a `$HOME` path (that is the second test's case).

proc show(label: string; r: ReproRun) =
  checkpoint(label & " -> exit " & $r.exitCode & "\n--- stdout\n" &
    r.stdout & "\n--- stderr\n" & r.stderr)

proc fileRel(package, file: string): string =
  ## The within-package path of `file` in `package`: `<file>` nested under a
  ## per-package directory, so every package keeps its own `$HOME` paths.
  "." & package.toLowerAscii & "-home/" & file

proc writeTree(sb: ProfileSandbox; descending: bool) =
  var packages = @Packages
  var files = @PackageFiles
  packages.sort(system.cmp[string], if descending: Descending else: Ascending)
  files.sort(system.cmp[string], if descending: Descending else: Ascending)
  for p in packages:
    for f in files:
      sb.writeProfileFile("stow/" & p & "/" & fileRel(p, f), p & ":" & f & "\n")
  sb.writeProfileFile("stow/loose.txt", "not in a package\n")

proc expectedOrder(): seq[tuple[package, rel: string]] =
  ## Package name, then within-package path, both bytewise.
  var packages = @Packages
  packages.sort(system.cmp[string])
  for p in packages:
    var rels = PackageFiles.mapIt(fileRel(p, it))
    rels.sort(system.cmp[string])
    for r in rels:
      result.add((package: p, rel: r))

proc stowSection(output, root: string): seq[string] =
  ## The `[stow]` section of `repro home apply --plan`, with the sandbox root
  ## replaced by `<root>` so two sandboxes compare.
  var inside = false
  for line in output.splitLines():
    if line.strip() == "[stow]":
      inside = true
      continue
    if inside:
      if not line.startsWith("    "):
        break
      result.add line.strip().replace(root, "<root>").replace('\\', '/')

suite "stow discovery is deterministic":

  test "e2e_stow_plan_does_not_depend_on_enumeration_order":
    let down = newProfileSandbox("stow-order-down", PlainProfile)
    defer: down.dispose()
    let up = newProfileSandbox("stow-order-up", PlainProfile)
    defer: up.dispose()
    down.writeTree(descending = true)
    up.writeTree(descending = false)

    let planDown = down.runRepro(["home", "apply", "--plan"])
    show("plan (descending tree)", planDown)
    require planDown.exitCode == 0
    let planUp = up.runRepro(["home", "apply", "--plan"])
    show("plan (ascending tree)", planUp)
    require planUp.exitCode == 0

    let sectionDown = stowSection(planDown.stdout, down.root)
    let sectionUp = stowSection(planUp.stdout, up.root)
    # Vacuity: every file of every package is planned, and the loose file is
    # reported (one `skip` line), not planned.
    let expected = expectedOrder()
    proc planned(section: seq[string]): seq[string] =
      section.filterIt(not it.startsWith("skip"))
    check sectionDown.len == expected.len + 1
    check sectionDown.filterIt(it.startsWith("skip  stow/loose.txt")).len == 1
    # The two copies plan identically, line for line...
    check sectionDown == sectionUp
    # ...in package order, then path order. The verb (`link`, or a copy on
    # Windows) is not compared; the target and the source are.
    let linesDown = planned(sectionDown)
    check linesDown.len == expected.len
    for i in 0 ..< min(linesDown.len, expected.len):
      let (package, rel) = expected[i]
      checkpoint("line " & $i & ": want " & package & "/" & rel & "\n   got " &
        linesDown[i])
      check ("<root>/home/" & rel & " ") in linesDown[i]
      check ("<root>/profile/stow/" & package & "/" & rel & ")") in
        linesDown[i]

    # A real apply of the descending copy materializes every planned file.
    let applied = down.runRepro(["home", "apply"])
    show("apply (descending tree)", applied)
    require applied.exitCode == 0
    for (package, rel) in expected:
      let path = down.homeDir / rel
      checkpoint("materialized: " & path)
      when not defined(windows):
        check symlinkExists(extendedPath(path))
      check readFile(extendedPath(path)) ==
        package & ":" & rel.split('/', 1)[1] & "\n"

  test "e2e_two_stow_packages_on_one_path_are_refused":
    for (label, betaContent) in [("differing", "beta\n"),
                                 ("identical", "alpha\n")]:
      checkpoint("case: " & label)
      let sb = newProfileSandbox("stow-clash-" & label, PlainProfile)
      defer: sb.dispose()
      sb.writeProfileFile("stow/beta/.clash.conf", betaContent)
      sb.writeProfileFile("stow/alpha/.clash.conf", "alpha\n")
      sb.writeProfileFile("stow/alpha/.only-alpha", "a\n")
      sb.writeProfileFile("stow/beta/.only-beta", "b\n")
      const Needle = "two stow packages map a file to the same $HOME path, " &
        "and a path has one writer; keep the file in one package only: " &
        "`~/.clash.conf` (packages alpha, beta)"
      let homeBefore = treeFingerprint(sb.homeDir)

      let facts = sb.runRepro(["home", "facts"])
      show(label & ": facts", facts)
      check facts.exitCode != 0
      check Needle in facts.stderr

      let plan = sb.runRepro(["home", "apply", "--plan"])
      show(label & ": apply --plan", plan)
      check plan.exitCode != 0
      check Needle in (plan.stdout & plan.stderr)

      let applied = sb.runRepro(["home", "apply"])
      show(label & ": apply", applied)
      check applied.exitCode != 0
      check Needle in (applied.stdout & applied.stderr)
      # Refused before anything was written: neither package's own file is
      # linked, and there is no generation.
      check treeFingerprint(sb.homeDir) == homeBefore
      check not fileExists(extendedPath(sb.homeDir / ".only-alpha"))
      check readCurrentGenerationId(sb.stateDir).len == 0

  test "e2e_stow_packages_no_host_gets_together_are_not_a_pair":
    const Scoped = """
import repro_profile

profile "stowClashScoped":
  activity default:
    discard

  activity desktop_core:
    stow:
      "kitty-desktop"

  activity server_core:
    stow:
      "kitty-server"

  hosts:
    "clash-desktop": [desktop_core]
    "clash-server": [server_core]
    "clash-both": [desktop_core, server_core]
"""
    let sb = newProfileSandbox("stow-clash-scoped", Scoped)
    defer: sb.dispose()
    sb.writeProfileFile("stow/kitty-desktop/.config/kitty/kitty.conf",
      "font_size 12\n")
    sb.writeProfileFile("stow/kitty-server/.config/kitty/kitty.conf",
      "font_size 9\n")
    # Each single-activity host plans its own package's file at the path.
    for (host, package) in [("clash-desktop", "kitty-desktop"),
                            ("clash-server", "kitty-server")]:
      let plan = sb.runRepro(["home", "apply", "--plan"], host = host)
      show("apply --plan " & host, plan)
      check plan.exitCode == 0
      let section = stowSection(plan.stdout, sb.root)
      check section.len == 1
      check section.join("\n").contains("<root>/profile/stow/" & package &
        "/.config/kitty/kitty.conf)")

    # And applies it.
    let desktop = sb.runRepro(["home", "apply"], host = "clash-desktop")
    show("apply clash-desktop", desktop)
    require desktop.exitCode == 0
    check readFile(extendedPath(sb.homeDir / ".config/kitty/kitty.conf")) ==
      "font_size 12\n"

    # The host that selects both activities gets both packages: refused.
    let both = sb.runRepro(["home", "apply", "--plan"], host = "clash-both")
    show("apply --plan clash-both", both)
    check both.exitCode != 0
    check ("`~/.config/kitty/kitty.conf` (packages kitty-desktop, " &
      "kitty-server)") in (both.stdout & both.stderr)
