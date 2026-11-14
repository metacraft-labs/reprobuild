## NF-2 — **a `flake.lock` re-pin moves the `.github/sibling-repos` commit pin
## of the same repository with it.**
##
## reprobuild-pm issue
## 2026-11-14-commit-time-repin-moves-runquota-in-flake-lock-without-sibling-repos:
## `.github/sibling-repos` may pin a sibling by commit (`name=<sha>`), and
## `scripts/check_sibling_lock_pins.py` requires that commit to equal the one
## `flake.lock` locks. The commit-time re-pin moved `runquota-src` and left
## `runquota=` behind, so the commit carried a bill of materials the check
## refuses.
##
## Asserted for the three writers that share the rule: the managed `pre-commit`
## hook (the entry is staged into the same commit), the operator verb
## `repro flake refresh-lock` and `repro lock update`. An entry for a repository that did NOT move,
## and the comments around the entry, are carried through byte for byte.
##
## Mutation: drop the `syncSiblingRepoPins` calls ⇒ RED at the entry checks.
##
## Test-double policy: NO mocks, doubles or fakes. See the header of
## `nf2_flake_lock_fixture.nim`.

import std/[os, strutils, unittest]

import hl11_two_lock_fixture
import repro_test_support/reasoned_skip

proc siblingReposPath(fx: Nf2Fixture): string =
  fx.app / ".github" / "sibling-repos"

proc seedSiblingRepos(fx: Nf2Fixture) =
  ## The lock's repository coordinate is the url's last segment, which for the
  ## fixture's origins is `origin-<name>`.
  createDir(fx.app / ".github")
  writeFile(siblingReposPath(fx),
    "# a comment that must survive\n" &
    "origin-alpha=" & fx.seedSha[0] & "  # trailing note\n" &
    "origin-beta=" & fx.seedSha[1] & "\n" &
    "unrelated\n")
  discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
  discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) &
    " commit -q -m " & q("list siblings"))

suite "NF-2: a re-pin moves the sibling-repos pin with flake.lock":

  test "t_a_repin_moves_the_sibling_repos_pin_with_flake_lock (commit hook)":
    if not nf2Prerequisites("t_a_repin_moves_the_sibling_repos_pin_with_flake_lock"):
      skip("nix or the fixture prerequisites are not available")
    else:
      let fx = setupNf2Fixture("sibling-repos-hook")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      seedSiblingRepos(fx)

      let newAlpha = moveAndPublishSibling(fx, "alpha", "revision 2")
      writeFile(fx.app / "work.txt", "unrelated work\n")
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
      let commit = tryCommitInApp(fx, "unrelated work")
      checkpoint("commit output:\n" & commit.output)
      checkpoint("pre-commit log:\n" & preCommitLog(fx))
      check commit.code == 0

      # The lock moved (the arrangement), and the entry moved with it...
      check nodeText(lockInCommit(fx), "alpha-src").contains(newAlpha)
      let inCommit = gitIn(fx, fx.app, "show HEAD:.github/sibling-repos")
      check inCommit == "# a comment that must survive\n" &
        "origin-alpha=" & newAlpha & "  # trailing note\n" &
        "origin-beta=" & fx.seedSha[1] & "\n" &
        "unrelated\n"
      # ...in the SAME commit, leaving nothing behind in the working tree.
      check readFile(siblingReposPath(fx)) == inCommit
      check gitIn(fx, fx.app, "status --porcelain").strip().len == 0

  test "t_a_repin_moves_the_sibling_repos_pin_with_flake_lock (verb)":
    if not nf2Prerequisites("t_a_repin_moves_the_sibling_repos_pin_with_flake_lock"):
      skip("nix or the fixture prerequisites are not available")
    else:
      let fx = setupNf2Fixture("sibling-repos-verb")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      seedSiblingRepos(fx)

      let newBeta = moveAndPublishSibling(fx, "beta", "revision 2")
      let res = run(q(fx.repro) & " flake refresh-lock --all --tool-provisioning=path",
        cwd = fx.app)
      checkpoint("refresh-lock output:\n" & res.output)
      check res.code == 0
      check nodeText(readFile(lockPath(fx)), "beta-src").contains(newBeta)
      check readFile(siblingReposPath(fx)) ==
        "# a comment that must survive\n" &
        "origin-alpha=" & fx.seedSha[0] & "  # trailing note\n" &
        "origin-beta=" & newBeta & "\n" &
        "unrelated\n"

  test "t_a_repin_moves_the_sibling_repos_pin_with_flake_lock (awkward spellings)":
    # CRLF line ends, an acknowledged `!=` override, an upper-case commit id,
    # a spaced `=`, an entry for a repository that did not move, and no
    # trailing newline: the entry moves, every other byte is carried through.
    if not nf2Prerequisites("t_a_repin_moves_the_sibling_repos_pin_with_flake_lock"):
      skip("nix or the fixture prerequisites are not available")
    else:
      let fx = setupNf2Fixture("sibling-repos-spellings")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      createDir(fx.app / ".github")
      writeFile(siblingReposPath(fx),
        "# note\r\n" &
        "origin-alpha!=" & fx.seedSha[0] & "\r\n" &
        "origin-beta = " & fx.seedSha[1].toUpperAscii() & " # tail\r\n" &
        "origin-gamma=" & fx.seedSha[2])
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) &
        " commit -q -m " & q("list siblings"))
      let newAlpha = moveAndPublishSibling(fx, "alpha", "revision 2")
      let newBeta = moveAndPublishSibling(fx, "beta", "revision 2")
      let res = run(q(fx.repro) & " flake refresh-lock --all --tool-provisioning=path",
        cwd = fx.app)
      checkpoint("refresh-lock output:\n" & res.output)
      check res.code == 0
      check readFile(siblingReposPath(fx)) ==
        "# note\r\n" &
        "origin-alpha!=" & newAlpha & "\r\n" &
        "origin-beta = " & newBeta & " # tail\r\n" &
        "origin-gamma=" & fx.seedSha[2]

  test "t_a_repin_moves_the_sibling_repos_pin_with_flake_lock (lock update)":
    # `repro lock update <input> --to <rev>` moves only the entry of the
    # repository it moves, in the same all-or-nothing step as the lock.
    if not nf2Prerequisites("t_a_repin_moves_the_sibling_repos_pin_with_flake_lock"):
      skip("nix or the fixture prerequisites are not available")
    else:
      let fx = setupNf2Fixture("sibling-repos-lock-update", siblingRecipes = true)
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      publishAll(fx)
      seedSiblingRepos(fx)
      let newBeta = moveAndPublishSibling(fx, "beta", "revision 2")
      let res = run(q(fx.repro) & " lock update beta-src --to " & newBeta &
        " --repo-root=" & q(fx.app), cwd = fx.ws)
      checkpoint("lock update output:\n" & res.output)
      check res.code == 0
      check nodeText(readFile(lockPath(fx)), "beta-src").contains(newBeta)
      check readFile(siblingReposPath(fx)) ==
        "# a comment that must survive\n" &
        "origin-alpha=" & fx.seedSha[0] & "  # trailing note\n" &
        "origin-beta=" & newBeta & "\n" &
        "unrelated\n"
