## `repro lock refresh` never moves a committed `repro.lock` pin BACKWARD, and
## neither it nor the managed `pre-commit` re-pin records any branch for a pin
## (Unified-Locking-And-Hooks.md §13.3, §14.2).
##
## WHY. Both doors observe each sibling at whatever its shared checkout has
## checked out. A checkout left on a stale branch made a refresh roll four pins
## back to ANCESTORS of the pins already committed, and wrote the checkouts'
## local branch names (`blocktracer`, `n3g`) into `ref`, which name nothing on
## any other machine. A pin now records no branch at all: which branch holds a
## commit is a fact about the writer's remote-tracking refs, not about the
## commit. The commit hook already refuses a backward pin (covered by
## `t_commit_refuses_a_backward_sibling_pin.nim`); this file holds the explicit
## door to the same rule, and both doors to the no-branch rule.
##
## Fixture: `committed_lock_siblings_fixture.nim` — a real manifest workspace
## (app → lib-b → lib-c, lib-d unrelated) of real git repositories cloned from
## real bare origins, refreshed and published with the built `repro`.
##
## Cases:
##   * refresh against a sibling BEHIND its pin exits non-zero, leaves
##     `repro.lock` byte-identical, and names the sibling, `behind by N`, both
##     revisions, the checkout, a forward command (which really brings the
##     checkout forward, after which the refresh succeeds) and the flag;
##   * the same refresh with `--allow-pin-regression=lib-b` (or the
##     `REPRO_ALLOW_PIN_REGRESSION` variable) writes the older pin and says so;
##   * the incident: the sibling switched to a stale LOCAL branch — refused;
##     when allowed, the pin records the commit and never the local name;
##   * a DIVERGED sibling (another line of history) is refused without the
##     flag and written with it;
##   * an AHEAD sibling advances with no refusal;
##   * no pin records a branch, for a sibling or for the root, whichever
##     branches the checkouts sit on; publishing an unmoved pin on another
##     branch changes no byte;
##   * through the real `pre-commit` hook: a sibling on a local-only branch is
##     pinned with no branch; a `ref` an older writer committed over an
##     unmoved revision is left alone (nothing moved), and dropped when the
##     pin next moves; a sibling switched to a stale local branch refuses the
##     commit.
##
## NO MOCKS. The hook file is written by hand rather than by
## `repro hooks ensure --vcs` so that it names the built binary by absolute
## path (a dev-shell `repro` on PATH cannot stand in for the one under test);
## its body is the managed body's dispatch line.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_test_support
import ./committed_lock_siblings_fixture

const AllowEnv = "REPRO_ALLOW_PIN_REGRESSION"

proc field(entry, key: string): string =
  let k = key & " = \""
  let at = entry.find(k)
  if at < 0: return "<absent>"
  let stop = entry.find('"', at + k.len)
  entry[at + k.len ..< stop]

proc pinOf(lockBody, name: string): string =
  field(depEntry(lockBody, name), "revision")

proc noRef(lockBody, name: string): bool =
  ## Whether the `deps` entry `name` records no branch: a pin is a commit
  ## (Unified-Locking-And-Hooks.md §14.2).
  let entry = depEntry(lockBody, name)
  entry.len > 0 and field(entry, "ref") == "<absent>"

proc refresh(fx: SiblingFixture; extra = ""; allowEnv = ""):
    tuple[code: int; output: string] =
  ## `repro lock refresh <app>` with `REPRO_ALLOW_PIN_REGRESSION` set
  ## explicitly, so a value exported in the suite's environment cannot leak in.
  runCmd(AllowEnv & "=" & q(allowEnv) & " " & q(fx.repro) &
    " lock refresh " & q(fx.app) & (if extra.len > 0: " " & extra else: "") &
    " 2>&1")

proc lineWith(text: string; needles: varargs[string]): string =
  for line in text.splitLines():
    var all = true
    for n in needles:
      if n notin line:
        all = false
        break
    if all: return line
  ""

proc backticked(text: string): seq[string] =
  var i = 0
  while true:
    let open = text.find('`', i)
    if open < 0: break
    let close = text.find('`', open + 1)
    if close < 0: break
    result.add(text[open + 1 ..< close])
    i = close + 1

type Started = object
  fx: SiblingFixture
  libB: string
  seed: string     ## lib-b's first commit
  pinned: string   ## lib-b's newest published commit — what the lock pins

proc startPinnedAtNewest(label: string): Started =
  ## The committed lock pins lib-b at its newest published commit, two commits
  ## after its seed.
  var fx = setupSiblingFixture(label)
  result.libB = fx.ws / "lib-b"
  result.seed = fx.headOf(result.libB)
  discard fx.advance("lib-b")
  result.pinned = fx.advance("lib-b")
  fx.refreshAndPublishLock()
  let committed = fx.git(fx.app, "show HEAD:repro.lock")
  doAssert pinOf(committed, "lib-b") == result.pinned,
    "the baseline lock does not pin lib-b's newest commit:\n" & committed
  result.fx = fx

proc hookPath(fx: SiblingFixture): string =
  fx.app / ".git" / "hooks" / "pre-commit"

proc installHook(fx: SiblingFixture) =
  let hook = fx.hookPath()
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

proc tryCommit(fx: SiblingFixture; label: string):
    tuple[code: int; output: string] =
  writeFile(fx.app / (label & ".txt"), label & "\n")
  discard fx.git(fx.app, "add " & q(label & ".txt"))
  runCmd(AllowEnv & "= " & q(fx.gitBin) & " -C " & q(fx.app) &
    " commit -m " & q(label) & " 2>&1")

suite "repro lock refresh never moves a pin backward":

  test "t_a_refresh_against_a_behind_sibling_is_refused_and_names_the_remedy":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let s = startPinnedAtNewest("refresh-behind")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      discard fx.git(s.libB, "reset -q --hard HEAD~2")
      check fx.headOf(s.libB) == s.seed
      let lockBefore = readFile(fx.app / "repro.lock")

      let r = fx.refresh()
      checkpoint(r.output)
      check r.code != 0
      check readFile(fx.app / "repro.lock") == lockBefore
      let headline = lineWith(r.output, "repro.lock sibling 'lib-b'",
        "behind by 2 commit(s)")
      checkpoint("headline: " & headline)
      check headline.len > 0
      check s.pinned in headline
      check s.seed in headline
      check s.libB in headline
      check "--allow-pin-regression=lib-b" in r.output
      check "repro ws sync" in r.output

      # The forward command runs where it is printed and brings the checkout
      # up to the pin; the same refresh then succeeds and keeps the pin.
      let forward = backticked(lineWith(r.output, "bring the checkout forward"))
      check forward.len == 1
      if forward.len == 1:
        check "merge --ff-only" in forward[0]
        let ran = runCmd(forward[0], fx.app)
        checkpoint("ran `" & forward[0] & "`:\n" & ran.output)
        check ran.code == 0
        check fx.headOf(s.libB) == s.pinned
        let again = fx.refresh()
        checkpoint(again.output)
        check again.code == 0
        check pinOf(readFile(fx.app / "repro.lock"), "lib-b") == s.pinned

  test "t_an_allowed_regression_writes_the_older_pin_and_says_so":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let s = startPinnedAtNewest("refresh-allowed")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      discard fx.git(s.libB, "reset -q --hard HEAD~2")

      let byFlag = fx.refresh("--allow-pin-regression=lib-b")
      checkpoint(byFlag.output)
      check byFlag.code == 0
      check pinOf(readFile(fx.app / "repro.lock"), "lib-b") == s.seed
      let announced = lineWith(byFlag.output, "allowed pin regression",
        "lib-b")
      check announced.len > 0
      check s.pinned in announced
      check s.seed in announced

      # The variable is the same allowance, for the same sibling only.
      discard fx.git(fx.app, "checkout -q -- repro.lock")
      let byEnv = fx.refresh(allowEnv = "lib-b")
      checkpoint(byEnv.output)
      check byEnv.code == 0
      check pinOf(readFile(fx.app / "repro.lock"), "lib-b") == s.seed
      discard fx.git(fx.app, "checkout -q -- repro.lock")
      let other = fx.refresh(allowEnv = "lib-c")
      checkpoint(other.output)
      check other.code != 0
      check pinOf(readFile(fx.app / "repro.lock"), "lib-b") == s.pinned
      check "names 'lib-c', which this refresh does not move backward" in
        other.output

  test "t_a_sibling_on_a_stale_local_branch_is_refused_and_never_named":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let s = startPinnedAtNewest("refresh-stale-branch")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      # The incident: the shared checkout sits on an old local branch.
      discard fx.git(s.libB, "checkout -q -b blocktracer " & s.seed)

      let r = fx.refresh()
      checkpoint(r.output)
      check r.code != 0
      check pinOf(readFile(fx.app / "repro.lock"), "lib-b") == s.pinned
      check lineWith(r.output, "lib-b", "behind by 2").len > 0

      let allowed = fx.refresh("--allow-pin-regression=lib-b")
      checkpoint(allowed.output)
      check allowed.code == 0
      let body = readFile(fx.app / "repro.lock")
      check pinOf(body, "lib-b") == s.seed
      check noRef(body, "lib-b")
      check "\"blocktracer\"" notin body

  test "t_a_diverged_sibling_needs_the_explicit_flag":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let s = startPinnedAtNewest("refresh-diverged")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      discard fx.git(s.libB, "reset -q --hard HEAD~1")
      writeFile(s.libB / "other-line.txt", "another line of history\n")
      discard fx.git(s.libB, "add other-line.txt")
      discard fx.git(s.libB, "commit -q -m other-line")
      let sideways = fx.headOf(s.libB)

      let r = fx.refresh()
      checkpoint(r.output)
      check r.code != 0
      check pinOf(readFile(fx.app / "repro.lock"), "lib-b") == s.pinned
      check lineWith(r.output, "lib-b", "diverged: 1 and 1").len > 0

      let allowed = fx.refresh("--allow-pin-regression=lib-b")
      checkpoint(allowed.output)
      check allowed.code == 0
      let body = readFile(fx.app / "repro.lock")
      check pinOf(body, "lib-b") == sideways
      # Not reachable from any published branch, and recorded the same way
      # as any other commit: by revision, with no branch.
      check noRef(body, "lib-b")

  test "t_an_ahead_sibling_advances":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let s = startPinnedAtNewest("refresh-ahead")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      let next = fx.advance("lib-b")
      let r = fx.refresh()
      checkpoint(r.output)
      check r.code == 0
      check pinOf(readFile(fx.app / "repro.lock"), "lib-b") == next
      check "REFUSED" notin r.output
      check "allowed pin regression" notin r.output

suite "a committed lock names no branch":

  test "t_refresh_records_no_branch_and_publication_changes_nothing":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let s = startPinnedAtNewest("ref-published")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      # lib-b on a local-only topic branch at a published commit; the root on
      # a local-only branch too.
      discard fx.git(s.libB, "checkout -q -b n3g")
      discard fx.git(fx.app, "checkout -q -b local-topic")
      var r = fx.refresh()
      checkpoint(r.output)
      check r.code == 0
      var body = readFile(fx.app / "repro.lock")
      check noRef(body, "lib-b")
      check noRef(body, ".")
      check "\"n3g\"" notin body
      check "\"local-topic\"" notin body

      # lib-b sits on the local-only `n3g`, so `advance` publishes nothing to
      # `main`: the commit is on `dev` alone, then on `agents` and `dev`.
      let next = fx.advance("lib-b")
      discard fx.git(s.libB, "push -q origin HEAD:dev")
      discard fx.git(s.libB, "fetch -q origin")
      r = fx.refresh()
      checkpoint(r.output)
      check r.code == 0
      body = readFile(fx.app / "repro.lock")
      check pinOf(body, "lib-b") == next
      check noRef(body, "lib-b")
      # Publishing the pinned commit on another branch changes no byte.
      discard fx.git(s.libB, "push -q origin HEAD:agents")
      discard fx.git(s.libB, "fetch -q origin")
      r = fx.refresh()
      check r.code == 0
      check readFile(fx.app / "repro.lock") == body
      # A moved pin records the commit and nothing else.
      let newest = fx.advance("lib-b")
      discard fx.git(s.libB, "push -q origin HEAD:agents HEAD:dev")
      discard fx.git(s.libB, "fetch -q origin")
      r = fx.refresh()
      checkpoint(r.output)
      check r.code == 0
      body = readFile(fx.app / "repro.lock")
      check pinOf(body, "lib-b") == newest
      check noRef(body, "lib-b")

  test "t_the_commit_hook_records_no_branch_and_drops_a_recorded_one":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      let s = startPinnedAtNewest("ref-hook")
      defer: removeDir(s.fx.scratch)
      let fx = s.fx
      fx.installHook()

      # A sibling advanced on a local-only branch and published to `main`.
      discard fx.git(s.libB, "checkout -q -b n3g")
      let next = fx.advance("lib-b")
      discard fx.git(s.libB, "push -q origin HEAD:main")
      discard fx.git(s.libB, "fetch -q origin")
      var c = fx.tryCommit("adopt-lib-b-from-a-topic-branch")
      checkpoint(c.output)
      check c.code == 0
      var body = fx.git(fx.app, "show HEAD:repro.lock")
      check pinOf(body, "lib-b") == next
      check noRef(body, "lib-b")
      check "\"n3g\"" notin body

      # A lock an older writer committed carries a `ref`. Over an unmoved
      # revision it is not a change — nothing reads it — so the hook leaves
      # the file alone, whatever the remote now publishes.
      let lockPath = fx.app / "repro.lock"
      writeFile(lockPath, readFile(lockPath).replace(
        "revision = \"" & next & "\"",
        "ref = \"blocktracer\", revision = \"" & next & "\""))
      check not noRef(readFile(lockPath), "lib-b")
      discard fx.git(fx.app, "add repro.lock")
      discard fx.git(fx.app, "commit -q --no-verify -m older-writer-ref")
      discard fx.git(s.libB, "push -q origin HEAD:agents")
      discard fx.git(s.libB, "fetch -q origin")
      let lockBefore = readFile(lockPath)
      c = fx.tryCommit("nothing-moved")
      checkpoint(c.output)
      check c.code == 0
      check readFile(lockPath) == lockBefore
      check fx.git(fx.app, "diff --name-only HEAD~1 HEAD").strip() ==
        "nothing-moved.txt"

      # The next re-pin that moves the sibling rewrites the entry, and the
      # recorded branch goes with it. (`advance` pushes the local `main`, so
      # bring it up to the published tip first.)
      discard fx.git(s.libB, "branch -f main HEAD")
      let newest = fx.advance("lib-b")
      discard fx.git(s.libB, "push -q origin HEAD:main")
      discard fx.git(s.libB, "fetch -q origin")
      c = fx.tryCommit("adopt-the-newest-lib-b")
      checkpoint(c.output)
      check c.code == 0
      body = fx.git(fx.app, "show HEAD:repro.lock")
      check pinOf(body, "lib-b") == newest
      check noRef(body, "lib-b")
      check "\"blocktracer\"" notin body

      # The incident through the hook: the checkout switched to a stale
      # local branch refuses the commit and writes nothing.
      let pinnedLock = readFile(lockPath)
      discard fx.git(s.libB, "checkout -q -b blocktracer " & s.seed)
      let headBefore = fx.headOf(fx.app)
      c = fx.tryCommit("work-against-a-stale-branch")
      checkpoint(c.output)
      check c.code != 0
      check fx.headOf(fx.app) == headBefore
      check readFile(lockPath) == pinnedLock
      check lineWith(c.output, "lib-b", "behind by 4").len > 0
