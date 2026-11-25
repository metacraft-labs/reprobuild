## A committed `repro.lock` records each pinned repository's `url` in one
## canonical form, whichever writer — the commit-time re-pin or
## `repro lock refresh` — writes it, and whichever spelling the writing
## clone's remote uses, so a commit that moves no pin does not rewrite the
## lock (Unified-Locking-And-Hooks.md §14.2, "The `url` a pin records";
## §13.3, "Only on change").
##
## WHY. Both writers took a sibling's `url` verbatim from its checkout's
## remote. One machine had cloned `…/test-certificates-tools.git`, another
## `…/test-certificates-tools`, so a commit that staged only `flake.lock` ran
## the managed pre-commit hook, which printed `repro-lock refreshed sibling
## coordinates` and staged a rewritten lock in which not one revision had
## moved: the url gained `.git`, and the rewrite dropped the legacy `ref`
## fields an older (pre-v0.2.20) writer had left behind. Committed locks then
## alternated between encodings with the last writer, and the bytes a
## certificate binds changed for the same workspace state.
##
## Fixture: `committed_lock_siblings_fixture.nim` — a real manifest workspace
## (app → lib-b → lib-c) of real git repositories. After the fixture is
## published, lib-b's and lib-c's `origin` remotes are pointed at forge-style
## URLs, so the lock records those; then the remotes are re-spelled the way
## another clone of the same repositories spells them (`.git` suffix, scp
## form). Nothing is fetched from those URLs: neither writer contacts a
## remote, which is the point — the url is the writing clone's description.
##
## Cases (one `git commit` through a real `.git/hooks/pre-commit` carrying
## the managed dispatch, then one `repro lock refresh`):
##   1. Re-spelled remotes and a legacy `ref` in the committed lock, no
##      revision moved: the commit does not touch `repro.lock`.
##   2. `repro lock refresh` on that clone writes the bytes the first refresh
##      wrote — the canonical url, and no `ref` (§14.2: a pin records no
##      branch; the next real write drops a legacy one) — except the self
##      entry's revision, which a refresh sets to the repo's own HEAD and which
##      this case moved by committing.
##   3. A remote that names ANOTHER repository is a coordinate change: the
##      commit-time re-pin records the new url, and a refresh keeps it.
##
## Falsifiability (observed at reprobuild 10f974bc0, before lock writers
## recorded the canonical url): case 1's commit prints `refreshed sibling
## coordinates` and carries a rewritten `repro.lock` with `…/lib-b.git`,
## `git@…:fixture/lib-c.git` and no `ref`; case 2's refresh writes those
## spellings too, and case 3's commit keeps lib-c's scp spelling.
##
## NO MOCKS. The hook file is written by hand instead of
## `repro hooks ensure --vcs` so the built binary is named by absolute path
## and a dev-shell `repro` on PATH cannot stand in for it; its body is the
## managed body's dispatch line (as in t_commit_repins_committed_lock_siblings).

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import ./committed_lock_siblings_fixture

const AllowEnv = "REPRO_ALLOW_PIN_REGRESSION"

proc refresh(fx: SiblingFixture): tuple[code: int; output: string] =
  ## `repro lock refresh <app>`, with `REPRO_ALLOW_PIN_REGRESSION` cleared so a
  ## value exported in the suite's environment cannot leak in.
  runCmd(AllowEnv & "= " & q(fx.repro) & " lock refresh " & q(fx.app) &
    " 2>&1")

proc installPreCommit(fx: SiblingFixture) =
  let hook = fx.app / ".git" / "hooks" / "pre-commit"
  createDir(hook.parentDir)
  writeFile(hook,
    "#!/usr/bin/env sh\nset -eu\n" &
    "REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)\n" &
    "cd \"$REPO_ROOT\"\nREPRO_STATUS=0\n" &
    q(fx.repro) & " hooks dispatch pre-commit --repo-root \"$REPO_ROOT\" " &
      "-- \"$@\" || REPRO_STATUS=$?\nexit $REPRO_STATUS\n")
  var perms = getFilePermissions(hook)
  perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(hook, perms)

proc commitInApp(fx: SiblingFixture; label: string):
    tuple[code: int; output: string] =
  writeFile(fx.app / (label & ".txt"), label & "\n")
  discard fx.git(fx.app, "add " & q(label & ".txt"))
  runCmd(AllowEnv & "= " & q(fx.gitBin) & " -C " & q(fx.app) &
    " commit -m " & q(label) & " 2>&1")

proc filesInHead(fx: SiblingFixture): string =
  fx.git(fx.app, "show --name-only --format= HEAD")

proc sameExceptOwnHead(fx: SiblingFixture; got, want: string): bool =
  ## ``got`` is ``want`` with only the self entry's revision moved to app's
  ## current HEAD. A refresh records the repo's own HEAD (§13.7.5 "The root
  ## entry"), and this case commits in app between the two writes, so that
  ## revision — and its integrity — is the one thing that legitimately differs.
  let wantSelf = depEntry(want, ".")
  let gotSelf = depEntry(got, ".")
  let head = fx.headOf(fx.app)
  var rev = wantSelf
  let at = rev.find("revision = \"")
  if at < 0: return false
  let old = rev[at + "revision = \"".len ..< rev.find('"', at + "revision = \"".len)]
  rev = rev.replace(old, head)
  got == want.replace(wantSelf, rev) and gotSelf == rev

proc setOrigin(fx: SiblingFixture; name, url: string) =
  discard fx.git(fx.ws / name, "remote set-url origin " & q(url))

suite "a committed lock's url spelling does not depend on the writing clone":

  test "re-spelled remotes rewrite nothing; another repository is recorded":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      delEnv("REPRO_WORKSPACE_CONFIG")
      let fx = setupSiblingFixture("url-spelling")
      defer: removeDir(fx.scratch)
      const libBUrl = "https://example.invalid/fixture/lib-b"
      const libCUrl = "https://example.invalid/fixture/lib-c"
      fx.setOrigin("lib-b", libBUrl)
      fx.setOrigin("lib-c", libCUrl)
      fx.refreshAndPublishLock()
      let written = readFile(fx.app / "repro.lock")
      checkpoint("lock as the first refresh wrote it:\n" & written)
      check ("url = \"" & libBUrl & "\"") in depEntry(written, "lib-b")
      check ("url = \"" & libCUrl & "\"") in depEntry(written, "lib-c")
      let libBPin = fx.headOf(fx.ws / "lib-b")
      let libCPin = fx.headOf(fx.ws / "lib-c")

      # The committed lock as a pre-v0.2.20 writer left it: lib-b's entry
      # carries `ref = "agents"` (the field order that writer used).
      let plain = "url = \"" & libBUrl & "\", revision = "
      check plain in written
      let legacy = written.replace(plain,
        "url = \"" & libBUrl & "\", ref = \"agents\", revision = ")
      writeFile(fx.app / "repro.lock", legacy)
      discard fx.git(fx.app, "add repro.lock")
      discard fx.git(fx.app, "commit -q -m legacy-ref")

      # Another clone's spellings of the SAME repositories.
      fx.setOrigin("lib-b", libBUrl & ".git")
      fx.setOrigin("lib-c", "git@example.invalid:fixture/lib-c.git")
      fx.installPreCommit()

      # 1. nothing moved: the commit leaves repro.lock alone.
      let c1 = fx.commitInApp("respelled")
      checkpoint("commit with re-spelled remotes:\n" & c1.output)
      check c1.code == 0
      check "repro.lock" notin fx.filesInHead()
      check readFile(fx.app / "repro.lock") == legacy
      check "refreshed sibling coordinates" notin c1.output

      # 2. a refresh on this clone writes what the first refresh wrote.
      var r = fx.refresh()
      checkpoint("refresh with re-spelled remotes:\n" & r.output)
      check r.code == 0
      let refreshed = readFile(fx.app / "repro.lock")
      checkpoint("lock after that refresh:\n" & refreshed)
      check fx.sameExceptOwnHead(refreshed, written)
      check "ref = " notin linePrefixed(refreshed, "deps = [")
      discard fx.git(fx.app, "add repro.lock")
      discard fx.git(fx.app, "commit -q -m refreshed")

      # 3. a remote naming another repository is a real coordinate change.
      const moved = "https://example.invalid/elsewhere/lib-b"
      fx.setOrigin("lib-b", moved)
      let c3 = fx.commitInApp("moved-remote")
      checkpoint("commit with lib-b moved to another repository:\n" &
        c3.output)
      check c3.code == 0
      check "repro.lock" in fx.filesInHead()
      let committed = fx.git(fx.app, "show HEAD:repro.lock")
      let libB = depEntry(committed, "lib-b")
      check ("url = \"" & moved & "\"") in libB
      check ("revision = \"" & libBPin & "\"") in libB
      let libC = depEntry(committed, "lib-c")
      check ("url = \"" & libCUrl & "\"") in libC
      check ("revision = \"" & libCPin & "\"") in libC
      r = fx.refresh()
      checkpoint("refresh after the move:\n" & r.output)
      check r.code == 0
      check fx.sameExceptOwnHead(readFile(fx.app / "repro.lock"), committed)
