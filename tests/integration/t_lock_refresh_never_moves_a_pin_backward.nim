## `repro lock refresh` never moves a committed `repro.lock` pin BACKWARD, and
## neither it nor the managed `pre-commit` re-pin ever records a local-only
## branch name as a pin's `ref` (Unified-Locking-And-Hooks.md §13.3, §14.2).
##
## WHY. Both doors observe each sibling at whatever its shared checkout has
## checked out. A checkout left on a stale branch made a refresh roll four pins
## back to ANCESTORS of the pins already committed, and wrote the checkouts'
## local branch names (`blocktracer`, `n3g`) into `ref`, which name nothing on
## any other machine. The commit hook already refuses a backward pin (covered by
## `t_commit_refuses_a_backward_sibling_pin.nim`); this file holds the explicit
## door to the same rule, and both doors to the `ref` rule.
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
##     when allowed, the recorded `ref` is the published branch, never the
##     local name;
##   * a DIVERGED sibling (another line of history) is refused without the
##     flag and written with it;
##   * an AHEAD sibling advances with no refusal;
##   * `ref` is a remote-tracking branch containing the commit, preferring
##     `agents`, then `dev`; a local-only branch is never written for a
##     sibling or for the root; an unpublished commit records an empty `ref`;
##   * through the real `pre-commit` hook: a sibling on a local-only branch is
##     pinned with its published `ref`; a committed local-only `ref` over an
##     unmoved revision is repaired; a still-published `ref` over an unmoved
##     revision is kept (no churn); a sibling switched to a stale local branch
##     refuses the commit.
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

proc pinOf(lockBody, path: string): string =
  field(depEntry(lockBody, path), "revision")

proc refOf(lockBody, path: string): string =
  field(depEntry(lockBody, path), "ref")

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
  doAssert pinOf(committed, "../lib-b") == result.pinned,
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
        check pinOf(readFile(fx.app / "repro.lock"), "../lib-b") == s.pinned

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
      check pinOf(readFile(fx.app / "repro.lock"), "../lib-b") == s.seed
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
      check pinOf(readFile(fx.app / "repro.lock"), "../lib-b") == s.seed
      discard fx.git(fx.app, "checkout -q -- repro.lock")
      let other = fx.refresh(allowEnv = "lib-c")
      checkpoint(other.output)
      check other.code != 0
      check pinOf(readFile(fx.app / "repro.lock"), "../lib-b") == s.pinned
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
      check pinOf(readFile(fx.app / "repro.lock"), "../lib-b") == s.pinned
      check lineWith(r.output, "lib-b", "behind by 2").len > 0

      let allowed = fx.refresh("--allow-pin-regression=lib-b")
      checkpoint(allowed.output)
      check allowed.code == 0
      let body = readFile(fx.app / "repro.lock")
      check pinOf(body, "../lib-b") == s.seed
      check refOf(body, "../lib-b") == "main"
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
      check pinOf(readFile(fx.app / "repro.lock"), "../lib-b") == s.pinned
      check lineWith(r.output, "lib-b", "diverged: 1 and 1").len > 0

      let allowed = fx.refresh("--allow-pin-regression=lib-b")
      checkpoint(allowed.output)
      check allowed.code == 0
      let body = readFile(fx.app / "repro.lock")
      check pinOf(body, "../lib-b") == sideways
      # Not reachable from any published branch: no ref rather than a
      # local one.
      check refOf(body, "../lib-b") == ""

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
      check pinOf(readFile(fx.app / "repro.lock"), "../lib-b") == next
      check "REFUSED" notin r.output
      check "allowed pin regression" notin r.output

suite "a committed lock's ref names a published branch":

  test "t_refresh_records_the_published_branch_not_the_local_one":
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
      check refOf(body, "../lib-b") == "main"
      check refOf(body, ".") == "main"
      check "\"n3g\"" notin body
      check "\"local-topic\"" notin body

      # `agents` is preferred, then `dev`, over every other published branch.
      let next = fx.advance("lib-b")
      discard fx.git(s.libB, "push -q origin HEAD:dev")
      discard fx.git(s.libB, "fetch -q origin")
      r = fx.refresh()
      checkpoint(r.output)
      check r.code == 0
      body = readFile(fx.app / "repro.lock")
      check pinOf(body, "../lib-b") == next
      check refOf(body, "../lib-b") == "dev"
      discard fx.git(s.libB, "push -q origin HEAD:agents")
      discard fx.git(s.libB, "fetch -q origin")
      # Re-observing an UNMOVED pin keeps a ref that is still published.
      r = fx.refresh()
      check r.code == 0
      check refOf(readFile(fx.app / "repro.lock"), "../lib-b") == "dev"
      # A moved pin takes the preferred published branch.
      let newest = fx.advance("lib-b")
      discard fx.git(s.libB, "push -q origin HEAD:agents HEAD:dev")
      discard fx.git(s.libB, "fetch -q origin")
      r = fx.refresh()
      checkpoint(r.output)
      check r.code == 0
      body = readFile(fx.app / "repro.lock")
      check pinOf(body, "../lib-b") == newest
      check refOf(body, "../lib-b") == "agents"

  test "t_the_commit_hook_records_and_repairs_published_refs":
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
      check pinOf(body, "../lib-b") == next
      check refOf(body, "../lib-b") == "main"
      check "\"n3g\"" notin body

      # A committed local-only ref over an unmoved revision is repaired.
      let lockPath = fx.app / "repro.lock"
      writeFile(lockPath, readFile(lockPath).replace(
        "ref = \"main\", revision = \"" & next & "\"",
        "ref = \"blocktracer\", revision = \"" & next & "\""))
      check refOf(readFile(lockPath), "../lib-b") == "blocktracer"
      discard fx.git(fx.app, "add repro.lock")
      discard fx.git(fx.app, "commit -q --no-verify -m hand-edited-ref")
      c = fx.tryCommit("repair-the-ref")
      checkpoint(c.output)
      check c.code == 0
      body = fx.git(fx.app, "show HEAD:repro.lock")
      check pinOf(body, "../lib-b") == next
      check refOf(body, "../lib-b") == "main"

      # A still-published ref over an unmoved revision is kept: a new
      # preferred branch containing it does not churn the lock.
      discard fx.git(s.libB, "push -q origin HEAD:agents")
      discard fx.git(s.libB, "fetch -q origin")
      let lockBefore = readFile(lockPath)
      c = fx.tryCommit("nothing-moved")
      checkpoint(c.output)
      check c.code == 0
      check readFile(lockPath) == lockBefore
      check fx.git(fx.app, "diff --name-only HEAD~1 HEAD").strip() ==
        "nothing-moved.txt"

      # The incident through the hook: the checkout switched to a stale
      # local branch refuses the commit and writes nothing.
      discard fx.git(s.libB, "checkout -q -b blocktracer " & s.seed)
      let headBefore = fx.headOf(fx.app)
      c = fx.tryCommit("work-against-a-stale-branch")
      checkpoint(c.output)
      check c.code != 0
      check fx.headOf(fx.app) == headBefore
      check readFile(lockPath) == lockBefore
      check lineWith(c.output, "lib-b", "behind by 3").len > 0
