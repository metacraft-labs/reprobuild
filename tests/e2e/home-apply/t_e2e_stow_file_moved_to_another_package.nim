## A stow file that moves to another package replaces the link the current
## generation recorded at its path, instead of being refused as drift
## (reprobuild-pm issue
## 2026-10-19-home-apply-refuses-a-stow-file-moved-to-another-package;
## Home-Profile-Resource-Lifecycle.md §Drift Handling: drift is a difference
## from what was RECORDED).
##
## Through the real `build/bin/repro`:
##
## * `e2e_moved_stow_file_is_relinked` -- `stow/a/.mv` is applied (a link),
##   then moved to `stow/b/.mv` with new content. `apply --plan` reports no drift and a
##   replacement of the recorded link; `apply`, with no flag, links `~/.mv`
##   to the new source. The same in copy mode (`REPRO_TEST_STOW_DISABLE_
##   SYMLINK=1`, the materializer's own seam for hosts without symlinks):
##   the recorded copy, unchanged, is replaced by the new file.
## * `e2e_activity_hands_a_path_to_another_package` -- one HOME applied for a
##   host selecting `kitty-desktop`, then for one selecting `kitty-server`,
##   both mapping `~/.config/kitty/kitty.conf`: the path follows the
##   selection.
## * Negative controls, in each: when the user has replaced the recorded
##   link with their own file (or edited the recorded copy) before the move,
##   the apply is still refused as drift and the user's file is kept;
##   `--reconcile-drift` then replaces it.
##
## Before the fix every relink case below failed with "refused to clobber
## pre-existing target" (measured on home-pc at reprobuild `agents` @
## c7e7c56ab plus this cluster's other fixes).
##
## No mocks: the real `build/bin/repro`, the real profile compile edge, the
## real planner and the real stow materializer, all in the harness's isolated
## sandbox. Platforms: every host; the link-specific checks (`symlinkExists`)
## are POSIX-only because Windows stow materializes by copy by default.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_home_generations

import ../m83/profile_compile_edge_harness

const
  Original = "original\n"
  Moved = "moved, v2\n"

const PlainProfile = """
import repro_profile

profile "stowMove":
  activity default:
    discard
"""

proc show(label: string; r: ReproRun) =
  checkpoint(label & " -> exit " & $r.exitCode & "\n--- stdout\n" &
    r.stdout & "\n--- stderr\n" & r.stderr)

proc both(r: ReproRun): string = r.stdout & r.stderr

proc moveStowFile(sb: ProfileSandbox; fromPkg, toPkg, rel: string) =
  ## Move `rel` from package `fromPkg` to `toPkg`, changing its content (so a
  ## byte-identical copy cannot pass for the new file), and drop the emptied
  ## package.
  let src = sb.profileDir / "stow" / fromPkg / rel
  let dst = sb.profileDir / "stow" / toPkg / rel
  createDir(extendedPath(dst.parentDir))
  moveFile(extendedPath(src), extendedPath(dst))
  writeFile(extendedPath(dst), Moved)
  removeDir(extendedPath(sb.profileDir / "stow" / fromPkg))

proc relinkCase(copyMode: bool): string =
  ## Returns what `~/.mv` holds after the second apply.
  let label = if copyMode: "copy" else: "link"
  let env: seq[(string, string)] =
    if copyMode: @[("REPRO_TEST_STOW_DISABLE_SYMLINK", "1")] else: @[]
  checkpoint("mode: " & label)
  let sb = newProfileSandbox("stow-move-" & label, PlainProfile)
  defer: sb.dispose()
  sb.writeProfileFile("stow/a/.mv", Original)
  let first = sb.runRepro(["home", "apply"], extraEnv = env)
  show(label & ": apply a", first)
  require first.exitCode == 0
  let target = sb.homeDir / ".mv"
  check readFile(extendedPath(target)) == Original
  when not defined(windows):
    check symlinkExists(extendedPath(target)) == not copyMode
  let genA = readCurrentGenerationId(sb.stateDir)

  sb.moveStowFile("a", "b", ".mv")
  let plan = sb.runRepro(["home", "apply", "--plan"], extraEnv = env)
  show(label & ": plan after move", plan)
  check plan.exitCode == 0
  check "0 drift(s)" in plan.both
  check "would replace what the current generation recorded" in plan.both
  let second = sb.runRepro(["home", "apply"], extraEnv = env)
  show(label & ": apply b", second)
  check second.exitCode == 0
  check readCurrentGenerationId(sb.stateDir) != genA
  check fileExists(extendedPath(target))
  if fileExists(extendedPath(target)):
    result = readFile(extendedPath(target))
  when not defined(windows):
    if not copyMode:
      check expandSymlink(target) == sb.profileDir / "stow" / "b" / ".mv"

proc userReplacedCase(copyMode: bool): string =
  ## Returns what `~/.mv` holds after the refused apply.
  let label = if copyMode: "copy" else: "link"
  let env: seq[(string, string)] =
    if copyMode: @[("REPRO_TEST_STOW_DISABLE_SYMLINK", "1")] else: @[]
  checkpoint("negative control, mode: " & label)
  let sb = newProfileSandbox("stow-move-neg-" & label, PlainProfile)
  defer: sb.dispose()
  sb.writeProfileFile("stow/a/.mv", Original)
  let first = sb.runRepro(["home", "apply"], extraEnv = env)
  show(label & ": apply a", first)
  require first.exitCode == 0
  let target = sb.homeDir / ".mv"
  # The user puts their own file where the recorded link / copy was.
  removeFile(extendedPath(target))
  writeFile(extendedPath(target), "mine\n")
  sb.moveStowFile("a", "b", ".mv")
  let refused = sb.runRepro(["home", "apply"], extraEnv = env)
  show(label & ": apply b over the user's file", refused)
  check refused.exitCode != 0
  check "refused to clobber pre-existing target" in refused.both
  result = readFile(extendedPath(target))
  let reconciled = sb.runRepro(["home", "apply", "--reconcile-drift"],
    extraEnv = env)
  show(label & ": apply b --reconcile-drift", reconciled)
  check reconciled.exitCode == 0
  check readFile(extendedPath(target)) == Moved

suite "stow: a file moved to another package":

  test "e2e_moved_stow_file_is_relinked":
    when not defined(windows):
      check relinkCase(copyMode = false) == Moved
      check userReplacedCase(copyMode = false) == "mine\n"
    check relinkCase(copyMode = true) == Moved
    check userReplacedCase(copyMode = true) == "mine\n"

  test "e2e_activity_hands_a_path_to_another_package":
    const Scoped = """
import repro_profile

profile "stowHandOver":
  activity default:
    discard

  activity desktop_core:
    stow:
      "kitty-desktop"

  activity server_core:
    stow:
      "kitty-server"

  hosts:
    "handover-desktop": [desktop_core]
    "handover-server": [server_core]
"""
    let sb = newProfileSandbox("stow-handover", Scoped)
    defer: sb.dispose()
    sb.writeProfileFile("stow/kitty-desktop/.config/kitty/kitty.conf",
      "font_size 12\n")
    sb.writeProfileFile("stow/kitty-server/.config/kitty/kitty.conf",
      "font_size 9\n")
    let conf = sb.homeDir / ".config/kitty/kitty.conf"
    for (host, want) in [("handover-desktop", "font_size 12\n"),
                         ("handover-server", "font_size 9\n"),
                         ("handover-desktop", "font_size 12\n")]:
      let r = sb.runRepro(["home", "apply"], host = host)
      show("apply " & host, r)
      check r.exitCode == 0
      check fileExists(extendedPath(conf))
      if fileExists(extendedPath(conf)):
        check readFile(extendedPath(conf)) == want
