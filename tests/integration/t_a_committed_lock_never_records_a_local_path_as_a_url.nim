## A committed `repro.lock` never records a directory on the writing machine as
## a sibling's fetch `url`.
##
## WHY. Codetracer `a9d16e2b4b` (2026-11-26) committed a lock that named 19
## siblings at `/home/…/codetracer-gui/<repo>` instead of their GitHub URLs,
## and a mirror workspace's hooks wrote `/tmp/p79/m/<repo>` the same way. The
## siblings had been cloned from the workspace (`git clone ../m/<repo>`), so
## their `origin` was a local directory, and the managed pre-commit hook took
## each sibling's URL from that `origin`, printing `repro-lock refreshed sibling
## coordinates; staged into this commit`.
## `repro lock refresh` used the same source. No other machine can fetch from
## such a URL.
##
## WHAT IS PINNED. The root `app` is published at a network URL; the siblings'
## remotes are local (the fixture's bare repositories, and clones of them).
##
##   1. A local remote is FOLLOWED to the repository it was cloned from: each
##      bare origin is given a network `origin`, and `repro lock refresh`
##      records that URL, not the bare directory.
##   2. The commit-time re-pin does not replace a recorded URL with a local
##      one: lib-b is re-pointed at a clone of its bare origin (two local hops to
##      the network URL) and lib-c at a clone with no remote at all; a commit in
##      app leaves `repro.lock` untouched.
##   3. `repro lock refresh` then keeps lib-c's URL from the existing lock.
##   4. A lock already carrying a local URL (as `a9d16e2b4b` did) is repaired
##      where the chain reaches a network URL (lib-b), and the refresh is
##      REFUSED, naming the entry, where nothing does (lib-c).
##
## Fixture-only workspaces, whose root is itself known only by a local path,
## keep recording local URLs; every other committed-lock test depends on it.
##
## Falsifiability: at reprobuild c709357a7 (v0.2.31 era) case 1 records
## `file:///…/origin-lib-b.git`, case 2's commit prints `refreshed sibling
## coordinates` and stages the mirror paths, and case 4's refresh exits 0 with
## lib-c's local path in the lock.
##
## NO MOCKS. Real repositories, the real hook dispatch (written by hand so the
## built binary is named by absolute path, as in
## t_lock_url_spelling_does_not_depend_on_the_writing_clone), the built repro.

import std/[os, strutils, unittest]
import ./committed_lock_siblings_fixture
import repro_test_support/reasoned_skip

const AllowEnv = "REPRO_ALLOW_PIN_REGRESSION"
const AppUrl = "https://example.invalid/fixture/app"
const LibBUrl = "https://example.invalid/fixture/lib-b"
const LibCUrl = "https://example.invalid/fixture/lib-c"

proc refresh(fx: SiblingFixture): tuple[code: int; output: string] =
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

proc originOf(fx: SiblingFixture; name: string): string =
  for (n, o) in fx.origins:
    if n == name: return o

proc commitLock(fx: SiblingFixture; label: string) =
  discard fx.git(fx.app, "add repro.lock")
  discard fx.git(fx.app, "commit -q --no-verify -m " & q(label))

suite "a committed lock never records a local path as a url":

  test "local remotes are followed, kept out, and refused":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      delEnv("REPRO_WORKSPACE_CONFIG")
      let fx = setupSiblingFixture("local-url")
      defer: removeDir(fx.scratch)
      # app is published; its siblings' clones point at local directories.
      discard fx.git(fx.app, "remote set-url origin " & q(AppUrl))
      discard fx.git(fx.originOf("lib-b"), "remote add origin " & q(LibBUrl))
      discard fx.git(fx.originOf("lib-c"), "remote add origin " & q(LibCUrl))

      # 1. followed to the network URL.
      var r = fx.refresh()
      checkpoint("refresh:\n" & r.output)
      require r.code == 0
      let first = readFile(fx.app / "repro.lock")
      checkpoint("lock:\n" & first)
      check ("url = \"" & LibBUrl & "\"") in depEntry(first, "lib-b")
      check ("url = \"" & LibCUrl & "\"") in depEntry(first, "lib-c")
      check fx.scratch notin first
      fx.commitLock("lock")

      # 2. the commit-time re-pin keeps local remotes out.
      let mirror = fx.scratch / "mirror"
      createDir(mirror)
      # Each mirror is cloned from the sibling's bare origin, so lib-b's chain
      # is checkout -> mirror -> bare origin -> network URL.
      discard requireCmd(q(fx.gitBin) & " clone -q " &
        q(fx.originOf("lib-b")) & " " & q(mirror / "lib-b"))
      discard requireCmd(q(fx.gitBin) & " clone -q " &
        q(fx.originOf("lib-c")) & " " & q(mirror / "lib-c"))
      discard fx.git(mirror / "lib-c", "remote remove origin")
      discard fx.git(fx.ws / "lib-b", "remote set-url origin " &
        q(mirror / "lib-b"))
      discard fx.git(fx.ws / "lib-c", "remote set-url origin " &
        q(mirror / "lib-c"))
      fx.installPreCommit()
      writeFile(fx.app / "note.txt", "note\n")
      discard fx.git(fx.app, "add note.txt")
      let c = runCmd(AllowEnv & "= " & q(fx.gitBin) & " -C " & q(fx.app) &
        " commit -m note 2>&1")
      checkpoint("commit:\n" & c.output)
      check c.code == 0
      check "refreshed sibling coordinates" notin c.output
      check "repro.lock" notin fx.git(fx.app, "show --name-only --format= HEAD")
      check readFile(fx.app / "repro.lock") == first

      # 3. the refresh keeps lib-c's URL from the existing lock.
      r = fx.refresh()
      checkpoint("refresh with local remotes:\n" & r.output)
      check r.code == 0
      let kept = readFile(fx.app / "repro.lock")
      checkpoint("lock:\n" & kept)
      check ("url = \"" & LibBUrl & "\"") in depEntry(kept, "lib-b")
      check ("url = \"" & LibCUrl & "\"") in depEntry(kept, "lib-c")
      check fx.scratch notin kept

      # 4. a lock that already carries local URLs.
      let broken = kept.replace("url = \"" & LibBUrl & "\"",
        "url = \"" & mirror / "lib-b" & "\"").replace(
        "url = \"" & LibCUrl & "\"", "url = \"" & mirror / "lib-c" & "\"")
      check broken != kept
      writeFile(fx.app / "repro.lock", broken)
      r = fx.refresh()
      checkpoint("refresh of a lock carrying local urls:\n" & r.output)
      check r.code != 0
      check "refusing to write a local path" in r.output
      check "'lib-c'" in r.output
      check "'lib-b'" notin r.output
      # With lib-c published again, the same lock is repaired.
      discard fx.git(mirror / "lib-c", "remote add origin " & q(LibCUrl))
      r = fx.refresh()
      checkpoint("refresh after publishing lib-c:\n" & r.output)
      check r.code == 0
      let repaired = readFile(fx.app / "repro.lock")
      check ("url = \"" & LibBUrl & "\"") in depEntry(repaired, "lib-b")
      check ("url = \"" & LibCUrl & "\"") in depEntry(repaired, "lib-c")
      check fx.scratch notin repaired
