## A committed `repro.lock`'s bytes depend only on the commits it pins, never
## on the writing machine's remote-tracking refs (Unified-Locking-And-Hooks.md
## §14.2).
##
## WHY. A pin used to record `ref`, the published branch containing its
## revision, read from the writer's remote-tracking refs. Two clones of one
## workspace at the same commits — one fetched, one not; one single-branch;
## one with an extra remote — wrote different bytes for the same pins, and
## publishing a sibling turned a dependent's `ref = ""` into `ref = "main"`
## with no pinned commit moved. A certificate binds the tracked lock, so the
## lock a `repro push` certified was no longer the commit it pushed.
##
## Fixture: `committed_lock_siblings_fixture.nim` — a real manifest workspace
## (app → lib-b → lib-c) of real git repositories cloned from real bare
## origins, refreshed with the built `repro`. A second workspace holds clones
## of the same repositories at the same commits, set up so that every
## remote-tracking fact differs:
##
##   * lib-b: workspace one has `origin/main` and `origin/dev` (both contain
##     the commit); workspace two is a single-branch clone of `dev`;
##   * lib-c: its HEAD is unpublished in both — workspace two additionally
##     has a `mirror` remote whose `topic` branch contains it;
##   * app: workspace two never fetched `origin/dev`.
##
## Cases:
##   * `repro lock refresh` writes byte-identical `repro.lock` in both, and
##     no pin carries a `ref`;
##   * publishing lib-c to `origin/main` and refreshing again — in the clone
##     that fetched it and in the one that did not — leaves both locks
##     byte-identical to what they were.
##
## NO MOCKS.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_test_support
import ./committed_lock_siblings_fixture

const AllowEnv = "REPRO_ALLOW_PIN_REGRESSION"

proc refresh(fx: SiblingFixture; target: string):
    tuple[code: int; output: string] =
  ## `repro lock refresh <target>`, with `REPRO_ALLOW_PIN_REGRESSION` cleared
  ## so a value exported in the suite's environment cannot leak in.
  runCmd(AllowEnv & "= " & q(fx.repro) & " lock refresh " & q(target) &
    " 2>&1")

proc commitIn(fx: SiblingFixture; repo, label: string): string =
  writeFile(repo / "clone-identity.txt", label & "\n")
  discard fx.git(repo, "add clone-identity.txt")
  discard fx.git(repo, "commit -q -m " & q(label))
  fx.headOf(repo)

proc cloneInto(fx: SiblingFixture; origin, dest: string; extra = "") =
  discard requireCmd(q(fx.gitBin) & " clone -q " & extra & " " &
    q(fileUrl(origin)) & " " & q(dest))
  discard fx.git(dest, "config user.email tester@example.invalid")
  discard fx.git(dest, "config user.name \"Lock Tester\"")
  discard fx.git(dest, "config commit.gpgsign false")

proc originOf(fx: SiblingFixture; name: string): string =
  for (n, origin) in fx.origins:
    if n == name: return origin
  doAssert false, "no origin for " & name

proc remoteTracking(fx: SiblingFixture; repo: string): string =
  fx.git(repo, "for-each-ref " & q("--format=%(refname)") &
    " refs/remotes/").strip()

suite "a committed lock's bytes do not depend on remote-tracking refs":

  test "two clones with different remote-tracking refs write identical " &
      "locks, and publishing a sibling changes neither":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      delEnv("REPRO_WORKSPACE_CONFIG")
      let fx = setupSiblingFixture("clone-identity")
      defer: removeDir(fx.scratch)
      let ws1 = fx.ws
      let ws2 = fx.scratch / "workspace-two"

      # Workspace one: lib-b's commit published on `main` and `dev`, lib-c's
      # and app's on `main` only, then an UNPUBLISHED lib-c commit.
      let libB1 = ws1 / "lib-b"
      let libC1 = ws1 / "lib-c"
      let bTip = fx.commitIn(libB1, "lib-b published")
      discard fx.git(libB1, "push -q origin HEAD:refs/heads/main " &
        "HEAD:refs/heads/dev")
      discard fx.git(libB1, "fetch -q origin")
      discard fx.git(fx.app, "push -q origin HEAD:refs/heads/dev")
      discard fx.git(fx.app, "fetch -q origin")
      let cTip = fx.commitIn(libC1, "lib-c not published yet")
      let aTip = fx.headOf(fx.app)

      # Workspace two: the same manifests, clones of the same origins at the
      # same commits, with different remote-tracking refs.
      createDir(ws2)
      for dir in ["projects", "repos", ".repro"]:
        copyDir(ws1 / dir, ws2 / dir)
      fx.cloneInto(fx.originOf("app"), ws2 / "app",
        "--single-branch --branch main")
      fx.cloneInto(fx.originOf("lib-b"), ws2 / "lib-b",
        "--single-branch --branch dev")
      fx.cloneInto(fx.originOf("lib-c"), ws2 / "lib-c")
      fx.cloneInto(fx.originOf("lib-d"), ws2 / "lib-d")
      # lib-c's unpublished commit reaches workspace two through a mirror
      # that publishes it on a topic branch; `origin` still lacks it.
      let mirror = fx.scratch / "mirror-lib-c.git"
      discard requireCmd(q(fx.gitBin) & " init -q --bare -b main " & q(mirror))
      discard fx.git(libC1, "push -q " & q(fileUrl(mirror)) &
        " HEAD:refs/heads/topic")
      discard fx.git(ws2 / "lib-c", "remote add mirror " & q(fileUrl(mirror)))
      discard fx.git(ws2 / "lib-c", "fetch -q mirror")
      discard fx.git(ws2 / "lib-c", "checkout -q -B main mirror/topic")
      check fx.headOf(ws2 / "app") == aTip
      check fx.headOf(ws2 / "lib-b") == bTip
      check fx.headOf(ws2 / "lib-c") == cTip
      # The precondition: the two workspaces really do see different
      # remote-tracking refs for every repository the lock pins.
      for name in ["app", "lib-b", "lib-c"]:
        check fx.remoteTracking(ws1 / name) != fx.remoteTracking(ws2 / name)

      var r = fx.refresh(ws1 / "app")
      checkpoint("refresh in workspace one:\n" & r.output)
      check r.code == 0
      r = fx.refresh(ws2 / "app")
      checkpoint("refresh in workspace two:\n" & r.output)
      check r.code == 0
      let lock1 = readFile(ws1 / "app" / "repro.lock")
      let lock2 = readFile(ws2 / "app" / "repro.lock")
      checkpoint("workspace one's lock:\n" & lock1)
      checkpoint("workspace two's lock:\n" & lock2)
      for (name, tip) in [(".", aTip), ("lib-b", bTip), ("lib-c", cTip)]:
        check ("revision = \"" & tip & "\"") in depEntry(lock1, name)
      # THE PROPERTY: the same pins are the same bytes.
      check lock1 == lock2
      # No pin records a branch at all.
      check "ref = " notin linePrefixed(lock1, "deps = [")

      # Publishing lib-c changes no pinned commit, so it changes no byte:
      # neither in the clone that fetched the publication nor in the one
      # that did not.
      discard fx.git(libC1, "push -q origin HEAD:refs/heads/main")
      discard fx.git(libC1, "fetch -q origin")
      r = fx.refresh(ws1 / "app")
      checkpoint("refresh after publishing lib-c, workspace one:\n" & r.output)
      check r.code == 0
      check readFile(ws1 / "app" / "repro.lock") == lock1
      r = fx.refresh(ws2 / "app")
      checkpoint("refresh after publishing lib-c, workspace two:\n" & r.output)
      check r.code == 0
      check readFile(ws2 / "app" / "repro.lock") == lock2
      discard fx.git(ws2 / "lib-c", "fetch -q origin")
      r = fx.refresh(ws2 / "app")
      checkpoint("refresh after fetching it, workspace two:\n" & r.output)
      check r.code == 0
      check readFile(ws2 / "app" / "repro.lock") == lock2
